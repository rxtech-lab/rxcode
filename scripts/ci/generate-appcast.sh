#!/bin/bash
set -e

# Write SPARKLE_KEY to sparkle.key
echo "$SPARKLE_KEY" > sparkle.key

echo "Generating appcast for version: $VERSION"

# Create a temporary release notes file if release notes exist
if [ -n "$RELEASE_NOTE" ]; then
  echo "$RELEASE_NOTE" > release_notes.md
  # Convert markdown to HTML
  python3 scripts/ci/convert-markdown.py release_notes.md release_notes.html
else
  echo "No release notes provided"
fi

# Generate appcast.xml with optional release notes
./bin/generate_appcast ./ \
  --ed-key-file sparkle.key \
  --link https://github.com/rxtech-lab/Clarc/releases \
  --download-url-prefix https://github.com/rxtech-lab/Clarc/releases/download/${VERSION}/

if [ -f "release_notes.html" ]; then
  python3 scripts/ci/update-xml.py appcast.xml release_notes.html ${BUILD_NUMBER}
fi
