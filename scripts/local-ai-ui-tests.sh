#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

export RXCODE_RUN_LOCAL_AI_UI_TESTS="${RXCODE_RUN_LOCAL_AI_UI_TESTS:-1}"
export RXCODE_LOCAL_MCP_SERVER="${RXCODE_LOCAL_MCP_SERVER:-$ROOT/scripts/mcp_echo_server.py}"

if [[ ! -x "$RXCODE_LOCAL_MCP_SERVER" ]]; then
  chmod +x "$RXCODE_LOCAL_MCP_SERVER"
fi

if ! command -v codex >/dev/null 2>&1; then
  echo "codex is required for the local AI UI suite." >&2
  exit 1
fi

if ! command -v claude >/dev/null 2>&1; then
  echo "claude is required for the local AI UI suite." >&2
  exit 1
fi

cd "$ROOT"

xcodebuild test \
  -project RxCode.xcodeproj \
  -scheme RxCode \
  -testPlan UITestplan \
  -configuration Debug \
  -only-testing:RxCodeUITests
