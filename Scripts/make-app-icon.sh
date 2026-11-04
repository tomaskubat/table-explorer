#!/bin/sh
# Regenerate the macOS icon from the vector artwork using only macOS tools.
set -eu
cd "$(dirname "$0")/.."
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
setdir="$work/Database.iconset"
mkdir "$setdir"
mkdir -p .build/IconModuleCache
swift -module-cache-path .build/IconModuleCache - Design/Database.svg "$work/master.png" <<'SWIFT'
import AppKit
let source = URL(fileURLWithPath: CommandLine.arguments[1])
let destination = URL(fileURLWithPath: CommandLine.arguments[2])
guard let image = NSImage(contentsOf: source),
      let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024,
          bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
      let context = NSGraphicsContext(bitmapImageRep: bitmap) else { fatalError("Cannot render icon") }
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
image.draw(in: NSRect(x: 0, y: 0, width: 1024, height: 1024))
NSGraphicsContext.restoreGraphicsState()
try bitmap.representation(using: .png, properties: [:])!.write(to: destination)
SWIFT
for pt in 16 32 128 256 512; do
  for scale in 1 2; do
    suffix=""; if [ "$scale" = 2 ]; then suffix="@2x"; fi
    s=$((pt * scale))
    sips -z "$s" "$s" "$work/master.png" --out "$setdir/icon_${pt}x${pt}${suffix}.png" >/dev/null
  done
done
iconutil -c icns "$setdir" -o ConnectionBrowser/Database.icns
