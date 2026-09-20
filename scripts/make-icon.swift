#!/usr/bin/env swift
//
// make-icon.swift
//
// Renders the Chatbridge macOS app icon at 1024x1024 and
// downsamples it to every size required by AppIcon.appiconset.
//
// Usage:
//   DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
//     xcrun swift scripts/make-icon.swift [output-directory]
//
// (Plain `swift` may resolve to the Command Line Tools toolchain, which
// can behave differently for AppKit/CoreGraphics text & color APIs, so
// always pin DEVELOPER_DIR to a full Xcode install when running this.)
//
// Design: a macOS "squircle" (rounded rect, ~22.37% corner radius) filled
// with a vertical green -> teal gradient, a soft drop shadow, and two
// overlapping white speech bubbles connected by three small dots to
// suggest a bridge between chat apps and Siri/Spotlight.

import AppKit
import CoreGraphics
import Foundation

// MARK: - Output configuration

let outputDir: String = {
    let args = CommandLine.arguments
    if args.count > 1 {
        return args[1]
    }
    // Default: the app asset catalog, relative to this script's
    // location in <repo>/scripts/make-icon.swift.
    let scriptURL = URL(fileURLWithPath: args[0])
    let scriptsDir = scriptURL.deletingLastPathComponent()
    let repoRoot = scriptsDir.deletingLastPathComponent()
    return repoRoot
        .appendingPathComponent("app/Chatbridge/Assets.xcassets/AppIcon.appiconset")
        .path
}()

let fm = FileManager.default
if !fm.fileExists(atPath: outputDir) {
    try! fm.createDirectory(atPath: outputDir, withIntermediateDirectories: true)
}

// MARK: - Drawing

let canvasSize = 1024.0

/// Draws the full Chatbridge icon into a CGContext of size `canvasSize` x `canvasSize`.
func drawIcon(in ctx: CGContext) {
    ctx.saveGState()

    // Transparent background (do nothing — context starts clear).

    // --- Squircle geometry -------------------------------------------------
    // ~824 x 824 square centered in the 1024 canvas, ~22.37% corner radius,
    // matching the standard macOS Big Sur+ icon proportions.
    let squircleSide = 824.0
    let margin = (canvasSize - squircleSide) / 2.0 // 100
    let squircleRect = CGRect(x: margin, y: margin, width: squircleSide, height: squircleSide)
    let cornerRadius = squircleSide * 0.2237 // ~184.3

    let squirclePath = CGPath(
        roundedRect: squircleRect,
        cornerWidth: cornerRadius,
        cornerHeight: cornerRadius,
        transform: nil
    )

    // --- Soft drop shadow ----------------------------------------------------
    // Fill the squircle once with a shadow enabled (and a fully transparent
    // fill) so only the shadow lands on the canvas; the real gradient fill
    // is drawn on top afterwards with no shadow.
    ctx.saveGState()
    ctx.setShadow(
        offset: CGSize(width: 0, height: -14),
        blur: 36,
        color: NSColor.black.withAlphaComponent(0.35).cgColor
    )
    ctx.addPath(squirclePath)
    ctx.setFillColor(NSColor.black.cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    // --- Background gradient (fresh green -> teal, vertical) -----------------
    ctx.saveGState()
    ctx.addPath(squirclePath)
    ctx.clip()

    let green = NSColor(calibratedRed: 0x34 / 255.0, green: 0xC7 / 255.0, blue: 0x59 / 255.0, alpha: 1.0)
    let teal = NSColor(calibratedRed: 0x0F / 255.0, green: 0xA3 / 255.0, blue: 0xA3 / 255.0, alpha: 1.0)

    let colors = [green.cgColor, teal.cgColor] as CFArray
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: [0.0, 1.0])!

    // Top of squircle -> bottom of squircle (y-up coordinate system).
    ctx.drawLinearGradient(
        gradient,
        start: CGPoint(x: canvasSize / 2, y: squircleRect.maxY),
        end: CGPoint(x: canvasSize / 2, y: squircleRect.minY),
        options: []
    )
    ctx.restoreGState()

    // --- Foreground: two overlapping speech bubbles + connector dots --------
    let white = NSColor.white.cgColor

    // Large bubble (bottom-left), with a small tail.
    let bubble1Rect = CGRect(x: 300, y: 360, width: 430, height: 270)
    let bubble1Radius = 78.0
    let bubble1Path = CGMutablePath()
    bubble1Path.addRoundedRect(in: bubble1Rect, cornerWidth: bubble1Radius, cornerHeight: bubble1Radius)

    // Tail for bubble 1: a small rounded triangle pointing down-left from
    // the bubble's bottom-left region, overlapping the bubble so the two
    // shapes read as one continuous speech bubble.
    let tail1 = CGMutablePath()
    tail1.move(to: CGPoint(x: 372, y: 392))
    tail1.addLine(to: CGPoint(x: 300, y: 300))
    tail1.addLine(to: CGPoint(x: 430, y: 388))
    tail1.closeSubpath()

    // Small bubble (upper-right), overlapping bubble 1's top-right corner.
    let bubble2Rect = CGRect(x: 560, y: 560, width: 310, height: 200)
    let bubble2Radius = 58.0
    let bubble2Path = CGMutablePath()
    bubble2Path.addRoundedRect(in: bubble2Rect, cornerWidth: bubble2Radius, cornerHeight: bubble2Radius)

    ctx.saveGState()
    ctx.setFillColor(white)
    // Slight shadow under the bubbles for depth/separation from the background.
    ctx.setShadow(
        offset: CGSize(width: 0, height: -6),
        blur: 14,
        color: NSColor.black.withAlphaComponent(0.18).cgColor
    )
    ctx.addPath(tail1)
    ctx.addPath(bubble1Path)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.setFillColor(white)
    ctx.setShadow(
        offset: CGSize(width: 0, height: -6),
        blur: 14,
        color: NSColor.black.withAlphaComponent(0.18).cgColor
    )
    ctx.addPath(bubble2Path)
    ctx.fillPath()
    ctx.restoreGState()

    // Connector dots: three small white dots bridging the gap between the
    // two bubbles' inner corners, suggesting a link/bridge.
    let dotCenters: [(CGPoint, CGFloat)] = [
        (CGPoint(x: 505, y: 470), 26),
        (CGPoint(x: 555, y: 505), 20),
        (CGPoint(x: 598, y: 538), 15),
    ]
    ctx.setFillColor(white)
    for (center, radius) in dotCenters {
        let dotRect = CGRect(
            x: center.x - radius, y: center.y - radius,
            width: radius * 2, height: radius * 2
        )
        ctx.addEllipse(in: dotRect)
    }
    ctx.fillPath()

    ctx.restoreGState()
}

/// Renders the icon at `size` x `size` pixels and returns PNG data.
func renderPNG(size: Int) -> Data {
    let width = size
    let height = size
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        fatalError("Failed to create CGContext for size \(size)")
    }

    // Scale so the drawing code (written in 1024x1024 space) fills this
    // context regardless of its pixel size.
    let scale = CGFloat(size) / CGFloat(canvasSize)
    ctx.scaleBy(x: scale, y: scale)

    drawIcon(in: ctx)

    guard let cgImage = ctx.makeImage() else {
        fatalError("Failed to make CGImage for size \(size)")
    }

    let bitmapRep = NSBitmapImageRep(cgImage: cgImage)
    guard let pngData = bitmapRep.representation(using: .png, properties: [:]) else {
        fatalError("Failed to encode PNG for size \(size)")
    }
    return pngData
}

// MARK: - Emit all required sizes

struct IconSlot {
    let filename: String
    let pixelSize: Int
}

let slots: [IconSlot] = [
    IconSlot(filename: "icon_16x16.png", pixelSize: 16),
    IconSlot(filename: "icon_16x16@2x.png", pixelSize: 32),
    IconSlot(filename: "icon_32x32.png", pixelSize: 32),
    IconSlot(filename: "icon_32x32@2x.png", pixelSize: 64),
    IconSlot(filename: "icon_128x128.png", pixelSize: 128),
    IconSlot(filename: "icon_128x128@2x.png", pixelSize: 256),
    IconSlot(filename: "icon_256x256.png", pixelSize: 256),
    IconSlot(filename: "icon_256x256@2x.png", pixelSize: 512),
    IconSlot(filename: "icon_512x512.png", pixelSize: 512),
    IconSlot(filename: "icon_512x512@2x.png", pixelSize: 1024),
]

// Render each distinct pixel size once, then copy to every filename that
// needs it (16, 32, 64, 128, 256, 512, 1024 are all required at least once).
var cache: [Int: Data] = [:]
for slot in slots {
    let data: Data
    if let cached = cache[slot.pixelSize] {
        data = cached
    } else {
        data = renderPNG(size: slot.pixelSize)
        cache[slot.pixelSize] = data
    }
    let outURL = URL(fileURLWithPath: outputDir).appendingPathComponent(slot.filename)
    try! data.write(to: outURL)
    print("Wrote \(outURL.path) (\(slot.pixelSize)x\(slot.pixelSize))")
}

print("Done. \(slots.count) PNGs written to \(outputDir)")
