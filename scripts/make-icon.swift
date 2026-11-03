// Generates Resources/hdlanes.icns: a dark graphite rounded square (Big Sur grid) with three
// parallel lanes filled to different heights, like progress.
//
//   swift scripts/make-icon.swift Resources/hdlanes.icns
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources/hdlanes.icns"

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: r, green: g, blue: b, alpha: a)
}

/// Draws the icon into a `size`×`size` context. Geometry is designed on a 1024 canvas.
func render(size: Int) -> CGImage {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let s = CGFloat(size) / 1024
    ctx.scaleBy(x: s, y: s)
    ctx.interpolationQuality = .high

    // Big Sur grid: 824×824 body centered on the 1024 canvas, ~22.5% corner radius.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)

    // Soft drop shadow under the body.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: rgb(0, 0, 0, 0.35))
    ctx.addPath(shape)
    ctx.setFillColor(rgb(0.16, 0.17, 0.19))
    ctx.fillPath()
    ctx.restoreGState()

    // Graphite body with a subtle vertical gradient (lighter at the top).
    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    let gradient = CGGradient(colorsSpace: space,
                              colors: [rgb(0.235, 0.245, 0.270), rgb(0.120, 0.126, 0.142)] as CFArray,
                              locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])

    // Three lanes: a faint full-height track, filled from the bottom in the lane's color.
    let lanes: [(color: CGColor, fill: CGFloat)] = [
        (rgb(0.43, 0.50, 0.96), 0.64),  // indigo
        (rgb(0.22, 0.74, 0.66), 0.90),  // teal
        (rgb(0.96, 0.71, 0.29), 0.42),  // amber
    ]
    let barWidth: CGFloat = 150, gap: CGFloat = 78
    let totalWidth = barWidth * 3 + gap * 2
    let bottom: CGFloat = 238, top: CGFloat = 786
    for (i, lane) in lanes.enumerated() {
        let x = 512 - totalWidth / 2 + CGFloat(i) * (barWidth + gap)
        let track = CGRect(x: x, y: bottom, width: barWidth, height: top - bottom)
        ctx.addPath(CGPath(roundedRect: track, cornerWidth: barWidth / 2, cornerHeight: barWidth / 2, transform: nil))
        ctx.setFillColor(rgb(1, 1, 1, 0.07))
        ctx.fillPath()
        let height = max(barWidth, (top - bottom) * lane.fill)
        let filled = CGRect(x: x, y: bottom, width: barWidth, height: height)
        ctx.addPath(CGPath(roundedRect: filled, cornerWidth: barWidth / 2, cornerHeight: barWidth / 2, transform: nil))
        ctx.setFillColor(lane.color)
        ctx.fillPath()
    }
    ctx.restoreGState()

    // Hairline edge so the body reads on dark backgrounds.
    ctx.addPath(CGPath(roundedRect: body.insetBy(dx: 1.5, dy: 1.5), cornerWidth: 184, cornerHeight: 184, transform: nil))
    ctx.setStrokeColor(rgb(1, 1, 1, 0.10))
    ctx.setLineWidth(3)
    ctx.strokePath()

    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) throws {
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        throw CocoaError(.fileWriteUnknown)
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
}

let fm = FileManager.default
let iconset = fm.temporaryDirectory.appendingPathComponent("hdlanes-\(UUID().uuidString).iconset")
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: iconset) }

for base in [16, 32, 128, 256, 512] {
    try writePNG(render(size: base), to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try writePNG(render(size: base * 2), to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}

let outURL = URL(fileURLWithPath: output)
try fm.createDirectory(at: outURL.deletingLastPathComponent(), withIntermediateDirectories: true)
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", "-o", outURL.path, iconset.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else {
    FileHandle.standardError.write(Data("iconutil failed (\(iconutil.terminationStatus))\n".utf8))
    exit(1)
}
print(outURL.path)
