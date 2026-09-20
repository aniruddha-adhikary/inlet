#!/usr/bin/env swift
//
// make-icon.swift
//
// Renders the Inlet macOS app icon at 1024x1024 and
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
// with a vertical green -> teal gradient, a soft drop shadow, and a white
// arrow flowing into an open tray: content from your apps
// arriving on this Mac for Siri and Spotlight.

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
        .appendingPathComponent("app/Inlet/Assets.xcassets/AppIcon.appiconset")
        .path
}()

let fm = FileManager.default
if !fm.fileExists(atPath: outputDir) {
    try! fm.createDirectory(atPath: outputDir, withIntermediateDirectories: true)
}

// MARK: - Drawing

let canvasSize = 1024.0

/// Draws the full Inlet icon into a CGContext of size `canvasSize` x `canvasSize`.
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

    // --- Foreground: an arrow flowing into an open tray (content coming in) --
    // Deliberately says nothing about what kind of content: Inlet is not only for chats.
    let mark = CGMutablePath()
    // Tray: an open-topped container.
    mark.move(to: CGPoint(x: 292, y: 500))
    mark.addLine(to: CGPoint(x: 292, y: 372))
    mark.addQuadCurve(to: CGPoint(x: 372, y: 292), control: CGPoint(x: 292, y: 292))
    mark.addLine(to: CGPoint(x: 652, y: 292))
    mark.addQuadCurve(to: CGPoint(x: 732, y: 372), control: CGPoint(x: 732, y: 292))
    mark.addLine(to: CGPoint(x: 732, y: 500))
    // Arrow: shaft and head, pointing down into the tray.
    mark.move(to: CGPoint(x: 512, y: 772))
    mark.addLine(to: CGPoint(x: 512, y: 452))
    mark.move(to: CGPoint(x: 392, y: 572))
    mark.addLine(to: CGPoint(x: 512, y: 452))
    mark.addLine(to: CGPoint(x: 632, y: 572))

    ctx.saveGState()
    ctx.setStrokeColor(NSColor.white.cgColor)
    ctx.setLineWidth(68)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.setShadow(
        offset: CGSize(width: 0, height: -6),
        blur: 14,
        color: NSColor.black.withAlphaComponent(0.18).cgColor
    )
    ctx.addPath(mark)
    ctx.strokePath()
    ctx.restoreGState()

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
