#!/bin/bash
# Build the isolated ExtensionKit probe, distributable releases, or two-team fixtures.
set -euo pipefail
fixture_dir="$(cd "$(dirname "$0")" && pwd)"
repo_dir="$(cd "$fixture_dir/../.." && pwd)"
if [[ ${1:-} == package ]]; then
    if [[ $# != 4 && $# != 6 ]] || [[ ! "$2" =~ ^[0-9]+([.][0-9]+){0,2}$ || ! -x "$4" || -e "$3" ]]; then
        echo "Usage: $0 package VERSION NEW_OUTPUT_DIRECTORY /path/to/rxcode-extension [RXLab_DEVELOPER_ID NOTARY_KEYCHAIN_PROFILE]" >&2
        exit 2
    fi
    version="$2"
    destination="$3"
    cli="$4"
    signer="${5:--}"
    if [[ $# == 6 && ( "$signer" != "Developer ID Application: "*" (T7GYB573Y6)" || -z "$6" ) ]]; then
        echo "Use the rxlab Developer ID Application identity and a notarytool keychain profile." >&2
        exit 2
    fi
    mkdir -p "$destination/source/Sources"
    cp "$fixture_dir/Contributor/CombinedExtension.swift" "$destination/source/Sources/"
    cat > "$destination/source/extension.json" <<MANIFEST
{
  "id": "app.rxlab.extensions.discovery-probe",
  "name": "Discovery Probe", "version": "$version", "pluginAPI": "2.0", "readme": "README.md",
  "permissions": [],
  "contributes": {
    "inspector.panel": {"title": "Discovery Probe", "symbol": "puzzlepiece.extension"},
    "usage.detail": true,
    "usage.provider": [{"pluginID": "discovery-probe", "title": "Discovery Probe"}]
  }
}
MANIFEST
    cat > "$destination/source/README.md" <<'README'
# Discovery Probe

The inspector and usage detail popover report their dimensions, installed version and broker callback result.
Refreshing the fixture usage provider tests a callback over its service session.
README
    app="$destination/Contributor.app"
    "$cli" build "$destination/source" --output "$app" --sign "$signer"
    if [[ "$signer" != "-" ]]; then
        requirement='=anchor apple generic and certificate leaf[subject.OU] = "T7GYB573Y6" and certificate leaf[field.1.2.840.113635.100.6.1.13] exists'
        codesign --verify --all-architectures --strict -R "$requirement" "$app/Contents/Extensions/Service.appex"
        codesign --verify --all-architectures --deep --strict -R "$requirement" "$app"
        ditto -c -k --keepParent "$app" "$destination/notarization.zip"
        xcrun notarytool submit "$destination/notarization.zip" --keychain-profile "$6" --wait
        xcrun stapler staple "$app"
        xcrun stapler validate "$app"
    fi
    "$cli" package "$destination/Contributor.app" --output "$destination/probe.zip" > "$destination/metadata.json"
    echo "Built the distributable v$version probe and unsigned release metadata in $destination"
    exit
fi
if [[ ${1:-} == adhoc ]]; then
    # Build the fixture without installing it or modifying user enablement.
    version="${2:-1.0}"
    if [[ $# -gt 2 || ! "$version" =~ ^[0-9]+([.][0-9]+){0,2}$ ]]; then
        echo "Usage: $0 adhoc [numeric-version]" >&2
        exit 2
    fi
    probe_root="$repo_dir/build/extension-runtime-adhoc/$version"
    # An isolated host is the default. Use the Release host identifier on the test VMs.
    host_id="${FIXTURE_HOST_ID:-app.rxlab.flowcy.code.probe.adhoc}"
    container_id="app.rxlab.flowcy.code.contributor.adhoc"
    project="$fixture_dir/ExtensionRuntime.xcodeproj"
    xcodegen generate --spec "$fixture_dir/project.yml"
    args=(-quiet -project "$project" -configuration Release -destination 'generic/platform=macOS'
        CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO ENABLE_HARDENED_RUNTIME=YES
        "FIXTURE_HOST_ID=$host_id" "FIXTURE_CONTAINER_ID=$container_id"
        "FIXTURE_PRIMARY_CONTAINER_ID=$container_id" "MARKETING_VERSION=$version"
        ONLY_ACTIVE_ARCH=NO 'ARCHS=arm64 x86_64')
    xcodebuild "${args[@]}" -scheme CombinedContributors -derivedDataPath "$probe_root/contributor" build
    app="$probe_root/contributor/Build/Products/Release/CombinedContributors.app"
    appex="$app/Contents/Extensions/Combined.appex"
    codesign --verify --deep --strict "$app"
    for arch in arm64 x86_64; do
        lipo -verify_arch "$arch" "$appex/Contents/MacOS/Combined"
        codesign -d --arch "$arch" --entitlements :- "$appex" 2>/dev/null | python3 -c '
import plistlib, sys
expected = {"com.apple.security.app-sandbox": True}
if plistlib.loads(sys.stdin.buffer.read()) != expected:
    sys.exit("Unexpected contributor entitlements")
'
    done
    if [[ "$host_id" != app.rxlab.flowcy.code.probe.adhoc ]]; then
        # The production host already owns this extension point. Never build a second host with its ID.
        echo "Built the contributor for $host_id in $app"
        exit
    fi
    host_arch="$(uname -m)"
    cdhash="$(codesign -dvv --arch "$host_arch" "$appex" 2>&1 | sed -n 's/^CDHash=//p')"
    [[ "$cdhash" =~ ^[a-f0-9]{40}$ ]]
    xcodebuild "${args[@]}" -scheme RuntimeProbe -derivedDataPath "$probe_root/host" \
        "FIXTURE_COMBINED_CDHASH=$cdhash" build
    codesign --verify --deep --strict "$probe_root/host/Build/Products/Release/RuntimeProbe.app"
    echo "Built combined contributor $version and the isolated probe host for $host_arch in $probe_root"
    exit
fi
if [[ $# != 2 ]]; then
    echo "Usage: $0 HOST_TEAM_ID EXTERNAL_TEAM_ID | adhoc [version] | package VERSION NEW_OUTPUT_DIRECTORY CLI [RXLab_DEVELOPER_ID NOTARY_KEYCHAIN_PROFILE]" >&2
    exit 2
fi
case "${FIXTURE_SERVICE_POINT:-workspace-service}" in
    workspace-service) run_label=split ;;
    workspace) run_label=single ;;
    *) echo "Use workspace or workspace-service for FIXTURE_SERVICE_POINT." >&2; exit 2 ;;
esac
probe_root="$repo_dir/build/extension-runtime-$run_label"
host_id="app.rxlab.flowcy.code.probe.$run_label"
first_id="app.rxlab.flowcy.code.contributor.$run_label"
external_id="app.rxlab.flowcy.code.external.$run_label"
xcodegen generate --spec "$fixture_dir/project.yml"
build_fixture() {
    local scheme="$1" team="$2" container_id="$3" destination="$4"
    xcodebuild -quiet -project "$fixture_dir/ExtensionRuntime.xcodeproj" -scheme "$scheme" \
        -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath "$destination" \
        "DEVELOPMENT_TEAM=$team" "FIXTURE_HOST_ID=$host_id" "FIXTURE_CONTAINER_ID=$container_id" \
        "FIXTURE_PRIMARY_CONTAINER_ID=$first_id" "FIXTURE_EXTERNAL_CONTAINER_ID=$external_id" \
        "FIXTURE_PRIMARY_TEAM=$primary_team" "FIXTURE_EXTERNAL_TEAM=$external_team" \
        "FIXTURE_SERVICE_POINT=${FIXTURE_SERVICE_POINT:-workspace-service}" build
    codesign --verify --deep --strict "$destination/Build/Products/Debug/$scheme.app"
}
primary_team="$1"
external_team="$2"
build_fixture RuntimeProbe "$primary_team" "$first_id" "$probe_root/host"
build_fixture Contributors "$primary_team" "$first_id" "$probe_root/first"
build_fixture Contributors "$external_team" "$external_id" "$probe_root/external"
echo "Signed probe and contributors built under $probe_root"
