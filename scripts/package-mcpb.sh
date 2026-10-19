#!/usr/bin/env bash
# Builds dist/apple-reminders-calendar.mcpb — a Claude Desktop extension (double-click to install).
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ -z "${DEVELOPER_DIR:-}" ]] && ! xcrun swift --version >/dev/null 2>&1; then
  export DEVELOPER_DIR=/Library/Developer/CommandLineTools
fi
swift build -c release --product apple-reminders-calendar-mcp
STAGE="$(mktemp -d)/apple-reminders-calendar"
mkdir -p "$STAGE/server" dist
cp mcpb/manifest.json README.md LICENSE "$STAGE/"
cp "$(swift build -c release --show-bin-path)/apple-reminders-calendar-mcp" "$STAGE/server/"
rm -f dist/apple-reminders-calendar.mcpb
(cd "$STAGE" && zip -qrX "$OLDPWD/dist/apple-reminders-calendar.mcpb" .)
echo "Built dist/apple-reminders-calendar.mcpb"
