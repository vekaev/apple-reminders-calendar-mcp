#!/usr/bin/env bash
# Builds apple-reminders-calendar-mcp from source and installs it to ~/.local/bin.
#   ./scripts/install.sh           build + install
#   ./scripts/install.sh --claude  also register it with Claude Code (user scope)
set -euo pipefail
cd "$(dirname "$0")/.."
NAME=apple-reminders-calendar-mcp
DEST="${PREFIX:-$HOME/.local}/bin"

# Use the Command Line Tools when Xcode's license hasn't been accepted.
if [[ -z "${DEVELOPER_DIR:-}" ]] && ! xcrun swift --version >/dev/null 2>&1; then
  export DEVELOPER_DIR=/Library/Developer/CommandLineTools
fi

swift build -c release --product "$NAME"
mkdir -p "$DEST"
# Replace, never overwrite in place: macOS kills a signed binary rewritten under the same inode.
rm -f "$DEST/$NAME"
cp "$(swift build -c release --show-bin-path)/$NAME" "$DEST/$NAME"
./scripts/sign.sh "$DEST/$NAME" dev.vekaev.reminders-mcp
echo "Installed $DEST/$NAME"
"$DEST/$NAME" --check || true

if [[ "${1:-}" == "--claude" ]]; then
  claude mcp remove -s user apple-reminders-calendar >/dev/null 2>&1 || true
  claude mcp add -s user apple-reminders-calendar -- "$DEST/$NAME"
fi
