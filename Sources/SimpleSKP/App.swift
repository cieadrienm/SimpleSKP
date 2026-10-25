import AppKit

@main
@MainActor
enum SimpleSKPApp {
    static func main() {
        // Answered before AppKit boots: `--version` must not open a window or a panel.
        AppVersion.runIfRequested()
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
