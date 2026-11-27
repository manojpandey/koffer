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
# Newer toolchains (Command Line Tools without Xcode) can fail to start SwiftPM's default
# build system with "Could not initialize build system". Fall back to the native one.
BUILD_FLAGS=(-c release)
if ! swift build "${BUILD_FLAGS[@]}"; then
  echo "Default build system failed; retrying with --build-system native..."
  BUILD_FLAGS=(-c release --build-system native)
  swift build "${BUILD_FLAGS[@]}"
fi
BIN_DIR="$(swift build "${BUILD_FLAGS[@]}" --show-bin-path)"

APP="$ROOT/build/Koffer.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN_DIR/Koffer" "$APP/Contents/MacOS/Koffer"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Stamp where this copy of the source lives, so "Update Koffer" in the panel can update it later.
# (Only in the built app on this Mac; nothing here is committed.)
/usr/bin/plutil -replace KofferSourceDirectory -string "$ROOT" "$APP/Contents/Info.plist" || true
if COMMIT="$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null)"; then
  /usr/bin/plutil -replace KofferCommit -string "$COMMIT" "$APP/Contents/Info.plist" || true
fi

# Optional icon: never fatal.
bash "$ROOT/scripts/make-icon.sh" || true
if [ -f "$ROOT/build/AppIcon.icns" ]; then
  cp "$ROOT/build/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi

echo "Signing (ad-hoc)..."
codesign --force --deep --sign - "$APP"

echo "Built: $APP"
