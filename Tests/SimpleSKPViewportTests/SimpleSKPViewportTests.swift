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

    // Merged structure: one node per layer set under modelRoot, holding one face geometry per material and the edges.
    private func faces(_ scene: ViewportScene, _ layers: [Int]) -> [SCNNode] {
        scene.layerSets[layers]?.node?.childNodes.filter { $0.geometry?.elements.first?.primitiveType == .triangles } ?? []
    }

    private func edges(_ scene: ViewportScene, _ layers: [Int]) -> [SCNNode] {
        scene.layerSets[layers]?.node?.childNodes.filter { $0.geometry?.elements.first?.primitiveType == .line } ?? []
    }

    private func triangles(_ nodes: [SCNNode]) -> Int { nodes.reduce(0) { $0 + $1.geometry!.elements[0].primitiveCount } }

    /// Brief (a): the root cube and A (Layer0) merge into the {0} set, B (Cotes) into {0, 1}; no triangle lost or doubled.
    func testMergedTriangleCountsPerLayerSet() {
        let scene = ViewportScene(model: SyntheticModel.cube())
        XCTAssertEqual(Set(scene.layerSets.keys), [[0], [0, 1]])
        XCTAssertNil(scene.layerSets[[0, 1]]!.node, "Cotes is hidden: B's set is not built yet")
        scene.setLayer(1, visible: true)
        XCTAssertEqual(faces(scene, [0]).count, 1, "root cube and A share the red material: one geometry")
        XCTAssertEqual(triangles(faces(scene, [0])), 24)
        XCTAssertEqual(triangles(faces(scene, [0, 1])), 12)
        XCTAssertEqual(triangles(edges(scene, [0])), 24) // segments
        XCTAssertEqual(triangles(edges(scene, [0, 1])), 12)
        let red = faces(scene, [0])[0].geometry!.firstMaterial!
        XCTAssertEqual(red.lightingModel, .physicallyBased)
        XCTAssertEqual(red.isDoubleSided, true)
        XCTAssertTrue(faces(scene, [0, 1])[0].geometry!.firstMaterial !== red, "unpainted B: the default material")
        // Positions are in model space: A's cube sits at x 2…3.
        let (lo, hi) = faces(scene, [0])[0].geometry!.boundingBox
        XCTAssertEqual(SIMD3<Float>(lo), SIMD3(0, 0, 0))
        XCTAssertEqual(SIMD3<Float>(hi), SIMD3(3, 1, 1))
        scene.setLayer(1, visible: false)
        scene.setLayer(1, visible: true)
        XCTAssertEqual(scene.layerSets[[0, 1]]!.node!.childNodes.count, 2, "built once")
    }

    /// Brief (b): hiding Cotes hides B's set only; hiding Layer0 hides everything (every path holds it).
    func testLayers() {
        let scene = ViewportScene(model: SyntheticModel.cube())
        scene.setLayer(1, visible: true)
        let (a, b) = (scene.layerSets[[0]]!.node!, scene.layerSets[[0, 1]]!.node!)
        XCTAssertFalse(a.isHidden || b.isHidden)
        scene.setLayer(1, visible: false)
        XCTAssertTrue(b.isHidden)
        XCTAssertFalse(a.isHidden)
        scene.setLayer(0, visible: false)
        XCTAssertTrue(a.isHidden && b.isHidden)
        scene.setLayer(1, visible: true)
        XCTAssertTrue(b.isHidden, "Layer0 still hidden")
        scene.setLayer(0, visible: true)
        XCTAssertFalse(a.isHidden || b.isHidden)
    }

    /// Brief (c): an instance on B nested in a group on A is hidden when either A or B is hidden.
    func testNestedLayersHideWhenEitherIsHidden() {
        var model = SyntheticModel.cube()
        model.layers = [SKPModel.Layer(name: "Layer0", isVisible: true), SKPModel.Layer(name: "A", isVisible: true),
                        SKPModel.Layer(name: "B", isVisible: true)]
        model.definitions.append(SKPModel.Definition(name: "G", children: [
            SKPModel.Instance(definition: 0, transform: matrix_identity_float4x4, layer: 2, isGroup: false),
        ]))
        model.root.children = [SKPModel.Instance(definition: 1, transform: matrix_identity_float4x4, layer: 1, isGroup: true)]
        let scene = ViewportScene(model: model)
        XCTAssertEqual(Set(scene.layerSets.keys), [[0], [0, 1, 2]])
        let nested = scene.layerSets[[0, 1, 2]]!.node!
        for hidden in [1, 2] {
            scene.setLayer(hidden, visible: false)
            XCTAssertTrue(nested.isHidden, "layer \(hidden) hidden")
            XCTAssertFalse(scene.layerSets[[0]]!.node!.isHidden)
            scene.setLayer(hidden, visible: true)
            XCTAssertFalse(nested.isHidden)
        }
    }

    func testEdgesToggleAndLayerDoNotFight() {
        let scene = ViewportScene(model: SyntheticModel.cube())
        scene.showsEdges = false
        XCTAssertTrue(edges(scene, [0])[0].isHidden)
        XCTAssertFalse(faces(scene, [0])[0].isHidden)
        scene.setLayer(1, visible: true)
        XCTAssertTrue(edges(scene, [0, 1])[0].isHidden, "a set built while edges are off joins the toggle")
        scene.setLayer(0, visible: false)
        scene.setLayer(0, visible: true)
        XCTAssertTrue(edges(scene, [0])[0].isHidden, "showing the layer must not bring the edges back")
        scene.showsEdges = true
        XCTAssertFalse(edges(scene, [0])[0].isHidden || edges(scene, [0, 1])[0].isHidden)
    }

    func testTransparency() {
        var model = SyntheticModel.cube()
        model.materials.append(SKPModel.Material(name: "Verre", color: SIMD4(0.6, 0.8, 1, 0.5), opacity: 0.5))
        model.root.meshes[0].material = 1
        let glass = faces(ViewportScene(model: model), [0]).map { $0.geometry!.firstMaterial! }.first { $0.transparency < 1 }!
        XCTAssertEqual(glass.transparency, 0.5, accuracy: 1e-6)
        XCTAssertEqual(glass.transparencyMode, .dualLayer)
        XCTAssertFalse(glass.writesToDepthBuffer, "edges behind glass stay visible")
    }

    func testPaintedHiddenInstanceIsPaintedWhenShown() {
        var model = SyntheticModel.cube()
        // Root → group C on Layer0, painted with material 0 → unpainted instance of the box on hidden Cotes.
        model.definitions.append(SKPModel.Definition(name: "C", children: [
            SKPModel.Instance(definition: 0, transform: matrix_identity_float4x4, layer: 1, isGroup: false),
        ]))
        model.root.children.append(SKPModel.Instance(definition: 1, transform: matrix_identity_float4x4, layer: 0, isGroup: true, material: 0))
        let scene = ViewportScene(model: model)
        scene.setLayer(1, visible: true)
        let materials = faces(scene, [0, 1]).map { $0.geometry!.firstMaterial! }
        XCTAssertEqual(materials.count, 2, "B unpainted, the box in C inherits C's material")
        XCTAssertTrue(materials.contains { $0 === faces(scene, [0])[0].geometry!.firstMaterial })
    }

    func testMaterialCache() throws {
        var model = SyntheticModel.cube()
        model.root.meshes[0].uvs = model.root.meshes[0].positions.map { SIMD2($0.x, $0.y) } // untextured material with UVs
        let scene = ViewportScene(model: model)
        XCTAssertEqual(faces(scene, [0]).count, 1, "an untextured material is one SCNMaterial whatever the UVs")
        XCTAssertEqual(faces(scene, [0])[0].geometry!.sources(for: .texcoord).count, 0, "untextured: no UVs kept")
    }

    /// A mirrored instance keeps outward normals and a winding that agrees with them (double-sided lighting relies on it).
    func testMirroredInstanceNormalsAndWinding() throws {
        var model = SyntheticModel.cube()
        model.root.meshes = []
        model.root.children[0].transform.columns.0 = SIMD4(-1, 0, 0, 0) // A mirrored in x: spans 1…2
        let geometry = faces(ViewportScene(model: model), [0])[0].geometry!
        func vectors(_ semantic: SCNGeometrySource.Semantic) -> [SIMD3<Float>] { // packed Float × 3
            let f = geometry.sources(for: semantic)[0].data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            return stride(from: 0, to: f.count, by: 3).map { SIMD3(f[$0], f[$0 + 1], f[$0 + 2]) }
        }
        let (positions, normals) = (vectors(.vertex), vectors(.normal))
        let indices = geometry.elements[0].data.withUnsafeBytes { Array($0.bindMemory(to: UInt32.self)) }
        XCTAssertEqual(indices.count, 36)
        for t in stride(from: 0, to: indices.count, by: 3) {
            let (a, b, c) = (positions[Int(indices[t])], positions[Int(indices[t + 1])], positions[Int(indices[t + 2])])
            let n = normals[Int(indices[t])]
            XCTAssertGreaterThan(simd_dot(simd_cross(b - a, c - a), n), 0, "winding agrees with the normal")
            XCTAssertGreaterThan(simd_dot((a + b + c) / 3 - SIMD3(1.5, 0.5, 0.5), n), 0, "normal points outwards")
        }
    }

    /// Big groups are split into chunks under `chunkLimit` triangles, in spatial order.
    func testChunks() {
        var model = SyntheticModel.cube()
        model.root.children = (0..<6).map { i in
            var m = matrix_identity_float4x4
            m.columns.3 = SIMD4(Float(i % 2) * 10, Float(i / 2) * 10, 0, 1)
            return SKPModel.Instance(definition: 0, transform: m, layer: 0, isGroup: false, material: 0)
        }
        let limit = ViewportScene.chunkLimit
        ViewportScene.chunkLimit = 24
        defer { ViewportScene.chunkLimit = limit }
        let chunks = faces(ViewportScene(model: model), [0])
        XCTAssertEqual(chunks.count, 4, "7 cubes of 12 triangles, 2 per chunk")
        XCTAssertEqual(triangles(chunks), 84)
    }

    /// Brief (d): visible bounds leave out what is on a hidden layer, and take it in once the layer is shown.
    func testVisibleBoundsFollowLayers() {
        var model = SyntheticModel.cube()
        model.root.children[1].transform.columns.3 = SIMD4(0, 20, 0, 1) // B, on hidden Cotes, 20 m away
        let scene = ViewportScene(model: model)
        var bounds = scene.visibleBounds
        XCTAssertEqual(simd_distance(bounds.min, SIMD3(0, 0, 0)), 0, accuracy: 1e-5)
        XCTAssertEqual(simd_distance(bounds.max, SIMD3(3, 1, 1)), 0, accuracy: 1e-5, "root cube and A only")
        scene.setLayer(1, visible: true)
        bounds = scene.visibleBounds
        XCTAssertEqual(simd_distance(bounds.max, SIMD3(3, 21, 1)), 0, accuracy: 1e-5, "B joined")
        scene.setLayer(1, visible: false)
        XCTAssertEqual(simd_distance(scene.visibleBounds.max, SIMD3(3, 1, 1)), 0, accuracy: 1e-5, "B left again")
        scene.setLayer(0, visible: false)
        bounds = scene.visibleBounds
        XCTAssertEqual(bounds.max, model.boundsMax, "nothing shown: the model's bounds")
    }

    /// Edges alone on a layer set count in the bounds only while edges are shown.
    func testVisibleBoundsFollowEdges() {
        var model = SyntheticModel.cube()
        model.root.edges.append(SKPModel.EdgeSet(layer: 0, positions: [SIMD3(0, 0, 0), SIMD3(0, 0, 9)]))
        model.root.children[0].layer = 1 // only the root cube and its edges on Layer0
        model.layers[1].isVisible = false
        let scene = ViewportScene(model: model)
        XCTAssertEqual(scene.visibleBounds.max.z, 9, accuracy: 1e-5)
        scene.showsEdges = false
        XCTAssertEqual(scene.visibleBounds.max.z, 1, accuracy: 1e-5, "the edge-only height left with the edges")
        scene.showsEdges = true
        XCTAssertEqual(scene.visibleBounds.max.z, 9, accuracy: 1e-5)
    }

    func testBuildsOffMainThread() async {
        let model = SyntheticModel.cube()
        let count = await Task.detached { ViewportScene(model: model).layerSets[[0]]?.node?.childNodes.count }.value
        XCTAssertEqual(count, 2)
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
        // Zoomed past the target: the parallel scale must stay positive.
        view.cameraNode.simdWorldPosition = view.target + view.cameraNode.simdWorldFront * 3
        view.isPerspective = false
        XCTAssertGreaterThan(camera.orthographicScale, 0)
    }

    func testOrbitTurnsAroundWorldUpTowardsTheRight() {
        let (view, _) = presentedView()
        let centre = view.target // framed on the visible bounds (hidden B left out)
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
        let (view, _) = presentedView()
        let centre = view.target // framed on the visible bounds (hidden B left out)
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

    func testParallelZoomKeepsThePointUnderTheCursor() {
        let (view, scene) = presentedView()
        view.isPerspective = false
        let camera = view.cameraNode.camera!
        // Orthographic projection by hand (projectPoint needs a rendered frame); AppKit y up.
        func screen(_ p: SIMD3<Float>) -> SIMD2<Float> {
            let local = view.cameraNode.simdConvertPosition(p, from: nil)
            return SIMD2(400, 300) + SIMD2(local.x, local.y) / Float(camera.orthographicScale) * 300
        }
        let corner = scene.modelRoot.simdConvertPosition(SIMD3(1, 0, 1), to: nil)
        let before = screen(corner)
        XCTAssertGreaterThan(simd_distance(before, SIMD2(400, 300)), 20, "off the view centre")
        let target = view.target
        view.zoom(ratio: 0.8, at: CGPoint(x: CGFloat(before.x), y: CGFloat(before.y)))
        XCTAssertEqual(simd_distance(screen(corner), before), 0, accuracy: 0.05, "stays under the cursor")
        XCTAssertGreaterThan(simd_distance(view.target, target), 1e-3, "the target moved with the camera")
    }

    func testEdgesDrawnAfterFacesWithDepthBias() {
        let scene = ViewportScene(model: SyntheticModel.cube())
        scene.setLayer(1, visible: true)
        let (edges, otherEdges) = (edges(scene, [0])[0], edges(scene, [0, 1])[0])
        XCTAssertEqual(edges.renderingOrder, 1)
        XCTAssertEqual(otherEdges.renderingOrder, 1)
        XCTAssertEqual(faces(scene, [0])[0].renderingOrder, 0)
        let material = edges.geometry!.firstMaterial!
        XCTAssertTrue(material === otherEdges.geometry!.firstMaterial, "one shared edge material")
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
        let scene = ViewportScene(model: model)
        scene.setLayer(1, visible: true)
        let set0 = faces(scene, [0]).sorted { $0.geometry!.boundingBox.min.x < $1.geometry!.boundingBox.min.x } // root cube, then A

        func uv(_ m: SCNMaterial, _ p: SIMD2<Float>) -> SIMD2<Float> {
            let v = SCNVector3Make(CGFloat(p.x), CGFloat(p.y), 0), t = m.diffuse.contentsTransform
            return SIMD2(Float(v.x * t.m11 + v.y * t.m21 + t.m41), Float(v.x * t.m12 + v.y * t.m22 + t.m42))
        }
        XCTAssertEqual(set0.count, 2)
        XCTAssertEqual(set0[0].geometry!.sources(for: .texcoord).count, 1, "textured: UVs kept")
        let own = set0[0].geometry!.firstMaterial!
        XCTAssertTrue(own.diffuse.contents is NSImage)
        XCTAssertEqual(own.diffuse.wrapS, .repeat)
        XCTAssertEqual(uv(own, SIMD2(0.25, 0.25)), SIMD2(0.25, 0.75), "v flipped")
        let inherited = set0[1].geometry!.firstMaterial!
        XCTAssertTrue(inherited.diffuse.contents is NSImage)
        XCTAssertTrue(inherited !== own, "metre UVs need their own transform")
        XCTAssertEqual(uv(inherited, SIMD2(1, 0.25)), SIMD2(0.5, 0.5), "1/textureScale, then the flip")
        XCTAssertTrue(inherited.diffuse.contents as AnyObject === own.diffuse.contents as AnyObject, "one image for both variants")
        XCTAssertTrue(faces(scene, [0, 1])[0].geometry!.firstMaterial!.diffuse.contents is NSColor, "unpainted B stays white")
    }

    func testSnapshotIsNotUniform() throws {
        let (view, scene) = presentedView()
        view.apply(camera: scene.model.scenes[0].camera!, animated: false) // off-iso: the three visible faces differ
        let image = view.snapshot()
        if let path = ProcessInfo.processInfo.environment["VIEWPORT_SNAPSHOT"] { try image.tiffRepresentation?.write(to: URL(fileURLWithPath: path)) }
        XCTAssertEqual(image.size, view.bounds.size)
        let rep = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil).map(NSBitmapImageRep.init(cgImage:)))
        // The sky backdrop is a vertical gradient: uniform along a row. Model pixels are those that differ from the row's
        // left-most pixel (the cube is framed away from the edges).
        let data = try XCTUnwrap(rep.bitmapData)
        var colours = Set<UInt32>(), model = 0, total = 0
        for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
            let row = data + y * rep.bytesPerRow
            for x in stride(from: 0, to: rep.pixelsWide, by: 2) {
                let p = row + x * rep.bitsPerPixel / 8
                colours.insert(UInt32(p[0]) << 16 | UInt32(p[1]) << 8 | UInt32(p[2]))
                if (0..<3).contains(where: { abs(Int(p[$0]) - Int(row[$0])) > 6 }) { model += 1 }
                total += 1
            }
        }
        XCTAssertGreaterThan(colours.count, 5)
        XCTAssertTrue((0.03...0.7).contains(Double(model) / Double(total)), "\(model) / \(total)")
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
