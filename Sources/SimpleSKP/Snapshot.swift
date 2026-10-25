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
    /// `scene` is presented once the window is laid out, so a model without a saved camera is framed for the real aspect.
    static func render(model: DocumentModel, presenting scene: ViewportScene? = nil, seconds: Double = 0) -> (rep: NSBitmapImageRep, viewportRect: CGRect)? {
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
        if let scene {
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            hosting.layoutSubtreeIfNeeded()
            model.present(scene, seconds: seconds)
            let env = ProcessInfo.processInfo.environment
            if env["SIMPLESKP_SNAPSHOT_LIGHTING"] == "point" {
                model.setLightingMode(.point)
                if let intensity = env["SIMPLESKP_SNAPSHOT_LIGHT_INTENSITY"].flatMap(Float.init) {
                    model.updateSelectedPointLight(intensity: intensity)
                }
            }
            if let bg = env["SIMPLESKP_SNAPSHOT_BG"] {
                let parts = bg.split(separator: ",").compactMap { Float($0.trimmingCharacters(in: .whitespaces)) }
                if parts.count == 3 {
                    model.setCustomBackdropColor(SIMD3(parts[0], parts[1], parts[2]))
                }
            }
            if let ssao = env["SIMPLESKP_SNAPSHOT_SSAO"].flatMap(Float.init) {
                model.setAmbientOcclusionIntensity(ssao)
            }
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        hosting.layoutSubtreeIfNeeded()
        hosting.displayIfNeeded()

        let bounds = hosting.bounds
        var frame = model.viewport.convert(model.viewport.bounds, to: hosting)   // top-left origin when flipped
        if !hosting.isFlipped { frame.origin.y = bounds.height - frame.maxY }
        guard bounds.width > 1, frame.width > 1, frame.height > 1 else { return nil }

        let viewportShot = model.viewport.snapshot()
        model.snapshotPreviewImage = viewportShot
        defer { model.snapshotPreviewImage = nil }
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        hosting.layoutSubtreeIfNeeded()
        hosting.displayIfNeeded()

        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        hosting.cacheDisplay(in: bounds, to: rep)

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

    /// A SwiftUI view in an offscreen window at its fitting size: the auxiliary windows have no SceneKit.
    static func render<V: View>(_ view: V) -> NSBitmapImageRep? {
        let hosting = NSHostingView(rootView: view.preferredColorScheme(.dark))
        hosting.frame = CGRect(origin: .zero, size: hosting.fittingSize)
        let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: -20_000, y: -20_000), size: hosting.frame.size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = Theme.panel
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.25))
        hosting.layoutSubtreeIfNeeded()
        hosting.displayIfNeeded()
        guard hosting.bounds.width > 1, let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return nil }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        return rep
    }

    /// `SIMPLESKP_SNAPSHOT_MENU=Présentation`: the items of that top-level menu, validated with the document open.
    /// The app is not activated (no key window), so each action is resolved along window → document → app → delegate
    /// → document controller, the order of the responder chain past the first responder.
    static func listMenu(_ title: String, input: String?) -> Never {
        var document: SKPDocument?
        if let input {
            let url = URL(fileURLWithPath: (input as NSString).expandingTildeInPath)
            NSDocumentController.shared.openDocument(withContentsOf: url, display: false) { doc, _, error in
                if let error { fputs("menu error: \(error.localizedDescription)\n", stderr); exit(1) }
                document = doc as? SKPDocument
            }
            let deadline = Date().addingTimeInterval(30)
            while document == nil, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
            document?.makeWindowControllers()
            document?.startLoading()
            while let model = document?.model, !model.isReady, model.error == nil, Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            }
        }
        guard let menu = NSApp.mainMenu?.items.first(where: { $0.title == title })?.submenu else {
            fputs("menu error: no menu titled \(title)\n", stderr)
            exit(1)
        }
        let window = document?.windowControllers.first?.window
        for item in menu.items {
            if item.isSeparatorItem { print("—"); continue }
            var target: AnyObject? = item.target
            if target == nil, let action = item.action {
                target = ([window, document, NSApp, NSApp.delegate, NSDocumentController.shared] as [AnyObject?]).compactMap { $0 }.first { $0.responds(to: action) }
            }
            let enabled = target.map { ($0 as? NSMenuItemValidation)?.validateMenuItem(item) ?? true } ?? false
            let checked = item.state == .on ? " ✓" : ""
            print("\(keyLabel(item).padding(toLength: 6, withPad: " ", startingAt: 0)) \(item.title)\(checked) — \(enabled ? "enabled" : "disabled")")
        }
        exit(0)
    }

    /// "⌥⌘S", "⇧Z", in the menu's own glyph order.
    static func keyLabel(_ item: NSMenuItem) -> String {
        guard !item.keyEquivalent.isEmpty else { return "" }
        let mask = item.keyEquivalentModifierMask
        var label = ""
        if mask.contains(.control) { label += "⌃" }
        if mask.contains(.option) { label += "⌥" }
        if mask.contains(.shift) { label += "⇧" }
        if mask.contains(.command) { label += "⌘" }
        return label + item.keyEquivalent.uppercased()
    }

    static func run(output: String, input: String?, view: String? = nil) -> Never {
        let environment = ProcessInfo.processInfo.environment
        if let title = environment["SIMPLESKP_SNAPSHOT_MENU"] { listMenu(title, input: input) }
        let rep: NSBitmapImageRep?
        var viewportRect: CGRect?
        switch view ?? environment["SIMPLESKP_SNAPSHOT_WINDOW"] {
        case "about": rep = render(AboutView(close: {}))
        case "shortcuts": rep = render(ShortcutsView(close: {}))
        case "help": rep = render(HelpView(close: {}))
        case "settings": rep = render(SettingsView())
        case "lighting-sun":
            let model = DocumentModel()
            let scene = ViewportScene(model: SyntheticModel.cube())
            model.present(scene, seconds: 0.1)
            rep = render(LightingPopover(model: model))
        case "lighting-point":
            let model = DocumentModel()
            let scene = ViewportScene(model: SyntheticModel.cube())
            model.present(scene, seconds: 0.1)
            model.setLightingMode(.point)
            rep = render(LightingPopover(model: model))
        case nil, "", "document":
            let model = DocumentModel()
            do {
                let start = Date()
                let skp = try input.map { try SKPReader.load(URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath)) } ?? SyntheticModel.cube()
                model.info = skp.fileInfo
                let scene = ViewportScene(model: skp)
                let rendered = render(model: model, presenting: scene, seconds: Date().timeIntervalSince(start))
                rep = rendered?.rep
                viewportRect = rendered?.viewportRect
            } catch {
                fputs("snapshot error: \(error.localizedDescription)\n", stderr)
                exit(1)
            }
        case let other?:
            fputs("snapshot error: unknown SIMPLESKP_SNAPSHOT_WINDOW \(other) (about, shortcuts, help, settings)\n", stderr)
            exit(2)
        }
        guard let rep, let png = rep.representation(using: .png, properties: [:]) else {
            fputs("snapshot error: failed to render PNG\n", stderr)
            exit(1)
        }
        let url = URL(fileURLWithPath: (output as NSString).expandingTildeInPath)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try png.write(to: url, options: .atomic)
            // Written first so a blank result can still be looked at.
            if let viewportRect, !isNonUniform(rep, in: viewportRect) {
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
