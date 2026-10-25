// Draws the SimpleSKP app icon and writes Resources/AppIcon.icns. Usage: swift Scripts/make-icon.swift
import AppKit

func color(_ hex: Int, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xff) / 255,
        green: CGFloat((hex >> 8) & 0xff) / 255,
        blue: CGFloat(hex & 0xff) / 255,
        alpha: alpha
    )
}

func drawIcon(size: Int) -> Data {
    let s = CGFloat(size) / 1024
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(
        data: nil,
        width: size,
        height: size,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    ctx.scaleBy(x: s, y: s)

    // macOS icon grid: 824 pt rounded square centred in 1024
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: body, cornerWidth: 186, cornerHeight: 186, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12 * s), blur: 28 * s, color: color(0x000000, 0.48))
    ctx.addPath(shape)
    ctx.setFillColor(color(0x14171C))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    let bg = CGGradient(colorsSpace: space, colors: [color(0x222731), color(0x0E1014)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: 924), end: CGPoint(x: 0, y: 100), options: [])

    // Isometric cube (2:1 hexagon, the family's iso angle), centred on the tile
    let c = CGPoint(x: 512, y: 512)
    let r: CGFloat = 270
    let dx = r * 0.8660254, dy = r / 2
    let top = CGPoint(x: c.x, y: c.y + r), bottom = CGPoint(x: c.x, y: c.y - r)
    let ur = CGPoint(x: c.x + dx, y: c.y + dy), ul = CGPoint(x: c.x - dx, y: c.y + dy)
    let lr = CGPoint(x: c.x + dx, y: c.y - dy), ll = CGPoint(x: c.x - dx, y: c.y - dy)
    // Faint white faces: top lightest, then right, then left
    for (pts, alpha) in [([top, ur, c, ul], 0.10), ([c, ur, lr, bottom], 0.075), ([ul, c, bottom, ll], 0.05)] as [([CGPoint], CGFloat)] {
        ctx.addLines(between: pts)
        ctx.closePath()
        ctx.setFillColor(color(0xFFFFFF, alpha))
        ctx.fillPath()
    }
    ctx.setLineWidth(22)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    // One hidden edge, dashed cyan: the hint of 3D
    ctx.setStrokeColor(color(0x5CE1E6))
    ctx.setLineDash(phase: 0, lengths: [2, 46])
    ctx.move(to: c)
    ctx.addLine(to: top)
    ctx.strokePath()
    ctx.setLineDash(phase: 0, lengths: [])
    // Silhouette and the three visible edges, amber
    ctx.setStrokeColor(color(0xFFB454))
    ctx.addLines(between: [top, ur, lr, bottom, ll, ul])
    ctx.closePath()
    ctx.move(to: c); ctx.addLine(to: ul)
    ctx.move(to: c); ctx.addLine(to: ur)
    ctx.move(to: c); ctx.addLine(to: bottom)
    ctx.strokePath()

    ctx.restoreGState()
    let image = ctx.makeImage()!
    let rep = NSBitmapImageRep(cgImage: image)
    return rep.representation(using: .png, properties: [:])!
}

let fm = FileManager.default
let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
let resources = root.appendingPathComponent("Resources")
let iconset = fm.temporaryDirectory.appendingPathComponent("SimpleSKP-\(UUID().uuidString).iconset")
try! fm.createDirectory(at: iconset, withIntermediateDirectories: true)
try! fm.createDirectory(at: resources, withIntermediateDirectories: true)
for (name, size) in [
    ("16x16", 16), ("16x16@2x", 32),
    ("32x32", 32), ("32x32@2x", 64),
    ("128x128", 128), ("128x128@2x", 256),
    ("256x256", 256), ("256x256@2x", 512),
    ("512x512", 512), ("512x512@2x", 1024),
] {
    try! drawIcon(size: size).write(to: iconset.appendingPathComponent("icon_\(name).png"))
}
try! drawIcon(size: 1024).write(to: resources.appendingPathComponent("AppIcon.png"))
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", resources.appendingPathComponent("AppIcon.icns").path]
try! task.run()
task.waitUntilExit()
try? fm.removeItem(at: iconset)
print(task.terminationStatus == 0 ? "wrote \(resources.path)/AppIcon.icns" : "iconutil failed")
exit(task.terminationStatus)
