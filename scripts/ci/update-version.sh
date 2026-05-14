#!/bin/bash
set -e

VERSION="$1"

if [ -z "$VERSION" ]; then
  echo "Usage: $0 <version>"
  echo "Example: $0 1.2.3"
  exit 1
fi

PROJECT_FILE="RxCode.xcodeproj/project.pbxproj"

if [ ! -f "$PROJECT_FILE" ]; then
  echo "Error: $PROJECT_FILE not found"
  exit 1
fi

echo "Updating MARKETING_VERSION to $VERSION in $PROJECT_FILE"

# Create a temporary file
TMP_FILE=$(mktemp)

# Use awk to update only the RxCode main target (matched by PRODUCT_BUNDLE_IDENTIFIER)
awk -v new_version="$VERSION" '
/MARKETING_VERSION = / {
    # Store the current line
    marketing_line = $0
    # Read the next line
    getline
    # Check if this is the main app target (not Tests or UITests)
    if ($0 ~ /PRODUCT_BUNDLE_IDENTIFIER = com\.idealapp\.RxCode;$/) {
        # Update MARKETING_VERSION
        gsub(/MARKETING_VERSION = [^;]+;/, "MARKETING_VERSION = " new_version ";", marketing_line)
        print marketing_line
        print
    } else {
        # Keep both lines unchanged
        print marketing_line
        print
    }
    next
}
{ print }
' "$PROJECT_FILE" > "$TMP_FILE"

# Replace the original file
mv "$TMP_FILE" "$PROJECT_FILE"

echo "Successfully updated MARKETING_VERSION to $VERSION"
