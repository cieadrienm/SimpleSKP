import SceneKit
import SimpleSKPCore

/// Visual backdrop styles for the 3D viewport.
public enum BackdropStyle: String, CaseIterable, Identifiable, Sendable {
    case architecturalSky
    case studioDark
    case warmPaper
    case customColor

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .architecturalSky: return L("Ciel doux", "Soft Sky")
        case .studioDark: return L("Studio sombre", "Dark Studio")
        case .warmPaper: return L("Papier clair", "Warm Paper")
        case .customColor: return L("Couleur", "Custom Color")
        }
    }

    public var icon: String {
        switch self {
        case .architecturalSky: return "cloud.sun"
        case .studioDark: return "moon.stars"
        case .warmPaper: return "doc.plaintext"
        case .customColor: return "paintpalette"
        }
    }
}

/// Primary lighting mode for the 3D viewport.
public enum LightingMode: String, CaseIterable, Identifiable, Sendable {
    case sun
    case point

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .sun: return L("Soleil", "Sun")
        case .point: return L("Ponctuel", "Point")
        }
    }

    public var icon: String {
        switch self {
        case .sun: return "sun.max.fill"
        case .point: return "lightbulb.fill"
        }
    }
}

/// A point (omni) light in SketchUp model space (metres, Z up).
public struct ViewportPointLight: Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    /// Position in SketchUp model coordinates (metres, X right, Y depth, Z up).
    public var position: SIMD3<Float>
    /// Normalized intensity multiplier (`1.0` = 100%, range `0.1 ... 3.0`).
    public var intensity: Float
    /// True if extracted from a light component/group in the `.skp` model, false if created by the user.
    public var isFromScene: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        position: SIMD3<Float>,
        intensity: Float = 1.0,
        isFromScene: Bool = false
    ) {
        self.id = id
        self.name = name
        self.position = position
        self.intensity = intensity
        self.isFromScene = isFromScene
    }
}

/// Surface shading modes for architectural & stage inspection.
public enum ShadingStyle: String, CaseIterable, Identifiable, Sendable {
    case textured
    case clay
    case xray
    case wireframe

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .textured: return L("Texturé", "Textured")
        case .clay: return L("Maquette blanche", "White Clay")
        case .xray: return L("Rayons X", "X-Ray")
        case .wireframe: return L("Filaire", "Wireframe")
        }
    }

    public var shortLabel: String {
        switch self {
        case .textured: return L("PBR", "PBR")
        case .clay: return L("Blanc", "Clay")
        case .xray: return L("Rayons X", "X-Ray")
        case .wireframe: return L("Filaire", "Wire")
        }
    }

    public var icon: String {
        switch self {
        case .textured: return "cube.fill"
        case .clay: return "cube"
        case .xray: return "cube.transparent"
        case .wireframe: return "squareshape.split.2x2"
        }
    }
}

/// Rendering setup shared by the scene builder and the view (D7 / D13 « réaliste doux »). The view calls `configure(camera:)`
/// and `setAmbientOcclusion(_:intensity:on:)`; the scene uses `skyImage()` as lighting environment and `backdropImage(for:customColor:)` as background.
public enum Rendering {
    public static let defaultAmbientOcclusionIntensity: CGFloat = 0.7
    public static let defaultCustomBackdropColor = SIMD3<Float>(0.14, 0.16, 0.20)
    public static let defaultAmbientIntensity: Float = 1.0
    public static let defaultSunIntensity: Float = 1.0

    /// Logarithmic / perceptual curve exponent (`2.6`) for light intensity sliders:
    /// slider position `t` in `0...1` maps to `maxIntensity * t^2.6`, giving ~3× finer resolution in the 0–30% range.
    public static let lightCurveExponent: Double = 2.6

    /// Maps a normalized slider position `t` (`0.0 ... 1.0`) to a light intensity (`0.0 ... maxIntensity`) with logarithmic feel in low values.
    public static func sliderToLightIntensity(_ sliderValue: Double, maxIntensity: Double = 3.0) -> Float {
        let t = max(0.0, min(1.0, sliderValue))
        if t <= 1e-5 { return 0.0 }
        return Float(maxIntensity * pow(t, lightCurveExponent))
    }

    /// Maps a light intensity (`0.0 ... maxIntensity`) back to a normalized slider position `t` (`0.0 ... 1.0`).
    public static func lightIntensityToSlider(_ intensity: Float, maxIntensity: Double = 3.0) -> Double {
        let clamped = max(0.0, min(maxIntensity, Double(intensity)))
        if clamped <= 1e-6 || maxIntensity <= 0 { return 0.0 }
        return pow(clamped / maxIntensity, 1.0 / lightCurveExponent)
    }

    /// Formats a light intensity multiplier (`1.0` = `100 %`) with 1 decimal place below `10 %` for fine low-level readout.
    public static func formatLightPercentage(_ intensity: Float) -> String {
        let pct = max(0.0, Double(intensity) * 100.0)
        if pct < 0.05 {
            return "0 %"
        } else if pct < 10.0 {
            let formatted = String(format: "%.1f", pct)
            return (Localization.isEnglish ? formatted : formatted.replacingOccurrences(of: ".", with: ",")) + " %"
        } else {
            return "\(Int(pct.rounded())) %"
        }
    }

    /// Representative mid-screen sRGB color (`0...1`) of the backdrop for contrast and PDF background calculations.
    public static func backdropRepresentativeColor(for style: BackdropStyle, customColor: SIMD3<Float> = defaultCustomBackdropColor) -> SIMD3<Float> {
        let stops = backdropGradientStops(for: style, customColor: customColor)
        return stops.mid
    }

    /// Top, middle, and bottom sRGB colors (`0...1`) of the vertical backdrop gradient.
    public static func backdropGradientStops(
        for style: BackdropStyle,
        customColor: SIMD3<Float> = defaultCustomBackdropColor
    ) -> (top: SIMD3<Float>, mid: SIMD3<Float>, bottom: SIMD3<Float>) {
        switch style {
        case .architecturalSky:
            return (
                top: SIMD3<Float>(0.24, 0.31, 0.42),
                mid: SIMD3<Float>(0.42, 0.49, 0.59),
                bottom: SIMD3<Float>(0.72, 0.74, 0.77)
            )
        case .studioDark:
            return (
                top: SIMD3<Float>(0.09, 0.11, 0.14),
                mid: SIMD3<Float>(0.13, 0.15, 0.20),
                bottom: SIMD3<Float>(0.18, 0.21, 0.26)
            )
        case .warmPaper:
            return (
                top: SIMD3<Float>(0.88, 0.87, 0.84),
                mid: SIMD3<Float>(0.93, 0.92, 0.89),
                bottom: SIMD3<Float>(0.83, 0.81, 0.78)
            )
        case .customColor:
            let clamped = simd_clamp(customColor, .zero, SIMD3(repeating: 1))
            return (
                top: simd_clamp(clamped * 0.92, .zero, SIMD3(repeating: 1)),
                mid: clamped,
                bottom: simd_clamp(clamped + SIMD3(repeating: 0.04), .zero, SIMD3(repeating: 1))
            )
        }
    }

    /// Relative perceptual luminance (`0...1`) of the backdrop.
    public static func backdropLuminance(for style: BackdropStyle, customColor: SIMD3<Float> = defaultCustomBackdropColor) -> Float {
        let c = backdropRepresentativeColor(for: style, customColor: customColor)
        return 0.2126 * c.x + 0.7152 * c.y + 0.0722 * c.z
    }

    /// Returns a high-contrast sRGB edge color (`0...1`) that always stands out against the active backdrop.
    /// When the backdrop is dark (`luma < 0.52`), edges become crisp light silver-white; when light (`luma >= 0.52`), deep charcoal ink.
    public static func contrastingEdgeColor(
        for style: BackdropStyle,
        customColor: SIMD3<Float> = defaultCustomBackdropColor,
        shadingStyle: ShadingStyle = .wireframe
    ) -> SIMD3<Float> {
        let luma = backdropLuminance(for: style, customColor: customColor)
        // In clay mode, faces are bright white plaster, so unless we are in wireframe/xray, keep edges dark on the white clay.
        if shadingStyle == .clay && style != .warmPaper && luma < 0.52 {
            return SIMD3<Float>(0.16, 0.18, 0.22)
        }
        if luma < 0.52 {
            return shadingStyle == .wireframe
                ? SIMD3<Float>(0.95, 0.96, 0.99)
                : SIMD3<Float>(0.88, 0.91, 0.96)
        } else {
            return shadingStyle == .wireframe
                ? SIMD3<Float>(0.07, 0.09, 0.12)
                : SIMD3<Float>(0.14, 0.16, 0.20)
        }
    }

    /// Adapts a raw AutoCAD layer or entity sRGB color (`0…1`) to guarantee high legibility and contrast against
    /// a backdrop with perceptual luminance `backdropLuminance` (`0…1`), while preserving the CAD layer's hue.
    /// - Black/White (ACI 7) automatically becomes crisp silver-white on dark backdrops and deep charcoal ink on light backdrops.
    /// - Dark blues, purples, and reds are lifted in luminance on dark backdrops; bright yellows, greens, and cyans are darkened on light paper.
    public static func adaptedCADColor(_ rawRGB: SIMD3<Float>, backdropLuminance: Float) -> SIMD3<Float> {
        let c = simd_clamp(rawRGB, .zero, SIMD3(repeating: 1))
        let maxC = max(c.x, max(c.y, c.z))
        let minC = min(c.x, min(c.y, c.z))
        let delta = maxC - minC
        let rawLuma = 0.2126 * c.x + 0.7152 * c.y + 0.0722 * c.z
        let isDarkBackdrop = backdropLuminance < 0.54

        // 1. Achromatic colors: AutoCAD ACI 7 (White/Black) and greys (ACI 8, 9, 250…255)
        if delta < 0.08 {
            if maxC < 0.20 || minC > 0.84 {
                return isDarkBackdrop
                    ? SIMD3<Float>(0.93, 0.95, 0.98)
                    : SIMD3<Float>(0.11, 0.13, 0.17)
            }
            let v = isDarkBackdrop ? (0.64 + 0.24 * rawLuma) : (0.24 + 0.24 * rawLuma)
            return SIMD3<Float>(repeating: v)
        }

        // 2. Chromatic colors: convert RGB -> HSV (h in 0..<360)
        var h: Float = 0
        if maxC == c.x {
            h = 60.0 * ((c.y - c.z) / delta).truncatingRemainder(dividingBy: 6.0)
        } else if maxC == c.y {
            h = 60.0 * (((c.z - c.x) / delta) + 2.0)
        } else {
            h = 60.0 * (((c.x - c.y) / delta) + 4.0)
        }
        if h < 0 { h += 360.0 }
        var s = delta / max(maxC, 1e-5)
        var v = maxC

        if isDarkBackdrop {
            v = max(v, 0.92)
            s = min(s, 0.82)
            if h >= 205.0 && h <= 285.0 {
                // Deep blue / indigo / violet: boost brightness and mix white so perceptual contrast is high on dark studio
                s = min(s, 0.60)
                v = max(v, 0.98)
            } else if h <= 18.0 || h >= 342.0 {
                // Red / crimson: soften saturation slightly for luminous coral-red legibility
                s = min(s, 0.74)
                v = max(v, 0.96)
            }
        } else {
            // Light backdrop (.warmPaper / light custom): darken high-luma hues (yellow, green, cyan) so they don't vanish
            s = max(s, 0.78)
            let maxV: Float = (h >= 38.0 && h <= 198.0) ? 0.55 : 0.66
            v = min(max(v, 0.38), maxV)
        }

        let chroma = v * s
        let x = chroma * (1.0 - abs((h / 60.0).truncatingRemainder(dividingBy: 2.0) - 1.0))
        let m = v - chroma
        let (r1, g1, b1): (Float, Float, Float)
        switch Int(h / 60.0) % 6 {
        case 0: (r1, g1, b1) = (chroma, x, 0)
        case 1: (r1, g1, b1) = (x, chroma, 0)
        case 2: (r1, g1, b1) = (0, chroma, x)
        case 3: (r1, g1, b1) = (0, x, chroma)
        case 4: (r1, g1, b1) = (x, 0, chroma)
        default: (r1, g1, b1) = (chroma, 0, x)
        }
        return simd_clamp(SIMD3<Float>(r1 + m, g1 + m, b1 + m), .zero, SIMD3(repeating: 1))
    }

    /// Camera post-processing: HDR without exposure adaptation, screen-space ambient occlusion, subtle contrast, no bloom/blur/fringe.
    public static func configure(camera: SCNCamera) {
        camera.wantsHDR = true
        camera.wantsExposureAdaptation = false
        camera.exposureOffset = -0.62 // Balanced: keeps sunlit floors unclipped while preserving crisp white walls
        camera.contrast = 0.06
        camera.saturation = 1.04
        camera.automaticallyAdjustsZRange = true
        camera.screenSpaceAmbientOcclusionRadius = 0.3
        camera.screenSpaceAmbientOcclusionBias = 0.08
        camera.screenSpaceAmbientOcclusionDepthThreshold = 2 // 0.3–1 banded open floors and speckled far walls
        camera.bloomIntensity = 0
        camera.motionBlurIntensity = 0
        camera.colorFringeIntensity = 0
        setAmbientOcclusion(true, on: camera)
    }

    /// Toggles screen-space ambient occlusion (intensity `0.7` by default when on, `0` when off; the app's default is off).
    /// SceneKit's SSAO assumes a perspective depth buffer: in a parallel projection it blackens whole faces and streaks floors,
    /// so it stays off there — call again after switching projection.
    public static func setAmbientOcclusion(_ enabled: Bool, intensity: CGFloat = defaultAmbientOcclusionIntensity, on camera: SCNCamera) {
        camera.screenSpaceAmbientOcclusionIntensity = enabled && !camera.usesOrthographicProjection ? max(0, intensity) : 0
    }

    /// Procedural sky, equirectangular 512 × 256 (top row = zenith): soft blue zenith, warm white horizon, grey ground.
    /// The lighting environment. `backdrop: true` gives a vertical gradient strip, which SceneKit draws as a screen-space background.
    public static func skyImage(backdrop: Bool = false) -> CGImage {
        if backdrop {
            return backdropImage(for: .architecturalSky)
        }
        let (w, h) = (512, 256)
        let zenith = SIMD3<Float>(0.52, 0.69, 0.90)
        let horizon = SIMD3<Float>(0.96, 0.95, 0.92)
        let ground = SIMD3<Float>(0.34, 0.35, 0.38)
        var pixels = [UInt8](repeating: 255, count: w * h * 4)
        for y in 0..<h {
            let elevation = (0.5 - (Float(y) + 0.5) / Float(h)) * .pi
            let c = elevation >= 0
                ? simd_mix(horizon, zenith, SIMD3(repeating: pow(sin(elevation), 0.65)))
                : simd_mix(horizon, ground, SIMD3(repeating: min(1, -elevation / 0.18)))
            for x in 0..<w {
                let o = (y * w + x) * 4
                pixels[o] = UInt8(c.x * 255)
                pixels[o + 1] = UInt8(c.y * 255)
                pixels[o + 2] = UInt8(c.z * 255)
            }
        }
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        return CGImage(
            width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
        )!
    }

    /// Screen-space vertical gradient backdrop (`4 × 256`) for the chosen `BackdropStyle` and optional custom sRGB color.
    public static func backdropImage(for style: BackdropStyle, customColor: SIMD3<Float> = defaultCustomBackdropColor) -> CGImage {
        let (w, h) = (4, 256)
        let top: SIMD3<Float>
        let mid: SIMD3<Float>
        let bottom: SIMD3<Float>
        switch style {
        case .architecturalSky:
            // Refined slate-azure zenith to warm studio horizon
            top = SIMD3<Float>(0.24, 0.31, 0.42)
            mid = SIMD3<Float>(0.42, 0.49, 0.59)
            bottom = SIMD3<Float>(0.72, 0.74, 0.77)
        case .studioDark:
            // Deep architectural dark studio harmonizing with Simple dark theme
            top = SIMD3<Float>(0.09, 0.11, 0.14)
            mid = SIMD3<Float>(0.13, 0.15, 0.20)
            bottom = SIMD3<Float>(0.18, 0.21, 0.26)
        case .warmPaper:
            // Warm architectural drafting paper
            top = SIMD3<Float>(0.88, 0.87, 0.84)
            mid = SIMD3<Float>(0.93, 0.92, 0.89)
            bottom = SIMD3<Float>(0.83, 0.81, 0.78)
        case .customColor:
            let clamped = simd_clamp(customColor, .zero, SIMD3(repeating: 1))
            top = simd_clamp(clamped * 0.92, .zero, SIMD3(repeating: 1))
            mid = clamped
            bottom = simd_clamp(clamped + SIMD3(repeating: 0.04), .zero, SIMD3(repeating: 1))
        }
        var pixels = [UInt8](repeating: 255, count: w * h * 4)
        for y in 0..<h {
            let t = (Float(y) + 0.5) / Float(h) // 0 = top, 1 = bottom
            let c: SIMD3<Float>
            if t < 0.58 {
                let u = t / 0.58
                c = simd_mix(top, mid, SIMD3(repeating: u * u * (3 - 2 * u)))
            } else {
                let u = (t - 0.58) / 0.42
                c = simd_mix(mid, bottom, SIMD3(repeating: u * u * (3 - 2 * u)))
            }
            for x in 0..<w {
                let o = (y * w + x) * 4
                pixels[o] = UInt8(simd_clamp(c.x, 0, 1) * 255)
                pixels[o + 1] = UInt8(simd_clamp(c.y, 0, 1) * 255)
                pixels[o + 2] = UInt8(simd_clamp(c.z, 0, 1) * 255)
            }
        }
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        return CGImage(
            width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
        )!
    }
}
