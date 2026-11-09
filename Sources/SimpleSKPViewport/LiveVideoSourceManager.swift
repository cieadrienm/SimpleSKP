import Foundation
import Metal
import SimpleSKPCore
import SimpleSKPVideoBridge

public extension Notification.Name {
    static let sskpLiveVideoSourcesDidChange = Notification.Name("sskpLiveVideoSourcesDidChange")
}

/// Describes a discovered live Syphon server or NDI network stream.
public struct LiveVideoSource: Identifiable, Equatable, Sendable {
    public var id: String
    public var kind: ProjectionPattern
    public var name: String
    public var appName: String
    public var displayTitle: String
    public var matchText: String

    public init(
        id: String,
        kind: ProjectionPattern,
        name: String,
        appName: String,
        displayTitle: String,
        matchText: String
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.appName = appName
        self.displayTitle = displayTitle
        self.matchText = matchText
    }
}

/// Discovers and resolves live Syphon servers and NDI video streams for `VideoProjector` instances.
public final class LiveVideoSourceManager: @unchecked Sendable {
    public static let shared = LiveVideoSourceManager()

    public static var isSyphonAvailable: Bool {
        SSKPVideoSyphonBridge.isAvailable()
    }

    public static var isNDIAvailable: Bool {
        SSKPVideoNDIBridge.isAvailable()
    }

    public static var ndiVersion: String? {
        SSKPVideoNDIBridge.ndiVersion()
    }

    private let lock = NSLock()
    private var syphonObserver: Any?
    private var ndiBridge: SSKPVideoNDIBridge?
    private var cachedSyphonDescriptors: [SSKPVideoSourceDescriptor] = []
    private var cachedNDIDescriptors: [SSKPVideoSourceDescriptor] = []
    /// Optional registered private Syphon server descriptions (used by automated tests).
    private var customSyphonDescriptions: [String: [String: Any]] = [:]
    /// Syphon server UUIDs published by SimpleSKP itself (excluded from VideoProjector input choices to avoid feedback loops).
    private var excludedSyphonServerUUIDs: Set<String> = []

    private init() {
        refreshSyphonSourcesLocked()
        syphonObserver = SSKPVideoSyphonBridge.observeChanges { [weak self] in
            self?.refreshSources()
        }
    }

    deinit {
        if let syphonObserver {
            SSKPVideoSyphonBridge.removeObserver(syphonObserver)
        }
        ndiBridge?.stop()
    }

    /// Ensures the background NDI discovery thread is running if `libndi.dylib` is available.
    public func ensureNDIDiscoveryStarted() {
        lock.lock()
        let needsStart = (ndiBridge == nil && SSKPVideoNDIBridge.isAvailable())
        lock.unlock()
        guard needsStart else { return }

        let bridge = SSKPVideoNDIBridge { [weak self] in
            self?.handleNDISourcesChanged()
        }
        lock.lock()
        if ndiBridge == nil {
            ndiBridge = bridge
            if let bridge {
                cachedNDIDescriptors = bridge.currentSources()
            }
        }
        lock.unlock()
        NotificationCenter.default.post(name: .sskpLiveVideoSourcesDidChange, object: self)
    }

    private func handleNDISourcesChanged() {
        lock.lock()
        if let ndiBridge {
            cachedNDIDescriptors = ndiBridge.currentSources()
        }
        lock.unlock()
        NotificationCenter.default.post(name: .sskpLiveVideoSourcesDidChange, object: self)
    }

    private func refreshSyphonSourcesLocked() {
        let excluded = excludedSyphonServerUUIDs
        cachedSyphonDescriptors = SSKPVideoSyphonBridge.availableServers().filter { desc in
            guard !excluded.isEmpty else { return true }
            return !excluded.contains { uuid in desc.identifier == "syphon:\(uuid)" }
        }
    }

    /// Marks or unmarks a Syphon server UUID as owned by SimpleSKP's viewport output so VideoProjectors do not self-feedback.
    public func setOwnSyphonServerUUID(_ uuid: String, excluded: Bool) {
        guard !uuid.isEmpty else { return }
        lock.lock()
        if excluded {
            excludedSyphonServerUUIDs.insert(uuid)
        } else {
            excludedSyphonServerUUIDs.remove(uuid)
        }
        refreshSyphonSourcesLocked()
        lock.unlock()
    }

    /// Refreshes both Syphon and NDI source lists and posts `.sskpLiveVideoSourcesDidChange`.
    public func refreshSources() {
        ensureNDIDiscoveryStarted()
        lock.lock()
        refreshSyphonSourcesLocked()
        if let ndiBridge {
            cachedNDIDescriptors = ndiBridge.currentSources()
        }
        lock.unlock()
        NotificationCenter.default.post(name: .sskpLiveVideoSourcesDidChange, object: self)
    }

    public var syphonSources: [LiveVideoSource] {
        lock.lock()
        refreshSyphonSourcesLocked()
        let descs = cachedSyphonDescriptors
        lock.unlock()
        return descs.map { d in
            LiveVideoSource(
                id: d.identifier,
                kind: .syphon,
                name: d.name,
                appName: d.appName,
                displayTitle: d.displayTitle,
                matchText: d.matchText
            )
        }
    }

    public var ndiSources: [LiveVideoSource] {
        ensureNDIDiscoveryStarted()
        lock.lock()
        if let ndiBridge {
            cachedNDIDescriptors = ndiBridge.currentSources()
        }
        let descs = cachedNDIDescriptors
        lock.unlock()
        return descs.map { d in
            LiveVideoSource(
                id: d.identifier,
                kind: .ndi,
                name: d.name,
                appName: d.appName,
                displayTitle: d.displayTitle,
                matchText: d.matchText
            )
        }
    }

    /// Registers or unregisters a custom/private Syphon server description by identifier (for headless self-tests).
    public func registerCustomSyphonServerDescription(_ description: [String: Any]?, forIdentifier id: String) {
        lock.lock()
        if let description {
            customSyphonDescriptions[id] = description
        } else {
            customSyphonDescriptions.removeValue(forKey: id)
        }
        lock.unlock()
    }

    internal func resolveSyphonDescriptor(id: String?, name: String?) -> (identifier: String, description: [String: Any])? {
        lock.lock()
        if let id, let custom = customSyphonDescriptions[id] {
            lock.unlock()
            return (id, custom)
        }
        refreshSyphonSourcesLocked()
        let descs = cachedSyphonDescriptors
        lock.unlock()

        if let id, !id.isEmpty,
           let exact = descs.first(where: { $0.identifier == id }),
           let dict = exact.syphonDescription {
            return (exact.identifier, dict)
        }
        if let name, !name.isEmpty {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if let match = descs.first(where: {
                $0.displayTitle.caseInsensitiveCompare(trimmed) == .orderedSame ||
                $0.name.caseInsensitiveCompare(trimmed) == .orderedSame ||
                $0.matchText.localizedCaseInsensitiveContains(trimmed)
            }), let dict = match.syphonDescription {
                return (match.identifier, dict)
            }
        }
        // If no specific source was chosen yet, fall back to the first available Syphon server
        if (id == nil || id?.isEmpty == true) && (name == nil || name?.isEmpty == true),
           let first = descs.first,
           let dict = first.syphonDescription {
            return (first.identifier, dict)
        }
        return nil
    }

    internal func resolveNDIDescriptor(id: String?, name: String?) -> SSKPVideoSourceDescriptor? {
        ensureNDIDiscoveryStarted()
        lock.lock()
        if let ndiBridge {
            cachedNDIDescriptors = ndiBridge.currentSources()
        }
        let descs = cachedNDIDescriptors
        lock.unlock()

        if let id, !id.isEmpty,
           let exact = descs.first(where: { $0.identifier == id }) {
            return exact
        }
        if let name, !name.isEmpty {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if let match = descs.first(where: {
                $0.displayTitle.caseInsensitiveCompare(trimmed) == .orderedSame ||
                $0.name.caseInsensitiveCompare(trimmed) == .orderedSame ||
                $0.matchText.localizedCaseInsensitiveContains(trimmed)
            }) {
                return match
            }
        }
        if (id == nil || id?.isEmpty == true) && (name == nil || name?.isEmpty == true),
           let first = descs.first {
            return first
        }
        return nil
    }
}
