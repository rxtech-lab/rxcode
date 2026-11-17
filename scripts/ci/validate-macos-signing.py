#!/usr/bin/env python3
"""Validate the installed profile and identity before starting a release build."""

import datetime
import hashlib
import os
import plistlib
import subprocess
import sys

TEAM = "T7GYB573Y6"
BUNDLE_ID = "app.rxlab.flowcy.code"


def validate(profile_path):
    with open(profile_path, "rb") as stream:
        profile = plistlib.load(stream)
    entitlements = profile.get("Entitlements", {})
    checks = {
        "profile team": profile.get("TeamIdentifier") == [TEAM],
        "profile name": profile.get("Name") == "RxCode Developer ID",
        "application identifier": entitlements.get("com.apple.application-identifier") == f"{TEAM}.{BUNDLE_ID}",
        "associated domains": "com.apple.developer.associated-domains" in entitlements,
        "profile expiration": profile.get("ExpirationDate", datetime.datetime.min) > datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None),
        "notarization team": os.environ.get("APPLE_TEAM_ID") == TEAM,
        "signing identity": os.environ.get("SIGNING_CERTIFICATE_NAME") == f"Developer ID Application: Rxlab LIMITED ({TEAM})",
    }
    identities = subprocess.check_output(["security", "find-identity", "-v", "-p", "codesigning"], text=True)
    checks["installed certificate matches profile"] = any(
        hashlib.sha1(certificate).hexdigest().upper() in identities
        for certificate in profile.get("DeveloperCertificates", [])
    )
    failed = [label for label, valid in checks.items() if not valid]
    if failed:
        raise ValueError("Signing configuration mismatch: " + ", ".join(failed))
    print(f"Validated Developer ID signing for {TEAM}.{BUNDLE_ID}")


if __name__ == "__main__":
    try:
        validate(sys.argv[1])
    except (ValueError, OSError, IndexError, subprocess.CalledProcessError) as error:
        sys.exit(str(error))
