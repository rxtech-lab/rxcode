#!/bin/bash

# Xcode Cloud post-clone hook for RxCodeMobile
# - Stamps the app version from the git tag (CI_TAG -> MARKETING_VERSION)
# - Sets the build number from CI_BUILD_NUMBER (CURRENT_PROJECT_VERSION)
#
# Xcode Cloud runs this script automatically right after cloning the repo.
# Configure the Xcode Cloud workflow to start a build on new tag creation;
# CI_TAG and CI_BUILD_NUMBER are then provided by Xcode Cloud.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECT_DIR="$REPO_ROOT"
PROJECT_FILE="$REPO_ROOT/RxCode.xcodeproj/project.pbxproj"

echo "== Xcode Cloud: ci_post_clone =="
echo "Repo root: $REPO_ROOT"

# Xcode plugin/macro validation often blocks CI for SPM dependency plugins.
defaults write com.apple.dt.Xcode IDESkipPackagePluginFingerprintValidatation -bool YES || true
defaults write com.apple.dt.Xcode IDESkipMacroFingerprintValidation -bool YES || true

# Materialize Firebase config files from Xcode Cloud env secrets.
# FIREBASE_MACOS_B64 / FIREBASE_IOS_B64 must be defined as workflow secrets.
"$REPO_ROOT/scripts/ci/write-firebase-config.sh"

if [[ -n "${CI_TAG:-}" ]]; then
  VERSION="${CI_TAG#v}"
  if [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-.][A-Za-z0-9.]+)?$ ]]; then
    echo "Stamping MARKETING_VERSION from CI_TAG: $CI_TAG -> $VERSION"
    sed -i '' "s/MARKETING_VERSION = [^;]*;/MARKETING_VERSION = $VERSION;/g" "$PROJECT_FILE"

    if [[ -n "${CI_BUILD_NUMBER:-}" ]]; then
      echo "Stamping CURRENT_PROJECT_VERSION from CI_BUILD_NUMBER: $CI_BUILD_NUMBER"
      (
        cd "$PROJECT_DIR"
        xcrun agvtool new-version -all "$CI_BUILD_NUMBER"
      )
    else
      echo "CI_BUILD_NUMBER not set; skipping CURRENT_PROJECT_VERSION update"
    fi
  else
    echo "CI_TAG '$CI_TAG' is not a semver tag; skipping version stamping"
  fi
else
  echo "CI_TAG not set; skipping version stamping"
fi

echo "ci_post_clone completed"
