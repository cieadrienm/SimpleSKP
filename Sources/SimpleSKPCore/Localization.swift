import Foundation

/// Supported UI languages across the Simple app family.
public enum AppLanguage: String, CaseIterable, Identifiable, Codable, Sendable {
    case system
    case fr
    case en

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .system: return L("Système", "System")
        case .fr: return "Français"
        case .en: return "English"
        }
    }

    /// Resolved two-letter language code (`"fr"` or `"en"`).
    public var resolvedCode: String {
        switch self {
        case .fr:
            return "fr"
        case .en:
            return "en"
        case .system:
            if let envLang = ProcessInfo.processInfo.environment["SIMPLE_LANG"]?.lowercased() {
                if envLang.hasPrefix("en") { return "en" }
                if envLang.hasPrefix("fr") { return "fr" }
            }
            let args = CommandLine.arguments
            if let idx = args.firstIndex(of: "--lang"), idx + 1 < args.count {
                let arg = args[idx + 1].lowercased()
                if arg.hasPrefix("en") { return "en" }
                if arg.hasPrefix("fr") { return "fr" }
            }
            let preferred = Locale.preferredLanguages.first?.lowercased() ?? "fr"
            return preferred.hasPrefix("en") ? "en" : "fr"
        }
    }

    public var isEnglish: Bool {
        resolvedCode == "en"
    }

    public var locale: Locale {
        Locale(identifier: resolvedCode)
    }
}

/// Global language selector persisted in UserDefaults (`net.cieadrienm.simpleskp.language`).
public enum Localization {
    private static let defaultsKey = "net.cieadrienm.simpleskp.language"
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _current: AppLanguage = {
        let args = CommandLine.arguments
        if let idx = args.firstIndex(of: "--lang"), idx + 1 < args.count {
            let arg = args[idx + 1].lowercased()
            if arg.hasPrefix("en") { return .en }
            if arg.hasPrefix("fr") { return .fr }
        }
        if let raw = UserDefaults.standard.string(forKey: defaultsKey),
           let lang = AppLanguage(rawValue: raw) {
            return lang
        }
        return .system
    }()

    public static var current: AppLanguage {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _current
        }
        set {
            lock.lock()
            _current = newValue
            lock.unlock()
            UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey)
            if newValue == .system {
                UserDefaults.standard.removeObject(forKey: "AppleLanguages")
            } else {
                UserDefaults.standard.set([newValue.rawValue], forKey: "AppleLanguages")
            }
        }
    }

    public static var isEnglish: Bool {
        current.isEnglish
    }
}

/// Returns `en` when the active language is English, otherwise `fr`.
@inline(__always)
public func L(_ fr: String, _ en: String) -> String {
    Localization.isEnglish ? en : fr
}
