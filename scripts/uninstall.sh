#!/usr/bin/env bash
# Quits and removes Koffer. Settings, history and logs are left alone.
set -euo pipefail

osascript -e 'quit app "Koffer"' >/dev/null 2>&1 || true
sleep 1
pkill -x Koffer || true

removed=0
for dir in /Applications "$HOME/Applications"; do
  if [ -d "$dir/Koffer.app" ]; then
    rm -rf "$dir/Koffer.app"
    echo "Removed: $dir/Koffer.app"
    removed=1
  fi
done
[ "$removed" -eq 1 ] || echo "Koffer.app was not found in /Applications or ~/Applications."

echo
echo "Left in place (delete them yourself if you like):"
echo "  Settings and history: $HOME/Library/Application Support/Koffer"
echo "  Logs:                 $HOME/Library/Logs/Koffer"
