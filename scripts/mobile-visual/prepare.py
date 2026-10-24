#!/usr/bin/env python3
"""Create missing simulator devices using the approved screenshot environment."""
import argparse
import json
import subprocess

from run import BASELINES, DEFAULT_DEVICES, read_json


def prepare(profiles):
    xcode = subprocess.check_output(["xcodebuild", "-version"], text=True).strip()
    inventory = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "--json"]))
    for profile in profiles:
        environment = read_json(BASELINES / profile / "approved.json")["environment"]
        if xcode != environment["xcode"]:
            raise RuntimeError(f"Install the approved Xcode for {profile}: {environment['xcode']}")
        runtime = environment["runtime"]
        if not any(item["identifier"] == runtime and item.get("isAvailable", False)
                   for item in inventory["runtimes"]):
            raise RuntimeError(f"Install the approved simulator runtime for {profile}: {runtime}")
        model = environment["deviceType"]
        if not any(item["identifier"] == model for item in inventory["devicetypes"]):
            raise RuntimeError(f"The selected Xcode does not provide the approved device model: {model}")
        if not any(device.get("isAvailable", False) and device["deviceTypeIdentifier"] == model
                   for device in inventory["devices"].get(runtime, [])):
            subprocess.run(["xcrun", "simctl", "create", f"RxCode Visual {profile}", model, runtime], check=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--profile", choices=DEFAULT_DEVICES, action="append", required=True)
    prepare(parser.parse_args().profile)
