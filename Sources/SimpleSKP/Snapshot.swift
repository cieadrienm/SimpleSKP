import AppKit
import SimpleSKPCore
import SimpleSKPViewport
import SwiftUI

/// `SimpleSKP --snapshot out.png [file.skp]`: the model window with the 3D, as a PNG, without a screen.
/// `cacheDisplay` does not see Metal, so the viewport's own `snapshot()` is drawn over its frame (D11).
@MainActor
enum Snapshot {
    static let size = CGSize(width: 1380, height: 820)

    /// The window composed offscreen, and the viewport's rectangle in the image's pixels (top-left origin).
    static func render(model: DocumentModel) -> (rep: NSBitmapImageRep, viewportRect: CGRect)? {
        let window = NSWindow(
            contentRect: CGRect(origin: CGPoint(x: -20_000, y: -20_000), size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = Theme.background
        window.isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: ContentView(model: model))
        hosting.frame = CGRect(origin: .zero, size: size)
        window.contentView = hosting
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        hosting.layoutSubtreeIfNeeded()
        hosting.displayIfNeeded()

        let bounds = hosting.bounds
        guard bounds.width > 1, let rep = hosting.bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        hosting.cacheDisplay(in: bounds, to: rep)

        var frame = model.viewport.convert(model.viewport.bounds, to: hosting)   // top-left origin when flipped
        if !hosting.isFlipped { frame.origin.y = bounds.height - frame.maxY }
        guard frame.width > 1, frame.height > 1 else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let drawRect = CGRect(x: frame.minX, y: bounds.height - frame.maxY, width: frame.width, height: frame.height)
        model.viewport.snapshot().draw(in: drawRect)
        NSGraphicsContext.restoreGraphicsState()

        let scale = CGFloat(rep.pixelsWide) / bounds.width
        let pixels = CGRect(x: frame.minX * scale, y: frame.minY * scale, width: frame.width * scale, height: frame.height * scale)
        return (rep, pixels)
    }

    static func png(of image: NSImage) -> Data? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:])
    }

    /// Something besides the background was drawn: on a 48 × 48 grid, at least 8 samples differ from the most
    /// frequent colour (flat-shaded models give few colours; a far camera leaves the model a few % of the view).
    static func isNonUniform(_ rep: NSBitmapImageRep, in rect: CGRect? = nil) -> Bool {
        let area = rect ?? CGRect(x: 0, y: 0, width: rep.pixelsWide, height: rep.pixelsHigh)
        let grid = 48
        var counts: [UInt32: Int] = [:]
        for row in 0..<grid {
            for column in 0..<grid {
                let x = Int(area.minX + area.width * (CGFloat(column) + 0.5) / CGFloat(grid))
                let y = Int(area.minY + area.height * (CGFloat(row) + 0.5) / CGFloat(grid))
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                counts[UInt32(c.redComponent * 63) << 12 | UInt32(c.greenComponent * 63) << 6 | UInt32(c.blueComponent * 63), default: 0] += 1
            }
        }
        let total = counts.values.reduce(0, +)
        return total - (counts.values.max() ?? total) >= 8
    }

    static func isNonUniform(_ image: NSImage) -> Bool {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return false }
        return isNonUniform(NSBitmapImageRep(cgImage: cgImage))
    }

    static func run(output: String, input: String?) -> Never {
        let model = DocumentModel()
        do {
            let start = Date()
            let skp = try input.map { try SKPReader.load(URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath)) } ?? SyntheticModel.cube()
            model.info = skp.fileInfo
            let scene = ViewportScene(model: skp)
            model.present(scene, seconds: Date().timeIntervalSince(start))
        } catch {
            fputs("snapshot error: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
        guard let (rep, viewportRect) = render(model: model), let png = rep.representation(using: .png, properties: [:]) else {
            fputs("snapshot error: failed to render PNG\n", stderr)
            exit(1)
        }
        let url = URL(fileURLWithPath: (output as NSString).expandingTildeInPath)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try png.write(to: url, options: .atomic)
            // Written first so a blank result can still be looked at.
            guard isNonUniform(rep, in: viewportRect) else {
                fputs("snapshot error: the 3D viewport of \(url.path) is uniform (nothing drawn)\n", stderr)
                exit(1)
            }
            print("Snapshot written to \(url.path) (\(png.count) bytes)")
            exit(0)
        } catch {
            fputs("snapshot error: \(error)\n", stderr)
            exit(1)
        }
    }
}
