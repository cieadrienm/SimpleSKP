import AppKit
import Foundation
import SceneKit
import simd

/// Reads Collada (`.dae`) and Wavefront (`.obj` + `.mtl`) 3D files into `SKPModel` (metres, Z up)
/// using a fast native `.obj`/`.mtl` parser and a native Collada XML parser (with `SceneKit` fallback for binary `.dae`) — zero external dependencies.
public enum Mesh3DReader {
    public static func load(
        _ url: URL,
        fileInfo: SKPFileInfo,
        progress: (@Sendable (SKPReader.Progress) -> Void)? = nil,
        isCancelled: @Sendable () -> Bool = { false }
    ) throws -> SKPModel {
        if isCancelled() { throw SKPError.cancelled }
        if fileInfo.isOBJ {
            return try loadOBJ(url, fileInfo: fileInfo, progress: progress, isCancelled: isCancelled)
        } else {
            return try loadDAE(url, fileInfo: fileInfo, progress: progress, isCancelled: isCancelled)
        }
    }

    // MARK: - Wavefront OBJ (+ MTL) Reader

    private struct EdgeKey: Hashable {
        var a: UInt32
        var b: UInt32
        init(_ u: UInt32, _ v: UInt32) {
            if u <= v { a = u; b = v } else { a = v; b = u }
        }
    }

    private static func loadOBJ(
        _ url: URL,
        fileInfo: SKPFileInfo,
        progress: (@Sendable (SKPReader.Progress) -> Void)?,
        isCancelled: @Sendable () -> Bool
    ) throws -> SKPModel {
        let start = Date()
        progress?(SKPReader.Progress(
            phase: L("Lecture du fichier OBJ…", "Reading OBJ file…"),
            faces: 0,
            fraction: 0.08,
            currentItem: url.lastPathComponent
        ))

        let data: Data
        do {
            data = try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            throw SKPError.unreadable(url)
        }
        if isCancelled() { throw SKPError.cancelled }

        guard let content = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            throw SKPError.unreadable(url)
        }

        let baseDir = url.deletingLastPathComponent()
        var positions: [SIMD3<Float>] = []
        var texcoords: [SIMD2<Float>] = []
        var normals: [SIMD3<Float>] = []

        // Detect if header explicitly states Z-up; standard Wavefront OBJ is Y-up (X right, Y up, Z front).
        let headerPreview = String(content.prefix(2048)).uppercased()
        let isZUp = headerPreview.contains("Z_UP") || headerPreview.contains("UP_AXIS = Z") || headerPreview.contains("UP_AXIS: Z")

        @inline(__always)
        func toModelSpace(_ x: Float, _ y: Float, _ z: Float) -> SIMD3<Float> {
            isZUp ? SIMD3<Float>(x, y, z) : SIMD3<Float>(x, -z, y)
        }

        @inline(__always)
        func normalToModelSpace(_ x: Float, _ y: Float, _ z: Float) -> SIMD3<Float> {
            let v = isZUp ? SIMD3<Float>(x, y, z) : SIMD3<Float>(x, -z, y)
            let len = simd_length(v)
            return len > 1e-6 ? v / len : SIMD3<Float>(0, 0, 1)
        }

        var layers: [SKPModel.Layer] = [SKPModel.Layer(name: "Layer0", isVisible: true)]
        var layerIndexByName: [String: Int] = ["Layer0": 0]
        var currentLayer = 0

        var materials: [SKPModel.Material] = []
        var materialIndexByName: [String: Int] = [:]
        var currentMaterial: Int? = nil

        func ensureLayer(_ rawName: String) -> Int {
            let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            let name = trimmed.isEmpty ? "Layer0" : trimmed
            if let existing = layerIndexByName[name] { return existing }
            let idx = layers.count
            layers.append(SKPModel.Layer(name: name, isVisible: true))
            layerIndexByName[name] = idx
            return idx
        }

        func ensureMaterial(_ rawName: String) -> Int {
            let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            if let existing = materialIndexByName[name] { return existing }
            let idx = materials.count
            materials.append(SKPModel.Material(name: name, color: SIMD4<Float>(0.86, 0.86, 0.88, 1.0)))
            materialIndexByName[name] = idx
            return idx
        }

        struct GroupKey: Hashable {
            var layer: Int
            var material: Int?
        }

        struct MeshAccumulator {
            var positions: [SIMD3<Float>] = []
            var normals: [SIMD3<Float>] = []
            var uvs: [SIMD2<Float>] = []
            var hasUVs: Bool = false
            var indices: [UInt32] = []
            var boundarySegments: [SIMD3<Float>] = []
        }

        var meshGroups: [GroupKey: MeshAccumulator] = [:]
        var explicitLinesByLayer: [Int: [SIMD3<Float>]] = [:]
        var totalFaces = 0
        var totalEdges = 0
        var lineCounter = 0

        func resolveIndex(_ raw: Int, count: Int) -> Int? {
            if raw > 0 {
                let idx = raw - 1
                return idx < count ? idx : nil
            } else if raw < 0 {
                let idx = count + raw
                return (idx >= 0 && idx < count) ? idx : nil
            }
            return nil
        }

        for line in content.split(whereSeparator: \.isNewline) {
            lineCounter &+= 1
            if lineCounter & 0x3FFF == 0 {
                if isCancelled() {
                    throw SKPError.cancelled
                }
                progress?(SKPReader.Progress(
                    phase: L("Analyse de la géométrie OBJ…", "Parsing OBJ geometry…"),
                    faces: totalFaces,
                    fraction: min(0.85, 0.15 + Double(totalFaces) / 250_000.0 * 0.65),
                    edges: totalEdges,
                    blocks: meshGroups.count,
                    layers: layers.count,
                    currentItem: layers[currentLayer].name
                ))
            }

            let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
            guard let first = trimmed.first, first != "#" else { continue }

            if trimmed.hasPrefix("v ") || trimmed.hasPrefix("v\t") {
                let parts = trimmed.dropFirst(2).split(omittingEmptySubsequences: true) { $0 == " " || $0 == "\t" }
                if parts.count >= 3,
                   let x = Float(parts[0]),
                   let y = Float(parts[1]),
                   let z = Float(parts[2]) {
                    positions.append(toModelSpace(x, y, z))
                }
            } else if trimmed.hasPrefix("vt ") || trimmed.hasPrefix("vt\t") {
                let parts = trimmed.dropFirst(3).split(omittingEmptySubsequences: true) { $0 == " " || $0 == "\t" }
                if parts.count >= 2,
                   let u = Float(parts[0]),
                   let v = Float(parts[1]) {
                    texcoords.append(SIMD2<Float>(u, v))
                }
            } else if trimmed.hasPrefix("vn ") || trimmed.hasPrefix("vn\t") {
                let parts = trimmed.dropFirst(3).split(omittingEmptySubsequences: true) { $0 == " " || $0 == "\t" }
                if parts.count >= 3,
                   let nx = Float(parts[0]),
                   let ny = Float(parts[1]),
                   let nz = Float(parts[2]) {
                    normals.append(normalToModelSpace(nx, ny, nz))
                }
            } else if trimmed.hasPrefix("f ") || trimmed.hasPrefix("f\t") {
                let tokens = trimmed.dropFirst(2).split(omittingEmptySubsequences: true) { $0 == " " || $0 == "\t" }
                guard tokens.count >= 3 else { continue }
                var polyPos: [SIMD3<Float>] = []
                var polyUV: [SIMD2<Float>?] = []
                var polyNorm: [SIMD3<Float>?] = []
                polyPos.reserveCapacity(tokens.count)
                polyUV.reserveCapacity(tokens.count)
                polyNorm.reserveCapacity(tokens.count)

                for tok in tokens {
                    let sub = tok.split(separator: "/", omittingEmptySubsequences: false)
                    guard let vRaw = Int(sub[0]), let vIdx = resolveIndex(vRaw, count: positions.count) else { continue }
                    polyPos.append(positions[vIdx])

                    if sub.count >= 2, !sub[1].isEmpty, let vtRaw = Int(sub[1]), let vtIdx = resolveIndex(vtRaw, count: texcoords.count) {
                        polyUV.append(texcoords[vtIdx])
                    } else {
                        polyUV.append(nil)
                    }

                    if sub.count >= 3, !sub[2].isEmpty, let vnRaw = Int(sub[2]), let vnIdx = resolveIndex(vnRaw, count: normals.count) {
                        polyNorm.append(normals[vnIdx])
                    } else {
                        polyNorm.append(nil)
                    }
                }

                guard polyPos.count >= 3 else { continue }
                totalFaces += 1

                let e1 = polyPos[1] - polyPos[0]
                let e2 = polyPos[2] - polyPos[0]
                let cross = simd_cross(e1, e2)
                let crossLen = simd_length(cross)
                let flatNormal = crossLen > 1e-7 ? (cross / crossLen) : SIMD3<Float>(0, 0, 1)

                let key = GroupKey(layer: currentLayer, material: currentMaterial)
                var acc = meshGroups[key] ?? MeshAccumulator()
                let baseIndex = UInt32(acc.positions.count)

                for i in 0..<polyPos.count {
                    acc.positions.append(polyPos[i])
                    acc.normals.append(polyNorm[i] ?? flatNormal)
                    if let uv = polyUV[i] {
                        acc.uvs.append(uv)
                        acc.hasUVs = true
                    } else {
                        acc.uvs.append(.zero)
                    }
                }
                for i in 1..<(polyPos.count - 1) {
                    acc.indices.append(baseIndex)
                    acc.indices.append(baseIndex + UInt32(i))
                    acc.indices.append(baseIndex + UInt32(i + 1))
                }
                if acc.boundarySegments.count < 80_000 {
                    for i in 0..<polyPos.count {
                        let a = polyPos[i]
                        let b = polyPos[(i + 1) % polyPos.count]
                        if simd_distance_squared(a, b) > 1e-10 {
                            acc.boundarySegments.append(a)
                            acc.boundarySegments.append(b)
                            totalEdges += 1
                        }
                    }
                }
                meshGroups[key] = acc
            } else if trimmed.hasPrefix("l ") || trimmed.hasPrefix("l\t") {
                let tokens = trimmed.dropFirst(2).split(omittingEmptySubsequences: true) { $0 == " " || $0 == "\t" }
                var linePts: [SIMD3<Float>] = []
                for tok in tokens {
                    let vStr = tok.split(separator: "/").first ?? tok
                    if let vRaw = Int(vStr), let vIdx = resolveIndex(vRaw, count: positions.count) {
                        linePts.append(positions[vIdx])
                    }
                }
                if linePts.count >= 2 {
                    var arr = explicitLinesByLayer[currentLayer] ?? []
                    for i in 0..<(linePts.count - 1) {
                        arr.append(linePts[i])
                        arr.append(linePts[i + 1])
                        totalEdges += 1
                    }
                    explicitLinesByLayer[currentLayer] = arr
                }
            } else if trimmed.hasPrefix("o ") || trimmed.hasPrefix("o\t") || trimmed.hasPrefix("g ") || trimmed.hasPrefix("g\t") {
                let name = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty && name.lowercased() != "default" {
                    currentLayer = ensureLayer(name)
                }
            } else if trimmed.hasPrefix("usemtl ") || trimmed.hasPrefix("usemtl\t") {
                let name = String(trimmed.dropFirst(7)).trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty {
                    currentMaterial = ensureMaterial(name)
                }
            } else if trimmed.hasPrefix("mtllib ") || trimmed.hasPrefix("mtllib\t") {
                let mtlRel = String(trimmed.dropFirst(7)).trimmingCharacters(in: .whitespacesAndNewlines)
                if !mtlRel.isEmpty {
                    let mtlURL = baseDir.appendingPathComponent(mtlRel)
                    parseMTL(at: mtlURL, baseDir: baseDir, materials: &materials, materialIndexByName: &materialIndexByName)
                }
            }
        }

        if isCancelled() { throw SKPError.cancelled }

        var meshes: [SKPModel.Mesh] = []
        var edgeSetsByLayer: [Int: [SIMD3<Float>]] = explicitLinesByLayer
        var boundsMin = SIMD3<Float>(repeating: .infinity)
        var boundsMax = SIMD3<Float>(repeating: -.infinity)
        var totalTriangles = 0

        for p in positions {
            boundsMin = simd_min(boundsMin, p)
            boundsMax = simd_max(boundsMax, p)
        }

        for (key, acc) in meshGroups where !acc.indices.isEmpty {
            let uvs: [SIMD2<Float>]? = acc.hasUVs ? acc.uvs : nil
            meshes.append(SKPModel.Mesh(
                material: key.material,
                layer: key.layer,
                positions: acc.positions,
                normals: acc.normals,
                uvs: uvs,
                indices: acc.indices
            ))
            totalTriangles += acc.indices.count / 3
            if !acc.boundarySegments.isEmpty {
                edgeSetsByLayer[key.layer, default: []].append(contentsOf: acc.boundarySegments)
            }
        }

        var edgeSets: [SKPModel.EdgeSet] = []
        var finalEdgeCount = 0
        for (layerIdx, segs) in edgeSetsByLayer where !segs.isEmpty {
            edgeSets.append(SKPModel.EdgeSet(layer: layerIdx, material: nil, positions: segs))
            finalEdgeCount += segs.count / 2
        }

        if !(boundsMin.x <= boundsMax.x) {
            boundsMin = .zero
            boundsMax = .zero
        }

        let root = SKPModel.Definition(name: "", meshes: meshes, edges: edgeSets, children: [])
        let elapsed = Date().timeIntervalSince(start)
        let stats = SKPModel.Stats(
            faces: totalFaces,
            triangles: totalTriangles,
            edges: finalEdgeCount,
            instances: 0,
            definitions: 0,
            loadSeconds: elapsed
        )
        return SKPModel(
            root: root,
            definitions: [],
            materials: materials,
            layers: layers,
            scenes: [],
            camera: nil,
            boundsMin: boundsMin,
            boundsMax: boundsMax,
            stats: stats,
            fileInfo: fileInfo
        )
    }

    private static func parseMTL(
        at url: URL,
        baseDir: URL,
        materials: inout [SKPModel.Material],
        materialIndexByName: inout [String: Int]
    ) {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
        else { return }

        var currentIndex: Int? = nil
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
            guard let first = trimmed.first, first != "#" else { continue }

            if trimmed.hasPrefix("newmtl ") || trimmed.hasPrefix("newmtl\t") {
                let name = String(trimmed.dropFirst(7)).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { continue }
                if let existing = materialIndexByName[name] {
                    currentIndex = existing
                } else {
                    let idx = materials.count
                    materials.append(SKPModel.Material(name: name, color: SIMD4<Float>(0.86, 0.86, 0.88, 1.0)))
                    materialIndexByName[name] = idx
                    currentIndex = idx
                }
            } else if let idx = currentIndex {
                if trimmed.hasPrefix("Kd ") || trimmed.hasPrefix("Kd\t") {
                    let parts = trimmed.dropFirst(3).split(omittingEmptySubsequences: true) { $0 == " " || $0 == "\t" }
                    if parts.count >= 3,
                       let r = Float(parts[0]),
                       let g = Float(parts[1]),
                       let b = Float(parts[2]) {
                        materials[idx].color = SIMD4<Float>(r, g, b, materials[idx].opacity)
                    }
                } else if trimmed.hasPrefix("d ") || trimmed.hasPrefix("d\t") {
                    let valStr = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespacesAndNewlines)
                    if let d = Float(valStr) {
                        let clamped = max(0.0, min(1.0, d))
                        materials[idx].opacity = clamped
                        materials[idx].color.w = clamped
                        materials[idx].isTransparent = clamped < 0.999
                    }
                } else if trimmed.hasPrefix("Tr ") || trimmed.hasPrefix("Tr\t") {
                    let valStr = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
                    if let tr = Float(valStr) {
                        let clamped = max(0.0, min(1.0, 1.0 - tr))
                        materials[idx].opacity = clamped
                        materials[idx].color.w = clamped
                        materials[idx].isTransparent = clamped < 0.999
                    }
                } else if trimmed.hasPrefix("map_Kd ") || trimmed.hasPrefix("map_Kd\t") {
                    let rawPath = String(trimmed.dropFirst(7)).trimmingCharacters(in: .whitespacesAndNewlines)
                    let cleanPath = rawPath.replacingOccurrences(of: "\\", with: "/")
                    let candidate = baseDir.appendingPathComponent(cleanPath)
                    if FileManager.default.fileExists(atPath: candidate.path) {
                        materials[idx].textureURL = candidate
                    }
                }
            }
        }
    }

    // MARK: - Collada DAE Reader (Native XML Collada + SceneKit Fallback)

    private static func loadDAE(
        _ url: URL,
        fileInfo: SKPFileInfo,
        progress: (@Sendable (SKPReader.Progress) -> Void)?,
        isCancelled: @Sendable () -> Bool
    ) throws -> SKPModel {
        let start = Date()
        progress?(SKPReader.Progress(
            phase: L("Lecture du modèle Collada (.dae)…", "Reading Collada (.dae) model…"),
            faces: 0,
            fraction: 0.12,
            currentItem: url.lastPathComponent
        ))

        guard FileManager.default.isReadableFile(atPath: url.path),
              let data = try? Data(contentsOf: url, options: .mappedIfSafe)
        else {
            throw SKPError.unreadable(url)
        }
        if isCancelled() { throw SKPError.cancelled }

        let dom = ColladaXMLParser.parse(data: data, baseDir: url.deletingLastPathComponent(), progress: progress, isCancelled: isCancelled)
        if isCancelled() { throw SKPError.cancelled }
        if !dom.root.meshes.isEmpty || !dom.root.edges.isEmpty || !dom.root.children.isEmpty {
            return dom.buildSKPModel(fileInfo: fileInfo, loadSeconds: Date().timeIntervalSince(start))
        }

        // Fallback to SceneKit for binary/compressed .dae files
        if let scnModel = try? loadDAEWithSceneKit(url, fileInfo: fileInfo, start: start, progress: progress, isCancelled: isCancelled),
           scnModel.stats.triangles > 0 || scnModel.stats.edges > 0 {
            return scnModel
        }

        throw SKPError.unreadable(url)
    }

    /// Native Collada 1.4 / 1.5 XML parser handling `<library_images>`, `<library_effects>`, `<library_materials>`,
    /// `<library_geometries>`, `<library_nodes>`, and `<library_visual_scenes>`.
    private final class ColladaXMLParser: NSObject, XMLParserDelegate {
        struct InputBinding {
            var semantic: String
            var sourceID: String
            var offset: Int
        }

        enum PrimitiveKind {
            case triangles
            case polylist
            case polygons
            case lines
            case linestrips
        }

        struct PrimitiveBatch {
            var kind: PrimitiveKind
            var materialSymbol: String?
            var inputs: [InputBinding] = []
            var vcounts: [Int] = []
            var pValues: [Int] = []
            var polygonP: [[Int]] = []
        }

        struct GeometryData {
            var id: String
            var name: String
            var floatSources: [String: (values: [Float], stride: Int)] = [:]
            var verticesPositionSource: [String: String] = [:] // vertices id -> position source id
            var primitives: [PrimitiveBatch] = []
        }

        struct InstanceGeom {
            var geometryID: String
            var materialMap: [String: String] // symbol -> materialID
        }

        final class SceneNode {
            var id: String
            var name: String
            var transform: simd_float4x4 = matrix_identity_float4x4
            var instanceGeometries: [InstanceGeom] = []
            var instanceNodes: [String] = []
            var children: [SceneNode] = []
            init(id: String, name: String) {
                self.id = id
                self.name = name
            }
        }

        struct EffectData {
            var color: SIMD4<Float> = SIMD4<Float>(0.88, 0.88, 0.90, 1.0)
            var opacity: Float = 1.0
            var imageID: String? = nil
            var paramSurfaceSource: [String: String] = [:] // sampler/surface sid -> imageID
        }

        let baseDir: URL
        var unitMeter: Float = 1.0
        var upAxis: String = "Z_UP"

        var images: [String: String] = [:] // imageID -> path
        var effects: [String: EffectData] = [:]
        var materialEffects: [String: (name: String, effectID: String)] = [:] // materialID -> (name, effectID)
        var geometries: [String: GeometryData] = [:]
        var libraryNodes: [String: SceneNode] = [:]
        var visualSceneNodes: [SceneNode] = []

        // Parser state
        private var elementStack: [String] = []
        private var currentText: String = ""
        private var currentImageID: String?
        private var currentEffectID: String?
        private var currentEffect = EffectData()
        private var currentNewParamSid: String?
        private var currentMaterialID: String?
        private var currentMaterialName: String?
        private var currentGeometry: GeometryData?
        private var currentSourceID: String?
        private var currentFloatValues: [Float] = []
        private var currentAccessorStride: Int = 3
        private var currentVerticesID: String?
        private var currentPrimitive: PrimitiveBatch?
        private var nodeStack: [SceneNode] = []
        private var inLibraryNodes = false
        private var inVisualScene = false
        private var currentInstanceGeom: InstanceGeom?
        private var currentTransformKind: String?

        init(baseDir: URL) {
            self.baseDir = baseDir
        }

        static func parse(
            data: Data,
            baseDir: URL,
            progress: (@Sendable (SKPReader.Progress) -> Void)?,
            isCancelled: @Sendable () -> Bool
        ) -> ColladaResult {
            let delegate = ColladaXMLParser(baseDir: baseDir)
            let parser = XMLParser(data: data)
            parser.shouldProcessNamespaces = false
            parser.delegate = delegate
            _ = parser.parse()
            return delegate.assemble(progress: progress, isCancelled: isCancelled)
        }

        private static func cleanID(_ raw: String?) -> String {
            guard let raw else { return "" }
            var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if s.hasPrefix("#") { s.removeFirst() }
            return s
        }

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?,
            attributes attributeDict: [String: String] = [:]
        ) {
            elementStack.append(elementName)
            currentText.removeAll(keepingCapacity: true)

            switch elementName {
            case "unit":
                if let mStr = attributeDict["meter"], let m = Float(mStr), m > 0 {
                    unitMeter = m
                }
            case "image":
                currentImageID = Self.cleanID(attributeDict["id"])
            case "effect":
                currentEffectID = Self.cleanID(attributeDict["id"])
                currentEffect = EffectData()
            case "newparam":
                currentNewParamSid = attributeDict["sid"]
            case "texture":
                if currentEffectID != nil, let tex = attributeDict["texture"] {
                    currentEffect.imageID = tex
                }
            case "material":
                if currentPrimitive == nil {
                    currentMaterialID = Self.cleanID(attributeDict["id"])
                    currentMaterialName = attributeDict["name"] ?? currentMaterialID
                }
            case "instance_effect":
                if let matID = currentMaterialID, let url = attributeDict["url"] {
                    let effID = Self.cleanID(url)
                    materialEffects[matID] = (name: currentMaterialName ?? matID, effectID: effID)
                }
            case "geometry":
                let id = Self.cleanID(attributeDict["id"])
                let name = attributeDict["name"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? id
                currentGeometry = GeometryData(id: id, name: name)
            case "source":
                if currentGeometry != nil {
                    currentSourceID = Self.cleanID(attributeDict["id"])
                    currentFloatValues = []
                    currentAccessorStride = 3
                }
            case "accessor":
                if let sStr = attributeDict["stride"], let s = Int(sStr), s > 0 {
                    currentAccessorStride = s
                }
            case "vertices":
                if currentGeometry != nil {
                    currentVerticesID = Self.cleanID(attributeDict["id"])
                }
            case "input":
                let semantic = attributeDict["semantic"] ?? ""
                let source = Self.cleanID(attributeDict["source"])
                let offset = attributeDict["offset"].flatMap(Int.init) ?? 0
                if let vID = currentVerticesID, semantic == "POSITION" {
                    currentGeometry?.verticesPositionSource[vID] = source
                } else if currentPrimitive != nil {
                    currentPrimitive?.inputs.append(InputBinding(semantic: semantic, sourceID: source, offset: offset))
                }
            case "triangles":
                currentPrimitive = PrimitiveBatch(kind: .triangles, materialSymbol: attributeDict["material"])
            case "polylist":
                currentPrimitive = PrimitiveBatch(kind: .polylist, materialSymbol: attributeDict["material"])
            case "polygons":
                currentPrimitive = PrimitiveBatch(kind: .polygons, materialSymbol: attributeDict["material"])
            case "lines":
                currentPrimitive = PrimitiveBatch(kind: .lines, materialSymbol: attributeDict["material"])
            case "linestrips":
                currentPrimitive = PrimitiveBatch(kind: .linestrips, materialSymbol: attributeDict["material"])
            case "library_nodes":
                inLibraryNodes = true
            case "library_visual_scenes":
                inVisualScene = true
            case "node":
                let id = Self.cleanID(attributeDict["id"])
                let name = attributeDict["name"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? id
                nodeStack.append(SceneNode(id: id, name: name))
            case "matrix", "translate", "rotate", "scale":
                if !nodeStack.isEmpty {
                    currentTransformKind = elementName
                }
            case "instance_geometry":
                if !nodeStack.isEmpty, let url = attributeDict["url"] {
                    currentInstanceGeom = InstanceGeom(geometryID: Self.cleanID(url), materialMap: [:])
                }
            case "instance_material":
                if currentInstanceGeom != nil,
                   let symbol = attributeDict["symbol"],
                   let target = attributeDict["target"] {
                    currentInstanceGeom?.materialMap[symbol] = Self.cleanID(target)
                }
            case "instance_node":
                if let top = nodeStack.last, let url = attributeDict["url"] {
                    top.instanceNodes.append(Self.cleanID(url))
                }
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            currentText.append(string)
        }

        func parser(
            _ parser: XMLParser,
            didEndElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?
        ) {
            let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)

            switch elementName {
            case "up_axis":
                if !text.isEmpty { upAxis = text.uppercased() }
            case "init_from":
                if let imgID = currentImageID, !text.isEmpty {
                    images[imgID] = text
                } else if let sid = currentNewParamSid, !text.isEmpty {
                    currentEffect.paramSurfaceSource[sid] = text
                }
            case "source":
                if let sid = currentNewParamSid, currentGeometry == nil, !text.isEmpty {
                    currentEffect.paramSurfaceSource[sid] = text
                } else if let sID = currentSourceID, currentGeometry != nil {
                    currentGeometry?.floatSources[sID] = (currentFloatValues, max(currentAccessorStride, 1))
                    currentSourceID = nil
                    currentFloatValues = []
                }
            case "image":
                currentImageID = nil
            case "newparam":
                currentNewParamSid = nil
            case "color":
                if currentEffectID != nil, elementStack.dropLast().last == "diffuse" {
                    let vals = Self.parseFloats(text)
                    if vals.count >= 3 {
                        let a = vals.count >= 4 ? vals[3] : 1.0
                        currentEffect.color = SIMD4<Float>(vals[0], vals[1], vals[2], a)
                    }
                }
            case "float":
                if currentEffectID != nil, elementStack.dropLast().last == "transparency", let val = Float(text) {
                    // Collada 1.4 transparency can be 1.0 = opaque (SketchUp/RGB_ZERO) or 0.0 = transparent depending on opaque mode;
                    // values strictly between 0.01 and 0.99 indicate translucency.
                    if val > 0.01 && val < 0.99 {
                        currentEffect.opacity = val
                    }
                }
            case "effect":
                if let effID = currentEffectID {
                    if let ref = currentEffect.imageID {
                        var resolved = ref
                        for _ in 0..<3 {
                            if let next = currentEffect.paramSurfaceSource[resolved] {
                                resolved = next
                            } else {
                                break
                            }
                        }
                        currentEffect.imageID = resolved
                    }
                    effects[effID] = currentEffect
                    currentEffectID = nil
                }
            case "material":
                if currentPrimitive == nil {
                    currentMaterialID = nil
                    currentMaterialName = nil
                }
            case "float_array":
                if currentGeometry != nil, currentSourceID != nil {
                    currentFloatValues = Self.parseFloats(text)
                }
            case "vertices":
                currentVerticesID = nil
            case "vcount":
                if currentPrimitive != nil {
                    currentPrimitive?.vcounts = Self.parseInts(text)
                }
            case "p":
                if var prim = currentPrimitive {
                    let ints = Self.parseInts(text)
                    if prim.kind == .polygons {
                        prim.polygonP.append(ints)
                    } else {
                        prim.pValues.append(contentsOf: ints)
                    }
                    currentPrimitive = prim
                }
            case "triangles", "polylist", "polygons", "lines", "linestrips":
                if let prim = currentPrimitive {
                    currentGeometry?.primitives.append(prim)
                    currentPrimitive = nil
                }
            case "geometry":
                if let geom = currentGeometry {
                    geometries[geom.id] = geom
                    currentGeometry = nil
                }
            case "instance_geometry":
                if let inst = currentInstanceGeom, let top = nodeStack.last {
                    top.instanceGeometries.append(inst)
                    currentInstanceGeom = nil
                }
            case "matrix":
                if let top = nodeStack.last {
                    let vals = Self.parseFloats(text)
                    if vals.count >= 16 {
                        // Collada <matrix> is row-major: row 0 is vals[0..3], row 1 is vals[4..7], etc.
                        let m = simd_float4x4(rows: [
                            SIMD4<Float>(vals[0], vals[1], vals[2], vals[3]),
                            SIMD4<Float>(vals[4], vals[5], vals[6], vals[7]),
                            SIMD4<Float>(vals[8], vals[9], vals[10], vals[11]),
                            SIMD4<Float>(vals[12], vals[13], vals[14], vals[15]),
                        ])
                        top.transform = simd_mul(top.transform, m)
                    }
                }
                currentTransformKind = nil
            case "translate":
                if let top = nodeStack.last {
                    let vals = Self.parseFloats(text)
                    if vals.count >= 3 {
                        var m = matrix_identity_float4x4
                        m.columns.3 = SIMD4<Float>(vals[0], vals[1], vals[2], 1.0)
                        top.transform = simd_mul(top.transform, m)
                    }
                }
                currentTransformKind = nil
            case "scale":
                if let top = nodeStack.last {
                    let vals = Self.parseFloats(text)
                    if vals.count >= 3 {
                        let m = simd_diagonal_matrix(SIMD4<Float>(vals[0], vals[1], vals[2], 1.0))
                        top.transform = simd_mul(top.transform, m)
                    }
                }
                currentTransformKind = nil
            case "rotate":
                if let top = nodeStack.last {
                    let vals = Self.parseFloats(text)
                    if vals.count >= 4 {
                        let axis = simd_normalize(SIMD3<Float>(vals[0], vals[1], vals[2]))
                        if axis.x.isFinite && axis.y.isFinite && axis.z.isFinite {
                            let rad = vals[3] * .pi / 180.0
                            let q = simd_quatf(angle: rad, axis: axis)
                            let m = simd_float4x4(q)
                            top.transform = simd_mul(top.transform, m)
                        }
                    }
                }
                currentTransformKind = nil
            case "node":
                if let finished = nodeStack.popLast() {
                    if let parent = nodeStack.last {
                        parent.children.append(finished)
                    } else if inLibraryNodes {
                        if !finished.id.isEmpty {
                            libraryNodes[finished.id] = finished
                        }
                    } else if inVisualScene {
                        visualSceneNodes.append(finished)
                    }
                }
            case "library_nodes":
                inLibraryNodes = false
            case "library_visual_scenes":
                inVisualScene = false
            default:
                break
            }

            _ = elementStack.popLast()
            currentText.removeAll(keepingCapacity: true)
        }

        private static func parseFloats(_ text: String) -> [Float] {
            var out: [Float] = []
            for tok in text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\r" || $0 == "\t" }) {
                if let v = Float(tok) { out.append(v) }
            }
            return out
        }

        private static func parseInts(_ text: String) -> [Int] {
            var out: [Int] = []
            for tok in text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\r" || $0 == "\t" }) {
                if let v = Int(tok) { out.append(v) }
            }
            return out
        }

        struct ColladaResult {
            var root: SKPModel.Definition
            var materials: [SKPModel.Material]
            var layers: [SKPModel.Layer]
            var boundsMin: SIMD3<Float>
            var boundsMax: SIMD3<Float>
            var totalFaces: Int
            var totalTriangles: Int
            var totalEdges: Int

            func buildSKPModel(fileInfo: SKPFileInfo, loadSeconds: Double) -> SKPModel {
                let bMin = boundsMin.x <= boundsMax.x ? boundsMin : .zero
                let bMax = boundsMin.x <= boundsMax.x ? boundsMax : .zero
                let stats = SKPModel.Stats(
                    faces: totalFaces,
                    triangles: totalTriangles,
                    edges: totalEdges,
                    instances: 0,
                    definitions: 0,
                    loadSeconds: loadSeconds
                )
                return SKPModel(
                    root: root,
                    definitions: [],
                    materials: materials,
                    layers: layers,
                    scenes: [],
                    camera: nil,
                    boundsMin: bMin,
                    boundsMax: bMax,
                    stats: stats,
                    fileInfo: fileInfo
                )
            }
        }

        private func assemble(
            progress: (@Sendable (SKPReader.Progress) -> Void)?,
            isCancelled: @Sendable () -> Bool
        ) -> ColladaResult {
            var layers: [SKPModel.Layer] = [SKPModel.Layer(name: "Layer0", isVisible: true)]
            var layerByName: [String: Int] = ["Layer0": 0]
            var materials: [SKPModel.Material] = []
            var materialByID: [String: Int] = [:]

            func ensureLayer(_ rawName: String) -> Int {
                let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
                let name = trimmed.isEmpty ? "Layer0" : trimmed
                if let existing = layerByName[name] { return existing }
                let idx = layers.count
                layers.append(SKPModel.Layer(name: name, isVisible: true))
                layerByName[name] = idx
                return idx
            }

            func resolveMaterial(_ matID: String?) -> Int? {
                guard let matID, !matID.isEmpty else { return nil }
                if let existing = materialByID[matID] { return existing }
                let matInfo = materialEffects[matID]
                let eff = matInfo.flatMap { effects[$0.effectID] } ?? EffectData()
                var texURL: URL? = nil
                if let imgID = eff.imageID, let relPath = images[imgID] {
                    let decoded = relPath.removingPercentEncoding ?? relPath
                    let cleanPath = decoded.replacingOccurrences(of: "file://", with: "").replacingOccurrences(of: "\\", with: "/")
                    let candidate = cleanPath.hasPrefix("/")
                        ? URL(fileURLWithPath: cleanPath)
                        : baseDir.appendingPathComponent(cleanPath)
                    if FileManager.default.fileExists(atPath: candidate.path) {
                        texURL = candidate
                    }
                }
                let idx = materials.count
                materials.append(SKPModel.Material(
                    name: matInfo?.name ?? matID,
                    color: SIMD4<Float>(eff.color.x, eff.color.y, eff.color.z, eff.opacity),
                    opacity: eff.opacity,
                    isTransparent: eff.opacity < 0.999,
                    textureURL: texURL
                ))
                materialByID[matID] = idx
                return idx
            }

            // Axis conversion matrix to SKPModel Z-up + unit scale to metres
            let scale = unitMeter
            let isYUp = (upAxis == "Y_UP")
            @inline(__always)
            func toModelPoint(_ p: SIMD3<Float>, transform: simd_float4x4) -> SIMD3<Float> {
                let wp4 = transform * SIMD4<Float>(p.x, p.y, p.z, 1.0)
                let wp = SIMD3<Float>(wp4.x, wp4.y, wp4.z) * scale
                return isYUp ? SIMD3<Float>(wp.x, -wp.z, wp.y) : wp
            }

            @inline(__always)
            func toModelNormal(_ n: SIMD3<Float>, normalMatrix: simd_float3x3) -> SIMD3<Float> {
                let wn = normalMatrix * n
                let mapped = isYUp ? SIMD3<Float>(wn.x, -wn.z, wn.y) : wn
                let len = simd_length(mapped)
                return len > 1e-6 ? (mapped / len) : SIMD3<Float>(0, 0, 1)
            }

            var meshes: [SKPModel.Mesh] = []
            var edgesByLayer: [Int: [SIMD3<Float>]] = [:]
            var boundsMin = SIMD3<Float>(repeating: .infinity)
            var boundsMax = SIMD3<Float>(repeating: -.infinity)
            var totalFaces = 0
            var totalTriangles = 0
            var totalEdges = 0

            func instantiateGeometry(
                _ geom: GeometryData,
                transform: simd_float4x4,
                layerIdx: Int,
                materialMap: [String: String]
            ) {
                let linear = simd_float3x3(
                    SIMD3(transform.columns.0.x, transform.columns.0.y, transform.columns.0.z),
                    SIMD3(transform.columns.1.x, transform.columns.1.y, transform.columns.1.z),
                    SIMD3(transform.columns.2.x, transform.columns.2.y, transform.columns.2.z)
                )
                let normalMatrix = linear.inverse.transpose

                for prim in geom.primitives {
                    let stride = max((prim.inputs.map(\.offset).max() ?? 0) + 1, 1)
                    let vertexInput = prim.inputs.first { $0.semantic == "VERTEX" } ?? prim.inputs.first { $0.semantic == "POSITION" }
                    guard let vInput = vertexInput else { continue }
                    let posSourceID = geom.verticesPositionSource[vInput.sourceID] ?? vInput.sourceID
                    guard let posSrc = geom.floatSources[posSourceID], posSrc.stride >= 3 else { continue }
                    let posCount = posSrc.values.count / posSrc.stride

                    let normInput = prim.inputs.first { $0.semantic == "NORMAL" }
                    let normSrc = normInput.flatMap { geom.floatSources[$0.sourceID] }
                    let uvInput = prim.inputs.first { $0.semantic == "TEXCOORD" }
                    let uvSrc = uvInput.flatMap { geom.floatSources[$0.sourceID] }

                    @inline(__always)
                    func readPosition(_ idx: Int) -> SIMD3<Float>? {
                        guard idx >= 0 && idx < posCount else { return nil }
                        let base = idx * posSrc.stride
                        let raw = SIMD3<Float>(posSrc.values[base], posSrc.values[base + 1], posSrc.values[base + 2])
                        let p = toModelPoint(raw, transform: transform)
                        boundsMin = simd_min(boundsMin, p)
                        boundsMax = simd_max(boundsMax, p)
                        return p
                    }

                    @inline(__always)
                    func readNormal(_ idx: Int) -> SIMD3<Float>? {
                        guard let normSrc, normSrc.stride >= 3 else { return nil }
                        let count = normSrc.values.count / normSrc.stride
                        guard idx >= 0 && idx < count else { return nil }
                        let base = idx * normSrc.stride
                        let raw = SIMD3<Float>(normSrc.values[base], normSrc.values[base + 1], normSrc.values[base + 2])
                        return toModelNormal(raw, normalMatrix: normalMatrix)
                    }

                    @inline(__always)
                    func readUV(_ idx: Int) -> SIMD2<Float>? {
                        guard let uvSrc, uvSrc.stride >= 2 else { return nil }
                        let count = uvSrc.values.count / uvSrc.stride
                        guard idx >= 0 && idx < count else { return nil }
                        let base = idx * uvSrc.stride
                        return SIMD2<Float>(uvSrc.values[base], uvSrc.values[base + 1])
                    }

                    let matID = prim.materialSymbol.map { materialMap[$0] ?? $0 }
                    let matIdx = resolveMaterial(matID)

                    switch prim.kind {
                    case .lines:
                        let tupleCount = prim.pValues.count / stride
                        var segs: [SIMD3<Float>] = []
                        var t = 0
                        while t + 1 < tupleCount {
                            let v0 = prim.pValues[t * stride + vInput.offset]
                            let v1 = prim.pValues[(t + 1) * stride + vInput.offset]
                            if let p0 = readPosition(v0), let p1 = readPosition(v1) {
                                segs.append(p0)
                                segs.append(p1)
                                totalEdges += 1
                            }
                            t += 2
                        }
                        if !segs.isEmpty {
                            edgesByLayer[layerIdx, default: []].append(contentsOf: segs)
                        }

                    case .linestrips:
                        let tupleCount = prim.pValues.count / stride
                        if tupleCount >= 2 {
                            var segs: [SIMD3<Float>] = []
                            for t in 0..<(tupleCount - 1) {
                                let v0 = prim.pValues[t * stride + vInput.offset]
                                let v1 = prim.pValues[(t + 1) * stride + vInput.offset]
                                if let p0 = readPosition(v0), let p1 = readPosition(v1) {
                                    segs.append(p0)
                                    segs.append(p1)
                                    totalEdges += 1
                                }
                            }
                            if !segs.isEmpty {
                                edgesByLayer[layerIdx, default: []].append(contentsOf: segs)
                            }
                        }

                    case .triangles, .polylist, .polygons:
                        var outPos: [SIMD3<Float>] = []
                        var outNorm: [SIMD3<Float>] = []
                        var outUV: [SIMD2<Float>] = []
                        var hasUV = false
                        var outIndices: [UInt32] = []

                        func emitPolygon(tupleSlice: ArraySlice<Int>) {
                            let nVerts = tupleSlice.count / stride
                            guard nVerts >= 3 else { return }
                            let baseIdx = UInt32(outPos.count)
                            var polyPts: [SIMD3<Float>] = []
                            var polyNorms: [SIMD3<Float>?] = []
                            var polyUVs: [SIMD2<Float>?] = []
                            polyPts.reserveCapacity(nVerts)
                            polyNorms.reserveCapacity(nVerts)
                            polyUVs.reserveCapacity(nVerts)

                            for k in 0..<nVerts {
                                let base = tupleSlice.startIndex + k * stride
                                let vIdx = tupleSlice[base + vInput.offset]
                                guard let p = readPosition(vIdx) else { return }
                                polyPts.append(p)
                                if let nOff = normInput?.offset {
                                    polyNorms.append(readNormal(tupleSlice[base + nOff]))
                                } else {
                                    polyNorms.append(nil)
                                }
                                if let uvOff = uvInput?.offset {
                                    polyUVs.append(readUV(tupleSlice[base + uvOff]))
                                } else {
                                    polyUVs.append(nil)
                                }
                            }

                            let e1 = polyPts[1] - polyPts[0]
                            let e2 = polyPts[2] - polyPts[0]
                            let cross = simd_cross(e1, e2)
                            let len = simd_length(cross)
                            let flatN = len > 1e-7 ? (cross / len) : SIMD3<Float>(0, 0, 1)

                            for k in 0..<nVerts {
                                outPos.append(polyPts[k])
                                outNorm.append(polyNorms[k] ?? flatN)
                                if let uv = polyUVs[k] {
                                    outUV.append(uv)
                                    hasUV = true
                                } else {
                                    outUV.append(.zero)
                                }
                            }
                            for k in 1..<(nVerts - 1) {
                                outIndices.append(baseIdx)
                                outIndices.append(baseIdx + UInt32(k))
                                outIndices.append(baseIdx + UInt32(k + 1))
                                totalTriangles += 1
                            }
                            totalFaces += 1
                        }

                        if prim.kind == .triangles {
                            let step = 3 * stride
                            var offset = 0
                            while offset + step <= prim.pValues.count {
                                emitPolygon(tupleSlice: prim.pValues[offset..<(offset + step)])
                                offset += step
                            }
                        } else if prim.kind == .polylist {
                            var offset = 0
                            for vc in prim.vcounts where vc >= 3 {
                                let step = vc * stride
                                guard offset + step <= prim.pValues.count else { break }
                                emitPolygon(tupleSlice: prim.pValues[offset..<(offset + step)])
                                offset += step
                            }
                        } else if prim.kind == .polygons {
                            for poly in prim.polygonP {
                                emitPolygon(tupleSlice: poly[0..<poly.count])
                            }
                        }

                        if !outIndices.isEmpty {
                            meshes.append(SKPModel.Mesh(
                                material: matIdx,
                                layer: layerIdx,
                                positions: outPos,
                                normals: outNorm,
                                uvs: hasUV ? outUV : nil,
                                indices: outIndices
                            ))
                            if edgesByLayer[layerIdx, default: []].count < 80_000 {
                                let feat = extractFeatureEdges(positions: outPos, indices: outIndices)
                                edgesByLayer[layerIdx, default: []].append(contentsOf: feat)
                                totalEdges += feat.count / 2
                            }
                        }
                    }
                }
            }

            func traverse(
                _ node: SceneNode,
                parentTransform: simd_float4x4,
                inheritedLayerName: String?,
                depth: Int
            ) {
                if depth > 48 || isCancelled() { return }
                let worldTransform = simd_mul(parentTransform, node.transform)
                let cleanName = node.name.trimmingCharacters(in: .whitespacesAndNewlines)
                let effectiveLayerName: String?
                if !cleanName.isEmpty && cleanName != "VisualSceneNode" && cleanName != "SketchUp" && cleanName != "Scene" {
                    effectiveLayerName = inheritedLayerName ?? cleanName
                } else {
                    effectiveLayerName = inheritedLayerName
                }
                let layerIdx = ensureLayer(effectiveLayerName ?? (cleanName.isEmpty ? "Layer0" : cleanName))

                for inst in node.instanceGeometries {
                    if let geom = geometries[inst.geometryID] {
                        let geomLayer = (effectiveLayerName == nil && !geom.name.isEmpty) ? ensureLayer(geom.name) : layerIdx
                        instantiateGeometry(geom, transform: worldTransform, layerIdx: geomLayer, materialMap: inst.materialMap)
                    }
                }
                for instNodeID in node.instanceNodes {
                    if let target = libraryNodes[instNodeID] {
                        traverse(target, parentTransform: worldTransform, inheritedLayerName: effectiveLayerName, depth: depth + 1)
                    }
                }
                for child in node.children {
                    traverse(child, parentTransform: worldTransform, inheritedLayerName: effectiveLayerName, depth: depth + 1)
                }
            }

            if !visualSceneNodes.isEmpty {
                for top in visualSceneNodes {
                    traverse(top, parentTransform: matrix_identity_float4x4, inheritedLayerName: nil, depth: 0)
                }
            } else {
                for (_, geom) in geometries {
                    let layerIdx = ensureLayer(geom.name.isEmpty ? "Layer0" : geom.name)
                    instantiateGeometry(geom, transform: matrix_identity_float4x4, layerIdx: layerIdx, materialMap: [:])
                }
            }

            var edgeSets: [SKPModel.EdgeSet] = []
            for (layerIdx, segs) in edgesByLayer where !segs.isEmpty {
                edgeSets.append(SKPModel.EdgeSet(layer: layerIdx, material: nil, positions: segs))
            }

            let root = SKPModel.Definition(name: "", meshes: meshes, edges: edgeSets, children: [])
            return ColladaResult(
                root: root,
                materials: materials,
                layers: layers,
                boundsMin: boundsMin,
                boundsMax: boundsMax,
                totalFaces: totalFaces,
                totalTriangles: totalTriangles,
                totalEdges: totalEdges
            )
        }
    }

    private static func loadDAEWithSceneKit(
        _ url: URL,
        fileInfo: SKPFileInfo,
        start: Date,
        progress: (@Sendable (SKPReader.Progress) -> Void)?,
        isCancelled: @Sendable () -> Bool
    ) throws -> SKPModel {
        let options: [SCNSceneSource.LoadingOption: Any] = [
            .convertToYUp: true,
            .convertUnitsToMeters: true,
            .checkConsistency: false,
        ]
        guard let scnScene = try? SCNScene(url: url, options: options) else {
            throw SKPError.unreadable(url)
        }
        if isCancelled() { throw SKPError.cancelled }

        var layers: [SKPModel.Layer] = [SKPModel.Layer(name: "Layer0", isVisible: true)]
        var layerIndexByName: [String: Int] = ["Layer0": 0]
        var materials: [SKPModel.Material] = []
        var materialByObjectID: [ObjectIdentifier: Int] = [:]
        var tempTextureDir: URL? = nil

        func ensureLayer(_ rawName: String) -> Int {
            let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            let name = trimmed.isEmpty ? "Layer0" : trimmed
            if let existing = layerIndexByName[name] { return existing }
            let idx = layers.count
            layers.append(SKPModel.Layer(name: name, isVisible: true))
            layerIndexByName[name] = idx
            return idx
        }

        func convertMaterial(_ scnMat: SCNMaterial) -> Int {
            let id = ObjectIdentifier(scnMat)
            if let existing = materialByObjectID[id] { return existing }
            let name = scnMat.name ?? "Material_\(materials.count)"
            let opacity = Float(scnMat.transparency)
            var color = SIMD4<Float>(0.88, 0.88, 0.90, opacity)
            var textureURL: URL? = nil

            if let contents = scnMat.diffuse.contents {
                if let nsColor = contents as? NSColor,
                   let srgb = nsColor.usingColorSpace(.sRGB) {
                    color = SIMD4<Float>(
                        Float(srgb.redComponent),
                        Float(srgb.greenComponent),
                        Float(srgb.blueComponent),
                        Float(srgb.alphaComponent) * opacity
                    )
                } else if let texURL = contents as? URL, FileManager.default.fileExists(atPath: texURL.path) {
                    textureURL = texURL
                } else if let texPath = contents as? String {
                    let candidate = texPath.hasPrefix("/")
                        ? URL(fileURLWithPath: texPath)
                        : url.deletingLastPathComponent().appendingPathComponent(texPath)
                    if FileManager.default.fileExists(atPath: candidate.path) {
                        textureURL = candidate
                    }
                } else if let image = contents as? NSImage,
                          let tiff = image.tiffRepresentation,
                          let rep = NSBitmapImageRep(data: tiff),
                          let png = rep.representation(using: .png, properties: [:]) {
                    let dir = tempTextureDir ?? {
                        let d = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                            .appendingPathComponent("SimpleSKP", isDirectory: true)
                            .appendingPathComponent(UUID().uuidString, isDirectory: true)
                        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
                        tempTextureDir = d
                        return d
                    }()
                    let fileURL = dir.appendingPathComponent("tex_\(materials.count).png")
                    if (try? png.write(to: fileURL)) != nil {
                        textureURL = fileURL
                    }
                }
            }

            let idx = materials.count
            materials.append(SKPModel.Material(
                name: name,
                color: color,
                opacity: color.w,
                isTransparent: color.w < 0.999,
                textureURL: textureURL,
                textureScale: SIMD2<Float>(1, 1)
            ))
            materialByObjectID[id] = idx
            return idx
        }

        @inline(__always)
        func scnToSKP(_ p: SIMD3<Float>) -> SIMD3<Float> {
            SIMD3<Float>(p.x, -p.z, p.y)
        }

        var meshes: [SKPModel.Mesh] = []
        var edgesByLayer: [Int: [SIMD3<Float>]] = [:]
        var boundsMin = SIMD3<Float>(repeating: .infinity)
        var boundsMax = SIMD3<Float>(repeating: -.infinity)
        var totalTriangles = 0
        var totalEdges = 0
        var camera: SKPModel.Camera? = nil

        func walk(_ node: SCNNode, inheritedLayerName: String?) {
            if isCancelled() { return }
            guard !node.isHidden, node.opacity > 0.01 else { return }

            let nodeName = node.name?.trimmingCharacters(in: .whitespacesAndNewlines)
            let effectiveLayerName: String?
            if let nodeName, !nodeName.isEmpty,
               !nodeName.hasPrefix("Untitled"),
               nodeName != "VisualSceneNode",
               nodeName != "SketchUp" {
                effectiveLayerName = inheritedLayerName ?? nodeName
            } else {
                effectiveLayerName = inheritedLayerName
            }
            let layerIdx = ensureLayer(effectiveLayerName ?? nodeName ?? "Layer0")

            if camera == nil, let scnCam = node.camera {
                let worldTransform = node.simdWorldTransform
                let posSCN = SIMD3<Float>(worldTransform.columns.3.x, worldTransform.columns.3.y, worldTransform.columns.3.z)
                let fwdSCN = -simd_normalize(SIMD3<Float>(worldTransform.columns.2.x, worldTransform.columns.2.y, worldTransform.columns.2.z))
                let upSCN = simd_normalize(SIMD3<Float>(worldTransform.columns.1.x, worldTransform.columns.1.y, worldTransform.columns.1.z))
                let pos = scnToSKP(posSCN)
                let fwd = scnToSKP(fwdSCN)
                let up = scnToSKP(upSCN)
                let fov = Float(scnCam.fieldOfView > 0 ? scnCam.fieldOfView : 35)
                camera = SKPModel.Camera(
                    position: pos,
                    target: pos + fwd * 10.0,
                    up: up,
                    isPerspective: !scnCam.usesOrthographicProjection,
                    fovDegrees: fov,
                    orthoHeight: Float(max(scnCam.orthographicScale * 2, 1.0))
                )
            }

            if let geom = node.geometry, let vertexSource = geom.sources(for: .vertex).first {
                let worldTransform = node.simdWorldTransform
                let linear = simd_float3x3(
                    SIMD3(worldTransform.columns.0.x, worldTransform.columns.0.y, worldTransform.columns.0.z),
                    SIMD3(worldTransform.columns.1.x, worldTransform.columns.1.y, worldTransform.columns.1.z),
                    SIMD3(worldTransform.columns.2.x, worldTransform.columns.2.y, worldTransform.columns.2.z)
                )
                let normalMatrix = linear.inverse.transpose

                let rawPos = extractFloat3Source(vertexSource)
                let worldPos: [SIMD3<Float>] = rawPos.map { p in
                    let wp = worldTransform * SIMD4<Float>(p.x, p.y, p.z, 1.0)
                    let skpP = scnToSKP(SIMD3<Float>(wp.x, wp.y, wp.z))
                    boundsMin = simd_min(boundsMin, skpP)
                    boundsMax = simd_max(boundsMax, skpP)
                    return skpP
                }
                let rawNormals = geom.sources(for: .normal).first.map(extractFloat3Source)
                let worldNormals: [SIMD3<Float>]? = rawNormals.map { norms in
                    norms.map { n in
                        let wn = normalMatrix * n
                        let skpN = scnToSKP(wn)
                        let len = simd_length(skpN)
                        return len > 1e-6 ? (skpN / len) : SIMD3<Float>(0, 0, 1)
                    }
                }
                let rawUVs = geom.sources(for: .texcoord).first.map(extractFloat2Source)

                let scnMaterials = geom.materials
                for (elemIdx, element) in geom.elements.enumerated() {
                    switch element.primitiveType {
                    case .triangles, .triangleStrip, .polygon:
                        let triIndices = extractTriangleIndices(element, vertexCount: worldPos.count)
                        guard !triIndices.isEmpty else { continue }
                        let matIdx = !scnMaterials.isEmpty ? convertMaterial(scnMaterials[elemIdx % scnMaterials.count]) : nil
                        let finalNormals = (worldNormals?.count == worldPos.count)
                            ? worldNormals!
                            : computeVertexNormals(positions: worldPos, indices: triIndices)
                        let finalUVs: [SIMD2<Float>]? = (rawUVs?.count == worldPos.count) ? rawUVs : nil
                        meshes.append(SKPModel.Mesh(
                            material: matIdx,
                            layer: layerIdx,
                            positions: worldPos,
                            normals: finalNormals,
                            uvs: finalUVs,
                            indices: triIndices
                        ))
                        totalTriangles += triIndices.count / 3
                        if edgesByLayer[layerIdx, default: []].count < 80_000 {
                            let featureSegs = extractFeatureEdges(positions: worldPos, indices: triIndices)
                            edgesByLayer[layerIdx, default: []].append(contentsOf: featureSegs)
                            totalEdges += featureSegs.count / 2
                        }
                    case .line:
                        let lineSegs = extractLineSegments(element, positions: worldPos)
                        if !lineSegs.isEmpty {
                            edgesByLayer[layerIdx, default: []].append(contentsOf: lineSegs)
                            totalEdges += lineSegs.count / 2
                        }
                    default:
                        break
                    }
                }
            }

            for child in node.childNodes {
                walk(child, inheritedLayerName: effectiveLayerName)
            }
        }

        for topChild in scnScene.rootNode.childNodes {
            walk(topChild, inheritedLayerName: nil)
        }

        var edgeSets: [SKPModel.EdgeSet] = []
        var finalEdgeCount = 0
        for (layerIdx, segs) in edgesByLayer where !segs.isEmpty {
            edgeSets.append(SKPModel.EdgeSet(layer: layerIdx, material: nil, positions: segs))
            finalEdgeCount += segs.count / 2
        }

        if !(boundsMin.x <= boundsMax.x) {
            boundsMin = .zero
            boundsMax = .zero
        }

        let root = SKPModel.Definition(name: "", meshes: meshes, edges: edgeSets, children: [])
        let elapsed = Date().timeIntervalSince(start)
        let stats = SKPModel.Stats(
            faces: totalTriangles,
            triangles: totalTriangles,
            edges: finalEdgeCount,
            instances: 0,
            definitions: 0,
            loadSeconds: elapsed
        )
        return SKPModel(
            root: root,
            definitions: [],
            materials: materials,
            layers: layers,
            scenes: [],
            camera: camera,
            boundsMin: boundsMin,
            boundsMax: boundsMax,
            stats: stats,
            fileInfo: fileInfo,
            textureDirectory: tempTextureDir
        )
    }

    // MARK: - Geometry Source Extraction Helpers

    private static func extractFloat3Source(_ source: SCNGeometrySource) -> [SIMD3<Float>] {
        let count = source.vectorCount
        guard count > 0, source.componentsPerVector >= 3 else { return [] }
        var result: [SIMD3<Float>] = []
        result.reserveCapacity(count)
        let stride = source.dataStride
        let offset = source.dataOffset
        let bpc = source.bytesPerComponent
        source.data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            for i in 0..<count {
                let ptr = base.advanced(by: offset + i * stride)
                if bpc == 4 && source.usesFloatComponents {
                    let f = ptr.assumingMemoryBound(to: Float.self)
                    result.append(SIMD3<Float>(f[0], f[1], f[2]))
                } else if bpc == 8 && source.usesFloatComponents {
                    let d = ptr.assumingMemoryBound(to: Double.self)
                    result.append(SIMD3<Float>(Float(d[0]), Float(d[1]), Float(d[2])))
                }
            }
        }
        return result
    }

    private static func extractFloat2Source(_ source: SCNGeometrySource) -> [SIMD2<Float>] {
        let count = source.vectorCount
        guard count > 0, source.componentsPerVector >= 2 else { return [] }
        var result: [SIMD2<Float>] = []
        result.reserveCapacity(count)
        let stride = source.dataStride
        let offset = source.dataOffset
        let bpc = source.bytesPerComponent
        source.data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            for i in 0..<count {
                let ptr = base.advanced(by: offset + i * stride)
                if bpc == 4 && source.usesFloatComponents {
                    let f = ptr.assumingMemoryBound(to: Float.self)
                    result.append(SIMD2<Float>(f[0], f[1]))
                } else if bpc == 8 && source.usesFloatComponents {
                    let d = ptr.assumingMemoryBound(to: Double.self)
                    result.append(SIMD2<Float>(Float(d[0]), Float(d[1])))
                }
            }
        }
        return result
    }

    private static func readIndex(from base: UnsafeRawPointer, at index: Int, bytesPerIndex: Int) -> UInt32 {
        switch bytesPerIndex {
        case 1:
            return UInt32(base.advanced(by: index).assumingMemoryBound(to: UInt8.self).pointee)
        case 2:
            return UInt32(base.advanced(by: index * 2).assumingMemoryBound(to: UInt16.self).pointee)
        case 4:
            return base.advanced(by: index * 4).assumingMemoryBound(to: UInt32.self).pointee
        case 8:
            return UInt32(truncatingIfNeeded: base.advanced(by: index * 8).assumingMemoryBound(to: UInt64.self).pointee)
        default:
            return 0
        }
    }

    private static func extractTriangleIndices(_ element: SCNGeometryElement, vertexCount: Int) -> [UInt32] {
        let primCount = element.primitiveCount
        let bpi = element.bytesPerIndex
        guard primCount > 0, bpi > 0 else { return [] }
        let vLimit = UInt32(vertexCount)
        var out: [UInt32] = []

        element.data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            let totalValues = raw.count / bpi
            switch element.primitiveType {
            case .triangles:
                let count = min(primCount * 3, totalValues)
                out.reserveCapacity(count)
                var i = 0
                while i + 2 < count {
                    let i0 = readIndex(from: base, at: i, bytesPerIndex: bpi)
                    let i1 = readIndex(from: base, at: i + 1, bytesPerIndex: bpi)
                    let i2 = readIndex(from: base, at: i + 2, bytesPerIndex: bpi)
                    if i0 < vLimit && i1 < vLimit && i2 < vLimit {
                        out.append(i0); out.append(i1); out.append(i2)
                    }
                    i += 3
                }
            case .triangleStrip:
                let count = min(primCount + 2, totalValues)
                guard count >= 3 else { return }
                for i in 0..<(count - 2) {
                    let i0 = readIndex(from: base, at: i, bytesPerIndex: bpi)
                    let i1 = readIndex(from: base, at: i + 1, bytesPerIndex: bpi)
                    let i2 = readIndex(from: base, at: i + 2, bytesPerIndex: bpi)
                    if i0 < vLimit && i1 < vLimit && i2 < vLimit {
                        if i % 2 == 0 {
                            out.append(i0); out.append(i1); out.append(i2)
                        } else {
                            out.append(i1); out.append(i0); out.append(i2)
                        }
                    }
                }
            case .polygon:
                guard totalValues > primCount else { return }
                var cursor = primCount
                for p in 0..<primCount {
                    let n = Int(readIndex(from: base, at: p, bytesPerIndex: bpi))
                    guard n >= 3, cursor + n <= totalValues else {
                        cursor += max(0, n)
                        continue
                    }
                    let i0 = readIndex(from: base, at: cursor, bytesPerIndex: bpi)
                    for k in 1..<(n - 1) {
                        let i1 = readIndex(from: base, at: cursor + k, bytesPerIndex: bpi)
                        let i2 = readIndex(from: base, at: cursor + k + 1, bytesPerIndex: bpi)
                        if i0 < vLimit && i1 < vLimit && i2 < vLimit {
                            out.append(i0); out.append(i1); out.append(i2)
                        }
                    }
                    cursor += n
                }
            default:
                break
            }
        }
        return out
    }

    private static func extractLineSegments(_ element: SCNGeometryElement, positions: [SIMD3<Float>]) -> [SIMD3<Float>] {
        let primCount = element.primitiveCount
        let bpi = element.bytesPerIndex
        guard primCount > 0, bpi > 0 else { return [] }
        let vLimit = UInt32(positions.count)
        var out: [SIMD3<Float>] = []
        element.data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            let count = min(primCount * 2, raw.count / bpi)
            out.reserveCapacity(count)
            var i = 0
            while i + 1 < count {
                let i0 = readIndex(from: base, at: i, bytesPerIndex: bpi)
                let i1 = readIndex(from: base, at: i + 1, bytesPerIndex: bpi)
                if i0 < vLimit && i1 < vLimit {
                    out.append(positions[Int(i0)])
                    out.append(positions[Int(i1)])
                }
                i += 2
            }
        }
        return out
    }

    private static func computeVertexNormals(positions: [SIMD3<Float>], indices: [UInt32]) -> [SIMD3<Float>] {
        var norms = [SIMD3<Float>](repeating: .zero, count: positions.count)
        var i = 0
        while i + 2 < indices.count {
            let i0 = Int(indices[i]), i1 = Int(indices[i + 1]), i2 = Int(indices[i + 2])
            let n = simd_cross(positions[i1] - positions[i0], positions[i2] - positions[i0])
            norms[i0] += n
            norms[i1] += n
            norms[i2] += n
            i += 3
        }
        for idx in norms.indices {
            let len = simd_length(norms[idx])
            norms[idx] = len > 1e-7 ? (norms[idx] / len) : SIMD3<Float>(0, 0, 1)
        }
        return norms
    }

    /// Extracts boundary edges and sharp crease edges (> 24° dihedral angle) from a triangle mesh.
    private static func extractFeatureEdges(positions: [SIMD3<Float>], indices: [UInt32]) -> [SIMD3<Float>] {
        let triCount = indices.count / 3
        guard triCount > 0, triCount <= 60_000 else { return [] }
        var edgeNormals: [EdgeKey: SIMD3<Float>] = [:]
        var sharpEdges: Set<EdgeKey> = []

        var i = 0
        while i + 2 < indices.count {
            let i0 = indices[i], i1 = indices[i + 1], i2 = indices[i + 2]
            let p0 = positions[Int(i0)], p1 = positions[Int(i1)], p2 = positions[Int(i2)]
            let cross = simd_cross(p1 - p0, p2 - p0)
            let len = simd_length(cross)
            let n = len > 1e-7 ? (cross / len) : SIMD3<Float>(0, 0, 1)

            for (u, v) in [(i0, i1), (i1, i2), (i2, i0)] where u != v {
                let key = EdgeKey(u, v)
                if let prevN = edgeNormals.removeValue(forKey: key) {
                    if simd_dot(prevN, n) < 0.9135 {
                        sharpEdges.insert(key)
                    }
                } else if !sharpEdges.contains(key) {
                    edgeNormals[key] = n
                }
            }
            i += 3
        }

        var segments: [SIMD3<Float>] = []
        segments.reserveCapacity((edgeNormals.count + sharpEdges.count) * 2)
        for key in edgeNormals.keys {
            segments.append(positions[Int(key.a)])
            segments.append(positions[Int(key.b)])
        }
        for key in sharpEdges {
            segments.append(positions[Int(key.a)])
            segments.append(positions[Int(key.b)])
        }
        return segments
    }
}
