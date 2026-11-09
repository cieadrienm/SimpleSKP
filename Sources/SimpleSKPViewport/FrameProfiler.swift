import Foundation
import Metal
import os
import QuartzCore
import SimpleSKPCore

/// Permanent, near-zero-cost frame profiler modeled after eMotion's `eMotionProfiler` (Chantier 08).
///
/// - When disabled (`isEnabled == false`): a single lock-free atomic load on hot-path zone calls;
///   only the rolling 1-second frame counter (`framesInLastSecond`) is updated on frame completion.
/// - When enabled (`isEnabled == true`): accumulates per-zone wall-clock time (`mach_absolute_time`)
///   over each rendered frame and folds it at `frameEnd()` into a 240-frame ring buffer to report
///   `lastMs`, `p50Ms`, `p95Ms`, `maxMs`, and `frames`.
public final class FrameProfiler: @unchecked Sendable {
    public static let shared = FrameProfiler()

    public static let maxZones = 96
    public static let ringFrames = 240

    public typealias ZoneStats = ZoneStat

    public struct ZoneStat: Sendable, Equatable, Identifiable {
        public var id: String { name }
        public let name: String
        public let lastMs: Float
        public let p50Ms: Float
        public let p95Ms: Float
        public let maxMs: Float
        public let frames: Int
        public var samples: Int { frames }

        public init(name: String, lastMs: Float, p50Ms: Float, p95Ms: Float, maxMs: Float, frames: Int) {
            self.name = name
            self.lastMs = lastMs
            self.p50Ms = p50Ms
            self.p95Ms = p95Ms
            self.maxMs = maxMs
            self.frames = frames
        }
    }

    private final class ZoneEntry {
        let name: String
        var frameMachAccumulator: UInt64 = 0
        var ringMs: [Float] = Array(repeating: 0.0, count: FrameProfiler.ringFrames)
        var lastMs: Float = 0.0

        init(name: String) {
            self.name = name
        }
    }

    private let lock = OSAllocatedUnfairLock()
    private var enabledFlag: Bool = false
    private var zones: [ZoneEntry] = []
    private var zoneIndexByName: [String: Int] = [:]
    private var ringIndex: Int = 0
    private var totalFramesRecorded: Int = 0
    private var lastFrameEndMach: UInt64 = 0
    private var recentFrameTimestamps: [TimeInterval] = []
    private var lastActiveMeasuredFPS: Double = 0.0
    private let machToMs: Double

    /// Pre-registered canonical zone indices for fast lookup.
    public let zoneFrameTotal: Int
    public let zoneFramePeriod: Int
    public let zoneDLTick: Int
    public let zoneGPURender: Int
    public let zoneFrameWork: Int
    public let zoneRenderScene: Int
    public let zonePresentDrawable: Int
    public let zoneSyphonPublish: Int
    public let zoneOSCUpdate: Int
    public let zoneRigStep: Int
    public let zoneVPDepthMap: Int
    public let zoneVPBounce: Int
    public let zoneVPFrustum: Int
    public let zoneVPLiveVideo: Int
    public let zoneRaycastPick: Int

    private init() {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        let numer = Double(max(1, tb.numer))
        let denom = Double(max(1, tb.denom))
        self.machToMs = (numer / denom) * 1e-6

        var initialZones: [ZoneEntry] = []
        var initialMap: [String: Int] = [:]
        func reg(_ name: String) -> Int {
            let idx = initialZones.count
            initialZones.append(ZoneEntry(name: name))
            initialMap[name] = idx
            return idx
        }

        self.zoneFrameTotal = reg("frame.total")
        self.zoneFramePeriod = reg("frame.period")
        self.zoneDLTick = reg("dl.tick")
        self.zoneGPURender = reg("gpu.render")
        self.zoneFrameWork = reg("frame.work")
        self.zoneRenderScene = reg("render.scene")
        self.zonePresentDrawable = reg("present.drawable")
        self.zoneSyphonPublish = reg("syphon.publish")
        self.zoneOSCUpdate = reg("osc.update")
        self.zoneRigStep = reg("rig.step")
        self.zoneVPDepthMap = reg("vp.depthMap")
        self.zoneVPBounce = reg("vp.bounce")
        self.zoneVPFrustum = reg("vp.frustum")
        self.zoneVPLiveVideo = reg("vp.liveVideo")
        self.zoneRaycastPick = reg("raycast.pick")

        self.zones = initialZones
        self.zoneIndexByName = initialMap
        self.enabledFlag = UserDefaults.standard.bool(forKey: "SimpleSKPProfilerEnabled")
    }

    public var isEnabled: Bool {
        get { lock.withLock { enabledFlag } }
        set {
            lock.withLock {
                enabledFlag = newValue
            }
            UserDefaults.standard.set(newValue, forKey: "SimpleSKPProfilerEnabled")
        }
    }

    /// Returns `mach_absolute_time()` when enabled, or `0` immediately when disabled.
    @inline(__always)
    public func begin() -> UInt64 {
        guard isEnabled else { return 0 }
        return mach_absolute_time()
    }

    /// Accumulates elapsed time since `startMach` into the given pre-registered zone index.
    @inline(__always)
    public func end(zone: Int, startMach: UInt64) {
        guard startMach != 0 else { return }
        let delta = mach_absolute_time() &- startMach
        addMach(zone: zone, machDelta: delta)
    }

    /// Measures a synchronous block into the given pre-registered zone index.
    @inline(__always)
    public func measure<T>(zone: Int, _ body: () throws -> T) rethrows -> T {
        let t0 = begin()
        defer {
            if t0 != 0 {
                end(zone: zone, startMach: t0)
            }
        }
        return try body()
    }

    /// Finds or registers a zone by name and returns its index (`-1` if full).
    public func zoneNamed(_ name: String) -> Int {
        lock.withLock {
            if let existing = zoneIndexByName[name] {
                return existing
            }
            guard zones.count < Self.maxZones else { return -1 }
            let idx = zones.count
            zones.append(ZoneEntry(name: name))
            zoneIndexByName[name] = idx
            return idx
        }
    }

    public func addMach(zone: Int, machDelta: UInt64) {
        guard zone >= 0 else { return }
        lock.withLock {
            guard enabledFlag, zone < zones.count else { return }
            zones[zone].frameMachAccumulator &+= machDelta
        }
    }

    public func addMilliseconds(zone: Int, ms: Double) {
        guard zone >= 0, ms > 0.0, machToMs > 0.0 else { return }
        let machDelta = UInt64((ms / machToMs) + 0.5)
        addMach(zone: zone, machDelta: machDelta)
    }

    public func addSeconds(zone: Int, seconds: Double) {
        addMilliseconds(zone: zone, ms: seconds * 1000.0)
    }

    public func recordDuration(seconds: Double, for name: String) {
        guard seconds > 0.0, machToMs > 0.0 else { return }
        lock.withLock {
            guard enabledFlag else { return }
            let idx: Int
            if let existing = zoneIndexByName[name] {
                idx = existing
            } else {
                guard zones.count < Self.maxZones else { return }
                idx = zones.count
                zones.append(ZoneEntry(name: name))
                zoneIndexByName[name] = idx
            }
            let machDelta = UInt64(((seconds * 1000.0) / machToMs) + 0.5)
            zones[idx].frameMachAccumulator &+= machDelta
        }
    }

    public func frameEnd(totalSeconds: Double, now: TimeInterval = CACurrentMediaTime()) {
        if totalSeconds > 0.0 {
            addSeconds(zone: zoneFrameTotal, seconds: totalSeconds)
        }
        frameEnd(at: now, frameStartMach: 0)
    }

    /// Records a directly measured GPU render duration into the ring buffer asynchronously (since `MTLCommandBuffer`
    /// completion handlers may fire slightly after `frameEnd()`).
    public func recordAsyncGPUDuration(seconds: Double) {
        guard seconds > 0.0 else { return }
        let ms = Float(seconds * 1000.0)
        lock.withLock {
            guard enabledFlag, zoneGPURender < zones.count else { return }
            let entry = zones[zoneGPURender]
            let prevSlot = (ringIndex - 1 + Self.ringFrames) % Self.ringFrames
            entry.ringMs[prevSlot] = ms
            entry.lastMs = ms
        }
    }

    /// Resets all zone ring buffers and frame counters.
    public func reset() {
        lock.withLock {
            for z in zones {
                z.frameMachAccumulator = 0
                for i in 0..<Self.ringFrames {
                    z.ringMs[i] = 0.0
                }
                z.lastMs = 0.0
            }
            ringIndex = 0
            totalFramesRecorded = 0
            lastFrameEndMach = 0
            lastActiveMeasuredFPS = 0.0
        }
    }

    /// Called once per rendered frame (from `ViewportView`). Always updates the rolling 1-second FPS counter,
    /// and folds per-zone timings into the 240-frame ring when `isEnabled == true`.
    public func frameEnd(at now: TimeInterval = CACurrentMediaTime(), frameStartMach: UInt64 = 0) {
        let nowMach = mach_absolute_time()
        lock.withLock {
            // 1. Rolling 1-second FPS tracking (always active, near-zero cost)
            recentFrameTimestamps.append(now)
            let cutoff = now - 1.0
            if let firstValid = recentFrameTimestamps.firstIndex(where: { $0 >= cutoff }) {
                if firstValid > 0 {
                    recentFrameTimestamps.removeFirst(firstValid)
                }
            } else {
                recentFrameTimestamps.removeAll(keepingCapacity: true)
            }
            let countInWindow = recentFrameTimestamps.count
            if countInWindow >= 2,
               let first = recentFrameTimestamps.first,
               let last = recentFrameTimestamps.last,
               last - first >= 0.12 {
                lastActiveMeasuredFPS = Double(countInWindow - 1) / (last - first)
            } else if countInWindow > 0 {
                lastActiveMeasuredFPS = Double(countInWindow)
            }

            // 2. Detailed zone ring folding when profiler is enabled
            guard enabledFlag else {
                lastFrameEndMach = nowMach
                return
            }

            if frameStartMach != 0, nowMach >= frameStartMach {
                zones[zoneFrameTotal].frameMachAccumulator &+= (nowMach &- frameStartMach)
            }

            if lastFrameEndMach != 0, nowMach > lastFrameEndMach {
                let periodDelta = nowMach &- lastFrameEndMach
                let periodMs = Double(periodDelta) * machToMs
                // Ignore idle gaps > 500 ms (since SimpleSKP renders on demand when stationary)
                if periodMs < 500.0 {
                    zones[zoneFramePeriod].frameMachAccumulator = periodDelta
                }
            }
            lastFrameEndMach = nowMach

            let totalMach = zones[zoneFrameTotal].frameMachAccumulator
            let drawMach = zones[zonePresentDrawable].frameMachAccumulator
            zones[zoneFrameWork].frameMachAccumulator = totalMach > drawMach ? (totalMach - drawMach) : 0

            let slot = ringIndex
            for i in 0..<zones.count {
                let mach = zones[i].frameMachAccumulator
                zones[i].frameMachAccumulator = 0
                let ms = Float(Double(mach) * machToMs)
                // Keep previous gpu.render sample if it was written asynchronously via recordAsyncGPUDuration
                if i == zoneGPURender && ms == 0.0 {
                    zones[i].ringMs[slot] = 0.0
                } else {
                    zones[i].ringMs[slot] = ms
                    if ms > 0.0 || i != zoneGPURender {
                        zones[i].lastMs = ms
                    }
                }
            }
            ringIndex = (ringIndex + 1) % Self.ringFrames
            totalFramesRecorded += 1
        }
    }

    /// Number of frames rendered during the last 1.0 second (`0` when stationary for > 1 s).
    public func framesInLastSecond(at now: TimeInterval = CACurrentMediaTime()) -> Int {
        lock.withLock {
            let cutoff = now - 1.0
            if let firstValid = recentFrameTimestamps.firstIndex(where: { $0 >= cutoff }) {
                if firstValid > 0 {
                    recentFrameTimestamps.removeFirst(firstValid)
                }
            } else {
                recentFrameTimestamps.removeAll(keepingCapacity: true)
            }
            return recentFrameTimestamps.count
        }
    }

    /// Instantaneous or last-measured cadence FPS for the profiler header and Markdown export.
    public func profilerDisplayFPS(at now: TimeInterval = CACurrentMediaTime()) -> Double {
        let liveCount = framesInLastSecond(at: now)
        return lock.withLock {
            if liveCount >= 2,
               let first = recentFrameTimestamps.first,
               let last = recentFrameTimestamps.last,
               last - first >= 0.15 {
                return Double(liveCount - 1) / (last - first)
            }
            if liveCount > 0 {
                return Double(liveCount)
            }
            // When stationary after a movement, derive FPS from frame.period p50 so the user can read/copy the report
            let periodRing = zones[zoneFramePeriod].ringMs.filter { $0 > 0.0 }.sorted()
            if !periodRing.isEmpty {
                let p50 = Double(periodRing[periodRing.count / 2])
                if p50 > 0.1 {
                    return min(240.0, 1000.0 / p50)
                }
            }
            return lastActiveMeasuredFPS
        }
    }

    /// Copies and sorts the current zone statistics (`frame.total` first, then by `p95Ms` descending).
    public func copyStats(includeZeroZones: Bool = false) -> [ZoneStat] {
        lock.withLock {
            var result: [ZoneStat] = []
            result.reserveCapacity(zones.count)

            for z in zones {
                var nonZero: [Float] = []
                nonZero.reserveCapacity(Self.ringFrames)
                for v in z.ringMs where v > 0.0 {
                    nonZero.append(v)
                }
                let n = nonZero.count
                if n == 0 && !includeZeroZones && z.name != "frame.total" && z.name != "present.drawable" {
                    continue
                }
                let p50: Float
                let p95: Float
                let maxV: Float
                if n > 0 {
                    nonZero.sort()
                    p50 = nonZero[n / 2]
                    p95 = nonZero[Int(Float(n - 1) * 0.95)]
                    maxV = nonZero[n - 1]
                } else {
                    p50 = 0.0
                    p95 = 0.0
                    maxV = 0.0
                }
                result.append(ZoneStat(
                    name: z.name,
                    lastMs: z.lastMs,
                    p50Ms: p50,
                    p95Ms: p95,
                    maxMs: maxV,
                    frames: n
                ))
            }

            result.sort { a, b in
                let aTotal = (a.name == "frame.total")
                let bTotal = (b.name == "frame.total")
                if aTotal != bTotal { return aTotal }
                if a.p95Ms != b.p95Ms { return a.p95Ms > b.p95Ms }
                return a.name < b.name
            }
            return result
        }
    }

    /// Formats the current profiler table as Markdown (identical to eMotion's `eMotionProfilerPanel -markdownTable`).
    public func markdownTable(now: TimeInterval = CACurrentMediaTime()) -> String {
        let rows = copyStats()
        let fps = profilerDisplayFPS(at: now)
        let windowFrames = rows.first(where: { $0.name == "frame.total" })?.frames ?? Self.ringFrames
        var md = "| Zone | p50 ms | p95 ms | max ms | frames |\n|---|---|---|---|---|\n"
        for row in rows {
            md += String(
                format: "| %@ | %.3f | %.3f | %.3f | %d |\n",
                row.name,
                row.p50Ms,
                row.p95Ms,
                row.maxMs,
                row.frames
            )
        }
        md += String(format: "\n> %.1f fps, fenêtre %d frames rendues.\n", fps, windowFrames > 0 ? windowFrames : Self.ringFrames)
        return md
    }
}
