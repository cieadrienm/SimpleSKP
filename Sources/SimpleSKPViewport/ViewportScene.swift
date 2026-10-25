import SceneKit
import SimpleSKPCore

/// Builds the SceneKit scene for a model. May be constructed off the main thread, right after `SKPReader.load`.
/// Root node rotated −90° about X (Z up → Y up); one node per definition, one child node per mesh batch
/// (tagged with its layer), instances by `clone()` sharing geometry; edges as `.line` elements.
public final class ViewportScene {
    public let model: SKPModel
    public let scene: SCNScene

    public init(model: SKPModel) {
        self.model = model
        self.scene = SCNScene()
        fatalError("todo: Viewport agent")
    }

    /// Shows or hides every node (meshes, edges, instances) on a layer, by index into `model.layers`.
    public func setLayer(_ index: Int, visible: Bool) { fatalError("todo: Viewport agent") }

    public var showsEdges: Bool = true { didSet { fatalError("todo: Viewport agent") } }
}
