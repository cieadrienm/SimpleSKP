import AppKit
import Foundation
import ImageIO
import simd

/// Native, zero-dependency reader for Khronos **glTF 2.0** (`.gltf` JSON + `.bin` / data URIs) and **Binary glTF** (`.glb`) 3D models.
/// Converts glTF's right-handed Y-up coordinate space (`+X` right, `+Y` up, `+Z` forward, 1 unit = 1 metre)
/// into SimpleSKP's right-handed Z-up model space (`+X` right, `+Y` depth, `+Z` up, 1 unit = 1 metre) via `(x, y, z) -> (x, -z, y)`.
public enum GLTFReader {

    // MARK: - glTF 2.0 JSON Schema

    private struct GLTFDocument: Decodable {
        var asset: Asset?
        var scene: Int?
        var scenes: [SceneDef]?
        var nodes: [NodeDef]?
        var meshes: [MeshDef]?
        var accessors: [AccessorDef]?
        var bufferViews: [BufferViewDef]?
        var buffers: [BufferDef]?
        var materials: [MaterialDef]?
        var textures: [TextureDef]?
        var images: [ImageDef]?
        var cameras: [CameraDef]?

        struct Asset: Decodable {
            var version: String?
            var minVersion: String?
            var generator: String?
        }

        struct SceneDef: Decodable {
            var name: String?
            var nodes: [Int]?
        }

        struct NodeDef: Decodable {
            var name: String?
            var children: [Int]?
            var mesh: Int?
            var camera: Int?
            var matrix: [Float]?
            var translation: [Float]?
            var rotation: [Float]?
            var scale: [Float]?
        }

        struct MeshDef: Decodable {
            var name: String?
            var primitives: [PrimitiveDef]?
        }

        struct PrimitiveDef: Decodable {
            var attributes: [String: Int]
            var indices: Int?
            var material: Int?
            var mode: Int? // default 4 = TRIANGLES
        }

        struct AccessorDef: Decodable {
            var bufferView: Int?
            var byteOffset: Int?
            var componentType: Int // 5120 BYTE, 5121 UBYTE, 5122 SHORT, 5123 USHORT, 5125 UINT, 5126 FLOAT
            var normalized: Bool?
            var count: Int
            var type: String // "SCALAR", "VEC2", "VEC3", "VEC4", "MAT4"
            var sparse: SparseDef?

            struct SparseDef: Decodable {
                var count: Int
                var indices: SparseIndices
                var values: SparseValues
            }
            struct SparseIndices: Decodable {
                var bufferView: Int
                var byteOffset: Int?
                var componentType: Int
            }
            struct SparseValues: Decodable {
                var bufferView: Int
                var byteOffset: Int?
            }
        }

        struct BufferViewDef: Decodable {
            var buffer: Int
            var byteOffset: Int?
            var byteLength: Int
            var byteStride: Int?
        }

        struct BufferDef: Decodable {
            var uri: String?
            var byteLength: Int
        }

        struct MaterialDef: Decodable {
            var name: String?
            var pbrMetallicRoughness: PBRMetallicRoughness?
            var emissiveTexture: TextureInfo?
            var emissiveFactor: [Float]?
            var alphaMode: String? // "OPAQUE", "MASK", "BLEND"
            var alphaCutoff: Float?
            var doubleSided: Bool?
        }

        struct PBRMetallicRoughness: Decodable {
            var baseColorFactor: [Float]?
            var baseColorTexture: TextureInfo?
            var metallicFactor: Float?
            var roughnessFactor: Float?
        }

        struct TextureInfo: Decodable {
            var index: Int
            var texCoord: Int?
            var extensions: TextureInfoExtensions?
        }

        struct TextureInfoExtensions: Decodable {
            var KHR_texture_transform: KHRTextureTransform?
        }

        struct KHRTextureTransform: Decodable {
            var offset: [Float]?
            var rotation: Float?
            var scale: [Float]?
            var texCoord: Int?
        }

        struct TextureDef: Decodable {
            var name: String?
            var source: Int?
            var extensions: TextureExtensions?
        }

        struct TextureExtensions: Decodable {
            var KHR_texture_basisu: TextureSourceExt?
            var EXT_texture_webp: TextureSourceExt?
        }

        struct TextureSourceExt: Decodable {
            var source: Int?
        }

        struct ImageDef: Decodable {
            var name: String?
            var uri: String?
            var mimeType: String?
            var bufferView: Int?
        }

        struct CameraDef: Decodable {
            var name: String?
            var type: String // "perspective" or "orthographic"
            var perspective: PerspectiveCamera?
            var orthographic: OrthographicCamera?

            struct PerspectiveCamera: Decodable {
                var yfov: Float
                var znear: Float?
                var zfar: Float?
                var aspectRatio: Float?
            }
            struct OrthographicCamera: Decodable {
                var xmag: Float
                var ymag: Float
                var znear: Float?
                var zfar: Float?
            }
        }
    }

    // MARK: - Entry Point

    public static func load(
        _ url: URL,
        fileInfo: SKPFileInfo,
        progress: (@Sendable (SKPReader.Progress) -> Void)? = nil,
        isCancelled: @Sendable () -> Bool = { false }
    ) throws -> SKPModel {
        let startTime = Date()
        if isCancelled() { throw SKPError.cancelled }

        progress?(SKPReader.Progress(
            phase: L("Lecture du fichier glTF/GLB…", "Reading glTF/GLB file…"),
            faces: 0,
            fraction: 0.06,
            currentItem: url.lastPathComponent
        ))

        let fileData: Data
        do {
            fileData = try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            throw SKPError.unreadable(url)
        }
        if isCancelled() { throw SKPError.cancelled }

        let baseDir = url.deletingLastPathComponent()
        let (jsonData, glbBinChunk) = try extractJSONAndBinaryChunk(from: fileData, url: url)

        let doc: GLTFDocument
        do {
            doc = try JSONDecoder().decode(GLTFDocument.self, from: jsonData)
        } catch {
            throw SKPError.unreadable(url)
        }
        if isCancelled() { throw SKPError.cancelled }

        let buffers = try resolveBuffers(doc: doc, glbBinChunk: glbBinChunk, baseDir: baseDir, url: url)
        if isCancelled() { throw SKPError.cancelled }

        // Prepare materials and extract embedded/external textures
        var textureDirectory: URL? = nil
        func ensureTextureDirectory() -> URL? {
            if let existing = textureDirectory { return existing }
            let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("SimpleSKP", isDirectory: true)
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            textureDirectory = dir
            return dir
        }

        let accessors = doc.accessors ?? []
        let bufferViews = doc.bufferViews ?? []
        let images = doc.images ?? []
        let textures = doc.textures ?? []
        let rawMaterials = doc.materials ?? []

        // Cache extracted image URLs by glTF image index
        var resolvedImageURLs: [Int: URL] = [:]
        func resolveImageURL(_ imageIndex: Int) -> URL? {
            if let cached = resolvedImageURLs[imageIndex] { return cached }
            guard images.indices.contains(imageIndex) else { return nil }
            let imgDef = images[imageIndex]

            if let bvIndex = imgDef.bufferView,
               let slice = sliceForBufferView(bvIndex, bufferViews: bufferViews, buffers: buffers),
               !slice.isEmpty,
               let dir = ensureTextureDirectory() {
                let ext = Self.fileExtension(forMimeType: imgDef.mimeType, data: slice)
                let safeName = Self.sanitizedFilename(imgDef.name ?? "tex_\(imageIndex)")
                let dest = dir.appendingPathComponent("\(safeName)_\(imageIndex).\(ext)")
                if (try? Data(slice).write(to: dest, options: .atomic)) != nil {
                    resolvedImageURLs[imageIndex] = dest
                    return dest
                }
            }

            if let uri = imgDef.uri, !uri.isEmpty {
                if uri.hasPrefix("data:"),
                   let decoded = Self.decodeDataURI(uri),
                   !decoded.isEmpty,
                   let dir = ensureTextureDirectory() {
                    let ext = Self.fileExtension(forMimeType: imgDef.mimeType, data: decoded[...])
                    let safeName = Self.sanitizedFilename(imgDef.name ?? "tex_\(imageIndex)")
                    let dest = dir.appendingPathComponent("\(safeName)_\(imageIndex).\(ext)")
                    if (try? decoded.write(to: dest, options: .atomic)) != nil {
                        resolvedImageURLs[imageIndex] = dest
                        return dest
                    }
                } else {
                    let decodedPath = uri.removingPercentEncoding ?? uri
                    let candidate = baseDir.appendingPathComponent(decodedPath)
                    if FileManager.default.fileExists(atPath: candidate.path) {
                        resolvedImageURLs[imageIndex] = candidate
                        return candidate
                    }
                }
            }
            return nil
        }

        struct MaterialUVTransform {
            var texCoordIndex: Int = 0
            var offset: SIMD2<Float> = .zero
            var scale: SIMD2<Float> = SIMD2<Float>(1, 1)
            var rotation: Float = 0
            var hasTransform: Bool = false
        }

        var skpMaterials: [SKPModel.Material] = []
        var materialUVTransforms: [MaterialUVTransform] = []
        skpMaterials.reserveCapacity(rawMaterials.count)
        materialUVTransforms.reserveCapacity(rawMaterials.count)

        for (matIdx, matDef) in rawMaterials.enumerated() {
            let pbr = matDef.pbrMetallicRoughness
            let baseFactor = pbr?.baseColorFactor ?? [1, 1, 1, 1]
            let r = baseFactor.count > 0 ? simd_clamp(baseFactor[0], 0, 1) : 1.0
            let g = baseFactor.count > 1 ? simd_clamp(baseFactor[1], 0, 1) : 1.0
            let b = baseFactor.count > 2 ? simd_clamp(baseFactor[2], 0, 1) : 1.0
            let a = baseFactor.count > 3 ? simd_clamp(baseFactor[3], 0, 1) : 1.0

            let alphaMode = (matDef.alphaMode ?? "OPAQUE").uppercased()
            let opacity: Float = (alphaMode == "BLEND") ? a : 1.0
            let isTransparent = (alphaMode == "BLEND" && a < 0.999)

            var texURL: URL? = nil
            var uvTrans = MaterialUVTransform()

            let texInfo = pbr?.baseColorTexture ?? matDef.emissiveTexture
            if let texInfo, textures.indices.contains(texInfo.index) {
                let texDef = textures[texInfo.index]
                let imgIndex = texDef.source
                    ?? texDef.extensions?.EXT_texture_webp?.source
                    ?? texDef.extensions?.KHR_texture_basisu?.source
                if let imgIndex {
                    texURL = resolveImageURL(imgIndex)
                }
                uvTrans.texCoordIndex = texInfo.texCoord ?? 0
                if let khr = texInfo.extensions?.KHR_texture_transform {
                    if let tc = khr.texCoord { uvTrans.texCoordIndex = tc }
                    if let off = khr.offset, off.count >= 2 {
                        uvTrans.offset = SIMD2<Float>(off[0], off[1])
                        uvTrans.hasTransform = true
                    }
                    if let sc = khr.scale, sc.count >= 2 {
                        uvTrans.scale = SIMD2<Float>(sc[0], sc[1])
                        uvTrans.hasTransform = true
                    }
                    if let rot = khr.rotation, abs(rot) > 1e-6 {
                        uvTrans.rotation = rot
                        uvTrans.hasTransform = true
                    }
                }
            }

            let matName = (matDef.name?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
                ?? "Material_\(matIdx + 1)"

            skpMaterials.append(SKPModel.Material(
                name: matName,
                color: SIMD4<Float>(r, g, b, a),
                opacity: opacity,
                isTransparent: isTransparent,
                textureURL: texURL,
                textureScale: SIMD2<Float>(1, 1)
            ))
            materialUVTransforms.append(uvTrans)
        }

        // Coordinate conversion matrix from glTF Y-up `(x, y, z)` to SimpleSKP Z-up `(x, -z, y)`:
        // Column 0 (X_gltf) -> (1,  0, 0)
        // Column 1 (Y_gltf) -> (0,  0, 1)
        // Column 2 (Z_gltf) -> (0, -1, 0)
        // Determinant = +1 (right-handed rotation of +90° around X).
        let yUpToZUp = simd_float4x4(
            SIMD4<Float>(1,  0, 0, 0),
            SIMD4<Float>(0,  0, 1, 0),
            SIMD4<Float>(0, -1, 0, 0),
            SIMD4<Float>(0,  0, 0, 1)
        )

        // Decode each glTF Mesh into local-space primitives
        struct DecodedPrimitive {
            var material: Int?
            var positions: [SIMD3<Float>]
            var normals: [SIMD3<Float>]
            var uvs: [SIMD2<Float>]?
            var indices: [UInt32]
            var lineSegments: [SIMD3<Float>]
            var featureEdges: [SIMD3<Float>]
        }

        let meshDefs = doc.meshes ?? []
        var decodedMeshes: [[DecodedPrimitive]] = Array(repeating: [], count: meshDefs.count)

        // Map unique untextured (materialIndex, quantizedVertexColor) to a synthesized SKPModel.Material
        var vertexColorMaterials: [UInt64: Int] = [:]
        func materialWithVertexColor(baseMaterial: Int?, color: SIMD4<Float>) -> Int {
            let r8 = UInt64(simd_clamp(color.x * 255.0, 0, 255).rounded())
            let g8 = UInt64(simd_clamp(color.y * 255.0, 0, 255).rounded())
            let b8 = UInt64(simd_clamp(color.z * 255.0, 0, 255).rounded())
            let a8 = UInt64(simd_clamp(color.w * 255.0, 0, 255).rounded())
            let baseKey = UInt64(baseMaterial.map { $0 + 1 } ?? 0)
            let key = (baseKey << 32) | (r8 << 24) | (g8 << 16) | (b8 << 8) | a8
            if let existing = vertexColorMaterials[key] { return existing }

            let baseColor: SIMD4<Float>
            let baseName: String
            if let baseMaterial, skpMaterials.indices.contains(baseMaterial) {
                baseColor = skpMaterials[baseMaterial].color
                baseName = skpMaterials[baseMaterial].name
            } else {
                baseColor = SIMD4<Float>(1, 1, 1, 1)
                baseName = "VertexColor"
            }
            let combined = baseColor * color
            let newIdx = skpMaterials.count
            skpMaterials.append(SKPModel.Material(
                name: "\(baseName)_vc\(newIdx)",
                color: combined,
                opacity: combined.w
            ))
            vertexColorMaterials[key] = newIdx
            return newIdx
        }

        var decodedTriangleTotal = 0
        for (mIdx, meshDef) in meshDefs.enumerated() {
            if isCancelled() { throw SKPError.cancelled }
            guard let prims = meshDef.primitives else { continue }
            var outPrims: [DecodedPrimitive] = []
            outPrims.reserveCapacity(prims.count)

            for prim in prims {
                guard let posAccIdx = prim.attributes["POSITION"],
                      accessors.indices.contains(posAccIdx)
                else { continue }

                let positions = readVec3Accessor(posAccIdx, accessors: accessors, bufferViews: bufferViews, buffers: buffers)
                guard !positions.isEmpty else { continue }

                let mode = prim.mode ?? 4 // 4 = TRIANGLES
                let rawIndices: [UInt32]
                if let idxAccIdx = prim.indices, accessors.indices.contains(idxAccIdx) {
                    rawIndices = readScalarUInt32Accessor(idxAccIdx, accessors: accessors, bufferViews: bufferViews, buffers: buffers)
                } else {
                    rawIndices = (0..<UInt32(positions.count)).map { $0 }
                }

                // Handle line primitives (1 = LINES, 2 = LINE_LOOP, 3 = LINE_STRIP)
                if mode == 1 || mode == 2 || mode == 3 {
                    var segs: [SIMD3<Float>] = []
                    let vCount = positions.count
                    if mode == 1 {
                        var i = 0
                        while i + 1 < rawIndices.count {
                            let i0 = Int(rawIndices[i]), i1 = Int(rawIndices[i + 1])
                            if i0 < vCount && i1 < vCount {
                                segs.append(positions[i0])
                                segs.append(positions[i1])
                            }
                            i += 2
                        }
                    } else if rawIndices.count >= 2 {
                        for i in 0..<(rawIndices.count - 1) {
                            let i0 = Int(rawIndices[i]), i1 = Int(rawIndices[i + 1])
                            if i0 < vCount && i1 < vCount {
                                segs.append(positions[i0])
                                segs.append(positions[i1])
                            }
                        }
                        if mode == 2, rawIndices.count >= 3 {
                            let iLast = Int(rawIndices.last!), iFirst = Int(rawIndices.first!)
                            if iLast < vCount && iFirst < vCount {
                                segs.append(positions[iLast])
                                segs.append(positions[iFirst])
                            }
                        }
                    }
                    if !segs.isEmpty {
                        outPrims.append(DecodedPrimitive(
                            material: prim.material,
                            positions: [],
                            normals: [],
                            uvs: nil,
                            indices: [],
                            lineSegments: segs,
                            featureEdges: []
                        ))
                    }
                    continue
                }

                // Convert triangle modes (4 = TRIANGLES, 5 = TRIANGLE_STRIP, 6 = TRIANGLE_FAN) to triangle list
                let triIndices = Self.triangulateIndices(rawIndices, mode: mode, vertexCount: positions.count)
                guard triIndices.count >= 3 else { continue }

                var normals: [SIMD3<Float>]
                if let normAccIdx = prim.attributes["NORMAL"], accessors.indices.contains(normAccIdx) {
                    normals = readVec3Accessor(normAccIdx, accessors: accessors, bufferViews: bufferViews, buffers: buffers)
                    if normals.count != positions.count {
                        normals = Self.computeVertexNormals(positions: positions, indices: triIndices)
                    }
                } else {
                    normals = Self.computeVertexNormals(positions: positions, indices: triIndices)
                }

                var matIndex: Int? = prim.material.flatMap { skpMaterials.indices.contains($0) ? $0 : nil }
                let uvTrans = matIndex.map { materialUVTransforms[$0] } ?? MaterialUVTransform()

                // Choose requested TEXCOORD_n (e.g. TEXCOORD_1 in Blender lightmap/dual-UV exports), falling back to TEXCOORD_0
                let preferredUVKey = "TEXCOORD_\(uvTrans.texCoordIndex)"
                let uvAccIdx = prim.attributes[preferredUVKey] ?? prim.attributes["TEXCOORD_0"]
                var uvs: [SIMD2<Float>]? = nil
                if let uvAccIdx, accessors.indices.contains(uvAccIdx) {
                    var rawUVs = readVec2Accessor(uvAccIdx, accessors: accessors, bufferViews: bufferViews, buffers: buffers)
                    if rawUVs.count == positions.count {
                        let cosR = cos(uvTrans.rotation)
                        let sinR = sin(uvTrans.rotation)
                        for i in 0..<rawUVs.count {
                            var uv = rawUVs[i]
                            if uvTrans.hasTransform {
                                uv *= uvTrans.scale
                                if abs(uvTrans.rotation) > 1e-6 {
                                    uv = SIMD2<Float>(uv.x * cosR - uv.y * sinR, uv.x * sinR + uv.y * cosR)
                                }
                                uv += uvTrans.offset
                            }
                            // Convert glTF upper-left UV origin (v down) to SKPModel lower-left UV origin (v up)
                            rawUVs[i] = SIMD2<Float>(uv.x, 1.0 - uv.y)
                        }
                        uvs = rawUVs
                    }
                }

                // If the primitive is untextured and carries COLOR_0 vertex colors, bake the average vertex color into a material
                let isTextured = matIndex.flatMap { skpMaterials[$0].textureURL != nil } ?? false
                if !isTextured, let colAccIdx = prim.attributes["COLOR_0"], accessors.indices.contains(colAccIdx) {
                    if let avgColor = readAverageColor(colAccIdx, accessors: accessors, bufferViews: bufferViews, buffers: buffers) {
                        matIndex = materialWithVertexColor(baseMaterial: matIndex, color: avgColor)
                    }
                }

                let fEdges = Self.extractFeatureEdges(positions: positions, indices: triIndices)
                decodedTriangleTotal += triIndices.count / 3
                outPrims.append(DecodedPrimitive(
                    material: matIndex,
                    positions: positions,
                    normals: normals,
                    uvs: uvs,
                    indices: triIndices,
                    lineSegments: [],
                    featureEdges: fEdges
                ))
            }

            decodedMeshes[mIdx] = outPrims
            if (mIdx & 7) == 0 {
                progress?(SKPReader.Progress(
                    phase: L("Décodage des maillages glTF…", "Decoding glTF meshes…"),
                    faces: decodedTriangleTotal,
                    fraction: 0.15 + 0.55 * (Double(mIdx + 1) / Double(max(meshDefs.count, 1))),
                    blocks: meshDefs.count,
                    currentItem: meshDef.name ?? "Mesh \(mIdx + 1)"
                ))
            }
        }

        // Traverse scene graph (or all root nodes if `scenes` is omitted)
        let nodeDefs = doc.nodes ?? []
        let rootNodeIndices: [Int] = {
            if let scenes = doc.scenes, !scenes.isEmpty {
                let sIdx = doc.scene ?? 0
                if scenes.indices.contains(sIdx), let roots = scenes[sIdx].nodes, !roots.isEmpty {
                    return roots
                }
                let allSceneNodes = scenes.flatMap { $0.nodes ?? [] }
                if !allSceneNodes.isEmpty { return allSceneNodes }
            }
            // Fallback: nodes that are never referenced as children
            var childSet = Set<Int>()
            for n in nodeDefs {
                for c in n.children ?? [] { childSet.insert(c) }
            }
            return nodeDefs.indices.filter { !childSet.contains($0) }
        }()

        var layers: [SKPModel.Layer] = [SKPModel.Layer(name: "Layer0", isVisible: true)]
        var layerIndexByName: [String: Int] = ["Layer0": 0]
        func ensureLayer(_ rawName: String) -> Int {
            let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            let name = trimmed.isEmpty ? "Layer0" : trimmed
            if let existing = layerIndexByName[name] { return existing }
            let idx = layers.count
            layers.append(SKPModel.Layer(name: name, isVisible: true))
            layerIndexByName[name] = idx
            return idx
        }

        // Build one SKPModel.Definition per non-empty glTF Mesh so shared meshes stay instanced
        var skpDefinitions: [SKPModel.Definition] = []
        var meshToDefIndex: [Int: Int] = [:]
        for (mIdx, prims) in decodedMeshes.enumerated() where !prims.isEmpty {
            var defMeshes: [SKPModel.Mesh] = []
            var defEdges: [SKPModel.EdgeSet] = []
            var allEdgePoints: [SIMD3<Float>] = []
            for p in prims {
                if !p.positions.isEmpty && !p.indices.isEmpty {
                    defMeshes.append(SKPModel.Mesh(
                        material: p.material,
                        layer: 0,
                        positions: p.positions,
                        normals: p.normals,
                        uvs: p.uvs,
                        indices: p.indices
                    ))
                }
                if !p.lineSegments.isEmpty {
                    allEdgePoints.append(contentsOf: p.lineSegments)
                }
                if !p.featureEdges.isEmpty {
                    allEdgePoints.append(contentsOf: p.featureEdges)
                }
            }
            if !allEdgePoints.isEmpty {
                defEdges.append(SKPModel.EdgeSet(layer: 0, positions: allEdgePoints))
            }
            let defName = (meshDefs[mIdx].name?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
                ?? "Mesh_\(mIdx + 1)"
            let defIdx = skpDefinitions.count
            skpDefinitions.append(SKPModel.Definition(name: defName, meshes: defMeshes, edges: defEdges, children: []))
            meshToDefIndex[mIdx] = defIdx
        }

        var rootInstances: [SKPModel.Instance] = []
        var extractedScenes: [SKPModel.Scene] = []
        let cameraDefs = doc.cameras ?? []

        var boundsMin = SIMD3<Float>(repeating: .infinity)
        var boundsMax = SIMD3<Float>(repeating: -.infinity)
        var totalTriangles = 0
        var totalEdges = 0

        func traverseNode(
            nodeIndex: Int,
            parentTransform: simd_float4x4,
            inheritedLayerName: String?,
            visited: inout Set<Int>
        ) {
            guard nodeDefs.indices.contains(nodeIndex), !visited.contains(nodeIndex) else { return }
            visited.insert(nodeIndex)
            defer { visited.remove(nodeIndex) }

            let node = nodeDefs[nodeIndex]
            let localMatrix = Self.nodeLocalMatrix(node)
            let worldMatrix = parentTransform * localMatrix

            let rawNodeName = node.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let isGenericWrapper = rawNodeName.isEmpty
                || rawNodeName == "RootNode"
                || rawNodeName == "Scene"
                || rawNodeName.hasPrefix("Sketchfab_")
                || rawNodeName.hasPrefix("GLTF_SceneRootNode")
            let currentLayerName: String? = inheritedLayerName ?? (isGenericWrapper ? nil : rawNodeName)

            if let camIdx = node.camera, cameraDefs.indices.contains(camIdx) {
                let camDef = cameraDefs[camIdx]
                // In glTF, a camera looks along local -Z with +Y up
                let origin4 = worldMatrix * SIMD4<Float>(0, 0, 0, 1)
                let target4 = worldMatrix * SIMD4<Float>(0, 0, -5.0, 1)
                let up4 = worldMatrix * SIMD4<Float>(0, 1, 0, 0)
                let pos = SIMD3<Float>(origin4.x, origin4.y, origin4.z)
                let tgt = SIMD3<Float>(target4.x, target4.y, target4.z)
                let upVec = simd_length(SIMD3<Float>(up4.x, up4.y, up4.z)) > 1e-4
                    ? simd_normalize(SIMD3<Float>(up4.x, up4.y, up4.z))
                    : SIMD3<Float>(0, 0, 1)
                let isPersp = (camDef.type.lowercased() != "orthographic")
                let fovDeg: Float = camDef.perspective.map { max(10.0, min(120.0, $0.yfov * 180.0 / .pi)) } ?? 35.0
                let orthoH: Float = camDef.orthographic.map { max(0.1, $0.ymag * 2.0) } ?? 10.0
                let sceneTitle = camDef.name ?? (rawNodeName.isEmpty ? "Caméra \(extractedScenes.count + 1)" : rawNodeName)
                let skpCam = SKPModel.Camera(
                    position: pos,
                    target: tgt,
                    up: upVec,
                    isPerspective: isPersp,
                    fovDegrees: fovDeg,
                    orthoHeight: orthoH
                )
                extractedScenes.append(SKPModel.Scene(name: sceneTitle, camera: skpCam, hiddenLayers: nil))
            }

            if let mIdx = node.mesh, let defIdx = meshToDefIndex[mIdx] {
                let meshName = meshDefs[mIdx].name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let effectiveLayerName = currentLayerName ?? (!meshName.isEmpty ? meshName : "Layer0")
                let layerIdx = ensureLayer(effectiveLayerName)

                let def = skpDefinitions[defIdx]
                for mesh in def.meshes {
                    totalTriangles += mesh.indices.count / 3
                    for p in mesh.positions {
                        let wp4 = worldMatrix * SIMD4<Float>(p, 1.0)
                        let wp = SIMD3<Float>(wp4.x, wp4.y, wp4.z)
                        boundsMin = simd_min(boundsMin, wp)
                        boundsMax = simd_max(boundsMax, wp)
                    }
                }
                for eSet in def.edges {
                    totalEdges += eSet.positions.count / 2
                    for p in eSet.positions {
                        let wp4 = worldMatrix * SIMD4<Float>(p, 1.0)
                        let wp = SIMD3<Float>(wp4.x, wp4.y, wp4.z)
                        boundsMin = simd_min(boundsMin, wp)
                        boundsMax = simd_max(boundsMax, wp)
                    }
                }

                let instName = !rawNodeName.isEmpty ? rawNodeName : def.name
                rootInstances.append(SKPModel.Instance(
                    definition: defIdx,
                    transform: worldMatrix,
                    layer: layerIdx,
                    isGroup: false,
                    material: nil,
                    name: instName
                ))
            }

            for childIdx in node.children ?? [] {
                traverseNode(
                    nodeIndex: childIdx,
                    parentTransform: worldMatrix,
                    inheritedLayerName: currentLayerName,
                    visited: &visited
                )
            }
        }

        var visitedNodes = Set<Int>()
        for rIdx in rootNodeIndices {
            traverseNode(
                nodeIndex: rIdx,
                parentTransform: yUpToZUp,
                inheritedLayerName: nil,
                visited: &visitedNodes
            )
        }

        // Fallback if a glTF has meshes but no nodes referencing them
        if rootInstances.isEmpty && !skpDefinitions.isEmpty {
            for (mIdx, defIdx) in meshToDefIndex.sorted(by: { $0.key < $1.key }) {
                let def = skpDefinitions[defIdx]
                let layerIdx = ensureLayer(def.name)
                for mesh in def.meshes {
                    totalTriangles += mesh.indices.count / 3
                    for p in mesh.positions {
                        let wp4 = yUpToZUp * SIMD4<Float>(p, 1.0)
                        let wp = SIMD3<Float>(wp4.x, wp4.y, wp4.z)
                        boundsMin = simd_min(boundsMin, wp)
                        boundsMax = simd_max(boundsMax, wp)
                    }
                }
                for eSet in def.edges {
                    totalEdges += eSet.positions.count / 2
                }
                rootInstances.append(SKPModel.Instance(
                    definition: defIdx,
                    transform: yUpToZUp,
                    layer: layerIdx,
                    isGroup: false,
                    material: nil,
                    name: meshDefs[mIdx].name ?? def.name
                ))
            }
        }

        if !(boundsMin.x <= boundsMax.x) {
            boundsMin = SIMD3<Float>(-1, -1, 0)
            boundsMax = SIMD3<Float>(1, 1, 1)
        }

        let rootDef = SKPModel.Definition(
            name: url.deletingPathExtension().lastPathComponent,
            meshes: [],
            edges: [],
            children: rootInstances
        )
        let elapsed = Date().timeIntervalSince(startTime)
        let stats = SKPModel.Stats(
            faces: totalTriangles,
            triangles: totalTriangles,
            edges: totalEdges,
            instances: rootInstances.count,
            definitions: skpDefinitions.count,
            splats: 0,
            loadSeconds: elapsed
        )

        return SKPModel(
            root: rootDef,
            definitions: skpDefinitions,
            materials: skpMaterials,
            layers: layers,
            scenes: extractedScenes,
            camera: extractedScenes.first?.camera,
            boundsMin: boundsMin,
            boundsMax: boundsMax,
            stats: stats,
            fileInfo: fileInfo,
            loadWarning: nil,
            textureDirectory: textureDirectory
        )
    }

    // MARK: - GLB Binary Container & Buffer Resolution

    private static let glbMagic: UInt32 = 0x46546C67 // "glTF"
    private static let glbJSONChunkType: UInt32 = 0x4E4F534A // "JSON"
    private static let glbBINChunkType: UInt32 = 0x004E4942 // "BIN\0"

    private static func extractJSONAndBinaryChunk(from data: Data, url: URL) throws -> (json: Data, bin: Data?) {
        if data.count >= 20 {
            let magic: UInt32 = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: UInt32.self).littleEndian }
            if magic == glbMagic {
                let version: UInt32 = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self).littleEndian }
                guard version == 2 else { throw SKPError.unreadable(url) }
                var offset = 12
                var jsonChunk: Data? = nil
                var binChunk: Data? = nil
                while offset + 8 <= data.count {
                    let chunkLength: Int = data.withUnsafeBytes {
                        Int($0.loadUnaligned(fromByteOffset: offset, as: UInt32.self).littleEndian)
                    }
                    let chunkType: UInt32 = data.withUnsafeBytes {
                        $0.loadUnaligned(fromByteOffset: offset + 4, as: UInt32.self).littleEndian
                    }
                    offset += 8
                    let end = min(offset + chunkLength, data.count)
                    guard end >= offset else { break }
                    let slice = data.subdata(in: offset..<end)
                    if chunkType == glbJSONChunkType && jsonChunk == nil {
                        jsonChunk = slice
                    } else if chunkType == glbBINChunkType && binChunk == nil {
                        binChunk = slice
                    }
                    offset += chunkLength
                }
                guard let jsonChunk else { throw SKPError.unreadable(url) }
                return (jsonChunk, binChunk)
            }
        }
        return (data, nil)
    }

    private static func resolveBuffers(
        doc: GLTFDocument,
        glbBinChunk: Data?,
        baseDir: URL,
        url: URL
    ) throws -> [Data] {
        guard let bufferDefs = doc.buffers, !bufferDefs.isEmpty else {
            return glbBinChunk.map { [$0] } ?? []
        }
        var result: [Data] = []
        result.reserveCapacity(bufferDefs.count)
        for (idx, bufDef) in bufferDefs.enumerated() {
            if let uri = bufDef.uri, !uri.isEmpty {
                if uri.hasPrefix("data:") {
                    guard let decoded = decodeDataURI(uri) else {
                        throw SKPError.unreadable(url)
                    }
                    result.append(decoded)
                } else {
                    let decodedPath = uri.removingPercentEncoding ?? uri
                    let binURL = baseDir.appendingPathComponent(decodedPath)
                    guard let binData = try? Data(contentsOf: binURL, options: .mappedIfSafe) else {
                        throw SKPError.unreadable(binURL)
                    }
                    result.append(binData)
                }
            } else if idx == 0, let glbBinChunk {
                result.append(glbBinChunk)
            } else {
                result.append(Data())
            }
        }
        return result
    }

    private static func decodeDataURI(_ uri: String) -> Data? {
        guard let comma = uri.firstIndex(of: ",") else { return nil }
        let payload = String(uri[uri.index(after: comma)...])
        return Data(base64Encoded: payload, options: .ignoreUnknownCharacters)
    }

    private static func sliceForBufferView(
        _ bvIndex: Int,
        bufferViews: [GLTFDocument.BufferViewDef],
        buffers: [Data]
    ) -> Data.SubSequence? {
        guard bufferViews.indices.contains(bvIndex) else { return nil }
        let bv = bufferViews[bvIndex]
        guard buffers.indices.contains(bv.buffer) else { return nil }
        let buf = buffers[bv.buffer]
        let start = bv.byteOffset ?? 0
        let end = min(start + bv.byteLength, buf.count)
        guard start >= 0 && start <= end else { return nil }
        return buf[start..<end]
    }

    // MARK: - Accessor Readers

    private static func componentByteSize(_ componentType: Int) -> Int {
        switch componentType {
        case 5120, 5121: return 1 // BYTE, UNSIGNED_BYTE
        case 5122, 5123: return 2 // SHORT, UNSIGNED_SHORT
        case 5125, 5126: return 4 // UNSIGNED_INT, FLOAT
        default: return 4
        }
    }

    private static func readComponentFloat(
        from raw: UnsafeRawBufferPointer,
        byteOffset: Int,
        componentType: Int,
        normalized: Bool
    ) -> Float {
        switch componentType {
        case 5126: // FLOAT
            guard byteOffset + 4 <= raw.count else { return 0 }
            let bits = raw.loadUnaligned(fromByteOffset: byteOffset, as: UInt32.self).littleEndian
            return Float(bitPattern: bits)
        case 5121: // UNSIGNED_BYTE
            guard byteOffset + 1 <= raw.count else { return 0 }
            let v = raw[byteOffset]
            return normalized ? (Float(v) / 255.0) : Float(v)
        case 5120: // BYTE
            guard byteOffset + 1 <= raw.count else { return 0 }
            let v = Int8(bitPattern: raw[byteOffset])
            return normalized ? max(Float(v) / 127.0, -1.0) : Float(v)
        case 5123: // UNSIGNED_SHORT
            guard byteOffset + 2 <= raw.count else { return 0 }
            let v = raw.loadUnaligned(fromByteOffset: byteOffset, as: UInt16.self).littleEndian
            return normalized ? (Float(v) / 65535.0) : Float(v)
        case 5122: // SHORT
            guard byteOffset + 2 <= raw.count else { return 0 }
            let v = raw.loadUnaligned(fromByteOffset: byteOffset, as: Int16.self).littleEndian
            return normalized ? max(Float(v) / 32767.0, -1.0) : Float(v)
        case 5125: // UNSIGNED_INT
            guard byteOffset + 4 <= raw.count else { return 0 }
            let v = raw.loadUnaligned(fromByteOffset: byteOffset, as: UInt32.self).littleEndian
            return Float(v)
        default:
            return 0
        }
    }

    private static func readVec3Accessor(
        _ accIndex: Int,
        accessors: [GLTFDocument.AccessorDef],
        bufferViews: [GLTFDocument.BufferViewDef],
        buffers: [Data]
    ) -> [SIMD3<Float>] {
        let acc = accessors[accIndex]
        guard acc.count > 0 else { return [] }
        var out = [SIMD3<Float>](repeating: .zero, count: acc.count)

        if let bvIdx = acc.bufferView, bufferViews.indices.contains(bvIdx) {
            let bv = bufferViews[bvIdx]
            if buffers.indices.contains(bv.buffer) {
                let buf = buffers[bv.buffer]
                let compSize = componentByteSize(acc.componentType)
                let elemSize = compSize * 3
                let stride = bv.byteStride ?? elemSize
                let baseOffset = (bv.byteOffset ?? 0) + (acc.byteOffset ?? 0)
                let norm = acc.normalized ?? false

                buf.withUnsafeBytes { raw in
                    if acc.componentType == 5126 && stride == 12 && baseOffset + acc.count * 12 <= raw.count {
                        for i in 0..<acc.count {
                            let off = baseOffset + i * 12
                            let x = Float(bitPattern: raw.loadUnaligned(fromByteOffset: off, as: UInt32.self).littleEndian)
                            let y = Float(bitPattern: raw.loadUnaligned(fromByteOffset: off + 4, as: UInt32.self).littleEndian)
                            let z = Float(bitPattern: raw.loadUnaligned(fromByteOffset: off + 8, as: UInt32.self).littleEndian)
                            out[i] = SIMD3<Float>(x, y, z)
                        }
                    } else {
                        for i in 0..<acc.count {
                            let off = baseOffset + i * stride
                            let x = readComponentFloat(from: raw, byteOffset: off, componentType: acc.componentType, normalized: norm)
                            let y = readComponentFloat(from: raw, byteOffset: off + compSize, componentType: acc.componentType, normalized: norm)
                            let z = readComponentFloat(from: raw, byteOffset: off + compSize * 2, componentType: acc.componentType, normalized: norm)
                            out[i] = SIMD3<Float>(x, y, z)
                        }
                    }
                }
            }
        }
        return out
    }

    private static func readVec2Accessor(
        _ accIndex: Int,
        accessors: [GLTFDocument.AccessorDef],
        bufferViews: [GLTFDocument.BufferViewDef],
        buffers: [Data]
    ) -> [SIMD2<Float>] {
        let acc = accessors[accIndex]
        guard acc.count > 0, let bvIdx = acc.bufferView, bufferViews.indices.contains(bvIdx) else { return [] }
        let bv = bufferViews[bvIdx]
        guard buffers.indices.contains(bv.buffer) else { return [] }
        let buf = buffers[bv.buffer]
        let compSize = componentByteSize(acc.componentType)
        let elemSize = compSize * 2
        let stride = bv.byteStride ?? elemSize
        let baseOffset = (bv.byteOffset ?? 0) + (acc.byteOffset ?? 0)
        let norm = acc.normalized ?? (acc.componentType == 5121 || acc.componentType == 5123)
        var out = [SIMD2<Float>](repeating: .zero, count: acc.count)

        buf.withUnsafeBytes { raw in
            if acc.componentType == 5126 && stride == 8 && baseOffset + acc.count * 8 <= raw.count {
                for i in 0..<acc.count {
                    let off = baseOffset + i * 8
                    let u = Float(bitPattern: raw.loadUnaligned(fromByteOffset: off, as: UInt32.self).littleEndian)
                    let v = Float(bitPattern: raw.loadUnaligned(fromByteOffset: off + 4, as: UInt32.self).littleEndian)
                    out[i] = SIMD2<Float>(u, v)
                }
            } else {
                for i in 0..<acc.count {
                    let off = baseOffset + i * stride
                    let u = readComponentFloat(from: raw, byteOffset: off, componentType: acc.componentType, normalized: norm)
                    let v = readComponentFloat(from: raw, byteOffset: off + compSize, componentType: acc.componentType, normalized: norm)
                    out[i] = SIMD2<Float>(u, v)
                }
            }
        }
        return out
    }

    private static func readScalarUInt32Accessor(
        _ accIndex: Int,
        accessors: [GLTFDocument.AccessorDef],
        bufferViews: [GLTFDocument.BufferViewDef],
        buffers: [Data]
    ) -> [UInt32] {
        let acc = accessors[accIndex]
        guard acc.count > 0, let bvIdx = acc.bufferView, bufferViews.indices.contains(bvIdx) else { return [] }
        let bv = bufferViews[bvIdx]
        guard buffers.indices.contains(bv.buffer) else { return [] }
        let buf = buffers[bv.buffer]
        let compSize = componentByteSize(acc.componentType)
        let stride = bv.byteStride ?? compSize
        let baseOffset = (bv.byteOffset ?? 0) + (acc.byteOffset ?? 0)
        var out = [UInt32](repeating: 0, count: acc.count)

        buf.withUnsafeBytes { raw in
            switch acc.componentType {
            case 5121: // UNSIGNED_BYTE
                for i in 0..<acc.count {
                    let off = baseOffset + i * stride
                    if off < raw.count { out[i] = UInt32(raw[off]) }
                }
            case 5123: // UNSIGNED_SHORT
                for i in 0..<acc.count {
                    let off = baseOffset + i * stride
                    if off + 2 <= raw.count {
                        out[i] = UInt32(raw.loadUnaligned(fromByteOffset: off, as: UInt16.self).littleEndian)
                    }
                }
            case 5125: // UNSIGNED_INT
                for i in 0..<acc.count {
                    let off = baseOffset + i * stride
                    if off + 4 <= raw.count {
                        out[i] = raw.loadUnaligned(fromByteOffset: off, as: UInt32.self).littleEndian
                    }
                }
            default:
                break
            }
        }
        return out
    }

    private static func readAverageColor(
        _ accIndex: Int,
        accessors: [GLTFDocument.AccessorDef],
        bufferViews: [GLTFDocument.BufferViewDef],
        buffers: [Data]
    ) -> SIMD4<Float>? {
        let acc = accessors[accIndex]
        guard acc.count > 0, let bvIdx = acc.bufferView, bufferViews.indices.contains(bvIdx) else { return nil }
        let bv = bufferViews[bvIdx]
        guard buffers.indices.contains(bv.buffer) else { return nil }
        let buf = buffers[bv.buffer]
        let isVec4 = (acc.type == "VEC4")
        let numComps = isVec4 ? 4 : 3
        let compSize = componentByteSize(acc.componentType)
        let stride = bv.byteStride ?? (compSize * numComps)
        let baseOffset = (bv.byteOffset ?? 0) + (acc.byteOffset ?? 0)
        let norm = acc.normalized ?? (acc.componentType == 5121 || acc.componentType == 5123)

        let step = max(1, acc.count / 256)
        var sum = SIMD4<Float>.zero
        var samples = 0
        buf.withUnsafeBytes { raw in
            var i = 0
            while i < acc.count {
                let off = baseOffset + i * stride
                let r = readComponentFloat(from: raw, byteOffset: off, componentType: acc.componentType, normalized: norm)
                let g = readComponentFloat(from: raw, byteOffset: off + compSize, componentType: acc.componentType, normalized: norm)
                let b = readComponentFloat(from: raw, byteOffset: off + compSize * 2, componentType: acc.componentType, normalized: norm)
                let a = isVec4 ? readComponentFloat(from: raw, byteOffset: off + compSize * 3, componentType: acc.componentType, normalized: norm) : 1.0
                sum += SIMD4<Float>(r, g, b, a)
                samples += 1
                i += step
            }
        }
        guard samples > 0 else { return nil }
        return simd_clamp(sum / Float(samples), SIMD4<Float>(repeating: 0), SIMD4<Float>(repeating: 1))
    }

    // MARK: - Scene Graph & Geometry Utilities

    private static func nodeLocalMatrix(_ node: GLTFDocument.NodeDef) -> simd_float4x4 {
        if let m = node.matrix, m.count == 16 {
            return simd_float4x4(
                SIMD4<Float>(m[0], m[1], m[2], m[3]),
                SIMD4<Float>(m[4], m[5], m[6], m[7]),
                SIMD4<Float>(m[8], m[9], m[10], m[11]),
                SIMD4<Float>(m[12], m[13], m[14], m[15])
            )
        }
        let t = node.translation ?? [0, 0, 0]
        let r = node.rotation ?? [0, 0, 0, 1]
        let s = node.scale ?? [1, 1, 1]

        let tx = t.count > 0 ? t[0] : 0
        let ty = t.count > 1 ? t[1] : 0
        let tz = t.count > 2 ? t[2] : 0

        let qx = r.count > 0 ? r[0] : 0
        let qy = r.count > 1 ? r[1] : 0
        let qz = r.count > 2 ? r[2] : 0
        let qw = r.count > 3 ? r[3] : 1
        let quat = simd_normalize(simd_quatf(ix: qx, iy: qy, iz: qz, r: qw))
        let rotMat = simd_float4x4(quat)

        let sx = s.count > 0 ? s[0] : 1
        let sy = s.count > 1 ? s[1] : 1
        let sz = s.count > 2 ? s[2] : 1

        var mat = rotMat
        mat.columns.0 *= sx
        mat.columns.1 *= sy
        mat.columns.2 *= sz
        mat.columns.3 = SIMD4<Float>(tx, ty, tz, 1.0)
        return mat
    }

    private static func triangulateIndices(_ raw: [UInt32], mode: Int, vertexCount: Int) -> [UInt32] {
        let vLimit = UInt32(max(vertexCount, 0))
        switch mode {
        case 4: // TRIANGLES
            let triCount = raw.count / 3
            guard triCount > 0 else { return [] }
            var out: [UInt32] = []
            out.reserveCapacity(triCount * 3)
            for t in 0..<triCount {
                let i0 = raw[t * 3], i1 = raw[t * 3 + 1], i2 = raw[t * 3 + 2]
                if i0 < vLimit && i1 < vLimit && i2 < vLimit {
                    out.append(i0); out.append(i1); out.append(i2)
                }
            }
            return out
        case 5: // TRIANGLE_STRIP
            guard raw.count >= 3 else { return [] }
            var out: [UInt32] = []
            out.reserveCapacity((raw.count - 2) * 3)
            for i in 0..<(raw.count - 2) {
                let i0 = raw[i]
                let i1 = (i & 1) == 0 ? raw[i + 1] : raw[i + 2]
                let i2 = (i & 1) == 0 ? raw[i + 2] : raw[i + 1]
                if i0 < vLimit && i1 < vLimit && i2 < vLimit && i0 != i1 && i1 != i2 && i2 != i0 {
                    out.append(i0); out.append(i1); out.append(i2)
                }
            }
            return out
        case 6: // TRIANGLE_FAN
            guard raw.count >= 3 else { return [] }
            var out: [UInt32] = []
            out.reserveCapacity((raw.count - 2) * 3)
            let i0 = raw[0]
            for i in 1..<(raw.count - 1) {
                let i1 = raw[i], i2 = raw[i + 1]
                if i0 < vLimit && i1 < vLimit && i2 < vLimit {
                    out.append(i0); out.append(i1); out.append(i2)
                }
            }
            return out
        default:
            return []
        }
    }

    private static func computeVertexNormals(positions: [SIMD3<Float>], indices: [UInt32]) -> [SIMD3<Float>] {
        var accum = [SIMD3<Float>](repeating: .zero, count: positions.count)
        let triCount = indices.count / 3
        for t in 0..<triCount {
            let i0 = Int(indices[t * 3])
            let i1 = Int(indices[t * 3 + 1])
            let i2 = Int(indices[t * 3 + 2])
            let fn = simd_cross(positions[i1] - positions[i0], positions[i2] - positions[i0])
            accum[i0] += fn
            accum[i1] += fn
            accum[i2] += fn
        }
        for i in 0..<accum.count {
            let len = simd_length(accum[i])
            accum[i] = len > 1e-7 ? (accum[i] / len) : SIMD3<Float>(0, 1, 0)
        }
        return accum
    }

    /// Extracts architectural feature & boundary edges (boundary edges + crease edges with dihedral angle > 24°)
    /// so Wireframe, White Clay, X-Ray, and 3D measurement snapping (`⌘D`) work cleanly on glTF/GLB models.
    private static func extractFeatureEdges(positions: [SIMD3<Float>], indices: [UInt32]) -> [SIMD3<Float>] {
        let triCount = indices.count / 3
        guard triCount > 0 && triCount <= 120_000 else { return [] }

        struct QuantizedEdge: Hashable {
            var a: SIMD3<Int32>
            var b: SIMD3<Int32>
            init(_ p0: SIMD3<Float>, _ p1: SIMD3<Float>) {
                let q0 = SIMD3<Int32>(
                    Int32((p0.x * 1000.0).rounded()),
                    Int32((p0.y * 1000.0).rounded()),
                    Int32((p0.z * 1000.0).rounded())
                )
                let q1 = SIMD3<Int32>(
                    Int32((p1.x * 1000.0).rounded()),
                    Int32((p1.y * 1000.0).rounded()),
                    Int32((p1.z * 1000.0).rounded())
                )
                if q0.x < q1.x || (q0.x == q1.x && (q0.y < q1.y || (q0.y == q1.y && q0.z <= q1.z))) {
                    a = q0; b = q1
                } else {
                    a = q1; b = q0
                }
            }
        }

        struct EdgeRecord {
            var p0: SIMD3<Float>
            var p1: SIMD3<Float>
            var normal0: SIMD3<Float>
            var count: Int
            var isCrease: Bool
        }

        let cosThreshold: Float = 0.9135 // cos(24°)
        var edgeMap: [QuantizedEdge: EdgeRecord] = [:]
        edgeMap.reserveCapacity(min(triCount * 2, 65_536))

        for t in 0..<triCount {
            let i0 = Int(indices[t * 3])
            let i1 = Int(indices[t * 3 + 1])
            let i2 = Int(indices[t * 3 + 2])
            let v0 = positions[i0], v1 = positions[i1], v2 = positions[i2]
            let cross = simd_cross(v1 - v0, v2 - v0)
            let cLen = simd_length(cross)
            guard cLen > 1e-8 else { continue }
            let fn = cross / cLen

            let pairs = [(v0, v1), (v1, v2), (v2, v0)]
            for (pa, pb) in pairs {
                let key = QuantizedEdge(pa, pb)
                if var existing = edgeMap[key] {
                    existing.count += 1
                    if simd_dot(existing.normal0, fn) < cosThreshold {
                        existing.isCrease = true
                    }
                    edgeMap[key] = existing
                } else {
                    edgeMap[key] = EdgeRecord(p0: pa, p1: pb, normal0: fn, count: 1, isCrease: false)
                }
            }
        }

        var result: [SIMD3<Float>] = []
        result.reserveCapacity(edgeMap.count)
        for (_, rec) in edgeMap where rec.count == 1 || rec.isCrease {
            result.append(rec.p0)
            result.append(rec.p1)
        }
        return result
    }

    private static func fileExtension(forMimeType mime: String?, data: Data.SubSequence) -> String {
        if let mime = mime?.lowercased() {
            if mime.contains("png") { return "png" }
            if mime.contains("jpeg") || mime.contains("jpg") { return "jpg" }
            if mime.contains("webp") { return "webp" }
            if mime.contains("ktx2") { return "ktx2" }
        }
        if data.count >= 4 {
            let b0 = data[data.startIndex]
            let b1 = data[data.index(data.startIndex, offsetBy: 1)]
            if b0 == 0x89 && b1 == 0x50 { return "png" }
            if b0 == 0xFF && b1 == 0xD8 { return "jpg" }
            if b0 == 0x52 && b1 == 0x49 { return "webp" }
        }
        return "png"
    }

    private static func sanitizedFilename(_ raw: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
        let cleaned = raw.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
        let str = String(cleaned).trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return str.isEmpty ? "texture" : String(str.prefix(48))
    }
}
