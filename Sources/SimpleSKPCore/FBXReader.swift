import Foundation
import simd
import SimpleSKPFBX

/// Native `.fbx` (Autodesk FBX binary & ASCII) reader powered by `ufbx`, converting meshes, instances,
/// materials, embedded/external textures, display layers, line curves, and cameras into `SKPModel` (metres, Z up).
enum FBXReader {

    static func load(
        _ url: URL,
        fileInfo: SKPFileInfo,
        progress: (@Sendable (SKPReader.Progress) -> Void)? = nil,
        isCancelled: @Sendable () -> Bool = { false }
    ) throws -> SKPModel {
        let start = Date()
        if isCancelled() { throw SKPError.cancelled }

        progress?(SKPReader.Progress(
            phase: L("Lecture du fichier FBX…", "Reading FBX file…"),
            faces: 0,
            fraction: 0.08
        ))

        var opts = ufbx_load_opts()
        opts.target_axes = ufbx_axes_right_handed_z_up
        opts.target_unit_meters = 1.0
        opts.space_conversion = UFBX_SPACE_CONVERSION_MODIFY_GEOMETRY
        opts.geometry_transform_handling = UFBX_GEOMETRY_TRANSFORM_HANDLING_MODIFY_GEOMETRY
        opts.inherit_mode_handling = UFBX_INHERIT_MODE_HANDLING_HELPER_NODES
        opts.generate_missing_normals = true
        opts.normalize_normals = true
        opts.use_blender_pbr_material = true
        opts.ignore_missing_external_files = true
        opts.clean_skin_weights = true

        var error = ufbx_error()
        let scenePtr: UnsafeMutablePointer<ufbx_scene>? = url.withUnsafeFileSystemRepresentation { cPath in
            guard let cPath else { return nil }
            return ufbx_load_file(cPath, &opts, &error)
        }
        guard let scene = scenePtr else {
            throw SKPError.unreadable(url)
        }
        defer { ufbx_free_scene(scene) }

        if isCancelled() { throw SKPError.cancelled }

        return try withoutActuallyEscaping(isCancelled) { escapingIsCancelled in
            let converter = Converter(
                scene: scene,
                sourceURL: url,
                fileInfo: fileInfo,
                start: start,
                progress: progress,
                isCancelled: escapingIsCancelled
            )
            return try converter.buildModel()
        }
    }

    // MARK: - Converter

    private final class Converter {
        let scene: UnsafeMutablePointer<ufbx_scene>
        let sourceURL: URL
        let baseDir: URL
        let fileInfo: SKPFileInfo
        let start: Date
        let progress: (@Sendable (SKPReader.Progress) -> Void)?
        let isCancelled: () -> Bool

        var materials: [SKPModel.Material] = []
        /// Maps `ufbx_material.typed_id` to `SKPModel.materials` index.
        var materialMap: [UInt32: Int] = [:]
        var textureDirectory: URL?
        /// Avoid writing the same embedded texture blob multiple times.
        var writtenTextureBlobs: [UnsafeRawPointer: URL] = [:]

        var layers: [SKPModel.Layer] = [SKPModel.Layer(name: "Layer0", isVisible: true)]
        var layerByName: [String: Int] = ["layer0": 0]
        /// Maps `ufbx_node.typed_id` to `SKPModel.layers` index from `scene.display_layers`.
        var nodeDisplayLayer: [UInt32: Int] = [:]

        var definitions: [SKPModel.Definition] = []
        var stats = SKPModel.Stats()

        struct MeshDefKey: Hashable {
            var meshTypedID: UInt32
            var layer: Int
            var materialIndices: [Int]
        }
        var meshDefCache: [MeshDefKey: (defIndex: Int, box: SKPReader.Box)] = [:]

        init(
            scene: UnsafeMutablePointer<ufbx_scene>,
            sourceURL: URL,
            fileInfo: SKPFileInfo,
            start: Date,
            progress: (@Sendable (SKPReader.Progress) -> Void)?,
            isCancelled: @escaping () -> Bool
        ) {
            self.scene = scene
            self.sourceURL = sourceURL
            self.baseDir = sourceURL.deletingLastPathComponent()
            self.fileInfo = fileInfo
            self.start = start
            self.progress = progress
            self.isCancelled = isCancelled
        }

        func buildModel() throws -> SKPModel {
            do {
                progress?(SKPReader.Progress(
                    phase: L("Lecture des matériaux et calques FBX…", "Reading FBX materials and layers…"),
                    faces: 0,
                    fraction: 0.20
                ))
                readMaterials()
                readDisplayLayers()

                if isCancelled() { throw SKPError.cancelled }

                var rootDef = SKPModel.Definition(name: "")
                var rootBox = SKPReader.Box()

                if let rootNode = scene.pointee.root_node {
                    let children = rootNode.pointee.children
                    // Determine whether to derive layers from top-level nodes when the file has no display layers.
                    let deriveTopLayers = nodeDisplayLayer.isEmpty
                    // If there is a single wrapper root child (e.g. "RootNode" or scene wrapper) with multiple children,
                    // allow deriving layers at depth 1 or 2.
                    let singleWrapperChild = deriveTopLayers && children.count == 1 && (children.data[0]?.pointee.mesh == nil)

                    for i in 0..<children.count {
                        guard let childNode = children.data[i] else { continue }
                        let assignedLayer: Int?
                        if deriveTopLayers && !singleWrapperChild {
                            let rawName = fbxString(childNode.pointee.element.name)
                            assignedLayer = rawName.isEmpty ? nil : ensureLayer(name: rawName, isVisible: childNode.pointee.visible)
                        } else {
                            assignedLayer = nil
                        }
                        if let (inst, instBox) = try convertNode(
                            childNode,
                            inheritedLayer: assignedLayer,
                            deriveLayerForImmediateChildren: singleWrapperChild,
                            depth: 0
                        ) {
                            rootDef.children.append(inst)
                            rootBox.add(instBox, inst.transform)
                            stats.instances += 1
                        }
                    }
                }

                let camerasAndScenes = readCameras(modelBounds: rootBox)
                stats.definitions = definitions.count
                stats.loadSeconds = Date().timeIntervalSince(start)

                var updatedFileInfo = fileInfo
                if scene.pointee.metadata.version > 0 {
                    let v = scene.pointee.metadata.version
                    let major = v / 1000
                    let minor = (v % 1000) / 100
                    let verStr = "FBX \(major).\(minor)"
                    let labelStr = scene.pointee.metadata.ascii ? "Autodesk FBX \(major).\(minor) (ASCII)" : "Autodesk FBX \(major).\(minor)"
                    updatedFileInfo = SKPFileInfo(
                        url: fileInfo.url,
                        fileSize: fileInfo.fileSize,
                        version: verStr,
                        versionLabel: labelStr,
                        thumbnailPNG: fileInfo.thumbnailPNG
                    )
                }

                progress?(SKPReader.Progress(
                    phase: L("Construction de la scène", "Building scene"),
                    faces: stats.faces,
                    fraction: 0.92,
                    edges: stats.edges,
                    blocks: definitions.count,
                    layers: layers.count
                ))

                return SKPModel(
                    root: rootDef,
                    definitions: definitions,
                    materials: materials,
                    layers: layers,
                    scenes: camerasAndScenes.scenes,
                    camera: camerasAndScenes.defaultCamera,
                    boundsMin: rootBox.isEmpty ? .zero : rootBox.min,
                    boundsMax: rootBox.isEmpty ? .zero : rootBox.max,
                    stats: stats,
                    fileInfo: updatedFileInfo,
                    textureDirectory: textureDirectory
                )
            } catch {
                if let dir = textureDirectory {
                    try? FileManager.default.removeItem(at: dir)
                }
                throw error
            }
        }

        // MARK: - Materials & Textures

        private func readMaterials() {
            let matList = scene.pointee.materials
            for i in 0..<matList.count {
                guard let matPtr = matList.data[i] else { continue }
                let mat = matPtr.pointee
                let rawName = fbxString(mat.element.name)
                let matName = rawName.isEmpty ? "Material_\(i)" : rawName

                // Prefer PBR base_color if present, otherwise FBX diffuse_color
                var color = SIMD4<Float>(0.82, 0.82, 0.82, 1.0)
                if mat.pbr.base_color.has_value {
                    let c = mat.pbr.base_color.value_vec4
                    let factor = mat.pbr.base_factor.has_value ? Float(mat.pbr.base_factor.value_real) : 1.0
                    color = SIMD4<Float>(
                        simd_clamp(Float(c.x) * factor, 0, 1),
                        simd_clamp(Float(c.y) * factor, 0, 1),
                        simd_clamp(Float(c.z) * factor, 0, 1),
                        mat.pbr.base_color.value_components >= 4 ? simd_clamp(Float(c.w), 0, 1) : 1.0
                    )
                } else if mat.fbx.diffuse_color.has_value {
                    let c = mat.fbx.diffuse_color.value_vec3
                    let factor = mat.fbx.diffuse_factor.has_value ? Float(mat.fbx.diffuse_factor.value_real) : 1.0
                    color = SIMD4<Float>(
                        simd_clamp(Float(c.x) * factor, 0, 1),
                        simd_clamp(Float(c.y) * factor, 0, 1),
                        simd_clamp(Float(c.z) * factor, 0, 1),
                        1.0
                    )
                }

                // Opacity / transparency
                var opacity: Float = color.w
                if mat.pbr.opacity.has_value {
                    opacity = simd_clamp(Float(mat.pbr.opacity.value_real), 0, 1)
                } else if mat.fbx.transparency_factor.has_value {
                    let tf = Float(mat.fbx.transparency_factor.value_real)
                    if mat.fbx.transparency_color.has_value {
                        let tc = mat.fbx.transparency_color.value_vec3
                        let avgTrans = (Float(tc.x) + Float(tc.y) + Float(tc.z)) / 3.0 * tf
                        if avgTrans > 0.001 && avgTrans < 0.999 {
                            opacity = simd_clamp(1.0 - avgTrans, 0, 1)
                        }
                    } else if tf > 0.001 && tf < 0.999 {
                        opacity = simd_clamp(1.0 - tf, 0, 1)
                    }
                }
                if opacity <= 0.001 { opacity = 1.0 }

                // Resolve primary diffuse/base color texture
                let texPtr = mat.pbr.base_color.texture ?? mat.fbx.diffuse_color.texture
                let texURL = resolveTexture(texPtr, materialIndex: i)
                if texURL != nil && color.x < 0.02 && color.y < 0.02 && color.z < 0.02 {
                    color = SIMD4<Float>(1, 1, 1, 1)
                }

                let isTransparent = opacity < 0.999 || mat.pbr.opacity.texture != nil || mat.fbx.transparency_color.texture != nil
                let skpMat = SKPModel.Material(
                    name: matName,
                    color: color,
                    opacity: opacity,
                    isTransparent: isTransparent,
                    textureURL: texURL
                )
                materialMap[mat.element.typed_id] = materials.count
                materials.append(skpMat)
            }
        }

        private func resolveTexture(_ texPtr: UnsafeMutablePointer<ufbx_texture>?, materialIndex: Int) -> URL? {
            guard let texPtr else { return nil }
            var tex = texPtr.pointee
            // If this is a layered or shader texture, pick its first underlying file texture if available
            if tex.type != UFBX_TEXTURE_FILE && tex.file_textures.count > 0,
               let firstFileTex = tex.file_textures.data[0] {
                tex = firstFileTex.pointee
            }

            // 1. Check embedded texture content (`tex.content`)
            if tex.content.size > 0, let rawData = tex.content.data {
                if let cached = writtenTextureBlobs[rawData] {
                    return cached
                }
                let filenameHint = fbxString(tex.filename)
                let relHint = fbxString(tex.relative_filename)
                var ext = URL(fileURLWithPath: filenameHint.isEmpty ? relHint : filenameHint).pathExtension.lowercased()
                if ext.isEmpty {
                    ext = Self.sniffImageExtension(rawData, size: tex.content.size)
                }
                if textureDirectory == nil {
                    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("SimpleSKP/\(UUID().uuidString)", isDirectory: true)
                    if (try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)) != nil {
                        textureDirectory = dir
                    }
                }
                if let dir = textureDirectory {
                    let fileURL = dir.appendingPathComponent("fbx_tex_\(materialIndex)_\(writtenTextureBlobs.count).\(ext)")
                    let data = Data(bytes: rawData, count: tex.content.size)
                    if (try? data.write(to: fileURL)) != nil {
                        writtenTextureBlobs[rawData] = fileURL
                        return fileURL
                    }
                }
            }

            // 2. Check external texture file paths
            let candidates = [
                fbxString(tex.filename),
                fbxString(tex.relative_filename),
                fbxString(tex.absolute_filename),
            ]
            for raw in candidates where !raw.isEmpty {
                let normalized = raw.replacingOccurrences(of: "\\", with: "/")
                let directURL = URL(fileURLWithPath: normalized, relativeTo: baseDir).standardizedFileURL
                if FileManager.default.fileExists(atPath: directURL.path) {
                    return directURL
                }
                let lastComp = (normalized as NSString).lastPathComponent
                if !lastComp.isEmpty {
                    let sibling = baseDir.appendingPathComponent(lastComp)
                    if FileManager.default.fileExists(atPath: sibling.path) {
                        return sibling
                    }
                    for sub in ["textures", "Textures", "tex", "images", "maps", "\(sourceURL.deletingPathExtension().lastPathComponent).fbm"] {
                        let subCandidate = baseDir.appendingPathComponent(sub).appendingPathComponent(lastComp)
                        if FileManager.default.fileExists(atPath: subCandidate.path) {
                            return subCandidate
                        }
                    }
                }
            }
            return nil
        }

        private static func sniffImageExtension(_ ptr: UnsafeRawPointer, size: Int) -> String {
            guard size >= 4 else { return "png" }
            let bytes = ptr.assumingMemoryBound(to: UInt8.self)
            if bytes[0] == 0x89 && bytes[1] == 0x50 && bytes[2] == 0x4E && bytes[3] == 0x47 { return "png" }
            if bytes[0] == 0xFF && bytes[1] == 0xD8 { return "jpg" }
            if bytes[0] == 0x42 && bytes[1] == 0x4D { return "bmp" }
            if bytes[0] == 0x49 && bytes[1] == 0x49 || bytes[0] == 0x4D && bytes[1] == 0x4D { return "tiff" }
            return "png"
        }

        // MARK: - Display Layers

        private func readDisplayLayers() {
            let dlList = scene.pointee.display_layers
            for i in 0..<dlList.count {
                guard let dlPtr = dlList.data[i] else { continue }
                let dl = dlPtr.pointee
                let rawName = fbxString(dl.element.name)
                let name = rawName.isEmpty ? "Layer_\(i + 1)" : rawName
                let c = dl.ui_color
                let color: SIMD4<Float>? = (c.x > 0 || c.y > 0 || c.z > 0)
                    ? SIMD4<Float>(simd_clamp(Float(c.x), 0, 1), simd_clamp(Float(c.y), 0, 1), simd_clamp(Float(c.z), 0, 1), 1.0)
                    : nil
                let layerIdx = ensureLayer(name: name, isVisible: dl.visible, color: color)
                for nIdx in 0..<dl.nodes.count {
                    if let nPtr = dl.nodes.data[nIdx] {
                        nodeDisplayLayer[nPtr.pointee.element.typed_id] = layerIdx
                    }
                }
            }
        }

        private func ensureLayer(name: String, isVisible: Bool = true, color: SIMD4<Float>? = nil) -> Int {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return 0 }
            let key = trimmed.lowercased()
            if let existing = layerByName[key] {
                if !isVisible { layers[existing].isVisible = false }
                if layers[existing].color == nil, let color { layers[existing].color = color }
                return existing
            }
            let idx = layers.count
            layers.append(SKPModel.Layer(name: trimmed, isVisible: isVisible, color: color))
            layerByName[key] = idx
            return idx
        }

        // MARK: - Nodes & Geometry

        private func convertNode(
            _ nodePtr: UnsafeMutablePointer<ufbx_node>,
            inheritedLayer: Int?,
            deriveLayerForImmediateChildren: Bool,
            depth: Int
        ) throws -> (SKPModel.Instance, SKPReader.Box)? {
            guard depth < 96 else { return nil }
            if isCancelled() { throw SKPError.cancelled }

            let node = nodePtr.pointee
            // Skip hidden nodes unless they belong to a display layer whose visibility is controlled in the sidebar
            let explicitDisplayLayer = nodeDisplayLayer[node.element.typed_id]
            if !node.visible && explicitDisplayLayer == nil {
                return nil
            }

            let nodeName = fbxString(node.element.name)
            let layerIdx = explicitDisplayLayer ?? inheritedLayer ?? 0
            let localMatrix = simdMatrix(node.node_to_parent)

            // Collect children first
            var childInstances: [SKPModel.Instance] = []
            var childrenBox = SKPReader.Box()
            for i in 0..<node.children.count {
                guard let childPtr = node.children.data[i] else { continue }
                let childLayer: Int?
                if deriveLayerForImmediateChildren {
                    let cName = fbxString(childPtr.pointee.element.name)
                    childLayer = cName.isEmpty ? layerIdx : ensureLayer(name: cName, isVisible: childPtr.pointee.visible)
                } else {
                    childLayer = layerIdx
                }
                if let (childInst, childBox) = try convertNode(
                    childPtr,
                    inheritedLayer: childLayer,
                    deriveLayerForImmediateChildren: false,
                    depth: depth + 1
                ) {
                    childInstances.append(childInst)
                    childrenBox.add(childBox, childInst.transform)
                    stats.instances += 1
                }
            }

            // Case 1: Node has a mesh attribute and no child instances -> can share cached mesh definition directly!
            if let meshPtr = node.mesh, childInstances.isEmpty && node.attrib_type == UFBX_ELEMENT_MESH {
                let matIndices = resolveNodeMaterials(node: node, mesh: meshPtr.pointee)
                let key = MeshDefKey(meshTypedID: meshPtr.pointee.element.typed_id, layer: layerIdx, materialIndices: matIndices)
                let cached: (defIndex: Int, box: SKPReader.Box)
                if let hit = meshDefCache[key] {
                    cached = hit
                } else {
                    let (meshDef, meshBox) = try buildMeshDefinition(meshPtr: meshPtr, name: nodeName, layer: layerIdx, materialIndices: matIndices)
                    guard !meshDef.meshes.isEmpty || !meshDef.edges.isEmpty else { return nil }
                    definitions.append(meshDef)
                    cached = (definitions.count - 1, meshBox)
                    meshDefCache[key] = cached
                }
                let inst = SKPModel.Instance(
                    definition: cached.defIndex,
                    transform: localMatrix,
                    layer: layerIdx,
                    isGroup: false,
                    name: nodeName
                )
                return (inst, cached.box)
            }

            // Case 2: Node has a mesh and/or line curve and/or child instances
            var def = SKPModel.Definition(name: nodeName, children: childInstances)
            var box = childrenBox

            if let meshPtr = node.mesh {
                let matIndices = resolveNodeMaterials(node: node, mesh: meshPtr.pointee)
                let (meshDef, meshBox) = try buildMeshDefinition(meshPtr: meshPtr, name: nodeName, layer: layerIdx, materialIndices: matIndices)
                def.meshes.append(contentsOf: meshDef.meshes)
                def.edges.append(contentsOf: meshDef.edges)
                box.add(meshBox, matrix_identity_float4x4)
            }

            if let attrib = node.attrib, let lineCurvePtr = ufbx_as_line_curve(attrib) {
                appendLineCurve(lineCurvePtr, layer: layerIdx, into: &def, box: &box)
            }

            guard !def.meshes.isEmpty || !def.edges.isEmpty || !def.children.isEmpty else {
                return nil
            }

            definitions.append(def)
            let inst = SKPModel.Instance(
                definition: definitions.count - 1,
                transform: localMatrix,
                layer: layerIdx,
                isGroup: true,
                name: nodeName
            )
            return (inst, box)
        }

        private func resolveNodeMaterials(node: ufbx_node, mesh: ufbx_mesh) -> [Int] {
            let sourceList = node.materials.count > 0 ? node.materials : mesh.materials
            var result: [Int] = []
            result.reserveCapacity(sourceList.count)
            for i in 0..<sourceList.count {
                if let mPtr = sourceList.data[i], let idx = materialMap[mPtr.pointee.element.typed_id] {
                    result.append(idx)
                } else {
                    result.append(-1)
                }
            }
            return result
        }

        private func buildMeshDefinition(
            meshPtr: UnsafeMutablePointer<ufbx_mesh>,
            name: String,
            layer: Int,
            materialIndices: [Int]
        ) throws -> (SKPModel.Definition, SKPReader.Box) {
            let mesh = meshPtr.pointee
            var def = SKPModel.Definition(name: name)
            var box = SKPReader.Box()

            guard mesh.num_faces > 0 && mesh.vertex_position.exists else {
                return (def, box)
            }

            let hasNormals = mesh.vertex_normal.exists
            let hasUVs = mesh.vertex_uv.exists
            let hasFaceMat = mesh.face_material.count == mesh.num_faces
            let maxTriIndices = max(3, mesh.max_face_triangles * 3)
            var triScratch = [UInt32](repeating: 0, count: maxTriIndices)

            var batchSlotByMaterial: [Int?: Int] = [:]

            for fIdx in 0..<mesh.num_faces {
                if stats.faces % 4000 == 0 {
                    if isCancelled() { throw SKPError.cancelled }
                    let frac = 0.25 + 0.62 * (1.0 - 1.0 / (1.0 + Double(stats.faces) / 50_000.0))
                    progress?(SKPReader.Progress(
                        phase: L("Conversion des maillages FBX…", "Converting FBX meshes…"),
                        faces: stats.faces,
                        fraction: frac,
                        edges: stats.edges,
                        blocks: definitions.count,
                        layers: layers.count,
                        currentItem: name.isEmpty ? nil : name
                    ))
                }

                if mesh.face_hole.count == mesh.num_faces && mesh.face_hole.data[fIdx] {
                    continue
                }
                let face = mesh.faces.data[fIdx]
                if face.num_indices == 2 {
                    // Two-vertex line face -> add to edges
                    let p0 = readVec3(mesh.vertex_position, index: Int(face.index_begin))
                    let p1 = readVec3(mesh.vertex_position, index: Int(face.index_begin + 1))
                    if def.edges.isEmpty {
                        def.edges.append(SKPModel.EdgeSet(layer: layer, positions: []))
                    }
                    def.edges[0].positions.append(p0)
                    def.edges[0].positions.append(p1)
                    box.add(p0); box.add(p1)
                    stats.edges += 1
                    continue
                }
                guard face.num_indices >= 3 else { continue }

                let matIdx: Int? = {
                    guard hasFaceMat else { return materialIndices.first.flatMap { $0 >= 0 ? $0 : nil } }
                    let slot = Int(mesh.face_material.data[fIdx])
                    guard slot >= 0 && slot < materialIndices.count else { return nil }
                    let resolved = materialIndices[slot]
                    return resolved >= 0 ? resolved : nil
                }()

                let batchSlot: Int
                if let existing = batchSlotByMaterial[matIdx] {
                    batchSlot = existing
                } else {
                    batchSlot = def.meshes.count
                    batchSlotByMaterial[matIdx] = batchSlot
                    def.meshes.append(SKPModel.Mesh(
                        material: matIdx,
                        layer: layer,
                        positions: [],
                        normals: [],
                        uvs: hasUVs ? [] : nil,
                        indices: []
                    ))
                }

                let numTris = triScratch.withUnsafeMutableBufferPointer { buf in
                    Int(ufbx_triangulate_face(buf.baseAddress, buf.count, meshPtr, face))
                }
                guard numTris > 0 else { continue }
                stats.faces += 1
                stats.triangles += numTris

                for t in 0..<numTris {
                    let i0 = Int(triScratch[t * 3])
                    let i1 = Int(triScratch[t * 3 + 1])
                    let i2 = Int(triScratch[t * 3 + 2])

                    let p0 = readVec3(mesh.vertex_position, index: i0)
                    let p1 = readVec3(mesh.vertex_position, index: i1)
                    let p2 = readVec3(mesh.vertex_position, index: i2)

                    let n0: SIMD3<Float>
                    let n1: SIMD3<Float>
                    let n2: SIMD3<Float>
                    if hasNormals {
                        n0 = readVec3(mesh.vertex_normal, index: i0)
                        n1 = readVec3(mesh.vertex_normal, index: i1)
                        n2 = readVec3(mesh.vertex_normal, index: i2)
                    } else {
                        let crossN = simd_cross(p1 - p0, p2 - p0)
                        let len = simd_length(crossN)
                        let fn = len > 1e-7 ? crossN / len : SIMD3<Float>(0, 0, 1)
                        n0 = fn; n1 = fn; n2 = fn
                    }

                    let baseVertex = UInt32(def.meshes[batchSlot].positions.count)
                    def.meshes[batchSlot].positions.append(p0)
                    def.meshes[batchSlot].positions.append(p1)
                    def.meshes[batchSlot].positions.append(p2)
                    def.meshes[batchSlot].normals.append(n0)
                    def.meshes[batchSlot].normals.append(n1)
                    def.meshes[batchSlot].normals.append(n2)
                    if hasUVs {
                        def.meshes[batchSlot].uvs?.append(readVec2(mesh.vertex_uv, index: i0))
                        def.meshes[batchSlot].uvs?.append(readVec2(mesh.vertex_uv, index: i1))
                        def.meshes[batchSlot].uvs?.append(readVec2(mesh.vertex_uv, index: i2))
                    }
                    def.meshes[batchSlot].indices.append(baseVertex)
                    def.meshes[batchSlot].indices.append(baseVertex + 1)
                    def.meshes[batchSlot].indices.append(baseVertex + 2)
                    box.add(p0); box.add(p1); box.add(p2)
                }
            }

            // Extract sharp / boundary edges for clean SketchUp-style wireframe overlay
            let sharpEdges = Mesh3DReader.extractFeatureEdges(from: def.meshes)
            if !sharpEdges.isEmpty {
                if def.edges.isEmpty {
                    def.edges.append(SKPModel.EdgeSet(layer: layer, positions: sharpEdges))
                } else {
                    def.edges[0].positions.append(contentsOf: sharpEdges)
                }
                stats.edges += sharpEdges.count / 2
            }

            return (def, box)
        }

        private func appendLineCurve(
            _ curvePtr: UnsafeMutablePointer<ufbx_line_curve>,
            layer: Int,
            into def: inout SKPModel.Definition,
            box: inout SKPReader.Box
        ) {
            let curve = curvePtr.pointee
            guard curve.control_points.count > 0 && curve.segments.count > 0 else { return }
            var edgePositions: [SIMD3<Float>] = []
            for sIdx in 0..<curve.segments.count {
                let seg = curve.segments.data[sIdx]
                guard seg.num_indices >= 2 else { continue }
                for k in 0..<(Int(seg.num_indices) - 1) {
                    let idxA = Int(curve.point_indices.data[Int(seg.index_begin) + k])
                    let idxB = Int(curve.point_indices.data[Int(seg.index_begin) + k + 1])
                    guard idxA < curve.control_points.count && idxB < curve.control_points.count else { continue }
                    let a = curve.control_points.data[idxA]
                    let b = curve.control_points.data[idxB]
                    let pa = SIMD3<Float>(Float(a.x), Float(a.y), Float(a.z))
                    let pb = SIMD3<Float>(Float(b.x), Float(b.y), Float(b.z))
                    edgePositions.append(pa)
                    edgePositions.append(pb)
                    box.add(pa); box.add(pb)
                    stats.edges += 1
                }
            }
            if !edgePositions.isEmpty {
                def.edges.append(SKPModel.EdgeSet(layer: layer, positions: edgePositions))
            }
        }

        // MARK: - Cameras

        private func readCameras(modelBounds: SKPReader.Box) -> (defaultCamera: SKPModel.Camera?, scenes: [SKPModel.Scene]) {
            let camList = scene.pointee.cameras
            guard camList.count > 0 else { return (nil, []) }

            let modelCenter = modelBounds.isEmpty ? SIMD3<Float>.zero : (modelBounds.min + modelBounds.max) * 0.5
            let modelRadius = modelBounds.isEmpty ? Float(10.0) : max(1.0, simd_length(modelBounds.max - modelBounds.min) * 0.5)
            let defaultCamName = fbxString(scene.pointee.settings.default_camera)

            var scenes: [SKPModel.Scene] = []
            var defaultCamera: SKPModel.Camera? = nil

            for i in 0..<camList.count {
                guard let camPtr = camList.data[i] else { continue }
                let cam = camPtr.pointee
                guard cam.instances.count > 0, let camNodePtr = cam.instances.data[0] else { continue }
                let camNode = camNodePtr.pointee
                let worldMat = simdMatrix(camNode.geometry_to_world)
                let pos = SIMD3<Float>(worldMat.columns.3.x, worldMat.columns.3.y, worldMat.columns.3.z)

                // Determine camera forward and up directions from `cam.projection_axes`
                let forwardLocal = axisVector(cam.projection_axes.front, negate: true)
                let upLocal = axisVector(cam.projection_axes.up, negate: false)
                let forwardWorld = simd_normalize(SIMD3<Float>(
                    worldMat.columns.0.x * forwardLocal.x + worldMat.columns.1.x * forwardLocal.y + worldMat.columns.2.x * forwardLocal.z,
                    worldMat.columns.0.y * forwardLocal.x + worldMat.columns.1.y * forwardLocal.y + worldMat.columns.2.y * forwardLocal.z,
                    worldMat.columns.0.z * forwardLocal.x + worldMat.columns.1.z * forwardLocal.y + worldMat.columns.2.z * forwardLocal.z
                ))
                let upWorld = simd_normalize(SIMD3<Float>(
                    worldMat.columns.0.x * upLocal.x + worldMat.columns.1.x * upLocal.y + worldMat.columns.2.x * upLocal.z,
                    worldMat.columns.0.y * upLocal.x + worldMat.columns.1.y * upLocal.y + worldMat.columns.2.y * upLocal.z,
                    worldMat.columns.0.z * upLocal.x + worldMat.columns.1.z * upLocal.y + worldMat.columns.2.z * upLocal.z
                ))

                guard forwardWorld.x.isFinite && pos.x.isFinite else { continue }
                let distToCenter = simd_distance(pos, modelCenter)
                let lookDist = max(1.0, distToCenter > 0.1 ? distToCenter : modelRadius)
                let target = pos + forwardWorld * lookDist

                let isPersp = cam.projection_mode == UFBX_PROJECTION_MODE_PERSPECTIVE
                let fovY = Float(cam.field_of_view_deg.y)
                let clampedFOV = (fovY.isFinite && fovY >= 5 && fovY <= 150) ? fovY : 35.0
                let orthoH = Float(cam.orthographic_size.y)
                let validOrthoH = (orthoH.isFinite && orthoH > 0.01) ? orthoH : modelRadius * 2.0

                let skpCam = SKPModel.Camera(
                    position: pos,
                    target: target,
                    up: upWorld.x.isFinite ? upWorld : SIMD3<Float>(0, 0, 1),
                    isPerspective: isPersp,
                    fovDegrees: clampedFOV,
                    orthoHeight: validOrthoH
                )
                let rawName = fbxString(camNode.element.name).isEmpty ? fbxString(cam.element.name) : fbxString(camNode.element.name)
                let sceneName = rawName.isEmpty ? "Camera \(i + 1)" : rawName
                scenes.append(SKPModel.Scene(name: sceneName, camera: skpCam, hiddenLayers: nil))
                if defaultCamera == nil || (!defaultCamName.isEmpty && sceneName == defaultCamName) {
                    defaultCamera = skpCam
                }
            }

            return (defaultCamera, scenes)
        }

        // MARK: - Low-Level Value Helpers

        @inline(__always)
        private func fbxString(_ s: ufbx_string) -> String {
            guard s.length > 0, let data = s.data else { return "" }
            return String(decoding: UnsafeBufferPointer(start: UnsafeRawPointer(data).assumingMemoryBound(to: UInt8.self), count: s.length), as: UTF8.self)
        }

        @inline(__always)
        private func simdMatrix(_ m: ufbx_matrix) -> simd_float4x4 {
            simd_float4x4(
                SIMD4<Float>(Float(m.m00), Float(m.m10), Float(m.m20), 0),
                SIMD4<Float>(Float(m.m01), Float(m.m11), Float(m.m21), 0),
                SIMD4<Float>(Float(m.m02), Float(m.m12), Float(m.m22), 0),
                SIMD4<Float>(Float(m.m03), Float(m.m13), Float(m.m23), 1)
            )
        }

        @inline(__always)
        private func readVec3(_ attr: ufbx_vertex_vec3, index: Int) -> SIMD3<Float> {
            guard index < attr.indices.count else { return .zero }
            let valIdx = attr.indices.data[index]
            guard valIdx != UFBX_NO_INDEX && Int(valIdx) < attr.values.count else { return .zero }
            let v = attr.values.data[Int(valIdx)]
            return SIMD3<Float>(Float(v.x), Float(v.y), Float(v.z))
        }

        @inline(__always)
        private func readVec2(_ attr: ufbx_vertex_vec2, index: Int) -> SIMD2<Float> {
            guard index < attr.indices.count else { return .zero }
            let valIdx = attr.indices.data[index]
            guard valIdx != UFBX_NO_INDEX && Int(valIdx) < attr.values.count else { return .zero }
            let v = attr.values.data[Int(valIdx)]
            return SIMD2<Float>(Float(v.x), Float(v.y))
        }

        private func axisVector(_ axis: ufbx_coordinate_axis, negate: Bool) -> SIMD3<Float> {
            let s: Float = negate ? -1.0 : 1.0
            switch axis {
            case UFBX_COORDINATE_AXIS_POSITIVE_X: return SIMD3<Float>(s, 0, 0)
            case UFBX_COORDINATE_AXIS_NEGATIVE_X: return SIMD3<Float>(-s, 0, 0)
            case UFBX_COORDINATE_AXIS_POSITIVE_Y: return SIMD3<Float>(0, s, 0)
            case UFBX_COORDINATE_AXIS_NEGATIVE_Y: return SIMD3<Float>(0, -s, 0)
            case UFBX_COORDINATE_AXIS_POSITIVE_Z: return SIMD3<Float>(0, 0, s)
            case UFBX_COORDINATE_AXIS_NEGATIVE_Z: return SIMD3<Float>(0, 0, -s)
            default: return SIMD3<Float>(s, 0, 0)
            }
        }
    }
}
