import AppKit

private func color(_ red: Int, _ green: Int, _ blue: Int, alpha: CGFloat = 1) -> NSColor {
    NSColor(calibratedRed: CGFloat(red) / 255, green: CGFloat(green) / 255,
            blue: CGFloat(blue) / 255, alpha: alpha)
}

private func roundedRect(_ rect: NSRect, radius: CGFloat) -> NSBezierPath {
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
}

private func playTriangle(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat,
                          fill: NSColor) {
    let path = NSBezierPath()
    path.move(to: NSPoint(x: x, y: y))
    path.line(to: NSPoint(x: x, y: y + height))
    path.line(to: NSPoint(x: x + width, y: y + height / 2))
    path.close()
    fill.setFill()
    path.fill()
}

private func renderIcon(size: Int) throws -> Data {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        throw NSError(domain: "MP4MergeIcon", code: 1)
    }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    let scale = NSAffineTransform()
    scale.scale(by: CGFloat(size) / 1024)
    scale.concat()

    let tile = roundedRect(NSRect(x: 64, y: 64, width: 896, height: 896), radius: 205)
    NSGradient(starting: color(36, 99, 80), ending: color(14, 38, 34))!
        .draw(in: tile, angle: 115)

    let glow = roundedRect(NSRect(x: 93, y: 93, width: 838, height: 838), radius: 185)
    color(144, 235, 185, alpha: 0.16).setStroke()
    glow.lineWidth = 9
    glow.stroke()

    let back = roundedRect(NSRect(x: 150, y: 395, width: 514, height: 356), radius: 75)
    color(34, 78, 69).setFill()
    back.fill()
    color(116, 205, 165).setStroke()
    back.lineWidth = 27
    back.stroke()
    playTriangle(x: 286, y: 511, width: 101, height: 124,
                 fill: color(182, 242, 206))

    let shadow = NSShadow()
    shadow.shadowColor = color(0, 12, 9, alpha: 0.38)
    shadow.shadowBlurRadius = 36
    shadow.shadowOffset = NSSize(width: 0, height: -21)
    NSGraphicsContext.current?.saveGraphicsState()
    shadow.set()
    let front = roundedRect(NSRect(x: 357, y: 266, width: 519, height: 408), radius: 80)
    color(28, 65, 56).setFill()
    front.fill()
    NSGraphicsContext.current?.restoreGraphicsState()

    color(168, 246, 200).setStroke()
    front.lineWidth = 30
    front.stroke()
    playTriangle(x: 544, y: 365, width: 160, height: 208,
                 fill: color(244, 255, 247))

    context.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
    guard let data = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "MP4MergeIcon", code: 2)
    }
    return data
}

private func appendLength(_ value: Int, to data: inout Data) {
    var bigEndian = UInt32(value).bigEndian
    withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
}

let variants: [(String, Int)] = [
    ("icp4", 16), ("icp5", 32), ("icp6", 64),
    ("ic07", 128), ("ic08", 256), ("ic09", 512), ("ic10", 1024)
]
var chunks = Data()
for (type, size) in variants {
    let png = try renderIcon(size: size)
    chunks.append(contentsOf: type.utf8)
    appendLength(png.count + 8, to: &chunks)
    chunks.append(png)
}
var icon = Data("icns".utf8)
appendLength(chunks.count + 8, to: &icon)
icon.append(chunks)
try icon.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
