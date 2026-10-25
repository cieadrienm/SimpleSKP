import Foundation

/// What can be known about a `.skp` in a few milliseconds, without SketchUp: the version written in the
/// UTF-16 header (`SketchUp Model {17.3.116}`) and the embedded PNG thumbnail.
public struct SKPFileInfo: Sendable {
    public let url: URL
    public let fileSize: Int
    /// Raw version from the header, e.g. "17.3.116"; nil when the header is not SketchUp's.
    public let version: String?
    /// Human label, e.g. "SketchUp 2017" (8 → "SketchUp 8", 13…23 → "SketchUp 2013…2023").
    public let versionLabel: String?
    public let thumbnailPNG: Data?

    public init(url: URL, fileSize: Int, version: String?, versionLabel: String?, thumbnailPNG: Data?) {
        self.url = url; self.fileSize = fileSize; self.version = version; self.versionLabel = versionLabel; self.thumbnailPNG = thumbnailPNG
    }

    /// Reads only the first megabyte of the file. Throws `SKPError.unreadable` when the file cannot be read.
    public static func read(_ url: URL) throws -> SKPFileInfo {
        fatalError("todo: Core agent")
    }

    /// Parses an in-memory header (for tests and `read`).
    public static func parse(header: Data, url: URL, fileSize: Int) -> SKPFileInfo {
        fatalError("todo: Core agent")
    }
}
