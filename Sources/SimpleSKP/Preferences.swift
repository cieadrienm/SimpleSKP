import Foundation

/// User settings with a default in code: without `register()` (tests) they still read the default.
/// The language is kept by `Localization` itself.
enum Preferences {
    enum Key {
        static let showSidebar = "showSidebar"
        static let showsEdges = "showsEdges"
        static let isPerspective = "isPerspective"
    }

    static let defaults: [String: Any] = [
        Key.showSidebar: true,
        Key.showsEdges: true,
        Key.isPerspective: true,
    ]

    static func register() {
        UserDefaults.standard.register(defaults: defaults)
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

    /// Used when the file has no saved camera; a saved camera keeps its own projection.
    static var isPerspective: Bool {
        get { bool(Key.isPerspective) }
        set { UserDefaults.standard.set(newValue, forKey: Key.isPerspective) }
    }
}
