#!/usr/bin/env swift
// Composites raw iOS Simulator screenshots into App Store Connect marketing frames
// in Retappd's Taproom palette (opaque sRGB PNGs).
//
// Usage: swift scripts/make-screenshots.swift <raw-dir> <output-dir>
//   Expects <raw-dir>/iphone/01-checkin.png ... 06-discover.png
//   and/or  <raw-dir>/ipad/01-checkin.png   ... 06-discover.png

import AppKit
import CoreGraphics
import CoreText
import Foundation

struct Palette {
    let top: CGColor
    let bottom: CGColor
    let glow: CGColor
    let title: NSColor
    let subtitle: NSColor
    let isDark: Bool
}

struct Slide {
    let file: String
    let iphoneHeadline: String
    let ipadHeadline: String
    let subtitle: String
    let palette: Palette
}

func rgb(_ hex: Int, alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

func nsColor(_ hex: Int, alpha: CGFloat = 1) -> NSColor {
    NSColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

let espresso = Palette(
    top: rgb(0x261C14),
    bottom: rgb(0x140F0A),
    glow: rgb(0xE9A23B, alpha: 0.24),
    title: nsColor(0xFBF8F3),
    subtitle: nsColor(0xC9B9A6),
    isDark: true
)

let cream = Palette(
    top: rgb(0xFBF8F3),
    bottom: rgb(0xEFE5D6),
    glow: rgb(0xE9A23B, alpha: 0.16),
    title: nsColor(0x2B2118),
    subtitle: nsColor(0x6F6252),
    isDark: false
)

let amber = Palette(
    top: rgb(0xEEA944),
    bottom: rgb(0xD88824),
    glow: rgb(0xFFF4DC, alpha: 0.28),
    title: nsColor(0x231A12),
    subtitle: nsColor(0x3B2B1B),
    isDark: false
)

let sand = Palette(
    top: rgb(0xF3EAD9),
    bottom: rgb(0xE4D3BC),
    glow: rgb(0xE9A23B, alpha: 0.20),
    title: nsColor(0x2B2118),
    subtitle: nsColor(0x5E5142),
    isDark: false
)

let slides: [Slide] = [
    Slide(
        file: "01-checkin.png",
        iphoneHeadline: "Pour a rating.",
        ipadHeadline: "Pour a rating.",
        subtitle: "Drag the glass to score and check in in seconds.",
        palette: espresso
    ),
    Slide(
        file: "02-feed.png",
        iphoneHeadline: "Your friends’ feed,\nuncluttered.",
        ipadHeadline: "Your friends’ feed, uncluttered.",
        subtitle: "Big photos, glass ratings, and badges—none of the noise.",
        palette: cream
    ),
    Slide(
        file: "03-venue.png",
        iphoneHeadline: "See what’s on tap.",
        ipadHeadline: "See what’s on tap.",
        subtitle: "Filter venue menus and spot beers you’ve already had.",
        palette: amber
    ),
    Slide(
        file: "04-beer.png",
        iphoneHeadline: "Every detail\non the label.",
        ipadHeadline: "Every detail on the label.",
        subtitle: "Compare scores with friends, explore flavours, and stats.",
        palette: cream
    ),
    Slide(
        file: "05-stats.png",
        iphoneHeadline: "Track your\ntasting history.",
        ipadHeadline: "Track your tasting history.",
        subtitle: "Interactive charts, custom ranges, and your top pours.",
        palette: espresso
    ),
    Slide(
        file: "06-discover.png",
        iphoneHeadline: "Built for basement\ntaprooms.",
        ipadHeadline: "Built for basement taprooms.",
        subtitle: "Find nearby venues, scan barcodes, or save offline.",
        palette: sand
    ),
]

enum DeviceSpec {
    case iphone
    case ipad

    var folder: String { self == .iphone ? "iphone" : "ipad" }
    var canvasWidth: Int { self == .iphone ? 1320 : 2064 }
    var canvasHeight: Int { self == .iphone ? 2868 : 2752 }
    var headlineSize: CGFloat { self == .iphone ? 96 : 94 }
    var subtitleSize: CGFloat { self == .iphone ? 41 : 40 }
    var horizontalInset: CGFloat { self == .iphone ? 92 : 140 }
    var topPadding: CGFloat { self == .iphone ? 135 : 108 }
    var deviceWidth: CGFloat { self == .iphone ? 1004 : 1680 }
    var bezelThickness: CGFloat { self == .iphone ? 28 : 34 }
    var screenCornerRadius: CGFloat { self == .iphone ? 118 : 52 }
    var deviceTopOffset: CGFloat { self == .iphone ? 625 : 495 }
}

func roundedRectPath(_ rect: CGRect, radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

func drawSlide(_ slide: Slide, rawURL: URL, outURL: URL, spec: DeviceSpec) throws {
    guard let srcImg = NSImage(contentsOf: rawURL),
          let cgRaw = srcImg.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
        throw NSError(domain: "make-screenshots", code: 1, userInfo: [NSLocalizedDescriptionKey: "Cannot load \(rawURL.path)"])
    }

    let w = spec.canvasWidth
    let h = spec.canvasHeight
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let ctx = CGContext(
        data: nil,
        width: w,
        height: h,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    ) else {
        throw NSError(domain: "make-screenshots", code: 2, userInfo: [NSLocalizedDescriptionKey: "Cannot create context"])
    }

    let fw = CGFloat(w)
    let fh = CGFloat(h)

    // 1. Background vertical gradient (CoreGraphics y=0 is bottom)
    let grad = CGGradient(
        colorsSpace: colorSpace,
        colors: [slide.palette.bottom, slide.palette.top] as CFArray,
        locations: [0.0, 1.0]
    )!
    ctx.drawLinearGradient(grad, start: CGPoint(x: fw / 2, y: 0), end: CGPoint(x: fw / 2, y: fh), options: [])

    // 2. Subtle warm radial glow behind the device
    let glowGrad = CGGradient(
        colorsSpace: colorSpace,
        colors: [slide.palette.glow, rgb(0xE9A23B, alpha: 0)] as CFArray,
        locations: [0.0, 1.0]
    )!
    let glowCenter = CGPoint(x: fw / 2, y: fh * 0.42)
    ctx.drawRadialGradient(
        glowGrad,
        startCenter: glowCenter,
        startRadius: 40,
        endCenter: glowCenter,
        endRadius: fw * 0.85,
        options: []
    )

    // 3. Draw text using flipped NSGraphicsContext so top-down layout is effortless
    NSGraphicsContext.saveGraphicsState()
    let nsCtx = NSGraphicsContext(cgContext: ctx, flipped: true)
    NSGraphicsContext.current = nsCtx
    ctx.saveGState()
    ctx.translateBy(x: 0, y: fh)
    ctx.scaleBy(x: 1, y: -1)

    let textWidth = fw - spec.horizontalInset * 2
    let headline = spec == .iphone ? slide.iphoneHeadline : slide.ipadHeadline

    let para = NSMutableParagraphStyle()
    para.alignment = .center
    para.lineHeightMultiple = 1.04

    let headlineAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: spec.headlineSize, weight: .heavy),
        .foregroundColor: slide.palette.title,
        .kern: -2.2,
        .paragraphStyle: para,
    ]
    let headlineStr = NSAttributedString(string: headline, attributes: headlineAttrs)
    let headlineBounds = headlineStr.boundingRect(
        with: CGSize(width: textWidth, height: 600),
        options: [.usesLineFragmentOrigin, .usesFontLeading]
    )

    let subPara = NSMutableParagraphStyle()
    subPara.alignment = .center
    subPara.lineHeightMultiple = 1.18

    let subAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: spec.subtitleSize, weight: .medium),
        .foregroundColor: slide.palette.subtitle,
        .kern: -0.3,
        .paragraphStyle: subPara,
    ]
    let subStr = NSAttributedString(string: slide.subtitle, attributes: subAttrs)
    let subBounds = subStr.boundingRect(
        with: CGSize(width: textWidth, height: 300),
        options: [.usesLineFragmentOrigin, .usesFontLeading]
    )

    let gap: CGFloat = spec == .iphone ? 28 : 22
    let totalTextHeight = ceil(headlineBounds.height) + gap + ceil(subBounds.height)

    // Center the text block vertically between top margin and device top
    let availableHeader = spec.deviceTopOffset - spec.topPadding - 36
    let textStartY = spec.topPadding + max(0, (availableHeader - totalTextHeight) / 2)

    headlineStr.draw(
        with: CGRect(x: spec.horizontalInset, y: textStartY, width: textWidth, height: ceil(headlineBounds.height) + 12),
        options: [.usesLineFragmentOrigin, .usesFontLeading]
    )
    subStr.draw(
        with: CGRect(x: spec.horizontalInset, y: textStartY + ceil(headlineBounds.height) + gap, width: textWidth, height: ceil(subBounds.height) + 12),
        options: [.usesLineFragmentOrigin, .usesFontLeading]
    )

    ctx.restoreGState()
    NSGraphicsContext.restoreGraphicsState()

    // 4. Device bezel & screen (in CoreGraphics y-up coordinates)
    let rawAspect = CGFloat(cgRaw.height) / CGFloat(cgRaw.width)
    let bezel = spec.bezelThickness
    let bottomMargin: CGFloat = 40
    let maxScreenH = fh - spec.deviceTopOffset - bottomMargin - bezel * 2
    let screenW = min(spec.deviceWidth - bezel * 2, maxScreenH / rawAspect)
    let screenH = screenW * rawAspect
    let deviceW = screenW + bezel * 2
    let deviceH = screenH + bezel * 2

    let deviceX = (fw - deviceW) / 2
    let deviceTopY = fh - spec.deviceTopOffset // y-up coordinate of device top
    let deviceRect = CGRect(x: deviceX, y: deviceTopY - deviceH, width: deviceW, height: deviceH)
    let screenRect = deviceRect.insetBy(dx: bezel, dy: bezel)
    let outerRadius = spec.screenCornerRadius + bezel * 0.85

    // Deep realistic drop shadow
    ctx.saveGState()
    ctx.setShadow(
        offset: CGSize(width: 0, height: -28),
        blur: 76,
        color: rgb(0x000000, alpha: slide.palette.isDark ? 0.65 : 0.28)
    )
    ctx.setFillColor(rgb(0x161514))
    ctx.addPath(roundedRectPath(deviceRect, radius: outerRadius))
    ctx.fillPath()
    ctx.restoreGState()

    // Titanium outer chassis rim
    let chassisGrad = CGGradient(
        colorsSpace: colorSpace,
        colors: [rgb(0x3A3632), rgb(0x1E1C1A), rgb(0x2D2A27)] as CFArray,
        locations: [0.0, 0.5, 1.0]
    )!
    ctx.saveGState()
    ctx.addPath(roundedRectPath(deviceRect, radius: outerRadius))
    ctx.clip()
    ctx.drawLinearGradient(
        chassisGrad,
        start: CGPoint(x: deviceRect.minX, y: deviceRect.maxY),
        end: CGPoint(x: deviceRect.maxX, y: deviceRect.minY),
        options: []
    )
    ctx.restoreGState()

    // Inner black glass bezel
    let innerBezelRect = deviceRect.insetBy(dx: 7, dy: 7)
    ctx.setFillColor(rgb(0x090909))
    ctx.addPath(roundedRectPath(innerBezelRect, radius: outerRadius - 6))
    ctx.fillPath()

    // Clipped raw screenshot
    ctx.saveGState()
    ctx.addPath(roundedRectPath(screenRect, radius: spec.screenCornerRadius))
    ctx.clip()
    ctx.interpolationQuality = .high
    ctx.draw(cgRaw, in: screenRect)
    ctx.restoreGState()

    // Subtle specular rim stroke on outer chassis
    ctx.saveGState()
    ctx.addPath(roundedRectPath(deviceRect.insetBy(dx: 1.5, dy: 1.5), radius: outerRadius - 1.5))
    ctx.setStrokeColor(rgb(0xFFFFFF, alpha: slide.palette.isDark ? 0.16 : 0.22))
    ctx.setLineWidth(3)
    ctx.strokePath()
    ctx.restoreGState()

    // 5. Write opaque PNG
    guard let outImage = ctx.makeImage(),
          let png = NSBitmapImageRep(cgImage: outImage).representation(using: .png, properties: [:]) else {
        throw NSError(domain: "make-screenshots", code: 3, userInfo: [NSLocalizedDescriptionKey: "Cannot encode PNG"])
    }
    try FileManager.default.createDirectory(at: outURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try png.write(to: outURL)
    print("Wrote \(outURL.path) (\(w)×\(h))")
}

let args = CommandLine.arguments
guard args.count == 3 else {
    fputs("Usage: swift scripts/make-screenshots.swift <raw-dir> <output-dir>\n", stderr)
    exit(2)
}

let rawRoot = URL(fileURLWithPath: args[1], isDirectory: true)
let outRoot = URL(fileURLWithPath: args[2], isDirectory: true)

var rendered = 0
for spec in [DeviceSpec.iphone, DeviceSpec.ipad] {
    let rawDir = rawRoot.appendingPathComponent(spec.folder, isDirectory: true)
    guard FileManager.default.fileExists(atPath: rawDir.path) else { continue }
    let outDir = outRoot.appendingPathComponent(spec.folder, isDirectory: true)
    for slide in slides {
        let rawURL = rawDir.appendingPathComponent(slide.file)
        guard FileManager.default.fileExists(atPath: rawURL.path) else { continue }
        try drawSlide(slide, rawURL: rawURL, outURL: outDir.appendingPathComponent(slide.file), spec: spec)
        rendered += 1
    }
}

if rendered == 0 {
    fputs("No raw screenshots found under \(rawRoot.path)\n", stderr)
    exit(1)
}
print("Done: \(rendered) framed screenshots generated.")
