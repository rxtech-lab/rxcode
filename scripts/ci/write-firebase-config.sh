#!/bin/bash
# Decode the Firebase config files from CI secrets into the locations the
# respective targets expect them. Each input is optional — missing variables
# simply skip that platform, so a workflow that only builds one app doesn't
# need every secret defined.
#
# Required env (any/all):
#   FIREBASE_MACOS_B64   -> RxCode/GoogleService-Info.plist
#   FIREBASE_IOS_B64     -> RxCodeMobile/GoogleService-Info.plist
#   FIREBASE_ANDROID_B64 -> RxCodeAndroid/app/google-services.json

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

decode_to() {
  local var_name="$1"
  local out_path="$2"
  local b64="${!var_name:-}"
  if [[ -z "$b64" ]]; then
    echo "[firebase] $var_name not set; skipping $out_path"
    return
  fi
  mkdir -p "$(dirname "$out_path")"
  printf '%s' "$b64" | base64 --decode > "$out_path"
  echo "[firebase] wrote $out_path ($(wc -c < "$out_path") bytes)"
}

decode_to FIREBASE_MACOS_B64   "$REPO_ROOT/RxCode/GoogleService-Info.plist"
decode_to FIREBASE_IOS_B64     "$REPO_ROOT/RxCodeMobile/GoogleService-Info.plist"
decode_to FIREBASE_ANDROID_B64 "$REPO_ROOT/RxCodeAndroid/app/google-services.json"
