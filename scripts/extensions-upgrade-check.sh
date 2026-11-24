#!/bin/bash
# Read-only assertions for individual phases of the clean macOS 26 upgrade drill.
# Each invocation checks existing observations. It never installs software or changes user state.
set -euo pipefail
exec python3 - "$@" <<'PY'
import argparse
import base64
import hashlib
import json
import platform
import re
import subprocess
import sys
import tempfile
from pathlib import Path

PROVIDERS = {"github-ci", "neon", "turso", "vercel", "cloudflare",
             "ai-usage", "ai-limits", "acp-opencode", "acp-antigravity"}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def load(path):
    return json.loads(Path(path).read_bytes())


def command(*args):
    return subprocess.check_output(list(map(str, args)), stderr=subprocess.STDOUT, text=True)


def check_host(args):
    require(platform.mac_ver()[0].split(".")[0] == "26", "Requires macOS 26")
    require(platform.machine() == args.arch, "Machine architecture differs from the requested gate")
    if args.arch == "x86_64":
        translated = subprocess.run(["sysctl", "-in", "sysctl.proc_translated"], capture_output=True, text=True)
        require(translated.stdout.strip() != "1", "Requires an Intel system, not a translated process")
    app = args.app.resolve(strict=True)
    require(app.parent == Path("/Applications"), "Install the DMG host into /Applications")
    details = command("codesign", "-dvvv", app)
    require("\nTeamIdentifier=T7GYB573Y6\n" in details and "\nAuthority=Developer ID Application:" in details,
            "Host requires the rxlab Developer ID signature")
    command("codesign", "--verify", "--all-architectures", "--strict", "--deep", app)
    command("xcrun", "stapler", "validate", app)
    command("spctl", "--assess", "--type", "execute", app)
    plist = app / "Contents" / "Info.plist"
    require(command("plutil", "-extract", "CFBundleIdentifier", "raw", plist).strip() == "app.rxlab.flowcy.code",
            "Unexpected Release host bundle ID")
    print(f"Verified Gatekeeper assessment, staple, team, architecture and OS for {app.name}.")


def check_bundles(args):
    folder = args.app / "Contents/Resources/BundledExtensions"
    lock = load(args.lock)
    if isinstance(lock, dict):
        lock = lock.get("extensions")
    require(isinstance(lock, list) and len(lock) == 9, "Expected nine locked releases")
    actual = set()
    for release in lock:
        ident = release["id"]
        require(isinstance(ident, str) and re.fullmatch(r"app\.rxlab\.extensions\.[a-z0-9-]+", ident), "Invalid locked ID")
        actual.add(ident.removeprefix("app.rxlab.extensions."))
        envelope = folder / (ident + ".sig.json")
        signed = load(envelope)
        require(all(signed.get(k) == release.get(k) for k in ("id", "version", "sha256")),
                f"Envelope differs from the lock for {ident}")
        print(command(args.cli, "verify", "--archive", folder / (ident + ".zip"), "--envelope", envelope,
                      "--keys", args.keys, "--revocations", folder / "revocations.json",
                      "--revocation-signature", folder / "revocations.json.sig",
                      "--revocation-key", args.revocation_key.read_text().strip()).strip())
    require(actual == PROVIDERS, "Locked archives do not cover all nine providers")


def by_id(items):
    records = {x["id"].lower(): x for x in items}
    require(len(records) == len(items), "Duplicate record IDs")
    return records


def selected_metrics(card):
    return card["metricIDs"] if card.get("metricIDs") is not None else [card["metricID"]] if card.get("metricID") else []


def check_dashboard(args):
    old, new = load(args.before), load(args.after)
    require(old["version"] == new["version"], "Dashboard format version changed")
    for key in ("integrations", "cards", "snapshots"):
        before, after = by_id(old[key]), by_id(new[key])
        require(before.keys() == after.keys(), f"{key} IDs changed")
        if key == "integrations":
            require({x["pluginID"] for x in before.values()} == PROVIDERS, "Baseline must exercise all nine providers")
            for uid, item in before.items():
                for field in ("pluginID", "account", "resource", "title", "projectID", "oauth"):
                    require(item.get(field) == after[uid].get(field), f"Integration {uid} changed {field}")
        if key == "cards":
            for uid, card in before.items():
                other = after[uid]
                for field in ("integrationID", "style", "size", "showInWidget", "showInMenuBar", "isVisible"):
                    require(card.get(field) == other.get(field), f"Card {uid} changed {field}")
                require(selected_metrics(card) == selected_metrics(other), f"Card {uid} changed selected metrics")
        if key == "snapshots":
            local_updated = False
            for uid, prior in before.items():
                current = after[uid]
                provider = prior["pluginID"]
                require(current["pluginID"] == provider, f"Snapshot {uid} changed provider")
                before_metrics = {m["id"]: m for m in prior["metrics"]}
                after_metrics = {m["id"]: m for m in current["metrics"]}
                if args.mode == "offline" and provider == "ai-usage":
                    require(before_metrics.keys() <= after_metrics.keys(), "AI usage lost a fixture metric")
                    if current["fetchedAt"] > prior["fetchedAt"] and before_metrics != after_metrics:
                        local_updated = True
                else:
                    require(before_metrics == after_metrics, f"Snapshot metrics changed for {provider}")
                    if args.mode == "offline" and provider != "ai-limits":
                        require(prior["fetchedAt"] == current["fetchedAt"], f"Offline refresh replaced the success time for {provider}")
                    if args.mode == "online":
                        require(not current.get("error"), f"Fixture refresh failed for {provider}")
                        if provider not in {"ai-usage", "ai-limits"}:
                            require(current["fetchedAt"] > prior["fetchedAt"], f"No successful new fixture fetch for {provider}")
                if provider == "acp-antigravity":
                    short = any(i == "5h" or i.endswith("gemini-5h") for i in after_metrics)
                    weekly = any(i == "7d" or i.endswith(("gemini-weekly", "gemini-7d")) for i in after_metrics)
                    require(short and weekly, "Gemini chat footer metrics are missing")
            if args.mode == "offline":
                require(local_updated, "Inject one local usage event and capture the resulting dashboard")
    print(f"Verified {args.mode} dashboard identities, card configuration and fixture metrics.")


def check_install(args):
    envelope = load(args.envelope)
    ident = envelope["id"]
    require(re.fullmatch(r"[a-z0-9-]+(?:\.[a-z0-9-]+)+", ident), "Invalid signed identifier")
    current = args.support / "Extensions" / ident / "current"
    require(load(current / (ident + ".sig.json")) == envelope, "Stored envelope differs from the verified release")
    if args.source:
        require(load(current / "source.json") == args.source, "Installation source differs from the expected channel")
    candidates = list(current.glob("*.app"))
    require(len(candidates) == 1, f"Expected one installed container for {ident}")
    app = candidates[0]
    command("codesign", "--verify", "--all-architectures", "--strict", "--deep", app)
    require("com.apple.quarantine" not in command("xattr", app).splitlines(), "Container has quarantine")
    appexes = list((app / "Contents/Extensions").glob("*.appex"))
    require(len(appexes) == 1, "Expected one active contributor executable")
    appex = appexes[0]
    hashes = []
    for arch in ("arm64", "x86_64"):
        info = command("codesign", "-dvv", "--arch", arch, appex)
        cdhash = re.search(r"^CDHash=([0-9a-f]{40})$", info, re.MULTILINE)
        require(cdhash, f"Missing {arch} code directory hash")
        hashes.append(f"{arch}:{cdhash.group(1)}")
    require(",".join(hashes) == envelope["cdhashes"], "Installed CDHashes differ from the verified envelope")
    container_manifest = (app / "Contents/Resources/RxCodeExtension.json").read_bytes()
    require(container_manifest == (appex / "Contents/Resources/RxCodeExtension.json").read_bytes(), "Installed manifest copies differ")
    manifest = json.loads(container_manifest)
    require((manifest["id"], manifest["version"], manifest["pluginAPI"]) ==
            (ident, envelope["version"], envelope["pluginApi"]), "Installed manifest differs from envelope")
    print(f"Verified on-disk code, manifests and quarantine state for {ident} {manifest['version']}.")


def check_uninstalled(args):
    require(args.id.removeprefix("app.rxlab.extensions.") in PROVIDERS
            and args.id.startswith("app.rxlab.extensions."), "Expected a first-party provider ID")
    require(load(args.support / "extension-install-state.json").get(args.id) == "uninstalled",
            "Missing recorded uninstall decision")
    require(not (args.support / "Extensions" / args.id / "current").exists(), "The provider is installed")
    print(f"Verified persisted uninstall and absence of {args.id}.")


def check_policy(args):
    stored = load(args.support / "extension-revocations.json")
    payload = base64.b64decode(stored["rawPayload"], validate=True)
    with tempfile.TemporaryDirectory() as scratch:
        doc = Path(scratch) / "revocations.json"
        signature = Path(scratch) / "revocations.json.sig"
        doc.write_bytes(payload)
        signature.write_text(stored["signature"])
        print(command(args.cli, "verify-revocation", "--document", doc, "--signature", signature,
                      "--public-key", args.revocation_key.read_text().strip()).strip())
    policy = json.loads(payload)
    require(policy["sequence"] >= args.min_sequence, "Stored sequence is below the last accepted sequence")
    require(args.revoked_key in policy["revokedKeyIds"], "Test key is absent from the accepted revocation policy")
    print(f"Verified persisted revocation of {args.revoked_key} at sequence {policy['sequence']}.")


def check_mobile(args):
    a, b = args.before.read_bytes(), args.after.read_bytes()
    require(a and a == b, "Captured mobile payload differs from the fixture baseline")
    print(f"Byte-identical mobile payload ({len(a)} bytes, SHA-256 {hashlib.sha256(a).hexdigest()}).")


parser = argparse.ArgumentParser(prog="extensions-upgrade-check.sh", description="Read-only checks for individual extension upgrade gate observations.")
modes = parser.add_subparsers(required=True)
host = modes.add_parser("host", help="verify the installed release host, OS and native architecture")
host.add_argument("app", type=Path)
host.add_argument("arch", choices=["arm64", "x86_64"])
host.set_defaults(check=check_host)
bundles = modes.add_parser("bundles", help="verify the nine pinned archives and signed baseline")
for name in ("app", "lock", "keys", "revocation_key", "cli"):
    bundles.add_argument(name, type=Path)
bundles.set_defaults(check=check_bundles)
install = modes.add_parser("installed", help="compare a current installation with a previously verified release envelope")
install.add_argument("support", type=Path)
install.add_argument("envelope", type=Path)
install.add_argument("--source", choices=["bundled", "flowcy"])
install.set_defaults(check=check_install)
uninstalled = modes.add_parser("uninstalled", help="check uninstall persistence after relaunch/refresh")
uninstalled.add_argument("support", type=Path)
uninstalled.add_argument("id")
uninstalled.set_defaults(check=check_uninstalled)
policy = modes.add_parser("policy", help="authenticate the last accepted revocation document after the rotation or rollback attempt")
policy.add_argument("support", type=Path)
policy.add_argument("revoked_key")
policy.add_argument("min_sequence", type=int)
policy.add_argument("revocation_key", type=Path)
policy.add_argument("cli", type=Path)
policy.set_defaults(check=check_policy)
dashboard = modes.add_parser("dashboard", help="compare snapshots captured by the previous and candidate apps on fixture data")
dashboard.add_argument("mode", choices=["offline", "online"])
dashboard.add_argument("before", type=Path)
dashboard.add_argument("after", type=Path)
dashboard.set_defaults(check=check_dashboard)
mobile = modes.add_parser("mobile", help="compare serialized mobile payloads captured at the same fixture state")
mobile.add_argument("before", type=Path)
mobile.add_argument("after", type=Path)
mobile.set_defaults(check=check_mobile)
args = parser.parse_args()
try:
    args.check(args)
except (OSError, ValueError, KeyError, TypeError, subprocess.CalledProcessError) as error:
    sys.exit(f"Check failed: {error}")
PY
