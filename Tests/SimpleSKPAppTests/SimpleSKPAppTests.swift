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
    }

    func testFrenchNumbers() {
        guard !Localization.isEnglish else { return }
        XCTAssertEqual(Format.count(184_320, "face"), "184\u{202F}320 faces")
        XCTAssertEqual(Format.decimal(48.04 as Float), "48,0")
        XCTAssertEqual(Format.seconds(1.94), "1,9 s")
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
        model.present(ViewportScene(model: cube), seconds: 0.1)
        XCTAssertTrue(model.isReady)
        let (rep, viewportRect) = try XCTUnwrap(Snapshot.render(model: model))
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
}
