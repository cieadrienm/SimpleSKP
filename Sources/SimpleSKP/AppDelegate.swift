import AppKit
import SimpleSKPCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Created on the normal launch path only: its init schedules the daily update check.
    static var updater: SimpleUpdater?

    var documentController: DocumentController!
    private var snapshotRequest: (output: String, input: String?)?
    private var selfTestRequested = false
    private var selfTestFile: String?
    private var cliMode: Bool { snapshotRequest != nil || selfTestRequested }

    func applicationWillFinishLaunching(_ notification: Notification) {
        Preferences.register()
        NSApp.appearance = NSAppearance(named: .darkAqua)
        NSApp.setActivationPolicy(.regular)
        // The first document controller made becomes `NSDocumentController.shared`.
        documentController = DocumentController()
        NSApp.mainMenu = MainMenu.build(delegate: self)
        NSWindow.allowsAutomaticWindowTabbing = false

        let args = Array(CommandLine.arguments.dropFirst())
        func operand(after index: Int) -> String? {
            index < args.count && !args[index].hasPrefix("-") ? args[index] : nil
        }
        if let index = args.firstIndex(of: "--snapshot") {
            snapshotRequest = (operand(after: index + 1) ?? "/tmp/simpleskp-snapshot.png", operand(after: index + 2))
        } else if let index = args.firstIndex(of: "--self-test") {
            selfTestRequested = true
            selfTestFile = operand(after: index + 1)
        } else {
            // Leftovers of a crashed session; not in the CLI modes, whose models may still load textures from there.
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("SimpleSKP"))
            Self.updater = SimpleUpdater()
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if selfTestRequested { SelfTest.runAndExit(file: selfTestFile) }
        if let snapshotRequest { Snapshot.run(output: snapshotRequest.output, input: snapshotRequest.input) }
        NSApp.activate(ignoringOtherApps: true)
        // A viewer has no untitled document: when nothing was opened or restored, ask for a file.
        DispatchQueue.main.async { [self] in
            if documentController.documents.isEmpty { documentController.openDocument(nil) }
        }
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Finder opens and command-line paths (`swift run SimpleSKP salle.skp`); the CLI modes' operands are not documents.
    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        defer { sender.reply(toOpenOrPrint: .success) }
        guard !cliMode else { return }
        var skip = 0
        for name in filenames {
            if skip > 0 { skip -= 1; continue }
            if name == "--lang" { skip = 1; continue }
            if name.hasPrefix("--") { continue }
            if name.hasPrefix("-") { skip = 1; continue }   // `-key value`, read by UserDefaults
            documentController.openDocument(withContentsOf: URL(fileURLWithPath: name), display: true) { _, _, error in
                if let error { NSApp.presentError(error) }
            }
        }
    }

    // MARK: Menu actions

    @objc func showAbout(_ sender: Any?) { AboutWindowController.shared.show() }

    @objc func checkForUpdates(_ sender: Any?) {
        Self.updater?.checkForUpdates(silent: false)
        UpdateWindowController.shared.show()
    }

    @objc func showSettings(_ sender: Any?) { SettingsWindowController.shared.show() }
    @objc func showHelp(_ sender: Any?) { HelpWindowController.shared.show() }
    @objc func showShortcuts(_ sender: Any?) { ShortcutsWindowController.shared.show() }
}
