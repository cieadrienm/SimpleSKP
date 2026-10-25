import AppKit
import os
import SimpleSKPCore
import SimpleSKPViewport
import SwiftUI

/// One `.skp`, read-only: the header is read by AppKit's open (milliseconds), the model loads in the
/// background once the window shows. Nothing is ever written.
@MainActor
final class SKPDocument: NSDocument {
    let model = DocumentModel()
    /// Read off the main thread by the reader's `isCancelled` (and by the tests).
    let cancelled = OSAllocatedUnfairLock(initialState: false)
    private var loadStarted = false

    override class var autosavesInPlace: Bool { false }
    override class var readableTypes: [String] { [DocumentController.skpType] }
    override class var writableTypes: [String] { [] }
    override class func isNativeType(_ type: String) -> Bool { false }
    override var isDocumentEdited: Bool { false }

    override func read(from url: URL, ofType typeName: String) throws {
        let info = try SKPFileInfo.read(url)
        // AppKit reads on the main thread: concurrent reading is off by default.
        MainActor.assumeIsolated { model.info = info }
    }

    override func makeWindowControllers() {
        addWindowController(ModelWindowController(document: self))
    }

    override func showWindows() {
        super.showWindows()
        startLoading()
    }

    /// Runs once per document, whatever calls `showWindows` again (restoration, Window menu).
    func startLoading() {
        guard !loadStarted, let url = fileURL else { return }
        loadStarted = true
        let model = self.model
        let cancelled = self.cancelled
        let start = Date()
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let skp = try SKPReader.load(url, progress: { progress in
                    DispatchQueue.main.async { if case .loading = model.state { model.state = .loading(progress) } }
                }, isCancelled: { cancelled.withLock { $0 } })
                if cancelled.withLock({ $0 }) {
                    Self.removeTextures(of: skp)
                    return
                }
                let scene = ViewportScene(model: skp)
                DispatchQueue.main.async {
                    guard !cancelled.withLock({ $0 }) else { return Self.removeTextures(of: skp) }
                    model.present(scene, seconds: Date().timeIntervalSince(start))
                }
            } catch {
                DispatchQueue.main.async { model.fail(error) }
            }
        }
    }

    override func close() {
        cancelled.withLock { $0 = true }
        if let skp = model.skp { Self.removeTextures(of: skp) }
        super.close()
    }

    nonisolated private static func removeTextures(of model: SKPModel) {
        if let directory = model.textureDirectory { try? FileManager.default.removeItem(at: directory) }
    }

    // MARK: Menu actions (reached through the responder chain)

    @objc func openInSketchUp(_ sender: Any?) { model.openInSketchUp() }
    @objc func revealInFinder(_ sender: Any?) { model.revealInFinder() }
    @objc func copyImage(_ sender: Any?) { model.copyImage() }
    @objc func toggleSidebarPanel(_ sender: Any?) { model.toggleSidebar() }
    @objc func toggleEdges(_ sender: Any?) { model.toggleEdges() }
    @objc func togglePerspective(_ sender: Any?) { model.togglePerspective() }
    @objc func zoomExtents(_ sender: Any?) { model.zoomExtents() }
    @objc func toggleShadows(_ sender: Any?) { model.toggleShadows() }
    @objc func toggleAmbientOcclusion(_ sender: Any?) { model.toggleAmbientOcclusion() }
    @objc func toggleFreeFlight(_ sender: Any?) { model.toggleFreeFlight() }
    @objc func previousScene(_ sender: Any?) { model.previousScene() }
    @objc func nextScene(_ sender: Any?) { model.nextScene() }

    /// Camera menu: the item's tag indexes `MainMenu.cameraViews`.
    @objc func lookStandard(_ sender: NSMenuItem) {
        guard MainMenu.cameraViews.indices.contains(sender.tag) else { return }
        model.look(MainMenu.cameraViews[sender.tag].view)
    }

    override func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(openInSketchUp(_:)):
            item.isHidden = model.sketchUpApp == nil   // SketchUp is optional (D1)
            return !item.isHidden
        case #selector(revealInFinder(_:)):
            return true
        case #selector(toggleSidebarPanel(_:)):
            item.state = model.showSidebar ? .on : .off
            return model.skp != nil
        case #selector(toggleEdges(_:)):
            item.state = model.showsEdges ? .on : .off
            return model.isReady
        case #selector(togglePerspective(_:)):
            item.state = model.isPerspective ? .on : .off
            return model.isReady
        case #selector(toggleShadows(_:)):
            item.state = model.scene?.shadowsEnabled ?? false ? .on : .off
            return model.isReady
        case #selector(toggleAmbientOcclusion(_:)):
            item.state = model.viewport.ambientOcclusionEnabled ? .on : .off
            return model.isReady
        case #selector(toggleFreeFlight(_:)):
            item.state = model.isFreeFlying ? .on : .off
            return model.isReady
        case #selector(previousScene(_:)), #selector(nextScene(_:)):
            return model.isReady && !(model.skp?.scenes.isEmpty ?? true)
        case #selector(copyImage(_:)), #selector(zoomExtents(_:)), #selector(lookStandard(_:)):
            return model.isReady
        default:
            return super.validateMenuItem(item)
        }
    }
}

/// One window per model, no tabs.
final class ModelWindowController: NSWindowController {
    init(document: SKPDocument) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1380, height: 820),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.minSize = NSSize(width: 760, height: 480)
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = Theme.background
        window.tabbingMode = .disallowed
        window.contentView = NSHostingView(rootView: ContentView(model: document.model))
        window.center()
        super.init(window: window)
        shouldCascadeWindows = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}
