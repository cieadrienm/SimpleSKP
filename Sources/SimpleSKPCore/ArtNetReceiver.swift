import Foundation
import Darwin

/// Standard Art-Net UDP port (0x1936 = 6454).
public let ArtNetDefaultPort: UInt16 = 6454

/// A parsed Art-Net OpDmx packet containing DMX512 channel data for a specific universe.
public struct ArtNetDMXPacket: Sendable {
    /// 15-bit Art-Net Universe address (`0 ... 32767`, composed of `Net:SubNet:Universe`).
    public let universe: Int
    /// Sub-Net / Universe in the local subnet (`0 ... 15`).
    public var shortUniverse: Int { universe & 0x0F }
    /// Sequence counter (0 = unsequenced, 1...255 = sequential order).
    public let sequence: UInt8
    /// Number of active DMX slots (typically 512).
    public let length: Int
    /// 0-indexed DMX channel values (slot 0 corresponds to DMX Channel 1).
    public let channels: [UInt8]

    public init(universe: Int, sequence: UInt8, channels: [UInt8]) {
        self.universe = universe
        self.sequence = sequence
        self.length = channels.count
        self.channels = channels
    }

    /// Retrieves the 8-bit DMX value (0...255) for 1-based channel `channel` (1...512), or nil if out of bounds.
    public func value(forChannel channel: Int) -> UInt8? {
        guard channel >= 1 && channel <= channels.count else { return nil }
        return channels[channel - 1]
    }

    /// Retrieves the normalized float value (`0.0 ... 1.0`) for 1-based channel `channel` (1...512).
    public func normalized(forChannel channel: Int) -> Float? {
        guard let byte = value(forChannel: channel) else { return nil }
        return Float(byte) / 255.0
    }
}

/// High-performance Art-Net 4 receiver listening on UDP port 6454.
///
/// Uses standard BSD sockets with `SO_REUSEPORT` & `SO_REUSEADDR` so it seamlessly coexists
/// with other lighting tools (e.g. Millumin, GrandMA, QLC+, OSCScore, proxy bridges).
public final class ArtNetReceiver: @unchecked Sendable {
    public static let shared = ArtNetReceiver()

    private let port: UInt16
    private var socketFD: Int32 = -1
    private var dispatchSource: DispatchSourceRead?
    private let queue = DispatchQueue(label: "fr.adrienm.simpleskp.artnet", qos: .userInteractive)

    private let lock = NSLock()
    private var _isListening: Bool = false
    private var _packetCount: UInt64 = 0
    private var _lastPacketDate: Date?
    private var _activeUniverses: Set<Int> = []
    private var _universeChannels: [Int: [UInt8]] = [:]

    /// Optional callback invoked when a valid OpDmx packet arrives.
    public var onDMXPacket: (@Sendable (ArtNetDMXPacket) -> Void)?

    public init(port: UInt16 = ArtNetDefaultPort) {
        self.port = port
    }

    deinit {
        stop()
    }

    public var isListening: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isListening
    }

    public var packetCount: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return _packetCount
    }

    public var lastPacketDate: Date? {
        lock.lock()
        defer { lock.unlock() }
        return _lastPacketDate
    }

    public var activeUniverses: [Int] {
        lock.lock()
        defer { lock.unlock() }
        return _activeUniverses.sorted()
    }

    /// Returns the latest cached DMX channels (0-indexed) for the given universe, or empty array if none received yet.
    public func latestChannels(forUniverse universe: Int) -> [UInt8] {
        lock.lock()
        defer { lock.unlock() }
        return _universeChannels[universe] ?? []
    }

    /// Returns the latest normalized float value (`0.0 ... 1.0`) for a specific universe and 1-based channel.
    public func latestNormalized(universe: Int, channel: Int) -> Float? {
        lock.lock()
        defer { lock.unlock() }
        guard let list = _universeChannels[universe], channel >= 1 && channel <= list.count else { return nil }
        return Float(list[channel - 1]) / 255.0
    }

    /// Starts listening for Art-Net UDP broadcast/unicast packets on port 6454.
    @discardableResult
    public func start() -> Bool {
        lock.lock()
        if _isListening {
            lock.unlock()
            return true
        }
        lock.unlock()

        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else {
            return false
        }

        var reuseOn: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuseOn, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &reuseOn, socklen_t(MemoryLayout<Int32>.size))

        // Non-blocking
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = INADDR_ANY.bigEndian

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.bind(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        guard bindResult == 0 else {
            close(fd)
            return false
        }

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            self?.readPendingPackets()
        }
        source.setCancelHandler {
            close(fd)
        }

        lock.lock()
        self.socketFD = fd
        self.dispatchSource = source
        self._isListening = true
        lock.unlock()

        source.resume()
        return true
    }

    /// Stops listening and releases the UDP port.
    public func stop() {
        lock.lock()
        guard _isListening else {
            lock.unlock()
            return
        }
        _isListening = false
        let source = dispatchSource
        dispatchSource = nil
        socketFD = -1
        lock.unlock()

        source?.cancel()
    }

    // MARK: - Packet Processing

    private func readPendingPackets() {
        var buffer = [UInt8](repeating: 0, count: 2048)

        while true {
            let bytesRead = Darwin.recv(socketFD, &buffer, buffer.count, 0)
            guard bytesRead > 0 else { break }

            guard let packet = Self.parseOpDmx(data: buffer, count: bytesRead) else {
                continue
            }

            lock.lock()
            _packetCount += 1
            _lastPacketDate = Date()
            _activeUniverses.insert(packet.universe)
            _universeChannels[packet.universe] = packet.channels
            let callback = onDMXPacket
            lock.unlock()

            callback?(packet)
        }
    }

    /// Parses an Art-Net packet byte buffer into an `ArtNetDMXPacket` if it matches OpDmx (0x5000).
    public static func parseOpDmx(data: [UInt8], count: Int) -> ArtNetDMXPacket? {
        // Minimum header size: 8 (Art-Net\0) + 2 (OpCode) + 2 (ProtVer) + 1 (Seq) + 1 (Phys) + 2 (SubUni/Net) + 2 (Length) = 18 bytes
        guard count >= 18 else { return nil }

        // 1. Magic header "Art-Net\0"
        guard data[0] == 0x41 && // 'A'
              data[1] == 0x72 && // 'r'
              data[2] == 0x74 && // 't'
              data[3] == 0x2D && // '-'
              data[4] == 0x4E && // 'N'
              data[5] == 0x65 && // 'e'
              data[6] == 0x74 && // 't'
              data[7] == 0x00    // '\0'
        else { return nil }

        // 2. OpCode: 0x5000 (OpDmx / OpOutput) in little-endian (0x00, 0x50)
        let opCode = UInt16(data[8]) | (UInt16(data[9]) << 8)
        guard opCode == 0x5000 else { return nil }

        // 3. Sequence & Physical
        let sequence = data[12]
        // 4. Universe (15 bits): SubUni (byte 14) + Net (byte 15, low 7 bits)
        let subUni = Int(data[14])
        let net = Int(data[15] & 0x7F)
        let universe = subUni | (net << 8)

        // 5. Data length: big-endian 16-bit
        let length = (Int(data[16]) << 8) | Int(data[17])
        guard length >= 2 && length <= 512 else { return nil }
        guard count >= 18 + length else { return nil }

        let channels = Array(data[18..<(18 + length)])
        return ArtNetDMXPacket(universe: universe, sequence: sequence, channels: channels)
    }

    /// Helper to construct a standard Art-Net OpDmx packet for testing or sending.
    public static func buildOpDmxPacket(universe: Int, sequence: UInt8 = 0, channels: [UInt8]) -> [UInt8] {
        var packet = [UInt8]()
        packet.reserveCapacity(18 + channels.count)

        // Magic "Art-Net\0"
        packet.append(contentsOf: [0x41, 0x72, 0x74, 0x2D, 0x4E, 0x65, 0x74, 0x00])
        // OpCode 0x5000 (little endian)
        packet.append(0x00)
        packet.append(0x50)
        // Protocol version 14 (big endian)
        packet.append(0x00)
        packet.append(0x0E)
        // Sequence
        packet.append(sequence)
        // Physical
        packet.append(0x00)
        // SubUni (universe & 0xFF)
        packet.append(UInt8(universe & 0xFF))
        // Net ((universe >> 8) & 0x7F)
        packet.append(UInt8((universe >> 8) & 0x7F))
        // Length (big endian, even count)
        let len = channels.count
        packet.append(UInt8((len >> 8) & 0xFF))
        packet.append(UInt8(len & 0xFF))
        // Channels
        packet.append(contentsOf: channels)

        return packet
    }
}
