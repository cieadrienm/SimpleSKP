import AppKit
import CryptoKit
import Foundation
import Observation

/// Lightweight, zero-dependency self-updater for the Simple app family.
/// Supports both a static JSON manifest (`SimpleUpdateURL` / `SIMPLE_UPDATE_URL`)
/// and the GitHub Releases API (`https://api.github.com/repos/cieadrienm/SimpleSKP/releases/latest`),
/// with SHA-256 + Apple `codesign` verification and atomic `.app` replacement.
@Observable
@MainActor
public final class SimpleUpdater {
    public struct ReleaseInfo: Equatable, Codable, Sendable {
        public var version: String
        public var build: Int?
        public var downloadURL: URL
        public var sha256: String?
        public var notesFR: String?
        public var notesEN: String?
        public var htmlURL: URL?

        public init(
            version: String,
            build: Int? = nil,
            downloadURL: URL,
            sha256: String? = nil,
            notesFR: String? = nil,
            notesEN: String? = nil,
            htmlURL: URL? = nil
        ) {
            self.version = version
            self.build = build
            self.downloadURL = downloadURL
            self.sha256 = sha256
            self.notesFR = notesFR
            self.notesEN = notesEN
            self.htmlURL = htmlURL
        }

        public var localizedNotes: String {
            if Localization.isEnglish {
                if let en = notesEN, !en.isEmpty { return en }
                if let fr = notesFR, !fr.isEmpty { return fr }
            } else {
                if let fr = notesFR, !fr.isEmpty { return fr }
                if let en = notesEN, !en.isEmpty { return en }
            }
            return L("Mise à jour de maintenance et d'améliorations.", "Maintenance and feature update.")
        }
    }

    public enum State: Equatable, Sendable {
        case idle
        case checking
        case upToDate(String)
        case updateAvailable(ReleaseInfo)
        case downloading(Double)
        case installing
        case failed(String)
    }

    public let appName: String
    public let bundleID: String
    public let githubRepo: String
    public let currentVersion: String
    public let currentBuild: Int
    private let defaultsPrefix: String

    public var state: State = .idle
    public var autoCheckOnLaunch: Bool {
        didSet {
            UserDefaults.standard.set(autoCheckOnLaunch, forKey: defaultsPrefix + "autoCheckUpdates")
        }
    }

    public var availableRelease: ReleaseInfo? {
        if case .updateAvailable(let rel) = state { return rel }
        return nil
    }

    public init(
        appName: String = "SimpleSKP",
        bundleID: String = "net.cieadrienm.simpleskp",
        githubRepo: String = "cieadrienm/SimpleSKP",
        currentVersion: String? = nil,
        currentBuild: Int? = nil,
        startAutoCheck: Bool = true
    ) {
        self.appName = appName
        self.bundleID = bundleID
        self.githubRepo = githubRepo
        self.defaultsPrefix = "\(bundleID)."
        self.currentVersion = currentVersion
            ?? (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String)
            ?? "1.0.0"
        self.currentBuild = currentBuild
            ?? Int((Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "1")
            ?? 1

        if UserDefaults.standard.object(forKey: defaultsPrefix + "autoCheckUpdates") == nil {
            self.autoCheckOnLaunch = true
        } else {
            self.autoCheckOnLaunch = UserDefaults.standard.bool(forKey: defaultsPrefix + "autoCheckUpdates")
        }

        if startAutoCheck && self.autoCheckOnLaunch {
            let lastCheck = UserDefaults.standard.double(forKey: defaultsPrefix + "lastUpdateCheckTimestamp")
            let now = Date().timeIntervalSince1970
            if now - lastCheck >= 86_400 {
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(2.5))
                    self?.checkForUpdates(silent: true)
                }
            }
        }
    }

    // MARK: - Feed URL Resolution

    public var configuredFeedURL: URL {
        if let env = ProcessInfo.processInfo.environment["SIMPLE_UPDATE_URL"],
           !env.isEmpty, let url = URL(string: env) {
            return url
        }
        if let custom = UserDefaults.standard.string(forKey: defaultsPrefix + "updateURL"),
           !custom.isEmpty, let url = URL(string: custom) {
            return url
        }
        if let plistURL = Bundle.main.infoDictionary?["SimpleUpdateURL"] as? String,
           !plistURL.isEmpty, let url = URL(string: plistURL) {
            return url
        }
        return URL(string: "https://api.github.com/repos/\(githubRepo)/releases/latest")!
    }

    // MARK: - Version Comparison & Feed Parsing

    /// Compares two semantic version strings (and optional build numbers).
    /// Returns `true` iff `(candidateVersion, candidateBuild)` is strictly newer than `(currentVersion, currentBuild)`.
    public nonisolated static func isNewer(
        candidateVersion: String,
        candidateBuild: Int? = nil,
        thanVersion currentVersion: String,
        currentBuild: Int? = nil
    ) -> Bool {
        let candParts = normalizeVersion(candidateVersion)
        let currParts = normalizeVersion(currentVersion)
        let count = max(candParts.count, currParts.count)
        for i in 0..<count {
            let a = i < candParts.count ? candParts[i] : 0
            let b = i < currParts.count ? currParts[i] : 0
            if a != b { return a > b }
        }
        if let cb = candidateBuild, let curB = currentBuild {
            return cb > curB
        }
        return false
    }

    private nonisolated static func normalizeVersion(_ raw: String) -> [Int] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "^[vV]", with: "", options: .regularExpression)
        let core = trimmed.split(separator: "-").first.map(String.init) ?? trimmed
        return core.split(separator: ".").map { Int($0) ?? 0 }
    }

    /// Parses either a custom JSON manifest (single-app or multi-app keyed by `bundleID`) or a GitHub Release JSON payload.
    public nonisolated static func parseRelease(from data: Data, bundleID: String, appName: String) throws -> ReleaseInfo {
        let json = try JSONSerialization.jsonObject(with: data, options: [])
        guard let dict = json as? [String: Any] else {
            throw NSError(domain: "SimpleUpdater", code: 1, userInfo: [
                NSLocalizedDescriptionKey: L("Réponse JSON de mise à jour invalide.", "Invalid update JSON response.")
            ])
        }

        // Case 1: Multi-app family manifest keyed by bundleID or appName
        if let sub = (dict[bundleID] as? [String: Any]) ?? (dict[appName] as? [String: Any]) {
            return try parseManifestDictionary(sub)
        }

        // Case 2: Direct manifest dictionary (`{"version": "...", "url": "..."}`)
        if dict["version"] != nil, (dict["url"] != nil || dict["download_url"] != nil) {
            return try parseManifestDictionary(dict)
        }

        // Case 3: GitHub Releases API (`tag_name`, `assets`, `body`)
        if let tagName = dict["tag_name"] as? String {
            let cleanVersion = tagName.replacingOccurrences(of: "^[vV]", with: "", options: .regularExpression)
            let body = dict["body"] as? String
            let htmlURL = (dict["html_url"] as? String).flatMap(URL.init(string:))
            let assets = dict["assets"] as? [[String: Any]] ?? []

            let matchingAsset = assets.first { asset in
                guard let name = (asset["name"] as? String)?.lowercased() else { return false }
                return name.hasSuffix(".zip") && name.contains(appName.lowercased())
            } ?? assets.first { asset in
                guard let name = (asset["name"] as? String)?.lowercased() else { return false }
                return name.hasSuffix(".zip")
            }

            if let asset = matchingAsset,
               let urlStr = asset["browser_download_url"] as? String,
               let url = URL(string: urlStr) {
                return ReleaseInfo(
                    version: cleanVersion,
                    build: nil,
                    downloadURL: url,
                    sha256: extractSHA256(from: body),
                    notesFR: body,
                    notesEN: body,
                    htmlURL: htmlURL
                )
            }
        }

        throw NSError(domain: "SimpleUpdater", code: 2, userInfo: [
            NSLocalizedDescriptionKey: L("Aucune archive .zip de mise à jour trouvée.", "No update .zip archive found.")
        ])
    }

    private nonisolated static func parseManifestDictionary(_ dict: [String: Any]) throws -> ReleaseInfo {
        guard let version = dict["version"] as? String,
              let urlStr = (dict["url"] as? String) ?? (dict["download_url"] as? String),
              let url = URL(string: urlStr) else {
            throw NSError(domain: "SimpleUpdater", code: 3, userInfo: [
                NSLocalizedDescriptionKey: L("Manifeste de mise à jour incomplet.", "Incomplete update manifest.")
            ])
        }
        let build = (dict["build"] as? Int) ?? (dict["build"] as? String).flatMap(Int.init)
        let sha256 = (dict["sha256"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let notesFR = (dict["notes_fr"] as? String) ?? (dict["notes"] as? String)
        let notesEN = (dict["notes_en"] as? String) ?? (dict["notes"] as? String)
        let htmlURL = (dict["html_url"] as? String).flatMap(URL.init(string:))
        return ReleaseInfo(
            version: version.replacingOccurrences(of: "^[vV]", with: "", options: .regularExpression),
            build: build,
            downloadURL: url,
            sha256: sha256?.isEmpty == true ? nil : sha256,
            notesFR: notesFR,
            notesEN: notesEN,
            htmlURL: htmlURL
        )
    }

    private nonisolated static func extractSHA256(from text: String?) -> String? {
        guard let text else { return nil }
        let pattern = "(?i)sha256\\s*[:=]\\s*([0-9a-f]{64})"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[range]).lowercased()
    }

    public nonisolated static func sha256Hex(of data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Network Check & Atomic Installation

    public func checkForUpdates(silent: Bool = false) {
        if !silent {
            state = .checking
        }
        let feedURL = configuredFeedURL
        let bundleID = self.bundleID
        let appName = self.appName
        let currentVersion = self.currentVersion
        let currentBuild = self.currentBuild
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: defaultsPrefix + "lastUpdateCheckTimestamp")

        Task.detached(priority: .utility) {
            do {
                var request = URLRequest(url: feedURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8.0)
                request.setValue("application/vnd.github+json, application/json", forHTTPHeaderField: "Accept")
                request.setValue("\(appName)/\(currentVersion)", forHTTPHeaderField: "User-Agent")

                let (data, response) = try await URLSession.shared.data(for: request)
                if let http = response as? HTTPURLResponse, http.statusCode == 404 {
                    await MainActor.run {
                        if !silent {
                            self.state = .upToDate(currentVersion)
                        }
                    }
                    return
                }
                let release = try Self.parseRelease(from: data, bundleID: bundleID, appName: appName)
                let newer = Self.isNewer(
                    candidateVersion: release.version,
                    candidateBuild: release.build,
                    thanVersion: currentVersion,
                    currentBuild: currentBuild
                )
                await MainActor.run {
                    if newer {
                        self.state = .updateAvailable(release)
                    } else if !silent {
                        self.state = .upToDate(currentVersion)
                    }
                }
            } catch {
                await MainActor.run {
                    if !silent {
                        self.state = .failed(error.localizedDescription)
                    }
                }
            }
        }
    }

    public func downloadAndInstall(_ release: ReleaseInfo) {
        state = .downloading(0.1)
        let appName = self.appName
        Task.detached(priority: .userInitiated) {
            do {
                let (zipData, _) = try await URLSession.shared.data(from: release.downloadURL)
                await MainActor.run { self.state = .downloading(0.75) }

                if let expectedSHA = release.sha256?.lowercased(), !expectedSHA.isEmpty {
                    let actualSHA = Self.sha256Hex(of: zipData)
                    guard actualSHA == expectedSHA else {
                        throw NSError(domain: "SimpleUpdater", code: 10, userInfo: [
                            NSLocalizedDescriptionKey: L(
                                "Empreinte SHA-256 invalide (attendu \(expectedSHA.prefix(10))…, reçu \(actualSHA.prefix(10))…).",
                                "SHA-256 checksum mismatch (expected \(expectedSHA.prefix(10))…, got \(actualSHA.prefix(10))…)."
                            )
                        ])
                    }
                }

                await MainActor.run { self.state = .installing }

                let tempRoot = FileManager.default.temporaryDirectory
                    .appendingPathComponent("SimpleUpdater-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
                let zipFile = tempRoot.appendingPathComponent("\(appName).zip")
                let extractDir = tempRoot.appendingPathComponent("extracted", isDirectory: true)
                try zipData.write(to: zipFile, options: .atomic)

                try Self.runProcess("/usr/bin/ditto", arguments: ["-x", "-k", zipFile.path, extractDir.path])

                guard let newAppURL = Self.findAppBundle(in: extractDir, preferredName: "\(appName).app") else {
                    throw NSError(domain: "SimpleUpdater", code: 11, userInfo: [
                        NSLocalizedDescriptionKey: L("Aucun bundle .app trouvé dans l'archive.", "No .app bundle found in archive.")
                    ])
                }

                try Self.verifyCodeSignature(of: newAppURL)

                let destURL = Self.targetInstallURL(appName: appName)
                try Self.launchSwapAndRestartScript(newAppURL: newAppURL, destURL: destURL)

                await MainActor.run {
                    NSApp.terminate(nil)
                }
            } catch {
                await MainActor.run {
                    self.state = .failed(error.localizedDescription)
                }
            }
        }
    }

    private nonisolated static func targetInstallURL(appName: String) -> URL {
        let currentURL = Bundle.main.bundleURL
        if currentURL.pathExtension == "app" {
            return currentURL
        }
        return URL(fileURLWithPath: "/Applications/\(appName).app")
    }

    private nonisolated static func findAppBundle(in directory: URL, preferredName: String) -> URL? {
        let fm = FileManager.default
        if let items = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            if let exact = items.first(where: { $0.lastPathComponent == preferredName }) {
                return exact
            }
            if let anyApp = items.first(where: { $0.pathExtension == "app" }) {
                return anyApp
            }
        }
        return nil
    }

    private nonisolated static func verifyCodeSignature(of appURL: URL) throws {
        try runProcess("/usr/bin/codesign", arguments: ["--verify", "--deep", "--strict", appURL.path])

        let currentAppURL = Bundle.main.bundleURL
        if currentAppURL.pathExtension == "app",
           let currentTeam = teamIdentifier(of: currentAppURL),
           !currentTeam.isEmpty,
           currentTeam != "not set" {
            let newTeam = teamIdentifier(of: appURL)
            guard newTeam == currentTeam else {
                throw NSError(domain: "SimpleUpdater", code: 12, userInfo: [
                    NSLocalizedDescriptionKey: L(
                        "Certificat développeur différent (\(newTeam ?? "inconnu") ≠ \(currentTeam)).",
                        "Developer certificate mismatch (\(newTeam ?? "unknown") ≠ \(currentTeam))."
                    )
                ])
            }
        }
    }

    private nonisolated static func teamIdentifier(of appURL: URL) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        proc.arguments = ["-dv", appURL.path]
        let pipe = Pipe()
        proc.standardError = pipe
        proc.standardOutput = Pipe()
        try? proc.run()
        proc.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return nil }
        for line in output.split(separator: "\n") where line.hasPrefix("TeamIdentifier=") {
            return String(line.dropFirst("TeamIdentifier=".count))
        }
        return nil
    }

    private nonisolated static func runProcess(_ path: String, arguments: [String]) throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = arguments
        let errPipe = Pipe()
        proc.standardError = errPipe
        proc.standardOutput = Pipe()
        try proc.run()
        proc.waitUntilExit()
        if proc.terminationStatus != 0 {
            let errText = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw NSError(domain: "SimpleUpdater", code: Int(proc.terminationStatus), userInfo: [
                NSLocalizedDescriptionKey: errText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? L("Échec de la commande \(path)", "Command \(path) failed")
                    : errText.trimmingCharacters(in: .whitespacesAndNewlines)
            ])
        }
    }

    private nonisolated static func launchSwapAndRestartScript(newAppURL: URL, destURL: URL) throws {
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = """
        while kill -0 \(pid) 2>/dev/null; do sleep 0.1; done
        rm -rf "\(destURL.path).new"
        /usr/bin/ditto "\(newAppURL.path)" "\(destURL.path).new"
        rm -rf "\(destURL.path)"
        mv "\(destURL.path).new" "\(destURL.path)"
        /usr/bin/xattr -dr com.apple.quarantine "\(destURL.path)" 2>/dev/null || true
        /usr/bin/open "\(destURL.path)"
        rm -rf "\(newAppURL.deletingLastPathComponent().deletingLastPathComponent().path)"
        """
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments = ["-c", script]
        proc.standardOutput = nil
        proc.standardError = nil
        try proc.run()
    }
}
