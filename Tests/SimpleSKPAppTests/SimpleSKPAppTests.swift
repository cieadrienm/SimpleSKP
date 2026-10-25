import AppKit
import SimpleSKPCore
import SimpleSKPMCPCore
@testable import SimpleSKPViewport
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

@MainActor
final class OSCAndCameraRemoteTests: XCTestCase {
    func testOSCCodecRoundTripAndBundle() {
        let msg1 = OSCCodec.Message(
            address: "/simpleskp/camera/position",
            arguments: [.float(1.5), .float(-4.25), .float(1.70)]
        )
        let encoded1 = OSCCodec.encode(msg1)
        let decoded1 = OSCCodec.decode(encoded1)
        XCTAssertEqual(decoded1, [msg1])

        let msg2 = OSCCodec.Message(
            address: "/simpleskp/style",
            arguments: [.string("clay"), .int(1), .bool(true), .impulse]
        )
        let encoded2 = OSCCodec.encode(msg2)
        var bundle = Data("#bundle\0".utf8)
        bundle.append(contentsOf: [0, 0, 0, 0, 0, 0, 0, 1]) // timetag
        var len1 = UInt32(encoded1.count).bigEndian
        withUnsafeBytes(of: &len1) { bundle.append(contentsOf: $0) }
        bundle.append(encoded1)
        var len2 = UInt32(encoded2.count).bigEndian
        withUnsafeBytes(of: &len2) { bundle.append(contentsOf: $0) }
        bundle.append(encoded2)

        let decodedBundle = OSCCodec.decode(bundle)
        XCTAssertEqual(decodedBundle, [msg1, msg2])
    }

    func testOSCQueryTreeHostInfoAndRoot() throws {
        let hostObj = OSCQueryTree.hostInfoJSON(name: "SimpleSKP", oscPort: 9150)
        XCTAssertEqual(hostObj["NAME"] as? String, "SimpleSKP")
        XCTAssertEqual(hostObj["OSC_PORT"] as? Int, 9150)
        XCTAssertEqual(hostObj["OSC_TRANSPORT"] as? String, "UDP")

        let specs: [OSCQueryParameterSpec] = [
            OSCQueryParameterSpec(path: "/simpleskp/camera/fov", typeTag: "f", description: "FOV", min: 10, max: 120, values: [35.0]),
            OSCQueryParameterSpec(path: "/simpleskp/camera/position", typeTag: "fff", description: "Position", min: -50, max: 50, values: [1.0, 2.0, 1.7]),
        ]
        let rootObj = OSCQueryTree.rootJSON(parameters: specs, description: "SimpleSKP")
        let contents = try XCTUnwrap(rootObj["CONTENTS"] as? [String: Any])
        let simpleskp = try XCTUnwrap(contents["simpleskp"] as? [String: Any])
        let cam = try XCTUnwrap((simpleskp["CONTENTS"] as? [String: Any])?["camera"] as? [String: Any])
        let fovNode = try XCTUnwrap((cam["CONTENTS"] as? [String: Any])?["fov"] as? [String: Any])
        XCTAssertEqual(fovNode["FULL_PATH"] as? String, "/simpleskp/camera/fov")
        XCTAssertEqual(fovNode["TYPE"] as? String, "f")

        let subNode = try XCTUnwrap(OSCQueryTree.nodeJSON(at: "/simpleskp/camera/position", in: rootObj))
        XCTAssertEqual(subNode["FULL_PATH"] as? String, "/simpleskp/camera/position")
        XCTAssertEqual(subNode["TYPE"] as? String, "fff")
    }

    func testFineCameraControlsOnDocumentModel() {
        let model = DocumentModel()
        model.present(ViewportScene(model: SyntheticModel.cube()), seconds: 0.1)

        model.setCameraFOV(52)
        XCTAssertEqual(model.cameraFOV, 52, accuracy: 0.05)

        model.setCameraFocalLength(50)
        XCTAssertEqual(model.cameraFocalLengthMM, 50, accuracy: 0.5)

        model.setCameraExposure(1.25)
        XCTAssertEqual(model.cameraExposure, 1.25, accuracy: 0.01)

        model.setCameraPosition(SIMD3<Float>(3, -6, 2.4))
        XCTAssertEqual(model.cameraPosition.x, 3, accuracy: 0.01)
        XCTAssertEqual(model.cameraPosition.y, -6, accuracy: 0.01)
        XCTAssertEqual(model.cameraPosition.z, 2.4, accuracy: 0.01)

        model.setCameraOrientation(yawDegrees: 45, pitchDegrees: -15)
        XCTAssertEqual(model.cameraYawDegrees, 45, accuracy: 0.1)
        XCTAssertEqual(model.cameraPitchDegrees, -15, accuracy: 0.1)

        model.levelCameraHorizon(animated: false)
        XCTAssertEqual(model.cameraPitchDegrees, 0, accuracy: 0.05)

        model.setCameraEyeHeight(1.70)
        XCTAssertEqual(model.cameraPosition.z, 1.70, accuracy: 0.01)

        model.setCameraLookAt(position: SIMD3<Float>(0, -5, 1.7), target: SIMD3<Float>(0, 0, 1.7), animated: false)
        XCTAssertEqual(model.cameraPosition.y, -5, accuracy: 0.01)
        XCTAssertEqual(model.cameraTarget.y, 0, accuracy: 0.05)
    }

    func testRemoteControlServerOSCHandlingAndNamespace() {
        let model = DocumentModel()
        model.present(ViewportScene(model: SyntheticModel.cube()), seconds: 0.1)
        let server = RemoteControlServer.shared
        server.overrideModel = model
        defer { server.overrideModel = nil }

        server.handleOSCMessage(OSCCodec.Message(address: "/simpleskp/camera/fov", arguments: [.float(64)]))
        XCTAssertEqual(model.cameraFOV, 64, accuracy: 0.05)

        server.handleOSCMessage(OSCCodec.Message(address: "/simpleskp/camera/position", arguments: [.float(2), .float(-8), .float(1.7)]))
        XCTAssertEqual(model.cameraPosition.x, 2, accuracy: 0.01)
        XCTAssertEqual(model.cameraPosition.y, -8, accuracy: 0.01)
        XCTAssertEqual(model.cameraPosition.z, 1.7, accuracy: 0.01)

        server.handleOSCMessage(OSCCodec.Message(address: "/simpleskp/camera/orientation", arguments: [.float(30), .float(-10)]))
        XCTAssertEqual(model.cameraYawDegrees, 30, accuracy: 0.1)
        XCTAssertEqual(model.cameraPitchDegrees, -10, accuracy: 0.1)

        server.handleOSCMessage(OSCCodec.Message(address: "/simpleskp/style", arguments: [.string("clay")]))
        XCTAssertEqual(model.shadingStyle, .clay)

        server.handleOSCMessage(OSCCodec.Message(address: "/simpleskp/light/intensity", arguments: [.float(2.4)]))
        XCTAssertEqual(model.selectedPointLight?.intensity ?? 0, 2.4, accuracy: 0.01)
        XCTAssertEqual(model.lightingMode, .point)

        let specs = server.oscQueryParameters()
        XCTAssertTrue(specs.contains(where: { $0.path == "/simpleskp/camera/position" && $0.typeTag == "fff" }))
        XCTAssertTrue(specs.contains(where: { $0.path == "/simpleskp/camera/orientation" && $0.typeTag == "ff" }))
        XCTAssertTrue(specs.contains(where: { $0.path == "/simpleskp/camera/fov" && $0.typeTag == "f" }))
    }

    func testMCPServerToolsListAndRouting() throws {
        var capturedMethod = ""
        var capturedPath = ""
        let mcp = SimpleSKPMCPServer(transport: { method, path, _ in
            capturedMethod = method
            capturedPath = path
            let payload = #"{"ok":true,"camera":{"fovDegrees":45.0}}"#
            return APIResponse(status: 200, data: Data(payload.utf8), contentType: "application/json")
        })

        let initResp: String = try XCTUnwrap(mcp.handle(line: #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#))
        XCTAssertTrue(initResp.contains(#""name":"simpleskp""#), initResp)

        let listResp: String = try XCTUnwrap(mcp.handle(line: #"{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}"#))
        for tool in ["simpleskp_state", "simpleskp_help", "simpleskp_open", "simpleskp_camera", "simpleskp_scene", "simpleskp_layers", "simpleskp_rendering", "simpleskp_snapshot"] {
            XCTAssertTrue(listResp.contains(tool), "missing tool \(tool)")
        }

        let camResp: String = try XCTUnwrap(mcp.handle(line: #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"simpleskp_camera","arguments":{"fov":45,"eyeHeight":1.7}}}"#))
        XCTAssertEqual(capturedMethod, "POST")
        XCTAssertEqual(capturedPath, "/v1/camera")
        XCTAssertTrue(camResp.contains("fovDegrees"), camResp)
    }

    func testSlowSceneTransitionAmbientLightAndVectorPDFOnDocumentModel() {
        let model = DocumentModel()
        model.present(ViewportScene(model: SyntheticModel.cube()), seconds: 0.1)

        // Normal scene transition (0.35 s) finishes within 0.5 s
        model.selectScene(1, slow: false)
        model.viewport.rig.step(dt: 0.5)
        XCTAssertFalse(model.viewport.rig.isMoving, "normal scene glide finished in 0.35 s")

        // Shift / slow scene transition (3.5 s = 10x slower) is still moving at 1.5 s and finishes at 3.6 s
        model.selectScene(0, slow: true)
        model.viewport.rig.step(dt: 1.5)
        XCTAssertTrue(model.viewport.rig.isMoving, "slow scene glide takes 3.5 s (10x slower)")
        model.viewport.rig.step(dt: 2.1)
        XCTAssertFalse(model.viewport.rig.isMoving, "slow scene glide completed after 3.5 s")

        // Ambient & sun intensity controls
        model.setAmbientIntensity(0.0)
        XCTAssertEqual(model.ambientIntensity, 0.0, accuracy: 1e-5)
        model.setSunIntensity(1.8)
        XCTAssertEqual(model.sunIntensity, 1.8, accuracy: 1e-5)

        // Vector PDF rendering from DocumentModel
        let pdfData = model.renderVectorPDF()
        XCTAssertNotNil(pdfData)
        XCTAssertEqual(String(decoding: (pdfData ?? Data()).prefix(5), as: UTF8.self), "%PDF-")
    }
}
