import AppKit
import SimpleSKPCore
import SimpleSKPViewport
import XCTest
@testable import SimpleSKP

@MainActor
final class SimpleSKPAppTests: XCTestCase {
    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
        // Made before anything touches `NSDocumentController.shared`, so it becomes the shared one.
        _ = DocumentController()
        UserDefaults.standard.removeObject(forKey: Preferences.Key.showSidebar)
    }

    /// The sibling targets start as `fatalError("todo: …")` stubs; a crash cannot be caught, so skip instead.
    private func skipIfStub(_ file: String) throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources").appendingPathComponent(file)
        let source = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        try XCTSkipIf(source.contains("fatalError(\"todo: "), "\(file) is still a stub")
    }

    func testMainMenuTitlesAndCameraKeys() {
        let menu = MainMenu.build(delegate: AppDelegate())
        let titles = menu.items.map(\.title)
        for title in [L("Fichier", "File"), L("Édition", "Edit"), L("Présentation", "View"), L("Caméra", "Camera"), L("Fenêtre", "Window"), L("Aide", "Help")] {
            XCTAssertTrue(titles.contains(title), "missing menu \(title) in \(titles)")
        }
        let camera = menu.items.first { $0.title == L("Caméra", "Camera") }?.submenu
        XCTAssertEqual(camera?.items.count, 7)
        XCTAssertEqual(camera?.items.map(\.keyEquivalent), ["1", "2", "3", "4", "5", "6", "7"])
        XCTAssertEqual(camera?.items.map(\.tag), Array(0..<7))
        let file = menu.items.first { $0.title == L("Fichier", "File") }?.submenu
        XCTAssertFalse(file?.items.contains { $0.action == #selector(NSDocument.save(_:)) } ?? true, "a viewer has no Save")
        let view = try! XCTUnwrap(menu.items.first { $0.title == L("Présentation", "View") }?.submenu)
        func item(_ action: Selector) -> NSMenuItem? { view.items.first { $0.action == action } }
        XCTAssertEqual(item(#selector(SKPDocument.resetView(_:)))?.keyEquivalent.lowercased(), "z")
        XCTAssertEqual(item(#selector(SKPDocument.resetView(_:)))?.keyEquivalentModifierMask, [], "Z without modifiers resets view")
        XCTAssertEqual(item(#selector(SKPDocument.zoomExtents(_:)))?.keyEquivalent.lowercased(), "z")
        XCTAssertEqual(item(#selector(SKPDocument.zoomExtents(_:)))?.keyEquivalentModifierMask, [.shift], "⇧Z, no ⌘")
        XCTAssertEqual(item(#selector(SKPDocument.toggleGrid(_:)))?.keyEquivalent, "g")
        XCTAssertEqual(item(#selector(SKPDocument.toggleGrid(_:)))?.keyEquivalentModifierMask, [.command, .option])
        XCTAssertEqual(item(#selector(SKPDocument.toggleSidebarPanel(_:)))?.keyEquivalent, "s")
        XCTAssertEqual(item(#selector(SKPDocument.toggleSidebarPanel(_:)))?.keyEquivalentModifierMask, [.command, .option])
        XCTAssertEqual(item(#selector(SKPDocument.togglePerspective(_:)))?.keyEquivalent, "p")
        XCTAssertEqual(item(#selector(SKPDocument.togglePerspective(_:)))?.keyEquivalentModifierMask, [.command, .option])
        XCTAssertEqual(Snapshot.keyLabel(item(#selector(SKPDocument.toggleSidebarPanel(_:)))!), "⌥⌘S")
        XCTAssertEqual(Snapshot.keyLabel(item(#selector(SKPDocument.toggleFreeFlight(_:)))!), "⌥⌘F")
        XCTAssertEqual(Snapshot.keyLabel(item(#selector(SKPDocument.toggleShadows(_:)))!), "⌥⌘O")
        XCTAssertEqual(Snapshot.keyLabel(item(#selector(SKPDocument.toggleAmbientOcclusion(_:)))!), "⌥⌘A")
    }

    func testFreeFlyShowsHowToExit() {
        let model = DocumentModel()
        model.setModel(SyntheticModel.cube())
        model.viewport.isFreeFlying = true
        XCTAssertEqual(model.statusText, L("Vol libre — Échap pour sortir", "Free fly — Esc to exit"))
        model.viewport.isFreeFlying = false
        XCTAssertFalse(model.isFreeFlying)
    }

    func testDocumentControllerTypes() throws {
        let controller = try XCTUnwrap(NSDocumentController.shared as? DocumentController)
        XCTAssertEqual(try controller.typeForContents(of: URL(fileURLWithPath: "/tmp/Salle.SKP")), "com.sketchup.skp")
        XCTAssertTrue(controller.documentClass(forType: "com.sketchup.skp") == SKPDocument.self)
        let panel = NSOpenPanel()
        controller.configurePanel(panel)
        XCTAssertEqual(panel.allowedContentTypes.map(\.identifier), ["com.sketchup.skp"])
    }

    func testDocumentModelWithCube() {
        let model = DocumentModel()
        model.setModel(SyntheticModel.cube())
        XCTAssertTrue(model.showSidebar, "two layers and a scene show the sidebar")
        model.selectScene(0)
        XCTAssertEqual(model.selectedScene, 0)
        XCTAssertEqual(model.layerVisible, [true, true])
        model.toggleLayer(1)
        XCTAssertEqual(model.layerVisible, [true, false])
        model.nextScene()   // wraps around the single scene and shows its layers again
        XCTAssertEqual(model.selectedScene, 0)
        XCTAssertEqual(model.layerVisible, [true, true])
        XCTAssertTrue(model.statusText.contains(L("faces", "faces")), model.statusText)
        XCTAssertTrue(model.statusText.contains("SketchUp 2023"), model.statusText)

        model.soloLayer(1)
        XCTAssertEqual(model.layerVisible, [false, true], "solo isolates layer 1")
        model.soloLayer(1)
        XCTAssertEqual(model.layerVisible, [true, true], "solo again restores all layers")
        model.setAllLayers(visible: false)
        XCTAssertEqual(model.layerVisible, [false, false])
        model.setAllLayers(visible: true)
        XCTAssertEqual(model.layerVisible, [true, true])
    }

    /// A scene that does not save layer visibility (nil) leaves the layers as they are, like SketchUp.
    func testSceneWithoutSavedLayersKeepsVisibility() {
        var cube = SyntheticModel.cube()
        cube.scenes = [SKPModel.Scene(name: "Caméra seule", camera: cube.camera, hiddenLayers: nil)]
        let model = DocumentModel()
        model.setModel(cube)
        model.toggleLayer(1)
        model.selectScene(0)
        XCTAssertEqual(model.selectedScene, 0)
        XCTAssertEqual(model.layerVisible, [true, false])
    }

    /// The status bar gives the size of what is shown: hiding « Décor » (the cube at x = 1.5 m) narrows it.
    func testStatusBarShowsVisibleSize() {
        let model = DocumentModel()
        model.present(ViewportScene(model: SyntheticModel.cube()), seconds: 0.1)
        let one = Format.decimal(1 as Float)
        XCTAssertTrue(model.statusText.contains("\(Format.decimal(2.5 as Float)) × \(one) × \(one) m"), model.statusText)
        model.toggleLayer(1)
        XCTAssertTrue(model.statusText.contains("\(one) × \(one) × \(one) m"), model.statusText)
        model.selectScene(0) // saves « all shown »
        XCTAssertTrue(model.statusText.contains("\(Format.decimal(2.5 as Float)) × \(one) × \(one) m"), model.statusText)
    }

    /// D7: Ombres and Occlusion ambiante are remembered: written on toggle, read by the next document.
    func testShadowsAndOcclusionAreRemembered() {
        let keys = [Preferences.Key.shadowsEnabled, Preferences.Key.ambientOcclusionEnabled]
        keys.forEach(UserDefaults.standard.removeObject(forKey:))
        defer { keys.forEach(UserDefaults.standard.removeObject(forKey:)) }
        let first = DocumentModel()
        first.present(ViewportScene(model: SyntheticModel.cube()), seconds: 0)
        let (shadows, occlusion) = (first.shadowsEnabled, first.ambientOcclusionEnabled)
        XCTAssertEqual(first.scene?.shadowsEnabled, shadows)
        XCTAssertEqual(first.viewport.ambientOcclusionEnabled, occlusion)
        first.toggleShadows()
        first.toggleAmbientOcclusion()
        XCTAssertEqual(Preferences.shadowsEnabled, !shadows)
        XCTAssertEqual(Preferences.ambientOcclusionEnabled, !occlusion)
        let next = DocumentModel()
        next.present(ViewportScene(model: SyntheticModel.cube()), seconds: 0)
        XCTAssertEqual(next.scene?.shadowsEnabled, !shadows)
        XCTAssertEqual(next.viewport.ambientOcclusionEnabled, !occlusion)
    }

    func testNumbersInBothLanguages() {
        let saved = Localization.current
        defer { Localization.current = saved }
        Localization.current = .fr
        XCTAssertEqual(Format.count(184_320, "face"), "184\u{202F}320 faces")
        XCTAssertEqual(Format.count(0, "face"), "0 face")
        XCTAssertEqual(Format.decimal(48.04 as Float), "48,0")
        XCTAssertEqual(Format.seconds(1.94), "1,9 s")
        Localization.current = .en
        XCTAssertEqual(Format.count(184_320, "face"), "184,320 faces")
        XCTAssertEqual(Format.count(0, "face"), "0 faces")
        XCTAssertEqual(Format.count(1, "face"), "1 face")
        XCTAssertEqual(Format.seconds(1.94), "1.9 s")
    }

    func testSidebarHiddenWithoutScenesAndSingleLayer() {
        var cube = SyntheticModel.cube()
        cube.scenes = []
        cube.layers = [cube.layers[0]]
        let model = DocumentModel()
        model.setModel(cube)
        XCTAssertFalse(model.showSidebar)
    }

    func testSnapshotOfCube() throws {
        try skipIfStub("SimpleSKPViewport/ViewportScene.swift")
        try skipIfStub("SimpleSKPViewport/ViewportView.swift")
        let model = DocumentModel()
        let cube = SyntheticModel.cube()
        model.info = cube.fileInfo
        let (rep, viewportRect) = try XCTUnwrap(Snapshot.render(model: model, presenting: ViewportScene(model: cube), seconds: 0.1))
        XCTAssertTrue(model.isReady)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("simpleskp-test-\(UUID().uuidString).png")
        try png.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let size = try XCTUnwrap(try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int)
        XCTAssertGreaterThan(size, 20_000)
        XCTAssertGreaterThan(viewportRect.minX, 0, "the sidebar is left of the viewport")
        XCTAssertTrue(Snapshot.isNonUniform(rep, in: viewportRect), "the 3D is visible in the viewport region")
    }
}

@MainActor
final class SnapshotCheckTests: XCTestCase {
    private func rep(drawing: (CGRect) -> Void) -> NSBitmapImageRep {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 200, pixelsHigh: 100, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        Theme.background.setFill()
        CGRect(x: 0, y: 0, width: 200, height: 100).fill()
        drawing(CGRect(x: 0, y: 0, width: 200, height: 100))
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    func testUniformAndFlatShapes() {
        XCTAssertFalse(Snapshot.isNonUniform(rep { _ in }))
        // One flat grey plane, as a flat-shaded model draws: few colours, but clearly not empty.
        XCTAssertTrue(Snapshot.isNonUniform(rep { _ in NSColor.gray.setFill(); CGRect(x: 20, y: 20, width: 60, height: 40).fill() }))
        // The left half is empty, the right half drawn: the region decides.
        let half = rep { _ in NSColor.white.setFill(); CGRect(x: 100, y: 0, width: 100, height: 100).fill() }
        XCTAssertFalse(Snapshot.isNonUniform(half, in: CGRect(x: 0, y: 0, width: 100, height: 100)))
        XCTAssertTrue(Snapshot.isNonUniform(half))
    }
}

@MainActor
final class DocumentOpenTests: XCTestCase {
    /// The real AppKit path: controller → type → SKPDocument.read (header) → background load → ready scene.
    func testOpenFixtureThroughDocumentController() throws {
        _ = NSApplication.shared
        _ = DocumentController()
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/VerreMirroir.skp")
        let opened = expectation(description: "opened")
        var document: NSDocument?
        NSDocumentController.shared.openDocument(withContentsOf: fixture, display: false) { doc, _, error in
            XCTAssertNil(error)
            document = doc
            opened.fulfill()
        }
        wait(for: [opened], timeout: 10)
        let skp = try XCTUnwrap(document as? SKPDocument)
        defer { skp.close() }
        XCTAssertEqual(skp.fileType, "com.sketchup.skp")
        XCTAssertEqual(skp.fileURL?.standardizedFileURL, fixture.standardizedFileURL)
        XCTAssertEqual(skp.model.info?.versionLabel, "SketchUp 8")

        try XCTSkipUnless(SketchUpAPI.isAvailable, "SketchUp not installed: the model cannot load")
        skp.startLoading()
        let ready = expectation(for: NSPredicate { _, _ in MainActor.assumeIsolated { skp.model.isReady || skp.model.error != nil } }, evaluatedWith: nil)
        wait(for: [ready], timeout: 30)
        XCTAssertNil(skp.model.error)
        XCTAssertEqual(skp.model.skp?.stats.faces, 18)
        XCTAssertNotNil(skp.model.loadSeconds)
    }

    /// Closing before `.ready` cancels: the scene is never presented and nothing crashes or leaks.
    func testCloseDuringLoad() throws {
        try XCTSkipUnless(SketchUpAPI.isAvailable, "SketchUp SDK not found: nothing loads, nothing to cancel")
        _ = NSApplication.shared
        _ = DocumentController()
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/VerreMirroir.skp")
        let opened = expectation(description: "opened")
        var document: NSDocument?
        NSDocumentController.shared.openDocument(withContentsOf: fixture, display: false) { doc, _, _ in
            document = doc
            opened.fulfill()
        }
        wait(for: [opened], timeout: 10)
        let skp = try XCTUnwrap(document as? SKPDocument)
        skp.makeWindowControllers()
        skp.startLoading()
        skp.close()
        // Long enough for the background load of 18 faces and its main-queue hop (an expectation drains the queue).
        let settled = expectation(description: "settled")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { settled.fulfill() }
        wait(for: [settled], timeout: 5)
        XCTAssertTrue(skp.cancelled.withLock { $0 }, "close() raised the flag the reader and the main-queue hop check")
        XCTAssertFalse(skp.model.isReady, "a closed document never presents its scene")
        XCTAssertNil(skp.model.skp, "the loaded model was dropped, not presented")
        XCTAssertFalse(NSDocumentController.shared.documents.contains(skp))
    }
}
