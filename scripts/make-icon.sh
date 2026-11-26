#!/bin/bash
# Builds build/AppIcon.icns from the committed Resources/AppIcon.png (1024 px).
# Best effort: never fails the build. Redraw the PNG with scripts/draw-icon.py if the design changes.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/Resources/AppIcon.png"
OUT="$ROOT/build"
SET="$OUT/AppIcon.iconset"

if [ ! -f "$SRC" ] || ! command -v sips >/dev/null 2>&1 || ! command -v iconutil >/dev/null 2>&1; then
  echo "Skipping app icon (missing AppIcon.png, sips or iconutil)."
  exit 0
fi

mkdir -p "$SET" || exit 0
for size in 16 32 128 256 512; do
  double=$((size * 2))
  sips -z "$size" "$size" "$SRC" --out "$SET/icon_${size}x${size}.png" >/dev/null 2>&1 || true
  sips -z "$double" "$double" "$SRC" --out "$SET/icon_${size}x${size}@2x.png" >/dev/null 2>&1 || true
done
if iconutil -c icns "$SET" -o "$OUT/AppIcon.icns" >/dev/null 2>&1; then
  echo "App icon built."
else
  echo "Could not build the app icon; continuing without it."
fi
rm -rf "$SET"
exit 0
