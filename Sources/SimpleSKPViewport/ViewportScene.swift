import SceneKit
import SimpleSKPCore

/// Builds the SceneKit scene for a model. May be constructed off the main thread, right after `SKPReader.load`.
/// Root node rotated −90° about X (Z up → Y up); one node per definition, one child node per mesh batch
/// (tagged with its layer), instances by `clone()` sharing geometry; edges as `.line` elements.
public final class ViewportScene {
    public let model: SKPModel
    public let scene: SCNScene
    /// The Z-up → Y-up node: everything from `SKPModel` (positions, transforms, camera) lives under it verbatim.
    public let modelRoot = SCNNode()
    /// Directional light the view attaches to its camera node (SketchUp's light follows the eye).
    public let headlight = SCNNode()

    private var materials: [Int: SCNMaterial] = [:]
    private lazy var defaultMaterial = makeMaterial(nil, uvs: .none)
    private let edgeMaterial = SCNMaterial()
    private var definitionNodes: [Int: SCNNode] = [:]
    private var layerNodes: [Int: [SCNNode]] = [:]
    private var edgeNodes = Set<SCNNode>()
    private var hiddenLayers = Set<Int>()

    public init(model: SKPModel) {
        self.model = model
        self.scene = SCNScene()
        scene.background.contents = NSColor(red: 0.067, green: 0.075, blue: 0.09, alpha: 1)

        edgeMaterial.lightingModel = .constant
        edgeMaterial.diffuse.contents = NSColor(red: 0.13, green: 0.13, blue: 0.14, alpha: 1)
        edgeMaterial.readsFromDepthBuffer = true
        edgeMaterial.writesToDepthBuffer = false
        edgeMaterial.shaderModifiers = [.geometry: Self.edgeBias]

        modelRoot.name = "model"
        modelRoot.simdEulerAngles.x = -.pi / 2
        let root = buildDefinition(model.root)
        root.name = "root" // a definition named like "L3" must not join the layer index
        modelRoot.addChildNode(root)
        definitionNodes = [:]
        scene.rootNode.addChildNode(modelRoot)

        modelRoot.enumerateHierarchy { node, _ in
            guard let name = node.name, name.first == "L", let layer = Int(name.dropFirst()) else { return }
            layerNodes[layer, default: []].append(node)
            if node.geometry?.elements.first?.primitiveType == .line { edgeNodes.insert(node) }
        }
        for (i, layer) in model.layers.enumerated() where !layer.isVisible { setLayer(i, visible: false) }

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
    public func setLayer(_ index: Int, visible: Bool) {
        if visible { hiddenLayers.remove(index) } else { hiddenLayers.insert(index) }
        for node in layerNodes[index] ?? [] { node.isHidden = !visible || (!showsEdges && edgeNodes.contains(node)) }
    }

    public var showsEdges: Bool = true {
        didSet {
            for node in edgeNodes {
                let layer = Int(node.name!.dropFirst())!
                node.isHidden = !showsEdges || hiddenLayers.contains(layer)
            }
        }
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
            let child = definitionNode(instance.definition).clone()
            child.simdTransform = instance.transform
            child.name = "L\(instance.layer)"
            if let material = instance.material { paint(child, model.definitions[instance.definition], material) }
            node.addChildNode(child)
        }
        return node
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
            paint(children[offset + j], model.definitions[instance.definition], material)
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
        let key = index * 3 + uvs.rawValue
        if let material = materials[key] { return material }
        let material = makeMaterial(index, uvs: uvs)
        materials[key] = material
        return material
    }

    private func makeMaterial(_ index: Int?, uvs: UVs) -> SCNMaterial {
        let material = SCNMaterial()
        material.lightingModel = .lambert
        material.isDoubleSided = true
        material.isLitPerPixel = false
        guard let index else { material.diffuse.contents = NSColor.white; return material }
        let source = model.materials[index]
        if uvs != .none, let url = source.textureURL, let image = NSImage(contentsOf: url) {
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
        }
        return material
    }

    /// Edges lie on their faces: pull them towards the eye by ε = 0.1 % of their depth so the depth test keeps them
    /// in front of coplanar faces but behind anything really in front (3 cm at 30 m). Perspective: uniform scale in
    /// view space (the projection of x, y is unchanged); orthographic: depth only.
    static let edgeBias = """
    float4 vp = scn_node.modelViewTransform * _geometry.position;
    if (scn_frame.projectionTransform[2][3] != 0.0) { vp.xyz *= 0.999; } else { vp.z *= 0.999; }
    _geometry.position = scn_node.inverseModelViewTransform * vp;
    """
}
