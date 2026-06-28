#!/usr/bin/env swift
//
// Renders the DMG background: a calm near-white canvas with a single soft arrow
// pointing from the app toward the Applications folder. Drawn at 2x (1320×800)
// for a 660×400 Finder window. Core Graphics / ImageIO only, so it runs headless.
//
// Usage: swift scripts/generate-dmg-background.swift <output.png>
//
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let outputPath = CommandLine.arguments.dropFirst().first ?? "dmg-background.png"
let width = 1320
let height = 800

let colorSpace = CGColorSpaceCreateDeviceRGB()
guard let ctx = CGContext(
    data: nil, width: width, height: height,
    bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else { fatalError("Could not create context") }

let w = CGFloat(width)
let h = CGFloat(height)

// Soft vertical gradient background (near-white, very low contrast).
let top = CGColor(red: 0.985, green: 0.987, blue: 0.992, alpha: 1)
let bottom = CGColor(red: 0.945, green: 0.953, blue: 0.965, alpha: 1)
if let gradient = CGGradient(colorsSpace: colorSpace, colors: [top, bottom] as CFArray, locations: [0, 1]) {
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: h), end: CGPoint(x: 0, y: 0), options: [])
}

// A single light-grey arrow pointing right, centered between the two icons.
// Icons sit at Finder window points (165,185) and (495,185) -> 2x pixels,
// measured from the top, so the vertical centre in CG coords is h - 185*2.
let centerY = h - 370
let arrowColor = CGColor(red: 0.74, green: 0.77, blue: 0.81, alpha: 1)
ctx.setFillColor(arrowColor)
ctx.setStrokeColor(arrowColor)

let shaftStart: CGFloat = 565
let shaftEnd: CGFloat = 735
let shaftThickness: CGFloat = 20
let shaft = CGRect(x: shaftStart, y: centerY - shaftThickness / 2,
                   width: shaftEnd - shaftStart, height: shaftThickness)
ctx.fill(shaft)

// Arrowhead.
let headTip: CGFloat = 790
let headHalf: CGFloat = 42
ctx.beginPath()
ctx.move(to: CGPoint(x: headTip, y: centerY))
ctx.addLine(to: CGPoint(x: shaftEnd, y: centerY + headHalf))
ctx.addLine(to: CGPoint(x: shaftEnd, y: centerY - headHalf))
ctx.closePath()
ctx.fillPath()

guard let image = ctx.makeImage() else { fatalError("Could not render image") }
let url = URL(fileURLWithPath: outputPath)
guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
    fatalError("Could not create PNG destination")
}
CGImageDestinationAddImage(dest, image, nil)
guard CGImageDestinationFinalize(dest) else { fatalError("Could not write PNG") }
print("Wrote \(outputPath)")
