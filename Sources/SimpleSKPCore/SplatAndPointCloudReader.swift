import Foundation
import simd
import zlib

/// High-performance parallel reader for 3D Gaussian Splats (`.ply`, `.splat`, `.spz`),
/// 3D Point Clouds (`.ply`, `.xyz`, `.pts`, `.pcd`), and Stanford `.ply` polygon meshes.
enum SplatAndPointCloudReader {

    static let shC0: Float = 0.28209479177387814

    static func load(
        _ url: URL,
        fileInfo: SKPFileInfo,
        progress: (@Sendable (SKPReader.Progress) -> Void)? = nil,
        isCancelled: @Sendable () -> Bool = { false }
    ) throws -> SKPModel {
        let start = Date()
        if isCancelled() { throw SKPError.cancelled }

        let ext = url.pathExtension.lowercased()
        switch ext {
        case "splat":
            return try loadDotSplat(url, fileInfo: fileInfo, start: start, progress: progress, isCancelled: isCancelled)
        case "spz":
            return try loadSPZ(url, fileInfo: fileInfo, start: start, progress: progress, isCancelled: isCancelled)
        case "xyz", "pts":
            return try loadXYZOrPTS(url, fileInfo: fileInfo, start: start, progress: progress, isCancelled: isCancelled)
        case "pcd":
            return try loadPCD(url, fileInfo: fileInfo, start: start, progress: progress, isCancelled: isCancelled)
        case "ply":
            return try loadPLY(url, fileInfo: fileInfo, start: start, progress: progress, isCancelled: isCancelled)
        default:
            if fileInfo.isSPZ {
                return try loadSPZ(url, fileInfo: fileInfo, start: start, progress: progress, isCancelled: isCancelled)
            }
            if fileInfo.isPLY {
                return try loadPLY(url, fileInfo: fileInfo, start: start, progress: progress, isCancelled: isCancelled)
            }
            throw SKPError.unreadable(url)
        }
    }

    // MARK: - 1. `.splat` Reader (antimatter15 32-byte format)

    private static func loadDotSplat(
        _ url: URL,
        fileInfo: SKPFileInfo,
        start: Date,
        progress: (@Sendable (SKPReader.Progress) -> Void)?,
        isCancelled: @Sendable () -> Bool
    ) throws -> SKPModel {
        progress?(SKPReader.Progress(
            phase: L("Lecture des Gaussian Splats (.splat)…", "Reading Gaussian Splats (.splat)…"),
            faces: 0,
            fraction: 0.15
        ))
        let data: Data
        do {
            data = try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            throw SKPError.unreadable(url)
        }
        let stride = 32
        let count = data.count / stride
        guard count > 0 else { throw SKPError.unreadable(url) }
        if isCancelled() { throw SKPError.cancelled }

        var splats = [SKPModel.PackedSplat](
            repeating: SKPModel.PackedSplat(
                position: .zero,
                colorR: 0, colorG: 0, colorB: 0, colorA: 0,
                covAx: 0, covAy: 0, covAz: 0,
                covBx: 0, covBy: 0, covBz: 0
            ),
            count: count
        )

        data.withUnsafeBytes { rawBuf in
            guard let base = rawBuf.baseAddress else { return }
            splats.withUnsafeMutableBufferPointer { outBuf in
                guard let outBase = outBuf.baseAddress else { return }
                let chunks = max(1, min(16, count / 16_384))
                let perChunk = (count + chunks - 1) / chunks
                DispatchQueue.concurrentPerform(iterations: chunks) { chunk in
                    let startIdx = chunk * perChunk
                    let endIdx = min(count, startIdx + perChunk)
                    guard startIdx < endIdx else { return }
                    for i in startIdx..<endIdx {
                        let offset = i * 32
                        let px = base.loadUnaligned(fromByteOffset: offset + 0, as: Float.self)
                        let py = base.loadUnaligned(fromByteOffset: offset + 4, as: Float.self)
                        let pz = base.loadUnaligned(fromByteOffset: offset + 8, as: Float.self)
                        let sx = max(1e-7, abs(base.loadUnaligned(fromByteOffset: offset + 12, as: Float.self)))
                        let sy = max(1e-7, abs(base.loadUnaligned(fromByteOffset: offset + 16, as: Float.self)))
                        let sz = max(1e-7, abs(base.loadUnaligned(fromByteOffset: offset + 20, as: Float.self)))
                        let cr = Float(base.loadUnaligned(fromByteOffset: offset + 24, as: UInt8.self)) / 255.0
                        let cg = Float(base.loadUnaligned(fromByteOffset: offset + 25, as: UInt8.self)) / 255.0
                        let cb = Float(base.loadUnaligned(fromByteOffset: offset + 26, as: UInt8.self)) / 255.0
                        let ca = Float(base.loadUnaligned(fromByteOffset: offset + 27, as: UInt8.self)) / 255.0
                        let rw = (Float(base.loadUnaligned(fromByteOffset: offset + 28, as: UInt8.self)) - 128.0) / 128.0
                        let rx = (Float(base.loadUnaligned(fromByteOffset: offset + 29, as: UInt8.self)) - 128.0) / 128.0
                        let ry = (Float(base.loadUnaligned(fromByteOffset: offset + 30, as: UInt8.self)) - 128.0) / 128.0
                        let rz = (Float(base.loadUnaligned(fromByteOffset: offset + 31, as: UInt8.self)) - 128.0) / 128.0

                        // Convert RDF (+X right, +Y down, +Z forward) -> Z-up (+X right, +Y forward, +Z up): (x, z, -y)
                        let posZUp = SIMD3<Float>(px.isFinite ? px : 0, pz.isFinite ? pz : 0, py.isFinite ? -py : 0)
                        let (covA, covB) = covarianceZUpFromRDF(
                            scale: SIMD3<Float>(sx, sy, sz),
                            quatXYZW: SIMD4<Float>(rx, ry, rz, rw)
                        )
                        outBase[i] = SKPModel.PackedSplat(
                            position: posZUp,
                            colorR: Float16(cr), colorG: Float16(cg), colorB: Float16(cb), colorA: Float16(ca),
                            covAx: covA.x, covAy: covA.y, covAz: covA.z,
                            covBx: covB.x, covBy: covB.y, covBz: covB.z
                        )
                    }
                }
            }
        }

        if isCancelled() { throw SKPError.cancelled }
        return finalizeSplatModel(
            kind: .gaussianSplats,
            splats: &splats,
            shDegree: 0,
            shCoefficients: [],
            shDirCols: (SIMD3(1, 0, 0), SIMD3(0, 0, 1), SIMD3(0, -1, 0)),
            fileInfo: fileInfo,
            start: start,
            progress: progress
        )
    }

    // MARK: - 2. `.spz` Reader (Niantic / Scaniverse `NGSP` v1–v3)

    private static func loadSPZ(
        _ url: URL,
        fileInfo: SKPFileInfo,
        start: Date,
        progress: (@Sendable (SKPReader.Progress) -> Void)?,
        isCancelled: @Sendable () -> Bool
    ) throws -> SKPModel {
        progress?(SKPReader.Progress(
            phase: L("Décompression des Gaussian Splats (.spz)…", "Decompressing Gaussian Splats (.spz)…"),
            faces: 0,
            fraction: 0.12
        ))
        let rawData: Data
        do {
            let fileData = try Data(contentsOf: url, options: .mappedIfSafe)
            if fileData.count >= 4 && fileData.starts(with: Data("NGSP".utf8)) {
                rawData = fileData
            } else {
                rawData = try gunzipData(fileData, url: url)
            }
        } catch {
            throw SKPError.unreadable(url)
        }
        guard rawData.count >= 16 else { throw SKPError.unreadable(url) }
        if isCancelled() { throw SKPError.cancelled }

        return try rawData.withUnsafeBytes { rawBuf -> SKPModel in
            guard let base = rawBuf.baseAddress else { throw SKPError.unreadable(url) }
            let magic = base.loadUnaligned(fromByteOffset: 0, as: UInt32.self).littleEndian
            let version = base.loadUnaligned(fromByteOffset: 4, as: UInt32.self).littleEndian
            let numPoints = Int(base.loadUnaligned(fromByteOffset: 8, as: UInt32.self).littleEndian)
            let shDegree = base.loadUnaligned(fromByteOffset: 12, as: UInt8.self)
            let fractionalBits = base.loadUnaligned(fromByteOffset: 13, as: UInt8.self)
            // magic == 0x5053474e ("NGSP")
            guard magic == 0x5053474E, version >= 1, version <= 3, numPoints > 0, shDegree <= 3 else {
                throw SKPError.unreadable(url)
            }

            let usesFloat16 = (version == 1)
            let usesQuaternionSmallestThree = (version >= 3)
            let positionsBytes = numPoints * 3 * (usesFloat16 ? 2 : 3)
            let alphasBytes = numPoints
            let colorsBytes = numPoints * 3
            let scalesBytes = numPoints * 3
            let rotationsBytes = numPoints * (usesQuaternionSmallestThree ? 4 : 3)
            let shCoeffsPerPoint: Int = {
                switch shDegree {
                case 1: return 3
                case 2: return 8
                case 3: return 15
                default: return 0
                }
            }()
            let shFloatsPerPoint = shCoeffsPerPoint * 3
            let shBytes = numPoints * shFloatsPerPoint

            let totalExpected = 16 + positionsBytes + alphasBytes + colorsBytes + scalesBytes + rotationsBytes + shBytes
            guard rawData.count >= totalExpected else {
                throw SKPError.unreadable(url)
            }

            let posOffset = 16
            let alphaOffset = posOffset + positionsBytes
            let colorOffset = alphaOffset + alphasBytes
            let scaleOffset = colorOffset + colorsBytes
            let rotOffset = scaleOffset + scalesBytes
            let shOffset = rotOffset + rotationsBytes

            progress?(SKPReader.Progress(
                phase: L("Décodage de \(numPoints) Gaussian Splats (.spz)…", "Decoding \(numPoints) Gaussian Splats (.spz)…"),
                faces: 0,
                fraction: 0.45
            ))

            var splats = [SKPModel.PackedSplat](
                repeating: SKPModel.PackedSplat(
                    position: .zero,
                    colorR: 0, colorG: 0, colorB: 0, colorA: 0,
                    covAx: 0, covAy: 0, covAz: 0,
                    covBx: 0, covBy: 0, covBz: 0
                ),
                count: numPoints
            )
            var shData = [Float16](repeating: 0, count: numPoints * shFloatsPerPoint)

            let posScale = 1.0 / Float(1 << Int(fractionalBits))
            let colorScale: Float = 1.0 / 0.15
            let sqrt1_2: Float = 0.7071067811865475

            let ptr = base.assumingMemoryBound(to: UInt8.self)
            splats.withUnsafeMutableBufferPointer { outSplats in
                shData.withUnsafeMutableBufferPointer { outSH in
                    let splatBase = outSplats.baseAddress!
                    let shBase = outSH.baseAddress
                    let chunks = max(1, min(16, numPoints / 16_384))
                    let perChunk = (numPoints + chunks - 1) / chunks

                    DispatchQueue.concurrentPerform(iterations: chunks) { chunk in
                        let startIdx = chunk * perChunk
                        let endIdx = min(numPoints, startIdx + perChunk)
                        guard startIdx < endIdx else { return }

                        for i in startIdx..<endIdx {
                            // 1. Position (RUB in SPZ -> Z-up: (x, -z, y))
                            let px: Float
                            let py: Float
                            let pz: Float
                            if usesFloat16 {
                                let pBase = posOffset + i * 6
                                let hx = base.loadUnaligned(fromByteOffset: pBase + 0, as: Float16.self)
                                let hy = base.loadUnaligned(fromByteOffset: pBase + 2, as: Float16.self)
                                let hz = base.loadUnaligned(fromByteOffset: pBase + 4, as: Float16.self)
                                px = Float(hx); py = Float(hy); pz = Float(hz)
                            } else {
                                let pBase = posOffset + i * 9
                                px = Self.readFixed24(ptr, offset: pBase + 0, scale: posScale)
                                py = Self.readFixed24(ptr, offset: pBase + 3, scale: posScale)
                                pz = Self.readFixed24(ptr, offset: pBase + 6, scale: posScale)
                            }
                            let posZUp = SIMD3<Float>(px, -pz, py)

                            // 2. Alpha (already linear 0..255 in SPZ)
                            let alpha = Float(ptr[alphaOffset + i]) / 255.0

                            // 3. Color SH0
                            let cBase = colorOffset + i * 3
                            let sh0R = ((Float(ptr[cBase + 0]) / 255.0) - 0.5) * colorScale
                            let sh0G = ((Float(ptr[cBase + 1]) / 255.0) - 0.5) * colorScale
                            let sh0B = ((Float(ptr[cBase + 2]) / 255.0) - 0.5) * colorScale
                            let colR = max(0, 0.5 + shC0 * sh0R)
                            let colG = max(0, 0.5 + shC0 * sh0G)
                            let colB = max(0, 0.5 + shC0 * sh0B)

                            // 4. Scale (log scale encoded as byte/16 - 10)
                            let sBase = scaleOffset + i * 3
                            let sx = exp(Float(ptr[sBase + 0]) / 16.0 - 10.0)
                            let sy = exp(Float(ptr[sBase + 1]) / 16.0 - 10.0)
                            let sz = exp(Float(ptr[sBase + 2]) / 16.0 - 10.0)

                            // 5. Rotation quaternion (x, y, z, w) in RUB
                            let quatXYZW: SIMD4<Float>
                            if usesQuaternionSmallestThree {
                                let rBase = rotOffset + i * 4
                                var comp = SIMD4<Float>(0, 0, 0, 0)
                                let iLargest = Int(ptr[rBase + 3] & 3)
                                var compMask: UInt32 = UInt32(ptr[rBase + 0])
                                    | (UInt32(ptr[rBase + 1]) << 8)
                                    | (UInt32(ptr[rBase + 2]) << 16)
                                    | (UInt32(ptr[rBase + 3]) << 24)
                                var sumSquares: Float = 0
                                for k in (0...3).reversed() where k != iLargest {
                                    let mag = compMask & 511
                                    let negbit = (compMask >> 9) & 1
                                    compMask >>= 10
                                    var val = sqrt1_2 * Float(mag) / 511.0
                                    if negbit == 1 { val = -val }
                                    comp[k] = val
                                    sumSquares += val * val
                                }
                                comp[iLargest] = sqrt(max(0, 1.0 - sumSquares))
                                quatXYZW = comp
                            } else {
                                let rBase = rotOffset + i * 3
                                let qx = Float(ptr[rBase + 0]) / 127.5 - 1.0
                                let qy = Float(ptr[rBase + 1]) / 127.5 - 1.0
                                let qz = Float(ptr[rBase + 2]) / 127.5 - 1.0
                                let qw = sqrt(max(0, 1.0 - (qx * qx + qy * qy + qz * qz)))
                                quatXYZW = SIMD4<Float>(qx, qy, qz, qw)
                            }

                            let (covA, covB) = covarianceZUpFromRUB(
                                scale: SIMD3<Float>(sx, sy, sz),
                                quatXYZW: quatXYZW
                            )
                            splatBase[i] = SKPModel.PackedSplat(
                                position: posZUp,
                                colorR: Float16(colR), colorG: Float16(colG), colorB: Float16(colB), colorA: Float16(alpha),
                                covAx: covA.x, covAy: covA.y, covAz: covA.z,
                                covBx: covB.x, covBy: covB.y, covBz: covB.z
                            )

                            // 6. Higher-order SH coefficients
                            if shFloatsPerPoint > 0, let shBase {
                                let inOff = shOffset + i * shFloatsPerPoint
                                let outOff = i * shFloatsPerPoint
                                for c in 0..<shFloatsPerPoint {
                                    let val = (Float(ptr[inOff + c]) - 128.0) / 128.0
                                    shBase[outOff + c] = Float16(val)
                                }
                            }
                        }
                    }
                }
            }

            return finalizeSplatModel(
                kind: .gaussianSplats,
                splats: &splats,
                shDegree: shDegree,
                shCoefficients: shData,
                shDirCols: (SIMD3(1, 0, 0), SIMD3(0, 0, -1), SIMD3(0, 1, 0)),
                fileInfo: fileInfo,
                start: start,
                progress: progress
            )
        }
    }

    private static func gunzipData(_ compressed: Data, url: URL) throws -> Data {
        guard !compressed.isEmpty else { throw SKPError.unreadable(url) }
        var stream = z_stream()
        // 15 + 32 enables automatic gzip or zlib header detection
        guard inflateInit2_(&stream, 15 + 32, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw SKPError.unreadable(url)
        }
        defer { inflateEnd(&stream) }

        let chunkSize = max(65_536, compressed.count * 2)
        var output = Data(capacity: compressed.count * 3)
        var buffer = [UInt8](repeating: 0, count: chunkSize)

        try compressed.withUnsafeBytes { rawIn in
            guard let inPtr = rawIn.baseAddress?.assumingMemoryBound(to: Bytef.self) else {
                throw SKPError.unreadable(url)
            }
            stream.next_in = UnsafeMutablePointer<Bytef>(mutating: inPtr)
            stream.avail_in = uInt(compressed.count)

            while true {
                let status: Int32 = buffer.withUnsafeMutableBufferPointer { outBuf in
                    stream.next_out = outBuf.baseAddress
                    stream.avail_out = uInt(chunkSize)
                    return inflate(&stream, Z_NO_FLUSH)
                }
                let produced = chunkSize - Int(stream.avail_out)
                if produced > 0 {
                    output.append(buffer, count: produced)
                }
                if status == Z_STREAM_END {
                    break
                }
                if status != Z_OK && status != Z_BUF_ERROR {
                    throw SKPError.unreadable(url)
                }
                if stream.avail_in == 0 && produced == 0 {
                    break
                }
            }
        }
        guard !output.isEmpty else { throw SKPError.unreadable(url) }
        return output
    }

    // MARK: - 3. `.ply` Reader (3D Gaussian Splats, Point Clouds, or Polygon Meshes)

    private enum PLYFormat {
        case ascii
        case binaryLittleEndian
        case binaryBigEndian
    }

    @inline(__always)
    private static func readFixed24(_ ptr: UnsafePointer<UInt8>, offset off: Int, scale: Float) -> Float {
        var fixed: Int32 = Int32(ptr[off]) | (Int32(ptr[off + 1]) << 8) | (Int32(ptr[off + 2]) << 16)
        if (fixed & 0x800000) != 0 { fixed |= Int32(bitPattern: 0xFF000000) }
        return Float(fixed) * scale
    }

    private indirect enum PLYPropertyType {
        case int8, uint8, int16, uint16, int32, uint32, float32, float64
        case list(countType: PLYPropertyType, valueType: PLYPropertyType)

        var byteSize: Int {
            switch self {
            case .int8, .uint8: return 1
            case .int16, .uint16: return 2
            case .int32, .uint32, .float32: return 4
            case .float64: return 8
            case .list: return 0
            }
        }

        var isList: Bool {
            if case .list = self { return true }
            return false
        }
    }

    private struct PLYProperty {
        var name: String
        var type: PLYPropertyType
        var byteOffset: Int
    }

    private struct PLYElement {
        var name: String
        var count: Int
        var properties: [PLYProperty]
        var fixedByteStride: Int?
    }

    private static func parsePLYType(_ token: String) -> PLYPropertyType? {
        switch token.lowercased() {
        case "char", "int8": return .int8
        case "uchar", "uint8": return .uint8
        case "short", "int16": return .int16
        case "ushort", "uint16": return .uint16
        case "int", "int32": return .int32
        case "uint", "uint32": return .uint32
        case "float", "float32": return .float32
        case "double", "float64": return .float64
        default: return nil
        }
    }

    private static func loadPLY(
        _ url: URL,
        fileInfo: SKPFileInfo,
        start: Date,
        progress: (@Sendable (SKPReader.Progress) -> Void)?,
        isCancelled: @Sendable () -> Bool
    ) throws -> SKPModel {
        let data: Data
        do {
            data = try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            throw SKPError.unreadable(url)
        }
        guard data.count >= 16 else { throw SKPError.unreadable(url) }

        // Locate "end_header\n" or "end_header\r\n" within first 64 KB
        let searchLimit = min(data.count, 65_536)
        let endHeaderMarker = Data("end_header".utf8)
        guard let markerRange = data.range(of: endHeaderMarker, in: 0..<searchLimit) else {
            throw SKPError.unreadable(url)
        }
        var bodyStart = markerRange.upperBound
        while bodyStart < data.count && (data[bodyStart] == 0x0D || data[bodyStart] == 0x0A || data[bodyStart] == 0x20) {
            let b = data[bodyStart]
            bodyStart += 1
            if b == 0x0A { break }
        }
        guard let headerStr = String(data: data[0..<markerRange.lowerBound], encoding: .utf8)
            ?? String(data: data[0..<markerRange.lowerBound], encoding: .isoLatin1) else {
            throw SKPError.unreadable(url)
        }

        var format: PLYFormat = .ascii
        var elements: [PLYElement] = []
        var currentElement: PLYElement? = nil

        for rawLine in headerStr.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("comment") || line.hasPrefix("obj_info") || line == "ply" {
                continue
            }
            let parts = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            guard let keyword = parts.first?.lowercased() else { continue }
            switch keyword {
            case "format":
                guard parts.count >= 2 else { continue }
                switch parts[1].lowercased() {
                case "ascii": format = .ascii
                case "binary_little_endian": format = .binaryLittleEndian
                case "binary_big_endian": format = .binaryBigEndian
                default: break
                }
            case "element":
                if let el = currentElement { elements.append(el) }
                guard parts.count >= 3, let count = Int(parts[2]) else {
                    currentElement = nil
                    continue
                }
                currentElement = PLYElement(name: parts[1], count: count, properties: [], fixedByteStride: 0)
            case "property":
                guard var el = currentElement, parts.count >= 3 else { continue }
                if parts[1].lowercased() == "list", parts.count >= 5,
                   let cType = parsePLYType(parts[2]),
                   let vType = parsePLYType(parts[3]) {
                    el.properties.append(PLYProperty(name: parts[4], type: .list(countType: cType, valueType: vType), byteOffset: -1))
                    el.fixedByteStride = nil
                } else if let pType = parsePLYType(parts[1]) {
                    let offset = el.fixedByteStride ?? -1
                    el.properties.append(PLYProperty(name: parts[2], type: pType, byteOffset: offset))
                    if let stride = el.fixedByteStride {
                        el.fixedByteStride = stride + pType.byteSize
                    }
                }
                currentElement = el
            default:
                break
            }
        }
        if let el = currentElement { elements.append(el) }

        guard let vertexEl = elements.first(where: { $0.name == "vertex" }), vertexEl.count > 0 else {
            throw SKPError.unreadable(url)
        }
        let propByName = Dictionary(uniqueKeysWithValues: vertexEl.properties.map { ($0.name, $0) })

        let isGaussianSplat = propByName["f_dc_0"] != nil
            && propByName["scale_0"] != nil
            && propByName["rot_0"] != nil
            && propByName["opacity"] != nil

        let faceEl = elements.first(where: { $0.name == "face" && $0.count > 0 })

        if isGaussianSplat {
            return try loadPLYGaussianSplats(
                data: data,
                bodyStart: bodyStart,
                format: format,
                vertexElement: vertexEl,
                propByName: propByName,
                fileInfo: fileInfo,
                start: start,
                progress: progress,
                isCancelled: isCancelled
            )
        } else if let faceEl, faceEl.count > 0 {
            return try loadPLYMesh(
                data: data,
                bodyStart: bodyStart,
                format: format,
                elements: elements,
                vertexElement: vertexEl,
                faceElement: faceEl,
                fileInfo: fileInfo,
                start: start,
                progress: progress,
                isCancelled: isCancelled
            )
        } else {
            return try loadPLYPointCloud(
                data: data,
                bodyStart: bodyStart,
                format: format,
                vertexElement: vertexEl,
                propByName: propByName,
                fileInfo: fileInfo,
                start: start,
                progress: progress,
                isCancelled: isCancelled
            )
        }
    }

    @inline(__always)
    private static func readBinaryFloat(_ base: UnsafeRawPointer, offset: Int, prop: PLYProperty?, bigEndian: Bool) -> Float {
        guard let prop, prop.byteOffset >= 0 else { return 0 }
        let off = offset + prop.byteOffset
        switch prop.type {
        case .float32:
            let bits = base.loadUnaligned(fromByteOffset: off, as: UInt32.self)
            return Float(bitPattern: bigEndian ? bits.bigEndian : bits.littleEndian)
        case .float64:
            let bits = base.loadUnaligned(fromByteOffset: off, as: UInt64.self)
            return Float(Double(bitPattern: bigEndian ? bits.bigEndian : bits.littleEndian))
        case .uint8:
            return Float(base.loadUnaligned(fromByteOffset: off, as: UInt8.self))
        case .int8:
            return Float(base.loadUnaligned(fromByteOffset: off, as: Int8.self))
        case .uint16:
            let v = base.loadUnaligned(fromByteOffset: off, as: UInt16.self)
            return Float(bigEndian ? v.bigEndian : v.littleEndian)
        case .int16:
            let v = base.loadUnaligned(fromByteOffset: off, as: Int16.self)
            return Float(bigEndian ? v.bigEndian : v.littleEndian)
        case .uint32:
            let v = base.loadUnaligned(fromByteOffset: off, as: UInt32.self)
            return Float(bigEndian ? v.bigEndian : v.littleEndian)
        case .int32:
            let v = base.loadUnaligned(fromByteOffset: off, as: Int32.self)
            return Float(bigEndian ? v.bigEndian : v.littleEndian)
        case .list:
            return 0
        }
    }

    private static func loadPLYGaussianSplats(
        data: Data,
        bodyStart: Int,
        format: PLYFormat,
        vertexElement: PLYElement,
        propByName: [String: PLYProperty],
        fileInfo: SKPFileInfo,
        start: Date,
        progress: (@Sendable (SKPReader.Progress) -> Void)?,
        isCancelled: @Sendable () -> Bool
    ) throws -> SKPModel {
        let count = vertexElement.count
        progress?(SKPReader.Progress(
            phase: L("Lecture de \(count) Gaussian Splats (PLY)…", "Reading \(count) Gaussian Splats (PLY)…"),
            faces: 0,
            fraction: 0.20
        ))

        guard let pX = propByName["x"],
              let pY = propByName["y"],
              let pZ = propByName["z"],
              let pDC0 = propByName["f_dc_0"],
              let pDC1 = propByName["f_dc_1"],
              let pDC2 = propByName["f_dc_2"],
              let pOpacity = propByName["opacity"],
              let pScale0 = propByName["scale_0"],
              let pScale1 = propByName["scale_1"],
              let pScale2 = propByName["scale_2"],
              let pRot0 = propByName["rot_0"],
              let pRot1 = propByName["rot_1"],
              let pRot2 = propByName["rot_2"],
              let pRot3 = propByName["rot_3"] else {
            throw SKPError.unreadable(fileInfo.url)
        }

        // Discover optional higher-order spherical harmonics (`f_rest_0 .. f_rest_44`)
        var restProps: [PLYProperty] = []
        for i in 0..<45 {
            if let rp = propByName["f_rest_\(i)"] {
                restProps.append(rp)
            } else {
                break
            }
        }
        let shDegree: UInt8
        let shBandsPerChannel: Int
        if restProps.count >= 45 {
            shDegree = 3; shBandsPerChannel = 15
        } else if restProps.count >= 24 {
            shDegree = 2; shBandsPerChannel = 8
        } else if restProps.count >= 9 {
            shDegree = 1; shBandsPerChannel = 3
        } else {
            shDegree = 0; shBandsPerChannel = 0
        }
        let shFloatsPerSplat = shBandsPerChannel * 3

        var splats = [SKPModel.PackedSplat](
            repeating: SKPModel.PackedSplat(
                position: .zero,
                colorR: 0, colorG: 0, colorB: 0, colorA: 0,
                covAx: 0, covAy: 0, covAz: 0,
                covBx: 0, covBy: 0, covBz: 0
            ),
            count: count
        )
        var shData = [Float16](repeating: 0, count: count * shFloatsPerSplat)

        switch format {
        case .binaryLittleEndian, .binaryBigEndian:
            guard let stride = vertexElement.fixedByteStride,
                  bodyStart + count * stride <= data.count else {
                throw SKPError.unreadable(fileInfo.url)
            }
            let bigEndian = (format == .binaryBigEndian)
            let restPropList = restProps

            data.withUnsafeBytes { rawBuf in
                guard let base = rawBuf.baseAddress else { return }
                let vBase = base.advanced(by: bodyStart)
                splats.withUnsafeMutableBufferPointer { outSplats in
                    shData.withUnsafeMutableBufferPointer { outSH in
                        let splatPtr = outSplats.baseAddress!
                        let shPtr = outSH.baseAddress
                        let chunks = max(1, min(16, count / 16_384))
                        let perChunk = (count + chunks - 1) / chunks

                        DispatchQueue.concurrentPerform(iterations: chunks) { chunk in
                            let startIdx = chunk * perChunk
                            let endIdx = min(count, startIdx + perChunk)
                            guard startIdx < endIdx else { return }

                            for i in startIdx..<endIdx {
                                let rowOff = i * stride
                                let rx = readBinaryFloat(vBase, offset: rowOff, prop: pX, bigEndian: bigEndian)
                                let ry = readBinaryFloat(vBase, offset: rowOff, prop: pY, bigEndian: bigEndian)
                                let rz = readBinaryFloat(vBase, offset: rowOff, prop: pZ, bigEndian: bigEndian)

                                let dc0 = readBinaryFloat(vBase, offset: rowOff, prop: pDC0, bigEndian: bigEndian)
                                let dc1 = readBinaryFloat(vBase, offset: rowOff, prop: pDC1, bigEndian: bigEndian)
                                let dc2 = readBinaryFloat(vBase, offset: rowOff, prop: pDC2, bigEndian: bigEndian)
                                let rawOp = readBinaryFloat(vBase, offset: rowOff, prop: pOpacity, bigEndian: bigEndian)

                                let s0 = exp(simd_clamp(readBinaryFloat(vBase, offset: rowOff, prop: pScale0, bigEndian: bigEndian), -20, 20))
                                let s1 = exp(simd_clamp(readBinaryFloat(vBase, offset: rowOff, prop: pScale1, bigEndian: bigEndian), -20, 20))
                                let s2 = exp(simd_clamp(readBinaryFloat(vBase, offset: rowOff, prop: pScale2, bigEndian: bigEndian), -20, 20))

                                // Standard 3DGS PLY stores quaternion as (rot_0 = w, rot_1 = x, rot_2 = y, rot_3 = z)
                                let qw = readBinaryFloat(vBase, offset: rowOff, prop: pRot0, bigEndian: bigEndian)
                                let qx = readBinaryFloat(vBase, offset: rowOff, prop: pRot1, bigEndian: bigEndian)
                                let qy = readBinaryFloat(vBase, offset: rowOff, prop: pRot2, bigEndian: bigEndian)
                                let qz = readBinaryFloat(vBase, offset: rowOff, prop: pRot3, bigEndian: bigEndian)

                                let colR = max(0, 0.5 + shC0 * dc0)
                                let colG = max(0, 0.5 + shC0 * dc1)
                                let colB = max(0, 0.5 + shC0 * dc2)
                                let alpha = 1.0 / (1.0 + exp(-rawOp))

                                let posZUp = SIMD3<Float>(
                                    rx.isFinite ? rx : 0,
                                    rz.isFinite ? rz : 0,
                                    ry.isFinite ? -ry : 0
                                )
                                let (covA, covB) = covarianceZUpFromRDF(
                                    scale: SIMD3<Float>(s0, s1, s2),
                                    quatXYZW: SIMD4<Float>(qx, qy, qz, qw)
                                )
                                splatPtr[i] = SKPModel.PackedSplat(
                                    position: posZUp,
                                    colorR: Float16(colR), colorG: Float16(colG), colorB: Float16(colB), colorA: Float16(alpha),
                                    covAx: covA.x, covAy: covA.y, covAz: covA.z,
                                    covBx: covB.x, covBy: covB.y, covBz: covB.z
                                )

                                // Interleave planar f_rest [R0..RN, G0..GN, B0..BN] -> [R0, G0, B0, R1, G1, B1, ...]
                                if shBandsPerChannel > 0, let shPtr {
                                    let outBase = i * shFloatsPerSplat
                                    // Note: total bands in file might be 15 even if we use shBandsPerChannel
                                    let fileBandsPerChannel = restPropList.count / 3
                                    for b in 0..<shBandsPerChannel {
                                        let rVal = readBinaryFloat(vBase, offset: rowOff, prop: restPropList[b], bigEndian: bigEndian)
                                        let gVal = readBinaryFloat(vBase, offset: rowOff, prop: restPropList[fileBandsPerChannel + b], bigEndian: bigEndian)
                                        let bVal = readBinaryFloat(vBase, offset: rowOff, prop: restPropList[fileBandsPerChannel * 2 + b], bigEndian: bigEndian)
                                        shPtr[outBase + b * 3 + 0] = Float16(rVal)
                                        shPtr[outBase + b * 3 + 1] = Float16(gVal)
                                        shPtr[outBase + b * 3 + 2] = Float16(bVal)
                                    }
                                }
                            }
                        }
                    }
                }
            }

        case .ascii:
            guard let bodyText = String(data: data[bodyStart...], encoding: .utf8)
                ?? String(data: data[bodyStart...], encoding: .isoLatin1) else {
                throw SKPError.unreadable(fileInfo.url)
            }
            let propIndex = Dictionary(uniqueKeysWithValues: vertexElement.properties.enumerated().map { ($0.element.name, $0.offset) })
            let ix = propIndex["x"] ?? 0, iy = propIndex["y"] ?? 1, iz = propIndex["z"] ?? 2
            let idc0 = propIndex["f_dc_0"]!, idc1 = propIndex["f_dc_1"]!, idc2 = propIndex["f_dc_2"]!
            let iop = propIndex["opacity"]!
            let is0 = propIndex["scale_0"]!, is1 = propIndex["scale_1"]!, is2 = propIndex["scale_2"]!
            let ir0 = propIndex["rot_0"]!, ir1 = propIndex["rot_1"]!, ir2 = propIndex["rot_2"]!, ir3 = propIndex["rot_3"]!

            var idx = 0
            bodyText.enumerateLines { line, stop in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { return }
                let vals = trimmed.split(whereSeparator: { $0.isWhitespace }).compactMap { Float($0) }
                guard vals.count >= vertexElement.properties.count else { return }
                let rx = vals[ix], ry = vals[iy], rz = vals[iz]
                let colR = max(0, 0.5 + shC0 * vals[idc0])
                let colG = max(0, 0.5 + shC0 * vals[idc1])
                let colB = max(0, 0.5 + shC0 * vals[idc2])
                let alpha = 1.0 / (1.0 + exp(-vals[iop]))
                let s0 = exp(simd_clamp(vals[is0], -20, 20))
                let s1 = exp(simd_clamp(vals[is1], -20, 20))
                let s2 = exp(simd_clamp(vals[is2], -20, 20))
                let (covA, covB) = covarianceZUpFromRDF(
                    scale: SIMD3<Float>(s0, s1, s2),
                    quatXYZW: SIMD4<Float>(vals[ir1], vals[ir2], vals[ir3], vals[ir0])
                )
                splats[idx] = SKPModel.PackedSplat(
                    position: SIMD3<Float>(rx, rz, -ry),
                    colorR: Float16(colR), colorG: Float16(colG), colorB: Float16(colB), colorA: Float16(alpha),
                    covAx: covA.x, covAy: covA.y, covAz: covA.z,
                    covBx: covB.x, covBy: covB.y, covBz: covB.z
                )
                idx += 1
                if idx >= count { stop = true }
            }
            if idx < count { splats.removeSubrange(idx..<count) }
        }

        if isCancelled() { throw SKPError.cancelled }
        return finalizeSplatModel(
            kind: .gaussianSplats,
            splats: &splats,
            shDegree: shDegree,
            shCoefficients: shData,
            shDirCols: (SIMD3(1, 0, 0), SIMD3(0, 0, 1), SIMD3(0, -1, 0)),
            fileInfo: fileInfo,
            start: start,
            progress: progress
        )
    }

    private static func loadPLYPointCloud(
        data: Data,
        bodyStart: Int,
        format: PLYFormat,
        vertexElement: PLYElement,
        propByName: [String: PLYProperty],
        fileInfo: SKPFileInfo,
        start: Date,
        progress: (@Sendable (SKPReader.Progress) -> Void)?,
        isCancelled: @Sendable () -> Bool
    ) throws -> SKPModel {
        let count = vertexElement.count
        progress?(SKPReader.Progress(
            phase: L("Lecture du nuage de points PLY (\(count) points)…", "Reading PLY point cloud (\(count) points)…"),
            faces: 0,
            fraction: 0.20
        ))

        guard let pX = propByName["x"],
              let pY = propByName["y"],
              let pZ = propByName["z"] else {
            throw SKPError.unreadable(fileInfo.url)
        }
        let pR = propByName["red"] ?? propByName["r"] ?? propByName["diffuse_red"]
        let pG = propByName["green"] ?? propByName["g"] ?? propByName["diffuse_green"]
        let pB = propByName["blue"] ?? propByName["b"] ?? propByName["diffuse_blue"]
        let pA = propByName["alpha"] ?? propByName["a"]
        let pIntensity = propByName["intensity"] ?? propByName["scalar_intensity"] ?? propByName["scalar_Intensity"] ?? propByName["reflectance"]

        let colorScale: Float = {
            guard let pR else { return 1.0 }
            switch pR.type {
            case .uint8, .int8: return 1.0 / 255.0
            case .uint16, .int16: return 1.0 / 65535.0
            default: return 1.0
            }
        }()

        var splats = [SKPModel.PackedSplat](
            repeating: SKPModel.PackedSplat(
                position: .zero,
                colorR: 0.85, colorG: 0.85, colorB: 0.85, colorA: 1,
                covAx: 0, covAy: 0, covAz: 0,
                covBx: 0, covBy: 0, covBz: 0
            ),
            count: count
        )

        switch format {
        case .binaryLittleEndian, .binaryBigEndian:
            guard let stride = vertexElement.fixedByteStride,
                  bodyStart + count * stride <= data.count else {
                throw SKPError.unreadable(fileInfo.url)
            }
            let bigEndian = (format == .binaryBigEndian)
            data.withUnsafeBytes { rawBuf in
                guard let base = rawBuf.baseAddress else { return }
                let vBase = base.advanced(by: bodyStart)
                splats.withUnsafeMutableBufferPointer { outBuf in
                    let outPtr = outBuf.baseAddress!
                    let chunks = max(1, min(16, count / 16_384))
                    let perChunk = (count + chunks - 1) / chunks
                    DispatchQueue.concurrentPerform(iterations: chunks) { chunk in
                        let startIdx = chunk * perChunk
                        let endIdx = min(count, startIdx + perChunk)
                        guard startIdx < endIdx else { return }
                        for i in startIdx..<endIdx {
                            let rowOff = i * stride
                            let px = readBinaryFloat(vBase, offset: rowOff, prop: pX, bigEndian: bigEndian)
                            let py = readBinaryFloat(vBase, offset: rowOff, prop: pY, bigEndian: bigEndian)
                            let pz = readBinaryFloat(vBase, offset: rowOff, prop: pZ, bigEndian: bigEndian)
                            var r: Float = 0.86, g: Float = 0.86, b: Float = 0.88, a: Float = 1.0
                            if let pR, let pG, let pB {
                                let rawR = readBinaryFloat(vBase, offset: rowOff, prop: pR, bigEndian: bigEndian)
                                let rawG = readBinaryFloat(vBase, offset: rowOff, prop: pG, bigEndian: bigEndian)
                                let rawB = readBinaryFloat(vBase, offset: rowOff, prop: pB, bigEndian: bigEndian)
                                let scale = (colorScale == 1.0 && (rawR > 1.01 || rawG > 1.01 || rawB > 1.01)) ? (1.0 / 255.0) : colorScale
                                r = simd_clamp(rawR * scale, 0, 1)
                                g = simd_clamp(rawG * scale, 0, 1)
                                b = simd_clamp(rawB * scale, 0, 1)
                            } else if let pIntensity {
                                let rawI = readBinaryFloat(vBase, offset: rowOff, prop: pIntensity, bigEndian: bigEndian)
                                let normI = rawI > 1.01 ? simd_clamp(rawI / 255.0, 0.1, 1.0) : simd_clamp(rawI, 0.1, 1.0)
                                r = normI; g = normI; b = normI
                            }
                            if let pA {
                                let rawA = readBinaryFloat(vBase, offset: rowOff, prop: pA, bigEndian: bigEndian)
                                a = rawA > 1.01 ? simd_clamp(rawA / 255.0, 0, 1) : simd_clamp(rawA, 0, 1)
                            }
                            outPtr[i] = SKPModel.PackedSplat(
                                position: SIMD3<Float>(px.isFinite ? px : 0, py.isFinite ? py : 0, pz.isFinite ? pz : 0),
                                colorR: Float16(r), colorG: Float16(g), colorB: Float16(b), colorA: Float16(a),
                                covAx: 0, covAy: 0, covAz: 0,
                                covBx: 0, covBy: 0, covBz: 0
                            )
                        }
                    }
                }
            }

        case .ascii:
            guard let bodyText = String(data: data[bodyStart...], encoding: .utf8)
                ?? String(data: data[bodyStart...], encoding: .isoLatin1) else {
                throw SKPError.unreadable(fileInfo.url)
            }
            let propIndex = Dictionary(uniqueKeysWithValues: vertexElement.properties.enumerated().map { ($0.element.name, $0.offset) })
            let ix = propIndex["x"] ?? 0, iy = propIndex["y"] ?? 1, iz = propIndex["z"] ?? 2
            let ir = pR.flatMap { propIndex[$0.name] }
            let ig = pG.flatMap { propIndex[$0.name] }
            let ib = pB.flatMap { propIndex[$0.name] }
            let ii = pIntensity.flatMap { propIndex[$0.name] }

            var idx = 0
            bodyText.enumerateLines { line, stop in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { return }
                let vals = trimmed.split(whereSeparator: { $0.isWhitespace }).compactMap { Float($0) }
                guard vals.count > max(ix, max(iy, iz)) else { return }
                var r: Float = 0.86, g: Float = 0.86, b: Float = 0.88
                if let ir, let ig, let ib, vals.count > max(ir, max(ig, ib)) {
                    let rawR = vals[ir], rawG = vals[ig], rawB = vals[ib]
                    let scale: Float = (rawR > 1.01 || rawG > 1.01 || rawB > 1.01) ? (1.0 / 255.0) : 1.0
                    r = simd_clamp(rawR * scale, 0, 1)
                    g = simd_clamp(rawG * scale, 0, 1)
                    b = simd_clamp(rawB * scale, 0, 1)
                } else if let ii, vals.count > ii {
                    let rawI = vals[ii]
                    let normI = rawI > 1.01 ? simd_clamp(rawI / 255.0, 0.1, 1.0) : simd_clamp(rawI, 0.1, 1.0)
                    r = normI; g = normI; b = normI
                }
                splats[idx] = SKPModel.PackedSplat(
                    position: SIMD3<Float>(vals[ix], vals[iy], vals[iz]),
                    colorR: Float16(r), colorG: Float16(g), colorB: Float16(b), colorA: 1.0,
                    covAx: 0, covAy: 0, covAz: 0,
                    covBx: 0, covBy: 0, covBz: 0
                )
                idx += 1
                if idx >= count { stop = true }
            }
            if idx < count { splats.removeSubrange(idx..<count) }
        }

        if isCancelled() { throw SKPError.cancelled }
        return finalizeSplatModel(
            kind: .pointCloud,
            splats: &splats,
            shDegree: 0,
            shCoefficients: [],
            shDirCols: (SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, 1)),
            fileInfo: fileInfo,
            start: start,
            progress: progress
        )
    }

    private static func loadPLYMesh(
        data: Data,
        bodyStart: Int,
        format: PLYFormat,
        elements: [PLYElement],
        vertexElement: PLYElement,
        faceElement: PLYElement,
        fileInfo: SKPFileInfo,
        start: Date,
        progress: (@Sendable (SKPReader.Progress) -> Void)?,
        isCancelled: @Sendable () -> Bool
    ) throws -> SKPModel {
        let vCount = vertexElement.count
        let fCount = faceElement.count
        let propByName = Dictionary(uniqueKeysWithValues: vertexElement.properties.map { ($0.name, $0) })
        guard let pX = propByName["x"], let pY = propByName["y"], let pZ = propByName["z"] else {
            throw SKPError.unreadable(fileInfo.url)
        }
        let pNX = propByName["nx"], pNY = propByName["ny"], pNZ = propByName["nz"]
        let pU = propByName["u"] ?? propByName["s"] ?? propByName["texture_u"]
        let pV = propByName["v"] ?? propByName["t"] ?? propByName["texture_v"]

        var vertices = [SIMD3<Float>](repeating: .zero, count: vCount)
        var vNormals = (pNX != nil && pNY != nil && pNZ != nil) ? [SIMD3<Float>](repeating: SIMD3(0, 0, 1), count: vCount) : []
        var vUVs = (pU != nil && pV != nil) ? [SIMD2<Float>](repeating: .zero, count: vCount) : []

        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var uvs: [SIMD2<Float>] = []
        var indices: [UInt32] = []
        var box = SKPReader.Box()
        var totalFaces = 0

        switch format {
        case .binaryLittleEndian, .binaryBigEndian:
            guard let vStride = vertexElement.fixedByteStride,
                  bodyStart + vCount * vStride <= data.count else {
                throw SKPError.unreadable(fileInfo.url)
            }
            let bigEndian = (format == .binaryBigEndian)
            data.withUnsafeBytes { rawBuf in
                guard let base = rawBuf.baseAddress else { return }
                let vBase = base.advanced(by: bodyStart)
                for i in 0..<vCount {
                    let rowOff = i * vStride
                    vertices[i] = SIMD3<Float>(
                        readBinaryFloat(vBase, offset: rowOff, prop: pX, bigEndian: bigEndian),
                        readBinaryFloat(vBase, offset: rowOff, prop: pY, bigEndian: bigEndian),
                        readBinaryFloat(vBase, offset: rowOff, prop: pZ, bigEndian: bigEndian)
                    )
                    if let pNX, let pNY, let pNZ {
                        vNormals[i] = SIMD3<Float>(
                            readBinaryFloat(vBase, offset: rowOff, prop: pNX, bigEndian: bigEndian),
                            readBinaryFloat(vBase, offset: rowOff, prop: pNY, bigEndian: bigEndian),
                            readBinaryFloat(vBase, offset: rowOff, prop: pNZ, bigEndian: bigEndian)
                        )
                    }
                    if let pU, let pV {
                        vUVs[i] = SIMD2<Float>(
                            readBinaryFloat(vBase, offset: rowOff, prop: pU, bigEndian: bigEndian),
                            readBinaryFloat(vBase, offset: rowOff, prop: pV, bigEndian: bigEndian)
                        )
                    }
                }

                var cursor = bodyStart + vCount * vStride
                guard let listProp = faceElement.properties.first,
                      case .list(let countType, let valType) = listProp.type else { return }
                let cSize = countType.byteSize
                let vSize = valType.byteSize

                func readInt(_ off: Int, type: PLYPropertyType) -> Int {
                    switch type {
                    case .uint8: return Int(base.loadUnaligned(fromByteOffset: off, as: UInt8.self))
                    case .int8: return Int(base.loadUnaligned(fromByteOffset: off, as: Int8.self))
                    case .uint16:
                        let v = base.loadUnaligned(fromByteOffset: off, as: UInt16.self)
                        return Int(bigEndian ? v.bigEndian : v.littleEndian)
                    case .int16:
                        let v = base.loadUnaligned(fromByteOffset: off, as: Int16.self)
                        return Int(bigEndian ? v.bigEndian : v.littleEndian)
                    case .uint32:
                        let v = base.loadUnaligned(fromByteOffset: off, as: UInt32.self)
                        return Int(bigEndian ? v.bigEndian : v.littleEndian)
                    case .int32:
                        let v = base.loadUnaligned(fromByteOffset: off, as: Int32.self)
                        return Int(bigEndian ? v.bigEndian : v.littleEndian)
                    default: return 0
                    }
                }

                for _ in 0..<fCount {
                    guard cursor + cSize <= data.count else { break }
                    let nVerts = readInt(cursor, type: countType)
                    cursor += cSize
                    guard nVerts >= 3, cursor + nVerts * vSize <= data.count else {
                        cursor += max(0, nVerts * vSize)
                        continue
                    }
                    let i0 = readInt(cursor, type: valType)
                    for k in 1..<(nVerts - 1) {
                        let i1 = readInt(cursor + k * vSize, type: valType)
                        let i2 = readInt(cursor + (k + 1) * vSize, type: valType)
                        guard i0 >= 0 && i0 < vCount && i1 >= 0 && i1 < vCount && i2 >= 0 && i2 < vCount else { continue }
                        let p0 = vertices[i0], p1 = vertices[i1], p2 = vertices[i2]
                        let baseV = UInt32(positions.count)
                        positions.append(p0); positions.append(p1); positions.append(p2)
                        if !vNormals.isEmpty {
                            normals.append(vNormals[i0]); normals.append(vNormals[i1]); normals.append(vNormals[i2])
                        } else {
                            let cn = simd_cross(p1 - p0, p2 - p0)
                            let len = simd_length(cn)
                            let fn = len > 1e-7 ? cn / len : SIMD3<Float>(0, 0, 1)
                            normals.append(fn); normals.append(fn); normals.append(fn)
                        }
                        if !vUVs.isEmpty {
                            uvs.append(vUVs[i0]); uvs.append(vUVs[i1]); uvs.append(vUVs[i2])
                        }
                        indices.append(baseV); indices.append(baseV + 1); indices.append(baseV + 2)
                        box.add(p0); box.add(p1); box.add(p2)
                    }
                    totalFaces += 1
                    cursor += nVerts * vSize
                }
            }

        case .ascii:
            guard let bodyText = String(data: data[bodyStart...], encoding: .utf8)
                ?? String(data: data[bodyStart...], encoding: .isoLatin1) else {
                throw SKPError.unreadable(fileInfo.url)
            }
            let propIndex = Dictionary(uniqueKeysWithValues: vertexElement.properties.enumerated().map { ($0.element.name, $0.offset) })
            let ix = propIndex["x"] ?? 0, iy = propIndex["y"] ?? 1, iz = propIndex["z"] ?? 2
            var lineIdx = 0
            bodyText.enumerateLines { line, stop in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { return }
                if lineIdx < vCount {
                    let vals = trimmed.split(whereSeparator: { $0.isWhitespace }).compactMap { Float($0) }
                    if vals.count > max(ix, max(iy, iz)) {
                        vertices[lineIdx] = SIMD3<Float>(vals[ix], vals[iy], vals[iz])
                    }
                    lineIdx += 1
                } else if lineIdx < vCount + fCount {
                    let ints = trimmed.split(whereSeparator: { $0.isWhitespace }).compactMap { Int($0) }
                    if let nVerts = ints.first, nVerts >= 3, ints.count >= 1 + nVerts {
                        let i0 = ints[1]
                        for k in 1..<(nVerts - 1) {
                            let i1 = ints[1 + k], i2 = ints[1 + k + 1]
                            guard i0 >= 0 && i0 < vCount && i1 >= 0 && i1 < vCount && i2 >= 0 && i2 < vCount else { continue }
                            let p0 = vertices[i0], p1 = vertices[i1], p2 = vertices[i2]
                            let baseV = UInt32(positions.count)
                            positions.append(p0); positions.append(p1); positions.append(p2)
                            let cn = simd_cross(p1 - p0, p2 - p0)
                            let len = simd_length(cn)
                            let fn = len > 1e-7 ? cn / len : SIMD3<Float>(0, 0, 1)
                            normals.append(fn); normals.append(fn); normals.append(fn)
                            indices.append(baseV); indices.append(baseV + 1); indices.append(baseV + 2)
                            box.add(p0); box.add(p1); box.add(p2)
                        }
                        totalFaces += 1
                    }
                    lineIdx += 1
                } else {
                    stop = true
                }
            }
        }

        let mesh = SKPModel.Mesh(
            material: nil,
            layer: 0,
            positions: positions,
            normals: normals,
            uvs: uvs.isEmpty ? nil : uvs,
            indices: indices
        )
        let sharpEdges = Mesh3DReader.extractFeatureEdges(from: [mesh])
        let edgeSets = sharpEdges.isEmpty ? [] : [SKPModel.EdgeSet(layer: 0, positions: sharpEdges)]
        let rootDef = SKPModel.Definition(name: "", meshes: [mesh], edges: edgeSets)
        let stats = SKPModel.Stats(
            faces: totalFaces,
            triangles: indices.count / 3,
            edges: sharpEdges.count / 2,
            instances: 0,
            definitions: 0,
            loadSeconds: Date().timeIntervalSince(start)
        )
        return SKPModel(
            root: rootDef,
            layers: [SKPModel.Layer(name: "Layer0", isVisible: true)],
            boundsMin: box.isEmpty ? .zero : box.min,
            boundsMax: box.isEmpty ? .zero : box.max,
            stats: stats,
            fileInfo: fileInfo
        )
    }

    // MARK: - 4. `.xyz` & `.pts` Point Cloud Reader

    private static func loadXYZOrPTS(
        _ url: URL,
        fileInfo: SKPFileInfo,
        start: Date,
        progress: (@Sendable (SKPReader.Progress) -> Void)?,
        isCancelled: @Sendable () -> Bool
    ) throws -> SKPModel {
        progress?(SKPReader.Progress(
            phase: L("Lecture du nuage de points (\(url.pathExtension.uppercased()))…", "Reading point cloud (\(url.pathExtension.uppercased()))…"),
            faces: 0,
            fraction: 0.15
        ))
        let data: Data
        do {
            data = try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            throw SKPError.unreadable(url)
        }
        guard !data.isEmpty else { throw SKPError.unreadable(url) }

        var splats: [SKPModel.PackedSplat] = []
        splats.reserveCapacity(max(1024, data.count / 36))

        data.withUnsafeBytes { rawBuf in
            guard let base = rawBuf.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            let n = rawBuf.count
            var i = 0
            var vals = [Float](repeating: 0, count: 10)

            while i < n {
                // Skip leading spaces/newlines
                while i < n && (base[i] == 0x20 || base[i] == 0x09 || base[i] == 0x0D || base[i] == 0x0A) {
                    i += 1
                }
                guard i < n else { break }

                // Skip comment lines ('#', '/', ';')
                if base[i] == 0x23 || base[i] == 0x2F || base[i] == 0x3B {
                    while i < n && base[i] != 0x0A { i += 1 }
                    continue
                }

                // Parse numbers on this line
                var valCount = 0
                while i < n && base[i] != 0x0A && base[i] != 0x0D {
                    while i < n && (base[i] == 0x20 || base[i] == 0x09 || base[i] == 0x2C || base[i] == 0x3B) {
                        i += 1
                    }
                    if i >= n || base[i] == 0x0A || base[i] == 0x0D { break }
                    let tokenStart = i
                    while i < n && base[i] != 0x20 && base[i] != 0x09 && base[i] != 0x2C && base[i] != 0x3B && base[i] != 0x0A && base[i] != 0x0D {
                        i += 1
                    }
                    if valCount < 10, let v = parseFastFloat(base, start: tokenStart, end: i) {
                        vals[valCount] = v
                        valCount += 1
                    }
                }

                // A single-integer line at the top of a .pts file is the point count header -> skip it
                if valCount >= 3 {
                    let px = vals[0], py = vals[1], pz = vals[2]
                    var r: Float = 0.86, g: Float = 0.86, b: Float = 0.88
                    if valCount >= 7 {
                        // PTS format: X Y Z Intensity R G B (or X Y Z Nx Ny Nz Intensity, check if cols 4,5,6 look like RGB)
                        let c4 = vals[4], c5 = vals[5], c6 = vals[6]
                        let scale: Float = (c4 > 1.01 || c5 > 1.01 || c6 > 1.01) ? (1.0 / 255.0) : 1.0
                        r = simd_clamp(c4 * scale, 0, 1)
                        g = simd_clamp(c5 * scale, 0, 1)
                        b = simd_clamp(c6 * scale, 0, 1)
                    } else if valCount == 6 {
                        // XYZRGB: X Y Z R G B
                        let c3 = vals[3], c4 = vals[4], c5 = vals[5]
                        if c3 >= 0 && c4 >= 0 && c5 >= 0 {
                            let scale: Float = (c3 > 1.01 || c4 > 1.01 || c5 > 1.01) ? (1.0 / 255.0) : 1.0
                            r = simd_clamp(c3 * scale, 0, 1)
                            g = simd_clamp(c4 * scale, 0, 1)
                            b = simd_clamp(c5 * scale, 0, 1)
                        }
                    } else if valCount == 4 {
                        // XYZI: X Y Z Intensity
                        let rawI = vals[3]
                        let normI: Float
                        if rawI < 0 {
                            // Leica PTS intensity (-2048 .. 2047)
                            normI = simd_clamp((rawI + 2048.0) / 4095.0, 0.15, 1.0)
                        } else if rawI > 1.01 {
                            normI = simd_clamp(rawI / 255.0, 0.15, 1.0)
                        } else {
                            normI = simd_clamp(rawI, 0.15, 1.0)
                        }
                        r = normI; g = normI; b = normI
                    }
                    splats.append(SKPModel.PackedSplat(
                        position: SIMD3<Float>(px, py, pz),
                        colorR: Float16(r), colorG: Float16(g), colorB: Float16(b), colorA: 1.0,
                        covAx: 0, covAy: 0, covAz: 0,
                        covBx: 0, covBy: 0, covBz: 0
                    ))
                }
            }
        }

        guard !splats.isEmpty else { throw SKPError.unreadable(url) }
        if isCancelled() { throw SKPError.cancelled }

        return finalizeSplatModel(
            kind: .pointCloud,
            splats: &splats,
            shDegree: 0,
            shCoefficients: [],
            shDirCols: (SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, 1)),
            fileInfo: fileInfo,
            start: start,
            progress: progress
        )
    }

    @inline(__always)
    private static func parseFastFloat(_ buf: UnsafePointer<UInt8>, start: Int, end: Int) -> Float? {
        guard start < end else { return nil }
        var idx = start
        var sign: Double = 1.0
        if buf[idx] == 0x2D { // '-'
            sign = -1.0; idx += 1
        } else if buf[idx] == 0x2B { // '+'
            idx += 1
        }
        guard idx < end else { return nil }
        var intPart: Double = 0
        var hasDigits = false
        while idx < end && buf[idx] >= 0x30 && buf[idx] <= 0x39 {
            intPart = intPart * 10.0 + Double(buf[idx] - 0x30)
            hasDigits = true
            idx += 1
        }
        var fracPart: Double = 0
        var fracDiv: Double = 1.0
        if idx < end && buf[idx] == 0x2E { // '.'
            idx += 1
            while idx < end && buf[idx] >= 0x30 && buf[idx] <= 0x39 {
                fracPart = fracPart * 10.0 + Double(buf[idx] - 0x30)
                fracDiv *= 10.0
                hasDigits = true
                idx += 1
            }
        }
        guard hasDigits else { return nil }
        var result = sign * (intPart + fracPart / fracDiv)
        if idx < end && (buf[idx] == 0x65 || buf[idx] == 0x45) { // 'e' or 'E'
            idx += 1
            var expSign = 1
            if idx < end && buf[idx] == 0x2D { expSign = -1; idx += 1 }
            else if idx < end && buf[idx] == 0x2B { idx += 1 }
            var expVal = 0
            while idx < end && buf[idx] >= 0x30 && buf[idx] <= 0x39 {
                expVal = expVal * 10 + Int(buf[idx] - 0x30)
                idx += 1
            }
            result *= pow(10.0, Double(expSign * expVal))
        }
        return Float(result)
    }

    // MARK: - 5. `.pcd` Reader (Point Cloud Library v0.7 ASCII / Binary / Binary Compressed)

    private static func loadPCD(
        _ url: URL,
        fileInfo: SKPFileInfo,
        start: Date,
        progress: (@Sendable (SKPReader.Progress) -> Void)?,
        isCancelled: @Sendable () -> Bool
    ) throws -> SKPModel {
        progress?(SKPReader.Progress(
            phase: L("Lecture du nuage de points (.pcd)…", "Reading point cloud (.pcd)…"),
            faces: 0,
            fraction: 0.15
        ))
        let data: Data
        do {
            data = try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            throw SKPError.unreadable(url)
        }
        guard data.count >= 32 else { throw SKPError.unreadable(url) }

        // Parse PCD header up to "DATA ..." line
        let searchLimit = min(data.count, 16_384)
        var bodyStart = 0
        var fields: [String] = []
        var sizes: [Int] = []
        var types: [String] = []
        var counts: [Int] = []
        var pointsCount = 0
        var width = 0
        var height = 1
        var dataMode = "ascii"

        let headerSlice = data[0..<searchLimit]
        let headerStr = String(data: headerSlice, encoding: .utf8) ?? String(data: headerSlice, encoding: .isoLatin1) ?? ""
        var offset = 0
        for rawLine in headerStr.components(separatedBy: "\n") {
            let lineLen = rawLine.utf8.count + 1
            offset += lineLen
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let parts = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            guard let key = parts.first?.uppercased() else { continue }
            switch key {
            case "FIELDS": fields = Array(parts.dropFirst()).map { $0.lowercased() }
            case "SIZE": sizes = parts.dropFirst().compactMap { Int($0) }
            case "TYPE": types = parts.dropFirst().map { $0.uppercased() }
            case "COUNT": counts = parts.dropFirst().compactMap { Int($0) }
            case "WIDTH": width = parts.dropFirst().first.flatMap { Int($0) } ?? 0
            case "HEIGHT": height = parts.dropFirst().first.flatMap { Int($0) } ?? 1
            case "POINTS": pointsCount = parts.dropFirst().first.flatMap { Int($0) } ?? 0
            case "DATA":
                dataMode = parts.dropFirst().first?.lowercased() ?? "ascii"
                bodyStart = offset
            default:
                break
            }
            if key == "DATA" { break }
        }

        if pointsCount <= 0 { pointsCount = width * max(1, height) }
        guard pointsCount > 0, !fields.isEmpty, sizes.count == fields.count else {
            throw SKPError.unreadable(url)
        }
        if counts.count != fields.count {
            counts = Array(repeating: 1, count: fields.count)
        }
        if types.count != fields.count {
            types = Array(repeating: "F", count: fields.count)
        }

        var fieldOffsets: [String: (offset: Int, size: Int, type: String)] = [:]
        var pointStride = 0
        for i in 0..<fields.count {
            fieldOffsets[fields[i]] = (pointStride, sizes[i], types[i])
            pointStride += sizes[i] * max(1, counts[i])
        }
        guard let fX = fieldOffsets["x"], let fY = fieldOffsets["y"], let fZ = fieldOffsets["z"] else {
            throw SKPError.unreadable(url)
        }
        let fRGB = fieldOffsets["rgb"] ?? fieldOffsets["rgba"]
        let fIntensity = fieldOffsets["intensity"]

        var splats: [SKPModel.PackedSplat] = []

        if dataMode == "binary" {
            guard bodyStart + pointsCount * pointStride <= data.count else {
                throw SKPError.unreadable(url)
            }
            splats.reserveCapacity(pointsCount)
            data.withUnsafeBytes { rawBuf in
                guard let base = rawBuf.baseAddress else { return }
                let bPtr = base.advanced(by: bodyStart)
                for i in 0..<pointsCount {
                    let row = i * pointStride
                    let px = bPtr.loadUnaligned(fromByteOffset: row + fX.offset, as: Float.self)
                    let py = bPtr.loadUnaligned(fromByteOffset: row + fY.offset, as: Float.self)
                    let pz = bPtr.loadUnaligned(fromByteOffset: row + fZ.offset, as: Float.self)
                    guard px.isFinite && py.isFinite && pz.isFinite else { continue }
                    var r: Float = 0.86, g: Float = 0.86, b: Float = 0.88
                    if let fRGB, fRGB.size == 4 {
                        let packed = bPtr.loadUnaligned(fromByteOffset: row + fRGB.offset, as: UInt32.self).littleEndian
                        r = Float((packed >> 16) & 0xFF) / 255.0
                        g = Float((packed >> 8) & 0xFF) / 255.0
                        b = Float(packed & 0xFF) / 255.0
                    } else if let fIntensity, fIntensity.size == 4 {
                        let rawI = bPtr.loadUnaligned(fromByteOffset: row + fIntensity.offset, as: Float.self)
                        let normI = rawI > 1.01 ? simd_clamp(rawI / 255.0, 0.15, 1.0) : simd_clamp(rawI, 0.15, 1.0)
                        r = normI; g = normI; b = normI
                    }
                    splats.append(SKPModel.PackedSplat(
                        position: SIMD3<Float>(px, py, pz),
                        colorR: Float16(r), colorG: Float16(g), colorB: Float16(b), colorA: 1.0,
                        covAx: 0, covAy: 0, covAz: 0,
                        covBx: 0, covBy: 0, covBz: 0
                    ))
                }
            }
        } else {
            // ASCII mode
            guard let bodyText = String(data: data[bodyStart...], encoding: .utf8)
                ?? String(data: data[bodyStart...], encoding: .isoLatin1) else {
                throw SKPError.unreadable(url)
            }
            let ix = fields.firstIndex(of: "x") ?? 0
            let iy = fields.firstIndex(of: "y") ?? 1
            let iz = fields.firstIndex(of: "z") ?? 2
            let irgb = fields.firstIndex(of: "rgb") ?? fields.firstIndex(of: "rgba")
            let iInt = fields.firstIndex(of: "intensity")

            bodyText.enumerateLines { line, _ in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { return }
                let parts = trimmed.split(whereSeparator: { $0.isWhitespace })
                guard parts.count > max(ix, max(iy, iz)),
                      let px = Float(parts[ix]),
                      let py = Float(parts[iy]),
                      let pz = Float(parts[iz]),
                      px.isFinite && py.isFinite && pz.isFinite else { return }
                var r: Float = 0.86, g: Float = 0.86, b: Float = 0.88
                if let irgb, parts.count > irgb {
                    let tok = parts[irgb]
                    let packed: UInt32
                    if let u = UInt32(tok) {
                        packed = u
                    } else if let f = Float(tok) {
                        packed = f.bitPattern
                    } else {
                        packed = 0xDCDCDC
                    }
                    r = Float((packed >> 16) & 0xFF) / 255.0
                    g = Float((packed >> 8) & 0xFF) / 255.0
                    b = Float(packed & 0xFF) / 255.0
                } else if let iInt, parts.count > iInt, let rawI = Float(parts[iInt]) {
                    let normI = rawI > 1.01 ? simd_clamp(rawI / 255.0, 0.15, 1.0) : simd_clamp(rawI, 0.15, 1.0)
                    r = normI; g = normI; b = normI
                }
                splats.append(SKPModel.PackedSplat(
                    position: SIMD3<Float>(px, py, pz),
                    colorR: Float16(r), colorG: Float16(g), colorB: Float16(b), colorA: 1.0,
                    covAx: 0, covAy: 0, covAz: 0,
                    covBx: 0, covBy: 0, covBz: 0
                ))
            }
        }

        guard !splats.isEmpty else { throw SKPError.unreadable(url) }
        return finalizeSplatModel(
            kind: .pointCloud,
            splats: &splats,
            shDegree: 0,
            shCoefficients: [],
            shDirCols: (SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, 1)),
            fileInfo: fileInfo,
            start: start,
            progress: progress
        )
    }

    // MARK: - 3D Covariance Helpers

    /// Computes 3D covariance `(covA, covB)` in `SimpleSKP` Z-up space from a scale and quaternion `(x, y, z, w)` in COLMAP `RDF` space.
    /// `M_RDF_to_ZUp` maps `(x, y, z)_RDF -> (x, z, -y)_ZUp`.
    @inline(__always)
    static func covarianceZUpFromRDF(scale: SIMD3<Float>, quatXYZW: SIMD4<Float>) -> (SIMD3<Float16>, SIMD3<Float16>) {
        let len = simd_length(quatXYZW)
        let q = len > 1e-8 ? (quatXYZW / len) : SIMD4<Float>(0, 0, 0, 1)
        let x = q.x, y = q.y, z = q.z, w = q.w

        // Rows of standard rotation matrix R_RDF:
        let r0 = SIMD3<Float>(1 - 2 * (y * y + z * z), 2 * (x * y - w * z), 2 * (x * z + w * y))
        let r1 = SIMD3<Float>(2 * (x * y + w * z), 1 - 2 * (x * x + z * z), 2 * (y * z - w * x))
        let r2 = SIMD3<Float>(2 * (x * z - w * y), 2 * (y * z + w * x), 1 - 2 * (x * x + y * y))

        // In Z-up (`(x, z, -y)`), the rows of `R_ZUp = M * R_RDF` are `(r0, r2, -r1)`:
        let z0 = r0
        let z1 = r2
        let z2 = -r1

        let s2 = scale * scale
        let z0s = z0 * s2
        let z1s = z1 * s2
        let z2s = z2 * s2

        let c00 = simd_dot(z0s, z0)
        let c01 = simd_dot(z0s, z1)
        let c02 = simd_dot(z0s, z2)
        let c11 = simd_dot(z1s, z1)
        let c12 = simd_dot(z1s, z2)
        let c22 = simd_dot(z2s, z2)

        return (
            SIMD3<Float16>(Float16(c00), Float16(c01), Float16(c02)),
            SIMD3<Float16>(Float16(c11), Float16(c12), Float16(c22))
        )
    }

    /// Computes 3D covariance `(covA, covB)` in `SimpleSKP` Z-up space from a scale and quaternion `(x, y, z, w)` in OpenGL/SPZ `RUB` space.
    /// `M_RUB_to_ZUp` maps `(x, y, z)_RUB -> (x, -z, y)_ZUp`.
    @inline(__always)
    static func covarianceZUpFromRUB(scale: SIMD3<Float>, quatXYZW: SIMD4<Float>) -> (SIMD3<Float16>, SIMD3<Float16>) {
        let len = simd_length(quatXYZW)
        let q = len > 1e-8 ? (quatXYZW / len) : SIMD4<Float>(0, 0, 0, 1)
        let x = q.x, y = q.y, z = q.z, w = q.w

        let r0 = SIMD3<Float>(1 - 2 * (y * y + z * z), 2 * (x * y - w * z), 2 * (x * z + w * y))
        let r1 = SIMD3<Float>(2 * (x * y + w * z), 1 - 2 * (x * x + z * z), 2 * (y * z - w * x))
        let r2 = SIMD3<Float>(2 * (x * z - w * y), 2 * (y * z + w * x), 1 - 2 * (x * x + y * y))

        // In Z-up (`(x, -z, y)`), the rows of `R_ZUp = M * R_RUB` are `(r0, -r2, r1)`:
        let z0 = r0
        let z1 = -r2
        let z2 = r1

        let s2 = scale * scale
        let z0s = z0 * s2
        let z1s = z1 * s2
        let z2s = z2 * s2

        let c00 = simd_dot(z0s, z0)
        let c01 = simd_dot(z0s, z1)
        let c02 = simd_dot(z0s, z2)
        let c11 = simd_dot(z1s, z1)
        let c12 = simd_dot(z1s, z2)
        let c22 = simd_dot(z2s, z2)

        return (
            SIMD3<Float16>(Float16(c00), Float16(c01), Float16(c02)),
            SIMD3<Float16>(Float16(c11), Float16(c12), Float16(c22))
        )
    }

    // MARK: - Morton Locality Sort & Final Model Assembly

    private static func finalizeSplatModel(
        kind: SKPModel.SplatCloud.Kind,
        splats: inout [SKPModel.PackedSplat],
        shDegree: UInt8,
        shCoefficients: [Float16],
        shDirCols: (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>),
        fileInfo: SKPFileInfo,
        start: Date,
        progress: (@Sendable (SKPReader.Progress) -> Void)?
    ) -> SKPModel {
        let count = splats.count
        progress?(SKPReader.Progress(
            phase: L("Tri spatial Morton (\(count) éléments)…", "Morton spatial sorting (\(count) elements)…"),
            faces: 0,
            fraction: 0.78
        ))

        // Compute overall bounding box & robust 5%..95% quantile bounds for Morton code quantization
        var boundsMin = SIMD3<Float>(repeating: .infinity)
        var boundsMax = SIMD3<Float>(repeating: -.infinity)
        for i in 0..<count {
            let p = splats[i].position
            if p.x.isFinite && p.y.isFinite && p.z.isFinite {
                boundsMin = simd_min(boundsMin, p)
                boundsMax = simd_max(boundsMax, p)
            }
        }
        if boundsMin.x > boundsMax.x {
            boundsMin = SIMD3<Float>(-1, -1, -1)
            boundsMax = SIMD3<Float>(1, 1, 1)
        }

        // Sort splats (and SH coefficients) by 30-bit 3D Morton code for cache locality and sub-block AABBs
        let extent = simd_max(boundsMax - boundsMin, SIMD3<Float>(repeating: 1e-5))
        let invExtent = SIMD3<Float>(repeating: 1023.0) / extent

        var mortonKeys = [UInt64](repeating: 0, count: count)
        splats.withUnsafeBufferPointer { sBuf in
            mortonKeys.withUnsafeMutableBufferPointer { kBuf in
                let sPtr = sBuf.baseAddress!
                let kPtr = kBuf.baseAddress!
                let chunks = max(1, min(16, count / 16_384))
                let perChunk = (count + chunks - 1) / chunks
                DispatchQueue.concurrentPerform(iterations: chunks) { chunk in
                    let startIdx = chunk * perChunk
                    let endIdx = min(count, startIdx + perChunk)
                    guard startIdx < endIdx else { return }
                    for i in startIdx..<endIdx {
                        let p = sPtr[i].position
                        let q = simd_clamp((p - boundsMin) * invExtent, .zero, SIMD3<Float>(repeating: 1023.0))
                        let code = morton3D(UInt32(q.x), UInt32(q.y), UInt32(q.z))
                        kPtr[i] = (UInt64(code) << 32) | UInt64(UInt32(i))
                    }
                }
            }
        }
        mortonKeys.sort()

        var sortedSplats = [SKPModel.PackedSplat](
            repeating: splats[0],
            count: count
        )
        let shFloatsPerSplat = count > 0 ? (shCoefficients.count / count) : 0
        var sortedSH = [Float16](repeating: 0, count: shCoefficients.count)

        for newIdx in 0..<count {
            let oldIdx = Int(UInt32(truncatingIfNeeded: mortonKeys[newIdx]))
            sortedSplats[newIdx] = splats[oldIdx]
            if shFloatsPerSplat > 0 {
                let srcOff = oldIdx * shFloatsPerSplat
                let dstOff = newIdx * shFloatsPerSplat
                for c in 0..<shFloatsPerSplat {
                    sortedSH[dstOff + c] = shCoefficients[srcOff + c]
                }
            }
        }

        let subBlocks = SKPModel.SplatCloud.buildSubBlocks(for: sortedSplats, blockSize: 256)
        let diag = max(0.1, simd_length(boundsMax - boundsMin))
        // Estimate a natural world-space surfel radius from model diagonal and point count
        let defaultPointRadius: Float = simd_clamp(
            diag / max(120.0, sqrt(Float(count)) * 0.85),
            diag * 0.0004,
            diag * 0.015
        )

        // For pure point clouds, populate isotropic covariance so they can also be rendered smoothly in 3DGS mode if desired
        if kind == .pointCloud {
            let sigma2 = Float16(defaultPointRadius * defaultPointRadius)
            for i in 0..<sortedSplats.count {
                sortedSplats[i].covAx = sigma2
                sortedSplats[i].covBx = sigma2
                sortedSplats[i].covBz = sigma2
            }
        }

        let cloud = SKPModel.SplatCloud(
            kind: kind,
            splats: sortedSplats,
            shDegree: shDegree,
            shCoefficients: sortedSH,
            shDirCol0: shDirCols.0,
            shDirCol1: shDirCols.1,
            shDirCol2: shDirCols.2,
            defaultPointRadius: defaultPointRadius,
            subBlocks: subBlocks
        )

        let layerName = (kind == .gaussianSplats) ? "Gaussian Splats" : "Point Cloud"
        let stats = SKPModel.Stats(
            faces: 0,
            triangles: 0,
            edges: 0,
            instances: 0,
            definitions: 0,
            splats: count,
            loadSeconds: Date().timeIntervalSince(start)
        )

        return SKPModel(
            root: SKPModel.Definition(name: ""),
            layers: [SKPModel.Layer(name: layerName, isVisible: true)],
            boundsMin: boundsMin,
            boundsMax: boundsMax,
            stats: stats,
            fileInfo: fileInfo,
            splatCloud: cloud
        )
    }

    @inline(__always)
    private static func expandBits10(_ v: UInt32) -> UInt32 {
        var x = v & 0x000003FF
        x = (x | (x << 16)) & 0x030000FF
        x = (x | (x <<  8)) & 0x0300F00F
        x = (x | (x <<  4)) & 0x030C30C3
        x = (x | (x <<  2)) & 0x09249249
        return x
    }

    @inline(__always)
    private static func morton3D(_ x: UInt32, _ y: UInt32, _ z: UInt32) -> UInt32 {
        (expandBits10(x) << 2) | (expandBits10(y) << 1) | expandBits10(z)
    }
}
