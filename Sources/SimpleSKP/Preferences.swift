import Foundation
import simd
import SimpleSKPCore
import SimpleSKPViewport

/// User settings with a default in code: without `register()` (tests) they still read the default.
/// The language is kept by `Localization` itself.
enum Preferences {
    enum Key {
        static let showSidebar = "showSidebar"
        static let showsEdges = "showsEdges"
        static let showsGrid = "showsGrid"
        static let isPerspective = "isPerspective"
        static let shadowsEnabled = "shadowsEnabled"
        static let ambientOcclusionEnabled = "ambientOcclusionEnabled"
        static let ambientOcclusionIntensity = "ambientOcclusionIntensity"
        static let backdropStyle = "backdropStyle"
        static let customBackdropR = "customBackdropR"
        static let customBackdropG = "customBackdropG"
        static let customBackdropB = "customBackdropB"
        static let twoFingerScrollZooms = "twoFingerScrollZooms"
        static let oscFeedbackEnabled = "oscFeedbackEnabled"
        static let oscOutHost = "oscOutHost"
        static let oscOutPort = "oscOutPort"
        static let hiddenFeatures = "hiddenFeatures"
    }

    static let defaults: [String: Any] = [
        Key.showSidebar: true,
        Key.showsEdges: true,
        Key.showsGrid: false,
        Key.isPerspective: true,
        Key.shadowsEnabled: true,
        Key.ambientOcclusionEnabled: false, // no SSAO setting gave corner shading without floor bands or speckles (fix-navrender)
        Key.ambientOcclusionIntensity: Float(Rendering.defaultAmbientOcclusionIntensity),
        Key.backdropStyle: BackdropStyle.architecturalSky.rawValue,
        Key.customBackdropR: Rendering.defaultCustomBackdropColor.x,
        Key.customBackdropG: Rendering.defaultCustomBackdropColor.y,
        Key.customBackdropB: Rendering.defaultCustomBackdropColor.z,
        Key.twoFingerScrollZooms: false,
        Key.oscFeedbackEnabled: true,
        Key.oscOutHost: "127.0.0.1",
        Key.oscOutPort: Int(kSimpleSKPDefaultOSCOutPort),
        Key.hiddenFeatures: false,
    ]

    @MainActor static func register() {
        UserDefaults.standard.register(defaults: defaults)
        ViewportView.twoFingerScrollZooms = twoFingerScrollZooms
    }

    private static func bool(_ key: String) -> Bool {
        UserDefaults.standard.object(forKey: key) != nil ? UserDefaults.standard.bool(forKey: key) : defaults[key] as! Bool
    }

    /// Last choice of the user; false keeps the sidebar hidden even on a model with scenes.
    static var showSidebar: Bool {
        get { bool(Key.showSidebar) }
        set { UserDefaults.standard.set(newValue, forKey: Key.showSidebar) }
    }

    static var showsEdges: Bool {
        get { bool(Key.showsEdges) }
        set { UserDefaults.standard.set(newValue, forKey: Key.showsEdges) }
    }

    static var showsGrid: Bool {
        get { bool(Key.showsGrid) }
        set { UserDefaults.standard.set(newValue, forKey: Key.showsGrid) }
    }

    static var backdropStyle: BackdropStyle {
        get {
            guard let raw = UserDefaults.standard.string(forKey: Key.backdropStyle),
                  let style = BackdropStyle(rawValue: raw) else {
                return .architecturalSky
            }
            return style
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Key.backdropStyle) }
    }

    static var customBackdropColor: SIMD3<Float> {
        get {
            let ud = UserDefaults.standard
            guard ud.object(forKey: Key.customBackdropR) != nil else {
                return Rendering.defaultCustomBackdropColor
            }
            return SIMD3(
                ud.float(forKey: Key.customBackdropR),
                ud.float(forKey: Key.customBackdropG),
                ud.float(forKey: Key.customBackdropB)
            )
        }
        set {
            let ud = UserDefaults.standard
            ud.set(newValue.x, forKey: Key.customBackdropR)
            ud.set(newValue.y, forKey: Key.customBackdropG)
            ud.set(newValue.z, forKey: Key.customBackdropB)
        }
    }

    /// « Ombres » and « Occlusion ambiante » (D7: remembered), read when a document opens.
    static var shadowsEnabled: Bool {
        get { bool(Key.shadowsEnabled) }
        set { UserDefaults.standard.set(newValue, forKey: Key.shadowsEnabled) }
    }

    static var ambientOcclusionEnabled: Bool {
        get { bool(Key.ambientOcclusionEnabled) }
        set { UserDefaults.standard.set(newValue, forKey: Key.ambientOcclusionEnabled) }
    }

    static var ambientOcclusionIntensity: Float {
        get {
            UserDefaults.standard.object(forKey: Key.ambientOcclusionIntensity) != nil
                ? UserDefaults.standard.float(forKey: Key.ambientOcclusionIntensity)
                : Float(Rendering.defaultAmbientOcclusionIntensity)
        }
        set { UserDefaults.standard.set(newValue, forKey: Key.ambientOcclusionIntensity) }
    }

    /// Used when the file has no saved camera; a saved camera keeps its own projection.
    static var isPerspective: Bool {
        get { bool(Key.isPerspective) }
        set { UserDefaults.standard.set(newValue, forKey: Key.isPerspective) }
    }

    /// « Défilement à deux doigts : zoom » for a Magic Mouse; orbit by default. Every open viewport reads it live.
    @MainActor static var twoFingerScrollZooms: Bool {
        get { bool(Key.twoFingerScrollZooms) }
        set {
            UserDefaults.standard.set(newValue, forKey: Key.twoFingerScrollZooms)
            ViewportView.twoFingerScrollZooms = newValue
        }
    }

    static var oscFeedbackEnabled: Bool {
        get { bool(Key.oscFeedbackEnabled) }
        set { UserDefaults.standard.set(newValue, forKey: Key.oscFeedbackEnabled) }
    }

    static var oscOutHost: String {
        get { UserDefaults.standard.string(forKey: Key.oscOutHost) ?? "127.0.0.1" }
        set { UserDefaults.standard.set(newValue, forKey: Key.oscOutHost) }
    }

    static var oscOutPort: UInt16 {
        get {
            if let env = ProcessInfo.processInfo.environment["SIMPLESKP_OSC_OUT_PORT"],
               let p = UInt16(env) {
                return p
            }
            let val = UserDefaults.standard.integer(forKey: Key.oscOutPort)
            return val > 0 && val <= 65535 ? UInt16(val) : kSimpleSKPDefaultOSCOutPort
        }
        set { UserDefaults.standard.set(Int(newValue), forKey: Key.oscOutPort) }
    }

    static var hiddenFeatures: Bool {
        get { bool(Key.hiddenFeatures) }
        set {
            UserDefaults.standard.set(newValue, forKey: Key.hiddenFeatures)
            NotificationCenter.default.post(name: .hiddenFeaturesChanged, object: nil)
        }
    }
}

extension Notification.Name {
    static let hiddenFeaturesChanged = Notification.Name("SimpleSKP.hiddenFeaturesChanged")
}
