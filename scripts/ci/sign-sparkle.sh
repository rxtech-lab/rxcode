#!/bin/bash
set -e

APP_PATH="output/output.xcarchive/Products/Applications/RxCode.app"

if [ -z "${SIGNING_CERTIFICATE_NAME}" ]; then
  echo "Error: SIGNING_CERTIFICATE_NAME is not set"
  exit 1
fi

# --timestamp makes codesign contact Apple's secure timestamp service, which
# intermittently answers "The timestamp service is not available." Dropping
# --timestamp is not an option (notarization requires a secure timestamp), so
# retry instead.
retry_codesign() {
  local attempt
  for attempt in 1 2 3; do
    if codesign "$@"; then
      return 0
    fi
    if [ "$attempt" -lt 3 ]; then
      echo "codesign attempt ${attempt}/3 failed; retrying in 15s"
      sleep 15
    fi
  done
  echo "Error: codesign failed after 3 attempts: $*"
  return 1
}

# Sign the main Sparkle framework binary first
retry_codesign --force --options runtime --timestamp --sign "${SIGNING_CERTIFICATE_NAME}" "$APP_PATH/Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle"

# Sign Sparkle components
retry_codesign --force --options runtime --timestamp --sign "${SIGNING_CERTIFICATE_NAME}" "$APP_PATH/Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app"
retry_codesign --force --options runtime --timestamp --sign "${SIGNING_CERTIFICATE_NAME}" "$APP_PATH/Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate"
retry_codesign --force --options runtime --timestamp --sign "${SIGNING_CERTIFICATE_NAME}" "$APP_PATH/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Downloader.xpc"
retry_codesign --force --options runtime --timestamp --sign "${SIGNING_CERTIFICATE_NAME}" "$APP_PATH/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Installer.xpc"

# Sign the Sparkle framework as a whole
retry_codesign --force --options runtime --timestamp --sign "${SIGNING_CERTIFICATE_NAME}" "$APP_PATH/Contents/Frameworks/Sparkle.framework"

# Capture the entitlements xcodebuild embedded in the archive BEFORE re-signing
# the main app. `codesign --force` without --entitlements drops them, which
# strips com.apple.developer.associated-domains and breaks passkeys/webcredentials
# (app reported as "not associated with domain rxlab.app"). We re-apply the exact
# archived entitlements (which also carry the profile-injected application-identifier
# and team-identifier) so the resealed binary keeps them.
ENTITLEMENTS_PLIST="${RUNNER_TEMP:-/tmp}/RxCode-app.entitlements.plist"
codesign -d --entitlements "$ENTITLEMENTS_PLIST" --xml "$APP_PATH" 2>/dev/null

if [ ! -s "$ENTITLEMENTS_PLIST" ]; then
  echo "Error: failed to extract entitlements from archived app; aborting to avoid shipping an app without associated-domains"
  exit 1
fi

echo "Preserving archived entitlements:"
/usr/bin/plutil -p "$ENTITLEMENTS_PLIST" || true

# Re-sign the main app binary, re-applying the archived entitlements
retry_codesign --force --options runtime --timestamp --entitlements "$ENTITLEMENTS_PLIST" --sign "${SIGNING_CERTIFICATE_NAME}" "$APP_PATH/Contents/MacOS/RxCode"

# Re-sign the main app to ensure everything is properly signed, keeping entitlements
retry_codesign --force --options runtime --timestamp --entitlements "$ENTITLEMENTS_PLIST" --sign "${SIGNING_CERTIFICATE_NAME}" "$APP_PATH"

# Verify the resealed app still declares associated-domains
if ! codesign -d --entitlements - --xml "$APP_PATH" 2>/dev/null | grep -q "com.apple.developer.associated-domains"; then
  echo "Error: associated-domains entitlement missing after re-signing"
  exit 1
fi

echo "Signing completed successfully"
