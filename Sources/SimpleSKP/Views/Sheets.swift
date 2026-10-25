import AppKit
import SimpleSKPCore
import SwiftUI

// MARK: - About

extension SketchUpAPI.Location {
    /// Where the framework comes from, for About and the self-test; nil for a `SIMPLESKP_SKETCHUP_SDK` override.
    var origin: String? {
        if isBundled { return L("livré dans l'app", "shipped in the app") }
        if let appVersion { return L("installé avec SketchUp \(appVersion)", "installed with SketchUp \(appVersion)") }
        if frameworkURL.path.contains("/Unity.app/") { return L("livré avec Unity", "shipped with Unity") }
        return nil
    }
}

struct AboutView: View {
    let close: () -> Void
    private let location = SketchUpAPI.locate()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 16) {
                Image(systemName: "cube")
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(Theme.accent.swiftUI)
                    .frame(width: 64, height: 64)
                    .background(RoundedRectangle(cornerRadius: 14).fill(Theme.background.swiftUI))
                    .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.white.opacity(0.08)))
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("SimpleSKP")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(Theme.text.swiftUI)
                        Chip(text: "v\(AppVersion.current.description)", tint: Theme.accent.swiftUI, filled: true)
                    }
                    Text(L("Visualiseur léger de fichiers SketchUp : ouvrir, tourner autour, passer de scène en scène.",
                           "Lightweight SketchUp file viewer: open, orbit, step from scene to scene."))
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textDim.swiftUI)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Rectangle().fill(Theme.separator.swiftUI).frame(height: 1)
            VStack(alignment: .leading, spacing: 6) {
                SectionHeader(L("Framework SketchUp", "SketchUp framework"))
                if let location {
                    Text(location.frameworkURL.path)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.text.swiftUI)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    if let origin = location.origin {
                        Text(origin)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textDim.swiftUI)
                    }
                } else {
                    Text(L("Framework SketchUp introuvable : réinstallez l'app", "SketchUp framework not found: reinstall the app"))
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(Theme.danger.swiftUI)
                }
            }
            Rectangle().fill(Theme.separator.swiftUI).frame(height: 1)
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("cie Adrien M — Compagnie Adrien M")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Theme.text.swiftUI)
                    Text(L("Licence publique générale GNU (GPL v3). Lit les fichiers avec le framework du SDK SketchUp de Trimble, livré dans l'app sous la licence du SDK SketchUp (pas GPL).",
                           "GNU General Public License (GPL v3). Reads files with Trimble's SketchUp SDK framework, shipped in the app under the SketchUp SDK licence (not GPL)."))
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.textFaint.swiftUI)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button("OK", action: close).keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 560)
        .background(Theme.panel.swiftUI)
    }
}

// MARK: - Shortcuts

struct ShortcutsView: View {
    let close: () -> Void

    static var groups: [(String, [(String, String)])] {
        [
            (L("Fichier & Présentation", "File & View"), [
                ("⌘O", L("Ouvrir un fichier .skp", "Open a .skp file")),
                ("⌘W", L("Fermer la fenêtre", "Close the window")),
                ("⇧⌘O", L("Ouvrir dans SketchUp", "Open in SketchUp")),
                ("⌘C", L("Copier l'image de la vue", "Copy the view as an image")),
                ("⌥⌘S", L("Barre latérale", "Sidebar")),
                ("⌘E", L("Arêtes", "Edges")),
                ("⌥⌘P", L("Perspective / Parallèle", "Perspective / Parallel")),
                ("⇧Z", L("Zoom étendu", "Zoom extents")),
                ("⌘[ / ⌘]", L("Scène précédente / suivante", "Previous / next scene")),
                ("⌘,", L("Réglages", "Settings")),
                ("⌘?", L("Aide", "Help")),
                ("⌘/", L("Raccourcis clavier", "Keyboard shortcuts")),
            ]),
            (L("Caméra", "Camera"), MainMenu.cameraViews.enumerated().map { ("⌘\($0.offset + 1)", $0.element.title) }),
            (L("Souris & trackpad", "Mouse & trackpad"), [
                (L("glisser", "drag"), L("Orbite autour du point visé", "Orbit around the point under the cursor")),
                (L("⇧-glisser, clic droit, bouton du milieu", "⇧-drag, right or middle drag"), L("Panoramique", "Pan")),
                (L("molette, pincement", "scroll, pinch"), L("Zoom vers le curseur", "Zoom towards the cursor")),
                (L("double-clic", "double-click"), L("Recentrer sur le point", "Recentre on the point")),
            ]),
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(L("Raccourcis clavier — SimpleSKP", "Keyboard Shortcuts — SimpleSKP"))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.text.swiftUI)
                Spacer()
                Button(L("Fermer", "Close"), action: close).keyboardShortcut(.defaultAction)
            }
            Rectangle().fill(Theme.separator.swiftUI).frame(height: 1)
            HStack(alignment: .top, spacing: 18) {
                ForEach(Self.groups, id: \.0) { title, items in
                    VStack(alignment: .leading, spacing: 7) {
                        SectionHeader(title)
                        ForEach(items, id: \.0) { key, label in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(key)
                                    .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(Theme.accent.swiftUI)
                                    .frame(width: 112, alignment: .leading)
                                Text(label)
                                    .font(.system(size: 11))
                                    .foregroundStyle(Theme.textDim.swiftUI)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(20)
        .frame(width: 900)
        .background(Theme.panel.swiftUI)
    }
}

// MARK: - Help

struct HelpView: View {
    let close: () -> Void

    private static var sections: [(String, String)] {
        [
            (L("Ce que fait SimpleSKP", "What SimpleSKP does"),
             L("Ouvre un fichier SketchUp (.skp) et le montre en 3D en quelques secondes : la vignette du fichier d'abord, puis le modèle. C'est un visualiseur : rien n'est modifié ni enregistré.",
               "Opens a SketchUp file (.skp) and shows it in 3D within seconds: the file's thumbnail first, then the model. It is a viewer: nothing is changed or saved.")),
            (L("Naviguer", "Navigating"),
             L("Glisser pour tourner autour du point visé ; ⇧-glisser, clic droit ou bouton du milieu pour se déplacer ; molette ou pincement pour zoomer vers le curseur ; double-clic pour recentrer. ⇧Z cadre tout le modèle, ⌘1 à ⌘7 donnent les vues standard, ⌥⌘P bascule perspective et parallèle, ⌘E montre ou cache les arêtes.",
               "Drag to orbit around the point under the cursor; ⇧-drag, right or middle drag to pan; scroll or pinch to zoom towards the cursor; double-click to recentre. ⇧Z frames the whole model, ⌘1 to ⌘7 give the standard views, ⌥⌘P switches perspective and parallel, ⌘E shows or hides edges.")),
            (L("Scènes et calques", "Scenes and layers"),
             L("La barre latérale (⌥⌘S) liste les scènes du fichier : un clic y amène la caméra et applique les calques masqués de la scène ; ⌘[ et ⌘] passent à la précédente ou à la suivante. Les cases des calques montrent ou cachent leur contenu aussitôt.",
               "The sidebar (⌥⌘S) lists the file's scenes: a click moves the camera there and applies the scene's hidden layers; ⌘[ and ⌘] step to the previous or next one. The layer checkboxes show or hide their content at once.")),
            (L("Le SDK SketchUp est dans l'app", "The SketchUp SDK is inside the app"),
             L("Le fichier est lu par le framework du SDK SketchUp, livré dans SimpleSKP.app : SketchUp n'a pas besoin d'être installé. Quand il l'est, « Ouvrir dans SketchUp » (⇧⌘O) y ouvre le fichier. Le chemin du framework est dans À propos.",
               "The file is read by the SketchUp SDK framework shipped inside SimpleSKP.app: SketchUp does not need to be installed. When it is, « Open in SketchUp » (⇧⌘O) opens the file there. The framework's path is in About.")),
            (L("Limites", "Limits"),
             L("Visualiseur seulement : pas d'édition, d'export, d'ombres, de styles ni de plans de section.",
               "Viewer only: no editing, export, shadows, styles or section planes.")),
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: "book.closed")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.accent.swiftUI)
                Text(L("Aide — SimpleSKP", "Help — SimpleSKP"))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.text.swiftUI)
                Spacer()
                Text(AppVersion.current.shortLabel)
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(Theme.textFaint.swiftUI)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(Theme.header.swiftUI)
            Rectangle().fill(Theme.separator.swiftUI).frame(height: 1)
            VStack(alignment: .leading, spacing: 16) {
                ForEach(Self.sections, id: \.0) { title, text in
                    VStack(alignment: .leading, spacing: 5) {
                        SectionHeader(title)
                        Text(text)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.text.swiftUI)
                            .lineSpacing(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                HStack {
                    TextButton(title: L("Raccourcis clavier (⌘/)", "Keyboard Shortcuts (⌘/)"), symbol: "command", compact: true) {
                        close()
                        ShortcutsWindowController.shared.show()
                    }
                    Spacer()
                    Button("OK", action: close).keyboardShortcut(.defaultAction)
                }
            }
            .padding(22)
        }
        .frame(width: 640)
        .background(Theme.panel.swiftUI)
    }
}

// MARK: - Settings

struct SettingsView: View {
    @State private var language = Localization.current

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(L("Langue", "Language"))
            Picker("", selection: $language) {
                ForEach(AppLanguage.allCases) { Text($0.label).tag($0) }
            }
            .labelsHidden()
            .frame(width: 200)
            .onChange(of: language) { _, value in Localization.current = value }
            Text(L("La nouvelle langue s'applique au prochain lancement de SimpleSKP.",
                   "The new language applies the next time SimpleSKP starts."))
                .font(.system(size: 11))
                .foregroundStyle(Theme.textDim.swiftUI)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(width: 380, alignment: .leading)
        .background(Theme.panel.swiftUI)
    }
}

// MARK: - Update

struct UpdateView: View {
    let updater: SimpleUpdater
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(L("Mises à jour — SimpleSKP", "Software Update — SimpleSKP"))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.text.swiftUI)
                Text(L("Version installée : v\(updater.currentVersion) (build \(updater.currentBuild))",
                       "Installed version: v\(updater.currentVersion) (build \(updater.currentBuild))"))
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(Theme.textDim.swiftUI)
            }
            Rectangle().fill(Theme.separator.swiftUI).frame(height: 1)
            state
            HStack {
                TextButton(title: L("Rechercher à nouveau", "Check Again"), symbol: "arrow.clockwise", compact: true) {
                    updater.checkForUpdates(silent: false)
                }
                Spacer()
                if case .updateAvailable(let release) = updater.state {
                    Button(L("Plus tard", "Later"), action: close)
                    TextButton(title: L("Mettre à jour et relancer", "Update & Relaunch"), symbol: "arrow.down.circle.fill", prominent: true) {
                        updater.downloadAndInstall(release)
                    }
                    .keyboardShortcut(.defaultAction)
                } else {
                    Button(L("Fermer", "Close"), action: close).keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 440)
        .background(Theme.panel.swiftUI)
    }

    @ViewBuilder
    private var state: some View {
        switch updater.state {
        case .idle, .checking:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(L("Recherche de mises à jour en cours…", "Checking for updates…"))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textDim.swiftUI)
            }
            .padding(.vertical, 14)
        case .upToDate(let version):
            HStack(spacing: 10) {
                Image(systemName: "checkmark.seal.fill").font(.system(size: 18)).foregroundStyle(Theme.alive.swiftUI)
                Text(L("SimpleSKP v\(version) est à jour.", "SimpleSKP v\(version) is up to date."))
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Theme.text.swiftUI)
            }
            .padding(.vertical, 10)
        case .updateAvailable(let release):
            VStack(alignment: .leading, spacing: 8) {
                Chip(text: L("NOUVELLE VERSION v\(release.version)", "NEW VERSION v\(release.version)"), tint: Theme.accent.swiftUI, filled: true)
                ScrollView {
                    Text(release.localizedNotes)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.text.swiftUI)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: 70, maxHeight: 140)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.04)))
            }
        case .downloading(let progress):
            VStack(alignment: .leading, spacing: 8) {
                Text(L("Téléchargement de la mise à jour…", "Downloading update…"))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.text.swiftUI)
                ProgressView(value: progress).tint(Theme.accent.swiftUI)
            }
            .padding(.vertical, 10)
        case .installing:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(L("Vérification de la signature et installation…", "Verifying code signature and installing…"))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.text.swiftUI)
            }
            .padding(.vertical, 10)
        case .failed(let message):
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 16)).foregroundStyle(Theme.warning.swiftUI)
                VStack(alignment: .leading, spacing: 3) {
                    Text(L("Impossible de vérifier ou d'installer la mise à jour", "Could not check or install update"))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.text.swiftUI)
                    Text(message)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textDim.swiftUI)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 6)
        }
    }
}
