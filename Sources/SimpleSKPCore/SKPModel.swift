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
        /// Texture written to a temporary file by the reader (`SUTextureWriteToFile`), nil for plain colours.
        public var textureURL: URL?
        /// Metres per texture repeat along S and T (SketchUp texture width/height) = 0.0254 / s_scale, 0.0254 / t_scale
        /// (texture.h: s_scale/t_scale are repeats per inch). Divide a nil-material mesh's `uvs` by it for an inherited texture.
        public var textureScale: SIMD2<Float>

        public init(name: String, color: SIMD4<Float>, opacity: Float = 1, textureURL: URL? = nil, textureScale: SIMD2<Float> = SIMD2(1, 1)) {
            self.name = name; self.color = color; self.opacity = opacity; self.textureURL = textureURL; self.textureScale = textureScale
        }
    }

    /// A SketchUp layer (« calque », called a tag since SketchUp 2020).
    public struct Layer: Sendable {
        public var name: String
        public var isVisible: Bool
        public init(name: String, isVisible: Bool) { self.name = name; self.isVisible = isVisible }
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
        self.root = root; self.definitions = definitions; self.materials = materials; self.layers = layers; self.scenes = scenes; self.camera = camera
        self.boundsMin = boundsMin; self.boundsMax = boundsMax; self.stats = stats; self.fileInfo = fileInfo; self.loadWarning = loadWarning; self.textureDirectory = textureDirectory
    }

    public var size: SIMD3<Float> { boundsMax - boundsMin }
    public var center: SIMD3<Float> { (boundsMin + boundsMax) / 2 }
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
