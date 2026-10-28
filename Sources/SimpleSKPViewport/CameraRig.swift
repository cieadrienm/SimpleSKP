import QuartzCore
import SceneKit
import SimpleSKPCore

// Feel of the navigation (D6), to tune by hand.
/// Orbit (left drag, two fingers): degrees of turn per point.
let orbitDegreesPerPoint: Float = 0.4
/// Look around (right drag, free fly): degrees per point of mouse motion.
let lookDegreesPerPoint: Float = 0.15
/// Orbit inertia: angular speed × e^(−damping × seconds); 10/s leaves 2 % after 0.4 s.
let inertiaDamping: Float = 10

/// The one camera of a viewport (D6): an eye in model space (metres, Z up), a yaw around Z, a pitch, and the distance
/// to the orbit target straight ahead. No roll: the horizon stays level. Every change is written to the SceneKit node
/// (parented under the model root); a 60 Hz timer runs only while something moves (glide, inertia, held keys).
@MainActor
public final class CameraRig {
    nonisolated public static let defaultGlideDuration: Float = 0.35
    nonisolated public static let slowGlideDuration: Float = 3.5

    public struct Pose: Equatable, Sendable {
        public var position = SIMD3<Float>(0, 0, 0)
        public var yaw: Float = 0
        public var pitch: Float = 0
        public var distance: Float = 1

        public init(
            position: SIMD3<Float> = SIMD3<Float>(0, 0, 0),
            yaw: Float = 0,
            pitch: Float = 0,
            distance: Float = 1
        ) {
            self.position = position
            self.yaw = yaw
            self.pitch = pitch
            self.distance = distance
        }

        public var forward: SIMD3<Float> { SIMD3(cos(pitch) * cos(yaw), cos(pitch) * sin(yaw), sin(pitch)) }
        public var right: SIMD3<Float> { SIMD3(sin(yaw), -cos(yaw), 0) }
        public var up: SIMD3<Float> { simd_cross(right, forward) }
        public var target: SIMD3<Float> { position + forward * distance }
        /// Camera axes in model space (SceneKit cameras look down their −Z).
        public var basis: simd_float3x3 { simd_float3x3(right, up, -forward) }
    }

    /// Movement keys by physical position (`keyCode`): ZQSD on AZERTY is WASD on QWERTY.
    static let forwardKeys: Set<UInt16> = [13, 126], backKeys: Set<UInt16> = [1, 125]
    static let leftKeys: Set<UInt16> = [0, 123], rightKeys: Set<UInt16> = [2, 124]
    static let upKeys: Set<UInt16> = [49, 14], downKeys: Set<UInt16> = [8]
    static let moveKeys = forwardKeys.union(backKeys).union(leftKeys).union(rightKeys).union(upKeys).union(downKeys)

    let node: SCNNode
    var onChange: () -> Void = {}
    var pose = Pose() { didSet { write() } }
    /// Orbit centre of the current drag or inertia (model space); nil = the target.
    var pivot: SIMD3<Float>?

    var keys: Set<UInt16> = [] { didSet { startTicking() } }
    var fast = false
    /// When `true` (2D CAD plan), orbit is restricted to in-plane rotation around Z (`pitch = -π/2`) and keyboard arrows pan in the 2D plane.
    public var is2DMode = false
    /// Metres per second of the movement keys: from the model's size, times what the wheel chose while looking.
    var baseSpeed: Float = 1
    var speedScale: Float = 1
    var speed: Float { baseSpeed * speedScale * (fast ? 4 : 1) }

    private var spin = SIMD2<Float>.zero // yaw, pitch in rad/s
    private var lastOrbitTime: TimeInterval?
    private var panVelocity = SIMD3<Float>.zero // model-space metres/s
    private var lastPanTime: TimeInterval?
    private var zoomInertiaRatio: Float = 1.0
    private var zoomInertiaPoint: CGPoint = .zero
    var onZoomInertiaStep: ((Float, CGPoint) -> Void)?
    private var glide: (from: Pose, to: Pose, fromScale: Double, toScale: Double, elapsed: Float, duration: Float)?
    private var timer: Timer?
    private var lastTick: CFTimeInterval = 0

    init(node: SCNNode) { self.node = node }

    /// The destination pose when a glide animation is in progress, otherwise the current `pose`.
    public var targetPose: Pose { glide?.to ?? pose }

    /// The destination orthographic scale when a glide animation is in progress, otherwise the camera's current `orthographicScale`.
    public var targetOrthographicScale: Double { glide?.toScale ?? (node.camera?.orthographicScale ?? 1) }

    var isMoving: Bool {
        glide != nil
            || spin != .zero
            || simd_length(panVelocity) > 1e-3
            || abs(zoomInertiaRatio - 1.0) > 1e-3
            || !keys.intersection(Self.moveKeys).isEmpty
    }

    /// Model diagonal / 32 per second (4× slower than the initial diagonal / 8), kept within 0.125–12.5 m/s.
    func setSpeed(diagonal: Float) { baseSpeed = max(0.125, min(12.5, diagonal / 32)) }

    // MARK: Moves

    /// Rigid turn around `pivot` (or the target): the pivot keeps its place on screen. Pitch stops at ±89°, or at the
    /// current pitch when a standard view or file camera put it beyond (straight down).
    func orbit(yaw: Float, pitch: Float, time: TimeInterval? = nil) {
        let centre = pivot ?? pose.target
        let effectivePitch: Float = is2DMode ? 0 : pitch
        var next = pose
        next.yaw += yaw
        next.pitch = is2DMode ? (-.pi / 2) : clampedPitch(pose.pitch + effectivePitch)
        next.position = centre + next.basis * pose.basis.transpose * (pose.position - centre)
        pose = next
        guard let time else { return }
        // Synthetic events share one timestamp: count them a frame apart. Coalesced events closer than 1/120 s cannot fling.
        let dt = Float(lastOrbitTime.map { time - $0 } ?? 0)
        spin = SIMD2(yaw, effectivePitch) / (dt > 0 ? max(dt, 1 / 120) : 1 / 60)
        lastOrbitTime = time
    }

    /// End of an orbit drag or gesture: the turn coasts if the hand was still moving.
    func release(time: TimeInterval) {
        if let last = lastOrbitTime, time - last < 0.05 { startTicking() } else { spin = .zero }
        lastOrbitTime = nil
    }

    /// Records a model-space pan displacement (`delta`) so releasing a drag or gesture coasts smoothly.
    func recordPan(delta: SIMD3<Float>, time: TimeInterval?) {
        guard let time else {
            panVelocity = .zero
            lastPanTime = nil
            return
        }
        let dt = Float(lastPanTime.map { time - $0 } ?? 0)
        let instVelocity = delta / (dt > 0 ? max(dt, 1 / 120) : 1 / 60)
        panVelocity = simd_length(panVelocity) > 1e-4 ? (panVelocity * 0.45 + instVelocity * 0.55) : instVelocity
        lastPanTime = time
    }

    /// End of a pan drag or gesture: the translation coasts gently if the hand was still moving.
    func releasePan(time: TimeInterval) {
        if let last = lastPanTime, time - last < 0.05 { startTicking() } else { panVelocity = .zero }
        lastPanTime = nil
    }

    /// Accumulates a multiplicative zoom ratio to be interpolated smoothly over ~120 ms at 60–120 Hz.
    func addZoomInertia(ratio: Float, at point: CGPoint) {
        guard ratio.isFinite, ratio > 0.05, ratio < 20.0 else { return }
        zoomInertiaPoint = point
        zoomInertiaRatio = max(0.05, min(20.0, zoomInertiaRatio * ratio))
        startTicking()
    }

    func look(yaw: Float, pitch: Float) {
        pose.yaw += yaw
        pose.pitch = clampedPitch(pose.pitch + pitch)
    }

    private func clampedPitch(_ pitch: Float) -> Float {
        let limit = max(89 * .pi / 180, abs(pose.pitch))
        return min(max(pitch, -limit), limit)
    }

    /// Animates to `pose` (0.35 s ease-in-out by default) through the rig, so a click or a key can stop it midway.
    func glide(to target: Pose, orthographicScale: Double? = nil, duration: Float = 0.35) {
        spin = .zero
        panVelocity = .zero
        lastPanTime = nil
        zoomInertiaRatio = 1.0
        let scale = node.camera?.orthographicScale ?? 1
        glide = (pose, target, scale, orthographicScale ?? scale, 0, duration)
        startTicking()
    }

    func set(_ target: Pose, orthographicScale: Double? = nil) {
        stop()
        if let orthographicScale {
            SCNTransaction.begin()
            SCNTransaction.animationDuration = 0
            node.camera?.orthographicScale = orthographicScale
            SCNTransaction.commit()
        }
        pose = target
    }

    /// Interruption: glide and inertia stop where they are; held keys keep moving.
    func stop() {
        glide = nil
        spin = .zero
        lastOrbitTime = nil
        panVelocity = .zero
        lastPanTime = nil
        zoomInertiaRatio = 1.0
    }

    // MARK: Conversions

    /// Yaw and pitch looking along `forward` with the screen's `up`: the yaw comes from the screen's right, so a plan view
    /// tilted past vertical (forward slightly south, up north) keeps its up with a pitch beyond ±90° instead of turning 180°.
    static func orientation(forward: SIMD3<Float>, up: SIMD3<Float>) -> (yaw: Float, pitch: Float) {
        let f = simd_normalize(forward)
        var r = simd_cross(f, up)
        r.z = 0 // a roll is dropped
        if simd_length(r) < 1e-4 { r = SIMD3(f.y, -f.x, 0) } // up along forward (a broken camera): right from forward alone
        let yaw = simd_length(r) < 1e-6 ? 0 : atan2(r.x, -r.y)
        return (yaw, atan2(f.z, f.x * cos(yaw) + f.y * sin(yaw)))
    }

    /// The file's camera, roll dropped (D6).
    static func pose(_ camera: SKPModel.Camera) -> Pose {
        let (yaw, pitch) = orientation(forward: camera.target - camera.position, up: camera.up)
        return Pose(position: camera.position, yaw: yaw, pitch: pitch, distance: max(simd_distance(camera.target, camera.position), 1e-3))
    }

    // MARK: Time

    /// One frame of glide, inertia and held keys (called by the timer; by the tests directly).
    func step(dt: Float) {
        if var g = glide {
            g.elapsed += dt
            let t = min(1, g.elapsed / g.duration), s = t * t * (3 - 2 * t)
            var p = g.to
            var dyaw = remainder(g.to.yaw - g.from.yaw, 2 * .pi) // the short way round
            if !dyaw.isFinite { dyaw = 0 }
            p.yaw = g.from.yaw + dyaw * s
            p.pitch = g.from.pitch + (g.to.pitch - g.from.pitch) * s
            p.position = g.from.position + (g.to.position - g.from.position) * s
            p.distance = g.from.distance + (g.to.distance - g.from.distance) * s
            SCNTransaction.begin()
            SCNTransaction.animationDuration = 0
            node.camera?.orthographicScale = g.fromScale + (g.toScale - g.fromScale) * Double(s)
            SCNTransaction.commit()
            glide = t < 1 ? g : nil
            pose = p
        }
        if spin != .zero {
            let s = spin * dt
            orbit(yaw: s.x, pitch: s.y)
            spin *= exp(-inertiaDamping * dt)
            if simd_length(spin) < 0.01 { spin = .zero }
        }
        if simd_length(panVelocity) > 1e-3 {
            pose.position += panVelocity * dt
            panVelocity *= exp(-11.0 * dt)
            if simd_length(panVelocity) <= 1e-3 { panVelocity = .zero }
        }
        if abs(zoomInertiaRatio - 1.0) > 1e-3 {
            let alpha = min(1.0, 1.0 - exp(-16.0 * dt))
            let stepRatio = pow(zoomInertiaRatio, alpha)
            zoomInertiaRatio = pow(zoomInertiaRatio, 1.0 - alpha)
            if abs(zoomInertiaRatio - 1.0) <= 1e-3 { zoomInertiaRatio = 1.0 }
            onZoomInertiaStep?(stepRatio, zoomInertiaPoint)
        }
        let held = keys
        if !held.isDisjoint(with: Self.moveKeys) {
            func axis(_ plus: Set<UInt16>, _ minus: Set<UInt16>) -> Float {
                (held.isDisjoint(with: plus) ? 0 : 1) - (held.isDisjoint(with: minus) ? 0 : 1)
            }
            let forwardAxis = is2DMode ? pose.up : pose.forward
            let verticalAxis = is2DMode ? SIMD3<Float>.zero : SIMD3<Float>(0, 0, 1)
            let move = forwardAxis * axis(Self.forwardKeys, Self.backKeys) + pose.right * axis(Self.rightKeys, Self.leftKeys)
                + verticalAxis * axis(Self.upKeys, Self.downKeys)
            if simd_length(move) > 0 { pose.position += simd_normalize(move) * speed * dt }
        }
    }

    private func startTicking() {
        guard timer == nil, isMoving else { return }
        lastTick = CACurrentMediaTime()
        let fps = Double(max(60, NSScreen.screens.map(\.maximumFramesPerSecond).max() ?? 60))
        let timer = Timer(timeInterval: 1.0 / fps, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            MainActor.assumeIsolated { self.tick() }
        }
        RunLoop.main.add(timer, forMode: .common) // keeps running during drags and menu tracking
        self.timer = timer
    }

    private func tick() {
        let now = CACurrentMediaTime()
        step(dt: Float(min(now - lastTick, 0.1)))
        lastTick = now
        if !isMoving {
            timer?.invalidate()
            timer = nil
        }
    }

    private func write() {
        SCNTransaction.begin()
        SCNTransaction.animationDuration = 0
        node.simdPosition = pose.position
        node.simdOrientation = simd_quatf(pose.basis)
        SCNTransaction.commit()
        onChange()
    }
}
