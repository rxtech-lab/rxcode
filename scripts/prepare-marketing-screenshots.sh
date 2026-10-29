#!/bin/zsh
# Build a separately identified debug app that only loads fictional marketing data.
set -euo pipefail
cd "${0:A:h:h}"
BUILD_DIR="${TMPDIR:-/tmp}/RxCodeMarketingBuild"
CAPTURE_APP="${TMPDIR:-/tmp}/RxCode-Screenshots.app"
xcodebuild -project RxCode.xcodeproj -scheme RxCode -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath "$BUILD_DIR" build
/usr/bin/ditto "$BUILD_DIR/Build/Products/Debug/RxCode.app" "$CAPTURE_APP"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier com.rxlab.RxCode.screenshots' "$CAPTURE_APP/Contents/Info.plist"
/usr/bin/codesign --force --deep --sign - "$CAPTURE_APP"
printf 'Capture app prepared at %s\nOpen this copy to capture fictional data; leave the regular RxCode app running.\n' "$CAPTURE_APP"
