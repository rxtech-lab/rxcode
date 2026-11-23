#!/bin/bash
# Run from any directory. Supply two installed signing team IDs.
set -euo pipefail
if [[ $# != 2 ]]; then
    echo "Usage: $0 HOST_TEAM_ID EXTERNAL_TEAM_ID" >&2
    exit 2
fi
fixture_dir="$(cd "$(dirname "$0")" && pwd)"
repo_dir="$(cd "$fixture_dir/../.." && pwd)"
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
