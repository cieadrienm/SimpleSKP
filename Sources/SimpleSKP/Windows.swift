import AppKit
import SimpleSKPCore
import SimpleSKPViewport
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

/// Débogage ▸ Profileur de frame (⌥⌘M), replicating eMotion's `eMotionProfilerPanel`.
@MainActor
final class FrameProfilerWindowController: NSObject, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    static let shared = FrameProfilerWindowController()

    private(set) var panel: NSPanel?
    private var enableCheckbox: NSButton?
    private var statusField: NSTextField?
    private var copyButton: NSButton?
    private var tableView: NSTableView?
    private var refreshTimer: Timer?
    private var rows: [FrameProfiler.ZoneStats] = []
    private var wasEnabledBeforeOpen = false
    private var userToggledCheckbox = false

    var isVisible: Bool {
        panel?.isVisible ?? false
    }

    func toggle() {
        if isVisible {
            panel?.orderOut(nil)
            stopTimerAndRestoreIfNeeded()
        } else {
            show()
        }
    }

    func show() {
        buildPanelIfNeeded()
        guard let panel else { return }
        if !panel.isVisible {
            wasEnabledBeforeOpen = FrameProfiler.shared.isEnabled
            userToggledCheckbox = false
            FrameProfiler.shared.isEnabled = true
        }
        panel.title = L("Profileur de frame", "Frame Profiler")
        enableCheckbox?.title = L("Profileur actif", "Profiler active")
        copyButton?.title = L("Copier (markdown)", "Copy (markdown)")
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        startTimer()
        refresh()
    }

    func copyMarkdownToPasteboard() {
        let md = FrameProfiler.shared.markdownTable()
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(md, forType: .string)
    }

    private func buildPanelIfNeeded() {
        guard panel == nil else { return }
        let rect = NSRect(x: 140, y: 140, width: 560, height: 380)
        let style: NSWindow.StyleMask = [.titled, .closable, .resizable, .utilityWindow]
        let p = NSPanel(contentRect: rect, styleMask: style, backing: .buffered, defer: false)
        p.title = L("Profileur de frame", "Frame Profiler")
        p.appearance = NSAppearance(named: .darkAqua)
        p.isFloatingPanel = true
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.minSize = NSSize(width: 440, height: 220)
        p.delegate = self

        let content = NSView(frame: NSRect(origin: .zero, size: rect.size))
        content.autoresizingMask = [.width, .height]
        p.contentView = content

        let check = NSButton(
            checkboxWithTitle: L("Profileur actif", "Profiler active"),
            target: self,
            action: #selector(toggleEnabled(_:))
        )
        check.frame = NSRect(x: 12, y: rect.height - 32, width: 130, height: 20)
        check.autoresizingMask = [.maxXMargin, .minYMargin]
        content.addSubview(check)
        self.enableCheckbox = check

        let status = NSTextField(labelWithString: "—")
        status.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        status.textColor = .secondaryLabelColor
        status.frame = NSRect(x: 146, y: rect.height - 30, width: rect.width - 300, height: 16)
        status.autoresizingMask = [.width, .minYMargin]
        content.addSubview(status)
        self.statusField = status

        let copyBtn = NSButton(
            title: L("Copier (markdown)", "Copy (markdown)"),
            target: self,
            action: #selector(copyStats(_:))
        )
        copyBtn.bezelStyle = .rounded
        copyBtn.controlSize = .small
        copyBtn.font = NSFont.systemFont(ofSize: 11)
        copyBtn.frame = NSRect(x: rect.width - 146, y: rect.height - 34, width: 134, height: 24)
        copyBtn.autoresizingMask = [.minXMargin, .minYMargin]
        content.addSubview(copyBtn)
        self.copyButton = copyBtn

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: rect.width, height: rect.height - 40))
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder

        let tv = NSTableView(frame: scroll.bounds)
        tv.rowSizeStyle = .small
        tv.usesAlternatingRowBackgroundColors = true
        tv.headerView = NSTableHeaderView()
        tv.dataSource = self
        tv.delegate = self

        let columns: [(id: String, title: String, width: CGFloat, minWidth: CGFloat)] = [
            ("zone",    "Zone",       170, 100),
            ("last",    L("dernier ms", "last ms"), 72, 55),
            ("p50",     "p50 ms",      72, 55),
            ("p95",     "p95 ms",      72, 55),
            ("max",     "max ms",      72, 55),
            ("samples", "frames",      64, 48),
        ]
        for spec in columns {
            let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(spec.id))
            col.title = spec.title
            col.width = spec.width
            col.minWidth = spec.minWidth
            tv.addTableColumn(col)
        }

        scroll.documentView = tv
        content.addSubview(scroll)
        self.tableView = tv
        self.panel = p
    }

    private func startTimer() {
        guard refreshTimer == nil else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refresh()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.refreshTimer = timer
    }

    private func stopTimerAndRestoreIfNeeded() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        if !userToggledCheckbox {
            FrameProfiler.shared.isEnabled = wasEnabledBeforeOpen
        }
    }

    func windowWillClose(_ notification: Notification) {
        stopTimerAndRestoreIfNeeded()
    }

    @objc private func toggleEnabled(_ sender: NSButton) {
        userToggledCheckbox = true
        FrameProfiler.shared.isEnabled = (sender.state == .on)
        refresh()
    }

    @objc private func copyStats(_ sender: Any?) {
        copyMarkdownToPasteboard()
    }

    private func screenRefreshRate() -> Double {
        let screen = NSApp.mainWindow?.screen ?? panel?.screen ?? NSScreen.main
        let hz = Double(screen?.maximumFramesPerSecond ?? 60)
        return hz > 0 ? hz : 60.0
    }

    func refresh() {
        let enabled = FrameProfiler.shared.isEnabled
        enableCheckbox?.state = enabled ? .on : .off
        self.rows = FrameProfiler.shared.copyStats()

        let fps = FrameProfiler.shared.profilerDisplayFPS()
        let hz = screenRefreshRate()
        let budgetMs = 1000.0 / hz
        statusField?.stringValue = String(
            format: "%.1f fps — budget %.2f ms @ %.0f Hz — %@ %d frames",
            fps,
            budgetMs,
            hz,
            L("fenêtre", "window"),
            FrameProfiler.ringFrames
        )
        tableView?.reloadData()
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row >= 0, row < rows.count, let tableColumn else { return nil }
        let s = rows[row]
        let ident = tableColumn.identifier
        let id = ident.rawValue

        let cell: NSTextField
        if let reused = tableView.makeView(withIdentifier: ident, owner: self) as? NSTextField {
            cell = reused
        } else {
            cell = NSTextField(labelWithString: "")
            cell.identifier = ident
            cell.lineBreakMode = .byTruncatingTail
        }

        let isTotal = (s.name == "frame.total")
        let isCadence = (s.name == "frame.period" || s.name == "dl.tick")
        let weight: NSFont.Weight = isTotal ? .semibold : .regular

        if id == "zone" {
            cell.font = NSFont.monospacedSystemFont(ofSize: 11, weight: weight)
            cell.alignment = .left
            cell.textColor = .labelColor
            cell.stringValue = s.name
            return cell
        }

        cell.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: weight)
        cell.alignment = .right

        if id == "samples" {
            cell.textColor = .secondaryLabelColor
            cell.stringValue = "\(s.samples)"
            return cell
        }

        let val: Double
        switch id {
        case "last": val = Double(s.lastMs)
        case "p50":  val = Double(s.p50Ms)
        case "p95":  val = Double(s.p95Ms)
        default:     val = Double(s.maxMs)
        }

        let budgetMs = 1000.0 / screenRefreshRate()
        let warnMs = isCadence ? budgetMs * 1.5 : budgetMs
        if (id == "p95" || id == "max") && val > warnMs {
            cell.textColor = .systemRed
        } else {
            cell.textColor = .labelColor
        }
        cell.stringValue = String(format: "%.3f", val)
        return cell
    }
}
