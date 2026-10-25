import Darwin
import Foundation

public let kSimpleSKPDefaultOSCInPort: UInt16 = 9150
public let kSimpleSKPDefaultOSCOutPort: UInt16 = 9151
public let kSimpleSKPDefaultHTTPPort: UInt16 = 17950

/// Minimal, zero-dependency OSC 1.0 packet & bundle encoder/decoder.
public enum OSCCodec {
    public enum Value: Equatable, Sendable {
        case int(Int32)
        case float(Float32)
        case string(String)
        case bool(Bool)
        case impulse

        public var boolValue: Bool? {
            switch self {
            case .bool(let b): return b
            case .impulse: return true
            case .int(let i): return i != 0
            case .float(let f): return f != 0
            case .string(let s):
                switch s.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) {
                case "1", "true", "on", "yes", "oui": return true
                case "0", "false", "off", "no", "non": return false
                default: return nil
                }
            }
        }

        public var doubleValue: Double? {
            switch self {
            case .int(let i): return Double(i)
            case .float(let f): return Double(f)
            case .bool(let b): return b ? 1.0 : 0.0
            case .impulse: return 1.0
            case .string(let s): return Double(s.replacingOccurrences(of: ",", with: "."))
            }
        }

        public var floatValue: Float? {
            doubleValue.map(Float.init)
        }

        public var intValue: Int? {
            switch self {
            case .int(let i): return Int(i)
            case .float(let f): return Int(f.rounded())
            case .bool(let b): return b ? 1 : 0
            case .impulse: return 1
            case .string(let s): return Int(s)
            }
        }

        public var stringValue: String {
            switch self {
            case .int(let i): return "\(i)"
            case .float(let f): return "\(f)"
            case .string(let s): return s
            case .bool(let b): return b ? "1" : "0"
            case .impulse: return "bang"
            }
        }
    }

    public struct Message: Equatable, Sendable {
        public var address: String
        public var arguments: [Value]

        public init(address: String, arguments: [Value] = []) {
            self.address = address
            self.arguments = arguments
        }

        public func double(at index: Int) -> Double? {
            guard arguments.indices.contains(index) else { return nil }
            return arguments[index].doubleValue
        }

        public func float(at index: Int) -> Float? {
            guard arguments.indices.contains(index) else { return nil }
            return arguments[index].floatValue
        }

        public func int(at index: Int) -> Int? {
            guard arguments.indices.contains(index) else { return nil }
            return arguments[index].intValue
        }

        public func bool(at index: Int) -> Bool? {
            guard arguments.indices.contains(index) else { return nil }
            return arguments[index].boolValue
        }

        public func string(at index: Int) -> String? {
            guard arguments.indices.contains(index) else { return nil }
            return arguments[index].stringValue
        }
    }

    public static func encode(_ message: Message) -> Data {
        var data = Data()
        appendPaddedString(message.address, to: &data)
        var typeTag = ","
        for arg in message.arguments {
            switch arg {
            case .int: typeTag.append("i")
            case .float: typeTag.append("f")
            case .string: typeTag.append("s")
            case .bool(let b): typeTag.append(b ? "T" : "F")
            case .impulse: typeTag.append("I")
            }
        }
        appendPaddedString(typeTag, to: &data)
        for arg in message.arguments {
            switch arg {
            case .int(let v):
                var be = v.bigEndian
                withUnsafeBytes(of: &be) { data.append(contentsOf: $0) }
            case .float(let v):
                var be = v.bitPattern.bigEndian
                withUnsafeBytes(of: &be) { data.append(contentsOf: $0) }
            case .string(let s):
                appendPaddedString(s, to: &data)
            case .bool, .impulse:
                break
            }
        }
        return data
    }

    public static func decode(_ data: Data) -> [Message] {
        let bytes = Array(data)
        guard !bytes.isEmpty else { return [] }
        if bytes.count >= 16, String(decoding: bytes[0..<7], as: UTF8.self) == "#bundle" {
            var offset = 16
            var out: [Message] = []
            while offset + 4 <= bytes.count {
                let size = Int(readUInt32(bytes, at: offset))
                offset += 4
                guard size > 0, offset + size <= bytes.count else { break }
                let slice = Data(bytes[offset..<(offset + size)])
                out.append(contentsOf: decode(slice))
                offset += size
            }
            return out
        }

        var idx = 0
        guard let address = readPaddedString(bytes, index: &idx), address.hasPrefix("/") else {
            return []
        }
        guard let tags = readPaddedString(bytes, index: &idx), tags.hasPrefix(",") else {
            return [Message(address: address, arguments: [])]
        }

        var args: [Value] = []
        for ch in tags.dropFirst() {
            switch ch {
            case "i":
                guard idx + 4 <= bytes.count else { break }
                let raw = Int32(bitPattern: readUInt32(bytes, at: idx))
                idx += 4
                args.append(.int(raw))
            case "h":
                guard idx + 8 <= bytes.count else { break }
                let hi = UInt64(readUInt32(bytes, at: idx)) << 32
                let lo = UInt64(readUInt32(bytes, at: idx + 4))
                let raw64 = Int64(bitPattern: hi | lo)
                idx += 8
                args.append(.int(Int32(clamping: raw64)))
            case "f":
                guard idx + 4 <= bytes.count else { break }
                let bits = readUInt32(bytes, at: idx)
                idx += 4
                args.append(.float(Float32(bitPattern: bits)))
            case "d":
                guard idx + 8 <= bytes.count else { break }
                let hi = UInt64(readUInt32(bytes, at: idx)) << 32
                let lo = UInt64(readUInt32(bytes, at: idx + 4))
                let dbl = Double(bitPattern: hi | lo)
                idx += 8
                args.append(.float(Float32(dbl)))
            case "s", "S":
                if let s = readPaddedString(bytes, index: &idx) {
                    args.append(.string(s))
                }
            case "T":
                args.append(.bool(true))
            case "F":
                args.append(.bool(false))
            case "I", "N":
                args.append(.impulse)
            default:
                break
            }
        }
        return [Message(address: address, arguments: args)]
    }

    private static func appendPaddedString(_ string: String, to data: inout Data) {
        data.append(contentsOf: string.utf8)
        data.append(0)
        while data.count % 4 != 0 {
            data.append(0)
        }
    }

    private static func readPaddedString(_ bytes: [UInt8], index: inout Int) -> String? {
        guard index < bytes.count else { return nil }
        var end = index
        while end < bytes.count && bytes[end] != 0 {
            end += 1
        }
        let str = String(decoding: bytes[index..<end], as: UTF8.self)
        let total = end - index + 1
        let padded = (total + 3) & ~3
        index = min(bytes.count, index + padded)
        return str
    }

    private static func readUInt32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        (UInt32(bytes[offset]) << 24)
            | (UInt32(bytes[offset + 1]) << 16)
            | (UInt32(bytes[offset + 2]) << 8)
            | UInt32(bytes[offset + 3])
    }
}

/// UDP OSC server for receiving show/automation cues (`/simpleskp/...` or `/camera/...`) from OSCScore or any OSC controller.
public final class OSCUDPServer: @unchecked Sendable {
    public private(set) var port: UInt16
    public private(set) var isRunning = false
    private var socketFD: Int32 = -1
    private let lock = NSLock()
    private let handler: @Sendable (OSCCodec.Message) -> Void

    public init(port: UInt16 = kSimpleSKPDefaultOSCInPort, handler: @escaping @Sendable (OSCCodec.Message) -> Void) {
        self.port = port
        self.handler = handler
    }

    deinit {
        stop()
    }

    @discardableResult
    public func start(maxPortAttempts: Int = 16) -> Bool {
        lock.lock()
        if isRunning {
            lock.unlock()
            return true
        }
        let preferredPort = self.port
        lock.unlock()

        let attempts = preferredPort == 0 ? 1 : max(1, maxPortAttempts)
        var boundFD: Int32 = -1
        var boundPort: UInt16 = 0

        for offset in 0..<attempts {
            let candidate: UInt16
            if preferredPort == 0 {
                candidate = 0
            } else {
                let next = Int(preferredPort) + offset
                guard next <= 65535 else { break }
                candidate = UInt16(next)
            }

            let fd = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
            guard fd >= 0 else { return false }
            var yes: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = candidate.bigEndian
            addr.sin_addr.s_addr = INADDR_ANY

            let bindRes = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            if bindRes == 0 {
                var bound = sockaddr_in()
                var len = socklen_t(MemoryLayout<sockaddr_in>.size)
                _ = withUnsafeMutablePointer(to: &bound) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        Darwin.getsockname(fd, $0, &len)
                    }
                }
                boundFD = fd
                boundPort = UInt16(bigEndian: bound.sin_port)
                break
            }
            Darwin.close(fd)
        }

        guard boundFD >= 0 else { return false }

        lock.lock()
        self.socketFD = boundFD
        self.port = boundPort
        self.isRunning = true
        lock.unlock()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.receiveLoop(fd: boundFD)
        }
        return true
    }

    public func stop() {
        lock.lock()
        isRunning = false
        let fd = socketFD
        socketFD = -1
        lock.unlock()
        if fd >= 0 {
            Darwin.close(fd)
        }
    }

    private func receiveLoop(fd: Int32) {
        var buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            lock.lock()
            let active = isRunning
            lock.unlock()
            if !active { break }

            let n = Darwin.recv(fd, &buffer, buffer.count, 0)
            if n <= 0 {
                if errno == EINTR { continue }
                break
            }
            let data = Data(buffer[0..<n])
            let messages = OSCCodec.decode(data)
            for msg in messages {
                handler(msg)
            }
        }
    }

    public static func send(_ message: OSCCodec.Message, toHost host: String = "127.0.0.1", port: UInt16 = kSimpleSKPDefaultOSCOutPort) {
        let data = OSCCodec.encode(message)
        let fd = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return }
        defer { Darwin.close(fd) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        guard inet_pton(AF_INET, host, &addr.sin_addr) == 1 else { return }
        _ = data.withUnsafeBytes { ptr in
            withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.sendto(fd, ptr.baseAddress, data.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }
}

/// One parameter descriptor in the OSCQuery namespace served at `/` and `/simpleskp/...` for OSCScore discovery.
public struct OSCQueryParameterSpec: @unchecked Sendable {
    public var path: String
    public var typeTag: String
    public var access: Int
    public var description: String
    public var min: Double?
    public var max: Double?
    public var values: [Any]
    public var unit: [String]?

    public init(
        path: String,
        typeTag: String,
        access: Int = 3,
        description: String,
        min: Double? = nil,
        max: Double? = nil,
        values: [Any] = [],
        unit: [String]? = nil
    ) {
        self.path = path
        self.typeTag = typeTag
        self.access = access
        self.description = description
        self.min = min
        self.max = max
        self.values = values
        self.unit = unit
    }
}

/// Builds OSCQuery JSON responses (`/?HOST_INFO`, `/`, or any `/subpath`) compatible with OSCScore (`_oscjson._tcp.`).
public enum OSCQueryTree {
    public static func hostInfoJSON(name: String = "SimpleSKP", oscPort: UInt16) -> [String: Any] {
        [
            "NAME": name,
            "OSC_PORT": Int(oscPort),
            "OSC_TRANSPORT": "UDP",
            "EXTENSIONS": [
                "ACCESS": true,
                "DESCRIPTION": true,
                "VALUE": true,
                "RANGE": true,
                "UNIT": true,
                "TAGS": false,
                "CLIPMODE": false,
                "CRITICAL": false,
                "LISTEN": false,
                "PATH_CHANGED": false,
            ],
        ]
    }

    public static func rootJSON(parameters: [OSCQueryParameterSpec], description: String = "SimpleSKP 3D Viewer OSC Namespace") -> [String: Any] {
        final class Node {
            var fullPath: String
            var spec: OSCQueryParameterSpec?
            var children: [String: Node] = [:]
            init(fullPath: String) { self.fullPath = fullPath }

            func toDictionary() -> [String: Any] {
                var dict: [String: Any] = ["FULL_PATH": fullPath]
                if let spec {
                    dict["ACCESS"] = spec.access
                    dict["TYPE"] = spec.typeTag
                    dict["DESCRIPTION"] = spec.description
                    if !spec.values.isEmpty {
                        dict["VALUE"] = spec.values
                    }
                    if let lo = spec.min, let hi = spec.max {
                        let count = max(1, spec.typeTag.count)
                        dict["RANGE"] = Array(repeating: ["MIN": lo, "MAX": hi], count: count)
                    }
                    if let unit = spec.unit, !unit.isEmpty {
                        dict["UNIT"] = unit
                    }
                } else {
                    dict["ACCESS"] = 0
                }
                if !children.isEmpty {
                    var contents: [String: Any] = [:]
                    for (k, child) in children {
                        contents[k] = child.toDictionary()
                    }
                    dict["CONTENTS"] = contents
                }
                return dict
            }
        }

        let root = Node(fullPath: "/")
        for param in parameters {
            let comps = param.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            guard !comps.isEmpty else { continue }
            var current = root
            var built = ""
            for comp in comps {
                built += "/" + comp
                if let existing = current.children[comp] {
                    current = existing
                } else {
                    let next = Node(fullPath: built)
                    current.children[comp] = next
                    current = next
                }
            }
            current.spec = param
        }
        var out = root.toDictionary()
        out["DESCRIPTION"] = description
        return out
    }

    public static func nodeJSON(at path: String, in root: [String: Any]) -> [String: Any]? {
        let comps = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        if comps.isEmpty { return root }
        var current = root
        for comp in comps {
            guard let contents = current["CONTENTS"] as? [String: Any],
                  let child = contents[comp] as? [String: Any] else {
                return nil
            }
            current = child
        }
        return current
    }
}
