import AppKit

@main
@MainActor
enum SimpleSKPApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    // todo: App agent (see docs/superpowers/specs/2026-10-25-simpleskp-design.md)
}
