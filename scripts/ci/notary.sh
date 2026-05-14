#!/bin/bash
set -e

APP_NAME="./output/output.xcarchive/Products/Applications/RxCode.app"
DMG_NAME="RxCode.dmg"

# Remove existing DMG if it exists
if [ -f "$DMG_NAME" ]; then
  echo "Removing existing DMG file"
  rm "$DMG_NAME"
fi

# Create DMG
create-dmg --overwrite "$APP_NAME" && mv *.dmg "$DMG_NAME"

echo "DMG created: $DMG_NAME"

# Notarize the app
xcrun notarytool submit ./$DMG_NAME --verbose --apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "$APPLE_ID_PWD" --wait

# Staple the ticket
xcrun stapler staple $DMG_NAME

echo "All operations completed successfully!"
