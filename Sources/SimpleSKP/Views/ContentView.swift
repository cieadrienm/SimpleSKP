import AppKit
import SimpleSKPCore
import SimpleSKPViewport
import SwiftUI

/// The model window: sidebar (scenes, layers) | 3D viewport, over the status bar.
struct ContentView: View {
    let model: DocumentModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                if model.showSidebar {
                    SidebarView(model: model)
                        .frame(width: 220)
                    Rectangle().fill(Theme.separator.swiftUI).frame(width: 1)
                }
                viewport
            }
            StatusBar(model: model)
        }
        .background(Theme.background.swiftUI)
        .preferredColorScheme(.dark)
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter { $0.isFileURL && $0.pathExtension.lowercased() == "skp" }
            for url in files {
                NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, error in
                    if let error { NSApp.presentError(error) }
                }
            }
            return !files.isEmpty
        }
    }

    private var viewport: some View {
        ZStack {
            ViewportRepresentable(view: model.viewport)
            if let thumbnail = model.thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .scaledToFit()
                    .opacity(model.isReady ? 0 : (model.error == nil ? 0.6 : 1))
                    .animation(.easeOut(duration: 0.3), value: model.isReady)
                    .allowsHitTesting(false)
            }
            if let error = model.error {
                FailureBanner(message: error.localizedDescription, openInSketchUp: model.openInSketchUp)
            }
        }
        .clipped()
    }
}

/// The model's own `ViewportView`, created once by the document model.
struct ViewportRepresentable: NSViewRepresentable {
    let view: ViewportView

    func makeNSView(context: Context) -> ViewportView { view }
    func updateNSView(_ nsView: ViewportView, context: Context) {}
}

private struct FailureBanner: View {
    let message: String
    let openInSketchUp: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 15))
                .foregroundStyle(Theme.danger.swiftUI)
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(Theme.text.swiftUI)
                .fixedSize(horizontal: false, vertical: true)
            TextButton(title: L("Ouvrir dans SketchUp", "Open in SketchUp"), symbol: "arrow.up.forward.app", compact: true, action: openInSketchUp)
        }
        .padding(14)
        .frame(maxWidth: 560)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.panel.swiftUI))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.white.opacity(0.08)))
        .shadow(color: .black.opacity(0.4), radius: 12, y: 4)
        .padding(20)
    }
}

struct SidebarView: View {
    let model: DocumentModel

    var body: some View {
        ScrollView {
            // Not lazy: in a LazyVStack the first layer row was laid out but not drawn (seen in --snapshot).
            VStack(alignment: .leading, spacing: 2) {
                if let skp = model.skp {
                    if !skp.scenes.isEmpty {
                        SectionHeader(L("Scènes", "Scenes")) { Chip(text: "\(skp.scenes.count)") }
                        ForEach(skp.scenes.indices, id: \.self) { index in
                            sceneRow(skp.scenes[index].name, index: index)
                        }
                        Spacer().frame(height: 12)
                    }
                    SectionHeader(L("Calques", "Layers")) { Chip(text: "\(skp.layers.count)") }
                    ForEach(skp.layers.indices, id: \.self) { index in
                        Toggle(isOn: Binding(
                            get: { model.layerVisible.indices.contains(index) && model.layerVisible[index] },
                            set: { _ in model.toggleLayer(index) }
                        )) {
                            Text(skp.layers[index].name)
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.text.swiftUI)
                                .lineLimit(1)
                        }
                        .toggleStyle(.checkbox)
                        .padding(.vertical, 1.5)
                    }
                }
            }
            .padding(10)
        }
        .background(Theme.panel.swiftUI)
    }

    private func sceneRow(_ name: String, index: Int) -> some View {
        let selected = model.selectedScene == index
        return Button { model.selectScene(index) } label: {
            Text(name)
                .font(.system(size: 12, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? Theme.accent.swiftUI : Theme.text.swiftUI)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 5).fill(selected ? Theme.accent.swiftUI.opacity(0.12) : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct StatusBar: View {
    let model: DocumentModel

    var body: some View {
        HStack(spacing: 10) {
            if case .loading = model.state {
                ProgressView().controlSize(.mini).scaleEffect(0.7).frame(width: 10, height: 10)
            }
            Text(model.statusText)
                .foregroundStyle(model.error != nil ? Theme.danger.swiftUI : Theme.textDim.swiftUI)
                .lineLimit(1)
                .truncationMode(.middle)
            if let warning = model.skp?.loadWarning {
                Chip(text: warning, tint: Theme.warning.swiftUI).help(warning)
            }
            Spacer(minLength: 8)
            if let seconds = model.loadSeconds {
                Text(Format.seconds(seconds))
                Divider().frame(height: 12)
            }
            Button { HelpWindowController.shared.show() } label: { Text(L("? aide", "? help")) }
                .buttonStyle(.plain).help(L("Aide SimpleSKP (⌘?)", "SimpleSKP Help (⌘?)"))
            Button { ShortcutsWindowController.shared.show() } label: { Text(L("⌘/ raccourcis", "⌘/ shortcuts")) }
                .buttonStyle(.plain).help(L("Raccourcis clavier (⌘/)", "Keyboard Shortcuts (⌘/)"))
            Button { AboutWindowController.shared.show() } label: {
                Text(AppVersion.current.shortLabel).foregroundStyle(Theme.textDim.swiftUI)
            }
            .buttonStyle(.plain).help(L("À propos de SimpleSKP", "About SimpleSKP"))
            if let release = AppDelegate.updater?.availableRelease {
                Button { UpdateWindowController.shared.show() } label: {
                    Text(L("↑ MAJ v\(release.version)", "↑ Update v\(release.version)"))
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(Theme.background.swiftUI)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1.5)
                        .background(Capsule().fill(Theme.accent.swiftUI))
                }
                .buttonStyle(.plain)
            }
        }
        .font(.system(size: 10.5, design: .monospaced))
        .foregroundStyle(Theme.textFaint.swiftUI)
        .padding(.horizontal, 12)
        .frame(height: 26)
        .background(Theme.panel.swiftUI)
        .overlay(alignment: .top) { Rectangle().fill(Theme.separator.swiftUI).frame(height: 1) }
    }
}
