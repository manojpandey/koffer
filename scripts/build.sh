#!/usr/bin/env bash
# Builds build/Koffer.app using only the Command Line Tools.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if ! command -v swift >/dev/null 2>&1; then
  echo "Swift was not found. Install the Command Line Tools with:" >&2
  echo "    xcode-select --install" >&2
  exit 1
fi

echo "Building Koffer (release)..."
swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"

APP="$ROOT/build/Koffer.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN_DIR/Koffer" "$APP/Contents/MacOS/Koffer"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Optional icon: never fatal.
bash "$ROOT/scripts/make-icon.sh" || true
if [ -f "$ROOT/build/AppIcon.icns" ]; then
  cp "$ROOT/build/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi

echo "Signing (ad-hoc)..."
codesign --force --deep --sign - "$APP"

echo "Built: $APP"
