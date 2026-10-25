import SceneKit
import SimpleSKPCore

public enum StandardView: CaseIterable, Sendable {
    case iso, top, bottom, front, back, left, right
}

/// SketchUp-like navigation on top of `SCNView`'s camera controller (`.orbitTurntable`, horizon kept, no inertia):
/// drag = orbit around the point under the cursor (hit test, else the model centre); ⇧-drag, right or middle
/// drag = pan; scroll or pinch = zoom towards the cursor; double-click = recentre on the point; ⇧Z = zoom extents.
/// Renders on demand only (`rendersContinuously = false`).
public final class ViewportView: SCNView {
    public private(set) var viewportScene: ViewportScene?

    /// Main thread: shows the scene, applies the file's camera if any, otherwise zooms to extents.
    public func present(_ scene: ViewportScene) { fatalError("todo: Viewport agent") }

    public func zoomExtents(animated: Bool) { fatalError("todo: Viewport agent") }

    /// Frames the whole model from a standard direction.
    public func look(_ view: StandardView, animated: Bool) { fatalError("todo: Viewport agent") }

    /// Applies a model-space camera (metres, Z up, vertical FOV) verbatim under the rotated root.
    public func apply(camera: SKPModel.Camera, animated: Bool) { fatalError("todo: Viewport agent") }

    public var isPerspective: Bool = true { didSet { fatalError("todo: Viewport agent") } }
}
