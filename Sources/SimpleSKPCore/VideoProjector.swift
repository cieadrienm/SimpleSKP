import Foundation
import simd

/// Semantic role of a DMX channel in a stage lighting fixture mode (OFL / Millumin).
public enum DMXChannelRole: String, Codable, Sendable, Equatable, CaseIterable {
    case dimmer
    case red
    case green
    case blue
    case white
    case warmWhite
    case coldWhite
    case amber
    case uv
    case cyan
    case magenta
    case yellow
    case strobe
    case zoom
    case focus
    case pan
    case tilt
    case colorTemperature
    case colorMacro
    case other
    case ignored

    public var shortLabel: String {
        switch self {
        case .dimmer: return "Dim"
        case .red: return "R"
        case .green: return "G"
        case .blue: return "B"
        case .white: return "W"
        case .warmWhite: return "WW"
        case .coldWhite: return "CW"
        case .amber: return "Amb"
        case .uv: return "UV"
        case .cyan: return "C"
        case .magenta: return "M"
        case .yellow: return "Y"
        case .strobe: return "Strb"
        case .zoom: return "Zoom"
        case .focus: return "Foc"
        case .pan: return "Pan"
        case .tilt: return "Tilt"
        case .colorTemperature: return "CCT"
        case .colorMacro: return "Macro"
        case .other, .ignored: return "Fx"
        }
    }

    /// Classifies an Open Fixture Library (OFL) channel by its name, OFL `type`, and OFL `color`.
    public static func classify(name: String, oflType: String? = nil, oflColor: String? = nil) -> DMXChannelRole {
        let lowerName = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let lowerType = (oflType ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let lowerColor = (oflColor ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        // Ignore 16-bit fine channels, speed, curve/mode/delay/reset channels so they never override primary controls
        if lowerName.contains("fine") || lowerName.contains("speed") || lowerName.contains("delay") ||
           lowerName.contains("curve") || lowerName.contains("dimmer mod") || lowerName.contains("dimmer_mod") ||
           lowerName.contains("auto") || lowerName.contains("program") || lowerName.contains("segment") ||
           lowerName.contains("macro") || lowerName.contains("sound") || lowerName.contains("reset") ||
           lowerName.contains("id select") {
            return .other
        }

        if lowerType == "single color" || !lowerColor.isEmpty {
            if lowerColor == "red" || lowerName.hasPrefix("red") { return .red }
            if lowerColor == "green" || lowerName.hasPrefix("green") { return .green }
            if lowerColor == "blue" || lowerName.hasPrefix("blue") { return .blue }
            if lowerColor == "warm white" || lowerName.contains("warm white") || lowerName.contains("warmwhite") { return .warmWhite }
            if lowerColor == "amber" || lowerName.contains("amber") { return .amber }
            if lowerColor == "uv" || lowerName.contains("uv") { return .uv }
            if lowerColor.contains("white") || lowerName.contains("white") { return .white }
        }

        if lowerName == "red" || lowerName.hasPrefix("red /") { return .red }
        if lowerName == "green" || lowerName.hasPrefix("green /") { return .green }
        if lowerName == "blue" || lowerName.hasPrefix("blue /") { return .blue }
        if lowerName.contains("warm white") || lowerName.contains("warm_white") || lowerName == "intensitywarmwhite" { return .warmWhite }
        if lowerName.contains("cool white") || lowerName.contains("cold white") || lowerName.contains("cool_white") ||
           lowerName.contains("cold_white") || lowerName == "white" || lowerName == "intensitycoldwhite" { return .white }
        if lowerName.contains("amber") || lowerName == "intensityamber" { return .amber }
        if lowerName == "uv" { return .uv }

        if lowerType == "intensity" || lowerName == "dimmer" || lowerName == "intensity" || lowerName == "master dimmer" {
            return .dimmer
        }
        if lowerType == "zoom" || lowerName == "zoom" {
            return .zoom
        }
        if lowerType == "focus" || lowerName == "focus" {
            return .focus
        }
        if lowerType == "pan" || lowerName == "pan" {
            return .pan
        }
        if lowerType == "tilt" || lowerName == "tilt" {
            return .tilt
        }
        if lowerType == "strobe" || lowerType == "shutter" || lowerName.contains("strobe") || lowerName.contains("shutter") {
            return .strobe
        }
        if lowerType == "color temperature" || lowerName.contains("temperature") || lowerName.contains("cct") {
            return .colorTemperature
        }
        return .other
    }
}

/// Optical and physical specification of a video projector or stage lighting fixture model.
public enum ProjectorKind: String, Codable, Sendable, CaseIterable {
    case videoProjector
    case profileSpot      // Découpe LED (Showtec Performer Profile Mini, ERS, Ikon Profile)
    case washPanel        // Wash / Panneau LED / Lyre Wash (Eurolite PLL-480, Varytec Hero Wash 300 FC, PAR)

    public var isStageLight: Bool {
        self != .videoProjector
    }

    public var localizedName: String {
        switch self {
        case .videoProjector:
            return L("Vidéoprojecteur", "Video Projector")
        case .profileSpot:
            return L("Découpe / Spot", "Profile Spot")
        case .washPanel:
            return L("Wash / Panneau LED", "LED Wash / Panel")
        }
    }
}

/// Optical and physical specification of a video projector model.
public struct ProjectorSpec: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var manufacturer: String
    public var model: String
    /// Type of optical fixture (video projector, profile spot with shutters, or wash panel with barn doors).
    public var kind: ProjectorKind
    /// Optional nominal color temperature in Kelvin (e.g. 3200 for warm white COB LED).
    public var colorTemperatureKelvin: Float?
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

    public var isStageLight: Bool {
        kind.isStageLight
    }

    /// Minimum beam angle in degrees (at telephoto `maxThrowRatio`).
    public var minBeamAngleDegrees: Float {
        2.0 * atan(1.0 / (2.0 * max(maxThrowRatio, 0.05))) * 180.0 / .pi
    }

    /// Maximum beam angle in degrees (at wide-angle `minThrowRatio`).
    public var maxBeamAngleDegrees: Float {
        2.0 * atan(1.0 / (2.0 * max(minThrowRatio, 0.05))) * 180.0 / .pi
    }

    /// Default beam angle in degrees.
    public var defaultBeamAngleDegrees: Float {
        2.0 * atan(1.0 / (2.0 * max(defaultThrowRatio, 0.05))) * 180.0 / .pi
    }

    public var resolutionLabel: String {
        if kind == .profileSpot {
            let minAngle = 2.0 * atan(1.0 / (2.0 * maxThrowRatio)) * 180.0 / .pi
            let maxAngle = 2.0 * atan(1.0 / (2.0 * minThrowRatio)) * 180.0 / .pi
            return String(format: "Découpe Zoom %.0f°–%.0f°", minAngle, maxAngle)
        } else if kind == .washPanel {
            if (maxThrowRatio - minThrowRatio) > 0.05 {
                let minAngle = 2.0 * atan(1.0 / (2.0 * maxThrowRatio)) * 180.0 / .pi
                let maxAngle = 2.0 * atan(1.0 / (2.0 * minThrowRatio)) * 180.0 / .pi
                return String(format: "Wash Zoom %.0f°–%.0f°", minAngle, maxAngle)
            } else {
                let angle = 2.0 * atan(1.0 / (2.0 * defaultThrowRatio)) * 180.0 / .pi
                return String(format: "Wash Flood %.0f°", angle)
            }
        }
        let ratio: String
        if abs(aspectRatio - 1.6) < 0.02 {
            ratio = nativeWidth >= 2560 ? "16:10 4K+/WQXGA" : "16:10 WUXGA"
        } else if abs(aspectRatio - 16.0 / 9.0) < 0.02 {
            ratio = "16:9 UHD/HD"
        } else {
            ratio = String(format: "%.2f:1", aspectRatio)
        }
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
        bodySize: SIMD3<Float>,
        kind: ProjectorKind = .videoProjector,
        colorTemperatureKelvin: Float? = nil
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
        self.kind = kind
        self.colorTemperatureKelvin = colorTemperatureKelvin
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

    /// Panasonic PT-RQ32K + ET-D75LE30 — 3-Chip DLP SOLID SHINE 4K+ laser projector (`32 000 lm`, `2560×1600` 16:10, zoom lens `2.40–4.70:1`, régie vidéo N4 La Seine Musicale).
    public static let panasonicPTRQ32K_ETD75LE30 = ProjectorSpec(
        id: "panasonic-pt-rq32k-et-d75le30",
        manufacturer: "Panasonic",
        model: "PT-RQ32K (ET-D75LE30)",
        nativeWidth: 2560,
        nativeHeight: 1600,
        minThrowRatio: 2.40,
        maxThrowRatio: 4.70,
        defaultThrowRatio: 3.00,
        maxLensShiftH: 0.20,
        maxLensShiftV: 0.55,
        lumens: 32000,
        bodySize: SIMD3<Float>(0.700, 1.070, 0.418)
    )

    /// Panasonic PT-RQ32K + ET-D3LEW50 — 3-Chip DLP SOLID SHINE 4K+ laser projector (`32 000 lm`, `2560×1600` 16:10, fixed wide-angle lens `0.70:1`).
    public static let panasonicPTRQ32K_ETD3LEW50 = ProjectorSpec(
        id: "panasonic-pt-rq32k-et-d3lew50",
        manufacturer: "Panasonic",
        model: "PT-RQ32K (ET-D3LEW50)",
        nativeWidth: 2560,
        nativeHeight: 1600,
        minThrowRatio: 0.70,
        maxThrowRatio: 0.70,
        defaultThrowRatio: 0.70,
        maxLensShiftH: 0.15,
        maxLensShiftV: 0.30,
        lumens: 32000,
        bodySize: SIMD3<Float>(0.700, 1.070, 0.418)
    )

    /// Showtec Performer Profile Mini — Compact 30W COB LED theatre profile spot (`1 500 lm`, 3200K warm white, zoom `19°–36°` / `1.54–3.00:1`, 4 framing shutters).
    public static let showtecPerformerProfileMini = ProjectorSpec(
        id: "showtec-performer-profile-mini",
        manufacturer: "Showtec",
        model: "Performer Profile Mini",
        nativeWidth: 1024,
        nativeHeight: 1024,
        minThrowRatio: 1.54,
        maxThrowRatio: 3.00,
        defaultThrowRatio: 2.20,
        maxLensShiftH: 0.0,
        maxLensShiftV: 0.0,
        lumens: 1500,
        bodySize: SIMD3<Float>(0.345, 0.130, 0.231),
        kind: .profileSpot,
        colorTemperatureKelvin: 3200
    )

    /// Eurolite LED PLL-480 QCL Panel — 480 SMD LED softlight wash panel (`4 500 lm`, RGBW, wide flood `120°` / `0.288:1`, 4-leaf barn doors).
    public static let euroliteLEDPLL480QCL = ProjectorSpec(
        id: "eurolite-led-pll-480-qcl",
        manufacturer: "Eurolite",
        model: "LED PLL-480 QCL Panel",
        nativeWidth: 1024,
        nativeHeight: 1024,
        minThrowRatio: 0.25,
        maxThrowRatio: 0.35,
        defaultThrowRatio: 0.288,
        maxLensShiftH: 0.0,
        maxLensShiftV: 0.0,
        lumens: 4500,
        bodySize: SIMD3<Float>(0.640, 0.130, 0.335),
        kind: .washPanel,
        colorTemperatureKelvin: nil
    )

    /// Varytec Hero Wash 300 FC — Moving head wash with 19×15W RGBW 4-in-1 LEDs (`6 000 lm`, motorized zoom `6°–50°` / `1.07–9.54:1`, 3-segment ring control).
    public static let varytecHeroWash300FC = ProjectorSpec(
        id: "varytec-hero-wash-300-fc",
        manufacturer: "Varytec",
        model: "Hero Wash 300 FC",
        nativeWidth: 1024,
        nativeHeight: 1024,
        minThrowRatio: 1.07,
        maxThrowRatio: 9.54,
        defaultThrowRatio: 2.25,
        maxLensShiftH: 0.0,
        maxLensShiftV: 0.0,
        lumens: 6000,
        bodySize: SIMD3<Float>(0.310, 0.208, 0.390),
        kind: .washPanel,
        colorTemperatureKelvin: nil
    )

    /// Varytec Hero Wash 340FX RGBW Zoom — Moving head wash 7×40W RGBW (`5 200 lm`, motorized zoom `4°–55°` / `0.96–14.3:1`).
    public static let varytecHeroWash340FX = ProjectorSpec(
        id: "varytec-hero-wash-340fx-rgbw-zoom",
        manufacturer: "Varytec",
        model: "Hero Wash 340FX RGBW Zoom",
        nativeWidth: 1024,
        nativeHeight: 1024,
        minThrowRatio: 0.96,
        maxThrowRatio: 14.30,
        defaultThrowRatio: 2.10,
        maxLensShiftH: 0.0,
        maxLensShiftV: 0.0,
        lumens: 5200,
        bodySize: SIMD3<Float>(0.292, 0.210, 0.378),
        kind: .washPanel,
        colorTemperatureKelvin: nil
    )

    /// Eurolite LED ML-56 QCL RGBW — Theater Multi-Lens PAR 56 (`2 200 lm`, RGBW, beam `18°–45°`).
    public static let euroliteLEDML56RGBW = ProjectorSpec(
        id: "eurolite-led-ml-56-rgbw",
        manufacturer: "Eurolite",
        model: "LED ML-56 QCL RGBW",
        nativeWidth: 1024,
        nativeHeight: 1024,
        minThrowRatio: 1.15,
        maxThrowRatio: 3.15,
        defaultThrowRatio: 1.80,
        maxLensShiftH: 0.0,
        maxLensShiftV: 0.0,
        lumens: 2200,
        bodySize: SIMD3<Float>(0.245, 0.205, 0.295),
        kind: .washPanel,
        colorTemperatureKelvin: nil
    )

    /// ADJ Ikon Profile — 32W white LED indoor gobo / profile projector (`1 600 lm`, zoom `15°–30°`, 4 framing shutters).
    public static let adjIkonProfile = ProjectorSpec(
        id: "american-dj-ikon-profile",
        manufacturer: "ADJ",
        model: "Ikon Profile",
        nativeWidth: 1024,
        nativeHeight: 1024,
        minThrowRatio: 1.86,
        maxThrowRatio: 3.80,
        defaultThrowRatio: 2.40,
        maxLensShiftH: 0.0,
        maxLensShiftV: 0.0,
        lumens: 1600,
        bodySize: SIMD3<Float>(0.150, 0.408, 0.147),
        kind: .profileSpot,
        colorTemperatureKelvin: 5600
    )

    /// Stairville LED Flood Panel 150 — Compact RGB LED flood panel (`1 800 lm`, `40°` beam).
    public static let stairvilleLEDFloodPanel150 = ProjectorSpec(
        id: "stairville-led-flood-panel-150",
        manufacturer: "Stairville",
        model: "LED Flood Panel 150",
        nativeWidth: 1024,
        nativeHeight: 1024,
        minThrowRatio: 0.85,
        maxThrowRatio: 1.90,
        defaultThrowRatio: 1.37,
        maxLensShiftH: 0.0,
        maxLensShiftV: 0.0,
        lumens: 1800,
        bodySize: SIMD3<Float>(0.240, 0.110, 0.155),
        kind: .washPanel,
        colorTemperatureKelvin: nil
    )

    /// Stairville Octagon Theater 20x6W CW/WW/A — Theater variable-white / amber wash (`3 200 lm`, `36°` beam).
    public static let stairvilleOctagonTheater = ProjectorSpec(
        id: "stairville-octagon-theater-20x6w-cw-ww-a",
        manufacturer: "Stairville",
        model: "Octagon Theater CW/WW/A",
        nativeWidth: 1024,
        nativeHeight: 1024,
        minThrowRatio: 1.00,
        maxThrowRatio: 2.20,
        defaultThrowRatio: 1.54,
        maxLensShiftH: 0.0,
        maxLensShiftV: 0.0,
        lumens: 3200,
        bodySize: SIMD3<Float>(0.340, 0.195, 0.305),
        kind: .washPanel,
        colorTemperatureKelvin: 3200
    )

    /// Cameo Thunder Wash 600 W — High-output white SMD strobe / blinder / wash (`6 500 lm`, `80°` flood).
    public static let cameoThunderWash600W = ProjectorSpec(
        id: "cameo-thunder-wash-600-w",
        manufacturer: "Cameo",
        model: "Thunder Wash 600 W",
        nativeWidth: 1024,
        nativeHeight: 1024,
        minThrowRatio: 0.45,
        maxThrowRatio: 0.90,
        defaultThrowRatio: 0.60,
        maxLensShiftH: 0.0,
        maxLensShiftV: 0.0,
        lumens: 6500,
        bodySize: SIMD3<Float>(0.335, 0.093, 0.182),
        kind: .washPanel,
        colorTemperatureKelvin: 6500
    )

    /// Millumin Theatrical ERS / Découpe — Generic theatre ellipsoidal profile spot (`2 800 lm`, 3200K warm white, `15°–50°` zoom, 4 shutters).
    public static let milluminTheatricalERS = ProjectorSpec(
        id: "millumin-theatrical-ers",
        manufacturer: "Théâtre",
        model: "Découpe ERS (3200K)",
        nativeWidth: 1024,
        nativeHeight: 1024,
        minThrowRatio: 1.07,
        maxThrowRatio: 3.80,
        defaultThrowRatio: 1.95,
        maxLensShiftH: 0.0,
        maxLensShiftV: 0.0,
        lumens: 2800,
        bodySize: SIMD3<Float>(0.280, 0.560, 0.280),
        kind: .profileSpot,
        colorTemperatureKelvin: 3200
    )

    /// Millumin Theatrical PAR / Fresnel — Generic theatre wash / PC / Fresnel (`3 000 lm`, 3200K warm white, `20°–65°`).
    public static let milluminTheatricalPAR = ProjectorSpec(
        id: "millumin-theatrical-par",
        manufacturer: "Théâtre",
        model: "Projecteur PAR / PC (3200K)",
        nativeWidth: 1024,
        nativeHeight: 1024,
        minThrowRatio: 0.78,
        maxThrowRatio: 2.84,
        defaultThrowRatio: 1.40,
        maxLensShiftH: 0.0,
        maxLensShiftV: 0.0,
        lumens: 3000,
        bodySize: SIMD3<Float>(0.260, 0.340, 0.260),
        kind: .washPanel,
        colorTemperatureKelvin: 3200
    )

    /// Millumin Generic RGBW PAR — Standard LED RGBW PAR wash (`3 500 lm`, `18°–60°`).
    public static let milluminRGBWPar = ProjectorSpec(
        id: "millumin-rgbw-par",
        manufacturer: "LED",
        model: "PAR LED RGBW",
        nativeWidth: 1024,
        nativeHeight: 1024,
        minThrowRatio: 0.86,
        maxThrowRatio: 3.15,
        defaultThrowRatio: 1.54,
        maxLensShiftH: 0.0,
        maxLensShiftV: 0.0,
        lumens: 3500,
        bodySize: SIMD3<Float>(0.250, 0.240, 0.250),
        kind: .washPanel,
        colorTemperatureKelvin: nil
    )
}

/// Extensible catalog of video projector and stage lighting models.
public enum ProjectorCatalog {
    public static let all: [ProjectorSpec] = [
        // Video Projectors
        .panasonicPTRQ32K_ETD75LE30,
        .panasonicPTRQ32K_ETD3LEW50,
        .optomaZU920ST,
        .optomaZU920T,
        .optomaZU725TST,
        .optomaZU606TSTE,
        .optomaZH450ST,
        .optomaZH406ST,
        // Stage Lights
        .showtecPerformerProfileMini,
        .euroliteLEDPLL480QCL,
        .varytecHeroWash300FC,
        .varytecHeroWash340FX,
        .euroliteLEDML56RGBW,
        .adjIkonProfile,
        .stairvilleLEDFloodPanel150,
        .stairvilleOctagonTheater,
        .cameoThunderWash600W,
        .milluminTheatricalERS,
        .milluminTheatricalPAR,
        .milluminRGBWPar,
    ]

    /// Only video projector models (excludes stage lights).
    public static var videoProjectorSpecs: [ProjectorSpec] {
        all.filter { !$0.isStageLight }
    }

    /// Only stage light fixtures (profile spots, wash panels, moving heads, theatrical lights).
    public static var stageLightSpecs: [ProjectorSpec] {
        all.filter { $0.isStageLight }
    }

    public static func spec(for id: String) -> ProjectorSpec {
        let normalized = id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let exact = all.first(where: { $0.id.lowercased() == normalized }) {
            return exact
        }
        if normalized.contains("340fx") || normalized.contains("340 fx") || normalized.contains("340-fx") {
            return .varytecHeroWash340FX
        }
        if normalized.contains("varytec") || normalized.contains("hero") || normalized.contains("300 fc") || normalized.contains("300fc") || normalized.contains("300-fc") {
            return .varytecHeroWash300FC
        }
        if normalized.contains("ikon") || normalized.contains("american-dj") || normalized.contains("adj") {
            return .adjIkonProfile
        }
        if normalized.contains("ml-56") || normalized.contains("ml56") {
            return .euroliteLEDML56RGBW
        }
        if normalized.contains("octagon") {
            return .stairvilleOctagonTheater
        }
        if normalized.contains("flood-panel-150") || normalized.contains("flood panel 150") {
            return .stairvilleLEDFloodPanel150
        }
        if normalized.contains("thunder-wash") || normalized.contains("thunder wash") || normalized.contains("cameo") {
            return .cameoThunderWash600W
        }
        if normalized.contains("millumin-theatrical-ers") || normalized == "ers" {
            return .milluminTheatricalERS
        }
        if normalized.contains("millumin-theatrical-par") || normalized.contains("theatrical") {
            return .milluminTheatricalPAR
        }
        if normalized.contains("millumin-rgbw-par") || normalized.contains("rgb-par") || normalized.contains("rgbw-par") {
            return .milluminRGBWPar
        }
        if normalized.contains("showtec") || normalized.contains("performer") || normalized.contains("profile") || normalized.contains("decoupe") {
            return .showtecPerformerProfileMini
        }
        if normalized.contains("eurolite") || normalized.contains("pll") || normalized.contains("480") || normalized.contains("dalle") || normalized.contains("wash") {
            return .euroliteLEDPLL480QCL
        }
        if normalized.contains("d3lew50") || normalized.contains("lew50") {
            return .panasonicPTRQ32K_ETD3LEW50
        }
        if normalized.contains("rq32") || normalized.contains("d75le30") || normalized.contains("le30") {
            return .panasonicPTRQ32K_ETD75LE30
        }
        if normalized.contains("920t") && !normalized.contains("920st") {
            return .optomaZU920T
        }
        if normalized.contains("725") {
            return .optomaZU725TST
        }
        if normalized.contains("606") {
            return .optomaZU606TSTE
        }
        if normalized.contains("450") {
            return .optomaZH450ST
        }
        if normalized.contains("406") {
            return .optomaZH406ST
        }
        return .optomaZU920ST
    }
}

/// Visual test pattern, custom image, or live video stream (Syphon / NDI) projected by a `VideoProjector`.
public enum ProjectionPattern: String, Codable, CaseIterable, Sendable {
    case testGrid = "testGrid"
    case colorBars = "colorBars"
    case whiteFrame = "whiteFrame"
    case customImage = "customImage"
    case syphon = "syphon"
    case ndi = "ndi"
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
    /// Selected projection pattern, custom image, or live stream.
    public var pattern: ProjectionPattern
    /// File path to a custom projected image when `pattern == .customImage`.
    public var customImagePath: String?
    /// Live video source identifier when `pattern == .syphon` or `pattern == .ndi` (e.g. `"syphon:UUID"` or `"ndi:HOST (Stream)"`).
    public var liveSourceID: String?
    /// Human-readable / matchable source name for automatic reconnection across sessions when `pattern == .syphon` or `pattern == .ndi`.
    public var liveSourceName: String?
    /// Whether to draw the 3D projector body and wireframe frustum in the viewport.
    public var showsFrustum: Bool

    // Optical beam shaping (profile spots / découpes & wash panels)
    /// Framing shutter / couteau top insertion (`0.0 ... 1.0`, where 0 is fully open and 1 is fully closed).
    public var shutterTop: Float
    /// Framing shutter / couteau bottom insertion (`0.0 ... 1.0`).
    public var shutterBottom: Float
    /// Framing shutter / couteau left insertion (`0.0 ... 1.0`).
    public var shutterLeft: Float
    /// Framing shutter / couteau right insertion (`0.0 ... 1.0`).
    public var shutterRight: Float
    /// Edge sharpness / softness factor (`0.0 ... 1.0`, where 0 is razor-sharp knife edge and 1 is diffused wash).
    public var edgeSoftness: Float
    /// Optical color tint / RGB emitter channels (normalized linear RGB `[0...1]`, e.g. warm 3200K tungsten / COB LED tint or RGB wash channels).
    public var lightColor: SIMD3<Float>
    /// Dedicated 4th White LED emitter channel (`0.0 ... 1.0`) for RGBW stage lighting fixtures (Eurolite PLL-480 QCL, Varytec Hero Wash 300 FC, LED PAR RGBW, OFL fixtures).
    public var whiteChannel: Float

    // DMX & Art-Net Patch
    /// DMX Universe (`0 ... 15` in Art-Net Sub-Net 0).
    public var dmxUniverse: Int
    /// DMX Start Channel (`1 ... 512`).
    public var dmxChannel: Int
    /// DMX Personality / Profile mode:
    /// - `"dimmer1ch"`: 1 channel (Intensity / Dimmer)
    /// - `"rgbw4ch"`: 4 channels (Red, Green, Blue, White)
    /// - `"dimmerRgbw6ch"`: 6 channels (Dimmer, Shutter/Strobe, Red, Green, Blue, White)
    /// - `"ofl"`: Custom Open Fixture Library (OFL) channel map defined by `dmxChannelRoles`
    public var dmxMode: String
    /// Millumin / Open Fixture Library identifier (e.g. `"varytec/hero-wash-300-fc"`, `"eurolite/led-ml-56-rgbw"`).
    public var oflFixtureID: String?
    /// Active OFL mode name (e.g. `"15-channel"`, `"6-channel"`, `"ERS"`).
    public var oflModeName: String?
    /// Ordered DMX channel names for the active OFL mode (1-to-1 with `dmxChannelRoles`).
    public var dmxChannelNames: [String]
    /// Ordered DMX channel roles for the active OFL mode (starting at `dmxChannel`).
    public var dmxChannelRoles: [DMXChannelRole]

    private enum CodingKeys: String, CodingKey {
        case id, name, specID, isEnabled, position, target, rollDegrees, throwRatio, lensShiftH, lensShiftV, intensity, reverbIntensity, pattern, customImagePath, liveSourceID, liveSourceName, showsFrustum
        case shutterTop, shutterBottom, shutterLeft, shutterRight, edgeSoftness, lightColor, whiteChannel
        case dmxUniverse, dmxChannel, dmxMode
        case oflFixtureID, oflModeName, dmxChannelNames, dmxChannelRoles
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
        liveSourceID: String? = nil,
        liveSourceName: String? = nil,
        showsFrustum: Bool = true,
        shutterTop: Float = 0.0,
        shutterBottom: Float = 0.0,
        shutterLeft: Float = 0.0,
        shutterRight: Float = 0.0,
        edgeSoftness: Float? = nil,
        lightColor: SIMD3<Float>? = nil,
        whiteChannel: Float = 0.0,
        dmxUniverse: Int = 0,
        dmxChannel: Int = 1,
        dmxMode: String = "dimmer1ch",
        oflFixtureID: String? = nil,
        oflModeName: String? = nil,
        dmxChannelNames: [String] = [],
        dmxChannelRoles: [DMXChannelRole] = []
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
        self.liveSourceID = liveSourceID
        self.liveSourceName = liveSourceName
        self.showsFrustum = showsFrustum
        self.shutterTop = simd_clamp(shutterTop, 0.0, 1.0)
        self.shutterBottom = simd_clamp(shutterBottom, 0.0, 1.0)
        self.shutterLeft = simd_clamp(shutterLeft, 0.0, 1.0)
        self.shutterRight = simd_clamp(shutterRight, 0.0, 1.0)
        if let es = edgeSoftness {
            self.edgeSoftness = simd_clamp(es, 0.0, 1.0)
        } else {
            switch resolvedSpec.kind {
            case .profileSpot:
                self.edgeSoftness = 0.05
            case .washPanel:
                self.edgeSoftness = 0.85
            case .videoProjector:
                self.edgeSoftness = 0.0
            }
        }
        if let lc = lightColor {
            self.lightColor = simd_clamp(lc, SIMD3<Float>(repeating: 0), SIMD3<Float>(repeating: 1))
        } else {
            if resolvedSpec.kind == .profileSpot || resolvedSpec.colorTemperatureKelvin == 3200 {
                // Default 3200K warm white tint
                self.lightColor = SIMD3<Float>(1.0, 0.86, 0.68)
            } else {
                self.lightColor = SIMD3<Float>(1.0, 1.0, 1.0)
            }
        }
        self.whiteChannel = simd_clamp(whiteChannel, 0.0, 1.0)
        self.dmxUniverse = max(0, min(15, dmxUniverse))
        self.dmxChannel = max(1, min(512, dmxChannel))
        self.dmxMode = dmxMode
        self.oflFixtureID = oflFixtureID
        self.oflModeName = oflModeName
        self.dmxChannelNames = dmxChannelNames
        self.dmxChannelRoles = dmxChannelRoles
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
        let liveSourceID = try c.decodeIfPresent(String.self, forKey: .liveSourceID)
        let liveSourceName = try c.decodeIfPresent(String.self, forKey: .liveSourceName)
        let showsFrustum = try c.decode(Bool.self, forKey: .showsFrustum)
        let sTop = try c.decodeIfPresent(Float.self, forKey: .shutterTop) ?? 0.0
        let sBottom = try c.decodeIfPresent(Float.self, forKey: .shutterBottom) ?? 0.0
        let sLeft = try c.decodeIfPresent(Float.self, forKey: .shutterLeft) ?? 0.0
        let sRight = try c.decodeIfPresent(Float.self, forKey: .shutterRight) ?? 0.0
        let edgeSoft = try c.decodeIfPresent(Float.self, forKey: .edgeSoftness)
        let lColor = try c.decodeIfPresent(SIMD3<Float>.self, forKey: .lightColor)
        let wChan = try c.decodeIfPresent(Float.self, forKey: .whiteChannel) ?? 0.0
        let dmxUni = try c.decodeIfPresent(Int.self, forKey: .dmxUniverse) ?? 0
        let dmxChan = try c.decodeIfPresent(Int.self, forKey: .dmxChannel) ?? 1
        let dmxMod = try c.decodeIfPresent(String.self, forKey: .dmxMode) ?? "dimmer1ch"
        let oflID = try c.decodeIfPresent(String.self, forKey: .oflFixtureID)
        let oflMode = try c.decodeIfPresent(String.self, forKey: .oflModeName)
        let chanNames = try c.decodeIfPresent([String].self, forKey: .dmxChannelNames) ?? []
        let chanRoles = try c.decodeIfPresent([DMXChannelRole].self, forKey: .dmxChannelRoles) ?? []
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
            liveSourceID: liveSourceID,
            liveSourceName: liveSourceName,
            showsFrustum: showsFrustum,
            shutterTop: sTop,
            shutterBottom: sBottom,
            shutterLeft: sLeft,
            shutterRight: sRight,
            edgeSoftness: edgeSoft,
            lightColor: lColor,
            whiteChannel: wChan,
            dmxUniverse: dmxUni,
            dmxChannel: dmxChan,
            dmxMode: dmxMod,
            oflFixtureID: oflID,
            oflModeName: oflMode,
            dmxChannelNames: chanNames,
            dmxChannelRoles: chanRoles
        )
    }

    /// True when this element is a stage light (profile spot, wash panel, moving head, or OFL fixture) rather than a video projector.
    public var isStageLight: Bool {
        spec.isStageLight || oflFixtureID != nil
    }

    /// Combined linear RGB spectral emission of the fixture, mixing the R, G, B emitters (`lightColor`)
    /// with the dedicated 4th White LED diode (`whiteChannel`, ~4000K neutral-warm white).
    public var effectiveBeamRGB: SIMD3<Float> {
        let rgb = simd_clamp(lightColor, .zero, SIMD3<Float>(repeating: 1.0))
        let w = simd_clamp(whiteChannel, 0.0, 1.0)
        guard isStageLight, w > 0.0005 else { return rgb }
        let whiteDiode = SIMD3<Float>(1.0, 0.95, 0.88) * w
        let sum = rgb + whiteDiode
        let peak = max(sum.x, max(sum.y, sum.z))
        if peak > 1.0 {
            let boost = min(1.0 + 0.35 * w, 1.35)
            return (sum / peak) * boost
        }
        return sum
    }

    /// Number of DMX channels occupied by this fixture.
    public var dmxChannelCount: Int {
        if !dmxChannelRoles.isEmpty {
            return dmxChannelRoles.count
        }
        switch dmxMode {
        case "rgbw4ch": return 4
        case "dimmerRgbw6ch": return 6
        default: return 1
        }
    }

    /// Applies a 512-channel DMX universe frame (`0.0 ... 1.0` per channel) to this light/projector.
    /// Uses `dmxChannelRoles` when populated (from OFL / Millumin fixture definition) or falls back to `dmxMode`.
    /// Returns `true` if any optical/photometric property changed noticeably.
    public mutating func applyDMXValues(_ universeChannels: [Float]) -> Bool {
        let baseIdx = max(0, min(511, dmxChannel - 1))
        guard baseIdx < universeChannels.count else { return false }

        if !dmxChannelRoles.isEmpty {
            return applyRoleMappedValues(
                roles: dmxChannelRoles,
                valueAt: { offset in
                    let idx = baseIdx + offset
                    return idx < universeChannels.count ? universeChannels[idx] : 0.0
                }
            )
        }

        var changed = false
        switch dmxMode {
        case "rgbw4ch":
            if baseIdx + 3 < universeChannels.count {
                let r = simd_clamp(universeChannels[baseIdx], 0.0, 1.0)
                let g = simd_clamp(universeChannels[baseIdx + 1], 0.0, 1.0)
                let b = simd_clamp(universeChannels[baseIdx + 2], 0.0, 1.0)
                let w = simd_clamp(universeChannels[baseIdx + 3], 0.0, 1.0)
                let newRGB = SIMD3<Float>(r, g, b)
                let maxEmitter = max(max(r, g), max(b, w))
                let newIntensity: Float = maxEmitter > 0.001 ? 1.0 : 0.0
                if abs(intensity - newIntensity) > 0.002 || simd_distance(lightColor, newRGB) > 0.003 || abs(whiteChannel - w) > 0.003 {
                    intensity = newIntensity
                    lightColor = newRGB
                    whiteChannel = w
                    changed = true
                }
            }
        case "dimmerRgbw6ch":
            if baseIdx + 5 < universeChannels.count {
                let dim = simd_clamp(universeChannels[baseIdx], 0.0, 1.0)
                let r = simd_clamp(universeChannels[baseIdx + 2], 0.0, 1.0)
                let g = simd_clamp(universeChannels[baseIdx + 3], 0.0, 1.0)
                let b = simd_clamp(universeChannels[baseIdx + 4], 0.0, 1.0)
                let w = simd_clamp(universeChannels[baseIdx + 5], 0.0, 1.0)
                let newRGB = SIMD3<Float>(r, g, b)
                if abs(intensity - dim) > 0.002 || simd_distance(lightColor, newRGB) > 0.003 || abs(whiteChannel - w) > 0.003 {
                    intensity = dim
                    lightColor = newRGB
                    whiteChannel = w
                    changed = true
                }
            }
        default: // "dimmer1ch"
            let dim = universeChannels[baseIdx]
            if abs(intensity - dim) > 0.002 {
                intensity = dim
                changed = true
            }
        }
        return changed
    }

    /// Applies named channel values from a Millumin cue (`FCLightStateMedia` dictionary, where keys are `"___Red"`, `"___Dimmer"`, etc., and values are either `0 ... 255` DMX bytes or `0.0 ... 1.0` normalized floats).
    public mutating func applyMilluminCueValues(_ rawValues: [String: Float]) -> Bool {
        let uses255Scale = rawValues.values.contains { $0 > 1.001 }
        let scale: Float = uses255Scale ? (1.0 / 255.0) : 1.0
        var roles: [DMXChannelRole] = []
        var vals: [Float] = []
        for (rawKey, rawVal) in rawValues {
            let cleanName = rawKey.hasPrefix("___") ? String(rawKey.dropFirst(3)) : rawKey
            let role = DMXChannelRole.classify(name: cleanName)
            let normalized = simd_clamp(rawVal * scale, 0.0, 1.0)
            roles.append(role)
            vals.append(normalized)
        }
        guard !roles.isEmpty else { return false }
        return applyRoleMappedValues(roles: roles, valueAt: { vals[$0] })
    }

    private mutating func applyRoleMappedValues(
        roles: [DMXChannelRole],
        valueAt: (Int) -> Float
    ) -> Bool {
        var dimmerVal: Float?
        var redVal: Float?
        var greenVal: Float?
        var blueVal: Float?
        var whiteVal: Float = 0.0
        var warmWhiteVal: Float = 0.0
        var coldWhiteVal: Float = 0.0
        var amberVal: Float = 0.0
        var uvVal: Float = 0.0
        var zoomVal: Float?
        var hasColorChannels = false

        for (i, role) in roles.enumerated() {
            let v = simd_clamp(valueAt(i), 0.0, 1.0)
            switch role {
            case .dimmer:
                dimmerVal = v
            case .red:
                redVal = v
                hasColorChannels = true
            case .green:
                greenVal = v
                hasColorChannels = true
            case .blue:
                blueVal = v
                hasColorChannels = true
            case .white:
                whiteVal = max(whiteVal, v)
                hasColorChannels = true
            case .warmWhite:
                warmWhiteVal = max(warmWhiteVal, v)
                hasColorChannels = true
            case .coldWhite:
                coldWhiteVal = max(coldWhiteVal, v)
                hasColorChannels = true
            case .amber:
                amberVal = max(amberVal, v)
                hasColorChannels = true
            case .uv:
                uvVal = max(uvVal, v)
                hasColorChannels = true
            case .cyan:
                redVal = max(0.0, (redVal ?? 1.0) - v)
                hasColorChannels = true
            case .magenta:
                greenVal = max(0.0, (greenVal ?? 1.0) - v)
                hasColorChannels = true
            case .yellow:
                blueVal = max(0.0, (blueVal ?? 1.0) - v)
                hasColorChannels = true
            case .zoom:
                zoomVal = v
            case .focus, .strobe, .pan, .tilt, .colorTemperature, .colorMacro, .other, .ignored:
                break
            }
        }

        var changed = false

        if hasColorChannels {
            let r = min(1.0, (redVal ?? 0.0)
                + warmWhiteVal * 1.00
                + coldWhiteVal * 0.92
                + amberVal * 1.00
                + uvVal * 0.45)
            let g = min(1.0, (greenVal ?? 0.0)
                + warmWhiteVal * 0.86
                + coldWhiteVal * 0.96
                + amberVal * 0.58
                + uvVal * 0.10)
            let b = min(1.0, (blueVal ?? 0.0)
                + warmWhiteVal * 0.68
                + coldWhiteVal * 1.00
                + amberVal * 0.08
                + uvVal * 0.95)
            let w = min(1.0, whiteVal)

            let newRGB = SIMD3<Float>(r, g, b)
            let maxEmitter = max(max(r, g), max(b, w))
            let newIntensity: Float
            if let dim = dimmerVal {
                newIntensity = dim
            } else {
                newIntensity = maxEmitter > 0.001 ? 1.0 : 0.0
            }

            if abs(intensity - newIntensity) > 0.002 || simd_distance(lightColor, newRGB) > 0.003 || abs(whiteChannel - w) > 0.003 {
                intensity = newIntensity
                lightColor = newRGB
                whiteChannel = w
                changed = true
            }
        } else if let dim = dimmerVal {
            if abs(intensity - dim) > 0.002 {
                intensity = dim
                changed = true
            }
        }

        if let z = zoomVal, (spec.maxThrowRatio - spec.minThrowRatio) > 0.05 {
            // DMX Zoom: 0 = tightest beam (maxThrowRatio) or widest depending on fixture; map smoothly across zoom range
            let newTR = spec.minThrowRatio + (1.0 - z) * (spec.maxThrowRatio - spec.minThrowRatio)
            if abs(throwRatio - newTR) > 0.01 {
                throwRatio = simd_clamp(newTR, spec.minThrowRatio, spec.maxThrowRatio)
                changed = true
            }
        }

        return changed
    }

    /// Beam spread angle in degrees (full angle along the horizontal axis).
    public var beamAngleDegrees: Float {
        get {
            2.0 * atan(1.0 / (2.0 * max(throwRatio, 0.05))) * 180.0 / .pi
        }
        set {
            let rad = max(newValue, 1.0) * .pi / 180.0
            let tr = 1.0 / (2.0 * tan(rad / 2.0))
            throwRatio = simd_clamp(tr, spec.minThrowRatio, spec.maxThrowRatio)
        }
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

    /// Hashable key capturing all parameters that affect a projector's 3D optical geometry, frustum rays, and shadow depth map.
    /// Changes to `name`, `intensity`, `reverbIntensity`, `pattern`, `customImagePath`, `liveSourceID`, or `showsFrustum`
    /// do not alter `opticalPoseKey`, allowing the renderer to reuse cached depth maps and raycast hits.
    public struct OpticalPoseKey: Hashable, Sendable {
        public let specID: String
        public let posX: Int32
        public let posY: Int32
        public let posZ: Int32
        public let tgtX: Int32
        public let tgtY: Int32
        public let tgtZ: Int32
        public let roll: Int32
        public let throwRatio: Int32
        public let shiftH: Int32
        public let shiftV: Int32

        @inline(__always)
        private static func quantize(_ value: Float, scale: Float) -> Int32 {
            guard value.isFinite else { return 0 }
            let scaled = (value * scale).rounded()
            if scaled >= Float(Int32.max) { return Int32.max }
            if scaled <= Float(Int32.min) { return Int32.min }
            return Int32(scaled)
        }

        public init(projector: VideoProjector) {
            self.specID = projector.specID
            self.posX = Self.quantize(projector.position.x, scale: 10_000)
            self.posY = Self.quantize(projector.position.y, scale: 10_000)
            self.posZ = Self.quantize(projector.position.z, scale: 10_000)
            self.tgtX = Self.quantize(projector.target.x, scale: 10_000)
            self.tgtY = Self.quantize(projector.target.y, scale: 10_000)
            self.tgtZ = Self.quantize(projector.target.z, scale: 10_000)
            self.roll = Self.quantize(projector.rollDegrees, scale: 1_000)
            self.throwRatio = Self.quantize(projector.throwRatio, scale: 10_000)
            self.shiftH = Self.quantize(projector.lensShiftH, scale: 10_000)
            self.shiftV = Self.quantize(projector.lensShiftV, scale: 10_000)
        }
    }

    public var opticalPoseKey: OpticalPoseKey {
        OpticalPoseKey(projector: self)
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

    /// Projected image cross-sectional area in square metres at distance `d` (defaults to `throwDistance`).
    public func projectedArea(atDistance d: Float? = nil) -> Float {
        let w = projectedWidth(atDistance: d)
        let h = projectedHeight(atDistance: d)
        return max(w * h, 0.001)
    }

    /// Estimated optical transmission efficiency of the lens (`0.0 ... 1.0`),
    /// accounting for internal glass multi-coating transmission (~90%) and zoom-dependent aperture loss.
    public var lensTransmission: Float {
        let s = spec
        let denom = max(s.maxThrowRatio - s.minThrowRatio, 0.001)
        let zoomFraction = simd_clamp((throwRatio - s.minThrowRatio) / denom, 0.0, 1.0)
        // Zooming to telephoto (higher throw ratio) narrows maximum aperture, causing ~12% light loss
        let zoomLoss = 1.0 - 0.12 * zoomFraction
        return 0.90 * zoomLoss
    }

    /// Effective luminous flux emitted in ANSI lumens, taking into account `intensity` dimmer and lens transmission.
    public var effectiveLumens: Float {
        Float(spec.lumens) * intensity * lensTransmission
    }

    /// Theoretical on-axis illuminance in Lux (`Lumens / m²`) at distance `d` (defaults to `throwDistance`).
    public func illuminanceLux(atDistance d: Float? = nil) -> Float {
        let area = projectedArea(atDistance: d)
        return max(0, effectiveLumens / area)
    }

    /// Estimated reflected luminance in cd/m² (Nits) on a Lambertian diffuse surface with given optical gain (default `1.0`).
    public func surfaceLuminanceNits(atDistance d: Float? = nil, screenGain: Float = 1.0) -> Float {
        (illuminanceLux(atDistance: d) * max(screenGain, 0.1)) / .pi
    }

    /// Estimated reflected luminance in Foot-Lamberts (fL) on a screen with given optical gain (default `1.0`).
    public func surfaceLuminanceFootLamberts(atDistance d: Float? = nil, screenGain: Float = 1.0) -> Float {
        surfaceLuminanceNits(atDistance: d, screenGain: screenGain) / 3.426259
    }

    public enum PhotometricRating: Sendable {
        case lowContrast       // < 120 lux
        case theaterAmbiance   // 120 - 300 lux
        case optimalMapping    // 300 - 800 lux
        case highPunch         // > 800 lux

        public var localizedTitle: String {
            switch self {
            case .lowContrast:
                return L("Faible (< 120 lx)", "Low (< 120 lx)")
            case .theaterAmbiance:
                return L("Théâtre (120–300 lx)", "Theater (120–300 lx)")
            case .optimalMapping:
                return L("Optimal (300–800 lx)", "Optimal (300–800 lx)")
            case .highPunch:
                return L("Percutant (> 800 lx)", "Punchy (> 800 lx)")
            }
        }

        public var localizedHint: String {
            switch self {
            case .lowContrast:
                return L("Image pâle si la salle est éclairée. Recommandé en noir total ou rapprocher le projecteur.",
                         "Pale image if stage lights are on. Recommended in blackout or move projector closer.")
            case .theaterAmbiance:
                return L("Parfait pour toiles, tulles et scénographies poétiques en pénombre contrôlée.",
                         "Ideal for cyclorama, scrims and poetic scenography in controlled dim stage lighting.")
            case .optimalMapping:
                return L("Éclairement standard pour mapping scénique, très bonne lisibilité avec lumière de plateau.",
                         "Standard illuminance for stage mapping, crisp readability under ambient stage light.")
            case .highPunch:
                return L("Contraste très fort, lisibilité vive même avec projecteurs traditionnels allumés.",
                         "High contrast and vivid pop even with traditional stage lights on.")
            }
        }
    }

    public func photometricRating(atDistance d: Float? = nil) -> PhotometricRating {
        let lux = illuminanceLux(atDistance: d)
        if lux < 120 { return .lowContrast }
        if lux < 300 { return .theaterAmbiance }
        if lux <= 800 { return .optimalMapping }
        return .highPunch
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
        public var photometricSimulation: Bool?
        public var photometricReferenceLux: Float?

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
            pointLights: [PointLightState],
            photometricSimulation: Bool? = nil,
            photometricReferenceLux: Float? = nil
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
            self.photometricSimulation = photometricSimulation
            self.photometricReferenceLux = photometricReferenceLux
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
