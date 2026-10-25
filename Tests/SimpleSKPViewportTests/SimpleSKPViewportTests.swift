import XCTest
import SceneKit
@testable import SimpleSKPViewport
import SimpleSKPCore

/// Hand-built models: the Core reader is not needed to test the scene.
enum SyntheticModel {
    /// Unit cube (0…1 m) as 12 triangles with flat normals, plus its 12 edges as point pairs.
    static func cubeMesh(material: Int?, layer: Int) -> (SKPModel.Mesh, SKPModel.EdgeSet) {
        let c = (0..<8).map { SIMD3<Float>(Float($0 & 1), Float($0 >> 1 & 1), Float($0 >> 2 & 1)) }
        // Each face: 4 corners, counter-clockwise from outside, and its normal.
        let faces: [([Int], SIMD3<Float>)] = [
            ([0, 2, 3, 1], SIMD3(0, 0, -1)), ([4, 5, 7, 6], SIMD3(0, 0, 1)),
            ([0, 1, 5, 4], SIMD3(0, -1, 0)), ([2, 6, 7, 3], SIMD3(0, 1, 0)),
            ([0, 4, 6, 2], SIMD3(-1, 0, 0)), ([1, 3, 7, 5], SIMD3(1, 0, 0)),
        ]
        var positions: [SIMD3<Float>] = [], normals: [SIMD3<Float>] = [], indices: [UInt32] = []
        for (corners, normal) in faces {
            let base = UInt32(positions.count)
            positions += corners.map { c[$0] }
            normals += Array(repeating: normal, count: 4)
            indices += [base, base + 1, base + 2, base, base + 2, base + 3]
        }
        let edgePairs = [(0, 1), (2, 3), (4, 5), (6, 7), (0, 2), (1, 3), (4, 6), (5, 7), (0, 4), (1, 5), (2, 6), (3, 7)]
        let mesh = SKPModel.Mesh(material: material, layer: layer, positions: positions, normals: normals, indices: indices)
        return (mesh, SKPModel.EdgeSet(layer: layer, positions: edgePairs.flatMap { [c[$0.0], c[$0.1]] }))
    }

    /// Root: the unit cube on Layer0 (material 0). Definition 0: an unpainted cube, instanced twice:
    /// at (2, 0, 0) on Layer0 painted with material 0, at (0, 2, 0) on the hidden "Cotes" layer.
    static func cube() -> SKPModel {
        let (mesh, edges) = cubeMesh(material: 0, layer: 0)
        let (defMesh, defEdges) = cubeMesh(material: nil, layer: 0)
        func translation(_ x: Float, _ y: Float) -> simd_float4x4 {
            var m = matrix_identity_float4x4
            m.columns.3 = SIMD4(x, y, 0, 1)
            return m
        }
        // Hostile root name: must not join the layer index.
        let root = SKPModel.Definition(name: "L1", meshes: [mesh], edges: [edges], children: [
            SKPModel.Instance(definition: 0, transform: translation(2, 0), layer: 0, isGroup: false, material: 0, name: "A"),
            SKPModel.Instance(definition: 0, transform: translation(0, 2), layer: 1, isGroup: false, name: "B"),
        ])
        let camera = SKPModel.Camera(position: SIMD3(5, -6, 4), target: SIMD3(0.5, 0.5, 0.5))
        return SKPModel(root: root, definitions: [SKPModel.Definition(name: "Box", meshes: [defMesh], edges: [defEdges])],
                        materials: [SKPModel.Material(name: "Red", color: SIMD4(0.8, 0.2, 0.2, 1))],
                        layers: [SKPModel.Layer(name: "Layer0", isVisible: true), SKPModel.Layer(name: "Cotes", isVisible: false)],
                        scenes: [SKPModel.Scene(name: "Scène 1", camera: camera)],
                        camera: nil, boundsMin: SIMD3(0, 0, 0), boundsMax: SIMD3(3, 3, 1),
                        fileInfo: SKPFileInfo(url: URL(fileURLWithPath: "/tmp/cube.skp"), fileSize: 0, version: nil, versionLabel: nil, thumbnailPNG: nil))
    }
}

@MainActor
final class SimpleSKPViewportTests: XCTestCase {
    func testStandardViews() {
        XCTAssertEqual(StandardView.allCases.count, 7)
    }

    // MARK: Scene

    func testZUpBecomesYUp() {
        let scene = ViewportScene(model: SyntheticModel.cube())
        XCTAssertEqual(scene.modelRoot.parent, scene.scene.rootNode)
        XCTAssertEqual(scene.modelRoot.simdEulerAngles.x, -.pi / 2, accuracy: 1e-5)
        let world = scene.modelRoot.simdConvertPosition(SIMD3(0, 0, 1), to: nil)
        XCTAssertEqual(simd_distance(world, SIMD3(0, 1, 0)), 0, accuracy: 1e-5)
    }

    func testNodesAndSharedGeometry() {
        let scene = ViewportScene(model: SyntheticModel.cube())
        let root = scene.modelRoot.childNodes[0]
        XCTAssertEqual(root.childNodes.count, 4) // mesh, edges, two instances
        let (mesh, edges, a, b) = (root.childNodes[0], root.childNodes[1], root.childNodes[2], root.childNodes[3])
        XCTAssertEqual(mesh.geometry?.elements.first?.primitiveType, .triangles)
        XCTAssertEqual(mesh.geometry?.elements.first?.primitiveCount, 12)
        XCTAssertEqual(edges.geometry?.elements.first?.primitiveType, .line)
        XCTAssertEqual(edges.geometry?.elements.first?.primitiveCount, 12)
        XCTAssertEqual(a.childNodes.count, 2)
        XCTAssertEqual(b.childNodes.count, 2)
        XCTAssertEqual(a.simdPosition, SIMD3(2, 0, 0))
        // B is unpainted: both clones share the edges geometry, B shares the mesh geometry with the prototype.
        XCTAssertTrue(a.childNodes[1].geometry === b.childNodes[1].geometry)
        XCTAssertTrue(a.childNodes[1].geometry !== edges.geometry)
        // A is painted: shallow copy (same sources), the shared model material (same object as the root mesh's).
        XCTAssertTrue(a.childNodes[0].geometry !== b.childNodes[0].geometry)
        XCTAssertTrue(a.childNodes[0].geometry?.sources.first === b.childNodes[0].geometry?.sources.first)
        XCTAssertTrue(a.childNodes[0].geometry?.firstMaterial === mesh.geometry?.firstMaterial)
        XCTAssertTrue(b.childNodes[0].geometry?.firstMaterial !== mesh.geometry?.firstMaterial)
        XCTAssertEqual(mesh.geometry?.firstMaterial?.lightingModel, .lambert)
        XCTAssertEqual(mesh.geometry?.firstMaterial?.isDoubleSided, true)
    }

    func testLayers() {
        let scene = ViewportScene(model: SyntheticModel.cube())
        let root = scene.modelRoot.childNodes[0]
        let b = root.childNodes[3]
        XCTAssertTrue(b.isHidden, "Cotes is hidden in the model")
        XCTAssertFalse(root.childNodes[0].isHidden)
        scene.setLayer(1, visible: true)
        XCTAssertFalse(b.isHidden)
        scene.setLayer(1, visible: false)
        var hidden: [SCNNode] = []
        scene.modelRoot.enumerateHierarchy { node, _ in if node.isHidden { hidden.append(node) } }
        XCTAssertEqual(hidden, [b])
        scene.setLayer(0, visible: false)
        XCTAssertTrue(root.childNodes[0].isHidden && root.childNodes[1].isHidden && root.childNodes[2].isHidden)
    }

    func testEdgesToggleAndLayerDoNotFight() {
        let scene = ViewportScene(model: SyntheticModel.cube())
        let root = scene.modelRoot.childNodes[0]
        scene.showsEdges = false
        XCTAssertTrue(root.childNodes[1].isHidden)
        XCTAssertTrue(root.childNodes[2].childNodes[1].isHidden)
        XCTAssertFalse(root.childNodes[0].isHidden)
        scene.setLayer(0, visible: false)
        scene.setLayer(0, visible: true)
        XCTAssertTrue(root.childNodes[1].isHidden, "showing the layer must not bring the edges back")
        XCTAssertFalse(root.childNodes[0].isHidden)
        scene.showsEdges = true
        XCTAssertFalse(root.childNodes[1].isHidden)
    }

    func testTransparency() {
        var model = SyntheticModel.cube()
        model.materials.append(SKPModel.Material(name: "Verre", color: SIMD4(0.6, 0.8, 1, 0.5), opacity: 0.5))
        model.root.meshes[0].material = 1
        let material = ViewportScene(model: model).modelRoot.childNodes[0].childNodes[0].geometry!.firstMaterial!
        XCTAssertEqual(material.transparency, 0.5, accuracy: 1e-6)
        XCTAssertEqual(material.transparencyMode, .dualLayer)
    }

    func testBuildsOffMainThread() async {
        let model = SyntheticModel.cube()
        let count = await Task.detached { ViewportScene(model: model).modelRoot.childNodes[0].childNodes.count }.value
        XCTAssertEqual(count, 4)
    }

    // MARK: View

    private func presentedView() -> (ViewportView, ViewportScene) {
        let view = ViewportView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let scene = ViewportScene(model: SyntheticModel.cube())
        view.present(scene)
        return (view, scene)
    }

    func testPresentFramesModel() {
        let (view, scene) = presentedView()
        XCTAssertTrue(view.pointOfView === view.cameraNode)
        XCTAssertTrue(view.cameraNode.parent === scene.modelRoot)
        XCTAssertFalse(view.rendersContinuously)
        XCTAssertTrue(view.isNode(scene.modelRoot.childNodes[0], insideFrustumOf: view.cameraNode))
        // Iso: camera above and in front-right of the centre, in model space.
        let p = view.cameraNode.simdPosition
        XCTAssertTrue(p.x > 1.5 && p.y < 1.5 && p.z > 0.5, "\(p)")
    }

    func testApplyCamera() {
        let (view, scene) = presentedView()
        let camera = scene.model.scenes[0].camera!
        view.apply(camera: camera, animated: false)
        XCTAssertEqual(simd_distance(view.cameraNode.simdPosition, camera.position), 0, accuracy: 1e-4)
        // Looks at the target: the target is straight ahead.
        let target = scene.modelRoot.simdConvertPosition(camera.target, to: nil)
        let ahead = simd_normalize(target - view.cameraNode.simdWorldPosition)
        XCTAssertEqual(simd_dot(ahead, view.cameraNode.simdWorldFront), 1, accuracy: 1e-4)
        // Model up (Z) stays up on screen: the camera's up has a positive world Y.
        XCTAssertGreaterThan(view.cameraNode.simdWorldUp.y, 0.5)

        view.apply(camera: SKPModel.Camera(position: camera.position, target: camera.target, isPerspective: false, orthoHeight: 8), animated: false)
        XCTAssertTrue(view.cameraNode.camera!.usesOrthographicProjection)
        XCTAssertEqual(view.cameraNode.camera!.orthographicScale, 4, accuracy: 1e-6)
        XCTAssertFalse(view.isPerspective)
    }

    func testZoomExtentsAndStandardViews() {
        let (view, scene) = presentedView()
        let centre = scene.model.center
        view.apply(camera: SKPModel.Camera(position: SIMD3(40, -1, 3), target: centre), animated: false)
        view.zoomExtents(animated: false)
        XCTAssertTrue(view.isNode(scene.modelRoot, insideFrustumOf: view.cameraNode))
        XCTAssertLessThan(simd_distance(view.cameraNode.simdPosition, centre), 20, "zoomed in from 40 m")

        view.look(.top, animated: false)
        let world = view.cameraNode.simdWorldPosition, worldCentre = scene.modelRoot.simdConvertPosition(centre, to: nil)
        XCTAssertGreaterThan(world.y, worldCentre.y + 1)
        XCTAssertEqual(world.x, worldCentre.x, accuracy: 1e-4)
        XCTAssertTrue(view.isNode(scene.modelRoot.childNodes[0], insideFrustumOf: view.cameraNode))

        view.look(.front, animated: false)
        let p = view.cameraNode.simdPosition
        XCTAssertLessThan(p.y, centre.y - 1)
        XCTAssertEqual(p.x, centre.x, accuracy: 1e-4)
        XCTAssertEqual(p.z, centre.z, accuracy: 1e-4)
    }

    func testPerspectiveToggleKeepsFraming() {
        let (view, _) = presentedView()
        let camera = view.cameraNode.camera!
        XCTAssertEqual(camera.fieldOfView, 35, "SketchUp's default FOV without a file camera")
        let eye = view.cameraNode.simdWorldPosition
        let depth = Double(simd_dot(view.target - eye, view.cameraNode.simdWorldFront))
        view.isPerspective = false
        XCTAssertTrue(camera.usesOrthographicProjection)
        XCTAssertEqual(camera.orthographicScale, depth * tan(35 * .pi / 360), accuracy: 1e-4)
        camera.orthographicScale /= 2 // zoomed in while parallel
        view.isPerspective = true
        XCTAssertFalse(camera.usesOrthographicProjection)
        let newDepth = Double(simd_dot(view.target - view.cameraNode.simdWorldPosition, view.cameraNode.simdWorldFront))
        XCTAssertEqual(newDepth, depth / 2, accuracy: 1e-3, "the camera moved in to keep the parallel framing")
    }

    func testOrbitTurnsAroundWorldUpTowardsTheRight() {
        let (view, scene) = presentedView()
        let centre = scene.modelRoot.simdConvertPosition(scene.model.center, to: nil)
        let before = view.cameraNode.simdWorldPosition, right = view.cameraNode.simdWorldRight
        view.orbit(dx: 50, dy: 0)
        let after = view.cameraNode.simdWorldPosition
        XCTAssertEqual(after.y, before.y, accuracy: 1e-3, "turntable keeps the height")
        XCTAssertEqual(simd_distance(after, centre), simd_distance(before, centre), accuracy: 1e-3)
        XCTAssertLessThan(simd_dot(after - before, right), -0.1, "model turns right = eye moves to its left")
        let ahead = simd_normalize(centre - after)
        XCTAssertEqual(simd_dot(ahead, view.cameraNode.simdWorldFront), 1, accuracy: 1e-3, "still looks at the target")
        // Dragging up shows the model from above: the eye goes down.
        view.orbit(dx: 0, dy: 30)
        XCTAssertLessThan(view.cameraNode.simdWorldPosition.y, after.y)
    }

    func testPanFollowsCursor() {
        let (view, scene) = presentedView()
        let centre = scene.modelRoot.simdConvertPosition(scene.model.center, to: nil)
        let before = view.cameraNode.simdWorldPosition, right = view.cameraNode.simdWorldRight
        // Perspective projection by hand (projectPoint needs a rendered frame).
        func screenX(_ p: SIMD3<Float>) -> Float {
            let local = view.cameraNode.simdConvertPosition(p, from: nil)
            return 400 + local.x / -local.z / Float(tan(view.cameraNode.camera!.fieldOfView * .pi / 360)) * 300
        }
        let projected = screenX(centre)
        view.pan(dx: 100, dy: 0)
        XCTAssertLessThan(simd_dot(view.cameraNode.simdWorldPosition - before, right), 0)
        XCTAssertEqual(screenX(centre) - projected, 100, accuracy: 15, "the centre follows the cursor ~1:1")
        // The orbit centre moved with the camera: orbiting now keeps the new distance to the target.
        let newTarget = centre + (view.cameraNode.simdWorldPosition - before)
        let d = simd_distance(view.cameraNode.simdWorldPosition, newTarget)
        view.orbit(dx: 40, dy: 0)
        XCTAssertEqual(simd_distance(view.cameraNode.simdWorldPosition, newTarget), d, accuracy: 1e-3)
    }

    func testZoomTowardsCursor() {
        let (view, scene) = presentedView()
        view.apply(camera: scene.model.scenes[0].camera!, animated: false) // the root cube is under the view centre
        // The step is 10 % of the depth under the cursor, so notches converge on the face and never cross it.
        for _ in 0..<60 { view.zoom(ratio: 0.9, at: CGPoint(x: 400, y: 300)) }
        let eye = scene.modelRoot.simdConvertPosition(view.cameraNode.simdWorldPosition, from: nil)
        XCTAssertFalse(simd_reduce_min(eye) > 0 && simd_reduce_max(eye) < 1, "eye entered the cube: \(eye)")
        XCTAssertLessThan(simd_distance(eye, SIMD3(0.5, 0.5, 0.5)), 1, "and still came close")
        // Towards the cursor: right of centre moves the eye right, above centre (AppKit y up) moves it up.
        view.apply(camera: scene.model.scenes[0].camera!, animated: false)
        var before = view.cameraNode.simdWorldPosition
        let right = view.cameraNode.simdWorldRight, up = view.cameraNode.simdWorldUp
        view.zoom(ratio: 0.9, at: CGPoint(x: 700, y: 300))
        XCTAssertGreaterThan(simd_dot(view.cameraNode.simdWorldPosition - before, right), 0)
        before = view.cameraNode.simdWorldPosition
        view.zoom(ratio: 0.9, at: CGPoint(x: 400, y: 550))
        XCTAssertGreaterThan(simd_dot(view.cameraNode.simdWorldPosition - before, up), 0)
        view.isPerspective = false
        let scale = view.cameraNode.camera!.orthographicScale
        view.zoom(ratio: 0.5, at: CGPoint(x: 400, y: 300))
        XCTAssertEqual(view.cameraNode.camera!.orthographicScale, scale * 0.5, accuracy: 1e-6)
    }

    private func click(_ view: NSView, at point: CGPoint, count: Int) {
        let event = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                       context: nil, eventNumber: 0, clickCount: count, pressure: 1)!
        view.mouseDown(with: event)
    }

    func testDoubleClickRecentresOnTheHitPoint() {
        let (view, scene) = presentedView()
        view.apply(camera: scene.model.scenes[0].camera!, animated: false) // looks at the root cube's centre
        let eye = view.cameraNode.simdWorldPosition, front = view.cameraNode.simdWorldFront
        // Real event path: the first click of a double-click already moved the target to the hit point.
        let point = CGPoint(x: 440, y: 330)
        click(view, at: point, count: 1)
        click(view, at: point, count: 2)
        let hit = view.target
        let local = view.cameraNode.simdConvertPosition(hit, from: nil)
        XCTAssertEqual(local.x, 0, accuracy: 1e-3, "the hit point is now at the view centre")
        XCTAssertEqual(local.y, 0, accuracy: 1e-3)
        XCTAssertEqual(simd_dot(view.cameraNode.simdWorldFront, front), 1, accuracy: 1e-5, "same direction, slid sideways")
        XCTAssertGreaterThan(simd_distance(view.cameraNode.simdWorldPosition, eye), 0.1)
        let cubeCentre = scene.modelRoot.simdConvertPosition(SIMD3(0.5, 0.5, 0.5), to: nil)
        XCTAssertLessThan(simd_distance(hit, eye), simd_distance(cubeCentre, eye), "nearest face, not the far one")
        let model = scene.modelRoot.simdConvertPosition(hit, from: nil)
        XCTAssertEqual(simd_reduce_max(abs(model - SIMD3(0.5, 0.5, 0.5))), 0.5, accuracy: 0.01, "on the cube's surface: \(model)")
        click(view, at: CGPoint(x: 5, y: 595), count: 2) // empty sky: nothing changes
        XCTAssertEqual(simd_distance(view.target, hit), 0, accuracy: 1e-5)
    }

    func testEdgesDrawnAfterFacesWithDepthBias() {
        let scene = ViewportScene(model: SyntheticModel.cube())
        let root = scene.modelRoot.childNodes[0]
        let edges = root.childNodes[1], cloneEdges = root.childNodes[2].childNodes[1]
        XCTAssertEqual(edges.renderingOrder, 1)
        XCTAssertEqual(cloneEdges.renderingOrder, 1, "survives clone()")
        XCTAssertEqual(root.childNodes[0].renderingOrder, 0)
        let material = edges.geometry!.firstMaterial!
        XCTAssertTrue(material === cloneEdges.geometry!.firstMaterial, "one shared edge material")
        XCTAssertNotNil(material.shaderModifiers?[.geometry])
    }

    func testTextures() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("simpleskp-test-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        let image = NSImage(size: NSSize(width: 4, height: 4), flipped: false) { rect in NSColor.orange.setFill(); rect.fill(); return true }
        try NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!.write(to: url)

        var model = SyntheticModel.cube()
        model.materials.append(SKPModel.Material(name: "Bois", color: SIMD4(0.5, 0.4, 0.3, 1), textureURL: url, textureScale: SIMD2(2, 0.5)))
        let uvs = model.root.meshes[0].positions.map { SIMD2($0.x, $0.y) }
        model.root.meshes[0].material = 1
        model.root.meshes[0].uvs = uvs                // own textured material: UVs in repeats
        model.definitions[0].meshes[0].uvs = uvs      // nil material: UVs in metres, inherited by instance A
        model.root.children[0].material = 1
        let root = ViewportScene(model: model).modelRoot.childNodes[0]

        func uv(_ m: SCNMaterial, _ p: SIMD2<Float>) -> SIMD2<Float> {
            let v = SCNVector3Make(CGFloat(p.x), CGFloat(p.y), 0), t = m.diffuse.contentsTransform
            return SIMD2(Float(v.x * t.m11 + v.y * t.m21 + t.m41), Float(v.x * t.m12 + v.y * t.m22 + t.m42))
        }
        let own = root.childNodes[0].geometry!.firstMaterial!
        XCTAssertTrue(own.diffuse.contents is NSImage)
        XCTAssertEqual(own.diffuse.wrapS, .repeat)
        XCTAssertEqual(uv(own, SIMD2(0.25, 0.25)), SIMD2(0.25, 0.75), "v flipped")
        let inherited = root.childNodes[2].childNodes[0].geometry!.firstMaterial!
        XCTAssertTrue(inherited.diffuse.contents is NSImage)
        XCTAssertTrue(inherited !== own, "metre UVs need their own transform")
        XCTAssertEqual(uv(inherited, SIMD2(1, 0.25)), SIMD2(0.5, 0.5), "1/textureScale, then the flip")
        XCTAssertTrue(root.childNodes[3].childNodes[0].geometry!.firstMaterial!.diffuse.contents is NSColor, "unpainted B stays white")
    }

    func testSnapshotIsNotUniform() throws {
        let (view, scene) = presentedView()
        view.apply(camera: scene.model.scenes[0].camera!, animated: false) // off-iso: the three visible faces differ
        let image = view.snapshot()
        if let path = ProcessInfo.processInfo.environment["VIEWPORT_SNAPSHOT"] { try image.tiffRepresentation?.write(to: URL(fileURLWithPath: path)) }
        XCTAssertEqual(image.size, view.bounds.size)
        let rep = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil).map(NSBitmapImageRep.init(cgImage:)))
        // Flat-shaded faces and 1-px edges give a dozen colours, not hundreds: check shades and coverage instead.
        let data = try XCTUnwrap(rep.bitmapData)
        var counts: [UInt32: Int] = [:], total = 0
        for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
            for x in stride(from: 0, to: rep.pixelsWide, by: 2) {
                let p = data + y * rep.bytesPerRow + x * rep.bitsPerPixel / 8
                let colour = UInt32(p[0]) << 16 | UInt32(p[1]) << 8 | UInt32(p[2])
                counts[colour, default: 0] += 1
                total += 1
            }
        }
        XCTAssertGreaterThan(counts.count, 5)
        let background = counts.values.max()! // the dark background is the most common colour
        XCTAssertTrue((0.3...0.97).contains(Double(background) / Double(total)), "\(background) / \(total)")
    }

    /// Manual probe of the edge depth bias on a real venue: `SIMPLESKP_PROBE=file.skp SIMPLESKP_PROBE_OUT=dir swift test
    /// --filter testProbeSceneSnapshots` writes one PNG per file scene camera; skipped otherwise (needs SketchUp).
    func testProbeSceneSnapshots() throws {
        let env = ProcessInfo.processInfo.environment
        guard let file = env["SIMPLESKP_PROBE"], let out = env["SIMPLESKP_PROBE_OUT"] else { throw XCTSkip("probe only") }
        let model = try SKPReader.load(URL(fileURLWithPath: file))
        let view = ViewportView(frame: NSRect(x: 0, y: 0, width: 1400, height: 900))
        let scene = ViewportScene(model: model)
        view.present(scene)
        for (i, s) in model.scenes.enumerated() {
            guard let camera = s.camera else { continue }
            view.apply(camera: camera, animated: false)
            let png = NSBitmapImageRep(data: view.snapshot().tiffRepresentation!)!.representation(using: .png, properties: [:])!
            try png.write(to: URL(fileURLWithPath: out).appendingPathComponent("scene\(i)-\(s.name).png"))
        }
    }
}
