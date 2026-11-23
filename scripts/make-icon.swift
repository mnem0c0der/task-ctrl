// Draws the app icon and writes it, in every size macOS asks for, to
// TaskCtrl/Resources/Assets.xcassets/AppIcon.appiconset.
//
// usage: swift scripts/make-icon.swift
//
// The icon is a keyboard key with the Control sign on it, for the "Ctrl" in
// the name, and a level meter under the sign, for what the app does.

import AppKit
import CoreGraphics
import Foundation

/// All drawing is done on a 1024-point canvas with the origin at the top
/// left, then scaled to the size being written.
let canvas = 1024.0

func color(_ hex: UInt32, alpha: Double = 1) -> CGColor {
    CGColor(
        red: Double((hex >> 16) & 0xff) / 255,
        green: Double((hex >> 8) & 0xff) / 255,
        blue: Double(hex & 0xff) / 255,
        alpha: alpha
    )
}

func rounded(_ rect: CGRect, _ radius: Double) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

func fill(_ context: CGContext, _ path: CGPath, top: UInt32, bottom: UInt32) {
    context.saveGState()
    context.addPath(path)
    context.clip()
    let gradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [color(top), color(bottom)] as CFArray,
        locations: [0, 1]
    )!
    let box = path.boundingBox
    context.drawLinearGradient(
        gradient,
        start: CGPoint(x: box.midX, y: box.minY),
        end: CGPoint(x: box.midX, y: box.maxY),
        options: []
    )
    context.restoreGState()
}

/// How much of the drawing a size can carry.
enum Detail {
    /// Sign and the nine-segment meter.
    case full
    /// A larger sign over three fat segments.
    case coarse
    /// The sign alone. A single bar under it would read as an eject symbol.
    case bare
}

func draw(in context: CGContext, detail: Detail) {
    // The plate the key sits in: the standard macOS icon shape, 824 points
    // wide on the 1024 canvas, with a soft shadow under it.
    let plate = rounded(CGRect(x: 100, y: 100, width: 824, height: 824), 185)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: 12), blur: 28, color: color(0x000000, alpha: 0.35))
    context.addPath(plate)
    context.setFillColor(color(0x0d0e11))
    context.fillPath()
    context.restoreGState()
    fill(context, plate, top: 0x16181c, bottom: 0x08090b)

    // The key: its side first, a little lower, then the top face.
    let face = CGRect(x: 164, y: 140, width: 696, height: 676)
    fill(context, rounded(face.offsetBy(dx: 0, dy: 36), 138), top: 0x15171b, bottom: 0x0f1013)
    let top = rounded(face, 138)
    fill(context, top, top: 0x343840, bottom: 0x22252b)
    context.addPath(rounded(face.insetBy(dx: 3, dy: 3), 135))
    context.setStrokeColor(color(0xffffff, alpha: 0.13))
    context.setLineWidth(6)
    context.strokePath()

    // The Control sign.
    let apex: CGPoint
    let reach: CGSize
    let weight: Double
    switch detail {
    case .full: (apex, reach, weight) = (CGPoint(x: 512, y: 300), CGSize(width: 150, height: 176), 58)
    case .coarse: (apex, reach, weight) = (CGPoint(x: 512, y: 280), CGSize(width: 176, height: 200), 76)
    case .bare: (apex, reach, weight) = (CGPoint(x: 512, y: 350), CGSize(width: 200, height: 230), 96)
    }
    context.move(to: CGPoint(x: apex.x - reach.width, y: apex.y + reach.height))
    context.addLine(to: apex)
    context.addLine(to: CGPoint(x: apex.x + reach.width, y: apex.y + reach.height))
    context.setStrokeColor(color(0xf4f4f5))
    context.setLineWidth(weight)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.strokePath()

    // The meter: green, then amber, then unlit.
    let green: UInt32 = 0x3ddc68, amber: UInt32 = 0xffd60a
    let segments: (lit: [UInt32], count: Int, width: Double, gap: Double, top: Double, height: Double, radius: Double)
    switch detail {
    case .full: segments = ([green, green, green, green, amber, amber], 9, 38, 13, 600, 104, 11)
    case .coarse: segments = ([green, green, amber], 3, 116, 40, 606, 116, 26)
    case .bare: return
    }
    let span = Double(segments.count) * segments.width + Double(segments.count - 1) * segments.gap
    for index in 0..<segments.count {
        let bar = CGRect(
            x: 512 - span / 2 + Double(index) * (segments.width + segments.gap), y: segments.top,
            width: segments.width, height: segments.height
        )
        context.addPath(rounded(bar, segments.radius))
        context.setFillColor(index < segments.lit.count ? color(segments.lit[index]) : color(0x000000, alpha: 0.38))
        context.fillPath()
    }
}

func png(pixels: Int) -> Data {
    let context = CGContext(
        data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    // Flip to a top-left origin and scale the 1024 canvas to this size.
    let scale = Double(pixels) / canvas
    context.translateBy(x: 0, y: Double(pixels))
    context.scaleBy(x: scale, y: -scale)
    draw(in: context, detail: pixels > 64 ? .full : pixels > 32 ? .coarse : .bare)
    let image = NSBitmapImageRep(cgImage: context.makeImage()!)
    return image.representation(using: .png, properties: [:])!
}

let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let catalog = root.appending(path: "TaskCtrl/Resources/Assets.xcassets")
let iconSet = catalog.appending(path: "AppIcon.appiconset")
try FileManager.default.createDirectory(at: iconSet, withIntermediateDirectories: true)

var images: [[String: String]] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        try png(pixels: points * scale).write(to: iconSet.appending(path: name))
        images.append([
            "idiom": "mac", "size": "\(points)x\(points)", "scale": "\(scale)x", "filename": name,
        ])
    }
}

func write(_ object: [String: Any], to url: URL) throws {
    let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    try (data + Data("\n".utf8)).write(to: url)
}

let info: [String: Any] = ["author": "xcode", "version": 1]
try write(["images": images, "info": info], to: iconSet.appending(path: "Contents.json"))
try write(["info": info], to: catalog.appending(path: "Contents.json"))
print("Wrote \(images.count) images to \(iconSet.path(percentEncoded: false))")
