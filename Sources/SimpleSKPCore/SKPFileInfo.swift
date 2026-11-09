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

    /// True when the file is a Collada `.dae` 3D model.
    public var isDAE: Bool {
        if let version, version.hasPrefix("COLLADA") { return true }
        return url.pathExtension.lowercased() == "dae"
    }

    /// True when the file is a Wavefront `.obj` 3D model.
    public var isOBJ: Bool {
        if version == "OBJ" { return true }
        return url.pathExtension.lowercased() == "obj"
    }

    /// True when the file is an Autodesk `.fbx` 3D model.
    public var isFBX: Bool {
        if let version, version.hasPrefix("FBX") { return true }
        return url.pathExtension.lowercased() == "fbx"
    }

    /// True when the file is a Binary glTF 2.0 `.glb` model.
    public var isGLB: Bool {
        if let version, version.hasPrefix("GLB") { return true }
        return url.pathExtension.lowercased() == "glb"
    }

    /// True when the file is a JSON glTF 2.0 `.gltf` model.
    public var isGLTF: Bool {
        if let version, version.hasPrefix("glTF") { return true }
        return url.pathExtension.lowercased() == "gltf"
    }

    /// True when the file is either a `.glb` or `.gltf` 3D model.
    public var isGLTFOrGLB: Bool {
        isGLB || isGLTF
    }

    /// True when the file is a Stanford `.ply` file (3D Gaussian Splat, Point Cloud, or Polygon Mesh).
    public var isPLY: Bool {
        if let version, version.hasPrefix("PLY") { return true }
        return url.pathExtension.lowercased() == "ply"
    }

    /// True when the file is a compact `.splat` 3D Gaussian Splat file.
    public var isSplat: Bool {
        if version == "SPLAT" { return true }
        return url.pathExtension.lowercased() == "splat"
    }

    /// True when the file is a compressed Niantic `.spz` 3D Gaussian Splat file.
    public var isSPZ: Bool {
        if let version, version.hasPrefix("SPZ") { return true }
        return url.pathExtension.lowercased() == "spz"
    }

    /// True when the file is an ASCII `.xyz` 3D point cloud.
    public var isXYZ: Bool {
        if version == "XYZ" { return true }
        return url.pathExtension.lowercased() == "xyz"
    }

    /// True when the file is a Leica `.pts` 3D laser scan point cloud.
    public var isPTS: Bool {
        if version == "PTS" { return true }
        return url.pathExtension.lowercased() == "pts"
    }

    /// True when the file is a Point Cloud Library `.pcd` 3D point cloud.
    public var isPCD: Bool {
        if let version, version.hasPrefix("PCD") { return true }
        return url.pathExtension.lowercased() == "pcd"
    }

    /// True when the file is a 3D Gaussian Splat (`.splat`, `.spz`, or a `.ply` with Gaussian Splat properties).
    public var isGaussianSplat: Bool {
        if isSplat || isSPZ { return true }
        if version == "PLY-3DGS" { return true }
        return false
    }

    /// True when the file is a 3D Point Cloud (`.xyz`, `.pts`, `.pcd`, or a vertex-only `.ply`).
    public var isPointCloud: Bool {
        if isXYZ || isPTS || isPCD { return true }
        if version == "PLY-PC" { return true }
        return false
    }

    /// True when the file is either a 3D Gaussian Splat or a 3D Point Cloud (or any `.ply` routed to the splat/PLY reader).
    public var isSplatOrPointCloud: Bool {
        isGaussianSplat || isPointCloud || isPLY
    }

    /// True when the file is a `.dae` or `.obj` 3D mesh file.
    public var is3DMesh: Bool { isDAE || isOBJ }

    /// True when the file is a SimpleSKP `.sskp` project file.
    public var isSSKP: Bool {
        if version == "SSKP" { return true }
        return url.pathExtension.lowercased() == "sskp"
    }

    /// Reads only the first megabyte of the file. Throws `SKPError.unreadable` when the file cannot be read.
    public static func read(_ url: URL) throws -> SKPFileInfo {
        if url.pathExtension.lowercased() == "sskp" {
            do {
                let project = try SSKPProject.read(from: url)
                let modelURL = project.resolveModelURL(relativeTo: url)
                let baseInfo = try read(modelURL)
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? baseInfo.fileSize
                let baseLabel = baseInfo.versionLabel ?? modelURL.pathExtension.uppercased()
                return SKPFileInfo(
                    url: url,
                    fileSize: size,
                    version: baseInfo.version ?? "SSKP",
                    versionLabel: "SSKP · \(baseLabel)",
                    thumbnailPNG: baseInfo.thumbnailPNG
                )
            } catch {
                throw SKPError.unreadable(url)
            }
        }
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
        if let daeInfo = parseDAEVersion(header, url: url) {
            return SKPFileInfo(
                url: url,
                fileSize: fileSize,
                version: daeInfo.version,
                versionLabel: daeInfo.label,
                thumbnailPNG: nil
            )
        }
        if let objInfo = parseOBJVersion(header, url: url) {
            return SKPFileInfo(
                url: url,
                fileSize: fileSize,
                version: objInfo.version,
                versionLabel: objInfo.label,
                thumbnailPNG: nil
            )
        }
        if let fbxInfo = parseFBXVersion(header, url: url) {
            return SKPFileInfo(
                url: url,
                fileSize: fileSize,
                version: fbxInfo.version,
                versionLabel: fbxInfo.label,
                thumbnailPNG: nil
            )
        }
        if let gltfInfo = parseGLTFVersion(header, url: url) {
            return SKPFileInfo(
                url: url,
                fileSize: fileSize,
                version: gltfInfo.version,
                versionLabel: gltfInfo.label,
                thumbnailPNG: nil
            )
        }
        if let plyInfo = parsePLYVersion(header, url: url) {
            return SKPFileInfo(
                url: url,
                fileSize: fileSize,
                version: plyInfo.version,
                versionLabel: plyInfo.label,
                thumbnailPNG: nil
            )
        }
        if let splatInfo = parseSplatOrPointCloudVersion(header, url: url) {
            return SKPFileInfo(
                url: url,
                fileSize: fileSize,
                version: splatInfo.version,
                versionLabel: splatInfo.label,
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

    static func parseDAEVersion(_ data: Data, url: URL) -> (version: String, label: String)? {
        let isDAEExt = url.pathExtension.lowercased() == "dae"
        let sample = data.prefix(min(data.count, 32_768))
        let text = String(data: sample, encoding: .utf8) ?? String(data: sample, encoding: .isoLatin1) ?? ""
        guard isDAEExt || text.contains("<COLLADA") else { return nil }
        var ver = "1.4"
        if text.contains("version=\"1.5") {
            ver = "1.5"
        } else if text.contains("version=\"1.4.1\"") {
            ver = "1.4.1"
        }
        return ("COLLADA \(ver)", "Collada DAE \(ver)")
    }

    static func parseOBJVersion(_ data: Data, url: URL) -> (version: String, label: String)? {
        guard url.pathExtension.lowercased() == "obj" else { return nil }
        return ("OBJ", "Wavefront OBJ")
    }

    static func parseFBXVersion(_ data: Data, url: URL) -> (version: String, label: String)? {
        let isFBXExt = url.pathExtension.lowercased() == "fbx"
        let magic = Data("Kaydara FBX Binary  \0".utf8)
        if data.count >= 27 && data.starts(with: magic) {
            let v: UInt32 = data.withUnsafeBytes { raw in
                raw.loadUnaligned(fromByteOffset: 23, as: UInt32.self).littleEndian
            }
            if v >= 5000 && v <= 9999 {
                let major = v / 1000
                let minor = (v % 1000) / 100
                return ("FBX \(major).\(minor)", "Autodesk FBX \(major).\(minor)")
            }
            return ("FBX", "Autodesk FBX")
        }
        let sample = data.prefix(min(data.count, 8192))
        if let text = String(data: sample, encoding: .utf8) ?? String(data: sample, encoding: .isoLatin1) {
            if text.hasPrefix("; FBX") || (isFBXExt && text.contains("FBXHeaderExtension")) {
                if let range = text.range(of: #"; FBX (\d+\.\d+\.\d+)"#, options: .regularExpression) {
                    let ver = String(text[range]).replacingOccurrences(of: "; FBX ", with: "")
                    return ("FBX \(ver)", "Autodesk FBX \(ver)")
                }
                return ("FBX ASCII", "Autodesk FBX ASCII")
            }
        }
        return isFBXExt ? ("FBX", "Autodesk FBX") : nil
    }

    static func parseGLTFVersion(_ data: Data, url: URL) -> (version: String, label: String)? {
        let ext = url.pathExtension.lowercased()
        let isGLBExt = (ext == "glb")
        let isGLTFExt = (ext == "gltf")
        // Binary glTF (.glb) header: 0x46546C67 ("glTF")
        if data.count >= 12 && data.starts(with: Data("glTF".utf8)) {
            let v: UInt32 = data.withUnsafeBytes { raw in
                raw.loadUnaligned(fromByteOffset: 4, as: UInt32.self).littleEndian
            }
            return ("GLB \(v).0", "glTF Binary \(v).0 (.glb)")
        }
        if isGLBExt {
            return ("GLB 2.0", "glTF Binary 2.0 (.glb)")
        }
        if isGLTFExt {
            return ("glTF 2.0", "Khronos glTF 2.0 (.gltf)")
        }
        let sample = data.prefix(min(data.count, 4096))
        if let text = String(data: sample, encoding: .utf8),
           text.contains("\"asset\"") && text.contains("\"version\"") && (text.contains("\"meshes\"") || text.contains("\"scenes\"")) {
            return ("glTF 2.0", "Khronos glTF 2.0 (.gltf)")
        }
        return nil
    }

    static func parsePLYVersion(_ data: Data, url: URL) -> (version: String, label: String)? {
        let isPLYExt = url.pathExtension.lowercased() == "ply"
        let startsWithPLY = data.starts(with: Data("ply\n".utf8)) || data.starts(with: Data("ply\r\n".utf8))
        guard isPLYExt || startsWithPLY else { return nil }
        let sample = data.prefix(min(data.count, 16_384))
        let text = String(data: sample, encoding: .utf8) ?? String(data: sample, encoding: .isoLatin1) ?? ""
        let headerText: String
        if let endHeader = text.range(of: "end_header") {
            headerText = String(text[..<endHeader.upperBound])
        } else {
            headerText = text
        }
        let hasSplatProps = headerText.contains("f_dc_0") && headerText.contains("scale_0") && headerText.contains("rot_0")
        if hasSplatProps {
            return ("PLY-3DGS", "3D Gaussian Splat (PLY)")
        }
        if headerText.contains("element face") {
            var faceCount = 0
            if let range = headerText.range(of: #"element\s+face\s+(\d+)"#, options: .regularExpression) {
                let parts = headerText[range].split(whereSeparator: { $0.isWhitespace })
                if let last = parts.last, let n = Int(last) { faceCount = n }
            }
            if faceCount > 0 {
                return ("PLY-Mesh", "Stanford PLY Mesh")
            }
        }
        return ("PLY-PC", "Point Cloud (PLY)")
    }

    static func parseSplatOrPointCloudVersion(_ data: Data, url: URL) -> (version: String, label: String)? {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "splat":
            return ("SPLAT", "3D Gaussian Splat (.splat)")
        case "spz":
            return ("SPZ", "3D Gaussian Splat (.spz)")
        case "xyz":
            return ("XYZ", "Point Cloud (.xyz)")
        case "pts":
            return ("PTS", "Point Cloud (.pts)")
        case "pcd":
            return ("PCD", "Point Cloud (.pcd)")
        default:
            // Also check uncompressed NGSP magic (`0x5053474e` little-endian = "NGSP")
            if data.count >= 16 && data.starts(with: Data("NGSP".utf8)) {
                return ("SPZ", "3D Gaussian Splat (.spz)")
            }
            return nil
        }
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
