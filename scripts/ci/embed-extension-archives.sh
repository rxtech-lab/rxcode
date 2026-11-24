#!/bin/bash
set -euo pipefail

cd "$SRCROOT"
destination="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/BundledExtensions"
mode=bundle
extra=()
if [[ "$CONFIGURATION" == Release && " ${OTHER_SWIFT_FLAGS:-} " == *" -DRXCODE_EXTENSION_RELEASE_GATE "* ]]; then
    mode=probe
    extra+=(--probe-resources "${RXCODE_EXTENSION_PROBE_RESOURCES:?The candidate needs the signed discovery fixture}")
elif [[ "$CONFIGURATION" != Debug && ! -f Extensions/bundled.lock.json ]]; then
    # Production keeps built-in providers until the signed releases have been pinned.
    exit 0
fi
if [[ "$CONFIGURATION" == Debug ]]; then
    mode=debug
    # Xcode already builds the shared package. Only run the standalone compiler when its
    # inputs or the current toolchain change, or when the product has been cleaned.
    fingerprint=$(python3 - <<'PY'
import hashlib, pathlib, subprocess
root = pathlib.Path.cwd()
digest = hashlib.sha256(subprocess.check_output(["xcrun", "swiftc", "--version"]))
patterns = ["Extensions/*/Sources/*.swift", "Extensions/*/extension.json", "Extensions/*/README.md",
            "Extensions/*/icon.png", "Extensions/*/Resources/Localizable.xcstrings", "Extensions/TestVectors/*.json",
            "Packages/Sources/RxCodeExtension*/**/*",
            "Packages/Sources/rxcode-extension/*.swift", "Packages/Sources/CExtensionArchive/**/*",
            "Packages/Sources/RxCodeCore/Extensions/*.swift", "scripts/ci/*extension*"]
for path in sorted({p for pattern in patterns for p in root.glob(pattern) if p.is_file()}):
    digest.update(path.relative_to(root).as_posix().encode() + bytes([0]))
    digest.update(hashlib.sha256(path.read_bytes()).digest())
print(digest.hexdigest())
PY
)
    marker="$DERIVED_FILE_DIR/debug-extension-archive-inputs"
    # Verify the sealed output set as well as the inputs. A partly cleaned product needs rebuilding.
    archive_tree_digest() {
        python3 - "$destination" <<'PYTHON'
import hashlib, pathlib, sys
folder = pathlib.Path(sys.argv[1])
digest = hashlib.sha256()
for path in sorted(folder.glob("*")):
    if not path.is_file():
        sys.exit(1)
    digest.update(path.name.encode() + bytes([0]) + hashlib.sha256(path.read_bytes()).digest())
print(digest.hexdigest())
PYTHON
    }
    if [[ -f "$marker" && -f "$destination/bundled.lock.json" && "$(cat "$marker")" == "$fingerprint $(archive_tree_digest)" ]]; then
        exit 0
    fi
fi
# SwiftPM needs its normal macOS environment even when invoked from a target build phase.
unset SDKROOT SWIFT_EXEC SWIFT_DRIVER_SWIFT_FRONTEND_EXEC
swift build --package-path Packages --product rxcode-extension
cli="$(swift build --package-path Packages --show-bin-path)/rxcode-extension"
python3 scripts/ci/extension-distribution.py "$mode" --cli "$cli" --output "$destination" ${extra[@]+"${extra[@]}"}
if [[ "$mode" == debug ]]; then
    printf '%s %s\n' "$fingerprint" "$(archive_tree_digest)" > "$marker"
fi
