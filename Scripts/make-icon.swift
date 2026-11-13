#!/usr/bin/env swift
import AppKit
import Foundation

guard CommandLine.arguments.count > 1 else {
    fputs("Usage: make-icon.swift <output.icns>\n", stderr)
    exit(1)
}

let outputICNS = URL(fileURLWithPath: CommandLine.arguments[1])
let tempIconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ScholarOS-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: tempIconset, withIntermediateDirectories: true)

func renderIcon(pixelSize: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixelSize,
        pixelsHigh: pixelSize,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(pixelSize)
    let rect = NSRect(x: 0, y: 0, width: s, height: s)

    // Library Forest Green squircle (#1D4D3E)
    let pad = s * 0.08
    let card = rect.insetBy(dx: pad, dy: pad)
    let bgPath = NSBezierPath(roundedRect: card, xRadius: s * 0.21, yRadius: s * 0.21)
    NSColor(calibratedRed: 0.114, green: 0.302, blue: 0.243, alpha: 1.0).setFill()
    bgPath.fill()

    // Cambridge Linen Folio Page (#F8F6F0)
    let page = card.insetBy(dx: s * 0.14, dy: s * 0.12)
    let pagePath = NSBezierPath(roundedRect: page, xRadius: s * 0.05, yRadius: s * 0.05)
    NSColor(calibratedRed: 0.973, green: 0.965, blue: 0.941, alpha: 1.0).setFill()
    pagePath.fill()

    // Brass / Ochre bookmark ribbon & manuscript lines
    let ribbon = NSRect(x: page.maxX - s * 0.11, y: page.maxY - s * 0.18, width: s * 0.055, height: s * 0.18)
    NSColor(calibratedRed: 0.765, green: 0.545, blue: 0.180, alpha: 1.0).setFill()
    NSBezierPath(rect: ribbon).fill()

    NSColor(calibratedRed: 0.114, green: 0.302, blue: 0.243, alpha: 0.82).setFill()
    for i in 0..<4 {
        let y = page.maxY - s * (0.24 + CGFloat(i) * 0.10)
        let w = i == 3 ? page.width * 0.50 : page.width * 0.72
        let line = NSRect(x: page.minX + s * 0.07, y: y, width: w, height: max(2.0, s * 0.032))
        NSBezierPath(roundedRect: line, xRadius: s * 0.015, yRadius: s * 0.015).fill()
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let specs: [(String, Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024)
]

for (name, px) in specs {
    try renderIcon(pixelSize: px).write(to: tempIconset.appendingPathComponent(name))
}

let proc = Process()
proc.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
proc.arguments = ["-c", "icns", tempIconset.path, "-o", outputICNS.path]
try proc.run()
proc.waitUntilExit()
try? FileManager.default.removeItem(at: tempIconset)
exit(proc.terminationStatus)
