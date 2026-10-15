// Generates the RDM-ARM app icon as a single 1024x1024 PNG.
// The build script turns it into an .icns with sips + iconutil.
//
//   swift Tools/MakeIcon.swift <output.png>

import AppKit
import CoreGraphics
import Foundation

let outputPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.png"
let size: CGFloat = 1024

guard let context = CGContext(data: nil,
                              width: Int(size),
                              height: Int(size),
                              bitsPerComponent: 8,
                              bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    FileHandle.standardError.write(Data("could not create bitmap context\n".utf8))
    exit(1)
}

// MARK: - Background squircle

let inset = size * 0.045
let backgroundRect = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
let cornerRadius = backgroundRect.width * 0.2237   // macOS icon corner ratio

let background = CGPath(roundedRect: backgroundRect,
                        cornerWidth: cornerRadius,
                        cornerHeight: cornerRadius,
                        transform: nil)
context.saveGState()
context.addPath(background)
context.clip()

let gradientColors = [
    CGColor(red: 0.145, green: 0.278, blue: 0.686, alpha: 1.0),
    CGColor(red: 0.361, green: 0.196, blue: 0.667, alpha: 1.0),
] as CFArray

if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                             colors: gradientColors,
                             locations: [0.0, 1.0]) {
    context.drawLinearGradient(gradient,
                               start: CGPoint(x: backgroundRect.minX, y: backgroundRect.maxY),
                               end: CGPoint(x: backgroundRect.maxX, y: backgroundRect.minY),
                               options: [])
}

// Soft highlight across the top third, for depth.
context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.10))
context.fill(CGRect(x: backgroundRect.minX,
                    y: backgroundRect.midY,
                    width: backgroundRect.width,
                    height: backgroundRect.height / 2))

context.restoreGState()

// MARK: - Monitor

let strokeWidth = size * 0.042
context.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
context.setLineWidth(strokeWidth)
context.setLineCap(.round)
context.setLineJoin(.round)

// Screen bezel
let bezel = CGRect(x: size * 0.150,
                   y: size * 0.315,
                   width: size * 0.700,
                   height: size * 0.430)
context.addPath(CGPath(roundedRect: bezel,
                       cornerWidth: size * 0.055,
                       cornerHeight: size * 0.055,
                       transform: nil))
context.strokePath()

// Stand neck
context.move(to: CGPoint(x: size * 0.500, y: bezel.minY))
context.addLine(to: CGPoint(x: size * 0.500, y: size * 0.225))
context.strokePath()

// Stand base
context.addPath(CGPath(roundedRect: CGRect(x: size * 0.352,
                                           y: size * 0.180,
                                           width: size * 0.296,
                                           height: strokeWidth),
                       cornerWidth: strokeWidth / 2,
                       cornerHeight: strokeWidth / 2,
                       transform: nil))
context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
context.fillPath()

// MARK: - Lightning bolt (the HiDPI marker, inherited from the original RDM)

// Unit-space outline, y increasing downward.
let boltUnit: [(CGFloat, CGFloat)] = [
    (0.60, 0.00),
    (0.26, 0.56),
    (0.46, 0.56),
    (0.36, 1.00),
    (0.74, 0.40),
    (0.52, 0.40),
]

let boltWidth = size * 0.200
let boltHeight = size * 0.250
let boltCenterX = size * 0.500
let boltCenterY = bezel.midY

let bolt = CGMutablePath()
for (index, point) in boltUnit.enumerated() {
    let x = boltCenterX + (point.0 - 0.5) * boltWidth
    let y = boltCenterY - (point.1 - 0.5) * boltHeight
    if index == 0 { bolt.move(to: CGPoint(x: x, y: y)) }
    else { bolt.addLine(to: CGPoint(x: x, y: y)) }
}
bolt.closeSubpath()

context.addPath(bolt)
context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
context.fillPath()

// MARK: - Write PNG

guard let image = context.makeImage() else {
    FileHandle.standardError.write(Data("could not render image\n".utf8))
    exit(1)
}

let url = URL(fileURLWithPath: outputPath)
guard let destination = CGImageDestinationCreateWithURL(url as CFURL,
                                                       "public.png" as CFString,
                                                       1, nil) else {
    FileHandle.standardError.write(Data("could not create PNG destination\n".utf8))
    exit(1)
}
CGImageDestinationAddImage(destination, image, nil)
guard CGImageDestinationFinalize(destination) else {
    FileHandle.standardError.write(Data("could not write PNG\n".utf8))
    exit(1)
}

print("wrote \(outputPath)")
