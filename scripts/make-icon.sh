#!/bin/bash
# Generate AppIcon.icns from an SF Symbol using a Swift one-liner.
#
# Produces: Resources/AppIcon.icns
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ICONSET_DIR="$PROJECT_DIR/.build/AppIcon.iconset"
OUT_ICNS="$PROJECT_DIR/Resources/AppIcon.icns"

rm -rf "$ICONSET_DIR"
mkdir -p "$ICONSET_DIR"

# Sizes required by macOS iconset
SIZES=(16 32 64 128 256 512 1024)

echo "[icon] Generating icon PNGs via Swift + AppKit…"

# Use a Swift script to render the icon. SF Symbol on a gradient background.
cat > /tmp/render_icon.swift <<'SWIFT'
import AppKit
import Foundation

let sizes: [Int] = [16, 32, 64, 128, 256, 512, 1024]
let outputDir = CommandLine.arguments[1]

for size in sizes {
    let px = CGFloat(size)
    let image = NSImage(size: NSSize(width: px, height: px))
    image.lockFocus()

    // Rounded square background gradient (blue → purple)
    let cornerRadius = px * 0.22
    let rect = NSRect(x: 0, y: 0, width: px, height: px)
    let path = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)

    let gradient = NSGradient(colors: [
        NSColor(calibratedRed: 0.35, green: 0.55, blue: 1.0, alpha: 1.0),  // sky blue
        NSColor(calibratedRed: 0.55, green: 0.40, blue: 0.95, alpha: 1.0), // purple
    ])!
    gradient.draw(in: path, angle: -45)

    // Inner glow ring
    path.lineWidth = max(px / 128, 1)
    NSColor.white.withAlphaComponent(0.25).setStroke()
    path.stroke()

    // SF Symbol foreground: waveform + speech bubble
    let symbolSize = px * 0.56
    let config = NSImage.SymbolConfiguration(pointSize: symbolSize, weight: .medium)
    if let symbol = NSImage(systemSymbolName: "waveform.and.mic", accessibilityDescription: nil)?
        .withSymbolConfiguration(config) {
        let whiteSymbol = NSImage(size: symbol.size, flipped: false) { rect in
            symbol.draw(in: rect)
            NSColor.white.set()
            rect.fill(using: .sourceIn)
            return true
        }
        let x = (px - symbol.size.width) / 2
        let y = (px - symbol.size.height) / 2
        whiteSymbol.draw(in: NSRect(x: x, y: y, width: symbol.size.width, height: symbol.size.height))
    }

    image.unlockFocus()

    // Save as PNG
    guard let tiffData = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiffData),
          let pngData = bitmap.representation(using: .png, properties: [:]) else {
        fatalError("Failed to render size \(size)")
    }

    let url = URL(fileURLWithPath: outputDir).appendingPathComponent("icon_\(size).png")
    try! pngData.write(to: url)
    print("  \(size)×\(size) → \(url.lastPathComponent)")
}
SWIFT

swift /tmp/render_icon.swift "$ICONSET_DIR"
rm -f /tmp/render_icon.swift

# Rename to iconset-required names:  icon_16x16.png, icon_16x16@2x.png, etc.
cd "$ICONSET_DIR"
mv icon_16.png   icon_16x16.png
cp icon_32.png   icon_16x16@2x.png
mv icon_32.png   icon_32x32.png
cp icon_64.png   icon_32x32@2x.png
rm icon_64.png
mv icon_128.png  icon_128x128.png
cp icon_256.png  icon_128x128@2x.png
mv icon_256.png  icon_256x256.png
cp icon_512.png  icon_256x256@2x.png
mv icon_512.png  icon_512x512.png
mv icon_1024.png icon_512x512@2x.png

# Convert iconset → icns
mkdir -p "$(dirname "$OUT_ICNS")"
iconutil -c icns -o "$OUT_ICNS" "$ICONSET_DIR"

# Cleanup
rm -rf "$ICONSET_DIR"

ICNS_SIZE=$(du -h "$OUT_ICNS" | cut -f1)
echo "[icon] Created: $OUT_ICNS ($ICNS_SIZE)"
