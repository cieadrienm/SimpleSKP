import Foundation

/// Reads a `.skp` through SketchUp's C API into an `SKPModel`. Synchronous and blocking: call it off the main
/// thread. One model is read at a time (the API is not thread-safe); `SUInitialize` runs once per process.
public enum SKPReader {
    public struct Progress: Sendable {
        /// Short French/English phase label for the status bar, via `L(...)`.
        public var phase: String
        /// Faces converted so far.
        public var faces: Int
        public init(phase: String, faces: Int) { self.phase = phase; self.faces = faces }
    }

    public static func load(
        _ url: URL,
        progress: (@Sendable (Progress) -> Void)? = nil,
        isCancelled: @Sendable () -> Bool = { false }
    ) throws -> SKPModel {
        fatalError("todo: Core agent")
    }
}
