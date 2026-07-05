// Generates the Rushlight app icon (a warm "rushlight" flame as a play
// triangle on a dark squircle) into an .iconset directory.
//
//   swift Scripts/make_icon.swift /path/to/Rushlight.iconset
//   iconutil -c icns /path/to/Rushlight.iconset -o Support/Rushlight.icns

import AppKit
import Foundation

let args = CommandLine.arguments
guard args.count == 2 else {
    FileHandle.standardError.write(Data("usage: swift make_icon.swift <output.iconset>\n".utf8))
    exit(1)
}
let outDir = URL(fileURLWithPath: args[1], isDirectory: true)
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

func render(pixels: Int) -> Data? {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ) else { return nil }

    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    let s = CGFloat(pixels)
    // macOS icon grid: content sits inside a margin.
    let inset = s * 0.09
    let squircle = NSBezierPath(
        roundedRect: NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2),
        xRadius: s * 0.185, yRadius: s * 0.185
    )
    let background = NSGradient(
        starting: NSColor(calibratedRed: 0.16, green: 0.17, blue: 0.22, alpha: 1),
        ending: NSColor(calibratedRed: 0.05, green: 0.05, blue: 0.08, alpha: 1)
    )
    background?.draw(in: squircle, angle: -90)

    // Warm glow behind the flame.
    squircle.addClip()
    let glowCenter = NSPoint(x: s * 0.52, y: s * 0.5)
    let glow = NSGradient(colors: [
        NSColor(calibratedRed: 1.0, green: 0.55, blue: 0.25, alpha: 0.55),
        NSColor(calibratedRed: 1.0, green: 0.55, blue: 0.25, alpha: 0.0),
    ])
    let glowRadius = s * 0.42
    glow?.draw(
        fromCenter: glowCenter, radius: 0,
        toCenter: glowCenter, radius: glowRadius,
        options: []
    )

    // Play triangle with softly rounded corners, nudged right for optical centering.
    let triangle = NSBezierPath()
    let cx = s * 0.545
    let cy = s * 0.5
    let r = s * 0.235
    let points = (0..<3).map { i -> NSPoint in
        let angle = CGFloat(i) * (2 * .pi / 3)
        return NSPoint(x: cx + r * cos(angle), y: cy + r * sin(angle))
    }
    triangle.move(to: points[0])
    triangle.line(to: points[1])
    triangle.line(to: points[2])
    triangle.close()
    triangle.lineJoinStyle = .round
    triangle.lineWidth = s * 0.07

    let flame = NSGradient(
        starting: NSColor(calibratedRed: 1.0, green: 0.72, blue: 0.28, alpha: 1),
        ending: NSColor(calibratedRed: 1.0, green: 0.38, blue: 0.22, alpha: 1)
    )
    NSColor(calibratedRed: 1.0, green: 0.55, blue: 0.25, alpha: 1).setStroke()
    triangle.stroke()
    flame?.draw(in: triangle, angle: -75)

    return rep.representation(using: .png, properties: [:])
}

let variants: [(name: String, pixels: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

for variant in variants {
    guard let png = render(pixels: variant.pixels) else {
        FileHandle.standardError.write(Data("failed to render \(variant.name)\n".utf8))
        exit(1)
    }
    try png.write(to: outDir.appendingPathComponent("\(variant.name).png"))
}
print("✓ Wrote iconset to \(outDir.path)")
