#!/usr/bin/env swift
// Renders the Retappd app icon ("Foamy R": a cream Georgia Bold R with a head of foam on orange)
// as a 1024×1024 opaque PNG. iOS applies the rounded-corner mask itself.
//
// Usage: swift scripts/make-app-icon.swift [output.png]

import AppKit
import CoreText

let output = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "Retappd/Assets.xcassets/AppIcon.appiconset/AppIcon.png"

let px = 1024
let unit = CGFloat(px) / 100 // the design is laid out on a 100×100 grid, y pointing down

let orange = CGColor(srgbRed: 0xE0 / 255, green: 0x62 / 255, blue: 0x1B / 255, alpha: 1)
let cream = CGColor(srgbRed: 0xFF / 255, green: 0xF4 / 255, blue: 0xDC / 255, alpha: 1)

guard let ctx = CGContext(
    data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
) else { fatalError("Couldn't create bitmap context") }

// Converts a point on the 100-unit, y-down design grid to CoreGraphics' y-up pixel space.
func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * unit, y: (100 - y) * unit) }

ctx.setFillColor(orange)
ctx.fill(CGRect(x: 0, y: 0, width: px, height: px))

// The R, centred horizontally on its glyph bounds, baseline at y = 82.
let font = CTFontCreateWithName("Georgia-Bold" as CFString, 68 * unit, nil)
let attrs: [NSAttributedString.Key: Any] = [
    NSAttributedString.Key(kCTFontAttributeName as String): font,
    NSAttributedString.Key(kCTForegroundColorAttributeName as String): cream,
]
let line = CTLineCreateWithAttributedString(NSAttributedString(string: "R", attributes: attrs))
let glyph = CTLineGetImageBounds(line, ctx)
let baseline = p(50, 82)
ctx.textPosition = CGPoint(x: baseline.x - glyph.midX, y: baseline.y)
CTLineDraw(line, ctx)

// The foam: overlapping bubbles across the top of the R, plus one stray fleck.
ctx.setFillColor(cream)
for (x, y, r) in [(34, 30, 7), (45, 26, 8), (57, 28, 7), (66, 32, 5), (74, 41, 2)] as [(CGFloat, CGFloat, CGFloat)] {
    let c = p(x, y)
    ctx.fillEllipse(in: CGRect(x: c.x - r * unit, y: c.y - r * unit, width: 2 * r * unit, height: 2 * r * unit))
}

guard let image = ctx.makeImage(),
      let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
else { fatalError("Couldn't encode PNG") }
try png.write(to: URL(fileURLWithPath: output))
print("Wrote \(output)")
