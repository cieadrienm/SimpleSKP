import SceneKit
import SimpleSKPCore

/// Builds the SceneKit scene for a model. May be constructed off the main thread, right after `SKPReader.load`.
/// Root node rotated −90° about X (Z up → Y up). The instance tree is flattened: SketchUp shows an entity iff every layer
/// on its path is visible, so all faces sharing a layer set (the layers along their path) and a resolved material are
/// merged into one geometry in model space, and all edges of a layer set into one `.line` geometry — a few hundred draw
/// calls instead of one per instance. A layer set is built the first time all its layers are visible.
public final class ViewportScene {
    public let model: SKPModel
    public let scene: SCNScene
    /// The Z-up → Y-up node: everything from `SKPModel` (positions, transforms, camera) lives under it verbatim.
    public let modelRoot = SCNNode()
    /// Node the view attaches to its camera; it holds the low ambient fill (the sun and the sky do the lighting).
    public let headlight = SCNNode()
    /// The sun (D7): directional, elevation 45°, azimuth 135° clockwise from +X (from the south-west: the iso view, seen
    /// from the south-east, then shows two differently lit faces and the shadows in front), soft cascaded shadows.
    public let sun = SCNNode()

    public var shadowsEnabled = true {
        didSet { sun.light!.castsShadow = shadowsEnabled }
    }

    /// High: 3 cascades of 2048²; low: 1 of 1024², for a scene over 33 ms (the app decides; D7).
    public private(set) var shadowQualityIsHigh = true

    public func setShadowQuality(_ high: Bool) {
        shadowQualityIsHigh = high
        sun.light!.shadowCascadeCount = high ? 3 : 1
        sun.light!.shadowMapSize = high ? CGSize(width: 2048, height: 2048) : CGSize(width: 1024, height: 1024)
    }

    /// The faces and edges drawn under one set of layers; `node` is nil until the set is first visible.
    final class LayerSet {
        let layers: [Int]
        /// Indices into `placements` whose definition has meshes or edges on this exact set.
        var placements: [Int] = []
        var node: SCNNode?
        init(layers: [Int]) { self.layers = layers }
    }

    /// A definition placed in the flattened tree (-1 = the root): model-space transform, material its unpainted faces
    /// inherit, sorted layers along its path (its own instance layer included).
    private struct Placement {
        var definition: Int
        var transform: simd_float4x4
        var material: Int?
        var layers: [Int]
    }

    private var materials: [Int: SCNMaterial] = [:]
    private var images: [Int: NSImage?] = [:]
    private lazy var defaultMaterial = makeMaterial(nil, uvs: .none)
    private let edgeMaterial = SCNMaterial()
    private var placements: [Placement] = []
    private(set) var layerSets: [[Int]: LayerSet] = [:]
    private var setsByLayer: [Int: [LayerSet]] = [:]
    private var edgeNodes: [SCNNode] = []
    private var hiddenLayers = Set<Int>()
    private var cachedVisibleBounds: (min: SIMD3<Float>, max: SIMD3<Float>)?

    public init(model: SKPModel) {
        self.model = model
        self.scene = SCNScene()
        scene.background.contents = Rendering.skyImage(backdrop: true)
        scene.lightingEnvironment.contents = Rendering.skyImage()
        scene.lightingEnvironment.intensity = 1

        edgeMaterial.lightingModel = .constant
        edgeMaterial.diffuse.contents = NSColor(white: 0.3, alpha: 1) // opaque: alpha-blended lines vanish behind HDR faces
        edgeMaterial.readsFromDepthBuffer = true
        edgeMaterial.writesToDepthBuffer = false
        edgeMaterial.shaderModifiers = [.geometry: Self.edgeBias]

        let start = CFAbsoluteTimeGetCurrent()
        hiddenLayers = Set(model.layers.indices.filter { !model.layers[$0].isVisible })
        modelRoot.name = "model"
        modelRoot.simdEulerAngles.x = -.pi / 2
        scene.rootNode.addChildNode(modelRoot)
        place(-1, transform: matrix_identity_float4x4, material: nil, layers: [])
        build(layerSets.values.filter(isVisible))
        if ProcessInfo.processInfo.environment["SIMPLESKP_TIMING"] == "1" {
            print(String(format: "ViewportScene: %.3f s, %d placements, %d layer sets (%d built), %d nodes", CFAbsoluteTimeGetCurrent() - start,
                         placements.count, layerSets.count, layerSets.values.filter { $0.node != nil }.count,
                         modelRoot.childNodes.reduce(0) { $0 + $1.childNodes.count }))
        }

        let fill = SCNLight()
        fill.type = .ambient
        fill.intensity = 150 // interiors out of the sun are not pitch black
        headlight.light = fill

        let light = SCNLight()
        light.type = .directional
        light.intensity = 1000
        light.castsShadow = true
        light.shadowMode = .forward
        light.shadowRadius = 3
        light.shadowSampleCount = 8
        light.automaticallyAdjustsShadowProjection = true
        light.shadowColor = NSColor(white: 0, alpha: 0.55)
        sun.light = light
        sun.name = "sun"
        setShadowQuality(true)
        let azimuth = -Float.pi * 3 / 4, elevation = Float.pi / 4
        let toSun = SIMD3(cos(azimuth) * cos(elevation), sin(azimuth) * cos(elevation), sin(elevation))
        sun.simdLook(at: -toSun, up: SIMD3(0, 0, 1), localFront: SCNNode.simdLocalFront)
        modelRoot.addChildNode(sun)
        updateShadowDistance()
    }

    /// Shows or hides everything on a layer, by index into `model.layers`: a layer set is shown iff all its layers are.
    /// Sets shown for the first time are built here (main thread, like any scene edit).
    public func setLayer(_ index: Int, visible: Bool) {
        if visible { hiddenLayers.remove(index) } else { hiddenLayers.insert(index) }
        cachedVisibleBounds = nil
        let sets = setsByLayer[index] ?? []
        build(sets.filter { $0.node == nil && isVisible($0) })
        for set in sets { set.node?.isHidden = !isVisible(set) }
        updateShadowDistance()
    }

    /// Cascades spread over what is shown. The distance counts from the eye, which the framing puts up to ~2 diagonals
    /// away: D7's diagonal × 1.5 cut the far shadows off in the iso view, × 4 covers it.
    private func updateShadowDistance() {
        let bounds = visibleBounds
        sun.light!.maximumShadowDistance = CGFloat(simd_distance(bounds.min, bounds.max) * 4)
    }

    public var showsEdges: Bool = true {
        didSet { for node in edgeNodes { node.isHidden = !showsEdges } }
    }

    /// Bounds of what is shown, in model space (metres, Z up): hidden layer sets are left out.
    /// The model's bounds when nothing is shown. Main thread; recomputed after a layer change.
    public var visibleBounds: (min: SIMD3<Float>, max: SIMD3<Float>) {
        if let cachedVisibleBounds { return cachedVisibleBounds }
        var lo = SIMD3<Float>(repeating: .infinity), hi = SIMD3<Float>(repeating: -.infinity)
        for set in layerSets.values {
            guard let node = set.node, !node.isHidden else { continue }
            for child in node.childNodes where child.geometry != nil { // merged geometries are in model space
                let (a, b) = child.geometry!.boundingBox
                lo = simd_min(lo, SIMD3(a)); hi = simd_max(hi, SIMD3(b))
            }
        }
        let bounds = lo.x <= hi.x ? (lo, hi) : (model.boundsMin, model.boundsMax)
        cachedVisibleBounds = bounds
        return bounds
    }

    private func isVisible(_ set: LayerSet) -> Bool { set.layers.allSatisfy { !hiddenLayers.contains($0) } }

    // MARK: - Flattening

    private func definition(_ index: Int) -> SKPModel.Definition { index < 0 ? model.root : model.definitions[index] }

    /// Records a placement and joins it to the layer sets of its meshes and edges, then recurses into its instances.
    private func place(_ index: Int, transform: simd_float4x4, material: Int?, layers: [Int]) {
        let definition = definition(index)
        let p = placements.count
        placements.append(Placement(definition: index, transform: transform, material: material, layers: layers))
        var joined: [[Int]] = []
        for layer in definition.meshes.map(\.layer) + definition.edges.filter({ !$0.positions.isEmpty }).map(\.layer) {
            let key = Self.adding(layer, to: layers)
            guard !joined.contains(key) else { continue }
            joined.append(key)
            layerSet(key).placements.append(p)
        }
        for instance in definition.children {
            place(instance.definition, transform: transform * instance.transform, material: instance.material ?? material,
                  layers: Self.adding(instance.layer, to: layers))
        }
    }

    private func layerSet(_ layers: [Int]) -> LayerSet {
        if let set = layerSets[layers] { return set }
        let set = LayerSet(layers: layers)
        layerSets[layers] = set
        for layer in layers { setsByLayer[layer, default: []].append(set) }
        return set
    }

    private static func adding(_ layer: Int, to layers: [Int]) -> [Int] {
        layers.contains(layer) ? layers : (layers + [layer]).sorted()
    }

    // MARK: - Merging

    /// Faces of one placement's mesh (or one edge set when `material` is nil) going into a merged geometry.
    private struct Piece { var placement: Int; var item: Int }

    /// One merged geometry to build: a material (nil = edges), whether it carries UVs, its pieces and sizes.
    private struct Chunk {
        var set: LayerSet
        var material: SCNMaterial?
        var textured = false
        var pieces: [Piece] = []
        var vertices = 0
        var indices = 0
    }

    /// Edge nodes' category: a pick passes `.categoryBitMask: 1` (faces) so lines, hit with a tolerance, never win.
    public static let edgeCategory = 2

    /// Chunks stay under this many triangles (or segments): spatially compact pieces keep frustum culling, shadow
    /// cascades and hit tests cheap, for a few more draw calls.
    static var chunkLimit = 250_000

    /// Builds the nodes of `sets`: grouping (serial: materials are resolved and cached), merging (parallel), nodes (serial).
    private func build(_ sets: [LayerSet]) {
        guard !sets.isEmpty else { return }
        var chunks: [Chunk] = []
        for set in sets {
            var groups: [ObjectIdentifier: [(piece: Piece, key: UInt32, size: Int, vertices: Int)]] = [:]
            var groupMaterial: [ObjectIdentifier: SCNMaterial] = [:]
            var edges: [(piece: Piece, key: UInt32, size: Int, vertices: Int)] = []
            for p in set.placements {
                let placement = placements[p], definition = definition(placement.definition)
                for (i, mesh) in definition.meshes.enumerated() where Self.adding(mesh.layer, to: placement.layers) == set.layers {
                    let material = resolvedMaterial(mesh, inherited: placement.material)
                    let id = ObjectIdentifier(material)
                    groupMaterial[id] = material
                    groups[id, default: []].append((Piece(placement: p, item: i), spatialKey(mesh.positions.first ?? .zero, placement.transform),
                                                    mesh.indices.count / 3, mesh.positions.count))
                }
                for (i, edgeSet) in definition.edges.enumerated()
                where !edgeSet.positions.isEmpty && Self.adding(edgeSet.layer, to: placement.layers) == set.layers {
                    edges.append((Piece(placement: p, item: i), spatialKey(edgeSet.positions.first ?? .zero, placement.transform),
                                  edgeSet.positions.count / 2, edgeSet.positions.count))
                }
            }
            func split(_ items: [(piece: Piece, key: UInt32, size: Int, vertices: Int)], _ material: SCNMaterial?) {
                let textured = material?.diffuse.contents is NSImage
                var chunk = Chunk(set: set, material: material, textured: textured)
                for item in items.sorted(by: { $0.key < $1.key }) {
                    if chunk.indices > 0, chunk.indices + item.size * 3 > Self.chunkLimit * 3 {
                        chunks.append(chunk)
                        chunk = Chunk(set: set, material: material, textured: textured)
                    }
                    chunk.pieces.append(item.piece)
                    chunk.vertices += item.vertices
                    chunk.indices += item.size * (material == nil ? 2 : 3)
                }
                if !chunk.pieces.isEmpty { chunks.append(chunk) }
            }
            for (id, items) in groups { split(items, groupMaterial[id]) }
            split(edges, nil)
        }

        if ProcessInfo.processInfo.environment["SIMPLESKP_TIMING"] == "1" {
            let faces = chunks.filter { $0.material != nil }, edges = chunks.filter { $0.material == nil }
            let bytes = faces.reduce(0) { $0 + $1.vertices * ($1.textured ? 32 : 24) + $1.indices * 4 } + edges.reduce(0) { $0 + $1.vertices * 16 }
            let largest = Dictionary(grouping: faces) { ObjectIdentifier($0.set) }.values.map { $0.reduce(0) { $0 + $1.indices / 3 } }.max() ?? 0
            print(String(format: "ViewportScene: building %d layer sets, %d chunks, %.2f M triangles (largest set %.2f M), %.2f M segments, %.0f MB",
                         sets.count, chunks.count, Double(faces.reduce(0) { $0 + $1.indices / 3 }) / 1e6, Double(largest) / 1e6,
                         Double(edges.reduce(0) { $0 + $1.vertices / 2 }) / 1e6, Double(bytes) / 1_048_576))
        }
        var merged = [Merged](repeating: Merged(), count: chunks.count)
        merged.withUnsafeMutableBufferPointer { out in
            let out = out // the closure below may not capture an inout parameter
            DispatchQueue.concurrentPerform(iterations: chunks.count) { i in
                out[i] = chunks[i].material == nil ? mergeEdges(chunks[i]) : mergeFaces(chunks[i])
            }
        }

        for set in sets {
            let node = SCNNode()
            node.name = set.layers.map(String.init).joined(separator: ",")
            set.node = node
            modelRoot.addChildNode(node)
        }
        for (chunk, data) in zip(chunks, merged) {
            let child = SCNNode(geometry: chunk.material == nil ? edgeGeometry(data.positions, data.indices, count: chunk.vertices) : faceGeometry(chunk, data))
            if chunk.material == nil {
                child.categoryBitMask = Self.edgeCategory
                child.castsShadow = false
                child.renderingOrder = 1 // after the faces, so the depth test sees them
                child.isHidden = !showsEdges
                edgeNodes.append(child)
            }
            chunk.set.node!.addChildNode(child)
        }
    }

    /// Morton order of a point's model-space position on a 1024³ grid over the model's bounds.
    private func spatialKey(_ point: SIMD3<Float>, _ transform: simd_float4x4) -> UInt32 {
        let w = transform * SIMD4(point, 1)
        let unit = (SIMD3(w.x, w.y, w.z) - model.boundsMin) / simd_max(model.boundsMax - model.boundsMin, SIMD3(repeating: 1e-6))
        let cell = SIMD3<UInt32>(simd_clamp(unit, .zero, SIMD3(repeating: 1)) * 1023)
        func spread(_ v: UInt32) -> UInt32 {
            var x = v & 0x3ff
            x = (x | x << 16) & 0x030000ff; x = (x | x << 8) & 0x0300f00f
            x = (x | x << 4) & 0x030c30c3; x = (x | x << 2) & 0x09249249
            return x
        }
        return spread(cell.x) | spread(cell.y) << 1 | spread(cell.z) << 2
    }

    /// A merged geometry's buffers, one per source: SceneKit copies a shared interleaved buffer once per source.
    private struct Merged {
        var positions = Data(), normals = Data(), uvs = Data(), indices = Data()
    }

    /// Positions, normals (and UVs when textured) in model space, packed `Float`s; 32-bit indices rebased per piece.
    private func mergeFaces(_ chunk: Chunk) -> Merged {
        var out = Merged(positions: Data(count: chunk.vertices * 12), normals: Data(count: chunk.vertices * 12),
                         uvs: Data(count: chunk.textured ? chunk.vertices * 8 : 0), indices: Data(count: chunk.indices * 4))
        out.positions.withUnsafeMutableBytes { pb in
            out.normals.withUnsafeMutableBytes { nb in
                out.uvs.withUnsafeMutableBytes { ub in
                    out.indices.withUnsafeMutableBytes { ib in
                        let pv = pb.bindMemory(to: Float.self).baseAddress!, nv = nb.bindMemory(to: Float.self).baseAddress!
                        let uv = ub.bindMemory(to: SIMD2<Float>.self).baseAddress, ix = ib.bindMemory(to: UInt32.self).baseAddress!
                        var vo = 0, io = 0, base: UInt32 = 0
                        for piece in chunk.pieces {
                            let placement = placements[piece.placement]
                            let mesh = definition(placement.definition).meshes[piece.item]
                            let m = placement.transform
                            let linear = simd_float3x3(SIMD3(m.columns.0.x, m.columns.0.y, m.columns.0.z), SIMD3(m.columns.1.x, m.columns.1.y, m.columns.1.z),
                                                       SIMD3(m.columns.2.x, m.columns.2.y, m.columns.2.z))
                            let normalMatrix = linear.inverse.transpose // what SceneKit applies per node
                            // A mirrored placement reverses the winding: swap two indices so it agrees with the transformed normal.
                            let (b, c) = simd_determinant(linear) < 0 ? (2, 1) : (1, 2)
                            mesh.positions.withUnsafeBufferPointer { positions in
                                mesh.normals.withUnsafeBufferPointer { normals in
                                    for i in 0..<positions.count {
                                        let p = m * SIMD4(positions[i], 1), n = simd_normalize(normalMatrix * normals[i])
                                        let o = (vo + i) * 3
                                        pv[o] = p.x; pv[o + 1] = p.y; pv[o + 2] = p.z
                                        nv[o] = n.x; nv[o + 1] = n.y; nv[o + 2] = n.z
                                    }
                                }
                            }
                            if chunk.textured, let uv, let uvs = mesh.uvs { for (i, t) in uvs.enumerated() { uv[vo + i] = t } }
                            mesh.indices.withUnsafeBufferPointer { idx in
                                var t = 0
                                while t < idx.count {
                                    ix[io] = base + idx[t]; ix[io + 1] = base + idx[t + b]; ix[io + 2] = base + idx[t + c]
                                    io += 3; t += 3
                                }
                            }
                            vo += mesh.positions.count
                            base += UInt32(mesh.positions.count)
                        }
                    }
                }
            }
        }
        return out
    }

    /// Packed segment end points in model space, with explicit indices (implicit ones were not re-tested after an unrelated crash).
    private func mergeEdges(_ chunk: Chunk) -> Merged {
        var out = Merged(positions: Data(count: chunk.vertices * 12))
        out.indices = [UInt32](0..<UInt32(chunk.vertices)).withUnsafeBytes { Data($0) }
        out.positions.withUnsafeMutableBytes { vb in
            let v = vb.bindMemory(to: Float.self).baseAddress!
            var vo = 0
            for piece in chunk.pieces {
                let placement = placements[piece.placement], m = placement.transform
                for point in definition(placement.definition).edges[piece.item].positions {
                    let p = m * SIMD4(point, 1)
                    v[vo] = p.x; v[vo + 1] = p.y; v[vo + 2] = p.z
                    vo += 3
                }
            }
        }
        return out
    }

    private func faceGeometry(_ chunk: Chunk, _ merged: Merged) -> SCNGeometry {
        func source(_ data: Data, _ semantic: SCNGeometrySource.Semantic, components: Int) -> SCNGeometrySource {
            SCNGeometrySource(data: data, semantic: semantic, vectorCount: chunk.vertices, usesFloatComponents: true,
                              componentsPerVector: components, bytesPerComponent: 4, dataOffset: 0, dataStride: components * 4)
        }
        var sources = [source(merged.positions, .vertex, components: 3), source(merged.normals, .normal, components: 3)]
        if chunk.textured { sources.append(source(merged.uvs, .texcoord, components: 2)) }
        let element = SCNGeometryElement(data: merged.indices, primitiveType: .triangles, primitiveCount: chunk.indices / 3, bytesPerIndex: 4)
        let geometry = SCNGeometry(sources: sources, elements: [element])
        geometry.materials = [chunk.material!]
        return geometry
    }

    private func edgeGeometry(_ vertices: Data, _ indices: Data, count: Int) -> SCNGeometry {
        let source = SCNGeometrySource(data: vertices, semantic: .vertex, vectorCount: count, usesFloatComponents: true,
                                       componentsPerVector: 3, bytesPerComponent: 4, dataOffset: 0, dataStride: 12)
        let element = SCNGeometryElement(data: indices, primitiveType: .line, primitiveCount: count / 2, bytesPerIndex: 4)
        let geometry = SCNGeometry(sources: [source], elements: [element])
        geometry.materials = [edgeMaterial]
        return geometry
    }

    /// SketchUp inheritance: a face without material takes the one of the nearest painted enclosing instance; its UVs
    /// are then in metres. Unpainted all the way up: the default material.
    private func resolvedMaterial(_ mesh: SKPModel.Mesh, inherited: Int?) -> SCNMaterial {
        if let index = mesh.material { return scnMaterial(index, uvs: mesh.uvs == nil ? .none : .repeats) }
        if let index = inherited { return scnMaterial(index, uvs: mesh.uvs == nil ? .none : .metres) }
        return defaultMaterial
    }

    /// How a mesh's UVs are expressed: none, texture repeats (own material), metres (material inherited from an instance).
    private enum UVs: Int { case none, repeats, metres }

    /// One shared `SCNMaterial` per model material and UV kind, so SceneKit can batch identical draws.
    private func scnMaterial(_ index: Int, uvs: UVs) -> SCNMaterial {
        let uvs = image(index) == nil ? .none : uvs // untextured: one material whatever the UVs
        let key = index * 3 + uvs.rawValue
        if let material = materials[key] { return material }
        let material = makeMaterial(index, uvs: uvs)
        materials[key] = material
        return material
    }

    /// One image per textured material, shared by its repeats and metres variants.
    private func image(_ index: Int) -> NSImage? {
        if let image = images[index] { return image }
        let image = model.materials[index].textureURL.flatMap(NSImage.init(contentsOf:))
        images[index] = image
        return image
    }

    private func makeMaterial(_ index: Int?, uvs: UVs) -> SCNMaterial {
        let material = SCNMaterial()
        material.lightingModel = .physicallyBased
        material.roughness.contents = 0.85
        material.metalness.contents = 0
        material.isDoubleSided = true
        guard let index else { material.diffuse.contents = NSColor(white: 0.96, alpha: 1); return material }
        let source = model.materials[index]
        if uvs != .none, let image = image(index) {
            material.diffuse.contents = image
            material.diffuse.wrapS = .repeat
            material.diffuse.wrapT = .repeat
            // SketchUp's v grows upwards, SceneKit samples v = 0 at the image top: flip (after metres → repeats).
            let flip = SCNMatrix4Mult(SCNMatrix4MakeScale(1, -1, 1), SCNMatrix4MakeTranslation(0, 1, 0))
            let scale = uvs == .metres ? SCNMatrix4MakeScale(CGFloat(1 / source.textureScale.x), CGFloat(1 / source.textureScale.y), 1)
                                       : SCNMatrix4Identity
            material.diffuse.contentsTransform = SCNMatrix4Mult(scale, flip)
        } else {
            let c = source.color
            material.diffuse.contents = NSColor(srgbRed: CGFloat(c.x), green: CGFloat(c.y), blue: CGFloat(c.z), alpha: 1)
        }
        if source.opacity < 1 {
            material.transparency = CGFloat(source.opacity)
            material.transparencyMode = .dualLayer
            material.writesToDepthBuffer = false // edges behind glass stay visible
        }
        return material
    }

    /// Edges lie on their faces: pull them towards the eye so the depth test keeps them in front of coplanar faces but
    /// behind anything really in front. Perspective: ε = 0.1 % of their depth (3 cm at 30 m), a uniform scale in view
    /// space (the projection of x, y is unchanged); orthographic: ε × the visible half-height, so it follows the zoom.
    static let edgeBias = """
    float4 vp = scn_node.modelViewTransform * _geometry.position;
    if (scn_frame.projectionTransform[2][3] != 0.0) { vp.xyz *= 0.999; } else { vp.z += 0.001 / scn_frame.projectionTransform[1][1]; }
    _geometry.position = scn_node.inverseModelViewTransform * vp;
    """
}
