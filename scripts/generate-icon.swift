#!/usr/bin/env swift
//
// Renders the MacHole app icon (a calm blue squircle with a white waveform)
// to a 1024×1024 PNG using only Core Graphics / ImageIO, so it runs headless.
//
// Usage: swift scripts/generate-icon.swift <output.png>
//
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let outputPath = CommandLine.arguments.dropFirst().first ?? "AppIcon-1024.png"
let size = 1024

let colorSpace = CGColorSpaceCreateDeviceRGB()
guard let ctx = CGContext(
    data: nil, width: size, height: size,
    bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else { fatalError("Could not create context") }

let dim = CGFloat(size)

// Rounded-rect (squircle-ish) background, full-bleed with a small margin.
let margin = dim * 0.06
let rect = CGRect(x: margin, y: margin, width: dim - 2 * margin, height: dim - 2 * margin)
let radius = rect.width * 0.225
let bg = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

ctx.saveGState()
ctx.addPath(bg)
ctx.clip()

// Soft vertical blue gradient (calm, not neon).
let top = CGColor(red: 0.36, green: 0.55, blue: 0.95, alpha: 1)
let bottom = CGColor(red: 0.20, green: 0.36, blue: 0.78, alpha: 1)
if let gradient = CGGradient(colorsSpace: colorSpace, colors: [top, bottom] as CFArray, locations: [0, 1]) {
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: dim), end: CGPoint(x: 0, y: 0), options: [])
}
ctx.restoreGState()

// White waveform bars, centered, with rounded caps.
let heights: [CGFloat] = [0.30, 0.52, 0.78, 1.00, 0.78, 0.52, 0.30]
let maxBarHeight = dim * 0.46
let barWidth = dim * 0.072
let gap = dim * 0.046
let totalWidth = CGFloat(heights.count) * barWidth + CGFloat(heights.count - 1) * gap
var x = (dim - totalWidth) / 2
let centerY = dim / 2

ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
for fraction in heights {
    let h = maxBarHeight * fraction
    let barRect = CGRect(x: x, y: centerY - h / 2, width: barWidth, height: h)
    let cap = barWidth / 2
    let path = CGPath(roundedRect: barRect, cornerWidth: cap, cornerHeight: cap, transform: nil)
    ctx.addPath(path)
    ctx.fillPath()
    x += barWidth + gap
}

guard let image = ctx.makeImage() else { fatalError("Could not render image") }
let url = URL(fileURLWithPath: outputPath)
guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
    fatalError("Could not create PNG destination")
}
CGImageDestinationAddImage(dest, image, nil)
guard CGImageDestinationFinalize(dest) else { fatalError("Could not write PNG") }
print("Wrote \(outputPath)")
