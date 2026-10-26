import AppKit
import SimpleSKPCore
import SimpleSKPViewport
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
    @State private var copiedVersion = false
    @State private var hoverWebsite = false

    private static var features: [(icon: String, title: String, subtitle: String)] {
        [
            ("cube.transparent",
             L("Lecture directe .skp, .dwg & .dxf", "Direct .skp, .dwg & .dxf reading"),
             L("Ouverture asynchrone SketchUp et AutoCAD, calibration métrique automatique, SDK C embarqué et fusion Metal par matériaux.",
               "Asynchronous SketchUp and AutoCAD loading, automatic metric calibration, embedded C SDK, and Metal material merging.")),
            ("sun.max.trianglebadge.exclamationmark",
             L("Rendu architectural doux", "Soft architectural rendering"),
             L("Matériaux PBR, soleil orientable à cascades d'ombres, contre-jour céleste et styles Maquette / Rayons X.",
               "PBR materials, orientable sun with cascaded shadows, sky fill light, and Clay / X-Ray styles.")),
            ("move.3d",
             L("4 modes de navigation", "4 navigation modes"),
             L("Orbite avec inertie, éditeur de jeu (clic droit + ZQSD), gestes trackpad, vol libre et Z / ⇧Z.",
               "Inertial orbit, game editor (right-click + WASD), trackpad gestures, free fly, and Z / ⇧Z.")),
            ("square.3.layers.3d",
             L("Scènes, calques & capture", "Scenes, layers & capture"),
             L("Passage de scène en scène, filtrage et mode solo des calques, copie et export PNG haute résolution.",
               "Scene stepping, layer filtering and solo mode, clipboard copy and high-resolution PNG export.")),
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            // Header
            HStack(alignment: .center, spacing: 18) {
                SKPHeroGraphic()
                    .frame(width: 72, height: 72)
                    .background(
                        RoundedRectangle(cornerRadius: 16)
                            .fill(
                                LinearGradient(
                                    colors: [Theme.panel.swiftUI, Theme.background.swiftUI],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .strokeBorder(Theme.accent.swiftUI.opacity(0.32), lineWidth: 1)
                    )
                    .shadow(color: Theme.accent.swiftUI.opacity(0.14), radius: 10)

                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("SimpleSKP")
                            .font(.system(size: 22, weight: .bold))
                            .foregroundStyle(Theme.text.swiftUI)

                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(AppVersion.current.cliLine, forType: .string)
                            copiedVersion = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copiedVersion = false }
                        } label: {
                            Chip(
                                text: copiedVersion ? L("copié", "copied") : "v\(AppVersion.current.description)",
                                tint: Theme.accent.swiftUI,
                                filled: true
                            )
                        }
                        .buttonStyle(.plain)
                        .help(L("Cliquer pour copier le numéro de version", "Click to copy version number"))
                    }

                    Text(L("Visualiseur 3D natif et léger de fichiers SketchUp (.skp) et AutoCAD (.dwg, .dxf) pour macOS.",
                           "Lightweight native 3D viewer for SketchUp (.skp) and AutoCAD (.dwg, .dxf) files on macOS."))
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.textDim.swiftUI)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 6) {
                        statusPill("SDK SketchUp C", color: location != nil ? Theme.alive.swiftUI : Theme.danger.swiftUI)
                        statusPill("Metal 3D PBR", color: Theme.accent.swiftUI)
                        statusPill("OSC :\(RemoteControlServer.shared.oscInPort)", color: Color(red: 0.78, green: 0.57, blue: 0.92))
                        statusPill("OSCQuery / MCP :\(RemoteControlServer.shared.httpPort)", color: Color(red: 0.36, green: 0.88, blue: 0.90))
                    }
                    .padding(.top, 2)
                }
            }

            Rectangle().fill(Theme.separator.swiftUI).frame(height: 1)

            // Points forts (2x2 grid)
            VStack(alignment: .leading, spacing: 8) {
                SectionHeader(L("Points forts", "Highlights"))
                Grid(alignment: .topLeading, horizontalSpacing: 10, verticalSpacing: 10) {
                    GridRow {
                        featureCard(Self.features[0])
                        featureCard(Self.features[1])
                    }
                    GridRow {
                        featureCard(Self.features[2])
                        featureCard(Self.features[3])
                    }
                }
            }

            // SketchUp SDK status
            VStack(alignment: .leading, spacing: 5) {
                SectionHeader(L("Framework SketchUp", "SketchUp framework"))
                if let location {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(location.frameworkURL.path)
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(Theme.text.swiftUI)
                            .textSelection(.enabled)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if let origin = location.origin {
                            Chip(text: origin, tint: Theme.alive.swiftUI)
                        }
                    }
                } else {
                    Text(L("Framework SketchUp introuvable : réinstaller l'application", "SketchUp framework not found: reinstall the application"))
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(Theme.danger.swiftUI)
                }
            }

            Rectangle().fill(Theme.separator.swiftUI).frame(height: 1)

            // Footer with clickable company link & actions
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Button {
                        if let url = URL(string: "https://adrien-m.net") {
                            NSWorkspace.shared.open(url)
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Text("Adrien Mondot · cie Adrien M")
                                .font(.system(size: 11.5, weight: .semibold))
                                .foregroundStyle(hoverWebsite ? Theme.text.swiftUI : Theme.accent.swiftUI)
                            Text("— adrien-m.net")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(hoverWebsite ? Theme.accent.swiftUI : Theme.textDim.swiftUI)
                            Image(systemName: "arrow.up.right.square")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(Theme.accent.swiftUI)
                        }
                    }
                    .buttonStyle(.plain)
                    .onHover { hoverWebsite = $0 }
                    .help(L("Ouvrir https://adrien-m.net dans le navigateur", "Open https://adrien-m.net in browser"))

                    Text(L("SDK C SketchUp (Trimble) embarqué sous licence SDK SketchUp · Code SimpleSKP sous licence GPL v3.",
                           "SketchUp C SDK (Trimble) embedded under SketchUp SDK licence · SimpleSKP code under GPL v3."))
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textFaint.swiftUI)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()

                TextButton(title: L("Mises à jour…", "Updates…"), symbol: "arrow.triangle.2.circlepath", compact: true) {
                    close()
                    AppDelegate.updater?.checkForUpdates(silent: false)
                    UpdateWindowController.shared.show()
                }
                TextButton(title: L("Guide (⌘?)", "Guide (⌘?)"), symbol: "book.closed", compact: true) {
                    close()
                    HelpWindowController.shared.show()
                }
                TextButton(title: "OK", prominent: true, compact: true, action: close)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 650)
        .background(Theme.panel.swiftUI)
    }

    private func statusPill(_ label: String, color: Color) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(Theme.textDim.swiftUI)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            Capsule()
                .fill(Color.white.opacity(0.04))
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.07), lineWidth: 1))
        )
    }

    private func featureCard(_ item: (icon: String, title: String, subtitle: String)) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: item.icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.accent.swiftUI)
                .frame(width: 24, height: 24)
                .background(RoundedRectangle(cornerRadius: 6).fill(Theme.accent.swiftUI.opacity(0.12)))
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Theme.text.swiftUI)
                Text(item.subtitle)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.textDim.swiftUI)
                    .lineSpacing(1.5)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(Color.white.opacity(0.03))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.white.opacity(0.06), lineWidth: 1))
        )
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
                ("⇧⌘E", L("Exporter l'image en PNG…", "Export PNG image…")),
                ("⌥⌘E", L("Exporter la vue en PDF vectoriel…", "Export vector PDF…")),
                ("⌥⌘S", L("Barre latérale (animée)", "Sidebar (animated)")),
                ("⌘E", L("Arêtes", "Edges")),
                ("⌥⌘G", L("Grille au sol et axes XYZ", "Ground grid and XYZ axes")),
                ("⌥⌘P", L("Perspective / Parallèle", "Perspective / Parallel")),
                ("⌥⌘O", L("Ombres portées", "Cast shadows")),
                ("⌥⌘L", L("Éclairage Soleil / Ponctuel", "Sun / Point lighting")),
                ("⌥⌘A", L("Occlusion ambiante SSAO", "Ambient occlusion SSAO")),
                ("Z", L("Réinitialiser la vue initiale", "Reset to initial view")),
                ("⇧Z", L("Zoom étendu sur le modèle", "Zoom extents to fit model")),
                ("⌥⌘F", L("Mode vol libre (Échap pour sortir)", "Free fly mode (Esc to exit)")),
                ("⌘[ / ⌘]", L("Scène précédente / suivante", "Previous / next scene")),
                ("⇧⌘[ / ⇧⌘]", L("Scène précédente / suivante (10× plus lent)", "Previous / next scene (10× slower)")),
                ("⌘,", L("Réglages", "Settings")),
                ("⌘?", L("Guide d'utilisation", "User guide")),
                ("⌘/", L("Raccourcis clavier", "Keyboard shortcuts")),
            ]),
            (L("Caméra", "Camera"), MainMenu.cameraViews.enumerated().map { ("⌘\($0.offset + 1)", $0.element.title) }),
            (L("Souris & trackpad", "Mouse & trackpad"), [
                (L("glisser", "drag"), L("Orbite autour du point visé, avec inertie", "Orbit around the point under the cursor, with inertia")),
                (L("⇧-glisser, bouton du milieu", "⇧-drag, middle drag"), L("Panoramique dans le plan écran", "Pan in the screen plane")),
                (L("molette, pincement", "wheel, pinch"), L("Zoom vers le point sous le curseur", "Zoom towards the cursor")),
                (L("double-clic", "double-click"), L("Recentrer et approcher le point visé", "Recentre on the point and move closer")),
                (L("deux doigts", "two fingers"), L("Orbite (ou zoom, voir Réglages)", "Orbit (or zoom, see Settings)")),
                (L("⌥ + deux doigts", "⌥ + two fingers"), L("Panoramique", "Pan")),
                (L("rotation à deux doigts", "two-finger rotate"), L("Tourner autour de la verticale", "Turn around the vertical")),
            ]),
            (L("Déplacement (touches physiques)", "Moving (physical keys)"), [
                (L("clic droit tenu", "hold right button"), L("Regarder autour (mode éditeur de jeu)", "Look around (game editor mode)")),
                (L("Z Q S D / W A S D", "W A S D / Z Q S D"), L("Avancer, gauche, reculer, droite", "Forward, left, back, right")),
                (L("flèches", "arrows"), L("Avancer, reculer, pas de côté", "Forward, back, sideways")),
                (L("espace, E / C", "space, E / C"), L("Monter / descendre verticalement", "Move up / down vertically")),
                ("⇧", L("Aller quatre fois plus vite", "Move four times faster")),
                (L("molette + clic droit", "wheel + right button"), L("Ajuster la vitesse de déplacement", "Adjust movement speed")),
            ]),
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "command")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.accent.swiftUI)
                Text(L("Raccourcis clavier — SimpleSKP", "Keyboard Shortcuts — SimpleSKP"))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.text.swiftUI)
                Spacer()
                TextButton(title: L("Fermer", "Close"), prominent: true, compact: true, action: close)
                    .keyboardShortcut(.defaultAction)
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
                                    .frame(width: 128, alignment: .leading)
                                    .fixedSize(horizontal: false, vertical: true)
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
        .frame(width: 1120)
        .background(Theme.panel.swiftUI)
    }
}

// MARK: - Help (2-column manual with sidebar, G62)

struct HelpView: View {
    let close: () -> Void

    enum Section: String, CaseIterable, Identifiable {
        case overview
        case navigation
        case rendering
        case scenesAndLayers
        case oscAndMCP
        case sdkAndFiles

        var id: String { rawValue }

        var title: String {
            switch self {
            case .overview: return L("Vue d'ensemble", "Overview")
            case .navigation: return L("Navigation & Caméra", "Navigation & Camera")
            case .rendering: return L("Rendu & Éclairage", "Rendering & Lighting")
            case .scenesAndLayers: return L("Scènes & Calques", "Scenes & Layers")
            case .oscAndMCP: return L("OSC, OSCScore & MCP", "OSC, OSCScore & MCP")
            case .sdkAndFiles: return L("SDK & Fichiers", "SDK & Files")
            }
        }

        var icon: String {
            switch self {
            case .overview: return "cube"
            case .navigation: return "move.3d"
            case .rendering: return "sun.max"
            case .scenesAndLayers: return "square.3.layers.3d"
            case .oscAndMCP: return "dot.radiowaves.left.and.right"
            case .sdkAndFiles: return "shippingbox"
            }
        }
    }

    @State private var selected: Section = .overview

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 10) {
                Image(systemName: "book.closed.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.accent.swiftUI)
                Text(L("Guide d'utilisation — SimpleSKP", "User Guide — SimpleSKP"))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.text.swiftUI)
                Spacer()
                TextButton(title: L("Raccourcis clavier (⌘/)", "Keyboard Shortcuts (⌘/)"), symbol: "command", compact: true) {
                    close()
                    ShortcutsWindowController.shared.show()
                }
                Text(AppVersion.current.shortLabel)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.textFaint.swiftUI)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(Theme.header.swiftUI)

            Rectangle().fill(Theme.separator.swiftUI).frame(height: 1)

            // 2-column body
            HStack(spacing: 0) {
                // Sidebar
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Section.allCases) { section in
                        Button {
                            selected = section
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: section.icon)
                                    .font(.system(size: 11.5, weight: .medium))
                                    .foregroundStyle(selected == section ? Theme.accent.swiftUI : Theme.textDim.swiftUI)
                                    .frame(width: 16)
                                Text(section.title)
                                    .font(.system(size: 12, weight: selected == section ? .semibold : .regular))
                                    .foregroundStyle(selected == section ? Theme.text.swiftUI : Theme.textDim.swiftUI)
                                Spacer()
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(selected == section ? Theme.accent.swiftUI.opacity(0.15) : Color.clear)
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer()
                }
                .padding(10)
                .frame(width: 195)
                .background(Theme.background.swiftUI.opacity(0.55))

                Rectangle().fill(Theme.separator.swiftUI).frame(width: 1)

                // Detail pane
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        sectionContent(selected)
                    }
                    .padding(22)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            Rectangle().fill(Theme.separator.swiftUI).frame(height: 1)

            // Footer
            HStack {
                Text(L("Visualiseur pur : aucun fichier .skp n'est jamais modifié ni enregistré.",
                       "Pure viewer: no .skp file is ever modified or saved."))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textFaint.swiftUI)
                Spacer()
                TextButton(title: L("Fermer", "Close"), prominent: true, compact: true, action: close)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background(Theme.header.swiftUI)
        }
        .frame(width: 760, height: 520)
        .background(Theme.panel.swiftUI)
    }

    @ViewBuilder
    private func sectionContent(_ section: Section) -> some View {
        switch section {
        case .overview:
            heading(L("Ouvrir et inspecter un modèle SketchUp ou AutoCAD", "Opening and inspecting a SketchUp or AutoCAD model"))
            paragraph(L("SimpleSKP ouvre directement les fichiers SketchUp (.skp) et AutoCAD (.dwg, .dxf) en lecture seule. Les plans et modèles CAD bénéficient d'une calibration métrique automatique, d'un recentrage des coordonnées géodésiques et d'un cadrage automatique en vue de dessus pour les plans 2D.",
                        "SimpleSKP opens SketchUp (.skp) and AutoCAD (.dwg, .dxf) files directly in read-only mode. CAD plans and models feature automatic metric unit calibration, geodetic origin recentering, and automatic top-view framing for 2D plans."))
            step(1, L("Ouvrir un fichier", "Open a file"),
                 L("Double-cliquer un fichier .skp, .dwg ou .dxf dans le Finder, le glisser dans la fenêtre ou utiliser ⌘O.",
                   "Double-click a .skp, .dwg, or .dxf file in Finder, drag it into the window, or press ⌘O."))
            step(2, L("Choisir l'angle et le style", "Choose angle and style"),
                 L("Utiliser la barre d'outils supérieure pour basculer entre les vues standard (Iso, Dessus, Face, Droite…), la projection (Perspective / Parallèle) et les styles de rendu (PBR, Blanc, Rayons X, Filaire).",
                   "Use the top toolbar to switch between standard views (Iso, Top, Front, Right…), projection (Perspective / Parallel), and shading styles (PBR, Clay, X-Ray, Wireframe)."))
            step(3, L("Capturer ou ouvrir dans SketchUp", "Capture or open in SketchUp"),
                 L("Copier une image haute définition dans le presse-papiers (⌘C), l'exporter en PNG (⇧⌘E) ou envoyer le modèle vers SketchUp (⇧⌘O).",
                   "Copy a high-definition image to the clipboard (⌘C), export it as PNG (⇧⌘E), or send the model to SketchUp (⇧⌘O)."))
            callout(icon: "checkmark.shield.fill",
                    L("Garantie d'intégrité : SimpleSKP est un visualiseur strict. Les fichiers .skp ouverts ne sont jamais réécrits ni verrouillés.",
                      "Integrity guarantee: SimpleSKP is a strict viewer. Opened .skp files are never rewritten or locked."))

        case .navigation:
            heading(L("Quatre modes de navigation complémentaires", "Four complementary navigation modes"))
            paragraph(L("Tous les modes sont actifs simultanément sans changer d'outil :",
                        "All modes are active simultaneously without switching tools:"))
            bullet(L("Orbite & Panoramique (souris)", "Orbit & Pan (mouse)"),
                   L("Glisser avec le bouton gauche fait tourner la caméra autour du point visé avec inertie. ⇧-glisser ou bouton du milieu déplace la vue dans le plan écran. La molette zoome vers le curseur ; un double-clic recentre et rapproche.",
                     "Left-dragging orbits around the point under the cursor with inertia. ⇧-drag or middle-drag pans in the screen plane. The scroll wheel zooms towards the cursor; double-clicking recentres and moves closer."))
            bullet(L("Touches Z et ⇧Z", "Z and ⇧Z keys"),
                   L("Appuyer sur Z réinitialise la caméra à la vue d'ouverture du fichier. Appuyer sur ⇧Z cadre l'ensemble des objets visibles (Zoom étendu).",
                     "Pressing Z resets the camera to the file's initial view. Pressing ⇧Z frames all visible geometry (Zoom Extents)."))
            bullet(L("Éditeur de jeu (clic droit + clavier)", "Game editor (right-click + keyboard)"),
                   L("Maintenir le clic droit pour orienter le regard et utiliser les touches physiques ZQSD (WASD en QWERTY) ou les flèches pour avancer et se décaler, Espace/E pour monter, C pour descendre et ⇧ pour aller quatre fois plus vite.",
                     "Hold the right mouse button to look around and use physical WASD (ZQSD on AZERTY) or arrow keys to move and strafe, Space/E to go up, C to go down, and ⇧ to move four times faster."))
            bullet(L("Trackpad & Mode vol libre (⌥⌘F)", "Trackpad & Free fly mode (⌥⌘F)"),
                   L("Deux doigts pour l'orbite (ou le zoom selon Réglages), ⌥ + deux doigts pour le panoramique, pincer pour zoomer. Le mode Vol libre (⌥⌘F) permet d'orienter le regard sans maintenir de bouton (Échap pour quitter).",
                     "Two fingers to orbit (or zoom per Settings), ⌥ + two fingers to pan, pinch to zoom. Free fly mode (⌥⌘F) looks around without holding a mouse button (Esc to exit)."))

        case .rendering:
            heading(L("Styles de rendu, soleil et fond de scène", "Shading styles, sun and backdrop"))
            paragraph(L("La barre d'outils supérieure permet d'adapter l'apparence du modèle en temps réel :",
                        "The top toolbar lets you tailor the model's appearance in real time:"))
            bullet(L("PBR (Texturé réaliste doux)", "PBR (Soft realistic textured)"),
                   L("Affiche les couleurs et textures du modèle avec éclairage physique, soleil directionnel, contre-jour céleste et exposition HDR équilibrée.",
                     "Displays model colors and textures with physically based lighting, directional sun, sky fill counter-light, and balanced HDR exposure."))
            bullet(L("Blanc (Maquette architecturale)", "Clay (Architectural white model)"),
                   L("Remplace temporairement tous les matériaux opaques par un plâtre blanc chaud mat pour étudier les volumes et la lumière sans distraction.",
                     "Temporarily replaces all opaque materials with warm matte white plaster to study volumes and light without distraction."))
            bullet(L("Rayons X & Filaire", "X-Ray & Wireframe"),
                   L("Rayons X rend les faces semi-transparentes pour inspecter l'intérieur d'une scénographie ; Filaire n'affiche que les arêtes vectorielles.",
                     "X-Ray makes faces semi-transparent to inspect interior layouts; Wireframe displays only vector edges."))
            bullet(L("Éclairage Soleil ou Ponctuel (⌥⌘L)", "Sun or Point lighting (⌥⌘L)"),
                   L("Basculez entre un éclairage directionnel solaire (azimut/hauteur + ombres) et un éclairage ponctuel omnidirectionnel. En mode Ponctuel, SimpleSKP utilise automatiquement les projecteurs/lumières détectés dans la scène .skp, ou crée par défaut une lumière au centre de la géométrie dont vous pouvez ajuster les coordonnées X, Y, Z et l'intensité.",
                     "Switch between directional sun lighting (azimuth/elevation + shadows) and omnidirectional point lighting. In Point mode, SimpleSKP automatically uses light fixtures detected in the .skp scene, or creates a default light at the center of the geometry with adjustable X, Y, Z coordinates and intensity."))
            bullet(L("Importance SSAO, Grille & Couleur du fond", "SSAO strength, Grid & Background color"),
                   L("Ajustez l'importance de l'occlusion ambiante SSAO (0 % à 200 %, ⌥⌘A), affichez la grille et les axes XYZ (⌥⌘G), et choisissez le fond parmi Ciel architectural, Studio sombre, Papier chaud ou n'importe quelle couleur personnalisée.",
                     "Adjust SSAO ambient occlusion strength (0% to 200%, ⌥⌘A), toggle the ground grid and XYZ axes (⌥⌘G), and pick the backdrop from Architectural Sky, Dark Studio, Warm Paper, or any custom color."))

        case .scenesAndLayers:
            heading(L("Scènes, calques et inspecteur de modèle", "Scenes, layers and model inspector"))
            paragraph(L("La barre latérale (⌥⌘S) regroupe l'organisation du modèle SketchUp :",
                        "The sidebar (⌥⌘S) groups the SketchUp model's structure:"))
            bullet(L("Scènes (⌘[ et ⌘])", "Scenes (⌘[ and ⌘])"),
                   L("Cliquer sur une scène déplace la caméra avec une transition fluide et applique la visibilité des calques enregistrée dans la scène. Le sélecteur de scène est aussi accessible directement dans la barre d'outils.",
                     "Clicking a scene smoothly glides the camera there and applies the scene's saved layer visibility. The scene selector is also directly available in the top toolbar."))
            bullet(L("Calques : filtre, Tout / Aucun et Solo", "Layers: filter, All / None and Solo"),
                   L("Sur les modèles complexes, le champ de recherche filtre les calques par nom. Les boutons Tout / Aucun basculent l'ensemble des calques, et le bouton Solo (au survol) isole instantanément un calque.",
                     "On complex models, the search field filters layers by name. All / None buttons toggle every layer at once, and the Solo button (on hover) isolates a single layer immediately."))
            bullet(L("Modèle & Matériaux", "Model & Materials"),
                   L("Le bas de la barre latérale résume les dimensions de la boîte englobante visible, le nombre de faces, d'arêtes, de composants et l'aperçu des matériaux.",
                     "The bottom of the sidebar summarizes visible bounding-box dimensions, face/edge/component counts, and material swatches."))

        case .oscAndMCP:
            heading(L("Pilotage OSC, découverte OSCScore & serveur MCP", "OSC control, OSCScore discovery & MCP server"))
            paragraph(L("SimpleSKP s'annonce automatiquement sur le réseau local en Bonjour (_oscjson._tcp. sur le port 17950 et _osc._udp. sur le port 9150). Il apparaît immédiatement dans l'explorateur OSCQuery d'OSCScore avec les plages de coordonnées adaptées à la maquette ouverte.",
                        "SimpleSKP automatically advertises itself on the local network via Bonjour (_oscjson._tcp. on port 17950 and _osc._udp. on port 9150). It immediately appears in OSCScore's OSCQuery browser with coordinate ranges tailored to the open model."))
            bullet(L("Caméra dans OSCScore (UDP :9150, retour :9151)", "Camera in OSCScore (UDP :9150, feedback :9151)"),
                   L("/simpleskp/camera/position <x y z> (m), /simpleskp/camera/target <tx ty tz> (m), /simpleskp/camera/orientation <yaw pitch> (°), /simpleskp/camera/fov <10..120> (°), /simpleskp/camera/focal <5..135> (mm), /simpleskp/camera/exposure <-3..3> (EV), /simpleskp/camera/eye_height [1.70]. Lorsque le retour OSC est actif, déplacer la caméra à la souris émet sa trajectoire vers OSCScore.",
                     "/simpleskp/camera/position <x y z> (m), /simpleskp/camera/target <tx ty tz> (m), /simpleskp/camera/orientation <yaw pitch> (°), /simpleskp/camera/fov <10..120> (°), /simpleskp/camera/focal <5..135> (mm), /simpleskp/camera/exposure <-3..3> (EV), /simpleskp/camera/eye_height [1.70]. When OSC feedback is enabled, moving the camera with the mouse streams its trajectory to OSCScore."))
            bullet(L("Scènes, styles et éclairage en OSC", "Scenes, styles and lighting over OSC"),
                   L("/simpleskp/scene/index <i>, /simpleskp/scene/name <s>, /simpleskp/scene/next, /simpleskp/style <textured|clay|xray|wireframe>, /simpleskp/lighting/mode <sun|point>, /simpleskp/sun/angles <az el>, /simpleskp/light/position <x y z>, /simpleskp/light/intensity <0..3>.",
                     "/simpleskp/scene/index <i>, /simpleskp/scene/name <s>, /simpleskp/scene/next, /simpleskp/style <textured|clay|xray|wireframe>, /simpleskp/lighting/mode <sun|point>, /simpleskp/sun/angles <az el>, /simpleskp/light/position <x y z>, /simpleskp/light/intensity <0..3>."))
            bullet(L("API HTTP /v1 & Serveur MCP (simpleskp-mcp)", "HTTP /v1 API & MCP Server (simpleskp-mcp)"),
                   L("Le binaire simpleskp-mcp (livré dans SimpleSKP.app/Contents/MacOS/simpleskp-mcp) expose les outils simpleskp_state, simpleskp_open, simpleskp_camera, simpleskp_scene, simpleskp_layers, simpleskp_rendering et simpleskp_snapshot via l'API HTTP locale 127.0.0.1:17950/v1.",
                     "The simpleskp-mcp binary (bundled in SimpleSKP.app/Contents/MacOS/simpleskp-mcp) exposes simpleskp_state, simpleskp_open, simpleskp_camera, simpleskp_scene, simpleskp_layers, simpleskp_rendering, and simpleskp_snapshot tools via the local HTTP API at 127.0.0.1:17950/v1."))

        case .sdkAndFiles:
            heading(L("SDK SketchUp embarqué et interopérabilité", "Embedded SketchUp SDK and interoperability"))
            paragraph(L("SimpleSKP embarque directement SketchUpAPI.framework dans son paquet d'application : SketchUp Pro n'a pas besoin d'être installé sur le Mac pour ouvrir des fichiers .skp.",
                        "SimpleSKP embeds SketchUpAPI.framework directly inside its application bundle: SketchUp Pro does not need to be installed on the Mac to open .skp files."))
            bullet(L("Ouvrir dans SketchUp (⇧⌘O)", "Open in SketchUp (⇧⌘O)"),
                   L("Si une version de SketchUp est présente sur le Mac, le bouton SketchUp de la barre d'outils et le raccourci ⇧⌘O transmettent immédiatement le fichier courant à SketchUp pour l'éditer.",
                     "If a version of SketchUp is installed on the Mac, the toolbar's SketchUp button and ⇧⌘O hand the current file over to SketchUp for editing."))
            callout(icon: "info.circle.fill",
                    L("Licences : Le framework du SDK C de SketchUp (Trimble) est embarqué sous la licence du SDK SketchUp ; le code source de SimpleSKP est distribué sous licence GPL v3.",
                      "Licences: The SketchUp C SDK framework (Trimble) is embedded under the SketchUp SDK licence; SimpleSKP's source code is distributed under GPL v3."))
        }
    }

    private func heading(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 15, weight: .bold))
            .foregroundStyle(Theme.text.swiftUI)
    }

    private func paragraph(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(Theme.textDim.swiftUI)
            .lineSpacing(2.5)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func step(_ number: Int, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(number)")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(Theme.background.swiftUI)
                .frame(width: 20, height: 20)
                .background(Circle().fill(Theme.accent.swiftUI))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.text.swiftUI)
                Text(detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textDim.swiftUI)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func bullet(_ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(Theme.accent.swiftUI)
                .frame(width: 5, height: 5)
                .padding(.top, 6)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.text.swiftUI)
                Text(detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textDim.swiftUI)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func callout(icon: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundStyle(Theme.accent.swiftUI)
                .padding(.top, 1)
            Text(text)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.text.swiftUI)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(Theme.accent.swiftUI.opacity(0.08))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.accent.swiftUI.opacity(0.25), lineWidth: 1))
        )
    }
}

// MARK: - Settings (G63)

struct SettingsView: View {
    @State private var language = Localization.current
    @State private var twoFingerScrollZooms = Preferences.twoFingerScrollZooms
    @State private var showsEdges = Preferences.showsEdges
    @State private var shadowsEnabled = Preferences.shadowsEnabled
    @State private var ambientOcclusionEnabled = Preferences.ambientOcclusionEnabled
    @State private var ambientOcclusionIntensity = Preferences.ambientOcclusionIntensity
    @State private var showsGrid = Preferences.showsGrid
    @State private var backdropStyle = Preferences.backdropStyle
    @State private var customBackdropColor = Preferences.customBackdropColor
    @State private var oscFeedbackEnabled = Preferences.oscFeedbackEnabled
    @State private var autoCheckUpdates = AppDelegate.updater?.autoCheckOnLaunch ?? true

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(L("Général", "General"))
            FieldRow(label: L("Langue", "Language"), width: 150) {
                Picker("", selection: $language) {
                    ForEach(AppLanguage.allCases) { Text($0.label).tag($0) }
                }
                .labelsHidden()
                .frame(width: 190)
                .onChange(of: language) { _, value in Localization.current = value }
            }
            Text(L("La nouvelle langue s'applique au prochain lancement de SimpleSKP.",
                   "The new language applies the next time SimpleSKP starts."))
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.textFaint.swiftUI)

            HStack(spacing: 10) {
                Toggle(isOn: $autoCheckUpdates) {
                    Text(L("Vérifier les mises à jour au lancement", "Check for updates on launch"))
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.text.swiftUI)
                }
                .toggleStyle(.checkbox)
                .onChange(of: autoCheckUpdates) { _, value in
                    AppDelegate.updater?.autoCheckOnLaunch = value
                }
                Spacer()
                TextButton(title: L("Rechercher…", "Check Now…"), symbol: "arrow.triangle.2.circlepath", compact: true) {
                    AppDelegate.updater?.checkForUpdates(silent: false)
                    UpdateWindowController.shared.show()
                }
            }

            Rectangle().fill(Theme.separator.swiftUI).frame(height: 1)

            SectionHeader(L("Navigation", "Navigation"))
            FieldRow(label: L("Deux doigts (trackpad)", "Two fingers (trackpad)"), width: 150) {
                Picker("", selection: $twoFingerScrollZooms) {
                    Text(L("Orbite", "Orbit")).tag(false)
                    Text(L("Zoom", "Zoom")).tag(true)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 190)
                .onChange(of: twoFingerScrollZooms) { _, value in Preferences.twoFingerScrollZooms = value }
            }

            Rectangle().fill(Theme.separator.swiftUI).frame(height: 1)

            SectionHeader(L("Affichage par défaut (nouvelles fenêtres)", "Default display (new windows)"))
            FieldRow(label: L("Fond de scène", "Backdrop"), width: 150) {
                HStack(spacing: 8) {
                    Picker("", selection: $backdropStyle) {
                        Text(L("Ciel", "Sky")).tag(BackdropStyle.architecturalSky)
                        Text(L("Studio", "Studio")).tag(BackdropStyle.studioDark)
                        Text(L("Papier", "Paper")).tag(BackdropStyle.warmPaper)
                        Text(L("Couleur", "Color")).tag(BackdropStyle.customColor)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 220)
                    .onChange(of: backdropStyle) { _, value in Preferences.backdropStyle = value }

                    ColorPicker(
                        "",
                        selection: Binding(
                            get: {
                                Color(.sRGB, red: Double(customBackdropColor.x), green: Double(customBackdropColor.y), blue: Double(customBackdropColor.z), opacity: 1.0)
                            },
                            set: { newColor in
                                if let cg = NSColor(newColor).usingColorSpace(.sRGB) {
                                    let rgb = SIMD3<Float>(Float(cg.redComponent), Float(cg.greenComponent), Float(cg.blueComponent))
                                    customBackdropColor = rgb
                                    backdropStyle = .customColor
                                    Preferences.customBackdropColor = rgb
                                    Preferences.backdropStyle = .customColor
                                }
                            }
                        ),
                        supportsOpacity: false
                    )
                    .labelsHidden()
                }
            }

            FieldRow(label: L("Importance SSAO", "SSAO strength"), width: 150) {
                HStack(spacing: 8) {
                    Slider(
                        value: Binding(
                            get: { Double(ambientOcclusionIntensity) },
                            set: { newValue in
                                ambientOcclusionIntensity = Float(newValue)
                                Preferences.ambientOcclusionIntensity = Float(newValue)
                            }
                        ),
                        in: 0.0...2.0
                    )
                    .frame(width: 180)
                    .tint(Theme.accent.swiftUI)
                    Text("\(Int((ambientOcclusionIntensity * 100).rounded())) %")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.text.swiftUI)
                        .frame(width: 48, alignment: .trailing)
                }
            }

            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
                GridRow {
                    Toggle(L("Afficher les arêtes (⌘E)", "Show edges (⌘E)"), isOn: $showsEdges)
                        .toggleStyle(.checkbox)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.text.swiftUI)
                        .onChange(of: showsEdges) { _, value in Preferences.showsEdges = value }
                    Toggle(L("Ombres portées (⌥⌘O)", "Cast shadows (⌥⌘O)"), isOn: $shadowsEnabled)
                        .toggleStyle(.checkbox)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.text.swiftUI)
                        .onChange(of: shadowsEnabled) { _, value in Preferences.shadowsEnabled = value }
                }
                GridRow {
                    Toggle(L("Occlusion ambiante (⌥⌘A)", "Ambient occlusion (⌥⌘A)"), isOn: $ambientOcclusionEnabled)
                        .toggleStyle(.checkbox)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.text.swiftUI)
                        .onChange(of: ambientOcclusionEnabled) { _, value in Preferences.ambientOcclusionEnabled = value }
                    Toggle(L("Grille et axes XYZ (⌥⌘G)", "Grid and XYZ axes (⌥⌘G)"), isOn: $showsGrid)
                        .toggleStyle(.checkbox)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.text.swiftUI)
                        .onChange(of: showsGrid) { _, value in Preferences.showsGrid = value }
                }
            }

            Rectangle().fill(Theme.separator.swiftUI).frame(height: 1)

            SectionHeader(L("OSC, OSCScore & MCP", "OSC, OSCScore & MCP"))
            HStack(spacing: 12) {
                Toggle(L("Retour OSC vers OSCScore (:\(Preferences.oscOutPort))", "OSC feedback to OSCScore (:\(Preferences.oscOutPort))"), isOn: $oscFeedbackEnabled)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.text.swiftUI)
                    .onChange(of: oscFeedbackEnabled) { _, value in Preferences.oscFeedbackEnabled = value }
                Spacer()
                Text("OSC UDP :\(RemoteControlServer.shared.oscInPort) · HTTP/OSCQuery :\(RemoteControlServer.shared.httpPort)")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(Theme.textDim.swiftUI)
            }

            Rectangle().fill(Theme.separator.swiftUI).frame(height: 1)

            SectionHeader(L("Confidentialité", "Privacy"))
            Text(L("SimpleSKP fonctionne intégralement en local : écoute OSC UDP (port \(RemoteControlServer.shared.oscInPort)), retour OSC (\(Preferences.oscOutHost):\(Preferences.oscOutPort)), API HTTP / OSCQuery / MCP (port \(RemoteControlServer.shared.httpPort)) et annonce Bonjour (_oscjson._tcp). La seule connexion externe concerne la vérification des mises à jour sur GitHub Releases.",
                   "SimpleSKP runs locally: UDP OSC input (port \(RemoteControlServer.shared.oscInPort)), OSC feedback (\(Preferences.oscOutHost):\(Preferences.oscOutPort)), HTTP / OSCQuery / MCP API (port \(RemoteControlServer.shared.httpPort)) and Bonjour advertisement (_oscjson._tcp). The only external connection checks GitHub Releases for updates."))
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.textDim.swiftUI)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(width: 485, alignment: .leading)
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
