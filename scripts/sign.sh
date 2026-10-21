#!/usr/bin/env bash
# Signs a built binary with a stable identity so macOS remembers its Reminders/Calendar permission across rebuilds.
#   scripts/sign.sh <binary> <identifier>
# macOS keys an ad-hoc signed binary's permission to its exact hash, so every rebuild asked again.
# With a certificate the permission is tied to identifier + certificate instead and survives rebuilds.
# Identity: $CODESIGN_IDENTITY, else the first "Apple Development" / "Developer ID Application" one, else ad-hoc.
set -euo pipefail
BIN="$1"; ID="$2"
IDENTITY="${CODESIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null \
  | grep -Eo '"(Developer ID Application|Apple Development): [^"]+"' | head -1 | tr -d '"' || true)}"
if [[ -n "$IDENTITY" ]] && codesign -f -s "$IDENTITY" -i "$ID" "$BIN" 2>/dev/null; then
  echo "Signed $(basename "$BIN") as $ID ($IDENTITY)"
else
  codesign -f -s - -i "$ID" "$BIN"
  echo "Signed $(basename "$BIN") ad-hoc — macOS will ask for Reminders/Calendar again after each rebuild" >&2
fi
