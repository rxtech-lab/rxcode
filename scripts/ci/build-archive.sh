#!/bin/bash
set -euo pipefail

# Archive RxCode for release.
#
# CURRENT_PROJECT_VERSION is overridden per-build so every CI build has a unique
# build number (github.run_number), without committing churn to project.pbxproj.
# The provisioning profile is scoped to the RxCode target's Release build
# settings in project.pbxproj (PROVISIONING_PROFILE_SPECIFIER), NOT passed on the
# command line. A command-line PROVISIONING_PROFILE* applies to every target in
# the graph — including SPM package targets that don't support provisioning
# profiles — which fails the archive. CODE_SIGN_STYLE/IDENTITY stay global:
# Manual signing needs no team and library targets sign with the identity but
# need no profile.
#
# --timestamp makes codesign contact Apple's secure timestamp service, which
# intermittently answers "The timestamp service is not available." and fails the
# whole archive with exit 65. Dropping --timestamp is not an option (notarization
# requires a secure timestamp), so retry instead. xcodebuild is incremental, so a
# retry only re-runs the CodeSign commands that failed.

LOG_FILE="xcodebuild-archive.log"
MAX_ATTEMPTS="${ARCHIVE_MAX_ATTEMPTS:-3}"
RETRY_DELAY="${ARCHIVE_RETRY_DELAY:-30}"

if [ -z "${SIGNING_CERTIFICATE_NAME:-}" ]; then
  echo "Error: SIGNING_CERTIFICATE_NAME is not set"
  exit 1
fi

if [ -z "${CURRENT_PROJECT_VERSION:-}" ]; then
  echo "Error: CURRENT_PROJECT_VERSION is not set"
  exit 1
fi

run_archive() {
  local status=0
  xcodebuild -destination platform=macOS \
    -project RxCode.xcodeproj \
    -scheme RxCode \
    -configuration Release \
    -archivePath output/output.xcarchive \
    -allowProvisioningUpdates \
    CODE_SIGN_IDENTITY="${SIGNING_CERTIFICATE_NAME}" \
    CODE_SIGN_STYLE=Manual \
    OTHER_CODE_SIGN_FLAGS="--options=runtime --timestamp" \
    CURRENT_PROJECT_VERSION="${CURRENT_PROJECT_VERSION}" \
    archive 2>&1 | tee "$LOG_FILE" | xcpretty || status=${PIPESTATUS[0]}
  return "$status"
}

# Only signing-service outages are worth retrying; a compile error would just
# fail again and burn runner minutes.
is_transient_failure() {
  grep -qE "The timestamp service is not available|Timestamp service is not available|timestamp service.*(unavailable|timed out)" "$LOG_FILE"
}

for attempt in $(seq 1 "$MAX_ATTEMPTS"); do
  status=0
  run_archive || status=$?

  if [ "$status" -eq 0 ]; then
    echo "Archive succeeded (attempt ${attempt}/${MAX_ATTEMPTS})"
    exit 0
  fi

  if [ "$attempt" -lt "$MAX_ATTEMPTS" ] && is_transient_failure; then
    echo "::warning::Archive failed on a transient Apple timestamp service error (attempt ${attempt}/${MAX_ATTEMPTS}); retrying in ${RETRY_DELAY}s"
    sleep "$RETRY_DELAY"
    continue
  fi

  echo "::group::Full xcodebuild output (archive failed)"
  cat "$LOG_FILE"
  echo "::endgroup::"
  exit "$status"
done
