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
    public let cameraNode = SCNNode()

    private enum Drag { case orbit, pan }
    private var drag = Drag.orbit
    private var lastPoint = CGPoint.zero
    private var zoomAnchor: SIMD3<Float>?
    private var lastWheel: TimeInterval = 0

    public override init(frame: NSRect, options: [String: Any]? = nil) {
        super.init(frame: frame, options: options)
        setUp()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        setUp()
    }

    private func setUp() {
        rendersContinuously = false
        antialiasingMode = .multisampling4X
        allowsCameraControl = false
        autoenablesDefaultLighting = false
        backgroundColor = NSColor(red: 0.067, green: 0.075, blue: 0.09, alpha: 1)
        preferredFramesPerSecond = 60
        let camera = SCNCamera()
        camera.automaticallyAdjustsZRange = true
        camera.projectionDirection = .vertical
        camera.fieldOfView = 35 // SketchUp's default
        cameraNode.camera = camera
        cameraNode.name = "camera"
    }

    public override var acceptsFirstResponder: Bool { true }

    private var camera: SCNCamera { cameraNode.camera! }
    private var controller: SCNCameraController { defaultCameraController }
    /// Orbit centre, world space.
    var target: SIMD3<Float> {
        get { SIMD3(controller.target) }
        set { controller.target = SCNVector3(newValue) }
    }

    /// Main thread: shows the scene, applies the file's camera if any, otherwise zooms to extents.
    public func present(_ scene: ViewportScene) {
        viewportScene = scene
        self.scene = scene.scene
        cameraNode.removeFromParentNode()
        scene.modelRoot.addChildNode(cameraNode)
        cameraNode.childNodes.forEach { $0.removeFromParentNode() } // the previous scene's headlight
        scene.headlight.removeFromParentNode()
        cameraNode.addChildNode(scene.headlight)
        pointOfView = cameraNode
        controller.pointOfView = cameraNode
        controller.interactionMode = .orbitTurntable
        controller.inertiaEnabled = false
        controller.automaticTarget = false
        controller.worldUp = SCNVector3(0, 1, 0)
        if let camera = scene.model.camera {
            apply(camera: camera, animated: false)
        } else {
            look(.iso, animated: false) // the never-placed camera has no meaningful direction to keep
        }
    }

    public func zoomExtents(animated: Bool) {
        let back = -cameraNode.simdWorldFront
        frame(direction: back.x.isFinite && simd_length(back) > 0.5 ? back : modelToWorld(vector: isoDirection),
              up: cameraNode.simdWorldUp, animated: animated)
    }

    /// Frames the whole model from a standard direction.
    public func look(_ view: StandardView, animated: Bool) {
        let z = SIMD3<Float>(0, 0, 1), y = SIMD3<Float>(0, 1, 0)
        let (direction, up): (SIMD3<Float>, SIMD3<Float>) = switch view {
        case .iso: (isoDirection, z)
        case .top: (z, y)
        case .bottom: (-z, y)
        case .front: (-y, z)
        case .back: (y, z)
        case .left: (SIMD3(-1, 0, 0), z)
        case .right: (SIMD3(1, 0, 0), z)
        }
        frame(direction: modelToWorld(vector: direction), up: modelToWorld(vector: up), animated: animated)
    }

    /// Applies a model-space camera (metres, Z up, vertical FOV) verbatim under the rotated root.
    public func apply(camera model: SKPModel.Camera, animated: Bool) {
        let worldTarget = modelToWorld(model.target)
        animate(animated) {
            cameraNode.simdPosition = model.position
            cameraNode.simdLook(at: worldTarget, up: modelToWorld(vector: model.up), localFront: SCNNode.simdLocalFront)
            camera.usesOrthographicProjection = !model.isPerspective
            camera.fieldOfView = CGFloat(model.fovDegrees) // kept for a later switch to perspective
            if !model.isPerspective { camera.orthographicScale = Double(model.orthoHeight / 2) }
        }
        target = worldTarget
        isPerspective = model.isPerspective
    }

    public var isPerspective: Bool = true {
        didSet {
            guard isPerspective == camera.usesOrthographicProjection else { return }
            let tanHalf = tan(Double(camera.fieldOfView) * .pi / 360)
            let eye = cameraNode.simdWorldPosition, front = cameraNode.simdWorldFront
            // Zoomed past the target: its depth is negative; fall back to its distance so the ortho scale stays positive.
            let along = simd_dot(target - eye, front)
            let depth = along > 1e-3 ? along : max(simd_distance(target, eye), 1e-3)
            if isPerspective {
                // Same framing: move along the view axis to the distance where the target plane fits the ortho height.
                cameraNode.simdWorldPosition += front * (depth - Float(camera.orthographicScale / tanHalf))
            } else {
                camera.orthographicScale = Double(depth) * tanHalf
            }
            camera.usesOrthographicProjection = !isPerspective
            setNeedsDisplay(bounds)
        }
    }

    // MARK: - Navigation (event handlers stay one-liners over testable methods)

    public override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        lastPoint = point
        drag = event.modifierFlags.contains(.shift) ? .pan : .orbit
        if event.clickCount == 2 { recentre(at: point); return }
        if let hit = hit(point) { target = hit }
    }
    public override func rightMouseDown(with event: NSEvent) { beginPan(event) } // no super: it would pop a context menu
    public override func otherMouseDown(with event: NSEvent) { beginPan(event) }
    public override func mouseDragged(with event: NSEvent) { dragged(event) }
    public override func rightMouseDragged(with event: NSEvent) { dragged(event) }
    public override func otherMouseDragged(with event: NSEvent) { dragged(event) }

    public override func scrollWheel(with event: NSEvent) {
        // One wheel notch ≈ 10 %; precise (trackpad) deltas are in points, ~10 per notch.
        let notches = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / 10 : event.scrollingDeltaY
        // A wheel has no phases: a burst of notches less than 150 ms apart is one gesture (one hit test on huge models).
        let wheel = event.phase.isEmpty && event.momentumPhase.isEmpty
        let newGesture = event.phase == .began || (wheel && event.timestamp - lastWheel > 0.15)
        if wheel { lastWheel = event.timestamp }
        zoom(ratio: Float(pow(0.9, notches)), at: convert(event.locationInWindow, from: nil), newGesture: newGesture)
    }

    public override func magnify(with event: NSEvent) {
        zoom(ratio: Float(1 / max(0.1, 1 + event.magnification)), at: convert(event.locationInWindow, from: nil),
             newGesture: event.phase == .began)
    }

    public override func keyDown(with event: NSEvent) {
        if event.charactersIgnoringModifiers?.lowercased() == "z", event.modifierFlags.contains(.shift),
           event.modifierFlags.isDisjoint(with: [.command, .option, .control]) {
            zoomExtents(animated: true)
        } else {
            super.keyDown(with: event)
        }
    }

    private func beginPan(_ event: NSEvent) {
        lastPoint = convert(event.locationInWindow, from: nil)
        drag = .pan
        if let hit = hit(lastPoint) { target = hit } // pan scale = depth under the cursor
    }

    private func dragged(_ event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let dx = Float(point.x - lastPoint.x), dy = Float(point.y - lastPoint.y)
        lastPoint = point
        if drag == .orbit { orbit(dx: dx, dy: dy) } else { pan(dx: dx, dy: dy) }
    }

    /// View points, y up (AppKit). Dragging right turns the model right, like SketchUp.
    func orbit(dx: Float, dy: Float) {
        controller.rotateBy(x: -dx, y: dy)
        setNeedsDisplay(bounds)
    }

    /// View points, y up. The model follows the cursor about 1:1 at the target's depth.
    func pan(dx: Float, dy: Float) {
        let metresPerPoint = visibleHeight / Float(max(1, bounds.height))
        let before = cameraNode.simdWorldPosition
        controller.translateInCameraSpaceBy(x: -dx * metresPerPoint, y: -dy * metresPerPoint, z: 0)
        target += cameraNode.simdWorldPosition - before // the controller leaves its target behind
        setNeedsDisplay(bounds)
    }

    /// ratio < 1 zooms in (distance or ortho height multiplied by ratio), towards `point`.
    /// Perspective: the step is a fraction of the depth under the cursor (hit tested once per gesture), so it never
    /// crosses a wall. Parallel: the camera slides towards the cursor so the point under it stays put.
    func zoom(ratio: Float, at point: CGPoint, newGesture: Bool = true) {
        if camera.usesOrthographicProjection {
            let metresPerPoint = visibleHeight / Float(max(1, bounds.height))
            let dx = Float(point.x - bounds.midX) * metresPerPoint, dy = Float(point.y - bounds.midY) * metresPerPoint
            camera.orthographicScale *= Double(ratio)
            let before = cameraNode.simdWorldPosition
            controller.translateInCameraSpaceBy(x: dx * (1 - ratio), y: dy * (1 - ratio), z: 0)
            target += cameraNode.simdWorldPosition - before // as in pan()
        } else {
            if newGesture { zoomAnchor = hit(point) }
            let depth = simd_distance(cameraNode.simdWorldPosition, zoomAnchor ?? target)
            controller.dolly(by: depth * (1 - ratio), onScreenPoint: point, viewport: bounds.size)
        }
        setNeedsDisplay(bounds)
    }

    /// Double-click: the clicked point becomes the target and the camera slides sideways until it sits on the view axis.
    func recentre(at point: CGPoint) {
        guard let hit = hit(point) else { return }
        let eye = cameraNode.simdWorldPosition, front = cameraNode.simdWorldFront
        let offset = hit - (eye + front * simd_dot(hit - eye, front))
        let position = cameraNode.simdWorldPosition + offset
        animate(true, duration: 0.25) { cameraNode.simdWorldPosition = position }
        target = hit
    }

    // MARK: - Helpers

    private var visibleHeight: Float {
        if camera.usesOrthographicProjection { return Float(camera.orthographicScale) * 2 }
        let distance = simd_distance(cameraNode.simdWorldPosition, target)
        return 2 * distance * Float(tan(camera.fieldOfView * .pi / 360))
    }

    /// Nearest model point under `point` (results are sorted by distance). Back faces count: SketchUp rooms are
    /// often single-sided walls facing outwards.
    private func hit(_ point: CGPoint) -> SIMD3<Float>? {
        hitTest(point, options: [.boundingBoxOnly: false, .backFaceCulling: false]).first.map { SIMD3<Float>($0.worldCoordinates) }
    }

    private var isoDirection: SIMD3<Float> { simd_normalize(SIMD3(1, -1, 1)) }

    private func modelToWorld(_ point: SIMD3<Float>) -> SIMD3<Float> {
        viewportScene?.modelRoot.simdConvertPosition(point, to: nil) ?? point
    }

    private func modelToWorld(vector: SIMD3<Float>) -> SIMD3<Float> {
        viewportScene?.modelRoot.simdConvertVector(vector, to: nil) ?? vector
    }

    /// Puts the camera on `direction` (world, target → eye) at the distance that fits the visible bounding sphere.
    private func frame(direction: SIMD3<Float>, up: SIMD3<Float>, animated: Bool) {
        guard let bounds = viewportScene?.visibleBounds else { return }
        let centre = modelToWorld((bounds.min + bounds.max) / 2)
        let radius = max(simd_length(bounds.max - bounds.min) / 2, 0.01)
        let aspect = Float(max(1, self.bounds.width) / max(1, self.bounds.height))
        let vfov = Float(camera.fieldOfView) * .pi / 180
        let hfov = 2 * atan(tan(vfov / 2) * aspect)
        let distance = radius / sin(min(vfov, hfov) / 2) * 1.05
        animate(animated) {
            cameraNode.simdWorldPosition = centre + simd_normalize(direction) * distance
            cameraNode.simdLook(at: centre, up: up, localFront: SCNNode.simdLocalFront)
            if camera.usesOrthographicProjection { camera.orthographicScale = Double(radius * 1.05 / min(1, aspect)) }
        }
        target = centre
    }

    private func animate(_ animated: Bool, duration: Double = 0.35, _ changes: () -> Void) {
        SCNTransaction.begin()
        SCNTransaction.animationDuration = animated ? duration : 0
        SCNTransaction.animationTimingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        changes()
        SCNTransaction.commit()
        setNeedsDisplay(bounds)
    }
}
