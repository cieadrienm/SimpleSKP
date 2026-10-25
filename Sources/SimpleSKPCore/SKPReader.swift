import Foundation
import simd

/// Reads a `.skp` through SketchUp's C API into an `SKPModel`. Synchronous and blocking: call it off the main
/// thread. One model is read at a time (the API is not thread-safe); `SUInitialize` runs once per process.
public enum SKPReader {
    public struct Progress: Sendable {
        /// Short French/English phase label for the status bar, via `L(...)`.
        public var phase: String
        /// Faces converted so far.
        public var faces: Int
        public init(phase: String, faces: Int) { self.phase = phase; self.faces = faces }
    }

    public static func load(
        _ url: URL,
        progress: (@Sendable (Progress) -> Void)? = nil,
        isCancelled: @Sendable () -> Bool = { false }
    ) throws -> SKPModel {
        let fileInfo = try SKPFileInfo.read(url)
        let f = try SketchUpAPI.functions()
        lock.lock()
        defer { lock.unlock() }

        progress?(Progress(phase: L("Lecture du fichier", "Reading file"), faces: 0))
        let start = Date()
        var model: Ref = nil
        var status: Int32 = 0
        let result = url.withUnsafeFileSystemRepresentation { f.SUModelCreateFromFileWithStatus(&model, $0!, &status) }
        guard result == 0 else {
            // SU_ERROR_SERIALIZATION, SU_ERROR_MODEL_INVALID, SU_ERROR_MODEL_VERSION (common.h order)
            if [7, 12, 13].contains(result) { throw SKPError.unreadable(url) }
            throw SKPError.api(function: "SUModelCreateFromFileWithStatus", code: result)
        }
        defer { _ = f.SUModelRelease(&model) }
        if isCancelled() { throw SKPError.cancelled }

        return try withoutActuallyEscaping(isCancelled) { isCancelled in
            let c = Converter(f: f, progress: progress, isCancelled: isCancelled)
            c.readMaterials(model)
            c.readLayers(model)
            let root: SKPModel.Definition, box: Box
            do {
                var rootEntities: Ref = nil
                let r = f.SUModelGetEntities(model, &rootEntities)
                guard r == 0 else { throw SKPError.api(function: "SUModelGetEntities", code: r) }
                (root, box) = try c.convert(rootEntities, name: "", depth: 0)
            } catch {
                // No model will own the written textures: delete them now.
                if let dir = c.textureDirectory { try? FileManager.default.removeItem(at: dir) }
                throw error
            }

            let scenes = c.refs(f.SUModelGetNumScenes, f.SUModelGetScenes, model).map { scene in
                SKPModel.Scene(
                    name: c.string(f.SUSceneGetName, scene),
                    camera: c.bool(f.SUSceneGetUseCamera, scene) ? c.ref(f.SUSceneGetCamera, scene).flatMap(c.camera) : nil,
                    hiddenLayers: Self.hiddenLayers(saved: c.bool(f.SUSceneGetUseHiddenLayers, scene)) {
                        c.refs(f.SUSceneGetNumLayers, f.SUSceneGetLayers, scene).compactMap { $0.flatMap { c.layerIndex[$0] } }
                    })
            }
            c.stats.definitions = c.definitions.count
            c.stats.loadSeconds = Date().timeIntervalSince(start)
            return SKPModel(
                root: root, definitions: c.definitions, materials: c.materials, layers: c.layers, scenes: scenes,
                camera: c.ref(f.SUModelGetCamera, model).flatMap(c.camera),
                boundsMin: box.isEmpty ? .zero : box.min, boundsMax: box.isEmpty ? .zero : box.max,
                stats: c.stats, fileInfo: fileInfo,
                loadWarning: status == 1 ? L("Fichier enregistré par un SketchUp plus récent ; chargé quand même.", "File saved by a newer SketchUp; loaded anyway.") : nil,
                textureDirectory: c.textureDirectory)
        }
    }

    static let lock = NSLock()

    /// A scene that does not save layer visibility has nil hidden layers: selecting it leaves the layers as they are.
    static func hiddenLayers(saved: Bool, _ indices: () -> [Int]) -> [Int]? { saved ? indices() : nil }
    static let inch = 0.0254

    /// SketchUp transform (column-major `double[16]`, inches) → metres. A uniform scale is stored as 1/scale in
    /// `values[15]`: normalise the homogeneous matrix first.
    static func transform(_ values: [Double]) -> simd_float4x4 {
        var v = values
        if v[15] != 1 && v[15] != 0 { let w = v[15]; v = v.map { $0 / w } }
        func column(_ i: Int) -> SIMD4<Float> { SIMD4(Float(v[i]), Float(v[i + 1]), Float(v[i + 2]), Float(v[i + 3])) }
        return simd_float4x4(column(0), column(4), column(8), SIMD4(Float(v[12] * inch), Float(v[13] * inch), Float(v[14] * inch), 1))
    }

    /// SketchUp may store the horizontal FOV; the contract wants the vertical one.
    static func verticalFOV(fov: Double, isHeight: Bool, aspect: Double) -> Float {
        if isHeight { return Float(fov) }
        let aspect = aspect > 0 ? aspect : 16.0 / 9.0
        return Float(2 * atan(tan(fov * .pi / 360) / aspect) * 180 / .pi)
    }

    struct Box {
        var min = SIMD3<Float>(repeating: .infinity)
        var max = SIMD3<Float>(repeating: -.infinity)
        var isEmpty: Bool { min.x > max.x }
        mutating func add(_ p: SIMD3<Float>) { min = simd_min(min, p); max = simd_max(max, p) }
        mutating func add(_ box: Box, _ m: simd_float4x4) {
            guard !box.isEmpty else { return }
            for i in 0..<8 {
                let corner = SIMD3(i & 1 == 0 ? box.min.x : box.max.x, i & 2 == 0 ? box.min.y : box.max.y, i & 4 == 0 ? box.min.z : box.max.z)
                let p = m * SIMD4(corner, 1)
                add(SIMD3(p.x, p.y, p.z))
            }
        }
    }

    struct BatchKey: Hashable { var material: Int?; var layer: Int }

    final class Converter {
        let f: SketchUpAPI.Functions
        let progress: (@Sendable (Progress) -> Void)?
        let isCancelled: () -> Bool
        var materials: [SKPModel.Material] = []
        var materialIndex: [UnsafeMutableRawPointer: Int] = [:]
        var textured: [Bool] = []
        var textureDirectory: URL?
        var layers: [SKPModel.Layer] = []
        var layerIndex: [UnsafeMutableRawPointer: Int] = [:]
        var definitions: [SKPModel.Definition] = []
        var definitionCache: [UnsafeMutableRawPointer: (index: Int, box: Box)] = [:]
        var stats = SKPModel.Stats()
        // Scratch buffers reused across faces.
        var points: [SUPoint3D] = []
        var normals: [SUPoint3D] = []
        var stq: [SUPoint3D] = []
        var indices: [Int] = []

        init(f: SketchUpAPI.Functions, progress: (@Sendable (Progress) -> Void)?, isCancelled: @escaping () -> Bool) {
            self.f = f; self.progress = progress; self.isCancelled = isCancelled
        }

        // MARK: C helpers

        func string(_ getter: SketchUpAPI.GetRef, _ owner: Ref) -> String {
            var s: Ref = nil
            guard f.SUStringCreate(&s) == 0 else { return "" }
            defer { _ = f.SUStringRelease(&s) }
            var length = 0
            guard getter(owner, &s) == 0, f.SUStringGetUTF8Length(s, &length) == 0 else { return "" }
            var buffer = [CChar](repeating: 0, count: length + 1)
            var copied = 0
            _ = f.SUStringGetUTF8(s, length + 1, &buffer, &copied)
            return String(cString: buffer)
        }

        func refs(_ count: (Ref, UnsafeMutablePointer<Int>) -> Int32, _ list: (Ref, Int, OutRef, UnsafeMutablePointer<Int>) -> Int32, _ owner: Ref) -> [Ref] {
            var n = 0
            guard count(owner, &n) == 0, n > 0 else { return [] }
            var out = [Ref](repeating: nil, count: n)
            var got = 0
            guard list(owner, n, &out, &got) == 0 else { return [] }
            return Array(out.prefix(got))
        }

        /// nil on SU_ERROR_NO_DATA (no material, no layer, no texture) or any other failure.
        func ref(_ getter: SketchUpAPI.GetRef, _ owner: Ref) -> UnsafeMutableRawPointer? {
            var out: Ref = nil
            return getter(owner, &out) == 0 ? out : nil
        }

        func bool(_ getter: SketchUpAPI.GetBool, _ owner: Ref, default value: Bool = false) -> Bool {
            var out = value
            return getter(owner, &out) == 0 ? out : value
        }

        func layer(_ element: Ref) -> Int { ref(f.SUDrawingElementGetLayer, element).flatMap { layerIndex[$0] } ?? 0 }
        func material(_ element: Ref) -> Int? { ref(f.SUDrawingElementGetMaterial, element).flatMap { materialIndex[$0] } }
        func metres(_ p: SUPoint3D) -> SIMD3<Float> { SIMD3(Float(p.x * inch), Float(p.y * inch), Float(p.z * inch)) }

        // MARK: Model tables

        func readMaterials(_ model: Ref) {
            for (i, m) in refs(f.SUModelGetNumMaterials, f.SUModelGetMaterials, model).enumerated() {
                if let m { materialIndex[m] = i }
                var c = SUColor()
                _ = f.SUMaterialGetColor(m, &c)
                var opacity = 1.0
                if bool(f.SUMaterialGetUseOpacity, m) { _ = f.SUMaterialGetOpacity(m, &opacity) }
                var type: Int32 = 0
                _ = f.SUMaterialGetType(m, &type)
                var material = SKPModel.Material(name: string(f.SUMaterialGetName, m),
                                                 color: SIMD4(Float(c.r), Float(c.g), Float(c.b), Float(c.a)) / 255,
                                                 opacity: Float(opacity))
                // SUMaterialType_Textured = 1, SUMaterialType_ColorizedTexture = 2
                let texture = type == 1 || type == 2 ? ref(f.SUMaterialGetTexture, m) : nil
                if let texture {
                    var ext = URL(fileURLWithPath: string(f.SUTextureGetFileName, texture)).pathExtension.lowercased()
                    if ext.isEmpty { ext = "png" }
                    if textureDirectory == nil {
                        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("SimpleSKP/\(UUID().uuidString)", isDirectory: true)
                        if (try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)) != nil { textureDirectory = dir }
                    }
                    if let file = textureDirectory?.appendingPathComponent("\(i).\(ext)"), f.SUTextureWriteToFile(texture, file.path) == 0 {
                        material.textureURL = file
                    }
                    // s_scale/t_scale map texture coordinates to inches: one repeat = 1/scale inches.
                    var w = 0, h = 0, s = 0.0, t = 0.0
                    if f.SUTextureGetDimensions(texture, &w, &h, &s, &t) == 0, s > 0, t > 0 {
                        material.textureScale = SIMD2(Float(inch / s), Float(inch / t))
                    }
                }
                textured.append(texture != nil)
                materials.append(material)
            }
        }

        func readLayers(_ model: Ref) {
            for (i, l) in refs(f.SUModelGetNumLayers, f.SUModelGetLayers, model).enumerated() {
                if let l { layerIndex[l] = i }
                layers.append(SKPModel.Layer(name: string(f.SULayerGetName, l), isVisible: bool(f.SULayerGetVisibility, l, default: true)))
            }
            // Unknown layers map to index 0, so it must exist.
            if layers.isEmpty { layers.append(SKPModel.Layer(name: "Layer0", isVisible: true)) }
        }

        func camera(_ cam: UnsafeMutableRawPointer) -> SKPModel.Camera? {
            var p = SUPoint3D(), t = SUPoint3D(), u = SUPoint3D()
            guard f.SUCameraGetOrientation(cam, &p, &t, &u) == 0 else { return nil }
            var fov = 35.0, aspect = 0.0, height = 0.0
            _ = f.SUCameraGetPerspectiveFrustumFOV(cam, &fov)
            if f.SUCameraGetAspectRatio(cam, &aspect) != 0 { aspect = 0 }
            if f.SUCameraGetOrthographicFrustumHeight(cam, &height) != 0 || height <= 0 { height = 10 / inch }
            return SKPModel.Camera(position: metres(p), target: metres(t), up: SIMD3(Float(u.x), Float(u.y), Float(u.z)),
                                   isPerspective: bool(f.SUCameraGetPerspective, cam, default: true),
                                   fovDegrees: verticalFOV(fov: fov, isHeight: bool(f.SUCameraGetFOVIsHeight, cam, default: true), aspect: aspect),
                                   orthoHeight: Float(height * inch))
        }

        // MARK: Geometry

        /// Converts one entities collection; returns the definition and its local bounds (children included).
        func convert(_ entities: Ref, name: String, depth: Int) throws -> (SKPModel.Definition, Box) {
            var def = SKPModel.Definition(name: name)
            var box = Box()
            guard depth < 64 else { return (def, box) }

            var batches: [BatchKey: Int] = [:]
            for face in refs(f.SUEntitiesGetNumFaces, f.SUEntitiesGetFaces, entities) where !bool(f.SUDrawingElementGetHidden, face) {
                if stats.faces % 2000 == 0 {
                    if isCancelled() { throw SKPError.cancelled }
                    progress?(Progress(phase: L("Conversion des faces", "Converting faces"), faces: stats.faces))
                }
                stats.faces += 1
                var helper: Ref = nil
                guard f.SUMeshHelperCreate(&helper, face) == 0 else { continue }
                defer { _ = f.SUMeshHelperRelease(&helper) }
                var triangles = 0, vertices = 0, got = 0
                _ = f.SUMeshHelperGetNumTriangles(helper, &triangles)
                _ = f.SUMeshHelperGetNumVertices(helper, &vertices)
                guard triangles > 0, vertices > 0 else { continue }
                if points.count < vertices {
                    points = Array(repeating: SUPoint3D(), count: vertices); normals = points; stq = points
                }
                if indices.count < triangles * 3 { indices = Array(repeating: 0, count: triangles * 3) }
                guard f.SUMeshHelperGetVertices(helper, vertices, &points, &got) == 0, got == vertices,
                      f.SUMeshHelperGetNormals(helper, vertices, &normals, &got) == 0, got == vertices,
                      f.SUMeshHelperGetVertexIndices(helper, triangles * 3, &indices, &got) == 0, got == triangles * 3
                else { continue }

                let material = ref(f.SUFaceGetFrontMaterial, face).flatMap { materialIndex[$0] }
                // Own texture → STQ in repeats; no own material → STQ in inches (for an inherited texture), stored in metres.
                let uvScale: Double? = material.map { textured[$0] ? 1 : nil } ?? inch
                let hasUVs = uvScale != nil
                if hasUVs {
                    guard f.SUMeshHelperGetFrontSTQCoords(helper, vertices, &stq, &got) == 0, got == vertices else { continue }
                }
                let key = BatchKey(material: material, layer: layer(face))
                let slot: Int
                if let existing = batches[key] { slot = existing } else {
                    slot = def.meshes.count
                    batches[key] = slot
                    def.meshes.append(SKPModel.Mesh(material: material, layer: key.layer, positions: [], normals: [], uvs: hasUVs ? [] : nil, indices: []))
                }
                append(into: &def.meshes[slot], vertices: vertices, triangles: triangles, uvScale: uvScale, box: &box)
                stats.triangles += triangles
            }

            var edgeSlots: [Int: Int] = [:]
            var a = SUPoint3D(), b = SUPoint3D()
            for edge in refs({ f.SUEntitiesGetNumEdges($0, false, $1) }, { f.SUEntitiesGetEdges($0, false, $1, $2, $3) }, entities)
            where !bool(f.SUDrawingElementGetHidden, edge) && !bool(f.SUEdgeGetSoft, edge) {
                guard let start = ref(f.SUEdgeGetStartVertex, edge), let end = ref(f.SUEdgeGetEndVertex, edge),
                      f.SUVertexGetPosition(start, &a) == 0, f.SUVertexGetPosition(end, &b) == 0 else { continue }
                let layer = layer(edge)
                let slot: Int
                if let existing = edgeSlots[layer] { slot = existing } else {
                    slot = def.edges.count
                    edgeSlots[layer] = slot
                    def.edges.append(SKPModel.EdgeSet(layer: layer, positions: []))
                }
                let pa = metres(a), pb = metres(b)
                def.edges[slot].positions.append(pa)
                def.edges[slot].positions.append(pb)
                box.add(pa); box.add(pb)
                stats.edges += 1
            }

            var matrix = [Double](repeating: 0, count: 16)
            for group in refs(f.SUEntitiesGetNumGroups, f.SUEntitiesGetGroups, entities) where !bool(f.SUDrawingElementGetHidden, group) {
                guard let groupEntities = ref(f.SUGroupGetEntities, group), f.SUGroupGetTransform(group, &matrix) == 0 else { continue }
                let t = transform(matrix)
                let name = string(f.SUGroupGetName, group)
                let (child, childBox) = try convert(groupEntities, name: name, depth: depth + 1)
                definitions.append(child)
                def.children.append(SKPModel.Instance(definition: definitions.count - 1, transform: t, layer: layer(group), isGroup: true,
                                                      material: material(group), name: name))
                box.add(childBox, t)
                stats.instances += 1
            }

            for instance in refs(f.SUEntitiesGetNumInstances, f.SUEntitiesGetInstances, entities) where !bool(f.SUDrawingElementGetHidden, instance) {
                guard let component = ref(f.SUComponentInstanceGetDefinition, instance),
                      f.SUComponentInstanceGetTransform(instance, &matrix) == 0 else { continue }
                let t = transform(matrix)
                let cached: (index: Int, box: Box)
                if let hit = definitionCache[component] { cached = hit } else {
                    guard let componentEntities = ref(f.SUComponentDefinitionGetEntities, component) else { continue }
                    let (child, childBox) = try convert(componentEntities, name: string(f.SUComponentDefinitionGetName, component), depth: depth + 1)
                    definitions.append(child)
                    cached = (definitions.count - 1, childBox)
                    definitionCache[component] = cached
                }
                def.children.append(SKPModel.Instance(definition: cached.index, transform: t, layer: layer(instance), isGroup: false,
                                                      material: material(instance), name: string(f.SUComponentInstanceGetName, instance)))
                box.add(cached.box, t)
                stats.instances += 1
            }
            return (def, box)
        }

        /// Appends the current scratch buffers (one face) to a batch, rebasing indices.
        func append(into mesh: inout SKPModel.Mesh, vertices: Int, triangles: Int, uvScale: Double?, box: inout Box) {
            let base = UInt32(mesh.positions.count)
            for i in 0..<vertices {
                let p = metres(points[i])
                mesh.positions.append(p)
                box.add(p)
                let n = normals[i]
                mesh.normals.append(SIMD3(Float(n.x), Float(n.y), Float(n.z)))
                if let k = uvScale {
                    let s = stq[i]
                    let q = s.z != 0 ? s.z : 1
                    mesh.uvs?.append(SIMD2(Float(s.x / q * k), Float(s.y / q * k)))
                }
            }
            for i in 0..<triangles * 3 { mesh.indices.append(base + UInt32(indices[i])) }
        }
    }
}
