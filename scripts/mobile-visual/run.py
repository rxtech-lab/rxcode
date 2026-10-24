#!/usr/bin/env python3
"""Capture candidates, explicitly approve reviewed images, or compare approved UI."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import shutil
import struct
import subprocess
import traceback
from report import finish_report

ROOT = Path(__file__).resolve().parents[2]
BASELINES = ROOT / "visual-baselines/mobile"
SCREENS = ("settings", "integrations", "account")
DEFAULT_DEVICES = {
    "iphone": "429C3782-3AA3-40F1-A481-BF761AE8E71B",
    "ipad": "83B675D5-CA1E-4F94-8292-7E147268E725",
    "iphone-duo": "DEBEB7E2-0F2C-4568-858E-FCBF76613586",
}


def run(*args, **kwargs):
    return subprocess.run([str(a) for a in args], check=True, **kwargs)


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def read_json(path):
    return json.loads(path.read_text())


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2) + "\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=["capture", "compare", "approve", "report"])
    parser.add_argument("--output", type=Path, required=True, help="Candidate directory (must be new for capture/compare)")
    parser.add_argument("--profile", choices=DEFAULT_DEVICES, action="append")
    parser.add_argument("--device", action="append", default=[], help="Override profile=simulator-UUID")
    parser.add_argument("--reviewer", help="Name of the user who explicitly approved these screenshots")
    parser.add_argument("--failed", action="store_true", help="Package an existing failed run (report mode)")
    options = parser.parse_args()
    profiles = options.profile or list(DEFAULT_DEVICES)
    output = options.output.resolve()
    if options.mode == "approve":
        if not options.reviewer:
            parser.error("Approval requires --reviewer after the user has reviewed every image.")
        # Validate every candidate before updating any approved profile.
        for profile in profiles:
            candidate = output / profile
            manifest = read_json(candidate / "capture.json")
            for screen in SCREENS:
                if digest(candidate / f"{screen}.png") != manifest["sha256"][screen]:
                    raise RuntimeError(f"Candidate changed since capture: {profile}/{screen}")
        for profile in profiles:
            candidate = output / profile
            approved = BASELINES / profile
            approved.mkdir(parents=True, exist_ok=True)
            manifest = read_json(candidate / "capture.json")
            for screen in SCREENS:
                shutil.copy2(candidate / f"{screen}.png", approved / f"{screen}.png")
            manifest["approval"] = {"reviewer": options.reviewer, "at": datetime.now(timezone.utc).isoformat()}
            write_json(approved / "approved.json", manifest)
        return

    if options.mode == "report":
        result = read_json(output / "result.json") if (output / "result.json").exists() else {}
        finish_report(output, profiles, BASELINES, "failed" if options.failed else result.get("status", "captured"),
                      result.get("errors", ["CI failed before screenshot results were recorded."] if options.failed else []))
        return
    # Create diagnostics even when approval/environment validation fails before XCTest.
    output.mkdir(parents=True, exist_ok=False)
    try:
        execute(options, profiles, output)
    except Exception as error:
        (output / "error.txt").write_text(traceback.format_exc())
        finish_report(output, profiles, BASELINES, "failed", [str(error)])
        raise
    finish_report(output, profiles, BASELINES, "passed" if options.mode == "compare" else "captured")
    print(f"{options.mode} completed for {', '.join(profiles)}: {output}")


def execute(options, profiles, output):
    devices = dict(DEFAULT_DEVICES)
    for override in options.device:
        profile, device = override.split("=", 1)
        if profile not in DEFAULT_DEVICES:
            raise ValueError(f"Unknown profile: {profile}")
        devices[profile] = device
    if options.mode == "compare":
        for profile in profiles:
            approval_path = BASELINES / profile / "approved.json"
            if not approval_path.exists():
                raise RuntimeError(f"No approved baseline for {profile}. Capture screenshots and obtain user review first.")
            manifest = read_json(approval_path)
            if not manifest.get("approval", {}).get("reviewer"):
                raise RuntimeError(f"No user approval: {profile}")
            for screen in SCREENS:
                if digest(BASELINES / profile / f"{screen}.png") != manifest["sha256"][screen]:
                    raise RuntimeError(f"Approved baseline modified: {profile}/{screen}")
    comparator = output / "compare"
    if options.mode == "compare":
        run("xcrun", "swiftc", ROOT / "scripts/mobile-visual/compare.swift", "-o", comparator)
    inventory = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devices", "available", "--json"]))
    failed = []
    for profile in profiles:
        device_id = devices[profile]
        available = [(runtime, device) for runtime, items in inventory["devices"].items() for device in items]
        matches = [(runtime, device) for runtime, device in available if device["udid"] == device_id]
        # Runner UUIDs differ across machines; use the exact reviewed model/runtime.
        if not matches and device_id == DEFAULT_DEVICES[profile]:
            pinned = read_json(BASELINES / profile / "approved.json")["environment"]
            matches = [(runtime, device) for runtime, device in available
                       if runtime == pinned["runtime"] and device["deviceTypeIdentifier"] == pinned["deviceType"]]
        if not matches:
            raise RuntimeError(f"No matching simulator for {profile}; install its reviewed model/runtime or pass --device.")
        runtime, device = matches[0]
        device_id = device["udid"]
        device_type = device["deviceTypeIdentifier"].split(".")[-1]
        valid_profile = {
            "iphone": device_type.startswith("iPhone-") and "Duo" not in device_type,
            "ipad": device_type.startswith("iPad-"),
            "iphone-duo": device_type == "iPhone-Duo",
        }
        if not valid_profile[profile]:
            raise RuntimeError(f"Wrong device type for {profile}: {device_type}")
        metadata = {"deviceType": device["deviceTypeIdentifier"], "runtime": runtime,
                    "xcode": subprocess.check_output(["xcodebuild", "-version"], text=True).strip()}
        if options.mode == "compare" and metadata != read_json(BASELINES / profile / "approved.json")["environment"]:
            raise RuntimeError(f"Pinned environment changed for {profile}; capture and review new candidates.")
        folder = output / profile
        folder.mkdir()
        if device["state"] != "Booted":
            run("xcrun", "simctl", "boot", device_id)
        run("xcrun", "simctl", "bootstatus", device_id, "-b")
        test_error = None
        try:
            run("xcrun", "simctl", "status_bar", device_id, "override", "--time", "2026-01-01T01:41:00.000Z",
                "--dataNetwork", "wifi", "--wifiMode", "active", "--wifiBars", "3",
                "--cellularMode", "active", "--cellularBars", "4",
                "--batteryState", "charged", "--batteryLevel", "100")
            with (folder / "xcodebuild.log").open("w") as log:
                run("xcodebuild", "test", "-project", ROOT / "RxCode.xcodeproj", "-scheme", "RxCodeMobile",
                    "-testPlan", "MobileVisualRegression", "-destination", f"platform=iOS Simulator,id={device_id}",
                    "-parallel-testing-enabled", "NO", "-derivedDataPath", ROOT / "build/mobile-visual",
                    "-resultBundlePath", folder / "result.xcresult", stdout=log, stderr=subprocess.STDOUT, cwd=ROOT)
        except subprocess.CalledProcessError as error:
            test_error = error
        finally:
            run("xcrun", "simctl", "status_bar", device_id, "clear")
        if test_error is not None and not (folder / "result.xcresult").exists():
            raise test_error
        exported = folder / "attachments"
        run("xcrun", "xcresulttool", "export", "attachments", "--path", folder / "result.xcresult", "--output-path", exported)
        attachments = [a for test in read_json(exported / "manifest.json") for a in test["attachments"]]
        for screen in SCREENS:
            matches = [a for a in attachments if a["suggestedHumanReadableName"].startswith(f"visual-{screen}")]
            if len(matches) != 1:
                if test_error is not None:
                    continue
                raise RuntimeError(f"Expected one {profile}/{screen} screenshot, found {len(matches)}")
            shutil.copy2(exported / matches[0]["exportedFileName"], folder / f"{screen}.png")
            width, height = struct.unpack(">II", (folder / f"{screen}.png").read_bytes()[16:24])
            if (width > height) != (profile != "iphone"):
                raise RuntimeError(f"Wrong screenshot orientation for {profile}/{screen}: {width}x{height}")
        if test_error is not None:
            raise test_error
        write_json(folder / "capture.json", {"environment": metadata, "sha256": {
            screen: digest(folder / f"{screen}.png") for screen in SCREENS}})
        if options.mode == "compare":
            comparisons = {}
            for screen in SCREENS:
                result = subprocess.run([str(comparator), str(BASELINES / profile / f"{screen}.png"),
                                         str(folder / f"{screen}.png"), str(folder / f"{screen}-diff.png")],
                                        capture_output=True, text=True)
                comparisons[screen] = {"passed": result.returncode == 0, "output": result.stdout + result.stderr}
                print(f"{profile}/{screen}: {result.stdout.strip()}")
                if result.returncode:
                    failed.append(f"{profile}/{screen}")
            write_json(folder / "comparisons.json", comparisons)
    if failed:
        raise RuntimeError("Visual regressions: " + ", ".join(failed))


if __name__ == "__main__":
    main()
