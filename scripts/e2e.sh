#!/usr/bin/env bash
# Builds and runs the end-to-end suite against your real Reminders and Calendar (sandbox [e2e] lists only).
# Both binaries are signed with a stable identity first, so macOS asks for access once, not after every build.
#   ./scripts/e2e.sh [--cleanup]
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ -z "${DEVELOPER_DIR:-}" ]] && ! xcrun swift --version >/dev/null 2>&1; then
  export DEVELOPER_DIR=/Library/Developer/CommandLineTools
fi
swift build -c release | tail -1
B="$(swift build -c release --show-bin-path)"
./scripts/sign.sh "$B/apple-reminders-calendar-mcp" dev.vekaev.reminders-mcp >/dev/null
./scripts/sign.sh "$B/e2e" dev.vekaev.reminders-mcp.e2e >/dev/null
if [[ "${1:-}" == "--cleanup" ]]; then exec "$B/e2e" --cleanup; fi
exec "$B/e2e" "$B/apple-reminders-calendar-mcp"
