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
    /// Metres per second of the movement keys: from the model's size, times what the wheel chose while looking.
    var baseSpeed: Float = 1
    var speedScale: Float = 1
    var speed: Float { baseSpeed * speedScale * (fast ? 4 : 1) }

    private var spin = SIMD2<Float>.zero // yaw, pitch in rad/s
    private var lastOrbitTime: TimeInterval?
    private var glide: (from: Pose, to: Pose, fromScale: Double, toScale: Double, elapsed: Float, duration: Float)?
    private var timer: Timer?
    private var lastTick: CFTimeInterval = 0

    init(node: SCNNode) { self.node = node }

    var isMoving: Bool { glide != nil || spin != .zero || !keys.intersection(Self.moveKeys).isEmpty }

    /// Model diagonal / 8 per second, kept within 0.5–50 m/s.
    func setSpeed(diagonal: Float) { baseSpeed = max(0.5, min(50, diagonal / 8)) }

    // MARK: Moves

    /// Rigid turn around `pivot` (or the target): the pivot keeps its place on screen. Pitch stops at ±89°, or at the
    /// current pitch when a standard view or file camera put it beyond (straight down).
    func orbit(yaw: Float, pitch: Float, time: TimeInterval? = nil) {
        let centre = pivot ?? pose.target
        var next = pose
        next.yaw += yaw
        next.pitch = clampedPitch(pose.pitch + pitch)
        next.position = centre + next.basis * pose.basis.transpose * (pose.position - centre)
        pose = next
        guard let time else { return }
        // Synthetic events share one timestamp: count them a frame apart. Coalesced events closer than 1/120 s cannot fling.
        let dt = Float(lastOrbitTime.map { time - $0 } ?? 0)
        spin = SIMD2(yaw, pitch) / (dt > 0 ? max(dt, 1 / 120) : 1 / 60)
        lastOrbitTime = time
    }

    /// End of an orbit drag or gesture: the turn coasts if the hand was still moving.
    func release(time: TimeInterval) {
        if let last = lastOrbitTime, time - last < 0.05 { startTicking() } else { spin = .zero }
        lastOrbitTime = nil
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
        let scale = node.camera?.orthographicScale ?? 1
        glide = (pose, target, scale, orthographicScale ?? scale, 0, duration)
        startTicking()
    }

    func set(_ target: Pose, orthographicScale: Double? = nil) {
        stop()
        if let orthographicScale { node.camera?.orthographicScale = orthographicScale }
        pose = target
    }

    /// Interruption: glide and inertia stop where they are; held keys keep moving.
    func stop() {
        glide = nil
        spin = .zero
        lastOrbitTime = nil
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
            node.camera?.orthographicScale = g.fromScale + (g.toScale - g.fromScale) * Double(s)
            glide = t < 1 ? g : nil
            pose = p
        }
        if spin != .zero {
            let s = spin * dt
            orbit(yaw: s.x, pitch: s.y)
            spin *= exp(-inertiaDamping * dt)
            if simd_length(spin) < 0.01 { spin = .zero }
        }
        let held = keys
        if !held.isDisjoint(with: Self.moveKeys) {
            func axis(_ plus: Set<UInt16>, _ minus: Set<UInt16>) -> Float {
                (held.isDisjoint(with: plus) ? 0 : 1) - (held.isDisjoint(with: minus) ? 0 : 1)
            }
            let move = pose.forward * axis(Self.forwardKeys, Self.backKeys) + pose.right * axis(Self.rightKeys, Self.leftKeys)
                + SIMD3(0, 0, 1) * axis(Self.upKeys, Self.downKeys)
            if simd_length(move) > 0 { pose.position += simd_normalize(move) * speed * dt }
        }
    }

    private func startTicking() {
        guard timer == nil, isMoving else { return }
        lastTick = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
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
        node.simdPosition = pose.position
        node.simdOrientation = simd_quatf(pose.basis)
        onChange()
    }
}
