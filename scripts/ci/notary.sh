#!/bin/bash
set -e

APP_NAME="./output/output.xcarchive/Products/Applications/RxCode.app"
DMG_NAME="RxCode.dmg"

# Remove existing DMG if it exists
if [ -f "$DMG_NAME" ]; then
  echo "Removing existing DMG file"
  rm "$DMG_NAME"
fi

# Create DMG. create-dmg exits non-zero when DMG signing fails (e.g. Apple's
# timestamp service is temporarily unavailable) even though the DMG was
# created, so retry a few times and fall back to the unsigned DMG.
for attempt in 1 2 3; do
  if create-dmg --overwrite "$APP_NAME"; then
    break
  fi
  echo "create-dmg failed (attempt $attempt)"
  if [ "$attempt" -lt 3 ]; then
    sleep 15
  fi
done

shopt -s nullglob
dmgs=(*.dmg)
shopt -u nullglob
if [ ${#dmgs[@]} -eq 0 ]; then
  echo "No DMG was created"
  exit 1
fi
mv "${dmgs[0]}" "$DMG_NAME"

echo "DMG created: $DMG_NAME"

# Notarize the app
xcrun notarytool submit ./$DMG_NAME --verbose --apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "$APPLE_ID_PWD" --wait

# Staple the ticket
xcrun stapler staple $DMG_NAME

echo "All operations completed successfully!"
