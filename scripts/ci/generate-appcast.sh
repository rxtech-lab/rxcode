#!/bin/bash
set -euo pipefail

: "${SPARKLE_KEY:?SPARKLE_KEY is required}"
: "${VERSION:?VERSION is required}"
: "${BUILD_NUMBER:?BUILD_NUMBER is required}"

RELEASES_URL="https://github.com/rxtech-lab/rxcode/releases"
DOWNLOAD_URL_PREFIX="${RELEASES_URL}/download/${VERSION}/"
EXPECTED_MINIMUM_SYSTEM_VERSION="${EXPECTED_MINIMUM_SYSTEM_VERSION:-15.0}"

# Write SPARKLE_KEY to sparkle.key
echo "$SPARKLE_KEY" > sparkle.key

echo "Generating appcast for version: $VERSION"

# Create a temporary release notes file if release notes exist
if [ -n "${RELEASE_NOTE:-}" ]; then
  echo "$RELEASE_NOTE" > release_notes.md
  # Convert markdown to HTML
  python3 scripts/ci/convert-markdown.py release_notes.md release_notes.html
else
  echo "No release notes provided"
fi

# Generate appcast.xml with optional release notes
./bin/generate_appcast ./ \
  --ed-key-file sparkle.key \
  --link "$RELEASES_URL" \
  --download-url-prefix "$DOWNLOAD_URL_PREFIX"

if grep -Fq "rxtech-lab/Clarc" appcast.xml; then
  echo "Error: generated appcast still points at the old Clarc repository"
  exit 1
fi

if ! grep -Fq "$DOWNLOAD_URL_PREFIX" appcast.xml; then
  echo "Error: generated appcast does not contain the expected RxCode download URL prefix"
  exit 1
fi

if ! grep -Fq "sparkle:edSignature=" appcast.xml; then
  echo "Error: generated appcast is missing sparkle:edSignature"
  exit 1
fi

if ! grep -Fq "<sparkle:minimumSystemVersion>${EXPECTED_MINIMUM_SYSTEM_VERSION}</sparkle:minimumSystemVersion>" appcast.xml; then
  echo "Error: generated appcast does not advertise macOS ${EXPECTED_MINIMUM_SYSTEM_VERSION} as the minimum system version"
  exit 1
fi

if [ -f "release_notes.html" ]; then
  python3 scripts/ci/update-xml.py appcast.xml release_notes.html "$BUILD_NUMBER"
fi

if ! grep -Fq "sparkle:edSignature=" appcast.xml; then
  echo "Error: appcast post-processing removed sparkle:edSignature"
  exit 1
fi

if ! grep -Fq "<sparkle:minimumSystemVersion>${EXPECTED_MINIMUM_SYSTEM_VERSION}</sparkle:minimumSystemVersion>" appcast.xml; then
  echo "Error: appcast post-processing changed the minimum system version"
  exit 1
fi
