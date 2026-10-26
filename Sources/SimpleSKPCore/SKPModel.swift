import Foundation
import simd

/// Neutral, render-agnostic description of a SketchUp model: metres, Z up, `Float` everywhere.
/// Produced by `SKPReader`, consumed by `SimpleSKPViewport`. Hidden entities are omitted by the reader.
public struct SKPModel: Sendable {
    public struct Material: Sendable {
        public var name: String
        /// sRGB components 0…1 (bytes / 255, alpha included; `opacity` is the SketchUp opacity, applied by the viewport).
        public var color: SIMD4<Float>
        public var opacity: Float
        /// True when the material uses opacity (< 1) or has a translucent/cutout alpha texture (`SUMaterialIsDrawnTransparent`).
        public var isTransparent: Bool
        /// Texture written to a temporary file by the reader (`SUTextureWriteToFile`), nil for plain colours.
        public var textureURL: URL?
        /// Metres per texture repeat along S and T (SketchUp texture width/height) = 0.0254 / s_scale, 0.0254 / t_scale
        /// (texture.h: s_scale/t_scale are repeats per inch). Divide a nil-material mesh's `uvs` by it for an inherited texture.
        public var textureScale: SIMD2<Float>

        public init(
            name: String,
            color: SIMD4<Float>,
            opacity: Float = 1,
            isTransparent: Bool? = nil,
            textureURL: URL? = nil,
            textureScale: SIMD2<Float> = SIMD2(1, 1)
        ) {
            self.name = name
            self.color = color
            self.opacity = opacity
            self.isTransparent = isTransparent ?? (opacity < 0.999 || color.w < 0.999)
            self.textureURL = textureURL
            self.textureScale = textureScale
        }
    }

    /// A SketchUp layer (« calque », called a tag since SketchUp 2020).
    public struct Layer: Sendable {
        public var name: String
        public var isVisible: Bool
        /// Optional native SketchUp tag folder name (`SULayerGetParentLayerFolder`), if any.
        public var folder: String?
        public init(name: String, isVisible: Bool, folder: String? = nil) {
            self.name = name
            self.isVisible = isVisible
            self.folder = folder
        }
    }

    /// Automatic or folder-based hierarchy grouping of layers that share a common name base.
    public struct LayerGroup: Sendable, Identifiable, Equatable {
        public var id: String
        public var name: String
        public var layerIndices: [Int]
        /// Short display labels for each layer index when shown inside this group (redundant prefix stripped).
        public var memberLabels: [Int: String]
        public var isSingleLayer: Bool { layerIndices.count == 1 }

        public init(id: String, name: String, layerIndices: [Int], memberLabels: [Int: String] = [:]) {
            self.id = id
            self.name = name
            self.layerIndices = layerIndices
            self.memberLabels = memberLabels
        }
    }

    /// One triangle batch: all the faces of a definition that share a material and a layer.
    public struct Mesh: Sendable {
        /// Index into `SKPModel.materials`; nil = SketchUp default material (white front face).
        public var material: Int?
        /// Index into `SKPModel.layers`.
        public var layer: Int
        public var positions: [SIMD3<Float>]
        public var normals: [SIMD3<Float>]
        /// Front-face texture coordinates (already divided by q): texture repeats when `material` is textured; metres when
        /// `material == nil`, to be divided by the inherited material's `textureScale`; nil otherwise.
        public var uvs: [SIMD2<Float>]?
        /// Triangle list, three indices per triangle.
        public var indices: [UInt32]

        public init(material: Int?, layer: Int, positions: [SIMD3<Float>], normals: [SIMD3<Float>], uvs: [SIMD2<Float>]? = nil, indices: [UInt32]) {
            self.material = material; self.layer = layer; self.positions = positions; self.normals = normals; self.uvs = uvs; self.indices = indices
        }
    }

    /// Visible (non-soft) edges of a definition on one layer, as point pairs (segment i = positions[2i], positions[2i+1]).
    public struct EdgeSet: Sendable {
        public var layer: Int
        public var positions: [SIMD3<Float>]
        public init(layer: Int, positions: [SIMD3<Float>]) { self.layer = layer; self.positions = positions }
    }

    /// A placed group or component. Groups get their own, never shared, entry in `definitions`.
    public struct Instance: Sendable {
        /// Index into `SKPModel.definitions`.
        public var definition: Int
        /// Parent-relative transform, translation in metres, `values[15]` already normalised to 1.
        public var transform: simd_float4x4
        public var layer: Int
        public var isGroup: Bool
        /// Material applied to the instance; faces of the definition with `material == nil` inherit it.
        public var material: Int?
        public var name: String

        public init(definition: Int, transform: simd_float4x4, layer: Int, isGroup: Bool, material: Int? = nil, name: String = "") {
            self.definition = definition; self.transform = transform; self.layer = layer; self.isGroup = isGroup; self.material = material; self.name = name
        }
    }

    /// Geometry of a component definition or of a group; the model's top level is `root`.
    public struct Definition: Sendable {
        public var name: String
        public var meshes: [Mesh]
        public var edges: [EdgeSet]
        public var children: [Instance]
        public init(name: String, meshes: [Mesh] = [], edges: [EdgeSet] = [], children: [Instance] = []) {
            self.name = name; self.meshes = meshes; self.edges = edges; self.children = children
        }
    }

    /// Camera in model space (metres, Z up). `fovDegrees` is always the VERTICAL field of view.
    /// The viewport parents its camera node under the Z-up→Y-up root and uses these values verbatim.
    public struct Camera: Sendable {
        public var position: SIMD3<Float>
        public var target: SIMD3<Float>
        public var up: SIMD3<Float>
        public var isPerspective: Bool
        public var fovDegrees: Float
        /// Visible height in metres for a parallel projection.
        public var orthoHeight: Float
        public init(position: SIMD3<Float>, target: SIMD3<Float>, up: SIMD3<Float> = SIMD3(0, 0, 1), isPerspective: Bool = true, fovDegrees: Float = 35, orthoHeight: Float = 10) {
            self.position = position; self.target = target; self.up = up; self.isPerspective = isPerspective; self.fovDegrees = fovDegrees; self.orthoHeight = orthoHeight
        }
    }

    /// A SketchUp scene (« scène », page): a camera and the layers hidden in it.
    public struct Scene: Sendable {
        public var name: String
        public var camera: Camera?
        /// Indices into `SKPModel.layers` that the scene hides; every other layer is shown.
        /// nil: the scene does not save layer visibility, selecting it leaves the layers as they are (SketchUp).
        public var hiddenLayers: [Int]?
        public init(name: String, camera: Camera?, hiddenLayers: [Int]? = []) { self.name = name; self.camera = camera; self.hiddenLayers = hiddenLayers }
    }

    public struct Stats: Sendable {
        public var faces: Int
        public var triangles: Int
        public var edges: Int
        /// Placed groups and component instances, over the whole tree.
        public var instances: Int
        public var definitions: Int
        public var loadSeconds: Double
        public init(faces: Int = 0, triangles: Int = 0, edges: Int = 0, instances: Int = 0, definitions: Int = 0, loadSeconds: Double = 0) {
            self.faces = faces; self.triangles = triangles; self.edges = edges; self.instances = instances; self.definitions = definitions; self.loadSeconds = loadSeconds
        }
    }

    public var root: Definition
    public var definitions: [Definition]
    public var materials: [Material]
    public var layers: [Layer]
    public var layerGroups: [LayerGroup]
    public var scenes: [Scene]
    /// The camera saved in the file (view at last save), if any.
    public var camera: Camera?
    public var boundsMin: SIMD3<Float>
    public var boundsMax: SIMD3<Float>
    public var stats: Stats
    public var fileInfo: SKPFileInfo
    /// Non-fatal note from the loader, e.g. file saved by a newer SketchUp (loaded anyway).
    public var loadWarning: String?
    /// Temporary folder holding the written textures (`NSTemporaryDirectory()/SimpleSKP/<uuid>/`), nil when none;
    /// the app deletes it when the document closes.
    public var textureDirectory: URL?

    public init(root: Definition, definitions: [Definition] = [], materials: [Material] = [], layers: [Layer], scenes: [Scene] = [], camera: Camera? = nil, boundsMin: SIMD3<Float>, boundsMax: SIMD3<Float>, stats: Stats = Stats(), fileInfo: SKPFileInfo, loadWarning: String? = nil, textureDirectory: URL? = nil) {
        self.root = root; self.definitions = definitions; self.materials = materials; self.layers = layers
        self.layerGroups = Self.buildLayerGroups(for: layers)
        self.scenes = scenes; self.camera = camera
        self.boundsMin = boundsMin; self.boundsMax = boundsMax; self.stats = stats; self.fileInfo = fileInfo; self.loadWarning = loadWarning; self.textureDirectory = textureDirectory
    }

    public var size: SIMD3<Float> { boundsMax - boundsMin }
    public var center: SIMD3<Float> { (boundsMin + boundsMax) / 2 }

    /// True when the model is a 2D plan/section in the XY plane (e.g. a 2D AutoCAD plan or pure-wireframe drawing).
    public var isPlanar2D: Bool {
        let planarXY = max(size.x, size.y)
        guard planarXY > 1e-4 else { return false }
        if size.z <= planarXY * 0.01 && (fileInfo.isCAD || stats.faces == 0) {
            return true
        }
        // AutoCAD 2D plans/sections overwhelmingly consist of edges (>96% edges vs faces), even when a few blocks carry Z elevations.
        if fileInfo.isCAD && stats.edges > 0 && stats.faces < max(60, stats.edges / 25) {
            return true
        }
        return false
    }

    // MARK: - Automatic Layer Grouping at Import

    private static let layerTokenSeparators = CharacterSet(charactersIn: "-_/:| ")

    /// Tokenizes a layer name on common separators (`-`, `_`, `/`, `:`, `|`, space).
    private static func tokenizeLayerName(_ raw: String) -> [String] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed
            .components(separatedBy: layerTokenSeparators)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// Normalizes a single token for stem comparison (case/diacritic insensitive, strips trailing digits and plural `s` on words >= 4 chars).
    private static func stemKey(_ token: String, stripTrailingDigits: Bool) -> String {
        var s = token.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current).lowercased()
        if stripTrailingDigits {
            let withoutDigits = s.replacingOccurrences(of: #"\d+$"#, with: "", options: .regularExpression)
            if withoutDigits.count >= 2 {
                s = withoutDigits
            }
        }
        if s.count >= 5 && s.hasSuffix("s") && !s.hasSuffix("ss") {
            s.removeLast()
        }
        return s
    }

    /// Automatically groups layers that share a native SketchUp tag folder or a common name base
    /// (e.g. `FRISS_VP_Sol` / `FRISS_Son`, `Mur-Jardin` / `Mur-Cour`, `Spotlight1` / `Spotlight2`,
    /// `W-2D-CIMU...`, `3D-CAGE...`, `Fond de plan-pdf` / `Fond de plan-skp`).
    /// Index 0 (`Layer0` / `Untagged`) is kept at the top as a standalone layer unless assigned to a folder.
    public static func buildLayerGroups(for layers: [Layer]) -> [LayerGroup] {
        guard !layers.isEmpty else { return [] }

        let allTokens: [[String]] = layers.map { tokenizeLayerName($0.name) }

        // Pass 1: Assign primary bucket keys in order of first appearance.
        var bucketOrder: [String] = []
        var buckets: [String: [Int]] = [:]

        func appendToBucket(_ key: String, index: Int) {
            if buckets[key] == nil {
                bucketOrder.append(key)
                buckets[key] = []
            }
            buckets[key]!.append(index)
        }

        for index in layers.indices {
            let layer = layers[index]
            if let folder = layer.folder?.trimmingCharacters(in: .whitespacesAndNewlines), !folder.isEmpty {
                appendToBucket("folder:\(folder.lowercased())", index: index)
                continue
            }
            // Keep Layer0 / Untagged as standalone at top.
            if index == 0 {
                appendToBucket("single:0", index: 0)
                continue
            }
            let tokens = allTokens[index]
            guard let first = tokens.first else {
                appendToBucket("single:\(index)", index: index)
                continue
            }
            // For single-token names (`Spotlight1`, `Projections`), strip trailing digits & plural `s`;
            // for multi-token names (`0_Murs`, `Mur-Jardin`), keep numeric tokens like `0` intact.
            let key = "tok:" + stemKey(first, stripTrailingDigits: tokens.count == 1)
            appendToBucket(key, index: index)
        }

        // Pass 2: Sub-split large or generic CAD buckets (e.g. `W-2D-CIMU...`, `3D-CAGE...`, `1-3D-...`)
        // when sub-tokens after `2D`/`3D` form multiple sub-groups of size >= 2.
        var refinedBuckets: [(key: String, indices: [Int])] = []
        let genericDimensionTokens: Set<String> = ["2d", "3d", "w"]

        for key in bucketOrder {
            guard let indices = buckets[key] else { continue }
            if key.hasPrefix("folder:") || indices.count < 5 {
                refinedBuckets.append((key, indices))
                continue
            }
            let firstTokLower = allTokens[indices[0]].first?.lowercased() ?? ""
            let isGenericCAD = genericDimensionTokens.contains(firstTokLower) || indices.count >= 8
            guard isGenericCAD else {
                refinedBuckets.append((key, indices))
                continue
            }

            // Determine depth of shared dimension prefix (e.g. `["3D"]` -> depth 1, `["W", "2D"]` -> depth 2)
            let depth: Int = {
                let sample = allTokens[indices[0]].map { $0.lowercased() }
                if sample.count >= 2 && (sample[1] == "2d" || sample[1] == "3d") {
                    return 2
                }
                return 1
            }()

            var subOrder: [String] = []
            var subMap: [String: [Int]] = [:]
            for idx in indices {
                let toks = allTokens[idx]
                let subKey: String
                if toks.count > depth {
                    subKey = stemKey(toks[depth], stripTrailingDigits: true)
                } else {
                    subKey = "_root_"
                }
                if subMap[subKey] == nil {
                    subOrder.append(subKey)
                    subMap[subKey] = []
                }
                subMap[subKey]!.append(idx)
            }

            let multiSubCount = subOrder.filter { (subMap[$0]?.count ?? 0) >= 2 }.count
            if multiSubCount >= 2 {
                var leftovers: [Int] = []
                for subKey in subOrder {
                    let subIndices = subMap[subKey]!
                    if subIndices.count >= 2 {
                        refinedBuckets.append(("\(key)/\(subKey)", subIndices))
                    } else {
                        leftovers.append(contentsOf: subIndices)
                    }
                }
                if !leftovers.isEmpty {
                    refinedBuckets.append(("\(key)/_misc", leftovers))
                }
            } else {
                refinedBuckets.append((key, indices))
            }
        }

        // Pass 3: Build final `LayerGroup` entries, computing human-readable group names and stripped member labels.
        var result: [LayerGroup] = []
        var usedIDs: Set<String> = []

        for (rawKey, indices) in refinedBuckets {
            if indices.count == 1 && !rawKey.hasPrefix("folder:") {
                let idx = indices[0]
                let name = layers[idx].name
                result.append(LayerGroup(
                    id: "layer-\(idx)",
                    name: name,
                    layerIndices: [idx],
                    memberLabels: [idx: name]
                ))
                continue
            }

            let groupName: String
            if rawKey.hasPrefix("folder:"), let folder = layers[indices[0]].folder, !folder.isEmpty {
                groupName = folder
            } else {
                groupName = computeGroupDisplayName(for: indices, layers: layers, allTokens: allTokens)
            }

            var labels: [Int: String] = [:]
            for idx in indices {
                labels[idx] = stripGroupPrefix(groupName, from: layers[idx].name)
            }

            var baseID = "group-" + groupName.lowercased().replacingOccurrences(of: #"[^a-z0-9]+"#, with: "-", options: .regularExpression)
            if usedIDs.contains(baseID) {
                baseID += "-\(indices[0])"
            }
            usedIDs.insert(baseID)

            result.append(LayerGroup(
                id: baseID,
                name: groupName,
                layerIndices: indices,
                memberLabels: labels
            ))
        }

        return result
    }

    private static func computeGroupDisplayName(for indices: [Int], layers: [Layer], allTokens: [[String]]) -> String {
        guard let firstIdx = indices.first else { return "" }
        let firstTokens = allTokens[firstIdx]
        guard !firstTokens.isEmpty else { return layers[firstIdx].name }

        // Find how many leading tokens are shared across all members in `indices`.
        var sharedCount = firstTokens.count
        for idx in indices.dropFirst() {
            let toks = allTokens[idx]
            var match = 0
            let limit = min(sharedCount, toks.count)
            while match < limit {
                let a = firstTokens[match].folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current).lowercased()
                let b = toks[match].folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current).lowercased()
                if a == b {
                    match += 1
                } else {
                    break
                }
            }
            sharedCount = match
        }

        // If all members are single-token or differ in the first token (`Spotlight1`/`Spotlight2`, `Projection`/`Projections`),
        // extract the shared stem from the first token.
        if sharedCount == 0 {
            let tok = firstTokens[0]
            let stripped = tok.replacingOccurrences(of: #"\d+$"#, with: "", options: .regularExpression)
            return stripped.isEmpty ? tok : stripped
        }

        // Reconstruct the prefix from `layers[firstIdx].name` preserving original separators up to `sharedCount` tokens.
        let raw = layers[firstIdx].name.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefixTokens = Array(firstTokens.prefix(sharedCount))
        var searchRange = raw.startIndex..<raw.endIndex
        var endBound = raw.startIndex
        for tok in prefixTokens {
            if let r = raw.range(of: tok, options: [.caseInsensitive, .diacriticInsensitive], range: searchRange) {
                endBound = r.upperBound
                searchRange = endBound..<raw.endIndex
            }
        }
        let candidate = String(raw[raw.startIndex..<endBound]).trimmingCharacters(in: layerTokenSeparators)
        return candidate.isEmpty ? prefixTokens.joined(separator: " ") : candidate
    }

    private static func stripGroupPrefix(_ prefix: String, from fullName: String) -> String {
        let trimmed = fullName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prefix.isEmpty else { return trimmed }
        if let range = trimmed.range(of: prefix, options: [.anchored, .caseInsensitive, .diacriticInsensitive]) {
            let remainder = String(trimmed[range.upperBound...]).trimmingCharacters(in: layerTokenSeparators)
            if !remainder.isEmpty {
                return remainder
            }
        }
        return trimmed
    }
}

public enum SKPError: Error, LocalizedError, Sendable {
    case sketchUpNotFound(searched: [URL])
    case api(function: String, code: Int32)
    case unreadable(URL)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .sketchUpNotFound:
            return L("Framework SketchUp introuvable : SimpleSKP.app semble incomplet (Contents/Frameworks/SketchUpAPI.framework). Réinstallez l'app.",
                     "SketchUp framework not found: SimpleSKP.app looks incomplete (Contents/Frameworks/SketchUpAPI.framework). Reinstall the app.")
        case .api(let function, let code):
            return L("Erreur de l'API SketchUp (\(function) → \(code)).", "SketchUp API error (\(function) → \(code)).")
        case .unreadable(let url):
            return L("Fichier illisible : \(url.lastPathComponent)", "Unreadable file: \(url.lastPathComponent)")
        case .cancelled:
            return L("Chargement annulé.", "Loading cancelled.")
        }
    }
}
