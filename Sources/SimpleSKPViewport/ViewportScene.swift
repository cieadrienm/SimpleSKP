import SceneKit
import SimpleSKPCore

/// Builds the SceneKit scene for a model. May be constructed off the main thread, right after `SKPReader.load`.
/// Root node rotated −90° about X (Z up → Y up); one prototype node per definition, one child node per mesh batch
/// (tagged with its layer), instances as copies of the prototype sharing its geometry; edges as `.line` elements.
/// Instances on a hidden layer stay empty until the layer is first shown (venue models hide most of their nodes).
public final class ViewportScene {
    public let model: SKPModel
    public let scene: SCNScene
    /// The Z-up → Y-up node: everything from `SKPModel` (positions, transforms, camera) lives under it verbatim.
    public let modelRoot = SCNNode()
    /// Directional light the view attaches to its camera node (SketchUp's light follows the eye).
    public let headlight = SCNNode()

    private var materials: [Int: SCNMaterial] = [:]
    private var images: [Int: NSImage?] = [:]
    private lazy var defaultMaterial = makeMaterial(nil, uvs: .none)
    private let edgeMaterial = SCNMaterial()
    /// Kept after the build: empty instances are filled from them.
    private var definitionNodes: [Int: SCNNode] = [:]
    /// Instance nodes built while their layer was hidden, still empty: their definition and the material to paint.
    private var pending: [ObjectIdentifier: (definition: Int, material: Int?)] = [:]
    private var layerNodes: [Int: [SCNNode]] = [:]
    private var edgeNodes = Set<SCNNode>()
    private var hiddenLayers = Set<Int>()
    private var cachedVisibleBounds: (min: SIMD3<Float>, max: SIMD3<Float>)?

    public init(model: SKPModel) {
        self.model = model
        self.scene = SCNScene()
        scene.background.contents = NSColor(red: 0.067, green: 0.075, blue: 0.09, alpha: 1)

        edgeMaterial.lightingModel = .constant
        edgeMaterial.diffuse.contents = NSColor(red: 0.13, green: 0.13, blue: 0.14, alpha: 1)
        edgeMaterial.readsFromDepthBuffer = true
        edgeMaterial.writesToDepthBuffer = false
        edgeMaterial.shaderModifiers = [.geometry: Self.edgeBias]

        let start = CFAbsoluteTimeGetCurrent()
        hiddenLayers = Set(model.layers.indices.filter { !model.layers[$0].isVisible })
        modelRoot.name = "model"
        modelRoot.simdEulerAngles.x = -.pi / 2
        let root = buildDefinition(model.root)
        root.name = "root" // a definition named like "L3" must not join the layer index
        modelRoot.addChildNode(root)
        scene.rootNode.addChildNode(modelRoot)
        register(below: modelRoot)
        if ProcessInfo.processInfo.environment["SIMPLESKP_TIMING"] == "1" {
            print(String(format: "ViewportScene: %.3f s, %d layer nodes, %d empty instances", CFAbsoluteTimeGetCurrent() - start,
                         layerNodes.values.reduce(0) { $0 + $1.count }, pending.count))
        }

        let ambient = SCNLight()
        ambient.type = .ambient
        ambient.intensity = 350
        let ambientNode = SCNNode()
        ambientNode.light = ambient
        scene.rootNode.addChildNode(ambientNode)
        let sun = SCNLight()
        sun.type = .directional
        sun.intensity = 800
        headlight.light = sun
    }

    /// Shows or hides every node (meshes, edges, instances) on a layer, by index into `model.layers`.
    /// The first time a layer is shown, its empty instances are filled (main thread, like any scene edit).
    public func setLayer(_ index: Int, visible: Bool) {
        if visible { hiddenLayers.remove(index) } else { hiddenLayers.insert(index) }
        cachedVisibleBounds = nil
        for node in layerNodes[index] ?? [] {
            if visible, pending[ObjectIdentifier(node)] != nil {
                fill(node)
                register(below: node)
            }
            node.isHidden = !visible || (!showsEdges && edgeNodes.contains(node))
        }
    }

    public var showsEdges: Bool = true {
        didSet {
            for node in edgeNodes {
                let layer = Int(node.name!.dropFirst())!
                node.isHidden = !showsEdges || hiddenLayers.contains(layer)
            }
        }
    }

    /// Bounds of what is shown, in model space (metres, Z up): hidden subtrees and still-empty instances are left out.
    /// The model's bounds when nothing is shown. Main thread; recomputed after a layer change.
    public var visibleBounds: (min: SIMD3<Float>, max: SIMD3<Float>) {
        if let cachedVisibleBounds { return cachedVisibleBounds }
        var lo = SIMD3<Float>(repeating: .infinity), hi = SIMD3<Float>(repeating: -.infinity)
        func walk(_ node: SCNNode, _ transform: simd_float4x4) {
            for child in node.childNodes where !child.isHidden {
                let m = transform * child.simdTransform
                if let geometry = child.geometry {
                    let (a, b) = geometry.boundingBox
                    let (p, q) = (SIMD3<Float>(a), SIMD3<Float>(b))
                    for i in 0..<8 {
                        let corner = SIMD3(i & 1 == 0 ? p.x : q.x, i & 2 == 0 ? p.y : q.y, i & 4 == 0 ? p.z : q.z)
                        let w = m * SIMD4(corner, 1)
                        lo = simd_min(lo, SIMD3(w.x, w.y, w.z)); hi = simd_max(hi, SIMD3(w.x, w.y, w.z))
                    }
                }
                walk(child, m)
            }
        }
        walk(modelRoot, matrix_identity_float4x4)
        let bounds = lo.x <= hi.x ? (lo, hi) : (model.boundsMin, model.boundsMax)
        cachedVisibleBounds = bounds
        return bounds
    }

    /// Indexes the layer-tagged nodes under `node` (in the scene) and gives them their visibility.
    private func register(below node: SCNNode) {
        for child in node.childNodes {
            child.enumerateHierarchy { node, _ in
                guard let layer = Self.layer(of: node) else { return }
                layerNodes[layer, default: []].append(node)
                let isEdge = node.geometry?.elements.first?.primitiveType == .line
                if isEdge { edgeNodes.insert(node) }
                node.isHidden = hiddenLayers.contains(layer) || (isEdge && !showsEdges)
            }
        }
    }

    private static func layer(of node: SCNNode) -> Int? {
        guard let name = node.name, name.first == "L" else { return nil }
        return Int(name.dropFirst())
    }

    // MARK: - Building

    private func buildDefinition(_ definition: SKPModel.Definition) -> SCNNode {
        let node = SCNNode()
        node.name = definition.name
        for mesh in definition.meshes {
            let child = SCNNode(geometry: geometry(mesh, material: mesh.material))
            child.name = "L\(mesh.layer)"
            node.addChildNode(child)
        }
        for edges in definition.edges where !edges.positions.isEmpty {
            let indices = [UInt32](0..<UInt32(edges.positions.count))
            let element = SCNGeometryElement(data: indices.withUnsafeBytes { Data($0) }, primitiveType: .line,
                                             primitiveCount: indices.count / 2, bytesPerIndex: 4)
            let geometry = SCNGeometry(sources: [vectorSource(edges.positions, .vertex)], elements: [element])
            geometry.materials = [edgeMaterial]
            let child = SCNNode(geometry: geometry)
            child.name = "L\(edges.layer)"
            child.renderingOrder = 1 // after the faces, so the depth test sees them
            node.addChildNode(child)
        }
        for instance in definition.children {
            let child: SCNNode
            if hiddenLayers.contains(instance.layer) {
                child = SCNNode()
                pending[ObjectIdentifier(child)] = (instance.definition, instance.material)
            } else {
                child = instantiate(definitionNode(instance.definition))
                if let material = instance.material { paint(child, model.definitions[instance.definition], material) }
            }
            child.simdTransform = instance.transform
            child.name = "L\(instance.layer)"
            node.addChildNode(child)
        }
        return node
    }

    /// Copies a prototype subtree sharing its geometry: about twice as fast as `clone()`, which also copies
    /// animations, actions and the other node attributes the scene never sets.
    private func instantiate(_ prototype: SCNNode) -> SCNNode {
        let node = SCNNode()
        node.geometry = prototype.geometry
        node.name = prototype.name
        node.simdTransform = prototype.simdTransform
        node.renderingOrder = prototype.renderingOrder
        if let record = pending[ObjectIdentifier(prototype)] {
            pending[ObjectIdentifier(node)] = record
            if let layer = Self.layer(of: node), !hiddenLayers.contains(layer) { fill(node) } // shown since the prototype was built
            return node
        }
        for child in prototype.childNodes { node.addChildNode(instantiate(child)) }
        return node
    }

    /// Gives an empty instance node its definition's content (`register(below:)` is the caller's job).
    private func fill(_ node: SCNNode) {
        guard let record = pending.removeValue(forKey: ObjectIdentifier(node)) else { return }
        for child in definitionNode(record.definition).childNodes { node.addChildNode(instantiate(child)) }
        if let material = record.material { paint(node, model.definitions[record.definition], material) }
    }

    private func definitionNode(_ index: Int) -> SCNNode {
        if let node = definitionNodes[index] { return node }
        let node = buildDefinition(model.definitions[index])
        definitionNodes[index] = node
        return node
    }

    /// Gives the instance's material to the faces that have none, down through nested unpainted instances
    /// (SketchUp inheritance). Children order mirrors `buildDefinition`: meshes, edge sets, instances.
    private func paint(_ node: SCNNode, _ definition: SKPModel.Definition, _ material: Int) {
        let children = node.childNodes
        for (i, mesh) in definition.meshes.enumerated() where mesh.material == nil {
            let copy = children[i].geometry!.copy() as! SCNGeometry
            copy.materials = [scnMaterial(material, uvs: mesh.uvs == nil ? .none : .metres)]
            children[i].geometry = copy
        }
        let offset = definition.meshes.count + definition.edges.filter { !$0.positions.isEmpty }.count
        for (j, instance) in definition.children.enumerated() where instance.material == nil {
            let child = children[offset + j]
            if pending[ObjectIdentifier(child)] != nil {
                pending[ObjectIdentifier(child)]!.material = material // painted when filled
            } else {
                paint(child, model.definitions[instance.definition], material)
            }
        }
    }

    private func geometry(_ mesh: SKPModel.Mesh, material: Int?) -> SCNGeometry {
        var sources = [vectorSource(mesh.positions, .vertex), vectorSource(mesh.normals, .normal)]
        if let uvs = mesh.uvs {
            sources.append(SCNGeometrySource(data: uvs.withUnsafeBytes { Data($0) }, semantic: .texcoord, vectorCount: uvs.count,
                                             usesFloatComponents: true, componentsPerVector: 2, bytesPerComponent: 4,
                                             dataOffset: 0, dataStride: MemoryLayout<SIMD2<Float>>.stride))
        }
        let element = SCNGeometryElement(data: mesh.indices.withUnsafeBytes { Data($0) }, primitiveType: .triangles,
                                         primitiveCount: mesh.indices.count / 3, bytesPerIndex: 4)
        let geometry = SCNGeometry(sources: sources, elements: [element])
        geometry.materials = [material.map { scnMaterial($0, uvs: mesh.uvs == nil ? .none : .repeats) } ?? defaultMaterial]
        return geometry
    }

    private func vectorSource(_ vectors: [SIMD3<Float>], _ semantic: SCNGeometrySource.Semantic) -> SCNGeometrySource {
        SCNGeometrySource(data: vectors.withUnsafeBytes { Data($0) }, semantic: semantic, vectorCount: vectors.count,
                          usesFloatComponents: true, componentsPerVector: 3, bytesPerComponent: 4,
                          dataOffset: 0, dataStride: MemoryLayout<SIMD3<Float>>.stride)
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
        material.lightingModel = .lambert
        material.isDoubleSided = true
        material.isLitPerPixel = false
        guard let index else { material.diffuse.contents = NSColor.white; return material }
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
