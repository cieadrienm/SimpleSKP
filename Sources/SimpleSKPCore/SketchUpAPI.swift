import Foundation

/// Locates and dynamically loads the SketchUp SDK's `SketchUpAPI.framework` (C API). Search order:
/// 0. `$SIMPLESKP_SKETCHUP_SDK` (a path to a `.framework`: tests, development; ignored by the bundled app, which must not
///    load code an environment variable points at),
/// 1. `SimpleSKP.app/Contents/Frameworks/SketchUpAPI.framework` (shipped in the app by `Scripts/bundle.sh`, D1),
/// then, unless `$SIMPLESKP_BUNDLED_SDK_ONLY` is set (proof that the app needs no SketchUp):
/// 2. `/Applications/SketchUp*.app/Contents/Frameworks/SketchUpAPI.framework` and `~/Applications/…`, newest first
///    (the framework's `@rpath` siblings `libCommon*.dylib` live next to it and must be preloaded by absolute path),
/// 3. `/Applications/Unity/Hub/Editor/*/Unity.app/Contents/Frameworks/SketchUpAPI.framework` (self-contained: `Versions/A/Libraries`).
public enum SketchUpAPI {
    public struct Location: Sendable, Equatable {
        public let frameworkURL: URL
        /// Version of the host application the framework came with (e.g. "23.0.396"), when known.
        public let appVersion: String?
        /// The framework shipped inside SimpleSKP.app.
        public let isBundled: Bool
        public init(frameworkURL: URL, appVersion: String?, isBundled: Bool = false) {
            self.frameworkURL = frameworkURL; self.appVersion = appVersion; self.isBundled = isBundled
        }
    }

    /// Candidate directories searched, for diagnostics (`SKPError.sketchUpNotFound(searched:)`).
    public static var searchedURLs: [URL] { candidates().map(\.frameworkURL) }

    public static func locate() -> Location? {
        candidates().first { FileManager.default.fileExists(atPath: $0.frameworkURL.appendingPathComponent("SketchUpAPI").path) }
    }

    public static var isAvailable: Bool { locate() != nil }

    static let frameworkPath = "Contents/Frameworks/SketchUpAPI.framework"

    /// Running as SimpleSKP.app (not `swift run`, not the tests).
    static var isBundledApp: Bool { Bundle.main.bundleIdentifier == "net.cieadrienm.simpleskp" }

    static func candidates() -> [Location] {
        // getenv, not ProcessInfo: the tests change the variables with setenv.
        func env(_ name: String) -> String? { getenv(name).map { String(cString: $0) } }
        var found: [Location] = []
        if let sdk = env("SIMPLESKP_SKETCHUP_SDK"), !isBundledApp { found.append(Location(frameworkURL: URL(fileURLWithPath: sdk), appVersion: nil)) }
        found.append(Location(frameworkURL: Bundle.main.bundleURL.appendingPathComponent(frameworkPath), appVersion: nil, isBundled: true))
        if env("SIMPLESKP_BUNDLED_SDK_ONLY") != nil { return found }

        let fm = FileManager.default
        func children(_ dir: URL) -> [URL] {
            (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        }
        func isSketchUp(_ url: URL) -> Bool { url.lastPathComponent.hasPrefix("SketchUp") }

        var apps: [URL] = []
        for base in [URL(fileURLWithPath: "/Applications"), fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications")] {
            for entry in children(base) where isSketchUp(entry) {
                if entry.pathExtension == "app" { apps.append(entry) }
                else { apps += children(entry).filter { isSketchUp($0) && $0.pathExtension == "app" } }
            }
        }
        let hosts = apps
            .map { Location(frameworkURL: $0.appendingPathComponent(frameworkPath), appVersion: Bundle(url: $0)?.infoDictionary?["CFBundleShortVersionString"] as? String) }
            .sorted { ($0.appVersion ?? "").compare($1.appVersion ?? "", options: .numeric) == .orderedDescending }
        let unity = children(URL(fileURLWithPath: "/Applications/Unity/Hub/Editor"))
            .sorted { $0.lastPathComponent.compare($1.lastPathComponent, options: .numeric) == .orderedDescending }
            .map { Location(frameworkURL: $0.appendingPathComponent("Unity.app").appendingPathComponent(frameworkPath), appVersion: nil) }
        return found + hosts + unity
    }

    private static let loadLock = NSLock()
    nonisolated(unsafe) private static var loaded: Functions?

    /// The C API, resolved and initialised once per process. Only success is cached: a framework that appears after
    /// a failed attempt is found on the next call.
    static func functions() throws -> Functions {
        loadLock.lock()
        defer { loadLock.unlock() }
        if let loaded { return loaded }
        guard let location = locate() else { throw SKPError.sketchUpNotFound(searched: searchedURLs) }
        let framework = location.frameworkURL
        if !FileManager.default.fileExists(atPath: framework.appendingPathComponent("Versions/A/Libraries").path) {
            preloadSiblings(framework.deletingLastPathComponent().path)
        }
        guard let handle = dlopen(framework.appendingPathComponent("SketchUpAPI").path, RTLD_NOW | RTLD_LOCAL) else {
            throw SKPError.api(function: "dlopen: " + String(cString: dlerror()), code: -1)
        }
        let functions = try Functions(handle: handle)
        functions.SUInitialize()
        loaded = functions
        return functions
    }

    /// SketchUp.app's framework finds its `libCommon*.dylib` through an rpath only the app's executable provides:
    /// load them by absolute path first, retrying until their own inter-dependencies resolve.
    static func preloadSiblings(_ dir: String) {
        var pending = Set(((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).filter { $0.hasPrefix("libCommon") && $0.hasSuffix(".dylib") })
        var progressed = true
        while progressed && !pending.isEmpty {
            progressed = false
            for lib in pending.sorted() where dlopen(dir + "/" + lib, RTLD_NOW | RTLD_GLOBAL) != nil {
                pending.remove(lib); progressed = true
            }
        }
    }
}
