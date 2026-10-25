import AppKit
import Darwin
import Foundation
import simd
import SimpleSKPCore
import SimpleSKPViewport

/// Thread-safe value box for bridging async `@MainActor` HTTP handlers back to BSD socket threads.
final class LockBox<T>: @unchecked Sendable {
    private var value: T
    private let lock = NSLock()
    init(_ value: T) { self.value = value }
    func get() -> T { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ newValue: T) { lock.lock(); value = newValue; lock.unlock() }
}

/// Manages SimpleSKP's remote control endpoints:
/// - UDP OSC input on `0.0.0.0:9150` (`SIMPLESKP_OSC_IN_PORT`)
/// - UDP OSC feedback output to `127.0.0.1:9151` (`SIMPLESKP_OSC_OUT_PORT`)
/// - TCP HTTP `/v1` API + OSCQuery server on `:17950` (`SIMPLESKP_API_PORT`)
/// - Bonjour advertisement (`_oscjson._tcp.` and `_osc._udp.`) for automatic discovery in `OSCScore`.
@MainActor
final class RemoteControlServer: NSObject, NetServiceDelegate {
    static let shared = RemoteControlServer()

    private(set) var oscServer: OSCUDPServer?
    private(set) var httpPort: UInt16 = kSimpleSKPDefaultHTTPPort
    private var httpListenFD: Int32 = -1
    private var oscQueryNetService: NetService?
    private var oscUDPNetService: NetService?
    private var bonjourRenameAttempted = false
    private var isApplyingRemoteOSC = false
    private var lastFeedbackTime: CFAbsoluteTime = 0

    /// Optional explicit document model for unit tests or headless invocations.
    weak var overrideModel: DocumentModel?

    var oscInPort: UInt16 {
        oscServer?.port ?? kSimpleSKPDefaultOSCInPort
    }

    var isOSCListening: Bool {
        oscServer?.isRunning ?? false
    }

    var isHTTPListening: Bool {
        httpListenFD >= 0
    }

    /// Resolves the active `DocumentModel` (override for tests, else frontmost document window, else first open document).
    var activeModel: DocumentModel? {
        if let overrideModel {
            attachFeedbackIfNeeded(to: overrideModel)
            return overrideModel
        }
        if let current = NSDocumentController.shared.currentDocument as? SKPDocument {
            attachFeedbackIfNeeded(to: current.model)
            return current.model
        }
        if let first = NSDocumentController.shared.documents.compactMap({ $0 as? SKPDocument }).first {
            attachFeedbackIfNeeded(to: first.model)
            return first.model
        }
        return nil
    }

    func attachFeedbackIfNeeded(to model: DocumentModel) {
        if model.onCameraFeedback == nil {
            model.onCameraFeedback = { [weak self] changedModel in
                self?.sendCameraFeedbackIfNeeded(from: changedModel)
            }
        }
    }

    // MARK: - Lifecycle

    func start(
        oscPort: UInt16? = nil,
        httpPort: UInt16? = nil,
        publishBonjour: Bool = true
    ) {
        let envOSC = ProcessInfo.processInfo.environment["SIMPLESKP_OSC_IN_PORT"].flatMap(UInt16.init)
        let targetOSC = oscPort ?? envOSC ?? kSimpleSKPDefaultOSCInPort
        startOSCServer(port: targetOSC)

        let envHTTP = ProcessInfo.processInfo.environment["SIMPLESKP_API_PORT"].flatMap(UInt16.init)
        let targetHTTP = httpPort ?? envHTTP ?? kSimpleSKPDefaultHTTPPort
        startHTTPServer(port: targetHTTP)

        if publishBonjour {
            publishBonjourServices()
        }
    }

    func stop() {
        oscServer?.stop()
        oscServer = nil
        stopHTTPServer()
        oscQueryNetService?.stop()
        oscQueryNetService = nil
        oscUDPNetService?.stop()
        oscUDPNetService = nil
    }

    func startOSCServer(port: UInt16 = kSimpleSKPDefaultOSCInPort) {
        oscServer?.stop()
        let srv = OSCUDPServer(port: port) { [weak self] msg in
            Task { @MainActor [weak self] in
                self?.handleOSCMessage(msg)
            }
        }
        _ = srv.start()
        self.oscServer = srv
    }

    func startHTTPServer(port: UInt16 = kSimpleSKPDefaultHTTPPort, maxAttempts: Int = 16) {
        stopHTTPServer()
        let attempts = port == 0 ? 1 : max(1, maxAttempts)
        var boundFD: Int32 = -1
        var boundPort: UInt16 = 0

        for offset in 0..<attempts {
            let candidate: UInt16
            if port == 0 {
                candidate = 0
            } else {
                let next = Int(port) + offset
                guard next <= 65535 else { break }
                candidate = UInt16(next)
            }

            let fd = Darwin.socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
            guard fd >= 0 else { return }
            var yes: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))

            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = candidate.bigEndian
            // Bind INADDR_ANY so both 127.0.0.1 (MCP) and Bonjour .local (OSCScore) can connect.
            addr.sin_addr.s_addr = INADDR_ANY

            let bindRes = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            if bindRes == 0 && Darwin.listen(fd, 32) == 0 {
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

        guard boundFD >= 0 else { return }
        self.httpListenFD = boundFD
        self.httpPort = boundPort

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            while true {
                var caddr = sockaddr_in()
                var clen = socklen_t(MemoryLayout<sockaddr_in>.size)
                let cfd = withUnsafeMutablePointer(to: &caddr) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        Darwin.accept(boundFD, $0, &clen)
                    }
                }
                if cfd < 0 { break }
                var one: Int32 = 1
                setsockopt(cfd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
                setsockopt(cfd, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
                var timeout = timeval(tv_sec: 5, tv_usec: 0)
                setsockopt(cfd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
                setsockopt(cfd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    self?.handleHTTPConnection(cfd)
                }
            }
        }
    }

    func stopHTTPServer() {
        if httpListenFD >= 0 {
            Darwin.shutdown(httpListenFD, SHUT_RDWR)
            Darwin.close(httpListenFD)
            httpListenFD = -1
        }
    }

    // MARK: - Bonjour (`_oscjson._tcp.` & `_osc._udp.`)

    func publishBonjourServices(serviceName: String = "SimpleSKP") {
        oscQueryNetService?.stop()
        oscUDPNetService?.stop()
        bonjourRenameAttempted = false

        if httpListenFD >= 0, httpPort > 0 {
            let oscQuery = NetService(domain: "", type: "_oscjson._tcp.", name: serviceName, port: Int32(httpPort))
            oscQuery.delegate = self
            oscQuery.publish()
            self.oscQueryNetService = oscQuery
        }

        if let osc = oscServer, osc.isRunning, osc.port > 0 {
            let oscUDP = NetService(domain: "", type: "_osc._udp.", name: serviceName, port: Int32(osc.port))
            oscUDP.delegate = self
            oscUDP.publish()
            self.oscUDPNetService = oscUDP
        }
    }

    nonisolated func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
        let code = errorDict[NetService.errorCode]?.intValue ?? 0
        Task { @MainActor [weak self] in
            guard let self else { return }
            if code == NetService.ErrorCode.collisionError.rawValue && !self.bonjourRenameAttempted {
                self.bonjourRenameAttempted = true
                self.publishBonjourServices(serviceName: "SimpleSKP \(self.httpPort)")
            }
        }
    }

    // MARK: - OSC Feedback (`127.0.0.1:9151`)

    func sendCameraFeedbackIfNeeded(from model: DocumentModel) {
        guard !isApplyingRemoteOSC, Preferences.oscFeedbackEnabled else { return }
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastFeedbackTime >= (1.0 / 60.0) else { return }
        lastFeedbackTime = now

        let host = Preferences.oscOutHost
        let port = Preferences.oscOutPort
        let pos = model.cameraPosition
        let tgt = model.cameraTarget
        let yaw = model.cameraYawDegrees
        let pitch = model.cameraPitchDegrees

        OSCUDPServer.send(
            OSCCodec.Message(address: "/simpleskp/camera/position", arguments: [.float(pos.x), .float(pos.y), .float(pos.z)]),
            toHost: host,
            port: port
        )
        OSCUDPServer.send(
            OSCCodec.Message(address: "/simpleskp/camera/target", arguments: [.float(tgt.x), .float(tgt.y), .float(tgt.z)]),
            toHost: host,
            port: port
        )
        OSCUDPServer.send(
            OSCCodec.Message(address: "/simpleskp/camera/orientation", arguments: [.float(yaw), .float(pitch)]),
            toHost: host,
            port: port
        )
        OSCUDPServer.send(
            OSCCodec.Message(address: "/simpleskp/camera/fov", arguments: [.float(model.cameraFOV)]),
            toHost: host,
            port: port
        )
    }

    // MARK: - OSC Incoming Message Routing

    func handleOSCMessage(_ message: OSCCodec.Message) {
        let rawParts = message.address
            .lowercased()
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        guard !rawParts.isEmpty else { return }

        // Accept both `/simpleskp/camera/fov` and `/camera/fov`
        let route = rawParts.first == "simpleskp" ? Array(rawParts.dropFirst()) : rawParts
        guard let head = route.first else { return }

        if head == "open", let pathStr = message.string(at: 0), !pathStr.isEmpty {
            let url = URL(fileURLWithPath: (pathStr as NSString).expandingTildeInPath)
            NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, _ in }
            return
        }

        guard let model = activeModel else { return }
        attachFeedbackIfNeeded(to: model)

        isApplyingRemoteOSC = true
        defer { isApplyingRemoteOSC = false }

        switch head {
        case "camera":
            handleCameraOSC(route: Array(route.dropFirst()), message: message, model: model)

        case "scene":
            let sub = route.count > 1 ? route[1] : "index"
            switch sub {
            case "next":
                model.nextScene()
            case "prev", "previous":
                model.previousScene()
            case "name":
                if let name = message.string(at: 0),
                   let idx = model.skp?.scenes.firstIndex(where: { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) {
                    model.selectScene(idx)
                }
            default:
                if let idx = message.int(at: 0) {
                    model.selectScene(idx)
                } else if let name = message.string(at: 0),
                          let idx = model.skp?.scenes.firstIndex(where: { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) {
                    model.selectScene(idx)
                }
            }

        case "layer":
            guard route.count >= 2 else { return }
            if route[1] == "all", let b = message.bool(at: 0) {
                model.setAllLayers(visible: b)
            } else if route[1] == "solo" {
                if let idx = message.int(at: 0) {
                    model.soloLayer(idx)
                } else if let name = message.string(at: 0),
                          let idx = model.skp?.layers.firstIndex(where: { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) {
                    model.soloLayer(idx)
                }
            } else if let idx = Int(route[1]), model.layerVisible.indices.contains(idx) {
                if let b = message.bool(at: 0) {
                    if model.layerVisible[idx] != b {
                        model.toggleLayer(idx)
                    }
                } else {
                    model.toggleLayer(idx)
                }
            }

        case "style":
            if let s = message.string(at: 0)?.lowercased() {
                switch s {
                case "textured", "pbr": model.setShadingStyle(.textured)
                case "clay", "blanc", "white": model.setShadingStyle(.clay)
                case "xray", "x-ray": model.setShadingStyle(.xray)
                case "wireframe", "wire", "filaire": model.setShadingStyle(.wireframe)
                default: break
                }
            }

        case "edges":
            if let b = message.bool(at: 0) {
                if model.showsEdges != b { model.toggleEdges() }
            } else {
                model.toggleEdges()
            }

        case "grid":
            if let b = message.bool(at: 0) {
                if model.showsGrid != b { model.toggleGrid() }
            } else {
                model.toggleGrid()
            }

        case "shadows":
            if let b = message.bool(at: 0) {
                if model.shadowsEnabled != b { model.toggleShadows() }
            } else {
                model.toggleShadows()
            }

        case "ssao":
            if let v = message.float(at: 0) {
                model.setAmbientOcclusionIntensity(v)
            }

        case "lighting", "ambient":
            if head == "ambient", let amb = message.float(at: 0) {
                model.setAmbientIntensity(amb)
                break
            }
            let sub = route.count > 1 ? route[1] : "mode"
            if sub == "ambient", let amb = message.float(at: 0) {
                model.setAmbientIntensity(amb)
            } else if sub == "mode", let s = message.string(at: 0)?.lowercased() {
                if s == "point" || s == "omni" || s == "ponctuel" {
                    model.setLightingMode(.point)
                } else if s == "sun" || s == "soleil" {
                    model.setLightingMode(.sun)
                }
            }

        case "sun":
            let sub = route.count > 1 ? route[1] : "angles"
            switch sub {
            case "azimuth":
                if let az = message.float(at: 0) {
                    model.setSun(azimuth: max(-180, min(180, az)), elevation: model.sunElevationDegrees)
                }
            case "elevation":
                if let el = message.float(at: 0) {
                    model.setSun(azimuth: model.sunAzimuthDegrees, elevation: max(8, min(85, el)))
                }
            case "intensity", "power":
                if let power = message.float(at: 0) {
                    model.setSunIntensity(power)
                }
            case "angles":
                if let az = message.float(at: 0), let el = message.float(at: 1) {
                    model.setSun(azimuth: max(-180, min(180, az)), elevation: max(8, min(85, el)))
                }
            case "reset":
                model.resetSun()
            default:
                break
            }

        case "light":
            if model.lightingMode != .point {
                model.setLightingMode(.point)
            }
            let sub = route.count > 1 ? route[1] : "intensity"
            let currentPos = model.selectedPointLight?.position ?? .zero
            switch sub {
            case "position":
                if let x = message.float(at: 0), let y = message.float(at: 1), let z = message.float(at: 2) {
                    model.updateSelectedPointLight(position: SIMD3<Float>(x, y, z))
                }
            case "x":
                if let x = message.float(at: 0) {
                    model.updateSelectedPointLight(position: SIMD3<Float>(x, currentPos.y, currentPos.z))
                }
            case "y":
                if let y = message.float(at: 0) {
                    model.updateSelectedPointLight(position: SIMD3<Float>(currentPos.x, y, currentPos.z))
                }
            case "z":
                if let z = message.float(at: 0) {
                    model.updateSelectedPointLight(position: SIMD3<Float>(currentPos.x, currentPos.y, z))
                }
            case "intensity":
                if let intensity = message.float(at: 0) {
                    model.updateSelectedPointLight(intensity: intensity)
                }
            case "gizmo":
                if let b = message.bool(at: 0) {
                    if model.showsPointLightGizmo != b { model.togglePointLightGizmo() }
                } else {
                    model.togglePointLightGizmo()
                }
            case "center":
                model.centerSelectedPointLight()
            case "to_camera", "camera":
                model.moveSelectedPointLightToCamera()
            default:
                break
            }

        case "backdrop":
            let sub = route.count > 1 ? route[1] : "style"
            switch sub {
            case "style":
                if let s = message.string(at: 0) {
                    if let style = BackdropStyle.allCases.first(where: { $0.rawValue.lowercased() == s.lowercased() }) {
                        model.setBackdropStyle(style)
                    } else if s.lowercased() == "sky" {
                        model.setBackdropStyle(.architecturalSky)
                    } else if s.lowercased() == "dark" || s.lowercased() == "studio" {
                        model.setBackdropStyle(.studioDark)
                    } else if s.lowercased() == "paper" {
                        model.setBackdropStyle(.warmPaper)
                    }
                }
            case "color":
                if let r = message.float(at: 0), let g = message.float(at: 1), let b = message.float(at: 2) {
                    model.setCustomBackdropColor(SIMD3<Float>(r, g, b))
                }
            default:
                break
            }

        default:
            break
        }
    }

    private func handleCameraOSC(route: [String], message: OSCCodec.Message, model: DocumentModel) {
        let sub = route.first ?? "position"
        let currentPos = model.cameraPosition
        switch sub {
        case "position", "pos":
            if let x = message.float(at: 0), let y = message.float(at: 1), let z = message.float(at: 2) {
                model.setCameraPosition(SIMD3<Float>(x, y, z))
            }
        case "x":
            if let x = message.float(at: 0) {
                model.setCameraPosition(SIMD3<Float>(x, currentPos.y, currentPos.z))
            }
        case "y":
            if let y = message.float(at: 0) {
                model.setCameraPosition(SIMD3<Float>(currentPos.x, y, currentPos.z))
            }
        case "z":
            if let z = message.float(at: 0) {
                model.setCameraPosition(SIMD3<Float>(currentPos.x, currentPos.y, z))
            }
        case "target":
            if let tx = message.float(at: 0), let ty = message.float(at: 1), let tz = message.float(at: 2) {
                model.setCameraTarget(SIMD3<Float>(tx, ty, tz))
            }
        case "lookat":
            if let x = message.float(at: 0), let y = message.float(at: 1), let z = message.float(at: 2),
               let tx = message.float(at: 3), let ty = message.float(at: 4), let tz = message.float(at: 5) {
                model.setCameraLookAt(position: SIMD3<Float>(x, y, z), target: SIMD3<Float>(tx, ty, tz))
            }
        case "orientation", "angles":
            if let yaw = message.float(at: 0), let pitch = message.float(at: 1) {
                model.setCameraOrientation(yawDegrees: yaw, pitchDegrees: pitch)
            }
        case "yaw", "azimuth":
            if let yaw = message.float(at: 0) {
                model.setCameraOrientation(yawDegrees: yaw)
            }
        case "pitch", "elevation", "tilt":
            if let pitch = message.float(at: 0) {
                model.setCameraOrientation(pitchDegrees: pitch)
            }
        case "distance", "dist":
            if let d = message.float(at: 0) {
                model.setCameraDistance(d)
            }
        case "orbit":
            let dYaw = message.float(at: 0) ?? 0
            let dPitch = message.float(at: 1) ?? 0
            model.orbitCameraByDegrees(yaw: dYaw, pitch: dPitch)
        case "fov":
            if let fov = message.float(at: 0) {
                model.setCameraFOV(fov)
            }
        case "focal":
            if let mm = message.float(at: 0) {
                model.setCameraFocalLength(mm)
            }
        case "exposure":
            if let ev = message.float(at: 0) {
                model.setCameraExposure(ev)
            }
        case "ortho_scale", "orthoscale":
            if let s = message.float(at: 0) {
                model.setCameraOrthoScale(s)
            }
        case "perspective":
            if let b = message.bool(at: 0) {
                model.setPerspective(b)
            } else {
                model.togglePerspective()
            }
        case "speed":
            if let s = message.float(at: 0) {
                model.setCameraSpeedScale(s)
            }
        case "view":
            if let s = message.string(at: 0)?.lowercased() {
                switch s {
                case "iso": model.look(.iso)
                case "top", "dessus": model.look(.top)
                case "bottom", "dessous": model.look(.bottom)
                case "front", "face": model.look(.front)
                case "back", "arriere", "arrière": model.look(.back)
                case "left", "gauche": model.look(.left)
                case "right", "droite": model.look(.right)
                default: break
                }
            }
        case "eye_height", "eyeheight":
            let h = message.float(at: 0) ?? 1.70
            model.setCameraEyeHeight(h)
        case "center":
            model.centerCameraInModel()
        case "level":
            model.levelCameraHorizon(animated: false)
        case "reset":
            model.resetView()
        case "zoom_extents", "zoomextents", "frame":
            model.zoomExtents()
        default:
            break
        }
    }

    // MARK: - OSCQuery Parameter Tree for OSCScore

    func oscQueryParameters() -> [OSCQueryParameterSpec] {
        let model = activeModel
        let posRange = model?.cameraCoordinateRange ?? (-100.0...100.0)
        let distRange = model?.cameraDistanceRange ?? (0.1...200.0)
        let pos = model?.cameraPosition ?? .zero
        let tgt = model?.cameraTarget ?? SIMD3<Float>(0, 1, 0)
        let yaw = Double(model?.cameraYawDegrees ?? 0)
        let pitch = Double(model?.cameraPitchDegrees ?? 0)
        let dist = Double(model?.cameraDistance ?? 10)
        let fov = Double(model?.cameraFOV ?? 35)
        let focal = Double(model?.cameraFocalLengthMM ?? 38)
        let exposure = Double(model?.cameraExposure ?? -0.62)
        let ortho = Double(model?.cameraOrthoScale ?? 5)
        let persp = (model?.isPerspective ?? true) ? 1 : 0
        let speed = Double(model?.cameraSpeedScale ?? 1)
        let sunAz = Double(model?.sunAzimuthDegrees ?? -135)
        let sunEl = Double(model?.sunElevationDegrees ?? 45)
        let sunInt = Double(model?.sunIntensity ?? 1.0)
        let ambientInt = Double(model?.ambientIntensity ?? 1.0)
        let ssao = Double(model?.ambientOcclusionEnabled == true ? (model?.ambientOcclusionIntensity ?? 0.7) : 0.0)
        let lightPos = model?.selectedPointLight?.position ?? .zero
        let lightIntensity = Double(model?.selectedPointLight?.intensity ?? 1.0)
        let bg = model?.customBackdropColor ?? Rendering.defaultCustomBackdropColor
        let sceneCount = max(1, model?.skp?.scenes.count ?? 1)

        return [
            // Camera 3D / 2D vector tracks for OSCScore
            OSCQueryParameterSpec(
                path: "/simpleskp/camera/position",
                typeTag: "fff",
                description: "Position 3D de la caméra (X, Y, Z en mètres)",
                min: posRange.lowerBound,
                max: posRange.upperBound,
                values: [Double(pos.x), Double(pos.y), Double(pos.z)]
            ),
            OSCQueryParameterSpec(
                path: "/simpleskp/camera/target",
                typeTag: "fff",
                description: "Point visé 3D par la caméra (X, Y, Z en mètres)",
                min: posRange.lowerBound,
                max: posRange.upperBound,
                values: [Double(tgt.x), Double(tgt.y), Double(tgt.z)]
            ),
            OSCQueryParameterSpec(
                path: "/simpleskp/camera/orientation",
                typeTag: "ff",
                description: "Orientation caméra : Azimut/Lacet (-180..180°) et Inclinaison/Tangage (-89..89°)",
                min: -180.0,
                max: 180.0,
                values: [yaw, pitch]
            ),
            OSCQueryParameterSpec(
                path: "/simpleskp/camera/lookat",
                typeTag: "ffffff",
                description: "Position caméra (X,Y,Z) et point visé (TX,TY,TZ) simultanés en mètres",
                min: posRange.lowerBound,
                max: posRange.upperBound,
                values: [Double(pos.x), Double(pos.y), Double(pos.z), Double(tgt.x), Double(tgt.y), Double(tgt.z)]
            ),
            // Camera individual scalar tracks for OSCScore
            OSCQueryParameterSpec(
                path: "/simpleskp/camera/x",
                typeTag: "f",
                description: "Position caméra X (mètres)",
                min: posRange.lowerBound,
                max: posRange.upperBound,
                values: [Double(pos.x)]
            ),
            OSCQueryParameterSpec(
                path: "/simpleskp/camera/y",
                typeTag: "f",
                description: "Position caméra Y (mètres)",
                min: posRange.lowerBound,
                max: posRange.upperBound,
                values: [Double(pos.y)]
            ),
            OSCQueryParameterSpec(
                path: "/simpleskp/camera/z",
                typeTag: "f",
                description: "Position caméra Z / hauteur (mètres)",
                min: posRange.lowerBound,
                max: posRange.upperBound,
                values: [Double(pos.z)]
            ),
            OSCQueryParameterSpec(
                path: "/simpleskp/camera/yaw",
                typeTag: "f",
                description: "Azimut / Lacet caméra en degrés (-180..180°)",
                min: -180.0,
                max: 180.0,
                values: [yaw]
            ),
            OSCQueryParameterSpec(
                path: "/simpleskp/camera/pitch",
                typeTag: "f",
                description: "Inclinaison / Tangage caméra en degrés (-89..89°)",
                min: -89.0,
                max: 89.0,
                values: [pitch]
            ),
            OSCQueryParameterSpec(
                path: "/simpleskp/camera/distance",
                typeTag: "f",
                description: "Distance de la caméra à la cible d'orbite (mètres)",
                min: distRange.lowerBound,
                max: distRange.upperBound,
                values: [dist]
            ),
            OSCQueryParameterSpec(
                path: "/simpleskp/camera/fov",
                typeTag: "f",
                description: "Angle d'ouverture vertical de la caméra (FOV 10..120°)",
                min: 10.0,
                max: 120.0,
                values: [fov]
            ),
            OSCQueryParameterSpec(
                path: "/simpleskp/camera/focal",
                typeTag: "f",
                description: "Focale équivalente 24x36 de la caméra (5..135 mm)",
                min: 5.0,
                max: 135.0,
                values: [focal]
            ),
            OSCQueryParameterSpec(
                path: "/simpleskp/camera/exposure",
                typeTag: "f",
                description: "Exposition HDR de la caméra (-3..+3 EV)",
                min: -3.0,
                max: 3.0,
                values: [exposure]
            ),
            OSCQueryParameterSpec(
                path: "/simpleskp/camera/ortho_scale",
                typeTag: "f",
                description: "Demi-hauteur orthographique en projection parallèle (mètres)",
                min: 0.1,
                max: distRange.upperBound,
                values: [ortho]
            ),
            OSCQueryParameterSpec(
                path: "/simpleskp/camera/perspective",
                typeTag: "i",
                description: "Projection perspective (1) ou parallèle (0)",
                min: 0,
                max: 1,
                values: [persp]
            ),
            OSCQueryParameterSpec(
                path: "/simpleskp/camera/speed",
                typeTag: "f",
                description: "Multiplicateur de vitesse de déplacement caméra (0.1..16)",
                min: 0.1,
                max: 16.0,
                values: [speed]
            ),
            OSCQueryParameterSpec(
                path: "/simpleskp/camera/view",
                typeTag: "s",
                description: "Vue standard (iso, top, bottom, front, back, left, right)",
                values: [model?.activeStandardView.map { "\($0)" } ?? "iso"]
            ),
            OSCQueryParameterSpec(
                path: "/simpleskp/camera/eye_height",
                typeTag: "f",
                description: "Place la caméra à hauteur d'oeil au-dessus du sol (défaut 1.70 m) et met l'horizon droit",
                min: 0.2,
                max: 10.0,
                values: [1.70]
            ),
            OSCQueryParameterSpec(
                path: "/simpleskp/camera/level",
                typeTag: "I",
                access: 2,
                description: "Remet l'horizon de la caméra à plat (tangage 0°)"
            ),
            OSCQueryParameterSpec(
                path: "/simpleskp/camera/reset",
                typeTag: "I",
                access: 2,
                description: "Réinitialise la caméra à la vue initiale du fichier (Z)"
            ),
            OSCQueryParameterSpec(
                path: "/simpleskp/camera/zoom_extents",
                typeTag: "I",
                access: 2,
                description: "Cadre l'ensemble du modèle visible (Zoom étendu ⇧Z)"
            ),
            // Scenes
            OSCQueryParameterSpec(
                path: "/simpleskp/scene/index",
                typeTag: "i",
                description: "Indice de la scène SketchUp active (0..N-1)",
                min: 0,
                max: Double(max(0, sceneCount - 1)),
                values: [model?.selectedScene ?? 0]
            ),
            OSCQueryParameterSpec(
                path: "/simpleskp/scene/name",
                typeTag: "s",
                description: "Nom de la scène SketchUp à activer",
                values: [
                    model.flatMap { m in
                        m.selectedScene.flatMap { idx in m.skp?.scenes.indices.contains(idx) == true ? m.skp?.scenes[idx].name : nil }
                    } ?? ""
                ]
            ),
            OSCQueryParameterSpec(
                path: "/simpleskp/scene/next",
                typeTag: "I",
                access: 2,
                description: "Passe à la scène suivante (⌘])"
            ),
            OSCQueryParameterSpec(
                path: "/simpleskp/scene/prev",
                typeTag: "I",
                access: 2,
                description: "Passe à la scène précédente (⌘[)"
            ),
            // Rendering & Lighting
            OSCQueryParameterSpec(
                path: "/simpleskp/style",
                typeTag: "s",
                description: "Style de rendu (textured, clay, xray, wireframe)",
                values: [model?.shadingStyle.rawValue ?? ShadingStyle.textured.rawValue]
            ),
            OSCQueryParameterSpec(
                path: "/simpleskp/edges",
                typeTag: "i",
                description: "Afficher les arêtes (0 ou 1)",
                min: 0,
                max: 1,
                values: [(model?.showsEdges ?? true) ? 1 : 0]
            ),
            OSCQueryParameterSpec(
                path: "/simpleskp/grid",
                typeTag: "i",
                description: "Afficher la grille et les axes XYZ (0 ou 1)",
                min: 0,
                max: 1,
                values: [(model?.showsGrid ?? false) ? 1 : 0]
            ),
            OSCQueryParameterSpec(
                path: "/simpleskp/shadows",
                typeTag: "i",
                description: "Activer les ombres portées du soleil (0 ou 1)",
                min: 0,
                max: 1,
                values: [(model?.shadowsEnabled ?? true) ? 1 : 0]
            ),
            OSCQueryParameterSpec(
                path: "/simpleskp/ssao",
                typeTag: "f",
                description: "Importance de l'occlusion ambiante SSAO (0.0..2.0)",
                min: 0.0,
                max: 2.0,
                values: [ssao]
            ),
            OSCQueryParameterSpec(
                path: "/simpleskp/lighting/mode",
                typeTag: "s",
                description: "Mode d'éclairage (sun ou point)",
                values: [model?.lightingMode.rawValue ?? LightingMode.sun.rawValue]
            ),
            OSCQueryParameterSpec(
                path: "/simpleskp/lighting/ambient",
                typeTag: "f",
                description: "Puissance de la lumière ambiante (0.0..2.0, 0 = noir complet quand les lumières sont à 0%)",
                min: 0.0,
                max: 2.0,
                values: [ambientInt]
            ),
            OSCQueryParameterSpec(
                path: "/simpleskp/sun/angles",
                typeTag: "ff",
                description: "Orientation du soleil : Azimut (-180..180°) et Hauteur (8..85°)",
                min: -180.0,
                max: 180.0,
                values: [sunAz, sunEl]
            ),
            OSCQueryParameterSpec(
                path: "/simpleskp/sun/azimuth",
                typeTag: "f",
                description: "Azimut du soleil (-180..180°)",
                min: -180.0,
                max: 180.0,
                values: [sunAz]
            ),
            OSCQueryParameterSpec(
                path: "/simpleskp/sun/elevation",
                typeTag: "f",
                description: "Hauteur du soleil (8..85°)",
                min: 8.0,
                max: 85.0,
                values: [sunEl]
            ),
            OSCQueryParameterSpec(
                path: "/simpleskp/sun/intensity",
                typeTag: "f",
                description: "Puissance du soleil (0.0..3.0)",
                min: 0.0,
                max: 3.0,
                values: [sunInt]
            ),
            OSCQueryParameterSpec(
                path: "/simpleskp/light/position",
                typeTag: "fff",
                description: "Position 3D de la lumière ponctuelle active (X, Y, Z en mètres)",
                min: posRange.lowerBound,
                max: posRange.upperBound,
                values: [Double(lightPos.x), Double(lightPos.y), Double(lightPos.z)]
            ),
            OSCQueryParameterSpec(
                path: "/simpleskp/light/x",
                typeTag: "f",
                description: "Coordonnée X de la lumière ponctuelle (mètres)",
                min: posRange.lowerBound,
                max: posRange.upperBound,
                values: [Double(lightPos.x)]
            ),
            OSCQueryParameterSpec(
                path: "/simpleskp/light/y",
                typeTag: "f",
                description: "Coordonnée Y de la lumière ponctuelle (mètres)",
                min: posRange.lowerBound,
                max: posRange.upperBound,
                values: [Double(lightPos.y)]
            ),
            OSCQueryParameterSpec(
                path: "/simpleskp/light/z",
                typeTag: "f",
                description: "Coordonnée Z de la lumière ponctuelle (mètres)",
                min: posRange.lowerBound,
                max: posRange.upperBound,
                values: [Double(lightPos.z)]
            ),
            OSCQueryParameterSpec(
                path: "/simpleskp/light/intensity",
                typeTag: "f",
                description: "Intensité de la lumière ponctuelle (0.0..3.0)",
                min: 0.0,
                max: 3.0,
                values: [lightIntensity]
            ),
            OSCQueryParameterSpec(
                path: "/simpleskp/backdrop/style",
                typeTag: "s",
                description: "Style de fond (architecturalSky, studioDark, warmPaper, customColor)",
                values: [model?.backdropStyle.rawValue ?? BackdropStyle.architecturalSky.rawValue]
            ),
            OSCQueryParameterSpec(
                path: "/simpleskp/backdrop/color",
                typeTag: "ffff",
                description: "Couleur personnalisée du fond (R, G, B, A entre 0 et 1)",
                min: 0.0,
                max: 1.0,
                values: [Double(bg.x), Double(bg.y), Double(bg.z), 1.0],
                unit: ["color.rgba"]
            ),
        ]
    }

    // MARK: - HTTP Connection Handling (`/v1` + OSCQuery)

    nonisolated private func handleHTTPConnection(_ fd: Int32) {
        defer { Darwin.close(fd) }
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 8192)
        var headerEndIndex: Int?
        var expectedContentLength = 0

        while true {
            let n = Darwin.recv(fd, &chunk, chunk.count, 0)
            if n <= 0 { break }
            buffer.append(contentsOf: chunk[0..<n])

            if headerEndIndex == nil, let range = buffer.range(of: Data("\r\n\r\n".utf8)) {
                headerEndIndex = range.upperBound
                let headerStr = String(decoding: buffer[..<range.lowerBound], as: UTF8.self)
                for line in headerStr.split(separator: "\r\n").dropFirst() {
                    let parts = line.split(separator: ":", maxSplits: 1)
                    if parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "content-length" {
                        expectedContentLength = Int(parts[1].trimmingCharacters(in: .whitespaces)) ?? 0
                    }
                }
            }
            if let end = headerEndIndex, buffer.count >= end + expectedContentLength {
                break
            }
            if buffer.count > 4 * 1024 * 1024 { return }
        }

        guard let end = headerEndIndex else { return }
        let headerString = String(decoding: buffer[..<(end - 4)], as: UTF8.self)
        let firstLine = headerString.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let tokens = firstLine.split(separator: " ").map(String.init)
        guard tokens.count >= 2 else { return }
        let method = tokens[0].uppercased()
        let rawTarget = tokens[1]
        let pathParts = rawTarget.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let rawPath = String(pathParts.first ?? "/")
        let path = rawPath.removingPercentEncoding ?? rawPath
        let query = pathParts.count > 1 ? String(pathParts[1]) : ""

        let bodyEnd = min(buffer.count, end + expectedContentLength)
        let bodyData = end < bodyEnd ? Data(buffer[end..<bodyEnd]) : Data()
        let jsonArgs = ((try? JSONSerialization.jsonObject(with: bodyData)) as? [String: Any]) ?? [:]

        let sem = DispatchSemaphore(value: 0)
        let box = LockBox<Data>(Data("{\"ok\":true}".utf8))
        let statusBox = LockBox<Int>(200)
        let contentTypeBox = LockBox<String>("application/json; charset=utf-8")

        Task { @MainActor [weak self] in
            defer { sem.signal() }
            guard let self else { return }
            await self.dispatchHTTPRequest(
                method: method,
                path: path.isEmpty ? "/" : path,
                query: query,
                args: jsonArgs,
                box: box,
                statusBox: statusBox,
                contentTypeBox: contentTypeBox
            )
        }
        _ = sem.wait(timeout: .now() + 15.0)

        let body = method == "HEAD" ? Data() : box.get()
        let code = statusBox.get()
        let ctype = contentTypeBox.get()
        let reason: String = switch code {
        case 200: "OK"
        case 204: "No Content"
        case 400: "Bad Request"
        case 404: "Not Found"
        default: "Error"
        }
        let header = "HTTP/1.1 \(code) \(reason)\r\nContent-Type: \(ctype)\r\nAccess-Control-Allow-Origin: *\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        var response = Data(header.utf8)
        response.append(body)
        response.withUnsafeBytes { ptr in
            guard let base = ptr.baseAddress else { return }
            var sent = 0
            while sent < response.count {
                let w = Darwin.send(fd, base.advanced(by: sent), response.count - sent, 0)
                if w <= 0 { break }
                sent += w
            }
        }
    }

    private func dispatchHTTPRequest(
        method: String,
        path: String,
        query: String,
        args: [String: Any],
        box: LockBox<Data>,
        statusBox: LockBox<Int>,
        contentTypeBox: LockBox<String>
    ) async {
        func writeJSON(_ dict: [String: Any]) {
            if let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) {
                box.set(data)
            }
        }

        // 1. OSCQuery `HOST_INFO` query (on `/` or any path)
        let attrQuery = query.split(separator: "&").first.flatMap { $0.split(separator: "=").first }.map(String.init) ?? ""
        if (method == "GET" || method == "HEAD") && attrQuery == "HOST_INFO" {
            writeJSON(OSCQueryTree.hostInfoJSON(name: "SimpleSKP", oscPort: oscInPort))
            return
        }

        // 2. OSCQuery namespace requests (`GET /` or `GET /simpleskp/...`)
        if (method == "GET" || method == "HEAD") && (path == "/" || path.hasPrefix("/simpleskp")) {
            let root = OSCQueryTree.rootJSON(parameters: oscQueryParameters())
            guard let node = OSCQueryTree.nodeJSON(at: path, in: root) else {
                statusBox.set(404)
                writeJSON(["error": "OSCQuery path not found", "path": path])
                return
            }
            if attrQuery.isEmpty {
                writeJSON(node)
                return
            }
            if let val = node[attrQuery] {
                writeJSON([attrQuery: val])
            } else {
                statusBox.set(204)
                box.set(Data())
            }
            return
        }

        // 3. `/v1` REST API for MCP and CLI automation
        switch (method, path) {
        case ("GET", "/v1/state"), ("GET", "/v1/status"):
            writeJSON(buildStateDictionary())

        case ("GET", "/v1/help"):
            writeJSON(buildHelpDictionary())

        case ("GET", "/v1/camera"):
            writeJSON(buildCameraDictionary(model: activeModel))

        case ("POST", "/v1/camera"):
            guard let model = activeModel else {
                statusBox.set(400)
                writeJSON(["error": "No .skp document is currently open in SimpleSKP"])
                return
            }
            applyCameraJSON(args, to: model)
            writeJSON([
                "ok": true,
                "camera": buildCameraDictionary(model: model),
            ])

        case ("POST", "/v1/open"):
            guard let rawPath = args["path"] as? String, !rawPath.isEmpty else {
                statusBox.set(400)
                writeJSON(["error": "Missing 'path' parameter"])
                return
            }
            let url = URL(fileURLWithPath: (rawPath as NSString).expandingTildeInPath)
            guard FileManager.default.fileExists(atPath: url.path) else {
                statusBox.set(400)
                writeJSON(["error": "File does not exist: \(url.path)"])
                return
            }
            let openedModel = await openDocumentAndWaitUntilReady(url: url)
            if let openedModel, openedModel.isReady {
                writeJSON([
                    "ok": true,
                    "path": url.path,
                    "state": buildStateDictionary(for: openedModel),
                ])
            } else {
                statusBox.set(500)
                writeJSON([
                    "ok": false,
                    "path": url.path,
                    "error": openedModel?.error?.localizedDescription ?? "Failed or timed out loading .skp file",
                ])
            }

        case ("POST", "/v1/scene"):
            guard let model = activeModel else {
                statusBox.set(400)
                writeJSON(["error": "No .skp document is currently open"])
                return
            }
            if let action = (args["action"] as? String)?.lowercased() {
                if action == "next" { model.nextScene() }
                else if action == "prev" || action == "previous" { model.previousScene() }
            } else if let idx = (args["index"] as? Int) ?? (args["index"] as? Double).map(Int.init) {
                model.selectScene(idx)
            } else if let name = args["name"] as? String,
                      let idx = model.skp?.scenes.firstIndex(where: { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) {
                model.selectScene(idx)
            }
            writeJSON([
                "ok": true,
                "selectedScene": model.selectedScene as Any,
                "camera": buildCameraDictionary(model: model),
            ])

        case ("POST", "/v1/layers"):
            guard let model = activeModel else {
                statusBox.set(400)
                writeJSON(["error": "No .skp document is currently open"])
                return
            }
            if let all = args["all"] as? Bool {
                model.setAllLayers(visible: all)
            } else if let soloIdx = (args["solo"] as? Int) ?? (args["solo"] as? Double).map(Int.init) {
                model.soloLayer(soloIdx)
            } else if let soloName = args["solo"] as? String,
                      let idx = model.skp?.layers.firstIndex(where: { $0.name.localizedCaseInsensitiveCompare(soloName) == .orderedSame }) {
                model.soloLayer(idx)
            } else {
                var targetIndex: Int? = (args["index"] as? Int) ?? (args["index"] as? Double).map(Int.init)
                if targetIndex == nil, let name = args["name"] as? String {
                    targetIndex = model.skp?.layers.firstIndex(where: { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame })
                }
                if let idx = targetIndex, model.layerVisible.indices.contains(idx) {
                    if let visible = args["visible"] as? Bool {
                        if model.layerVisible[idx] != visible { model.toggleLayer(idx) }
                    } else {
                        model.toggleLayer(idx)
                    }
                }
            }
            writeJSON([
                "ok": true,
                "visibleLayerCount": model.visibleLayerCount,
                "totalLayerCount": model.layerVisible.count,
            ])

        case ("POST", "/v1/rendering"):
            guard let model = activeModel else {
                statusBox.set(400)
                writeJSON(["error": "No .skp document is currently open"])
                return
            }
            applyRenderingJSON(args, to: model)
            writeJSON([
                "ok": true,
                "rendering": buildRenderingDictionary(model: model),
            ])

        case ("GET", "/v1/snapshot.png"):
            if let model = activeModel, model.isReady,
               let png = Snapshot.png(of: model.viewport.snapshot()) {
                contentTypeBox.set("image/png")
                box.set(png)
            } else {
                // Fallback: render synthetic model offscreen so snapshot tool always works even with no window open.
                let tempModel = DocumentModel()
                let scene = ViewportScene(model: SyntheticModel.cube())
                tempModel.present(scene, seconds: 0)
                if let png = Snapshot.png(of: tempModel.viewport.snapshot()) {
                    contentTypeBox.set("image/png")
                    box.set(png)
                } else {
                    statusBox.set(500)
                    writeJSON(["error": "Could not capture viewport snapshot"])
                }
            }

        case ("GET", "/v1/pdf"), ("POST", "/v1/pdf"):
            let targetModel: DocumentModel = {
                if let m = activeModel, m.isReady { return m }
                let temp = DocumentModel()
                temp.present(ViewportScene(model: SyntheticModel.cube()), seconds: 0)
                return temp
            }()
            let w = (args["width"] as? NSNumber)?.doubleValue
            let h = (args["height"] as? NSNumber)?.doubleValue
            let customSize: CGSize? = (w != nil && h != nil) ? CGSize(width: w!, height: h!) : nil
            guard let pdfData = targetModel.renderVectorPDF(pageSize: customSize) else {
                statusBox.set(500)
                writeJSON(["error": "Failed to generate vector PDF"])
                return
            }
            if let savePath = args["path"] as? String, !savePath.isEmpty {
                let url = URL(fileURLWithPath: (savePath as NSString).expandingTildeInPath)
                do {
                    try pdfData.write(to: url, options: .atomic)
                    writeJSON([
                        "ok": true,
                        "path": url.path,
                        "bytes": pdfData.count,
                        "vector": true,
                    ])
                } catch {
                    statusBox.set(500)
                    writeJSON(["error": error.localizedDescription])
                }
            } else {
                contentTypeBox.set("application/pdf")
                box.set(pdfData)
            }

        default:
            statusBox.set(404)
            writeJSON(["error": "not found", "path": path])
        }
    }

    // MARK: - Helpers & State Builders

    private func openDocumentAndWaitUntilReady(url: URL) async -> DocumentModel? {
        await withCheckedContinuation { continuation in
            NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { doc, _, error in
                guard let skpDoc = doc as? SKPDocument, error == nil else {
                    continuation.resume(returning: nil)
                    return
                }
                Task { @MainActor in
                    let model = skpDoc.model
                    self.attachFeedbackIfNeeded(to: model)
                    let deadline = CFAbsoluteTimeGetCurrent() + 12.0
                    while !model.isReady && model.error == nil && CFAbsoluteTimeGetCurrent() < deadline {
                        try? await Task.sleep(nanoseconds: 40_000_000)
                    }
                    continuation.resume(returning: model)
                }
            }
        }
    }

    func applyCameraJSON(_ args: [String: Any], to model: DocumentModel) {
        if let action = (args["action"] as? String)?.lowercased() {
            switch action {
            case "reset": model.resetView()
            case "zoom_extents", "zoomextents", "frame": model.zoomExtents()
            case "level": model.levelCameraHorizon(animated: false)
            case "eye_height", "eyeheight":
                let h = (args["eyeHeight"] as? Double).map(Float.init) ?? 1.70
                model.setCameraEyeHeight(h)
            case "center":
                model.centerCameraInModel()
            default: break
            }
        }
        if let viewStr = (args["standardView"] as? String)?.lowercased() ?? (args["view"] as? String)?.lowercased() {
            switch viewStr {
            case "iso": model.look(.iso)
            case "top", "dessus": model.look(.top)
            case "bottom", "dessous": model.look(.bottom)
            case "front", "face": model.look(.front)
            case "back", "arriere", "arrière": model.look(.back)
            case "left", "gauche": model.look(.left)
            case "right", "droite": model.look(.right)
            default: break
            }
        }
        if let persp = args["perspective"] as? Bool {
            model.setPerspective(persp)
        }
        if let fov = (args["fov"] as? Double).map(Float.init) ?? (args["fov"] as? Int).map(Float.init) {
            model.setCameraFOV(fov)
        }
        if let focal = (args["focalLengthMM"] as? Double).map(Float.init) ?? (args["focal"] as? Double).map(Float.init) {
            model.setCameraFocalLength(focal)
        }
        if let exp = (args["exposure"] as? Double).map(Float.init) {
            model.setCameraExposure(exp)
        }
        if let ortho = (args["orthoScale"] as? Double).map(Float.init) {
            model.setCameraOrthoScale(ortho)
        }
        if let speed = (args["speedScale"] as? Double).map(Float.init) ?? (args["speed"] as? Double).map(Float.init) {
            model.setCameraSpeedScale(speed)
        }

        var pos = model.cameraPosition
        var hasPosChange = false
        if let arr = args["position"] as? [Any], arr.count >= 3,
           let x = (arr[0] as? NSNumber)?.floatValue,
           let y = (arr[1] as? NSNumber)?.floatValue,
           let z = (arr[2] as? NSNumber)?.floatValue {
            pos = SIMD3<Float>(x, y, z)
            hasPosChange = true
        }
        if let x = (args["x"] as? NSNumber)?.floatValue { pos.x = x; hasPosChange = true }
        if let y = (args["y"] as? NSNumber)?.floatValue { pos.y = y; hasPosChange = true }
        if let z = (args["z"] as? NSNumber)?.floatValue { pos.z = z; hasPosChange = true }
        if hasPosChange {
            model.setCameraPosition(pos)
        }

        if let tgtArr = args["target"] as? [Any], tgtArr.count >= 3,
           let tx = (tgtArr[0] as? NSNumber)?.floatValue,
           let ty = (tgtArr[1] as? NSNumber)?.floatValue,
           let tz = (tgtArr[2] as? NSNumber)?.floatValue {
            model.setCameraTarget(SIMD3<Float>(tx, ty, tz), animated: false)
        }

        let yaw = (args["yaw"] as? NSNumber)?.floatValue
        let pitch = (args["pitch"] as? NSNumber)?.floatValue
        if yaw != nil || pitch != nil {
            model.setCameraOrientation(yawDegrees: yaw, pitchDegrees: pitch)
        }
        if let dist = (args["distance"] as? NSNumber)?.floatValue {
            model.setCameraDistance(dist)
        }
    }

    func applyRenderingJSON(_ args: [String: Any], to model: DocumentModel) {
        if let styleStr = (args["style"] as? String)?.lowercased() {
            switch styleStr {
            case "textured", "pbr": model.setShadingStyle(.textured)
            case "clay", "blanc": model.setShadingStyle(.clay)
            case "xray", "x-ray": model.setShadingStyle(.xray)
            case "wireframe", "wire", "filaire": model.setShadingStyle(.wireframe)
            default: break
            }
        }
        if let edges = args["edges"] as? Bool, model.showsEdges != edges {
            model.toggleEdges()
        }
        if let grid = args["grid"] as? Bool, model.showsGrid != grid {
            model.toggleGrid()
        }
        if let shadows = args["shadows"] as? Bool, model.shadowsEnabled != shadows {
            model.toggleShadows()
        }
        if let ssao = (args["ssao"] as? NSNumber)?.floatValue {
            model.setAmbientOcclusionIntensity(ssao)
        }
        if let modeStr = (args["lightingMode"] as? String)?.lowercased() {
            if modeStr == "point" || modeStr == "omni" {
                model.setLightingMode(.point)
            } else if modeStr == "sun" {
                model.setLightingMode(.sun)
            }
        }
        let sunAz = (args["sunAzimuth"] as? NSNumber)?.floatValue
        let sunEl = (args["sunElevation"] as? NSNumber)?.floatValue
        if sunAz != nil || sunEl != nil {
            model.setSun(
                azimuth: sunAz ?? model.sunAzimuthDegrees,
                elevation: sunEl ?? model.sunElevationDegrees
            )
        }
        if let sunInt = (args["sunIntensity"] as? NSNumber)?.floatValue {
            model.setSunIntensity(sunInt)
        }
        if let ambInt = (args["ambientIntensity"] as? NSNumber)?.floatValue ?? (args["ambient"] as? NSNumber)?.floatValue {
            model.setAmbientIntensity(ambInt)
        }
        if let lpos = args["lightPosition"] as? [Any], lpos.count >= 3,
           let lx = (lpos[0] as? NSNumber)?.floatValue,
           let ly = (lpos[1] as? NSNumber)?.floatValue,
           let lz = (lpos[2] as? NSNumber)?.floatValue {
            if model.lightingMode != .point { model.setLightingMode(.point) }
            model.updateSelectedPointLight(position: SIMD3<Float>(lx, ly, lz))
        }
        if let lint = (args["lightIntensity"] as? NSNumber)?.floatValue {
            if model.lightingMode != .point { model.setLightingMode(.point) }
            model.updateSelectedPointLight(intensity: lint)
        }
        if let gizmo = args["lightGizmo"] as? Bool, model.showsPointLightGizmo != gizmo {
            model.togglePointLightGizmo()
        }
        if let bdStr = args["backdropStyle"] as? String,
           let bd = BackdropStyle.allCases.first(where: { $0.rawValue.lowercased() == bdStr.lowercased() }) {
            model.setBackdropStyle(bd)
        }
        if let rgb = args["backdropColor"] as? [Any], rgb.count >= 3,
           let r = (rgb[0] as? NSNumber)?.floatValue,
           let g = (rgb[1] as? NSNumber)?.floatValue,
           let b = (rgb[2] as? NSNumber)?.floatValue {
            model.setCustomBackdropColor(SIMD3<Float>(r, g, b))
        }
    }

    func buildCameraDictionary(model: DocumentModel?) -> [String: Any] {
        guard let model else {
            return ["ready": false]
        }
        let pos = model.cameraPosition
        let tgt = model.cameraTarget
        return [
            "ready": model.isReady,
            "isPerspective": model.isPerspective,
            "position": [pos.x, pos.y, pos.z],
            "target": [tgt.x, tgt.y, tgt.z],
            "yawDegrees": model.cameraYawDegrees,
            "pitchDegrees": model.cameraPitchDegrees,
            "distance": model.cameraDistance,
            "fovDegrees": model.cameraFOV,
            "focalLengthMM": model.cameraFocalLengthMM,
            "exposureEV": model.cameraExposure,
            "orthoScale": model.cameraOrthoScale,
            "speedScale": model.cameraSpeedScale,
        ]
    }

    func buildRenderingDictionary(model: DocumentModel?) -> [String: Any] {
        guard let model else { return [:] }
        let light = model.selectedPointLight
        return [
            "shadingStyle": model.shadingStyle.rawValue,
            "showsEdges": model.showsEdges,
            "showsGrid": model.showsGrid,
            "shadowsEnabled": model.shadowsEnabled,
            "ambientOcclusionEnabled": model.ambientOcclusionEnabled,
            "ambientOcclusionIntensity": model.ambientOcclusionIntensity,
            "lightingMode": model.lightingMode.rawValue,
            "ambientIntensity": model.ambientIntensity,
            "sunAzimuthDegrees": model.sunAzimuthDegrees,
            "sunElevationDegrees": model.sunElevationDegrees,
            "sunIntensity": model.sunIntensity,
            "pointLightCount": model.pointLights.count,
            "selectedPointLight": light.map {
                [
                    "name": $0.name,
                    "position": [$0.position.x, $0.position.y, $0.position.z],
                    "intensity": $0.intensity,
                    "isFromScene": $0.isFromScene,
                ] as [String: Any]
            } as Any,
            "showsPointLightGizmo": model.showsPointLightGizmo,
            "backdropStyle": model.backdropStyle.rawValue,
            "customBackdropColor": [model.customBackdropColor.x, model.customBackdropColor.y, model.customBackdropColor.z],
        ]
    }

    func buildStateDictionary(for specificModel: DocumentModel? = nil) -> [String: Any] {
        let model = specificModel ?? activeModel
        let skp = model?.skp
        let size = model?.visibleSize ?? skp?.size ?? .zero
        return [
            "app": "SimpleSKP",
            "version": AppVersion.current.version,
            "build": AppVersion.current.build ?? "",
            "oscInPort": Int(oscInPort),
            "oscOutHost": Preferences.oscOutHost,
            "oscOutPort": Int(Preferences.oscOutPort),
            "oscFeedbackEnabled": Preferences.oscFeedbackEnabled,
            "apiPort": Int(httpPort),
            "hasDocument": model != nil,
            "isReady": model?.isReady ?? false,
            "filePath": model?.info?.url.path ?? skp?.fileInfo.url.path ?? "",
            "versionLabel": model?.info?.versionLabel ?? skp?.fileInfo.versionLabel ?? "",
            "statusText": model?.statusText ?? L("Aucun fichier ouvert", "No file open"),
            "dimensionsMetres": [size.x, size.y, size.z],
            "boundsMin": skp.map { [$0.boundsMin.x, $0.boundsMin.y, $0.boundsMin.z] } ?? [0, 0, 0],
            "boundsMax": skp.map { [$0.boundsMax.x, $0.boundsMax.y, $0.boundsMax.z] } ?? [0, 0, 0],
            "stats": [
                "faces": skp?.stats.faces ?? 0,
                "edges": skp?.stats.edges ?? 0,
                "instances": skp?.stats.instances ?? 0,
                "materials": skp?.materials.count ?? 0,
            ],
            "camera": buildCameraDictionary(model: model),
            "rendering": buildRenderingDictionary(model: model),
            "selectedScene": model?.selectedScene as Any,
            "scenes": (skp?.scenes ?? []).enumerated().map { idx, sc in
                [
                    "index": idx,
                    "name": sc.name,
                    "hasCamera": sc.camera != nil,
                    "selected": model?.selectedScene == idx,
                ] as [String: Any]
            },
            "layers": (skp?.layers ?? []).enumerated().map { idx, layer in
                [
                    "index": idx,
                    "name": layer.name,
                    "visible": (model?.layerVisible.indices.contains(idx) == true) ? model!.layerVisible[idx] : layer.isVisible,
                ] as [String: Any]
            },
        ]
    }

    func buildHelpDictionary() -> [String: Any] {
        [
            "app": "SimpleSKP",
            "oscInPort": Int(oscInPort),
            "oscOutPort": Int(Preferences.oscOutPort),
            "apiPort": Int(httpPort),
            "bonjourServices": ["_oscjson._tcp.", "_osc._udp."],
            "httpEndpoints": [
                "GET /?HOST_INFO (OSCQuery host info for OSCScore)",
                "GET / (OSCQuery full parameter namespace for OSCScore)",
                "GET /v1/state",
                "GET /v1/help",
                "GET /v1/camera",
                "POST /v1/camera {\"position\":[x,y,z],\"target\":[tx,ty,tz],\"yaw\":0,\"pitch\":-15,\"distance\":25,\"fov\":35,\"focalLengthMM\":38,\"exposure\":-0.62,\"perspective\":true,\"action\":\"reset|zoom_extents|level|eye_height|center\"}",
                "POST /v1/open {\"path\":\"/path/to/model.skp\"}",
                "POST /v1/scene {\"index\":0, \"name\":\"Scene 1\", \"action\":\"next|prev\"}",
                "POST /v1/layers {\"all\":true, \"solo\":0, \"index\":1, \"visible\":false}",
                "POST /v1/rendering {\"style\":\"textured|clay|xray|wireframe\",\"edges\":true,\"grid\":false,\"shadows\":true,\"ssao\":0.7,\"lightingMode\":\"sun|point\",\"sunAzimuth\":-135,\"sunElevation\":45,\"lightPosition\":[x,y,z],\"lightIntensity\":1.0,\"backdropStyle\":\"architecturalSky|studioDark|warmPaper|customColor\",\"backdropColor\":[r,g,b]}",
                "GET /v1/snapshot.png",
            ],
            "oscAddresses": oscQueryParameters().map { "\($0.path) [\($0.typeTag)] — \($0.description)" },
        ]
    }
}
