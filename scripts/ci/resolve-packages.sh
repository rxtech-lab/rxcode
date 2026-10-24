#!/bin/bash
set -euo pipefail

# Retry dependency downloads before building or testing, without retrying tests.
LOG_FILE=$(mktemp "${TMPDIR:-/tmp}/rxcode-resolve.XXXXXX")
trap 'rm -f "$LOG_FILE"' EXIT

for attempt in 1 2 3; do
  status=0
  xcodebuild -resolvePackageDependencies "$@" 2>&1 | tee "$LOG_FILE" || status=${PIPESTATUS[0]}
  if [ "$status" -eq 0 ]; then
    exit 0
  fi

  # Require both a download failure and a recognized transient network error.
  if [ "$attempt" -lt 3 ] \
    && grep -qiE 'failed downloading|Failed to clone repository|Could not fetch' "$LOG_FILE" \
    && grep -qiE 'timed out|connection (was )?reset|Could not resolve host|HTTP[^0-9]*50[234]|status code[^0-9]*50[234]' "$LOG_FILE"; then
    echo "::warning::Package download failed on attempt ${attempt}/3; retrying in 15s"
    sleep 15
  else
    exit "$status"
  fi
done
