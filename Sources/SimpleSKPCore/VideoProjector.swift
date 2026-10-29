import Foundation
import simd

/// Optical and physical specification of a video projector model.
public struct ProjectorSpec: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var manufacturer: String
    public var model: String
    /// Native horizontal resolution in pixels (e.g. 1920 for WUXGA).
    public var nativeWidth: Int
    /// Native vertical resolution in pixels (e.g. 1200 for WUXGA).
    public var nativeHeight: Int
    /// Minimum throw ratio (`distance / imageWidth`), e.g. `0.65` for Optoma ZU920ST at max zoom.
    public var minThrowRatio: Float
    /// Maximum throw ratio (`distance / imageWidth`), e.g. `0.75` for Optoma ZU920ST at min zoom.
    public var maxThrowRatio: Float
    /// Default throw ratio when creating a new projector of this model.
    public var defaultThrowRatio: Float
    /// Maximum horizontal lens shift as a fraction of projected image width (`0.25` = `±25 %`).
    public var maxLensShiftH: Float
    /// Maximum vertical lens shift as a fraction of projected image height (`0.55` = `±55 %`).
    public var maxLensShiftV: Float
    /// Nominal light output in ANSI lumens.
    public var lumens: Int
    /// Physical chassis dimensions `(width X, depth Y, height Z)` in metres.
    public var bodySize: SIMD3<Float>

    public var aspectRatio: Float {
        Float(max(1, nativeWidth)) / Float(max(1, nativeHeight))
    }

    public var displayName: String {
        "\(manufacturer) \(model)"
    }

    public var resolutionLabel: String {
        let ratio = abs(aspectRatio - 1.6) < 0.02 ? "16:10 WUXGA" : (abs(aspectRatio - 16.0 / 9.0) < 0.02 ? "16:9 UHD/HD" : String(format: "%.2f:1", aspectRatio))
        return "\(nativeWidth)×\(nativeHeight) (\(ratio))"
    }

    public init(
        id: String,
        manufacturer: String,
        model: String,
        nativeWidth: Int,
        nativeHeight: Int,
        minThrowRatio: Float,
        maxThrowRatio: Float,
        defaultThrowRatio: Float,
        maxLensShiftH: Float,
        maxLensShiftV: Float,
        lumens: Int,
        bodySize: SIMD3<Float>
    ) {
        self.id = id
        self.manufacturer = manufacturer
        self.model = model
        self.nativeWidth = nativeWidth
        self.nativeHeight = nativeHeight
        self.minThrowRatio = minThrowRatio
        self.maxThrowRatio = maxThrowRatio
        self.defaultThrowRatio = defaultThrowRatio
        self.maxLensShiftH = maxLensShiftH
        self.maxLensShiftV = maxLensShiftV
        self.lumens = lumens
        self.bodySize = bodySize
    }

    /// Optoma ZU920ST — Short-throw WUXGA DuraCore laser projector (`9 800 lm`, `0.65–0.75:1`, `H ±25 %`, `V ±55 %`).
    public static let optomaZU920ST = ProjectorSpec(
        id: "optoma-zu920st",
        manufacturer: "Optoma",
        model: "ZU920ST",
        nativeWidth: 1920,
        nativeHeight: 1200,
        minThrowRatio: 0.65,
        maxThrowRatio: 0.75,
        defaultThrowRatio: 0.68,
        maxLensShiftH: 0.25,
        maxLensShiftV: 0.55,
        lumens: 9800,
        bodySize: SIMD3<Float>(0.486, 0.4325, 0.176)
    )

    /// Optoma ZU920T — Standard-throw WUXGA DuraCore laser projector (`9 800 lm`, `1.25–2.00:1`, `H ±25 %`, `V ±55 %`).
    public static let optomaZU920T = ProjectorSpec(
        id: "optoma-zu920t",
        manufacturer: "Optoma",
        model: "ZU920T",
        nativeWidth: 1920,
        nativeHeight: 1200,
        minThrowRatio: 1.25,
        maxThrowRatio: 2.00,
        defaultThrowRatio: 1.50,
        maxLensShiftH: 0.25,
        maxLensShiftV: 0.55,
        lumens: 9800,
        bodySize: SIMD3<Float>(0.486, 0.4325, 0.176)
    )

    /// Optoma ZU725TST — Short-throw WUXGA laser projector (`7 500 lm`, `0.65–0.75:1`, `H ±25 %`, `V ±55 %`).
    public static let optomaZU725TST = ProjectorSpec(
        id: "optoma-zu725tst",
        manufacturer: "Optoma",
        model: "ZU725TST",
        nativeWidth: 1920,
        nativeHeight: 1200,
        minThrowRatio: 0.65,
        maxThrowRatio: 0.75,
        defaultThrowRatio: 0.68,
        maxLensShiftH: 0.25,
        maxLensShiftV: 0.55,
        lumens: 7500,
        bodySize: SIMD3<Float>(0.486, 0.4325, 0.176)
    )

    /// Optoma ZU606TSTE — Short-throw WUXGA DuraCore laser projector (`6 300 lm`, fixed `0.79:1`, vertical lens shift `100–120 %` offset / `V ±60 %`).
    public static let optomaZU606TSTE = ProjectorSpec(
        id: "optoma-zu606tste",
        manufacturer: "Optoma",
        model: "ZU606TSTE",
        nativeWidth: 1920,
        nativeHeight: 1200,
        minThrowRatio: 0.79,
        maxThrowRatio: 0.79,
        defaultThrowRatio: 0.79,
        maxLensShiftH: 0.15,
        maxLensShiftV: 0.60,
        lumens: 6300,
        bodySize: SIMD3<Float>(0.374, 0.302, 0.117)
    )

    /// Optoma ZH450ST — Compact short-throw Full HD 1080p DuraCore laser projector (`4 200 lm`, fixed `0.496:1`, native offset `116 %` / `V ±66 %`).
    public static let optomaZH450ST = ProjectorSpec(
        id: "optoma-zh450st",
        manufacturer: "Optoma",
        model: "ZH450ST",
        nativeWidth: 1920,
        nativeHeight: 1080,
        minThrowRatio: 0.496,
        maxThrowRatio: 0.496,
        defaultThrowRatio: 0.496,
        maxLensShiftH: 0.15,
        maxLensShiftV: 0.66,
        lumens: 4200,
        bodySize: SIMD3<Float>(0.274, 0.216, 0.114)
    )

    /// Optoma ZH406ST — Short-throw Full HD 1080p DuraCore laser projector (`4 200 lm`, fixed `0.50:1`, native offset `115 %` / `V ±65 %`).
    public static let optomaZH406ST = ProjectorSpec(
        id: "optoma-zh406st",
        manufacturer: "Optoma",
        model: "ZH406ST",
        nativeWidth: 1920,
        nativeHeight: 1080,
        minThrowRatio: 0.50,
        maxThrowRatio: 0.50,
        defaultThrowRatio: 0.50,
        maxLensShiftH: 0.15,
        maxLensShiftV: 0.65,
        lumens: 4200,
        bodySize: SIMD3<Float>(0.337, 0.265, 0.1225)
    )
}

/// Extensible catalog of video projector models.
public enum ProjectorCatalog {
    public static let all: [ProjectorSpec] = [
        .optomaZU920ST,
        .optomaZU920T,
        .optomaZU725TST,
        .optomaZU606TSTE,
        .optomaZH450ST,
        .optomaZH406ST,
    ]

    public static func spec(for id: String) -> ProjectorSpec {
        all.first(where: { $0.id == id }) ?? .optomaZU920ST
    }
}

/// Visual test pattern or media projected by a `VideoProjector`.
public enum ProjectionPattern: String, Codable, CaseIterable, Sendable {
    case testGrid = "testGrid"
    case colorBars = "colorBars"
    case whiteFrame = "whiteFrame"
    case customImage = "customImage"
}

/// A virtual video projector placed in the 3D scene (model coordinates in metres, Z up).
public struct VideoProjector: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var specID: String
    public var isEnabled: Bool
    /// Optical center (lens position) in model space (metres, Z up).
    public var position: SIMD3<Float>
    /// Target point along the optical axis in model space (metres, Z up).
    public var target: SIMD3<Float>
    /// Roll angle around the optical axis in degrees (`0°` = landscape table mount, `180°` = ceiling mount, `±90°` = portrait).
    public var rollDegrees: Float
    /// Active throw ratio (`distance / imageWidth`), clamped to the model's zoom range.
    public var throwRatio: Float
    /// Horizontal lens shift as a fraction of projected width (`-0.25 ... +0.25` for Optoma ZU920ST).
    public var lensShiftH: Float
    /// Vertical lens shift as a fraction of projected height (`-0.55 ... +0.55` for Optoma ZU920ST).
    public var lensShiftV: Float
    /// Light output multiplier (`0.0 ... 3.0`, default `1.0`).
    public var intensity: Float
    /// Indirect reverberation / bounce multiplier (`0.0 ... 2.5`, default `1.0`).
    public var reverbIntensity: Float
    /// Selected projection pattern or custom image.
    public var pattern: ProjectionPattern
    /// File path to a custom projected image when `pattern == .customImage`.
    public var customImagePath: String?
    /// Whether to draw the 3D projector body and wireframe frustum in the viewport.
    public var showsFrustum: Bool

    private enum CodingKeys: String, CodingKey {
        case id, name, specID, isEnabled, position, target, rollDegrees, throwRatio, lensShiftH, lensShiftV, intensity, reverbIntensity, pattern, customImagePath, showsFrustum
    }

    public init(
        id: UUID = UUID(),
        name: String,
        specID: String = ProjectorSpec.optomaZU920ST.id,
        isEnabled: Bool = true,
        position: SIMD3<Float>,
        target: SIMD3<Float>,
        rollDegrees: Float = 0,
        throwRatio: Float? = nil,
        lensShiftH: Float = 0,
        lensShiftV: Float = 0,
        intensity: Float = 1.0,
        reverbIntensity: Float = 1.0,
        pattern: ProjectionPattern = .testGrid,
        customImagePath: String? = nil,
        showsFrustum: Bool = true
    ) {
        let resolvedSpec = ProjectorCatalog.spec(for: specID)
        self.id = id
        self.name = name
        self.specID = resolvedSpec.id
        self.isEnabled = isEnabled
        self.position = position
        self.target = simd_distance(position, target) > 1e-4 ? target : (position + SIMD3<Float>(0, 5, 0))
        self.rollDegrees = rollDegrees
        let tr = throwRatio ?? resolvedSpec.defaultThrowRatio
        self.throwRatio = simd_clamp(tr, resolvedSpec.minThrowRatio, resolvedSpec.maxThrowRatio)
        self.lensShiftH = simd_clamp(lensShiftH, -resolvedSpec.maxLensShiftH, resolvedSpec.maxLensShiftH)
        self.lensShiftV = simd_clamp(lensShiftV, -resolvedSpec.maxLensShiftV, resolvedSpec.maxLensShiftV)
        self.intensity = max(0, min(3.0, intensity))
        self.reverbIntensity = max(0, min(2.5, reverbIntensity))
        self.pattern = pattern
        self.customImagePath = customImagePath
        self.showsFrustum = showsFrustum
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let id = try c.decode(UUID.self, forKey: .id)
        let name = try c.decode(String.self, forKey: .name)
        let specID = try c.decode(String.self, forKey: .specID)
        let isEnabled = try c.decode(Bool.self, forKey: .isEnabled)
        let position = try c.decode(SIMD3<Float>.self, forKey: .position)
        let target = try c.decode(SIMD3<Float>.self, forKey: .target)
        let rollDegrees = try c.decodeIfPresent(Float.self, forKey: .rollDegrees) ?? 0
        let throwRatio = try c.decode(Float.self, forKey: .throwRatio)
        let lensShiftH = try c.decode(Float.self, forKey: .lensShiftH)
        let lensShiftV = try c.decode(Float.self, forKey: .lensShiftV)
        let intensity = try c.decode(Float.self, forKey: .intensity)
        let reverbIntensity = try c.decodeIfPresent(Float.self, forKey: .reverbIntensity) ?? 1.0
        let pattern = try c.decode(ProjectionPattern.self, forKey: .pattern)
        let customImagePath = try c.decodeIfPresent(String.self, forKey: .customImagePath)
        let showsFrustum = try c.decode(Bool.self, forKey: .showsFrustum)
        self.init(
            id: id,
            name: name,
            specID: specID,
            isEnabled: isEnabled,
            position: position,
            target: target,
            rollDegrees: rollDegrees,
            throwRatio: throwRatio,
            lensShiftH: lensShiftH,
            lensShiftV: lensShiftV,
            intensity: intensity,
            reverbIntensity: reverbIntensity,
            pattern: pattern,
            customImagePath: customImagePath,
            showsFrustum: showsFrustum
        )
    }

    /// Luminous flux attenuation factor in `[0, 1]` as a function of the cosine of the incidence angle
    /// (`cosTheta = dot(surfaceNormal, toProjectorUnitRay)`):
    /// - `cosTheta = 1.0` (`0°`, surface normal to the beam): returns `1.0` (100% optimal flux).
    /// - `cosTheta -> 0.0` (`90°`, grazing incidence): smoothly approaches `0.0` via Lambert's cosine law + grazing obliquity falloff.
    public static func incidenceFluxFactor(cosTheta: Float) -> Float {
        guard cosTheta > 0.01 else { return 0.0 }
        let clamped = min(max(cosTheta, 0.0), 1.0)
        let t = min(max(clamped / 0.16, 0.0), 1.0)
        let smoothGrazing = t * t * (3.0 - 2.0 * t)
        return pow(clamped, 1.35) * smoothGrazing
    }

    public var spec: ProjectorSpec {
        ProjectorCatalog.spec(for: specID)
    }

    public mutating func applySpec(_ newSpec: ProjectorSpec) {
        let oldModel = spec.model
        specID = newSpec.id
        if name.hasSuffix("— \(oldModel)") {
            name = String(name.dropLast("— \(oldModel)".count)) + "— \(newSpec.model)"
        }
        if throwRatio < newSpec.minThrowRatio || throwRatio > newSpec.maxThrowRatio {
            throwRatio = newSpec.defaultThrowRatio
        } else {
            throwRatio = simd_clamp(throwRatio, newSpec.minThrowRatio, newSpec.maxThrowRatio)
        }
        lensShiftH = simd_clamp(lensShiftH, -newSpec.maxLensShiftH, newSpec.maxLensShiftH)
        lensShiftV = simd_clamp(lensShiftV, -newSpec.maxLensShiftV, newSpec.maxLensShiftV)
    }

    /// Distance in metres between the projector's lens (`position`) and `target`.
    public var throwDistance: Float {
        max(simd_distance(position, target), 0.05)
    }

    /// Projected image width in metres at distance `d` (defaults to `throwDistance`).
    public func projectedWidth(atDistance d: Float? = nil) -> Float {
        let dist = max(d ?? throwDistance, 0.05)
        return dist / max(throwRatio, 0.05)
    }

    /// Projected image height in metres at distance `d` (defaults to `throwDistance`).
    public func projectedHeight(atDistance d: Float? = nil) -> Float {
        projectedWidth(atDistance: d) / spec.aspectRatio
    }

    /// Projected image diagonal in metres at distance `d` (defaults to `throwDistance`).
    public func projectedDiagonal(atDistance d: Float? = nil) -> Float {
        let w = projectedWidth(atDistance: d)
        let h = projectedHeight(atDistance: d)
        return hypot(w, h)
    }

    /// Orthonormal optical basis `(right, up, forward)` in model space (metres, Z up), including `rollDegrees`.
    public func opticalBasis() -> (right: SIMD3<Float>, up: SIMD3<Float>, forward: SIMD3<Float>) {
        let delta = target - position
        let len = simd_length(delta)
        let forward = len > 1e-5 ? (delta / len) : SIMD3<Float>(0, 1, 0)
        let worldUp: SIMD3<Float> = abs(forward.z) < 0.999 ? SIMD3<Float>(0, 0, 1) : SIMD3<Float>(0, 1, 0)
        let r0 = simd_normalize(simd_cross(forward, worldUp))
        let u0 = simd_normalize(simd_cross(r0, forward))
        let rollRad = rollDegrees * .pi / 180.0
        let c = cos(rollRad)
        let s = sin(rollRad)
        let right = simd_normalize(r0 * c + u0 * s)
        let up = simd_normalize(-r0 * s + u0 * c)
        return (right, up, forward)
    }

    /// Horizontal azimuth angle in degrees (`0°` = +Y north, `90°` = +X east, `-90°` = -X west).
    public var panDegrees: Float {
        let f = opticalBasis().forward
        let horiz = hypot(f.x, f.y)
        guard horiz > 1e-5 else { return 0 }
        return atan2(f.x, f.y) * 180.0 / .pi
    }

    /// Vertical tilt/elevation angle in degrees (`0°` = horizontal, `-90°` = straight down, `+90°` = straight up).
    public var tiltDegrees: Float {
        let f = opticalBasis().forward
        return asin(simd_clamp(f.z, -1.0, 1.0)) * 180.0 / .pi
    }

    /// Updates `target` from `panDegrees` and `tiltDegrees` while keeping `throwDistance` constant.
    public mutating func setPanTilt(panDegrees: Float, tiltDegrees: Float) {
        let dist = throwDistance
        let panRad = panDegrees * .pi / 180.0
        let clampedTilt = simd_clamp(tiltDegrees, -89.5, 89.5)
        let tiltRad = clampedTilt * .pi / 180.0
        let cosTilt = cos(tiltRad)
        let dir = SIMD3<Float>(
            sin(panRad) * cosTilt,
            cos(panRad) * cosTilt,
            sin(tiltRad)
        )
        target = position + simd_normalize(dir) * dist
    }

    /// Computes the 4 corners and shifted center of the projected rectangle at forward distance `d` along the optical axis.
    public func frustumCorners(atDistance d: Float? = nil) -> (
        bottomLeft: SIMD3<Float>,
        bottomRight: SIMD3<Float>,
        topRight: SIMD3<Float>,
        topLeft: SIMD3<Float>,
        frameCenter: SIMD3<Float>
    ) {
        let dist = max(d ?? throwDistance, 0.05)
        let (right, up, forward) = opticalBasis()
        let w = projectedWidth(atDistance: dist)
        let h = projectedHeight(atDistance: dist)
        let axisCenter = position + forward * dist
        let shiftedCenter = axisCenter + right * (lensShiftH * w) + up * (lensShiftV * h)
        let halfW = right * (w * 0.5)
        let halfH = up * (h * 0.5)
        return (
            bottomLeft: shiftedCenter - halfW - halfH,
            bottomRight: shiftedCenter + halfW - halfH,
            topRight: shiftedCenter + halfW + halfH,
            topLeft: shiftedCenter - halfW + halfH,
            frameCenter: shiftedCenter
        )
    }

    /// Matrix transforming model-space coordinates `(x, y, z, 1)` into Projector Eye Space `(x_e, y_e, z_e, 1)`
    /// where `+X` is right, `+Y` is up, and `+Z` is forward along the optical axis.
    public var viewMatrix: simd_float4x4 {
        let (r, u, f) = opticalBasis()
        let tx = -simd_dot(r, position)
        let ty = -simd_dot(u, position)
        let tz = -simd_dot(f, position)
        return simd_float4x4(
            SIMD4<Float>(r.x, u.x, f.x, 0),
            SIMD4<Float>(r.y, u.y, f.y, 0),
            SIMD4<Float>(r.z, u.z, f.z, 0),
            SIMD4<Float>(tx, ty, tz, 1)
        )
    }

    /// Off-axis asymmetric Metal perspective projection matrix (`z_NDC` in `[0, 1]`, `w_clip = z_e`) incorporating
    /// `throwRatio`, `spec.aspectRatio`, `lensShiftH`, and `lensShiftV`.
    public func projectionMatrix(zNear: Float = 0.15, zFar: Float = 150.0) -> simd_float4x4 {
        let tr = max(throwRatio, 0.05)
        let aspect = spec.aspectRatio
        let sx = 2.0 * tr
        let sy = 2.0 * tr * aspect
        let ox = -2.0 * lensShiftH
        let oy = -2.0 * lensShiftV
        let near = max(zNear, 0.02)
        let far = max(zFar, near + 1.0)
        let sz = far / (far - near)
        let oz = -(near * far) / (far - near)
        return simd_float4x4(
            SIMD4<Float>(sx, 0, 0, 0),
            SIMD4<Float>(0, sy, 0, 0),
            SIMD4<Float>(ox, oy, sz, 1),
            SIMD4<Float>(0, 0, oz, 0)
        )
    }

    /// Combined view-projection matrix mapping model-space points `(x, y, z, 1)` directly to projector clip space.
    public func viewProjectionMatrix(zNear: Float = 0.15, zFar: Float = 150.0) -> simd_float4x4 {
        projectionMatrix(zNear: zNear, zFar: zFar) * viewMatrix
    }

    /// Projects a model-space point into normalized projector image coordinates `uv` in `[0, 1] × [0, 1]`
    /// (`u = 0` left, `u = 1` right, `v = 0` top, `v = 1` bottom) and returns its forward optical distance `eyeDepth`.
    public func projectPoint(
        _ modelPoint: SIMD3<Float>,
        zNear: Float = 0.15,
        zFar: Float = 150.0
    ) -> (uv: SIMD2<Float>, eyeDepth: Float, isInsideFrustum: Bool) {
        let clip = viewProjectionMatrix(zNear: zNear, zFar: zFar) * SIMD4<Float>(modelPoint, 1.0)
        let w = clip.w
        guard w > zNear, w <= zFar else {
            return (.zero, w, false)
        }
        let ndcX = clip.x / w
        let ndcY = clip.y / w
        let u = ndcX * 0.5 + 0.5
        let v = 0.5 - ndcY * 0.5
        let inside = (u >= 0.0 && u <= 1.0 && v >= 0.0 && v <= 1.0)
        return (SIMD2<Float>(u, v), w, inside)
    }
}

// MARK: - .sskp Project File Format

/// Saved `.sskp` project file combining a 3D model reference (`.skp`, `.dwg`, `.dxf`, `.dae`, `.obj`) with
/// video projectors, camera pose, lighting, and layer visibility.
public struct SSKPProject: Codable, Equatable, Sendable {
    public static let currentFormatVersion = 1
    public static let fileExtension = "sskp"

    public struct CameraState: Codable, Equatable, Sendable {
        public var position: SIMD3<Float>
        public var target: SIMD3<Float>
        public var fovDegrees: Float
        public var isPerspective: Bool
        public var orthoScale: Float
        public var exposureOffset: Float

        public init(
            position: SIMD3<Float>,
            target: SIMD3<Float>,
            fovDegrees: Float,
            isPerspective: Bool,
            orthoScale: Float,
            exposureOffset: Float
        ) {
            self.position = position
            self.target = target
            self.fovDegrees = fovDegrees
            self.isPerspective = isPerspective
            self.orthoScale = orthoScale
            self.exposureOffset = exposureOffset
        }
    }

    public struct PointLightState: Codable, Equatable, Sendable {
        public var name: String
        public var position: SIMD3<Float>
        public var intensity: Float
        public var isFromScene: Bool

        public init(name: String, position: SIMD3<Float>, intensity: Float, isFromScene: Bool) {
            self.name = name
            self.position = position
            self.intensity = intensity
            self.isFromScene = isFromScene
        }
    }

    public struct LightingState: Codable, Equatable, Sendable {
        public var lightingMode: String
        public var sunAzimuthDegrees: Float
        public var sunElevationDegrees: Float
        public var sunIntensity: Float
        public var ambientIntensity: Float
        public var shadowsEnabled: Bool
        public var shadingStyle: String
        public var backdropStyle: String
        public var customBackdropColor: SIMD3<Float>
        public var showsEdges: Bool
        public var showsGrid: Bool
        public var pointLights: [PointLightState]

        public init(
            lightingMode: String,
            sunAzimuthDegrees: Float,
            sunElevationDegrees: Float,
            sunIntensity: Float,
            ambientIntensity: Float,
            shadowsEnabled: Bool,
            shadingStyle: String,
            backdropStyle: String,
            customBackdropColor: SIMD3<Float>,
            showsEdges: Bool,
            showsGrid: Bool,
            pointLights: [PointLightState]
        ) {
            self.lightingMode = lightingMode
            self.sunAzimuthDegrees = sunAzimuthDegrees
            self.sunElevationDegrees = sunElevationDegrees
            self.sunIntensity = sunIntensity
            self.ambientIntensity = ambientIntensity
            self.shadowsEnabled = shadowsEnabled
            self.shadingStyle = shadingStyle
            self.backdropStyle = backdropStyle
            self.customBackdropColor = customBackdropColor
            self.showsEdges = showsEdges
            self.showsGrid = showsGrid
            self.pointLights = pointLights
        }
    }

    public var formatVersion: Int
    public var modelPath: String
    public var modelRelativePath: String?
    public var projectors: [VideoProjector]
    public var camera: CameraState?
    public var lighting: LightingState?
    public var hiddenLayerNames: [String]?

    public init(
        formatVersion: Int = SSKPProject.currentFormatVersion,
        modelPath: String,
        modelRelativePath: String? = nil,
        projectors: [VideoProjector],
        camera: CameraState? = nil,
        lighting: LightingState? = nil,
        hiddenLayerNames: [String]? = nil
    ) {
        self.formatVersion = formatVersion
        self.modelPath = modelPath
        self.modelRelativePath = modelRelativePath
        self.projectors = projectors
        self.camera = camera
        self.lighting = lighting
        self.hiddenLayerNames = hiddenLayerNames
    }

    /// Computes a relative path from `baseDirectory` to `targetURL` when possible.
    public static func relativePath(from baseDirectory: URL, to targetURL: URL) -> String? {
        let baseComponents = baseDirectory.standardizedFileURL.pathComponents
        let targetComponents = targetURL.standardizedFileURL.pathComponents
        var common = 0
        while common < baseComponents.count && common < targetComponents.count && baseComponents[common] == targetComponents[common] {
            common += 1
        }
        guard common > 1 else { return nil }
        let upCount = baseComponents.count - common
        guard upCount <= 6 else { return nil }
        let ups = Array(repeating: "..", count: upCount)
        let remainder = targetComponents[common...]
        return (ups + remainder).joined(separator: "/")
    }

    /// Resolves the underlying 3D model URL (`.skp`, `.dwg`, `.dxf`, `.dae`, `.obj`) referenced by this `.sskp` file.
    public func resolveModelURL(relativeTo sskpURL: URL) -> URL {
        let dir = sskpURL.deletingLastPathComponent()
        let fm = FileManager.default
        if let rel = modelRelativePath, !rel.isEmpty {
            let candidate = URL(fileURLWithPath: rel, relativeTo: dir).standardizedFileURL
            if fm.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        let absCandidate = URL(fileURLWithPath: modelPath).standardizedFileURL
        if fm.fileExists(atPath: absCandidate.path) {
            return absCandidate
        }
        let siblingCandidate = dir.appendingPathComponent(absCandidate.lastPathComponent).standardizedFileURL
        if fm.fileExists(atPath: siblingCandidate.path) {
            return siblingCandidate
        }
        return absCandidate
    }

    public func encodeJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    public static func decodeJSON(from data: Data) throws -> SSKPProject {
        try JSONDecoder().decode(SSKPProject.self, from: data)
    }

    public static func read(from url: URL) throws -> SSKPProject {
        let data = try Data(contentsOf: url)
        return try decodeJSON(from: data)
    }

    public func write(to url: URL) throws {
        let data = try encodeJSON()
        try data.write(to: url, options: .atomic)
    }
}
