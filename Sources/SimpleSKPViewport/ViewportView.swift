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
    /// Called when the hovered layer under the mouse cursor changes (`nil` when over empty background).
    public var onHoverLayer: ((Int?) -> Void)?
    /// Called when the user clicks an object in the viewport to select its layer in the hierarchy.
    public var onSelectLayer: ((Int) -> Void)?
    /// Called when the user presses `H` in CAD mode to hide the selected object/layer.
    public var onHideSelectedLayer: (() -> Void)?
    /// Currently hovered layer index in `model.layers`, if any.
    public private(set) var hoveredLayer: Int? = nil

    /// `true` when the interactive measurement tool (`⌘D`) is active.
    public var isMeasuring: Bool = false {
        didSet {
            guard isMeasuring != oldValue else { return }
            window?.invalidateCursorRects(for: self)
            if !isMeasuring {
                onMeasureHover?(nil, false)
            }
        }
    }
    /// Optional reference Z plane (e.g. `measureStart.position.z`) for planar fallback while measuring.
    public var measureFallbackZ: Float? = nil
    /// Called when the cursor moves while `isMeasuring == true`, passing `(snap, isShiftPressed)`.
    public var onMeasureHover: ((MeasureSnap?, Bool) -> Void)?
    /// Called when the user clicks to place a measurement point while `isMeasuring == true`, passing `(snap, isShiftPressed)`.
    public var onMeasureClick: ((MeasureSnap, Bool) -> Void)?
    /// Called when the user presses `Esc` while `isMeasuring == true`.
    public var onMeasureEscape: (() -> Void)?

    /// `true` when the user is clicking a 3D point in the viewport to place or aim a video projector.
    public var isPickingProjectorPoint: Bool = false {
        didSet {
            guard isPickingProjectorPoint != oldValue else { return }
            window?.invalidateCursorRects(for: self)
            if !isPickingProjectorPoint, !isMeasuring {
                onMeasureHover?(nil, false)
            }
        }
    }
    /// Called when the user clicks a point in the viewport while `isPickingProjectorPoint == true`.
    public var onPickProjectorPoint: ((MeasureSnap) -> Void)?
    /// Called when the user presses `Esc` while `isPickingProjectorPoint == true`.
    public var onCancelProjectorPick: (() -> Void)?

    /// `true` when viewing a 2D AutoCAD plan: left-drag & trackpad scroll translate, wheel/pinch zoom, and `⌥`-drag rotates the 2D plan in-plane.
    public var is2DNavigationMode: Bool { rig.is2DMode }

    private enum Drag { case orbit, pan, look, rotate2D }
    private var drag: Drag?
    private var lastPoint = CGPoint.zero
    private var mouseDownPoint = CGPoint.zero
    private var didDragDuringMouseDown = false
    private var zoomAnchor: SIMD3<Float>?
    private var lastWheel: TimeInterval = 0
    private var allowScrollMomentum = false
    private var mouseMovedMonitor: Any?
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
        preferredFramesPerSecond = max(60, NSScreen.screens.map(\.maximumFramesPerSecond).max() ?? 60)
        let camera = SCNCamera()
        Rendering.configure(camera: camera)
        Rendering.setAmbientOcclusion(ambientOcclusionEnabled, on: camera)
        camera.automaticallyAdjustsZRange = true
        camera.projectionDirection = .vertical
        camera.fieldOfView = 35 // SketchUp's default
        cameraNode.camera = camera
        cameraNode.name = "camera"
        rig.onChange = { [unowned self] in
            refreshMeasurementCamera()
            setNeedsDisplay(bounds)
            onPoseChange?(rig.pose.yaw, rig.pose.pitch, rig.speed)
        }
        rig.onZoomInertiaStep = { [unowned self] stepRatio, point in
            zoom(ratio: stepRatio, at: point, newGesture: false)
        }
        // Free fly & hover highlight read mouseMoved; .activeAlways works even before clicking the viewport.
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
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

    /// Full current camera pose in SketchUp model coordinates (metres, Z up, yaw/pitch in radians).
    public var cameraPose: CameraRig.Pose {
        get { rig.pose }
        set { rig.set(newValue) }
    }

    /// Vertical field of view in degrees (`10 ... 120`, default `35`).
    public var fieldOfView: Float {
        get { Float(camera.fieldOfView) }
        set {
            let clamped = max(10.0, min(120.0, newValue))
            SCNTransaction.begin()
            SCNTransaction.animationDuration = 0
            camera.fieldOfView = CGFloat(clamped)
            SCNTransaction.commit()
            refreshMeasurementCamera()
            requestRedraw()
            onPoseChange?(rig.pose.yaw, rig.pose.pitch, rig.speed)
        }
    }

    /// Camera HDR exposure offset in EV (`-3.0 ... 3.0`, default `-0.62`).
    public var exposureOffset: Float {
        get { Float(camera.exposureOffset) }
        set {
            let clamped = max(-3.0, min(3.0, newValue))
            camera.exposureOffset = CGFloat(clamped)
            requestRedraw()
            onPoseChange?(rig.pose.yaw, rig.pose.pitch, rig.speed)
        }
    }

    /// Half-height in metres when in parallel (orthographic) projection.
    public var orthographicScale: Float {
        get { Float(camera.orthographicScale) }
        set {
            SCNTransaction.begin()
            SCNTransaction.animationDuration = 0
            camera.orthographicScale = Double(max(0.01, min(10_000.0, newValue)))
            SCNTransaction.commit()
            refreshMeasurementCamera()
            requestRedraw()
            onPoseChange?(rig.pose.yaw, rig.pose.pitch, rig.speed)
        }
    }

    /// Movement speed multiplier (`0.0625 ... 16.0`, default `1.0`).
    public var movementSpeedScale: Float {
        get { rig.speedScale }
        set {
            rig.speedScale = max(1.0 / 16.0, min(16.0, newValue))
            onPoseChange?(rig.pose.yaw, rig.pose.pitch, rig.speed)
        }
    }

    /// 35mm full-frame (24 mm sensor height) focal length in mm for a vertical FOV in degrees.
    public static func focalLengthMM(forVerticalFOVDegrees fov: Float) -> Float {
        let clamped = max(5.0, min(160.0, fov))
        let tanHalf = tan(clamped * .pi / 360.0)
        return max(1.0, 12.0 / max(1e-4, tanHalf))
    }

    /// Vertical FOV in degrees for a 35mm full-frame (24 mm sensor height) focal length in mm.
    public static func verticalFOVDegrees(forFocalLengthMM focal: Float) -> Float {
        let clamped = max(4.0, min(300.0, focal))
        let fov = atan(12.0 / clamped) * 360.0 / .pi
        return max(10.0, min(120.0, fov))
    }

    /// Updates one or more camera pose components in place (eye position, yaw/pitch in degrees, orbit target distance).
    public func setCameraPose(
        position: SIMD3<Float>? = nil,
        yawDegrees: Float? = nil,
        pitchDegrees: Float? = nil,
        distance: Float? = nil
    ) {
        var next = rig.pose
        if let position { next.position = position }
        if let yawDegrees { next.yaw = yawDegrees * .pi / 180.0 }
        if let pitchDegrees {
            let clampedDeg = max(-89.0, min(89.0, pitchDegrees))
            next.pitch = clampedDeg * .pi / 180.0
        }
        if let distance { next.distance = max(0.05, distance) }
        rig.set(next)
    }

    /// Orbits around the current target by `(dYawDegrees, dPitchDegrees)`.
    public func orbitByDegrees(yaw dYawDegrees: Float, pitch dPitchDegrees: Float) {
        rig.stop()
        rig.orbit(yaw: dYawDegrees * .pi / 180.0, pitch: dPitchDegrees * .pi / 180.0)
    }

    /// Places the camera at `position` looking directly at `target` (roll dropped, horizon level).
    public func setCameraLookAt(position: SIMD3<Float>, target: SIMD3<Float>, animated: Bool = false) {
        let delta = target - position
        let dist = max(simd_length(delta), 0.05)
        let dir = dist > 1e-4 ? delta / dist : SIMD3<Float>(0, 1, 0)
        let (yaw, pitch) = CameraRig.orientation(forward: dir, up: SIMD3<Float>(0, 0, 1))
        let next = CameraRig.Pose(position: position, yaw: yaw, pitch: pitch, distance: dist)
        if animated {
            rig.glide(to: next)
        } else {
            rig.set(next)
        }
    }

    /// Destination camera pose (if a smooth glide is in progress) or current camera pose.
    public var targetCameraPose: CameraRig.Pose {
        rig.targetPose
    }

    /// Destination orthographic scale (if a smooth glide is in progress) or current orthographic scale.
    public var targetOrthographicScale: Float {
        Float(rig.targetOrthographicScale)
    }

    /// Restores a complete camera pose and projection state (used by Undo/Redo).
    public func restoreCameraState(
        pose: CameraRig.Pose,
        isPerspective persp: Bool,
        fovDegrees: Float,
        orthographicScale orthoScale: Float,
        exposureOffset exposure: Float,
        animated: Bool = true
    ) {
        camera.fieldOfView = CGFloat(max(10.0, min(120.0, fovDegrees)))
        camera.exposureOffset = CGFloat(max(-3.0, min(3.0, exposure)))
        if isPerspective != persp {
            isPerspective = persp
        }
        let scale: Double? = persp ? nil : Double(max(0.01, min(10_000.0, orthoScale)))
        if animated {
            rig.glide(to: pose, orthographicScale: scale)
        } else {
            rig.set(pose, orthographicScale: scale)
        }
        refreshMeasurementCamera()
        requestRedraw()
    }

    /// Aims the camera from its current position towards `target`.
    public func setCameraTarget(_ target: SIMD3<Float>, animated: Bool = false) {
        setCameraLookAt(position: rig.pose.position, target: target, animated: animated)
    }

    /// Levels the camera horizon (`pitch = 0°`) while keeping its eye position and azimuth.
    public func levelHorizon(animated: Bool = false) {
        var next = rig.pose
        next.pitch = 0
        if animated {
            rig.glide(to: next, duration: 0.2)
        } else {
            rig.set(next)
        }
    }

    /// Synchronizes the camera parameters with `viewportScene.measureRoot` so measurements stay at constant screen thickness with zero lag.
    public func refreshMeasurementCamera() {
        guard let scene = viewportScene else { return }
        let ortho = camera.usesOrthographicProjection ? Float(camera.orthographicScale) : nil
        scene.updateMeasurementCamera(
            pose: rig.pose,
            orthoScale: ortho,
            tanHalfFOV: tanHalfFOV,
            viewportHeight: Float(max(1, bounds.height))
        )
    }

    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        refreshMeasurementCamera()
    }

    /// Forces an immediate on-demand SceneKit redraw even when only light or camera post-processing properties changed.
    public func requestRedraw() {
        refreshMeasurementCamera()
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
        let is2DCAD = scene.model.fileInfo.isCAD && scene.model.isPlanar2D
        rig.is2DMode = is2DCAD
        if is2DCAD {
            if isFreeFlying { isFreeFlying = false }
            isPerspective = false
        }
        rig.setSpeed(diagonal: simd_distance(scene.model.boundsMin, scene.model.boundsMax))
        if let camera = scene.model.camera {
            apply(camera: camera, animated: false)
        } else {
            look(scene.model.isPlanar2D ? .top : .iso, animated: false)
        }
        refreshMeasurementCamera()
    }

    public func zoomExtents(animated: Bool) {
        frame(rig.pose, animated: animated)
    }

    /// Frames a specific model-space bounding box (e.g. a layer or layer group), keeping the current viewing direction.
    public func frameBounds(
        min boundsMin: SIMD3<Float>,
        max boundsMax: SIMD3<Float>,
        animated: Bool,
        duration: Float = CameraRig.defaultGlideDuration
    ) {
        let centre = (boundsMin + boundsMax) / 2
        let radius = max(simd_length(boundsMax - boundsMin) / 2, 0.25)
        let aspect = Float(max(1, self.bounds.width) / max(1, self.bounds.height))
        let vfov = Float(camera.fieldOfView) * .pi / 180
        let hfov = 2 * atan(tan(vfov / 2) * aspect)
        var pose = rig.pose
        if is2DNavigationMode {
            pose.pitch = -.pi / 2
        }
        pose.distance = radius / sin(min(vfov, hfov) / 2) * 1.15
        pose.position = centre - pose.forward * pose.distance
        let scale = camera.usesOrthographicProjection ? Double(radius * 1.15 / min(1, aspect)) : nil
        if animated {
            rig.glide(to: pose, orthographicScale: scale, duration: duration)
        } else {
            rig.set(pose, orthographicScale: scale)
        }
    }

    /// Resets the view (`Z`): restores the model's initial camera, or frames `.top` (2D CAD plan) / `.iso` (3D).
    public func resetView(animated: Bool) {
        if let camera = viewportScene?.model.camera {
            apply(camera: camera, animated: animated)
        } else {
            look((viewportScene?.model.isPlanar2D == true) ? .top : .iso, animated: animated)
        }
        onResetView?(isPerspective)
    }

    /// Zooms in (`ratio < 1`) or out (`ratio > 1`) around the centre of the viewport with smooth easing.
    public func zoomStep(ratio: Float) {
        rig.stop()
        smoothZoom(ratio: ratio, at: CGPoint(x: bounds.midX, y: bounds.midY), newGesture: true)
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
    public func apply(camera model: SKPModel.Camera, animated: Bool, duration: Float = CameraRig.defaultGlideDuration) {
        // A projection change cannot be tweened: switch with the same framing (didSet, which also re-applies SSAO), then
        // glide from there. To parallel with the FOV still shown; to perspective with the new one.
        if !model.isPerspective { isPerspective = false }
        camera.fieldOfView = CGFloat(model.fovDegrees) // kept for a later switch to perspective
        isPerspective = model.isPerspective
        let scale = model.isPerspective ? nil : Double(model.orthoHeight / 2)
        if animated {
            rig.glide(to: CameraRig.pose(model), orthographicScale: scale, duration: duration)
        } else {
            rig.set(CameraRig.pose(model), orthographicScale: scale)
        }
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
            refreshMeasurementCamera()
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
        allowScrollMomentum = false
        rig.stop()
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        lastPoint = point
        mouseDownPoint = point
        didDragDuringMouseDown = false
        if isFreeFlying { drag = nil; return }
        if event.clickCount == 2 { drag = nil; recentre(at: point); return }
        if is2DNavigationMode {
            drag = event.modifierFlags.contains(.option) ? .rotate2D : .pan
        } else {
            drag = event.modifierFlags.contains(.shift) ? .pan : .orbit
        }
        beginPivot(at: point)
    }

    public override func rightMouseDown(with event: NSEvent) { // no super: it would pop a context menu
        allowScrollMomentum = false
        rig.stop()
        window?.makeFirstResponder(self)
        if is2DNavigationMode {
            lastPoint = convert(event.locationInWindow, from: nil)
            drag = event.modifierFlags.contains(.option) ? .rotate2D : .pan
            beginPivot(at: lastPoint)
            return
        }
        drag = .look
        captureCursor(centre: false)
    }

    public override func otherMouseDown(with event: NSEvent) {
        allowScrollMomentum = false
        rig.stop()
        lastPoint = convert(event.locationInWindow, from: nil)
        drag = .pan
        beginPivot(at: lastPoint)
    }

    public override func resetCursorRects() {
        super.resetCursorRects()
        if isMeasuring || isPickingProjectorPoint {
            addCursorRect(bounds, cursor: .crosshair)
        }
    }

    public override func mouseDragged(with event: NSEvent) { dragged(event) }
    public override func rightMouseDragged(with event: NSEvent) { dragged(event) }
    public override func otherMouseDragged(with event: NSEvent) { dragged(event) }

    public override func mouseMoved(with event: NSEvent) {
        if isFreeFlying {
            mouseLook(dx: Float(event.deltaX), dy: Float(-event.deltaY))
            return
        }
        guard drag == nil else { return }
        let point = convert(event.locationInWindow, from: nil)
        updateHoveredLayer(at: point)
        if isMeasuring || isPickingProjectorPoint {
            onMeasureHover?(pickSnapPoint(at: point), event.modifierFlags.contains(.shift))
        }
    }

    public override func mouseExited(with event: NSEvent) {
        if hoveredLayer != nil {
            hoveredLayer = nil
            onHoverLayer?(nil)
        }
        if isMeasuring || isPickingProjectorPoint {
            onMeasureHover?(nil, false)
        }
        super.mouseExited(with: event)
    }

    public override func mouseUp(with event: NSEvent) {
        let shiftPressed = event.modifierFlags.contains(.shift)
        let wasSingleClick = !didDragDuringMouseDown
            && event.clickCount == 1
            && !isFreeFlying
            && !event.modifierFlags.contains(.option)
            && (!shiftPressed || isMeasuring || isPickingProjectorPoint)
        if drag == .orbit || drag == .rotate2D {
            rig.release(time: event.timestamp)
        } else if drag == .pan {
            rig.releasePan(time: event.timestamp)
        }
        drag = nil
        if wasSingleClick {
            let point = convert(event.locationInWindow, from: nil)
            if isPickingProjectorPoint {
                if let snap = pickSnapPoint(at: point) {
                    onPickProjectorPoint?(snap)
                }
                return
            }
            if isMeasuring {
                if let snap = pickSnapPoint(at: point) {
                    onMeasureHover?(snap, shiftPressed)
                    onMeasureClick?(snap, shiftPressed)
                }
                return
            }
            if viewportScene?.model.fileInfo.isCAD == true, let picked = pickLayer(at: point) {
                hoveredLayer = picked
                onHoverLayer?(picked)
                onSelectLayer?(picked)
            }
        }
    }

    public override func rightMouseUp(with event: NSEvent) {
        if drag == .rotate2D {
            rig.release(time: event.timestamp)
        } else if drag == .pan {
            rig.releasePan(time: event.timestamp)
        }
        drag = nil
        if !isFreeFlying { releaseCursor() }
    }

    public override func otherMouseUp(with event: NSEvent) {
        if drag == .pan { rig.releasePan(time: event.timestamp) }
        drag = nil
    }

    private func dragged(_ event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if hypot(point.x - mouseDownPoint.x, point.y - mouseDownPoint.y) > 3.0 {
            didDragDuringMouseDown = true
        }
        let dx = Float(point.x - lastPoint.x), dy = Float(point.y - lastPoint.y)
        lastPoint = point
        if isFreeFlying || drag == .look {
            mouseLook(dx: Float(event.deltaX), dy: Float(-event.deltaY)) // the captured cursor does not move: deltas only
        } else if drag == .orbit {
            orbit(dx: dx, dy: dy, time: event.timestamp)
        } else if drag == .rotate2D {
            rotatePlan2D(dx: dx, dy: dy, time: event.timestamp)
        } else if drag == .pan {
            pan(dx: dx, dy: dy, time: event.timestamp)
        }
    }

    public override func scrollWheel(with event: NSEvent) {
        let notches = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / 14 : event.scrollingDeltaY
        if drag == .look {
            rig.speedScale = min(16, max(1.0 / 16, rig.speedScale * Float(pow(1.25, notches))))
            return
        }
        let point = convert(event.locationInWindow, from: nil)

        // Trackpad momentum phase: allowed for 2D pan, ⌥-pan, and two-finger scroll zoom so scrolling glides naturally.
        if !event.momentumPhase.isEmpty {
            guard allowScrollMomentum else { return }
            if event.momentumPhase == .ended || event.momentumPhase == .cancelled {
                allowScrollMomentum = false
                return
            }
            let dx = Float(event.scrollingDeltaX), dy = Float(-event.scrollingDeltaY)
            if Self.twoFingerScrollZooms {
                zoom(ratio: Float(pow(0.92, notches)), at: point, newGesture: false)
            } else if is2DNavigationMode {
                pan(dx: dx * 0.80, dy: dy * 0.80)
            } else if event.modifierFlags.contains(.option) {
                pan(dx: -dx * 0.80, dy: -dy * 0.80)
            }
            return
        }

        let gesture = event.hasPreciseScrollingDeltas && !event.phase.isEmpty
        guard gesture else {
            // Discrete mouse wheel: burst of notches less than 180 ms apart is one gesture, smoothed at 60–120 Hz.
            allowScrollMomentum = false
            let newGesture = event.timestamp - lastWheel > 0.18
            lastWheel = event.timestamp
            if newGesture { rig.stop() }
            smoothZoom(ratio: Float(pow(0.92, notches)), at: point, newGesture: newGesture)
            return
        }

        let option = event.modifierFlags.contains(.option)
        let isOrbitOrRotateGesture = (is2DNavigationMode && option)
            || (!is2DNavigationMode && !option && !Self.twoFingerScrollZooms)
        allowScrollMomentum = !isOrbitOrRotateGesture

        if event.phase == .began { rig.stop(); beginPivot(at: point) }
        // The end carries no motion: orbiting/panning by zero would zero the velocity before it can coast.
        if event.phase == .ended || event.phase == .cancelled {
            if isOrbitOrRotateGesture {
                rig.release(time: event.timestamp)
            } else if !Self.twoFingerScrollZooms {
                rig.releasePan(time: event.timestamp)
            }
            return
        }

        let dx = Float(event.scrollingDeltaX), dy = Float(-event.scrollingDeltaY)
        if is2DNavigationMode {
            if option {
                rotatePlan2D(dx: dx, dy: dy, time: event.timestamp)
            } else if Self.twoFingerScrollZooms {
                smoothZoom(ratio: Float(pow(0.92, notches)), at: point, newGesture: event.phase == .began)
            } else {
                pan(dx: dx * 0.82, dy: dy * 0.82, time: event.timestamp)
            }
        } else if option {
            pan(dx: -dx * 0.82, dy: -dy * 0.82, time: event.timestamp) // the model follows the fingers
        } else if Self.twoFingerScrollZooms {
            smoothZoom(ratio: Float(pow(0.92, notches)), at: point, newGesture: event.phase == .began)
        } else {
            orbit(dx: dx, dy: dy, time: event.timestamp)
        }
    }

    public override func magnify(with event: NSEvent) {
        allowScrollMomentum = false
        if event.phase == .began { rig.stop() }
        zoom(ratio: Float(1 / max(0.1, 1 + event.magnification)), at: convert(event.locationInWindow, from: nil),
             newGesture: event.phase == .began)
    }

    /// Two-finger rotation: yaw around the point under the fingers, never roll; the model turns with the fingers.
    public override func rotate(with event: NSEvent) {
        allowScrollMomentum = false
        if event.phase == .began { rig.stop(); beginPivot(at: convert(event.locationInWindow, from: nil)) }
        rig.orbit(yaw: -event.rotation * .pi / 180, pitch: 0)
    }

    // MARK: - Keyboard

    public override func keyDown(with event: NSEvent) {
        allowScrollMomentum = false
        rig.stop()
        if event.keyCode == 53, isFreeFlying { isFreeFlying = false; return } // Esc
        if event.keyCode == 53, isPickingProjectorPoint { onCancelProjectorPick?(); return } // Esc in projector pick
        if event.keyCode == 53, isMeasuring { onMeasureEscape?(); return } // Esc in measure tool
        if press(event) { return }
        let chars = event.charactersIgnoringModifiers?.lowercased()
        if chars == "h",
           event.modifierFlags.isDisjoint(with: [.command, .option, .control]),
           viewportScene?.model.fileInfo.isCAD == true {
            onHideSelectedLayer?()
            return
        }
        if chars == "z",
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
        removeMouseMovedMonitor()
        releaseInput()
        super.viewWillMove(toWindow: newWindow)
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        window.acceptsMouseMovedEvents = true
        NotificationCenter.default.addObserver(self, selector: #selector(windowResignedKey), name: NSWindow.didResignKeyNotification, object: window)
        installMouseMovedMonitor()
    }

    private func installMouseMovedMonitor() {
        guard mouseMovedMonitor == nil else { return }
        mouseMovedMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { [weak self] event in
            guard let self, let window = self.window, event.window === window, !self.isFreeFlying, self.drag == nil else {
                return event
            }
            let point = self.convert(event.locationInWindow, from: nil)
            if self.bounds.contains(point) {
                self.updateHoveredLayer(at: point)
                if self.isMeasuring {
                    self.onMeasureHover?(self.pickSnapPoint(at: point), event.modifierFlags.contains(.shift))
                }
            } else {
                if self.hoveredLayer != nil {
                    self.hoveredLayer = nil
                    self.onHoverLayer?(nil)
                }
                if self.isMeasuring {
                    self.onMeasureHover?(nil, false)
                }
            }
            return event
        }
    }

    private func removeMouseMovedMonitor() {
        if let monitor = mouseMovedMonitor {
            NSEvent.removeMonitor(monitor)
            mouseMovedMonitor = nil
        }
    }

    @objc private func windowResignedKey(_ note: Notification) { releaseInput() }

    func releaseInput() {
        drag = nil
        allowScrollMomentum = false
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

    /// In-plane rotation of the 2D plan around the Z axis (`⌥`-drag in 2D CAD mode).
    func rotatePlan2D(dx: Float, dy: Float, time: TimeInterval? = nil) {
        let rate = orbitDegreesPerPoint * .pi / 180
        rig.orbit(yaw: -dx * rate, pitch: 0, time: time)
    }

    /// Mouse right turns right, mouse up looks up; the eye stays.
    func mouseLook(dx: Float, dy: Float) {
        let rate = lookDegreesPerPoint * .pi / 180
        rig.look(yaw: -dx * rate, pitch: dy * rate)
    }

    /// The model follows the cursor about 1:1 at the pivot's depth.
    func pan(dx: Float, dy: Float, time: TimeInterval? = nil) {
        let metresPerPoint = visibleHeight / Float(max(1, bounds.height))
        let delta = -(rig.pose.right * dx + rig.pose.up * dy) * metresPerPoint
        rig.pose.position += delta
        rig.recordPan(delta: delta, time: time)
    }

    /// Applies an immediate 40 % zoom step so motion starts with zero latency, and glides the remaining 60 % smoothly at 60–120 Hz.
    func smoothZoom(ratio: Float, at point: CGPoint, newGesture: Bool = true) {
        guard ratio.isFinite, ratio > 0.05, ratio < 20.0 else { return }
        let immediate = pow(ratio, 0.40)
        let deferred = pow(ratio, 0.60)
        zoom(ratio: immediate, at: point, newGesture: newGesture)
        rig.addZoomInertia(ratio: deferred, at: point)
    }

    /// ratio < 1 zooms in (distance or ortho height multiplied by ratio), towards `point`.
    /// Perspective: the step is a fraction of the depth under the cursor (hit tested once per gesture), so it never
    /// crosses a wall. Parallel: the camera slides towards the cursor so the point under it stays put.
    func zoom(ratio: Float, at point: CGPoint, newGesture: Bool = true) {
        if camera.usesOrthographicProjection {
            let metresPerPoint = visibleHeight / Float(max(1, bounds.height))
            let dx = Float(point.x - bounds.midX) * metresPerPoint, dy = Float(point.y - bounds.midY) * metresPerPoint
            SCNTransaction.begin()
            SCNTransaction.animationDuration = 0
            camera.orthographicScale *= Double(ratio)
            SCNTransaction.commit()
            let delta = (rig.pose.right * dx + rig.pose.up * dy) * (1 - ratio)
            if simd_length_squared(delta) > 0 {
                rig.pose.position += delta
            } else {
                refreshMeasurementCamera()
                setNeedsDisplay(bounds)
                onPoseChange?(rig.pose.yaw, rig.pose.pitch, rig.speed)
            }
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
        if let faceHit = root.hitTestWithSegment(
            from: SCNVector3(from),
            to: SCNVector3(to),
            options: [SCNHitTestOption.backFaceCulling.rawValue: false, SCNHitTestOption.categoryBitMask.rawValue: 1]
        ).first {
            return worldToModel(SIMD3<Float>(faceHit.worldCoordinates))
        }
        // Pure-edge / 2D CAD plan fallback: intersect the ray with the model's mid-Z plane so zoom-to-cursor,
        // double-click recentre and orbit pivot work seamlessly when there are no faces under the cursor.
        if let model = viewportScene?.model, (model.stats.faces == 0 || model.isPlanar2D), abs(direction.z) > 1e-5 {
            let planeZ = (bounds.min.z + bounds.max.z) * 0.5
            let t = (planeZ - from.z) / direction.z
            if t > 0, t <= reach {
                return from + direction * t
            }
        }
        return nil
    }

    /// Picks the layer index in `model.layers` of the visible face or edge under `point` in view coordinates.
    public func pickLayer(at point: CGPoint, screenRadiusPoints: Float = 12.0) -> Int? {
        guard let scene = viewportScene else { return nil }
        let bounds = scene.visibleBounds
        let pose = rig.pose
        let reach = simd_distance(pose.position, (bounds.min + bounds.max) / 2) + simd_distance(bounds.min, bounds.max)
        let viewHeight = Float(max(1, self.bounds.height))
        let metresPerPoint = visibleHeight / viewHeight
        var from = pose.position
        var direction = ray(through: point)
        let orthoTolerance: Float?
        if camera.usesOrthographicProjection {
            from += (pose.right * Float(point.x - self.bounds.midX) + pose.up * Float(point.y - self.bounds.midY)) * metresPerPoint
            direction = pose.forward
            orthoTolerance = metresPerPoint * screenRadiusPoints
        } else {
            orthoTolerance = nil
        }
        return scene.pickLayer(
            from: from,
            direction: direction,
            right: pose.right,
            up: pose.up,
            reach: max(reach, 1.0),
            orthoTolerance: orthoTolerance,
            tanHalfFOV: tanHalfFOV,
            viewportHeight: viewHeight,
            screenRadiusPoints: screenRadiusPoints
        )
    }

    func updateHoveredLayer(at point: CGPoint) {
        guard viewportScene?.model.fileInfo.isCAD == true else {
            if hoveredLayer != nil {
                hoveredLayer = nil
                onHoverLayer?(nil)
            }
            return
        }
        let picked = pickLayer(at: point)
        guard picked != hoveredLayer else { return }
        hoveredLayer = picked
        onHoverLayer?(picked)
    }

    /// Snaps the cursor at `point` (in view coordinates) to the nearest visible vertex, edge midpoint, edge segment, face, or 2D plane.
    public func pickSnapPoint(at point: CGPoint, screenRadiusPoints: Float = 13.0) -> MeasureSnap? {
        guard let scene = viewportScene else { return nil }
        let bounds = scene.visibleBounds
        let pose = rig.pose
        let reach = simd_distance(pose.position, (bounds.min + bounds.max) / 2) + simd_distance(bounds.min, bounds.max)
        let viewHeight = Float(max(1, self.bounds.height))
        let metresPerPoint = visibleHeight / viewHeight
        var from = pose.position
        var direction = ray(through: point)
        let orthoMPP: Float?
        if camera.usesOrthographicProjection {
            from += (pose.right * Float(point.x - self.bounds.midX) + pose.up * Float(point.y - self.bounds.midY)) * metresPerPoint
            direction = pose.forward
            orthoMPP = metresPerPoint
        } else {
            orthoMPP = nil
        }

        if let snapped = scene.pickSnapPoint(
            from: from,
            direction: direction,
            right: pose.right,
            up: pose.up,
            reach: max(reach, 1.0),
            metresPerPoint: orthoMPP,
            tanHalfFOV: tanHalfFOV,
            viewportHeight: viewHeight,
            screenRadiusPoints: screenRadiusPoints
        ) {
            return snapped
        }

        // Planar fallback for 2D CAD plans, pure-edge models, or when a first point reference Z is active
        let model = scene.model
        if (model.stats.faces == 0 || model.isPlanar2D || measureFallbackZ != nil), abs(direction.z) > 1e-5 {
            let planeZ = measureFallbackZ ?? ((bounds.min.z + bounds.max.z) * 0.5)
            let t = (planeZ - from.z) / direction.z
            if t > 0, t <= max(reach, 1.0) * 2.0 {
                return MeasureSnap(position: from + direction * t, kind: .plane)
            }
        }
        return nil
    }

    /// Projects a model-space point (metres, Z up) to top-left screen coordinates (`0...width × 0...height`) for SwiftUI overlays.
    public func projectModelPoint(_ point: SIMD3<Float>) -> CGPoint? {
        let w = max(1, Float(bounds.width)), h = max(1, Float(bounds.height))
        let rel = point - rig.pose.position
        let x = simd_dot(rel, rig.pose.right)
        let y = simd_dot(rel, rig.pose.up)
        let z = simd_dot(rel, rig.pose.forward)
        let halfH = h * 0.5
        if camera.usesOrthographicProjection {
            let scale = Float(camera.orthographicScale)
            guard scale > 1e-6 else { return nil }
            let sx = w * 0.5 + (x / scale) * halfH
            let sy = h * 0.5 - (y / scale) * halfH
            return CGPoint(x: CGFloat(sx), y: CGFloat(sy))
        } else {
            guard z > 1e-3 else { return nil }
            let tanHalf = tanHalfFOV
            guard tanHalf > 1e-6 else { return nil }
            let sx = w * 0.5 + (x / (z * tanHalf)) * halfH
            let sy = h * 0.5 - (y / (z * tanHalf)) * halfH
            return CGPoint(x: CGFloat(sx), y: CGFloat(sy))
        }
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
