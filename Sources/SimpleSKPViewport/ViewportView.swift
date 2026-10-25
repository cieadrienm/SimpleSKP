import SceneKit
import SimpleSKPCore

public enum StandardView: CaseIterable, Sendable {
    case iso, top, bottom, front, back, left, right
}

/// D6 navigation over one `CameraRig`, four ways side by side: orbit (left drag, inertia; ⇧/middle drag = pan; wheel =
/// zoom towards the cursor; double-click = recentre), game editor (right drag = look; WASD/ZQSD by keyCode, arrows,
/// space/E/C), trackpad (two fingers = orbit or zoom, ⌥ = pan, pinch = zoom, rotate = yaw), and free fly.
/// Renders on demand only (`rendersContinuously = false`).
public final class ViewportView: SCNView {
    public private(set) var viewportScene: ViewportScene?
    public let cameraNode = SCNNode()
    private(set) lazy var rig = CameraRig(node: cameraNode)

    /// Réglages « Défilement à deux doigts : zoom » (Magic Mouse); orbit otherwise.
    public static var twoFingerScrollZooms = false
    /// Called when free fly starts or ends, whatever ended it (Esc, the menu, lost focus).
    public var onFreeFlyingChange: ((Bool) -> Void)?
    /// Called whenever the camera pose changes (orbit, pan, zoom, glide), with `(yaw, pitch, speed)` for HUD indicators.
    public var onPoseChange: ((Float, Float, Float) -> Void)?
    /// Optional override for `resetView(animated:)` so the document model can restore the active scene's camera.
    public var onResetView: ((Bool) -> Void)?

    private enum Drag { case orbit, pan, look }
    private var drag: Drag?
    private var lastPoint = CGPoint.zero
    private var zoomAnchor: SIMD3<Float>?
    private var lastWheel: TimeInterval = 0
    /// NSCursor.hide() calls not yet balanced by unhide(): 0 or 1, checked by the tests.
    private(set) var cursorHides = 0

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
        Rendering.configure(camera: camera)
        Rendering.setAmbientOcclusion(ambientOcclusionEnabled, on: camera)
        camera.automaticallyAdjustsZRange = true
        camera.projectionDirection = .vertical
        camera.fieldOfView = 35 // SketchUp's default
        cameraNode.camera = camera
        cameraNode.name = "camera"
        rig.onChange = { [unowned self] in
            setNeedsDisplay(bounds)
            onPoseChange?(rig.pose.yaw, rig.pose.pitch, rig.speed)
        }
        // Free fly reads mouseMoved; .inVisibleRect follows resizes by itself.
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    public override var acceptsFirstResponder: Bool { true }

    private var camera: SCNCamera { cameraNode.camera! }
    /// Orbit target straight ahead, world space.
    var target: SIMD3<Float> { modelToWorld(rig.pose.target) }

    public var ambientOcclusionEnabled = false {
        didSet { Rendering.setAmbientOcclusion(ambientOcclusionEnabled, intensity: ambientOcclusionIntensity, on: camera) }
    }

    public var ambientOcclusionIntensity: CGFloat = Rendering.defaultAmbientOcclusionIntensity {
        didSet {
            Rendering.setAmbientOcclusion(ambientOcclusionEnabled, intensity: ambientOcclusionIntensity, on: camera)
            setNeedsDisplay(bounds)
        }
    }

    /// Current camera position in SketchUp model coordinates (metres, Z up).
    public var cameraModelPosition: SIMD3<Float> {
        rig.pose.position
    }

    /// Forces an immediate on-demand SceneKit redraw even when only light or camera post-processing properties changed.
    public func requestRedraw() {
        let pos = cameraNode.simdPosition
        cameraNode.simdPosition = pos
        SCNTransaction.flush()
        setNeedsDisplay(bounds)
    }

    /// Main thread: shows the scene, applies the file's camera if any, otherwise zooms to extents.
    public func present(_ scene: ViewportScene) {
        viewportScene = scene
        self.scene = scene.scene
        cameraNode.removeFromParentNode()
        scene.modelRoot.addChildNode(cameraNode)
        cameraNode.childNodes.forEach { $0.removeFromParentNode() } // the previous scene's fill
        scene.fill.removeFromParentNode()
        cameraNode.addChildNode(scene.fill)
        pointOfView = cameraNode
        rig.setSpeed(diagonal: simd_distance(scene.model.boundsMin, scene.model.boundsMax))
        if let camera = scene.model.camera {
            apply(camera: camera, animated: false)
        } else {
            look(.iso, animated: false) // the never-placed camera has no meaningful direction to keep
        }
    }

    public func zoomExtents(animated: Bool) {
        frame(rig.pose, animated: animated)
    }

    /// Resets the view (`Z`): restores the model's initial camera, or frames `.iso`.
    public func resetView(animated: Bool) {
        if let camera = viewportScene?.model.camera {
            apply(camera: camera, animated: animated)
        } else {
            look(.iso, animated: animated)
        }
        onResetView?(isPerspective)
    }

    /// Zooms in (`ratio < 1`) or out (`ratio > 1`) around the centre of the viewport.
    public func zoomStep(ratio: Float) {
        rig.stop()
        zoom(ratio: ratio, at: CGPoint(x: bounds.midX, y: bounds.midY), newGesture: true)
    }

    /// Frames the whole model from a standard direction.
    public func look(_ view: StandardView, animated: Bool) {
        let z = SIMD3<Float>(0, 0, 1), y = SIMD3<Float>(0, 1, 0)
        let (forward, up): (SIMD3<Float>, SIMD3<Float>) = switch view {
        case .iso: (-simd_normalize(SIMD3(1, -1, 1)), z)
        case .top: (-z, y)
        case .bottom: (z, y)
        case .front: (y, z)
        case .back: (-y, z)
        case .left: (SIMD3(1, 0, 0), z)
        case .right: (SIMD3(-1, 0, 0), z)
        }
        var pose = rig.pose
        (pose.yaw, pose.pitch) = CameraRig.orientation(forward: forward, up: up)
        frame(pose, animated: animated)
    }

    /// Applies a model-space camera (metres, Z up, vertical FOV) under the rotated root; roll is dropped.
    public func apply(camera model: SKPModel.Camera, animated: Bool) {
        // A projection change cannot be tweened: switch with the same framing (didSet, which also re-applies SSAO), then
        // glide from there. To parallel with the FOV still shown; to perspective with the new one.
        if !model.isPerspective { isPerspective = false }
        camera.fieldOfView = CGFloat(model.fovDegrees) // kept for a later switch to perspective
        isPerspective = model.isPerspective
        let scale = model.isPerspective ? nil : Double(model.orthoHeight / 2)
        if animated { rig.glide(to: CameraRig.pose(model), orthographicScale: scale) } else { rig.set(CameraRig.pose(model), orthographicScale: scale) }
    }

    public var isPerspective: Bool = true {
        didSet {
            guard isPerspective == camera.usesOrthographicProjection else { return }
            rig.stop()
            let tanHalf = Float(tan(Double(camera.fieldOfView) * .pi / 360))
            if isPerspective {
                // Same framing: move along the view axis to the distance where the target plane fits the ortho height.
                let distance = Float(camera.orthographicScale) / tanHalf
                rig.pose.position += rig.pose.forward * (rig.pose.distance - distance)
                rig.pose.distance = distance
            } else {
                camera.orthographicScale = Double(rig.pose.distance * tanHalf)
            }
            camera.usesOrthographicProjection = !isPerspective
            Rendering.setAmbientOcclusion(ambientOcclusionEnabled, intensity: ambientOcclusionIntensity, on: camera)
            setNeedsDisplay(bounds)
        }
    }

    /// Free fly (⌥⌘F): the cursor is hidden and captured, the mouse looks without a click, the keys move.
    /// Esc, the menu again, or losing the keyboard focus ends it.
    public var isFreeFlying = false {
        didSet {
            guard isFreeFlying != oldValue else { return }
            rig.stop()
            if isFreeFlying {
                window?.makeFirstResponder(self)
                captureCursor(centre: true)
            } else {
                rig.keys = []
                if drag != .look { releaseCursor() }
            }
            onFreeFlyingChange?(isFreeFlying)
        }
    }

    // MARK: - Mouse (handlers stay short over testable methods)

    public override func mouseDown(with event: NSEvent) {
        rig.stop()
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        lastPoint = point
        if isFreeFlying { drag = nil; return }
        if event.clickCount == 2 { drag = nil; recentre(at: point); return }
        drag = event.modifierFlags.contains(.shift) ? .pan : .orbit
        beginPivot(at: point)
    }

    public override func rightMouseDown(with event: NSEvent) { // no super: it would pop a context menu
        rig.stop()
        window?.makeFirstResponder(self)
        drag = .look
        captureCursor(centre: false)
    }

    public override func otherMouseDown(with event: NSEvent) {
        rig.stop()
        lastPoint = convert(event.locationInWindow, from: nil)
        drag = .pan
        beginPivot(at: lastPoint)
    }

    public override func mouseDragged(with event: NSEvent) { dragged(event) }
    public override func rightMouseDragged(with event: NSEvent) { dragged(event) }
    public override func otherMouseDragged(with event: NSEvent) { dragged(event) }

    public override func mouseMoved(with event: NSEvent) {
        if isFreeFlying { mouseLook(dx: Float(event.deltaX), dy: Float(-event.deltaY)) }
    }

    public override func mouseUp(with event: NSEvent) {
        if drag == .orbit { rig.release(time: event.timestamp) }
        drag = nil
    }

    public override func rightMouseUp(with event: NSEvent) {
        drag = nil
        if !isFreeFlying { releaseCursor() }
    }

    public override func otherMouseUp(with event: NSEvent) { drag = nil }

    private func dragged(_ event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let dx = Float(point.x - lastPoint.x), dy = Float(point.y - lastPoint.y)
        lastPoint = point
        if isFreeFlying || drag == .look {
            mouseLook(dx: Float(event.deltaX), dy: Float(-event.deltaY)) // the captured cursor does not move: deltas only
        } else if drag == .orbit {
            orbit(dx: dx, dy: dy, time: event.timestamp)
        } else if drag == .pan {
            pan(dx: dx, dy: dy)
        }
    }

    public override func scrollWheel(with event: NSEvent) {
        if !event.momentumPhase.isEmpty { return } // the rig's own inertia continues a two-finger orbit
        let gesture = event.hasPreciseScrollingDeltas && !event.phase.isEmpty
        // One wheel notch ≈ 10 %; precise deltas are in points, ~10 per notch.
        let notches = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / 10 : event.scrollingDeltaY
        if drag == .look {
            rig.speedScale = min(16, max(1.0 / 16, rig.speedScale * Float(pow(1.25, notches))))
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        guard gesture else {
            // A wheel has no phases: a burst of notches less than 150 ms apart is one gesture (one hit test on huge models).
            let newGesture = event.timestamp - lastWheel > 0.15
            lastWheel = event.timestamp
            if newGesture { rig.stop() }
            zoom(ratio: Float(pow(0.9, notches)), at: point, newGesture: newGesture)
            return
        }
        if event.phase == .began { rig.stop(); beginPivot(at: point) }
        // The end carries no motion: orbiting by zero would zero the spin before it can coast.
        if event.phase == .ended || event.phase == .cancelled { rig.release(time: event.timestamp); return }
        let dx = Float(event.scrollingDeltaX), dy = Float(-event.scrollingDeltaY)
        if event.modifierFlags.contains(.option) {
            pan(dx: -dx, dy: -dy) // the model follows the fingers
        } else if Self.twoFingerScrollZooms {
            zoom(ratio: Float(pow(0.9, notches)), at: point, newGesture: event.phase == .began)
        } else {
            orbit(dx: dx, dy: dy, time: event.timestamp)
        }
    }

    public override func magnify(with event: NSEvent) {
        if event.phase == .began { rig.stop() }
        zoom(ratio: Float(1 / max(0.1, 1 + event.magnification)), at: convert(event.locationInWindow, from: nil),
             newGesture: event.phase == .began)
    }

    /// Two-finger rotation: yaw around the point under the fingers, never roll; the model turns with the fingers.
    public override func rotate(with event: NSEvent) {
        if event.phase == .began { rig.stop(); beginPivot(at: convert(event.locationInWindow, from: nil)) }
        rig.orbit(yaw: -event.rotation * .pi / 180, pitch: 0)
    }

    // MARK: - Keyboard

    public override func keyDown(with event: NSEvent) {
        rig.stop()
        if event.keyCode == 53, isFreeFlying { isFreeFlying = false; return } // Esc
        if press(event) { return }
        if event.charactersIgnoringModifiers?.lowercased() == "z",
           event.modifierFlags.isDisjoint(with: [.command, .option, .control]) {
            if event.modifierFlags.contains(.shift) {
                zoomExtents(animated: true)
            } else {
                resetView(animated: true)
            }
        } else {
            super.keyDown(with: event)
        }
    }

    /// A menu must not take Z or ⇧Z from the movement keys while looking around (AZERTY: physical W types "z"/"Z").
    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        window?.firstResponder === self && press(event) ? true : super.performKeyEquivalent(with: event)
    }

    public override func keyUp(with event: NSEvent) {
        if CameraRig.moveKeys.contains(event.keyCode) { rig.keys.remove(event.keyCode) } else { super.keyUp(with: event) }
    }

    public override func flagsChanged(with event: NSEvent) {
        rig.fast = event.modifierFlags.contains(.shift)
        if event.modifierFlags.contains(.command) { rig.keys = [] } // AppKit sends no keyUp for a key released under ⌘
        super.flagsChanged(with: event)
    }

    /// Movement key by physical position. Z resets the view and ⇧Z stays « zoom étendu » unless looking around or flying, where Z moves and ⇧ means fast.
    private func press(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, CameraRig.moveKeys.contains(event.keyCode),
              event.modifierFlags.isDisjoint(with: [.command, .option, .control]) else { return false }
        let shift = event.modifierFlags.contains(.shift)
        // A held key: ⇧ pressed meanwhile means fast, never ⇧Z (AZERTY: holding Z then ⇧).
        if rig.keys.contains(event.keyCode) || event.isARepeat { rig.fast = shift; return true }
        if event.charactersIgnoringModifiers?.lowercased() == "z", drag != .look, !isFreeFlying { return false }
        rig.fast = shift
        rig.keys.insert(event.keyCode)
        return true
    }

    // MARK: - Focus: no path leaves the cursor hidden or a key held

    public override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { releaseInput() }
        return resigned
    }

    public override func viewWillMove(toWindow newWindow: NSWindow?) {
        NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: nil)
        releaseInput()
        super.viewWillMove(toWindow: newWindow)
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        NotificationCenter.default.addObserver(self, selector: #selector(windowResignedKey), name: NSWindow.didResignKeyNotification, object: window)
    }

    @objc private func windowResignedKey(_ note: Notification) { releaseInput() }

    func releaseInput() {
        drag = nil
        isFreeFlying = false
        rig.keys = []
        releaseCursor()
    }

    /// Hides the cursor and detaches it from the mouse: it cannot leave the view, the events still carry the deltas.
    private func captureCursor(centre: Bool) {
        guard cursorHides == 0 else { return }
        cursorHides += 1
        NSCursor.hide()
        guard let window, let screen = NSScreen.screens.first else { return } // headless tests: leave the real mouse alone
        if centre {
            let p = window.convertPoint(toScreen: convert(NSPoint(x: bounds.midX, y: bounds.midY), to: nil))
            CGWarpMouseCursorPosition(CGPoint(x: p.x, y: screen.frame.maxY - p.y)) // CG: top-left origin
        }
        CGAssociateMouseAndMouseCursorPosition(0)
    }

    private func releaseCursor() {
        guard cursorHides > 0 else { return }
        cursorHides -= 1
        CGAssociateMouseAndMouseCursorPosition(1)
        NSCursor.unhide()
    }

    // MARK: - Navigation (view points, AppKit y up)

    /// Dragging right turns the model right; dragging up makes the eye go down (SketchUp's feel).
    func orbit(dx: Float, dy: Float, time: TimeInterval? = nil) {
        let rate = orbitDegreesPerPoint * .pi / 180
        rig.orbit(yaw: -dx * rate, pitch: dy * rate, time: time)
    }

    /// Mouse right turns right, mouse up looks up; the eye stays.
    func mouseLook(dx: Float, dy: Float) {
        let rate = lookDegreesPerPoint * .pi / 180
        rig.look(yaw: -dx * rate, pitch: dy * rate)
    }

    /// The model follows the cursor about 1:1 at the pivot's depth.
    func pan(dx: Float, dy: Float) {
        let metresPerPoint = visibleHeight / Float(max(1, bounds.height))
        rig.pose.position -= (rig.pose.right * dx + rig.pose.up * dy) * metresPerPoint
    }

    /// ratio < 1 zooms in (distance or ortho height multiplied by ratio), towards `point`.
    /// Perspective: the step is a fraction of the depth under the cursor (hit tested once per gesture), so it never
    /// crosses a wall. Parallel: the camera slides towards the cursor so the point under it stays put.
    func zoom(ratio: Float, at point: CGPoint, newGesture: Bool = true) {
        if camera.usesOrthographicProjection {
            let metresPerPoint = visibleHeight / Float(max(1, bounds.height))
            let dx = Float(point.x - bounds.midX) * metresPerPoint, dy = Float(point.y - bounds.midY) * metresPerPoint
            camera.orthographicScale *= Double(ratio)
            rig.pose.position += (rig.pose.right * dx + rig.pose.up * dy) * (1 - ratio)
        } else {
            if newGesture { zoomAnchor = hit(point) }
            let pose = rig.pose
            let ray = ray(through: point)
            var next = pose
            next.position += ray * simd_distance(pose.position, zoomAnchor ?? pose.target) * (1 - ratio)
            // The target follows the point zoomed on; over the sky it travels with the eye.
            if let zoomAnchor { next.distance = max(simd_dot(zoomAnchor - next.position, pose.forward), 1e-3) }
            rig.pose = next
        }
    }

    /// Double-click: glides (0.3 s) until the clicked point sits at the view centre, at a third of its depth (judgement
    /// call: once instances are merged, the hit node's size says nothing about what was clicked). Parallel: a third of
    /// the scale, the eye keeps its depth (closer in, the near plane would cut the model).
    func recentre(at point: CGPoint) {
        guard let hit = hit(point) else { return }
        var next = rig.pose
        let parallel = camera.usesOrthographicProjection
        next.distance = max(simd_dot(hit - next.position, next.forward) / (parallel ? 1 : 3), 1e-3)
        next.position = hit - next.forward * next.distance
        let scale = parallel ? camera.orthographicScale / 3 : nil
        rig.glide(to: next, orthographicScale: scale, duration: 0.3)
    }

    /// Orbit and pan centre for a drag or gesture: the point under the cursor, else the target. The target moves to its
    /// depth so the pan scale and the parallel switch follow what is under the hand.
    private func beginPivot(at point: CGPoint) {
        guard let hit = hit(point) else { rig.pivot = nil; return }
        rig.pivot = hit
        rig.pose.distance = max(simd_dot(hit - rig.pose.position, rig.pose.forward), 1e-3)
    }

    // MARK: - Helpers

    private var tanHalfFOV: Float { Float(tan(camera.fieldOfView * .pi / 360)) }

    private var visibleHeight: Float {
        camera.usesOrthographicProjection ? Float(camera.orthographicScale) * 2 : 2 * rig.pose.distance * tanHalfFOV
    }

    /// Model-space direction of the perspective ray through a view point.
    private func ray(through point: CGPoint) -> SIMD3<Float> {
        let pose = rig.pose, scale = tanHalfFOV / (Float(max(1, bounds.height)) / 2)
        let x = Float(point.x - bounds.midX) * scale, y = Float(point.y - bounds.midY) * scale
        return simd_normalize(pose.forward + pose.right * x + pose.up * y)
    }

    /// Nearest face point under `point`, model space. Back faces count: SketchUp rooms are often single-sided walls facing
    /// outwards. Faces only (category 1): edges, hit with a tolerance, would win the closest-only search and lie off the
    /// surface. A segment test on the scene graph: `SCNView.hitTest` finds nothing before a first frame.
    func hit(_ point: CGPoint) -> SIMD3<Float>? {
        guard let root = viewportScene?.modelRoot, let bounds = viewportScene?.visibleBounds else { return nil }
        let pose = rig.pose, reach = simd_distance(pose.position, (bounds.min + bounds.max) / 2) + simd_distance(bounds.min, bounds.max)
        var from = pose.position, direction = ray(through: point)
        if camera.usesOrthographicProjection {
            let metresPerPoint = visibleHeight / Float(max(1, self.bounds.height))
            from += (pose.right * Float(point.x - self.bounds.midX) + pose.up * Float(point.y - self.bounds.midY)) * metresPerPoint
            direction = pose.forward
        }
        let to = from + direction * reach
        return root.hitTestWithSegment(from: SCNVector3(from), to: SCNVector3(to),
                                       options: [SCNHitTestOption.backFaceCulling.rawValue: false, SCNHitTestOption.categoryBitMask.rawValue: 1])
            .first.map { worldToModel(SIMD3<Float>($0.worldCoordinates)) }
    }

    private func modelToWorld(_ point: SIMD3<Float>) -> SIMD3<Float> {
        viewportScene?.modelRoot.simdConvertPosition(point, to: nil) ?? point
    }

    private func worldToModel(_ point: SIMD3<Float>) -> SIMD3<Float> {
        viewportScene?.modelRoot.simdConvertPosition(point, from: nil) ?? point
    }

    /// Keeps `pose`'s direction and puts the eye at the distance that fits the visible bounding sphere.
    private func frame(_ direction: CameraRig.Pose, animated: Bool) {
        guard let bounds = viewportScene?.visibleBounds else { return }
        let centre = (bounds.min + bounds.max) / 2
        let radius = max(simd_length(bounds.max - bounds.min) / 2, 0.01)
        let aspect = Float(max(1, self.bounds.width) / max(1, self.bounds.height))
        let vfov = Float(camera.fieldOfView) * .pi / 180
        let hfov = 2 * atan(tan(vfov / 2) * aspect)
        var pose = direction
        pose.distance = radius / sin(min(vfov, hfov) / 2) * 1.05
        pose.position = centre - pose.forward * pose.distance
        let scale = camera.usesOrthographicProjection ? Double(radius * 1.05 / min(1, aspect)) : nil
        if animated { rig.glide(to: pose, orthographicScale: scale) } else { rig.set(pose, orthographicScale: scale) }
    }
}
