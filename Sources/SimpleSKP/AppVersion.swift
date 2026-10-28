import Foundation

/// Version and build reported by SimpleSKP (status bar, About window, `--version`).
/// Both are stamped into the bundle's `Info.plist` by `Scripts/bundle.sh`.
struct AppVersion: Equatable, CustomStringConvertible, Sendable {
    static let defaultVersion = "1.4.0"
    static let bundleIdentifier = "net.cieadrienm.simpleskp"

    let version: String
    let build: String?

    init(version: String = Self.defaultVersion, build: String? = nil) {
        self.version = version
        self.build = build
    }

    init(infoDictionary info: [String: Any]?) {
        func value(_ key: String) -> String? {
            guard let s = (info?[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !s.isEmpty, !s.hasPrefix("@") else { return nil }
            return s
        }
        self.init(version: value("CFBundleShortVersionString") ?? Self.defaultVersion, build: value("CFBundleVersion"))
    }

    static let current = AppVersion(infoDictionary: Bundle.main.bundleIdentifier == bundleIdentifier ? Bundle.main.infoDictionary : nil)

    var description: String { build.map { "\(version) (\($0))" } ?? version }
    var shortLabel: String { "v\(version)" }
    var cliLine: String { "SimpleSKP \(description)" }

    static func runIfRequested(arguments: [String] = CommandLine.arguments) {
        let flags = Set(arguments.dropFirst())
        if flags.contains("--version") || flags.contains("-v") {
            print(current.cliLine)
            exit(0)
        }
        if flags.contains("--help") || flags.contains("-h") {
            print("""
            \(current.cliLine) — Visualiseur 3D de fichiers SketchUp (.skp)

            Usage:
              SimpleSKP [fichier.skp]
              SimpleSKP --version
              SimpleSKP --help
              SimpleSKP --self-test [fichier.skp]
              SimpleSKP --snapshot <sortie.png> [fichier.skp] [--view document|about|help|shortcuts|settings] [--lang fr|en]
            """)
            exit(0)
        }
    }
}
