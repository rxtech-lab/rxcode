#!/usr/bin/env python3
"""Prepare signed offline seeds or publish universal provider archives from protected CI."""
import argparse
import base64
import json
import os
import re
import shutil
import subprocess
import tempfile
import uuid
from pathlib import Path
from urllib.parse import urlparse
from urllib.request import Request, urlopen

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "Extensions"
TRUST = ROOT / "Packages/Sources/RxCodeExtensionDistribution/Resources/production-trust.json"
PROVIDERS = {"github-ci", "neon", "turso", "vercel", "cloudflare", "ai-usage", "ai-limits",
             "acp-opencode", "acp-antigravity"}
API = "https://www.flowcy.dev/api/v1"
LIMIT = 50 * 1024 * 1024


def require(condition, message):
    if not condition:
        raise ValueError(message)


def write(path, value):
    path.write_text(json.dumps(value, sort_keys=True, indent=2) + "\n")


def read(path):
    return json.loads(path.read_bytes())


def run(*args, env=None):
    return subprocess.check_output(list(map(str, args)), env=env)


def trust():
    pins = read(TRUST)
    require(pins.get("appleSigning") in ("adHoc", "developerID"), "Record the verified Apple signing mode first")
    keys = pins["keys"]
    vectors = read(SOURCE / "TestVectors/verification.json")
    require(len(keys) == 2 and set(keys) == {pins["active"], pins["backup"]}, "Pin the active and unused backup keys first")
    require(set(keys).isdisjoint(vectors["keys"]), "Debug key IDs are reserved")
    public = [*keys.values(), pins["revocationKey"]]
    require(all(len(base64.b64decode(k, validate=True)) == 32 for k in public) and len(set(public)) == 3,
            "Three distinct Ed25519 public keys are required")
    require(set(public).isdisjoint([*vectors["keys"].values(), vectors["revocationKey"]]), "Debug keys cannot sign releases")
    return pins


def check_https(url):
    item = urlparse(url)
    require(item.scheme == "https" and item.hostname and not item.username and not item.password, "Expected HTTPS")
    return url


def fetch(url, limit=1024 * 1024):
    with urlopen(check_https(url), timeout=30) as response:
        check_https(response.geturl())
        data = response.read(limit + 1)
        require(len(data) <= limit, "Download exceeds the size limit")
        return data, response.headers


def release_id(provider):
    return "app.rxlab.extensions." + provider


def verify(cli, folder, ident, keyfile, revocation_key):
    run(cli, "verify", "--archive", folder / (ident + ".zip"), "--envelope", folder / (ident + ".sig.json"),
        "--keys", keyfile, "--revocations", folder / "revocations.json", "--revocation-signature",
        folder / "revocations.json.sig", "--revocation-key", revocation_key)


def package(cli, provider, workspace, archive, signer):
    workspace.mkdir(parents=True)
    bundle = workspace / "Contributor.app"
    run(cli, "build", SOURCE / provider, "--output", bundle, "--sign", signer)
    if signer != "-":
        require("T7GYB573Y6" in signer, "Unexpected Developer ID team")
        pre_staple = workspace / "submit.zip"
        run("ditto", "-c", "-k", "--keepParent", bundle, pre_staple)
        run("xcrun", "notarytool", "submit", pre_staple, "--keychain-profile", "rxcode-extension-notary", "--wait")
        run("xcrun", "stapler", "staple", bundle)
        run("xcrun", "stapler", "validate", bundle)
    return json.loads(run(cli, "package", bundle, "--output", archive))


def debug(cli, folder, scratch, keys):
    vectors = read(SOURCE / "TestVectors/verification.json")
    write(keys, vectors["keys"])
    policy = folder / "revocations.json"
    write(policy, {"format": "rxcode-revocations-v1", "sequence": 1, "issuedAt": "2026-01-01T00:00:00Z",
                   "revokedKeyIds": [], "revokedReleases": []})
    # Fixed private seeds accompany the publicly reproducible Debug test vectors only.
    debug_env = dict(os.environ, DEBUG_EXTENSION_KEY=base64.b64encode(bytes([1]) * 32).decode(),
                     DEBUG_REVOCATION_KEY=base64.b64encode(bytes([3]) * 32).decode())
    run(cli, "sign-revocation", "--document", policy, "--key-env", "DEBUG_REVOCATION_KEY",
        "--output", folder / "revocations.json.sig", env=debug_env)
    pins = []
    for provider in sorted(PROVIDERS):
        ident = release_id(provider)
        archive = folder / (ident + ".zip")
        metadata = package(cli, provider, scratch / provider, archive, "-")
        require(metadata["id"] == ident, "Unexpected provider ID")
        meta = scratch / provider / "metadata.json"
        write(meta, metadata)
        run(cli, "sign", "--metadata", meta, "--key-env", "DEBUG_EXTENSION_KEY", "--key-id", "test-active",
            "--output", folder / (ident + ".sig.json"), env=debug_env)
        verify(cli, folder, ident, keys, vectors["revocationKey"])
        pins.append({field: metadata[field] for field in ("id", "version", "sha256")})
        print("Verified Debug archive for " + provider, flush=True)
    write(folder / "bundled.lock.json", pins)


def probe(cli, folder, keyfile, source):
    pins = trust()
    write(keyfile, pins["keys"])
    ident = release_id("discovery-probe")
    require(source and source.is_dir(), "The Release gate candidate needs signed probe resources")
    for name in ("revocations.json", "revocations.json.sig", ident + ".zip", ident + ".sig.json"):
        shutil.copyfile(source / name, folder / name)
    envelope = read(folder / (ident + ".sig.json"))
    require(envelope["id"] == ident and envelope["pluginApi"] == "2.0", "Unexpected probe envelope")
    verify(cli, folder, ident, keyfile, pins["revocationKey"])


def bundle(cli, folder, keys):
    pins = trust()
    write(keys, pins["keys"])
    lock = read(SOURCE / "bundled.lock.json")
    require(len(lock) == 9 and {p["id"] for p in lock} == {release_id(p) for p in PROVIDERS}, "Expected nine release pins")
    policy, headers = fetch(API + "/extensions/revocations")
    (folder / "revocations.json").write_bytes(policy)
    signature = headers.get("X-RxCode-Signature")
    require(signature, "Missing revocation signature")
    (folder / "revocations.json.sig").write_text(signature)
    run(cli, "verify-revocation", "--document", folder / "revocations.json", "--signature", folder / "revocations.json.sig",
        "--public-key", pins["revocationKey"])
    for pin in lock:
        ident, version = pin["id"], pin["version"]
        require(re.fullmatch(r"(?:0|[1-9][0-9]*)(?:\.(?:0|[1-9][0-9]*))*(?:-[0-9A-Za-z]+(?:[.-][0-9A-Za-z]+)*)?(?:\+[0-9A-Za-z]+(?:[.-][0-9A-Za-z]+)*)?", version), "Invalid pinned version")
        url = API + "/extensions/" + ident + "/releases/" + version
        meta = json.loads(fetch(url)[0])
        require(all(meta[k] == pin[k] for k in ("id", "version", "sha256")) and meta["pluginApi"] == "2.0",
                "Pinned metadata mismatch")
        envelope = {k: meta[k] for k in ("id", "version", "pluginApi", "sha256", "cdhashes", "signature", "keyId")}
        envelope["format"] = meta["signatureFormat"]
        write(folder / (ident + ".sig.json"), envelope)
        data, _ = fetch(url + "/download", LIMIT)
        require(len(data) == meta["size"], "Archive length mismatch")
        (folder / (ident + ".zip")).write_bytes(data)
        verify(cli, folder, ident, keys, pins["revocationKey"])
    shutil.copyfile(SOURCE / "bundled.lock.json", folder / "bundled.lock.json")


def publish(cli, scratch, keyfile, providers, signer, probe_artifacts=None, probe_version=None):
    if probe_artifacts is not None:
        require(providers == {"discovery-probe"}, "The gate workflow publishes only the discovery probe")
        require(os.environ.get("GITHUB_EVENT_NAME") == "workflow_dispatch", "Probe publication requires manual dispatch")
        require(re.fullmatch(r"(?:0|[1-9][0-9]{0,8})(?:\.(?:0|[1-9][0-9]{0,8})){2}", probe_version or ""),
                "Specify a three-component numeric probe version without leading zeros")
    pins = trust()
    require((signer == "-") == (pins["appleSigning"] == "adHoc"), "Signer differs from the pinned Apple signing mode")
    require(os.environ["RXCODE_EXTENSION_KEY_ID"] == pins["active"], "CI must use the pinned active key")
    require(os.environ.get("GITHUB_REF") == "refs/heads/main", "Publishing requires main")
    token = os.environ["FLOWCY_EXTENSIONS_TOKEN"]
    write(keyfile, pins["keys"])
    def post(path, body):
        # Do not follow redirects carrying a publisher token.
        import http.client
        connection = http.client.HTTPSConnection("www.flowcy.dev", timeout=60)
        try:
            connection.request("POST", "/api/v1/admin/extensions/releases" + path, json.dumps(body),
                               {"Authorization": "Bearer " + token, "Content-Type": "application/json"})
            response = connection.getresponse()
            require(response.status in (200, 201), f"Flowcy returned HTTP {response.status} for {path or 'create'}")
            return json.loads(response.read(1024 * 1024))
        finally:
            connection.close()
    for provider in sorted(providers):
        dest = scratch / provider
        if probe_artifacts is None:
            archive = scratch / (provider + ".zip")
            meta = package(cli, provider, dest, archive, signer)
        else:
            dest.mkdir()
            archive = probe_artifacts / "probe.zip"
            meta = read(probe_artifacts / "metadata.json")
            require(meta["version"] == probe_version and meta["pluginApi"] == "2.0", "Unexpected gate probe release")
        require(meta["id"] == release_id(provider), "Unexpected provider ID")
        metadata = dest / "metadata.json"
        envelope = dest / "signature.json"
        write(metadata, meta)
        run(cli, "sign", "--metadata", metadata, "--key-env", "RXCODE_EXTENSION_PRIVATE_KEY", "--key-id", pins["active"],
            "--output", envelope)
        run(cli, "verify", "--archive", archive, "--envelope", envelope, "--keys", keyfile)
        pending = post("", {**meta, **read(envelope)})
        if pending.get("alreadyPublished"):
            print(provider + " already published with the same source digest")
            continue
        headers = pending["headers"]
        require(headers == {"Content-Type": "application/zip", "Content-Length": str(meta["size"])}, "Invalid PUT headers")
        upload = Request(check_https(pending["uploadUrl"]), method="PUT", data=archive.read_bytes(), headers=headers)
        with urlopen(upload, timeout=60) as response:
            require(200 <= response.status < 300, "Archive upload failed")
        release = str(uuid.UUID(pending["releaseId"]))
        post("/" + release + "/confirm", {})
        print("Published " + provider)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("mode", choices=["debug", "bundle", "publish", "probe", "publish-probe"])
    parser.add_argument("--cli", required=True, type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--probe-resources", type=Path)
    parser.add_argument("--probe-artifacts", type=Path, help="Directory produced by build-probe.sh package")
    parser.add_argument("--probe-version", help="Exact version to publish in the manual gate workflow")
    parser.add_argument("--provider", choices=sorted(PROVIDERS), action="append")
    parser.add_argument("--since", help="Publish providers affected since this Git commit")
    parser.add_argument("--sign", default="-")
    args = parser.parse_args()
    cli = args.cli.resolve(strict=True)
    with tempfile.TemporaryDirectory() as temp:
        scratch = Path(temp)
        keys = scratch / "keys.json"
        if args.mode == "publish-probe":
            require(args.probe_artifacts and args.probe_version and not (args.since or args.provider or args.output or args.probe_resources),
                    "Pass --probe-artifacts and --probe-version for the fixed discovery probe")
            publish(cli, scratch, keys, {"discovery-probe"}, args.sign, args.probe_artifacts, args.probe_version)
            return
        require(args.probe_artifacts is None and args.probe_version is None, "Probe publish options require publish-probe")
        if args.mode == "publish":
            selected = set(args.provider or PROVIDERS)
            if args.since and args.since != "0" * 40:
                require(re.fullmatch(r"[0-9a-f]{40}", args.since), "Invalid base commit")
                files = run("git", "diff", "--name-only", args.since, "HEAD", "--").decode().splitlines()
                if not any(f.startswith("Packages/Sources/RxCodeExtensionSDK/") for f in files):
                    selected = {p for p in selected if any(f.startswith(f"Extensions/{p}/") for f in files)}
            if selected:
                publish(cli, scratch, keys, selected, args.sign)
            return
        require(args.output, "--output is required")
        output = args.output.resolve()
        require(output.name == "BundledExtensions", "Choose a BundledExtensions output directory")
        output.parent.mkdir(parents=True, exist_ok=True)
        # A cancelled Xcode build must never leave partial archives inside the sealed app.
        app = next((parent for parent in output.parents if parent.suffix == ".app"), None)
        staging_parent = app.parent if app else output.parent
        with tempfile.TemporaryDirectory(prefix=".rxcode-extension-bundle-", dir=staging_parent) as stage:
            folder = Path(stage) / "BundledExtensions"
            folder.mkdir()
            if args.mode == "debug":
                debug(cli, folder, scratch, keys)
            elif args.mode == "probe":
                probe(cli, folder, keys, args.probe_resources)
            else:
                bundle(cli, folder, keys)
            # The app only sees completed, verified generations.
            previous = Path(stage) / "previous"
            if output.exists():
                output.rename(previous)
            try:
                folder.rename(output)
            except OSError:
                if previous.exists():
                    previous.rename(output)
                raise


if __name__ == "__main__":
    main()
