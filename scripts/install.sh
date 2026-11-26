#!/usr/bin/env bash
# Builds Koffer and installs it to /Applications (or ~/Applications).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

"$ROOT/scripts/build.sh"

echo "Closing Koffer if it is running..."
osascript -e 'quit app "Koffer"' >/dev/null 2>&1 || true
sleep 1
pkill -x Koffer || true

DEST_DIR="/Applications"
if [ ! -w "$DEST_DIR" ]; then
  DEST_DIR="$HOME/Applications"
  mkdir -p "$DEST_DIR"
fi
DEST="$DEST_DIR/Koffer.app"
rm -rf "$DEST"
cp -R "$ROOT/build/Koffer.app" "$DEST"
echo "Installed: $DEST"

SUPPORT="$HOME/Library/Application Support/Koffer"
if [ ! -e "$SUPPORT/config.json" ] && [ -f "$ROOT/config/config.local.json" ]; then
  mkdir -p "$SUPPORT"
  cp "$ROOT/config/config.local.json" "$SUPPORT/config.json"
  echo "Installed your local job list to: $SUPPORT/config.json"
fi

if [ ! -x /opt/homebrew/bin/rclone ] && [ ! -x /usr/local/bin/rclone ]; then
  echo "Note: rclone was not found. Install it with:  brew install rclone"
  echo "      then set up OneDrive with:  rclone config"
fi

open "$DEST"
echo
echo "What to expect:"
echo "  1. A suitcase icon appears in your menu bar (there is no Dock icon)."
echo "  2. macOS asks to allow notifications. Say yes, so Koffer can tell you when a backup ends."
echo "  3. The first time it reads your external disk, macOS asks for access to removable volumes. Say yes."
