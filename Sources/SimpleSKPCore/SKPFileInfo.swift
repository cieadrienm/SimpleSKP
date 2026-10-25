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
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let header = try handle.read(upToCount: 1 << 20) ?? Data()
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? header.count
            return parse(header: header, url: url, fileSize: size)
        } catch {
            throw SKPError.unreadable(url)
        }
    }

    /// Parses an in-memory header (for tests and `read`).
    public static func parse(header: Data, url: URL, fileSize: Int) -> SKPFileInfo {
        let version = parseVersion(header)
        return SKPFileInfo(url: url, fileSize: fileSize, version: version, versionLabel: version.map(label), thumbnailPNG: thumbnail(header))
    }

    static func utf16(_ s: String) -> Data { s.data(using: .utf16LittleEndian)! }

    static func parseVersion(_ data: Data) -> String? {
        guard let magic = data.range(of: utf16("SketchUp Model")),
              let open = data.range(of: utf16("{"), in: magic.upperBound..<data.endIndex),
              open.lowerBound - magic.upperBound < 16,
              let close = data.range(of: utf16("}"), in: open.upperBound..<min(data.endIndex, open.upperBound + 64))
        else { return nil }
        let version = String(data: data[open.upperBound..<close.lowerBound], encoding: .utf16LittleEndian)
        return version?.isEmpty == false ? version : nil
    }

    static func label(_ version: String) -> String {
        let major = Int(version.prefix { $0.isNumber }) ?? 0
        switch major {
        case ...8: return "SketchUp 8"
        case 13...99: return "SketchUp 20\(String(format: "%02d", major))"
        default: return "SketchUp \(major)"
        }
    }

    static func thumbnail(_ data: Data) -> Data? {
        guard let start = data.range(of: Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])),
              let iend = data.range(of: Data("IEND".utf8), in: start.upperBound..<data.endIndex),
              iend.upperBound + 4 <= data.endIndex
        else { return nil }
        return Data(data[start.lowerBound..<iend.upperBound + 4])
    }
}
