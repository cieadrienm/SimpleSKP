import Foundation

/// What can be known about a `.skp` in a few milliseconds, without SketchUp: the version written in the
/// UTF-16 header (`SketchUp Model {17.3.116}`) and the embedded PNG thumbnail.
public struct SKPFileInfo: Sendable {
    public let url: URL
    public let fileSize: Int
    /// Raw version from the header, e.g. "17.3.116"; nil when the header is not SketchUp's.
    public let version: String?
    /// Human label, e.g. "SketchUp 2017" (3…12 → "SketchUp 3…12", 13…99 → "SketchUp 2013…2099").
    public let versionLabel: String?
    public let thumbnailPNG: Data?

    public init(url: URL, fileSize: Int, version: String?, versionLabel: String?, thumbnailPNG: Data?) {
        self.url = url; self.fileSize = fileSize; self.version = version; self.versionLabel = versionLabel; self.thumbnailPNG = thumbnailPNG
    }

    /// True when the file is an AutoCAD `.dwg` drawing (by header magic or `.dwg` extension).
    public var isDWG: Bool {
        if let version, version.hasPrefix("AC10"), url.pathExtension.lowercased() != "dxf" { return true }
        return url.pathExtension.lowercased() == "dwg"
    }

    /// True when the file is an AutoCAD `.dxf` drawing (by header or `.dxf` extension).
    public var isDXF: Bool {
        if version == "DXF" { return true }
        return url.pathExtension.lowercased() == "dxf"
    }

    /// True when the file is an AutoCAD `.dwg` or `.dxf` drawing.
    public var isCAD: Bool { isDWG || isDXF }

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
        if let skpVersion = parseVersion(header) {
            return SKPFileInfo(
                url: url,
                fileSize: fileSize,
                version: skpVersion,
                versionLabel: label(skpVersion),
                thumbnailPNG: thumbnail(header)
            )
        }
        if let dwgCode = parseDWGVersion(header) {
            return SKPFileInfo(
                url: url,
                fileSize: fileSize,
                version: dwgCode,
                versionLabel: dwgLabel(dwgCode),
                thumbnailPNG: thumbnail(header)
            )
        }
        if let dxfInfo = parseDXFVersion(header, url: url) {
            return SKPFileInfo(
                url: url,
                fileSize: fileSize,
                version: dxfInfo.version,
                versionLabel: dxfInfo.label,
                thumbnailPNG: nil
            )
        }
        return SKPFileInfo(url: url, fileSize: fileSize, version: nil, versionLabel: nil, thumbnailPNG: thumbnail(header))
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

    static func parseDWGVersion(_ data: Data) -> String? {
        guard data.count >= 6,
              let prefix = String(data: data.prefix(6), encoding: .ascii),
              prefix.hasPrefix("AC10"),
              prefix.dropFirst(4).allSatisfy({ $0.isASCII && ($0.isNumber || $0.isLetter) })
        else { return nil }
        return prefix
    }

    static func dwgLabel(_ code: String, isDXF: Bool = false) -> String {
        let base = isDXF ? "AutoCAD DXF" : "AutoCAD"
        switch code {
        case "AC1006": return "\(base) R10"
        case "AC1009": return "\(base) R11/R12"
        case "AC1012": return "\(base) R13"
        case "AC1014": return "\(base) R14"
        case "AC1015": return "\(base) 2000"
        case "AC1018": return "\(base) 2004"
        case "AC1021": return "\(base) 2007"
        case "AC1024": return "\(base) 2010"
        case "AC1027": return "\(base) 2013"
        case "AC1032": return "\(base) 2018"
        default: return isDXF ? "AutoCAD DXF" : "AutoCAD DWG"
        }
    }

    static func parseDXFVersion(_ data: Data, url: URL) -> (version: String, label: String)? {
        let isDXFExt = url.pathExtension.lowercased() == "dxf"
        if data.starts(with: Data("AutoCAD Binary DXF".utf8)) {
            return ("DXF", "AutoCAD Binary DXF")
        }
        let sample = data.prefix(min(data.count, 32_768))
        guard let text = String(data: sample, encoding: .utf8) ?? String(data: sample, encoding: .isoLatin1) else {
            return isDXFExt ? ("DXF", "AutoCAD DXF") : nil
        }
        let hasSection = text.contains("SECTION") && (text.contains("HEADER") || text.contains("ENTITIES") || text.contains("TABLES"))
        guard isDXFExt || hasSection else { return nil }
        if let range = text.range(of: "$ACADVER") {
            let tail = text[range.upperBound...]
            for token in tail.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).prefix(4) {
                let s = String(token)
                if s.hasPrefix("AC10"), s.count == 6 {
                    return (s, dwgLabel(s, isDXF: true))
                }
            }
        }
        return ("DXF", "AutoCAD DXF")
    }

    /// nil when the version does not start with a number.
    static func label(_ version: String) -> String? {
        guard let major = Int(version.prefix { $0.isASCII && $0.isNumber }) else { return nil }
        switch major {
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
