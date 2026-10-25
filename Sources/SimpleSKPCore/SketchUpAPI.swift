import Foundation

/// Locates and dynamically loads SketchUp's own `SketchUpAPI.framework` (C API). Search order:
/// 1. `SimpleSKP.app/Contents/Frameworks/SketchUpAPI.framework` (official SDK dropped in by the user),
/// 2. `/Applications/SketchUp*.app/Contents/Frameworks/SketchUpAPI.framework` and `~/Applications/…`, newest first
///    (the framework's `@rpath` siblings `libCommon*.dylib` live next to it and must be preloaded by absolute path),
/// 3. `/Applications/Unity/Hub/Editor/*/Unity.app/Contents/Frameworks/SketchUpAPI.framework` (self-contained: `Versions/A/Libraries`).
public enum SketchUpAPI {
    public struct Location: Sendable, Equatable {
        public let frameworkURL: URL
        /// Version of the host application the framework came with (e.g. "23.0.396"), when known.
        public let appVersion: String?
        public init(frameworkURL: URL, appVersion: String?) { self.frameworkURL = frameworkURL; self.appVersion = appVersion }
    }

    /// Candidate directories searched, for diagnostics (`SKPError.sketchUpNotFound(searched:)`).
    public static var searchedURLs: [URL] { fatalError("todo: Core agent") }

    public static func locate() -> Location? { fatalError("todo: Core agent") }

    public static var isAvailable: Bool { locate() != nil }
}
