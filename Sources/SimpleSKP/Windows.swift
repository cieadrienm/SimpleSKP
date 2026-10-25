import AppKit
import SimpleSKPCore
import SwiftUI

/// A dark auxiliary window holding a SwiftUI view, brought back rather than recreated.
@MainActor
class HostedWindowController {
    private(set) var window: NSWindow?
    private let titleProvider: () -> String

    init(title: @escaping () -> String) {
        self.titleProvider = title
    }

    func show<Content: View>(_ content: () -> Content) {
        let hosting = NSHostingView(rootView: content().preferredColorScheme(.dark))
        if let window {
            window.title = titleProvider()
            window.contentView = hosting
            window.setContentSize(hosting.fittingSize)
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        hosting.frame = NSRect(origin: .zero, size: hosting.fittingSize)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = titleProvider()
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = Theme.panel
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
    }

    func close() {
        window?.close()
    }
}

/// SimpleSKP ▸ À propos de SimpleSKP, and the version in the status bar.
@MainActor
final class AboutWindowController: HostedWindowController {
    static let shared = AboutWindowController(title: { L("À propos de SimpleSKP", "About SimpleSKP") })
    func show() { show { AboutView(close: { [weak self] in self?.close() }) } }
}

/// Aide ▸ Raccourcis clavier (⌘/).
@MainActor
final class ShortcutsWindowController: HostedWindowController {
    static let shared = ShortcutsWindowController(title: { L("Raccourcis clavier", "Keyboard Shortcuts") })
    func show() { show { ShortcutsView(close: { [weak self] in self?.close() }) } }
}

/// Aide ▸ Aide SimpleSKP (⌘?).
@MainActor
final class HelpWindowController: HostedWindowController {
    static let shared = HelpWindowController(title: { L("Aide SimpleSKP", "SimpleSKP Help") })
    func show() { show { HelpView(close: { [weak self] in self?.close() }) } }
}

/// SimpleSKP ▸ Réglages… (⌘,).
@MainActor
final class SettingsWindowController: HostedWindowController {
    static let shared = SettingsWindowController(title: { L("Réglages", "Settings") })
    func show() { show { SettingsView() } }
}

/// SimpleSKP ▸ Rechercher des mises à jour…
@MainActor
final class UpdateWindowController: HostedWindowController {
    static let shared = UpdateWindowController(title: { L("Mise à jour de SimpleSKP", "SimpleSKP Update") })
    func show() {
        guard let updater = AppDelegate.updater else { return }
        show { UpdateView(updater: updater, close: { [weak self] in self?.close() }) }
    }
}
