#!/usr/bin/env swift
// Renders FileFerry's app icon into an .iconset, for iconutil to compile.
//
// Drawn in code rather than checked in as binary PNGs so the icon is
// reviewable in a diff and regenerates at any size.
import AppKit
import CoreGraphics
import Foundation

let sizes = [16, 32, 64, 128, 256, 512, 1024]
let outputDirectory = URL(fileURLWithPath: CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "dist/FileFerry.iconset")

try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

func draw(size: Int) -> Data? {
    let side = CGFloat(size)
    guard let context = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }

    // Rounded-rect background with a vertical gradient.
    let inset = side * 0.06
    let rect = CGRect(x: inset, y: inset, width: side - inset * 2, height: side - inset * 2)
    let radius = rect.width * 0.225
    let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

    context.saveGState()
    context.addPath(path)
    context.clip()
    let gradient = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
        colors: [
            CGColor(red: 0.30, green: 0.55, blue: 0.98, alpha: 1),
            CGColor(red: 0.13, green: 0.30, blue: 0.78, alpha: 1),
        ] as CFArray,
        locations: [0, 1]
    )!
    context.drawLinearGradient(
        gradient,
        start: CGPoint(x: 0, y: side), end: CGPoint(x: 0, y: 0), options: []
    )
    context.restoreGState()

    // Two opposing arrows — the app is bidirectional transfer, and a single
    // arrow would imply one-way sync.
    let barHeight = side * 0.085
    let arrowWidth = side * 0.50
    let headWidth = side * 0.15
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.96))

    func arrow(centerY: CGFloat, pointingRight: Bool) {
        let startX = (side - arrowWidth) / 2
        let endX = startX + arrowWidth
        // The shaft runs right up to the head's base — leaving a gap reads as
        // a rendering bug rather than a style choice.
        let shaft = CGRect(
            x: pointingRight ? startX : startX + headWidth * 0.2,
            y: centerY - barHeight / 2,
            width: arrowWidth - headWidth * 0.2,
            height: barHeight
        )
        context.fill(shaft)

        context.beginPath()
        if pointingRight {
            context.move(to: CGPoint(x: endX + headWidth * 0.35, y: centerY))
            context.addLine(to: CGPoint(x: endX - headWidth * 0.2, y: centerY + headWidth * 0.62))
            context.addLine(to: CGPoint(x: endX - headWidth * 0.2, y: centerY - headWidth * 0.62))
        } else {
            context.move(to: CGPoint(x: startX - headWidth * 0.35, y: centerY))
            context.addLine(to: CGPoint(x: startX + headWidth * 0.2, y: centerY + headWidth * 0.62))
            context.addLine(to: CGPoint(x: startX + headWidth * 0.2, y: centerY - headWidth * 0.62))
        }
        context.closePath()
        context.fillPath()
    }

    arrow(centerY: side * 0.585, pointingRight: true)
    arrow(centerY: side * 0.395, pointingRight: false)

    guard let image = context.makeImage() else { return nil }
    let rep = NSBitmapImageRep(cgImage: image)
    return rep.representation(using: .png, properties: [:])
}

for size in sizes {
    for (suffix, pixels) in [("\(size)x\(size)", size), ("\(size / 2)x\(size / 2)@2x", size)] {
        guard size != 16 || !suffix.contains("@2x") else { continue }
        guard let data = draw(size: pixels) else { continue }
        let name = "icon_\(suffix).png"
        try data.write(to: outputDirectory.appendingPathComponent(name))
    }
}

print("wrote \(outputDirectory.path)")
