#!/usr/bin/env bash
# Optional, best effort: generates build/AppIcon.icns. Never fails the build.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/build"
WORK="$OUT/icon-work"

skip() { echo "Note: skipping app icon ($1)."; exit 0; }

for tool in swift sips iconutil; do
  command -v "$tool" >/dev/null 2>&1 || skip "$tool not found"
done

mkdir -p "$OUT" || skip "cannot create build folder"
rm -rf "$WORK"
mkdir -p "$WORK" || skip "cannot create work folder"

cat > "$WORK/icon.swift" <<'SWIFT'
import AppKit

let size: CGFloat = 1024
let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"

let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()

let rect = NSRect(x: 0, y: 0, width: size, height: size).insetBy(dx: 80, dy: 80)
let path = NSBezierPath(roundedRect: rect, xRadius: 185, yRadius: 185)
let gradient = NSGradient(colors: [
    NSColor(calibratedWhite: 0.16, alpha: 1),
    NSColor(calibratedWhite: 0.13, alpha: 1),
    NSColor(calibratedWhite: 0.11, alpha: 1),
    NSColor(calibratedWhite: 0.09, alpha: 1),
])
gradient?.draw(in: path, angle: -60)

let config = NSImage.SymbolConfiguration(pointSize: 480, weight: .semibold)
if let symbol = NSImage(systemSymbolName: "suitcase.fill", accessibilityDescription: nil)?
    .withSymbolConfiguration(config) {
    let white = NSImage(size: symbol.size)
    white.lockFocus()
    symbol.draw(in: NSRect(origin: .zero, size: symbol.size))
    NSColor.white.set()
    NSRect(origin: .zero, size: symbol.size).fill(using: .sourceIn)
    white.unlockFocus()
    let x = (size - white.size.width) / 2
    let y = (size - white.size.height) / 2
    white.draw(in: NSRect(x: x, y: y, width: white.size.width, height: white.size.height))
}

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    exit(1)
}
do { try png.write(to: URL(fileURLWithPath: outPath)) } catch { exit(1) }
SWIFT

swift "$WORK/icon.swift" "$WORK/icon_1024.png" >/dev/null 2>&1 || skip "could not draw the icon"
[ -s "$WORK/icon_1024.png" ] || skip "icon image was not created"

SET="$WORK/AppIcon.iconset"
mkdir -p "$SET"
make() { sips -z "$1" "$1" "$WORK/icon_1024.png" --out "$SET/$2" >/dev/null 2>&1; }
make 16 icon_16x16.png;       make 32 icon_16x16@2x.png
make 32 icon_32x32.png;       make 64 icon_32x32@2x.png
make 128 icon_128x128.png;    make 256 icon_128x128@2x.png
make 256 icon_256x256.png;    make 512 icon_256x256@2x.png
make 512 icon_512x512.png;    cp "$WORK/icon_1024.png" "$SET/icon_512x512@2x.png"

iconutil -c icns "$SET" -o "$OUT/AppIcon.icns" >/dev/null 2>&1 || skip "iconutil failed"
rm -rf "$WORK"
echo "Icon created: $OUT/AppIcon.icns"
exit 0
