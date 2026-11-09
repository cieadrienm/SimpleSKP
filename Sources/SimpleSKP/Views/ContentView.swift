import AppKit
import simd
import SimpleSKPCore
import SimpleSKPViewport
import SwiftUI

/// The model window: top toolbar, sidebar (scenes, layers, materials) | 3D viewport with HUD, over the status bar.
struct ContentView: View {
    let model: DocumentModel

    var body: some View {
        VStack(spacing: 0) {
            TopBar(model: model)
            HStack(spacing: 0) {
                if model.showSidebar {
                    HStack(spacing: 0) {
                        SidebarView(model: model)
                            .frame(width: 244)
                        Rectangle().fill(Theme.separator.swiftUI).frame(width: 1)
                    }
                    .transition(.move(edge: .leading).combined(with: .opacity))
                }
                viewport
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if model.showProjectorInspector {
                    HStack(spacing: 0) {
                        Rectangle().fill(Theme.separator.swiftUI).frame(width: 1)
                        ProjectorInspectorView(model: model)
                            .frame(width: ProjectorInspectorView.panelWidth)
                    }
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            .animation(.spring(duration: 0.22, bounce: 0.0), value: model.showSidebar)
            .animation(.spring(duration: 0.22, bounce: 0.0), value: model.showProjectorInspector)
            StatusBar(model: model)
        }
        .background(Theme.background.swiftUI)
        .preferredColorScheme(.dark)
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter { $0.isFileURL && DocumentController.allowedExtensions.contains($0.pathExtension.lowercased()) }
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
            if let snapshotImage = model.snapshotPreviewImage {
                Image(nsImage: snapshotImage)
                    .resizable()
                    .allowsHitTesting(false)
            }
            if let thumbnail = model.thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .scaledToFit()
                    .opacity(model.isReady ? 0 : (model.error == nil ? 0.6 : 1))
                    .animation(.easeOut(duration: 0.3), value: model.isReady)
                    .allowsHitTesting(false)
            }
            if let error = model.error {
                FailureBanner(message: error.localizedDescription, openInSketchUp: model.sketchUpApp.map { _ in model.openInSketchUp })
            }
            if case .loading(let progress) = model.state {
                LoadingProgressOverlay(
                    fileName: model.info?.url.lastPathComponent ?? L("Chargement…", "Loading…"),
                    versionLabel: model.info?.versionLabel,
                    progress: progress
                )
                .allowsHitTesting(false)
            }
            if model.isReady {
                ViewportHUDOverlay(model: model)
            }
        }
        .clipped()
    }
}

/// Prominent loading overlay with a wide progress bar shown in the viewport while reading `.skp` / `.dwg` / `.dxf` files.
private struct LoadingProgressOverlay: View {
    let fileName: String
    let versionLabel: String?
    let progress: SKPReader.Progress?

    @State private var pulse = false

    private var fraction: Double {
        min(max(progress?.fraction ?? 0.14, 0.06), 0.98)
    }

    var body: some View {
        ZStack(alignment: .top) {
            // Full-width top progress ribbon directly below TopBar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Rectangle()
                        .fill(Color.white.opacity(0.08))
                    Rectangle()
                        .fill(
                            LinearGradient(
                                colors: [Theme.accent.swiftUI.opacity(0.85), Theme.accent.swiftUI],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: max(24, geo.size.width * fraction))
                        .animation(.easeOut(duration: 0.22), value: fraction)
                }
            }
            .frame(height: 3.5)

            // Centered prominent loading card
            VStack(spacing: 11) {
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                        .tint(Theme.accent.swiftUI)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(fileName)
                            .font(.system(size: 13.5, weight: .semibold))
                            .foregroundStyle(Theme.text.swiftUI)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(progress?.phase ?? L("Ouverture du modèle…", "Opening model…"))
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.textDim.swiftUI)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    Text("\(Int((fraction * 100).rounded())) %")
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundStyle(Theme.accent.swiftUI)
                }

                // Wide high-contrast progress bar
                GeometryReader { barGeo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.white.opacity(0.10))
                            .overlay(Capsule().strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5))
                        Capsule()
                            .fill(
                                LinearGradient(
                                    colors: [
                                        Theme.accent.swiftUI.opacity(pulse ? 0.82 : 1.0),
                                        Theme.accent.swiftUI,
                                    ],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .frame(width: max(18, barGeo.size.width * fraction))
                            .shadow(color: Theme.accent.swiftUI.opacity(0.55), radius: 6, y: 0)
                            .animation(.easeOut(duration: 0.22), value: fraction)
                    }
                }
                .frame(height: 8)

                // Didactic live counters & current element being imported
                if let p = progress, (p.layers > 0 || p.blocks > 0 || p.edges > 0 || p.faces > 0 || p.currentItem != nil) {
                    VStack(alignment: .leading, spacing: 6) {
                        if let item = p.currentItem, !item.isEmpty {
                            HStack(spacing: 6) {
                                Image(systemName: "cube.transparent")
                                    .font(.system(size: 10.5, weight: .semibold))
                                    .foregroundStyle(Theme.accent.swiftUI)
                                Text(item)
                                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                                    .foregroundStyle(Theme.text.swiftUI)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3.5)
                            .background(
                                RoundedRectangle(cornerRadius: 5)
                                    .fill(Color.white.opacity(0.06))
                                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.accent.swiftUI.opacity(0.28), lineWidth: 0.5))
                            )
                        }

                        if p.layers > 0 || p.blocks > 0 || p.edges > 0 || p.faces > 0 {
                            HStack(spacing: 10) {
                                if p.layers > 0 {
                                    statBadge(label: L("Calques", "Layers"), value: p.layers)
                                }
                                if p.blocks > 0 {
                                    statBadge(label: L("Blocs", "Blocks"), value: p.blocks)
                                }
                                if p.edges > 0 {
                                    statBadge(label: L("Arêtes", "Edges"), value: p.edges)
                                }
                                if p.faces > 0 {
                                    statBadge(label: L("Faces", "Faces"), value: p.faces)
                                }
                                Spacer(minLength: 0)
                            }
                        }
                    }
                }

                if let versionLabel {
                    HStack {
                        Chip(text: versionLabel)
                        Spacer()
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 15)
            .frame(width: 400)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Theme.panel.swiftUI.opacity(0.94))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(Theme.accent.swiftUI.opacity(0.32), lineWidth: 1)
                    )
            )
            .shadow(color: .black.opacity(0.45), radius: 18, y: 6)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }

    private func statBadge(label: String, value: Int) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Theme.textFaint.swiftUI)
            Text(Format.integer(value))
                .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(Theme.textDim.swiftUI)
        }
    }
}

/// The model's own `ViewportView`, created once by the document model.
struct ViewportRepresentable: NSViewRepresentable {
    let view: ViewportView

    func makeNSView(context: Context) -> ViewportView { view }
    func updateNSView(_ nsView: ViewportView, context: Context) {}
}

// MARK: - TopBar

struct TopBar: View {
    @Bindable var model: DocumentModel
    @State private var showCameraPopover = false
    @State private var showLightingPopover = false

    private static let primaryViews: [(view: StandardView, label: String, shortcut: String)] = [
        (.iso, L("Iso", "Iso"), "⌘1"),
        (.top, L("Dessus", "Top"), "⌘2"),
        (.front, L("Face", "Front"), "⌘3"),
        (.right, L("Droite", "Right"), "⌘4"),
    ]

    private static let extraViews: [(view: StandardView, label: String, shortcut: String)] = [
        (.back, L("Arrière", "Back"), "⌘5"),
        (.left, L("Gauche", "Left"), "⌘6"),
        (.bottom, L("Dessous", "Bottom"), "⌘7"),
    ]

    private static let shadingStyles: [(style: ShadingStyle, label: String, symbol: String, help: String)] = [
        (.textured, L("PBR", "PBR"), "cube.fill", L("Style texturé réaliste doux (PBR)", "Soft realistic textured style (PBR)")),
        (.clay, L("Blanc", "Clay"), "cube", L("Style maquette blanche architecturale", "Architectural white clay style")),
        (.xray, L("Rayons X", "X-Ray"), "square.stack.3d.forward.dottedline", L("Style semi-transparent Rayons X", "Semi-transparent X-Ray style")),
        (.wireframe, L("Filaire", "Wire"), "squareshape.split.2x2", L("Style filaire (arêtes seules)", "Wireframe style (edges only)")),
    ]

    var body: some View {
        HStack(spacing: 7) {
            // 1. Sidebar & File actions
            HStack(spacing: 3) {
                IconButton(
                    symbol: "sidebar.left",
                    active: model.showSidebar,
                    disabled: model.skp == nil,
                    tooltip: L("Afficher ou masquer la barre latérale (⌥⌘S)", "Show or hide sidebar (⌥⌘S)")
                ) {
                    model.toggleSidebar()
                }
                IconButton(
                    symbol: "folder",
                    tooltip: L("Ouvrir un fichier SketchUp, AutoCAD, Collada, OBJ ou .sskp… (⌘O)", "Open a SketchUp, AutoCAD, Collada, OBJ or .sskp file… (⌘O)")
                ) {
                    NSDocumentController.shared.openDocument(nil)
                }
                if model.showsHiddenFeaturesUI {
                    ToolbarPillButton(
                        title: ".sskp",
                        symbol: "square.and.arrow.down",
                        active: model.sskpURL != nil,
                        disabled: !model.isReady || model.underlyingModelURL == nil,
                        tooltip: L("Enregistrer le projet SimpleSKP (.sskp) avec les vidéoprojecteurs et réglages (⌘S)",
                                   "Save SimpleSKP project (.sskp) with video projectors and settings (⌘S)")
                    ) {
                        model.saveSSKPProject()
                    }
                }
                if model.info != nil {
                    IconButton(
                        symbol: "finder",
                        tooltip: L("Afficher le fichier dans le Finder", "Show file in Finder")
                    ) {
                        model.revealInFinder()
                    }
                }
                if model.sketchUpApp != nil {
                    ToolbarPillButton(
                        title: "SketchUp",
                        symbol: "arrow.up.forward.app",
                        tooltip: L("Ouvrir le modèle dans SketchUp (⇧⌘O)", "Open model in SketchUp (⇧⌘O)")
                    ) {
                        model.openInSketchUp()
                    }
                }
            }

            barDivider

            // 2. Camera framing & standard views
            HStack(spacing: 3) {
                IconButton(
                    symbol: "arrow.counterclockwise",
                    disabled: !model.isReady,
                    tooltip: L("Réinitialiser la vue initiale (Z)", "Reset to initial view (Z)")
                ) {
                    model.resetView()
                }
                IconButton(
                    symbol: "arrow.up.left.and.arrow.down.right",
                    disabled: !model.isReady,
                    tooltip: L("Zoom étendu sur tout le modèle visible (⇧Z)", "Zoom extents to fit visible model (⇧Z)")
                ) {
                    model.zoomExtents()
                }
                ToolbarPillButton(
                    title: L("Mesurer", "Measure"),
                    symbol: "ruler",
                    active: model.isMeasuring,
                    disabled: !model.isReady,
                    tooltip: L("Outil de mesure avec magnétisme sur points, milieux et arêtes (⌘D · Échap pour quitter)",
                               "Measure tool with snapping on points, midpoints and edges (⌘D · Esc to exit)")
                ) {
                    model.toggleMeasureTool()
                }

                if !model.isCAD {
                    HStack(spacing: 1) {
                        ForEach(Self.primaryViews, id: \.view) { item in
                            ToolbarPillButton(
                                title: item.label,
                                active: model.activeStandardView == item.view,
                                disabled: !model.isReady,
                                tooltip: "\(item.label) (\(item.shortcut))"
                            ) {
                                model.look(item.view)
                            }
                        }
                        Menu {
                            ForEach(Self.extraViews, id: \.view) { item in
                                Button("\(item.label) (\(item.shortcut))") {
                                    model.look(item.view)
                                }
                            }
                        } label: {
                            Image(systemName: "chevron.down")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(Theme.textDim.swiftUI)
                                .frame(width: 18, height: 22)
                                .contentShape(Rectangle())
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .disabled(!model.isReady)
                        .help(L("Autres vues standard : Arrière (⌘5), Gauche (⌘6), Dessous (⌘7)",
                                "More standard views: Back (⌘5), Left (⌘6), Bottom (⌘7)"))
                    }
                    .padding(2)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.05)))

                    ToolbarPillButton(
                        title: model.isPerspective ? L("Persp.", "Persp.") : L("Parallèle", "Parallel"),
                        symbol: model.isPerspective ? "view.3d" : "square.grid.2x2",
                        active: !model.isPerspective,
                        disabled: !model.isReady,
                        tooltip: L("Basculer Perspective / Projection parallèle (⌥⌘P)", "Toggle Perspective / Parallel projection (⌥⌘P)")
                    ) {
                        model.togglePerspective()
                    }

                    ToolbarPillButton(
                        title: L("Vol libre", "Free Fly"),
                        symbol: "airplane",
                        active: model.isFreeFlying,
                        disabled: !model.isReady,
                        tooltip: L("Mode vol libre à la souris et au clavier (⌥⌘F, Échap pour quitter)",
                                   "Free fly mode with mouse and keyboard (⌥⌘F, Esc to exit)")
                    ) {
                        model.toggleFreeFlight()
                    }

                    IconButton(
                        symbol: "camera.aperture",
                        active: showCameraPopover || model.hasNonDefaultCameraOptics,
                        disabled: !model.isReady,
                        tooltip: L("Réglages fins de la caméra : angle d'ouverture (FOV / focale mm), position XYZ, orientation et exposition",
                                   "Fine camera settings: field of view (FOV / focal length mm), XYZ position, orientation and exposure")
                    ) {
                        showCameraPopover.toggle()
                    }
                    .popover(isPresented: $showCameraPopover, arrowEdge: .bottom) {
                        CameraPopover(model: model)
                    }
                }
            }

            barDivider

            // 3. Shading, Edges, Sun & Grid
            HStack(spacing: 3) {
                if !model.isCAD {
                    HStack(spacing: 1) {
                        ForEach(Self.shadingStyles, id: \.style) { item in
                            ToolbarPillButton(
                                title: item.label,
                                symbol: item.symbol,
                                active: model.shadingStyle == item.style,
                                disabled: !model.isReady,
                                tooltip: item.help
                            ) {
                                model.setShadingStyle(item.style)
                            }
                        }
                    }
                    .padding(2)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.05)))
                }

                IconButton(
                    symbol: "square.3.layers.3d.down.right",
                    active: model.showsEdges,
                    disabled: !model.isReady,
                    tooltip: L("Afficher ou masquer les arêtes (⌘E)", "Show or hide edges (⌘E)")
                ) {
                    model.toggleEdges()
                }

                if !model.isCAD {
                    ToolbarPillButton(
                        title: model.lightingMode == .sun ? L("Soleil", "Sun") : L("Ponctuel", "Point"),
                        symbol: model.lightingMode == .sun ? (model.shadowsEnabled ? "sun.max.fill" : "sun.max") : "lightbulb.fill",
                        active: model.lightingMode == .point,
                        disabled: !model.isReady,
                        tooltip: L("Basculer entre éclairage Soleil et éclairage Ponctuel", "Switch between Sun lighting and Point lighting")
                    ) {
                        model.setLightingMode(model.lightingMode == .sun ? .point : .sun)
                    }

                    IconButton(
                        symbol: model.shadowsEnabled ? "shadow" : "sun.min",
                        active: model.shadowsEnabled,
                        disabled: !model.isReady,
                        tooltip: L("Activer ou couper les ombres portées (⌥⌘O)", "Toggle cast shadows (⌥⌘O)")
                    ) {
                        model.toggleShadows()
                    }

                    IconButton(
                        symbol: "slider.horizontal.below.sun.max",
                        active: showLightingPopover || model.ambientOcclusionEnabled || model.lightingMode == .point || model.backdropStyle == .customColor,
                        disabled: !model.isReady,
                        tooltip: L("Réglages d'éclairage (Soleil / Ponctuel), importance SSAO et couleur de fond",
                                   "Lighting settings (Sun / Point), SSAO strength and background color")
                    ) {
                        showLightingPopover.toggle()
                    }
                    .popover(isPresented: $showLightingPopover, arrowEdge: .bottom) {
                        LightingPopover(model: model)
                    }

                    if model.showsHiddenFeaturesUI {
                        ToolbarPillButton(
                            title: model.onlyVideoProjectorIndices.isEmpty ? "VP" : "VP (\(model.onlyVideoProjectorIndices.count))",
                            symbol: "videoprojector.fill",
                            active: (model.showProjectorInspector && model.inspectorCategory == .videoProjectors) || !model.onlyVideoProjectorIndices.isEmpty,
                            disabled: !model.isReady,
                            tooltip: L("Inspecteur Vidéoprojecteurs (⌥⌘I) — optique, lens shift, mires et flux Syphon/NDI",
                                       "Video Projectors Inspector (⌥⌘I) — optics, lens shift, patterns and Syphon/NDI streams")
                        ) {
                            model.toggleVideoProjectorInspector()
                        }

                        ToolbarPillButton(
                            title: model.stageLightIndices.isEmpty ? L("Lumières", "Lights") : L("Lumières (\(model.stageLightIndices.count))", "Lights (\(model.stageLightIndices.count))"),
                            symbol: "light.cylindrical.ceiling.fill",
                            active: (model.showProjectorInspector && model.inspectorCategory == .stageLights) || !model.stageLightIndices.isEmpty,
                            disabled: !model.isReady,
                            tooltip: L("Inspecteur Lumières de scène — découpes, wash, fixtures OFL Millumin, patch DMX/Art-Net et conduite",
                                       "Stage Lights Inspector — profile spots, wash lights, Millumin OFL fixtures, DMX/Art-Net patch and cues")
                        ) {
                            model.toggleStageLightInspector()
                        }

                        if model.artNetListening {
                            HStack(spacing: 4) {
                                Circle()
                                    .fill(model.isArtNetActive ? Theme.alive.swiftUI : Color.orange.opacity(0.85))
                                    .frame(width: 5.5, height: 5.5)
                                Text("Art-Net")
                                    .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(model.isArtNetActive ? Theme.alive.swiftUI : Theme.textDim.swiftUI)
                            }
                            .padding(.horizontal, 5)
                            .padding(.vertical, 3)
                            .background(RoundedRectangle(cornerRadius: 4.5).fill(Color.white.opacity(0.04)))
                            .help(L("Art-Net UDP 6454 en écoute (\(model.artNetPacketCount) paquets reçus)",
                                    "Art-Net UDP 6454 listening (\(model.artNetPacketCount) packets received)"))
                        }
                    }
                } else {
                    ToolbarPillButton(
                        title: model.backdropStyle == .warmPaper ? L("Papier clair", "Light Paper") : L("Fond sombre", "Dark Canvas"),
                        symbol: model.backdropStyle == .warmPaper ? "doc.plaintext" : "moon.stars",
                        active: model.backdropStyle == .warmPaper,
                        disabled: !model.isReady,
                        tooltip: L("Basculer le fond AutoCAD entre Studio sombre et Papier clair (couleurs de tracé adaptées automatiquement)",
                                   "Toggle AutoCAD background between Dark Studio and Light Paper (line colors adapt automatically)")
                    ) {
                        model.setBackdropStyle(model.backdropStyle == .warmPaper ? .studioDark : .warmPaper)
                    }
                }

                IconButton(
                    symbol: "grid",
                    active: model.showsGrid,
                    disabled: !model.isReady,
                    tooltip: L("Afficher ou masquer la grille au sol et les axes XYZ (⌥⌘G)", "Show or hide ground grid and XYZ axes (⌥⌘G)")
                ) {
                    model.toggleGrid()
                }
            }

            Spacer(minLength: 4)

            // 4. Scene stepper & Capture
            if let skp = model.skp, !skp.scenes.isEmpty {
                HStack(spacing: 2) {
                    IconButton(
                        symbol: "chevron.left",
                        disabled: !model.isReady,
                        tooltip: L("Scène précédente (⌘[ · ⇧-clic : transition 10× plus lente)", "Previous scene (⌘[ · ⇧-click: 10× slower transition)")
                    ) {
                        model.previousScene()
                    }
                    Menu {
                        ForEach(skp.scenes.indices, id: \.self) { index in
                            Button {
                                model.selectScene(index)
                            } label: {
                                HStack {
                                    Text(skp.scenes[index].name)
                                    if model.selectedScene == index {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "camera.metering.center.weighted")
                                .font(.system(size: 10))
                                .foregroundStyle(Theme.accent.swiftUI)
                            Text(currentSceneLabel(skp))
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(Theme.text.swiftUI)
                                .lineLimit(1)
                                .frame(maxWidth: 110, alignment: .leading)
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .disabled(!model.isReady)
                    .help(L("Choisir une scène du modèle (maintenir ⇧ pour une transition 10× plus lente)", "Select a model scene (hold ⇧ for a 10× slower transition)"))

                    IconButton(
                        symbol: "chevron.right",
                        disabled: !model.isReady,
                        tooltip: L("Scène suivante (⌘] · ⇧-clic : transition 10× plus lente)", "Next scene (⌘] · ⇧-click: 10× slower transition)")
                    ) {
                        model.nextScene()
                    }
                }
                .padding(.horizontal, 2)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.05)))

                barDivider
            }

            HStack(spacing: 3) {
                if model.isSyphonAvailable {
                    HStack(spacing: 1) {
                        ToolbarPillButton(
                            title: model.syphonOutputEnabled && model.syphonOutputResolution != .viewport
                                ? "Syphon \(model.syphonOutputResolution.shortLabel)"
                                : "Syphon",
                            symbol: "dot.radiowaves.left.and.right",
                            active: model.syphonOutputEnabled,
                            disabled: !model.isReady,
                            tooltip: L("Diffuser la vue 3D en direct via Syphon (⌥⌘Y) — enregistrable dans SimpleRecorder",
                                       "Stream live 3D view via Syphon (⌥⌘Y) — recordable in SimpleRecorder")
                        ) {
                            model.toggleSyphonOutput()
                        }
                        Menu {
                            Button {
                                model.toggleSyphonOutput()
                            } label: {
                                HStack {
                                    Text(model.syphonOutputEnabled
                                         ? L("Désactiver la sortie Syphon", "Disable Syphon Output")
                                         : L("Activer la sortie Syphon", "Enable Syphon Output"))
                                    if model.syphonOutputEnabled {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                            Divider()
                            ForEach(SyphonOutputResolution.Category.allCases, id: \.rawValue) { category in
                                Section(category.title) {
                                    ForEach(SyphonOutputResolution.presets(in: category)) { res in
                                        Button {
                                            model.setSyphonOutputResolution(res)
                                        } label: {
                                            HStack {
                                                Text(res.label)
                                                if model.syphonOutputResolution == res {
                                                    Image(systemName: "checkmark")
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        } label: {
                            Image(systemName: "chevron.down")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(model.syphonOutputEnabled ? Theme.accent.swiftUI : Theme.textDim.swiftUI)
                                .frame(width: 16, height: 22)
                                .contentShape(Rectangle())
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .disabled(!model.isReady)
                        .help(L("Format du framebuffer Syphon (16:9, 16:10 WUXGA, Vertical 9:16, 4K…)",
                                "Syphon framebuffer format (16:9, 16:10 WUXGA, Vertical 9:16, 4K…)"))
                    }
                    .padding(1)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.04)))
                }

                IconButton(
                    symbol: "doc.on.doc",
                    disabled: !model.isReady,
                    tooltip: L("Copier l'image de la vue dans le presse-papiers (⌘C)", "Copy view image to clipboard (⌘C)")
                ) {
                    model.copyImage()
                }
                IconButton(
                    symbol: "camera",
                    disabled: !model.isReady,
                    tooltip: L("Exporter l'image en PNG… (⇧⌘E)", "Export PNG image… (⇧⌘E)")
                ) {
                    model.exportImage()
                }
                IconButton(
                    symbol: "doc.richtext",
                    disabled: !model.isReady,
                    tooltip: L("Exporter la vue en PDF vectoriel… (⌥⌘E)", "Export view as vector PDF… (⌥⌘E)")
                ) {
                    model.exportVectorPDF()
                }
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 38)
        .background(Theme.header.swiftUI)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.separator.swiftUI).frame(height: 1)
        }
    }

    private func currentSceneLabel(_ skp: SKPModel) -> String {
        if let index = model.selectedScene, skp.scenes.indices.contains(index) {
            return skp.scenes[index].name
        }
        return L("Scènes (\(skp.scenes.count))", "Scenes (\(skp.scenes.count))")
    }

    private var barDivider: some View {
        Rectangle()
            .fill(Theme.separator.swiftUI)
            .frame(width: 1, height: 18)
    }
}

// MARK: - Fine Camera Settings Popover

struct CameraPopover: View {
    let model: DocumentModel

    private static let focalPresets: [(mm: Float, label: String)] = [
        (14, "14 mm"),
        (24, "24 mm"),
        (35, "35 mm"),
        (50, "50 mm"),
        (85, "85 mm"),
    ]

    var body: some View {
        let posRange = model.cameraCoordinateRange
        let span = max(Float(posRange.upperBound - posRange.lowerBound), 1.0)
        let step = max(0.05, Double((span / 100.0).rounded(.toNearestOrAwayFromZero)))

        VStack(alignment: .leading, spacing: 11) {
            // 1. Optics & Field of View
            SectionHeader(L("Optique & Angle d'ouverture", "Optics & Field of View")) {
                Button {
                    model.setCameraFOV(35)
                    model.setCameraExposure(-0.62)
                    model.setCameraSpeedScale(1.0)
                } label: {
                    Text(L("Défaut (35°)", "Default (35°)"))
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(Theme.accent.swiftUI)
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 4) {
                ToolbarPillButton(
                    title: L("Perspective", "Perspective"),
                    symbol: "view.3d",
                    active: model.isPerspective
                ) {
                    model.setPerspective(true)
                }
                ToolbarPillButton(
                    title: L("Parallèle (Ortho)", "Parallel (Ortho)"),
                    symbol: "square.grid.2x2",
                    active: !model.isPerspective
                ) {
                    model.setPerspective(false)
                }
            }

            if model.isPerspective {
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(L("Angle d'ouverture (FOV)", "Field of view (FOV)"))
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.textDim.swiftUI)
                        Spacer()
                        Text("\(Int(model.cameraFOV.rounded()))° · \(Int(model.cameraFocalLengthMM.rounded())) mm")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Theme.text.swiftUI)
                    }
                    HStack(spacing: 6) {
                        Slider(
                            value: Binding(
                                get: { Double(model.cameraFOV) },
                                set: { model.setCameraFOV(Float($0)) }
                            ),
                            in: 10.0...120.0
                        )
                        .tint(Theme.accent.swiftUI)

                        HStack(spacing: 2) {
                            stepButton("minus") { model.setCameraFOV(model.cameraFOV - 1) }
                            stepButton("plus") { model.setCameraFOV(model.cameraFOV + 1) }
                        }
                    }

                    HStack(spacing: 4) {
                        Text(L("Focale 24×36 :", "35mm focal:"))
                            .font(.system(size: 10.5))
                            .foregroundStyle(Theme.textFaint.swiftUI)
                        Spacer()
                        ForEach(Self.focalPresets, id: \.mm) { preset in
                            let presetFOV = ViewportView.verticalFOVDegrees(forFocalLengthMM: preset.mm)
                            ToolbarPillButton(
                                title: preset.label,
                                active: abs(model.cameraFOV - presetFOV) < 1.2
                            ) {
                                model.setCameraFocalLength(preset.mm)
                            }
                        }
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(L("Demi-hauteur ortho", "Ortho half-height"))
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.textDim.swiftUI)
                        Spacer()
                        Text(String(format: "%.2f m", model.cameraOrthoScale))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Theme.text.swiftUI)
                    }
                    Slider(
                        value: Binding(
                            get: { Double(model.cameraOrthoScale) },
                            set: { model.setCameraOrthoScale(Float($0)) }
                        ),
                        in: model.cameraDistanceRange
                    )
                    .tint(Theme.accent.swiftUI)
                }
            }

            Rectangle().fill(Theme.separator.swiftUI).frame(height: 1)

            // 2. Camera Position XYZ & Quick Actions
            SectionHeader(L("Position de la caméra (m)", "Camera position (m)"))
            cameraCoordRow(
                axis: "X",
                color: NSColor(srgbRed: 0.92, green: 0.28, blue: 0.26, alpha: 1.0),
                value: model.cameraPosition.x,
                range: posRange,
                step: Float(step)
            ) { newX in
                model.setCameraPosition(SIMD3<Float>(newX, model.cameraPosition.y, model.cameraPosition.z))
            }
            cameraCoordRow(
                axis: "Y",
                color: NSColor(srgbRed: 0.25, green: 0.78, blue: 0.36, alpha: 1.0),
                value: model.cameraPosition.y,
                range: posRange,
                step: Float(step)
            ) { newY in
                model.setCameraPosition(SIMD3<Float>(model.cameraPosition.x, newY, model.cameraPosition.z))
            }
            cameraCoordRow(
                axis: "Z",
                color: NSColor(srgbRed: 0.24, green: 0.54, blue: 0.96, alpha: 1.0),
                value: model.cameraPosition.z,
                range: posRange,
                step: Float(step)
            ) { newZ in
                model.setCameraPosition(SIMD3<Float>(model.cameraPosition.x, model.cameraPosition.y, newZ))
            }

            HStack(spacing: 5) {
                ToolbarPillButton(
                    title: L("Œil 1,70 m", "Eye 1.70 m"),
                    symbol: "figure.stand",
                    active: false
                ) {
                    model.setCameraEyeHeight(1.70)
                }
                ToolbarPillButton(
                    title: L("Au centre", "Center"),
                    symbol: "scope",
                    active: false
                ) {
                    model.centerCameraInModel()
                }
                ToolbarPillButton(
                    title: L("Horizon 0°", "Horizon 0°"),
                    symbol: "level",
                    active: abs(model.cameraPitchDegrees) < 0.5
                ) {
                    model.levelCameraHorizon()
                }
            }

            Rectangle().fill(Theme.separator.swiftUI).frame(height: 1)

            // 3. Orientation (Azimut / Inclinaison) & Exposition
            SectionHeader(L("Orientation & Exposition", "Orientation & Exposure"))
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(L("Azimut (Lacet)", "Azimuth (Yaw)"))
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.textDim.swiftUI)
                    Spacer()
                    Text("\(Int(model.cameraYawDegrees.rounded()))°")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.text.swiftUI)
                }
                Slider(
                    value: Binding(
                        get: { Double(model.cameraYawDegrees) },
                        set: { model.setCameraOrientation(yawDegrees: Float($0)) }
                    ),
                    in: -180.0...180.0
                )
                .controlSize(.small)
                .tint(Theme.accent.swiftUI)

                HStack {
                    Text(L("Inclinaison (Tangage)", "Tilt (Pitch)"))
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.textDim.swiftUI)
                    Spacer()
                    Text("\(Int(model.cameraPitchDegrees.rounded()))°")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.text.swiftUI)
                }
                Slider(
                    value: Binding(
                        get: { Double(model.cameraPitchDegrees) },
                        set: { model.setCameraOrientation(pitchDegrees: Float($0)) }
                    ),
                    in: -89.0...89.0
                )
                .controlSize(.small)
                .tint(Theme.accent.swiftUI)

                HStack {
                    Text(L("Exposition HDR", "HDR exposure"))
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.textDim.swiftUI)
                    Spacer()
                    Text(String(format: "%+.2f EV", model.cameraExposure))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.text.swiftUI)
                }
                Slider(
                    value: Binding(
                        get: { Double(model.cameraExposure) },
                        set: { model.setCameraExposure(Float($0)) }
                    ),
                    in: -2.5...2.5
                )
                .controlSize(.small)
                .tint(Theme.accent.swiftUI)
            }
        }
        .padding(14)
        .frame(width: 332)
        .background(Theme.panel.swiftUI)
        .preferredColorScheme(.dark)
    }

    private func cameraCoordRow(
        axis: String,
        color: NSColor,
        value: Float,
        range: ClosedRange<Double>,
        step: Float,
        onChange: @escaping (Float) -> Void
    ) -> some View {
        HStack(spacing: 6) {
            Text(axis)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(Color(nsColor: color))
                .frame(width: 14, alignment: .leading)

            Slider(
                value: Binding(
                    get: { Double(value) },
                    set: { onChange(Float($0)) }
                ),
                in: range
            )
            .controlSize(.small)
            .tint(Color(nsColor: color))

            Text(String(format: "%+.2f m", value))
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(Theme.text.swiftUI)
                .frame(width: 58, alignment: .trailing)

            HStack(spacing: 2) {
                stepButton("minus") { onChange(value - step) }
                stepButton("plus") { onChange(value + step) }
            }
        }
    }

    private func stepButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .bold))
                .frame(width: 16, height: 16)
                .background(RoundedRectangle(cornerRadius: 3).fill(Color.white.opacity(0.08)))
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.textDim.swiftUI)
    }
}

// MARK: - Lighting, SSAO & Backdrop Popover

struct LightingPopover: View {
    let model: DocumentModel

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            // 1. Lighting Mode Header (Soleil vs Ponctuel) + Undo / Redo
            SectionHeader(L("Mode d'éclairage", "Lighting mode")) {
                HStack(spacing: 8) {
                    PopoverUndoRedoButtons(model: model)

                    if model.lightingMode == .sun {
                        Button {
                            model.resetSun()
                        } label: {
                            Text(L("Réinitialiser", "Reset"))
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundStyle(Theme.accent.swiftUI)
                        }
                        .buttonStyle(.plain)
                    } else {
                        Button {
                            model.addPointLight()
                        } label: {
                            HStack(spacing: 3) {
                                Image(systemName: "plus.circle.fill")
                                    .font(.system(size: 10.5))
                                Text(L("Créer une lumière", "Add light"))
                                    .font(.system(size: 10.5, weight: .medium))
                            }
                            .foregroundStyle(Theme.accent.swiftUI)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            HStack(spacing: 4) {
                ToolbarPillButton(
                    title: L("Soleil (Directionnel)", "Sun (Directional)"),
                    symbol: "sun.max.fill",
                    active: model.lightingMode == .sun
                ) {
                    model.setLightingMode(.sun)
                }
                ToolbarPillButton(
                    title: L("Ponctuel (Omni)", "Point (Omni)"),
                    symbol: "lightbulb.fill",
                    active: model.lightingMode == .point
                ) {
                    model.setLightingMode(.point)
                }
            }

            if model.lightingMode == .sun {
                sunControls
            } else {
                pointLightControls
            }

            ambientLightControl

            Rectangle().fill(Theme.separator.swiftUI).frame(height: 1)

            // 2. Ambient Occlusion (SSAO) + Importance slider
            SectionHeader(L("Occlusion ambiante (SSAO)", "Ambient occlusion (SSAO)"))
            Toggle(isOn: Binding(
                get: { model.ambientOcclusionEnabled },
                set: { _ in model.toggleAmbientOcclusion() }
            )) {
                Text(L("Activer l'occlusion ambiante (⌥⌘A)", "Enable ambient occlusion (⌥⌘A)"))
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.text.swiftUI)
            }
            .toggleStyle(.checkbox)

            if model.ambientOcclusionEnabled {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(L("Importance SSAO", "SSAO strength"))
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.textDim.swiftUI)
                        Spacer()
                        EditableNumericValue(
                            value: model.ambientOcclusionIntensity * 100.0,
                            displayFormat: "%.0f %%",
                            editFormat: "%.1f",
                            width: 54
                        ) { newPct in
                            model.setAmbientOcclusionIntensity(simd_clamp(newPct / 100.0, 0.0, 2.0), coalesce: false)
                        }
                        FineStepButtons(
                            normalStep: 5.0,
                            fineStep: 1.0,
                            coarseStep: 20.0,
                            unit: " %"
                        ) { deltaPct in
                            let next = simd_clamp(model.ambientOcclusionIntensity + deltaPct / 100.0, 0.0, 2.0)
                            model.setAmbientOcclusionIntensity(next, coalesce: false)
                        }
                    }
                    Slider(
                        value: Binding(
                            get: { Double(model.ambientOcclusionIntensity) },
                            set: { model.setAmbientOcclusionIntensity(Float($0), coalesce: true) }
                        ),
                        in: 0.0...2.0
                    )
                    .controlSize(.small)
                    .tint(Theme.accent.swiftUI)
                }
            }

            Rectangle().fill(Theme.separator.swiftUI).frame(height: 1)

            // 3. Backdrop Style & Custom Color
            SectionHeader(L("Fond de scène", "Backdrop"))
            HStack(spacing: 4) {
                backdropChoice(.architecturalSky, title: L("Ciel", "Sky"), symbol: "cloud.sun")
                backdropChoice(.studioDark, title: L("Studio", "Studio"), symbol: "circle.lefthalf.filled")
                backdropChoice(.warmPaper, title: L("Papier", "Paper"), symbol: "doc.plaintext")
                backdropChoice(.customColor, title: L("Couleur", "Color"), symbol: "paintpalette")
            }

            HStack(spacing: 8) {
                ColorPicker(
                    L("Couleur du fond", "Background color"),
                    selection: customColorBinding,
                    supportsOpacity: false
                )
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.textDim.swiftUI)

                Spacer()

                HStack(spacing: 5) {
                    colorSwatch(SIMD3<Float>(0.08, 0.09, 0.11), label: L("Noir théâtre", "Stage black"))
                    colorSwatch(SIMD3<Float>(0.16, 0.18, 0.22), label: L("Anthracite", "Anthracite"))
                    colorSwatch(SIMD3<Float>(0.45, 0.47, 0.50), label: L("Gris neutre", "Neutral grey"))
                    colorSwatch(SIMD3<Float>(0.12, 0.22, 0.34), label: L("Bleu nuit", "Night blue"))
                    colorSwatch(SIMD3<Float>(0.92, 0.90, 0.86), label: L("Crème", "Cream"))
                    colorSwatch(SIMD3<Float>(1.00, 1.00, 1.00), label: L("Blanc pur", "Pure white"))
                }
            }

            FineTuningHintFooter()
        }
        .padding(14)
        .frame(width: 342)
        .background(Theme.panel.swiftUI)
        .preferredColorScheme(.dark)
    }

    // MARK: Sun Controls

    private var sunControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(L("Azimut solaire", "Sun azimuth"))
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textDim.swiftUI)
                Spacer()
                EditableNumericValue(
                    value: model.sunAzimuthDegrees,
                    displayFormat: "%+.1f°",
                    editFormat: "%.1f",
                    width: 58
                ) { newAz in
                    model.setSun(azimuth: newAz, elevation: model.sunElevationDegrees, coalesce: false)
                }
                FineStepButtons(
                    normalStep: 2.0,
                    fineStep: 0.2,
                    coarseStep: 15.0,
                    unit: "°"
                ) { delta in
                    model.setSun(azimuth: model.sunAzimuthDegrees + delta, elevation: model.sunElevationDegrees, coalesce: false)
                }
            }
            Slider(
                value: Binding(
                    get: { Double(model.sunAzimuthDegrees) },
                    set: { model.setSun(azimuth: Float($0), elevation: model.sunElevationDegrees, coalesce: true) }
                ),
                in: -180...180
            )
            .controlSize(.small)
            .tint(Theme.accent.swiftUI)

            HStack(spacing: 6) {
                Text(L("Hauteur solaire", "Sun elevation"))
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textDim.swiftUI)
                Spacer()
                EditableNumericValue(
                    value: model.sunElevationDegrees,
                    displayFormat: "%.1f°",
                    editFormat: "%.1f",
                    width: 58
                ) { newEl in
                    model.setSun(azimuth: model.sunAzimuthDegrees, elevation: simd_clamp(newEl, 8.0, 85.0), coalesce: false)
                }
                FineStepButtons(
                    normalStep: 1.0,
                    fineStep: 0.1,
                    coarseStep: 10.0,
                    unit: "°"
                ) { delta in
                    model.setSun(azimuth: model.sunAzimuthDegrees, elevation: simd_clamp(model.sunElevationDegrees + delta, 8.0, 85.0), coalesce: false)
                }
            }
            Slider(
                value: Binding(
                    get: { Double(model.sunElevationDegrees) },
                    set: { model.setSun(azimuth: model.sunAzimuthDegrees, elevation: Float($0), coalesce: true) }
                ),
                in: 8...85
            )
            .controlSize(.small)
            .tint(Theme.accent.swiftUI)

            HStack(spacing: 6) {
                Text(L("Puissance solaire", "Sun intensity"))
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textDim.swiftUI)
                Spacer()
                EditableNumericValue(
                    value: model.sunIntensity * 100.0,
                    displayFormat: "%.1f %%",
                    editFormat: "%.1f",
                    width: 60
                ) { newPct in
                    model.setSunIntensity(simd_clamp(newPct / 100.0, 0.0, 3.0), coalesce: false)
                }
                FineStepButtons(
                    normalStep: 5.0,
                    fineStep: 0.5,
                    coarseStep: 25.0,
                    unit: " %"
                ) { deltaPct in
                    model.setSunIntensity(simd_clamp(model.sunIntensity + deltaPct / 100.0, 0.0, 3.0), coalesce: false)
                }
            }
            Slider(
                value: Binding(
                    get: { Rendering.lightIntensityToSlider(model.sunIntensity, maxIntensity: 3.0) },
                    set: { model.setSunIntensity(Rendering.sliderToLightIntensity($0, maxIntensity: 3.0), coalesce: true) }
                ),
                in: 0.0...1.0
            )
            .controlSize(.small)
            .tint(Theme.accent.swiftUI)

            Toggle(isOn: Binding(
                get: { model.shadowsEnabled },
                set: { _ in model.toggleShadows() }
            )) {
                Text(L("Ombres portées du soleil (⌥⌘O)", "Cast sun shadows (⌥⌘O)"))
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.text.swiftUI)
            }
            .toggleStyle(.checkbox)
        }
    }

    private var ambientLightControl: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(L("Lumière ambiante", "Ambient light"))
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textDim.swiftUI)
                Spacer()
                if abs(model.ambientIntensity - Rendering.defaultAmbientIntensity) > 0.02 {
                    Button {
                        model.setAmbientIntensity(Rendering.defaultAmbientIntensity, coalesce: false)
                    } label: {
                        Text("100 %")
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(Theme.accent.swiftUI)
                    }
                    .buttonStyle(.plain)
                }
                EditableNumericValue(
                    value: model.ambientIntensity * 100.0,
                    displayFormat: "%.1f %%",
                    editFormat: "%.1f",
                    width: 60
                ) { newPct in
                    model.setAmbientIntensity(simd_clamp(newPct / 100.0, 0.0, 2.0), coalesce: false)
                }
                FineStepButtons(
                    normalStep: 5.0,
                    fineStep: 0.5,
                    coarseStep: 25.0,
                    unit: " %"
                ) { deltaPct in
                    model.setAmbientIntensity(simd_clamp(model.ambientIntensity + deltaPct / 100.0, 0.0, 2.0), coalesce: false)
                }
            }
            Slider(
                value: Binding(
                    get: { Rendering.lightIntensityToSlider(model.ambientIntensity, maxIntensity: 2.0) },
                    set: { model.setAmbientIntensity(Rendering.sliderToLightIntensity($0, maxIntensity: 2.0), coalesce: true) }
                ),
                in: 0.0...1.0
            )
            .controlSize(.small)
            .tint(Theme.accent.swiftUI)
            .help(L("Lumière ambiante résiduelle lorsque les lumières sont à 0 % (courbe logarithmique)",
                    "Residual ambient light when lights are at 0% (logarithmic curve)"))
        }
    }

    // MARK: Point Light Controls

    private var pointLightControls: some View {
        let range = model.pointLightCoordinateRange

        return VStack(alignment: .leading, spacing: 8) {
            if let detectedCount = model.scene?.detectedSceneLights.count, detectedCount > 0 {
                HStack(spacing: 5) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.accent.swiftUI)
                    Text(L(
                        "\(detectedCount) lumière(s) détectée(s) dans la scène",
                        "\(detectedCount) light(s) detected in scene"
                    ))
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Theme.textDim.swiftUI)
                }
            }

            if model.pointLights.count > 1 {
                HStack(spacing: 6) {
                    Picker("", selection: Binding(
                        get: { model.selectedPointLightIndex },
                        set: { model.selectedPointLightIndex = $0 }
                    )) {
                        ForEach(Array(model.pointLights.enumerated()), id: \.offset) { index, light in
                            Text(light.isFromScene ? "★ \(light.name)" : light.name).tag(index)
                        }
                    }
                    .labelsHidden()
                    .controlSize(.small)

                    Button {
                        model.removeSelectedPointLight()
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textDim.swiftUI)
                    }
                    .buttonStyle(.plain)
                    .help(L("Supprimer cette lumière", "Delete this light"))
                }
            }

            if let light = model.selectedPointLight {
                coordinateRow(
                    axis: "X",
                    color: NSColor(srgbRed: 0.92, green: 0.28, blue: 0.26, alpha: 1.0),
                    value: light.position.x,
                    range: range,
                    onSliderChange: { newX in
                        model.updateSelectedPointLight(position: SIMD3<Float>(newX, light.position.y, light.position.z), coalesceKey: "light-x")
                    },
                    onDiscreteChange: { newX in
                        model.updateSelectedPointLight(position: SIMD3<Float>(newX, light.position.y, light.position.z), coalesceKey: nil)
                    }
                )
                coordinateRow(
                    axis: "Y",
                    color: NSColor(srgbRed: 0.25, green: 0.78, blue: 0.36, alpha: 1.0),
                    value: light.position.y,
                    range: range,
                    onSliderChange: { newY in
                        model.updateSelectedPointLight(position: SIMD3<Float>(light.position.x, newY, light.position.z), coalesceKey: "light-y")
                    },
                    onDiscreteChange: { newY in
                        model.updateSelectedPointLight(position: SIMD3<Float>(light.position.x, newY, light.position.z), coalesceKey: nil)
                    }
                )
                coordinateRow(
                    axis: "Z",
                    color: NSColor(srgbRed: 0.24, green: 0.54, blue: 0.96, alpha: 1.0),
                    value: light.position.z,
                    range: range,
                    onSliderChange: { newZ in
                        model.updateSelectedPointLight(position: SIMD3<Float>(light.position.x, light.position.y, newZ), coalesceKey: "light-z")
                    },
                    onDiscreteChange: { newZ in
                        model.updateSelectedPointLight(position: SIMD3<Float>(light.position.x, light.position.y, newZ), coalesceKey: nil)
                    }
                )

                HStack(spacing: 6) {
                    ToolbarPillButton(
                        title: L("Au milieu de la géométrie", "Center of geometry"),
                        symbol: "scope",
                        active: false
                    ) {
                        model.centerSelectedPointLight()
                    }
                    ToolbarPillButton(
                        title: L("À la caméra", "At camera"),
                        symbol: "video",
                        active: false
                    ) {
                        model.moveSelectedPointLightToCamera()
                    }
                }

                HStack(spacing: 6) {
                    Text(L("Puissance (log)", "Power (log)"))
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.textDim.swiftUI)
                    Spacer()
                    EditableNumericValue(
                        value: light.intensity * 100.0,
                        displayFormat: "%.1f %%",
                        editFormat: "%.1f",
                        width: 60
                    ) { newPct in
                        model.updateSelectedPointLight(intensity: simd_clamp(newPct / 100.0, 0.0, 3.0), coalesceKey: nil)
                    }
                    FineStepButtons(
                        normalStep: 5.0,
                        fineStep: 0.5,
                        coarseStep: 25.0,
                        unit: " %"
                    ) { deltaPct in
                        let next = simd_clamp(light.intensity + deltaPct / 100.0, 0.0, 3.0)
                        model.updateSelectedPointLight(intensity: next, coalesceKey: nil)
                    }
                }
                Slider(
                    value: Binding(
                        get: { Rendering.lightIntensityToSlider(light.intensity, maxIntensity: 3.0) },
                        set: { model.updateSelectedPointLight(intensity: Rendering.sliderToLightIntensity($0, maxIntensity: 3.0), coalesceKey: "light-power") }
                    ),
                    in: 0.0...1.0
                )
                .controlSize(.small)
                .tint(Theme.accent.swiftUI)
                .help(L("Puissance lumineuse à échelle logarithmique (réglage fin dans les basses valeurs, de 0 % à 300 %)",
                        "Logarithmic light power (fine control in low values, from 0% to 300%)"))

                Toggle(isOn: Binding(
                    get: { model.shadowsEnabled },
                    set: { _ in model.toggleShadows() }
                )) {
                    Text(L("Ombres portées de la lumière (⌥⌘O)", "Cast point light shadows (⌥⌘O)"))
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.text.swiftUI)
                }
                .toggleStyle(.checkbox)

                Toggle(isOn: Binding(
                    get: { model.showsPointLightGizmo },
                    set: { _ in model.togglePointLightGizmo() }
                )) {
                    Text(L("Afficher le repère 3D de la lumière", "Show 3D light gizmo"))
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.text.swiftUI)
                }
                .toggleStyle(.checkbox)
            }
        }
    }

    private func coordinateRow(
        axis: String,
        color: NSColor,
        value: Float,
        range: ClosedRange<Double>,
        onSliderChange: @escaping (Float) -> Void,
        onDiscreteChange: @escaping (Float) -> Void
    ) -> some View {
        let clampedRange = min(range.lowerBound, Double(value) - 1.0)...max(range.upperBound, Double(value) + 1.0)
        return HStack(spacing: 6) {
            Text(axis)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(Color(nsColor: color))
                .frame(width: 14, alignment: .leading)

            Slider(
                value: Binding(
                    get: { Double(value) },
                    set: { onSliderChange(Float($0)) }
                ),
                in: clampedRange
            )
            .controlSize(.small)
            .tint(Color(nsColor: color))

            EditableNumericValue(
                value: value,
                displayFormat: "%+.2f m",
                editFormat: "%.3f",
                width: 64,
                onCommit: onDiscreteChange
            )

            FineStepButtons(
                normalStep: 0.10,
                fineStep: 0.01,
                coarseStep: 1.00,
                unit: " m"
            ) { delta in
                onDiscreteChange(value + delta)
            }
        }
    }

    private var customColorBinding: Binding<Color> {
        Binding(
            get: {
                Color(
                    .sRGB,
                    red: Double(model.customBackdropColor.x),
                    green: Double(model.customBackdropColor.y),
                    blue: Double(model.customBackdropColor.z),
                    opacity: 1.0
                )
            },
            set: { newColor in
                if let cg = NSColor(newColor).usingColorSpace(.sRGB) {
                    model.setCustomBackdropColor(SIMD3<Float>(
                        Float(cg.redComponent),
                        Float(cg.greenComponent),
                        Float(cg.blueComponent)
                    ))
                }
            }
        )
    }

    private func colorSwatch(_ rgb: SIMD3<Float>, label: String) -> some View {
        let isSelected = model.backdropStyle == .customColor &&
            abs(model.customBackdropColor.x - rgb.x) < 0.02 &&
            abs(model.customBackdropColor.y - rgb.y) < 0.02 &&
            abs(model.customBackdropColor.z - rgb.z) < 0.02
        return Button {
            model.setCustomBackdropColor(rgb)
        } label: {
            Circle()
                .fill(Color(.sRGB, red: Double(rgb.x), green: Double(rgb.y), blue: Double(rgb.z), opacity: 1.0))
                .frame(width: 15, height: 15)
                .overlay(
                    Circle()
                        .strokeBorder(isSelected ? Theme.accent.swiftUI : Color.white.opacity(0.25), lineWidth: isSelected ? 2 : 1)
                )
        }
        .buttonStyle(.plain)
        .help(label)
    }

    private func backdropChoice(_ style: BackdropStyle, title: String, symbol: String) -> some View {
        ToolbarPillButton(
            title: title,
            symbol: symbol,
            active: model.backdropStyle == style
        ) {
            model.setBackdropStyle(style)
        }
    }
}

// MARK: - Video Projector & Stage Light Inspector (Docked Side Panel)

struct ProjectorInspectorView: View {
    static let panelWidth: CGFloat = 356

    @Bindable var model: DocumentModel
    @State private var nudgeStep: Float = 0.50

    private var isStageLightMode: Bool {
        model.inspectorCategory == .stageLights
    }

    private var categoryIndices: [Int] {
        isStageLightMode ? model.stageLightIndices : model.onlyVideoProjectorIndices
    }

    private var selectedCategoryIndices: [Int] {
        categoryIndices.filter { model.selectedVideoProjectorIndices.contains($0) }
    }

    private var activeProjectorInCategory: VideoProjector? {
        if let sel = model.selectedVideoProjector, sel.isStageLight == isStageLightMode {
            return sel
        }
        if let firstIdx = categoryIndices.first {
            return model.videoProjectors[firstIdx]
        }
        return nil
    }

    private var headerTitle: String {
        let count = selectedCategoryIndices.count
        if isStageLightMode {
            if count > 1 {
                return L("\(count) lumières sélectionnées", "\(count) Stage Lights Selected")
            } else if let light = activeProjectorInCategory {
                return light.name
            }
            return L("Lumières de plateau", "Stage Lights")
        } else {
            if count > 1 {
                return L("\(count) vidéoprojecteurs sélectionnés", "\(count) Video Projectors Selected")
            } else if let proj = activeProjectorInCategory {
                return proj.name
            }
            return L("Vidéoprojecteurs", "Video Projectors")
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // 1. Panel Header (Title, Undo/Redo, Add, Close)
            HStack(spacing: 6) {
                Image(systemName: isStageLightMode ? "light.cylindrical.ceiling.fill" : "videoprojector.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(isStageLightMode ? Theme.accent.swiftUI : Theme.alive.swiftUI)
                Text(headerTitle)
                    .font(.system(size: 11.5, weight: .bold))
                    .foregroundStyle(Theme.text.swiftUI)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 4)

                PopoverUndoRedoButtons(model: model)

                if isStageLightMode {
                    stageLightAddMenu
                } else {
                    videoProjectorAddMenu
                }

                Button {
                    model.showProjectorInspector = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9.5, weight: .bold))
                        .foregroundStyle(Theme.textDim.swiftUI)
                        .frame(width: 18, height: 18)
                        .background(RoundedRectangle(cornerRadius: 3.5).fill(Color.white.opacity(0.06)))
                }
                .buttonStyle(.plain)
                .help(L("Fermer l'inspecteur (⌥⌘I)", "Close inspector (⌥⌘I)"))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Theme.header.swiftUI)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Theme.separator.swiftUI).frame(height: 1)
            }

            // 1b. Category Switcher Bar: Vidéoprojecteurs vs Lumières
            categorySwitcherBar

            // 2. Scrollable Body
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 10) {
                    if isStageLightMode {
                        stageLightInspectorBody
                    } else {
                        videoProjectorInspectorBody
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .frame(width: Self.panelWidth, alignment: .leading)
            }
        }
        .frame(width: Self.panelWidth)
        .clipped()
        .background(Theme.panel.swiftUI)
        .preferredColorScheme(.dark)
    }

    // MARK: - Category Switcher & Header Menus

    private var categorySwitcherBar: some View {
        HStack(spacing: 4) {
            let vpCount = model.onlyVideoProjectorIndices.count
            let lightCount = model.stageLightIndices.count

            Button {
                model.switchInspectorCategory(.videoProjectors)
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "videoprojector.fill")
                        .font(.system(size: 10, weight: .semibold))
                    Text(vpCount > 0 ? L("Vidéoprojecteurs (\(vpCount))", "Video Projectors (\(vpCount))") : L("Vidéoprojecteurs", "Video Projectors"))
                        .font(.system(size: 10.5, weight: !isStageLightMode ? .bold : .medium))
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(!isStageLightMode ? Theme.alive.swiftUI.opacity(0.20) : Color.white.opacity(0.03))
                        .overlay(
                            RoundedRectangle(cornerRadius: 5)
                                .strokeBorder(!isStageLightMode ? Theme.alive.swiftUI.opacity(0.6) : Color.white.opacity(0.07), lineWidth: 1)
                        )
                )
                .foregroundStyle(!isStageLightMode ? Theme.alive.swiftUI : Theme.textDim.swiftUI)
            }
            .buttonStyle(.plain)

            Button {
                model.switchInspectorCategory(.stageLights)
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "light.cylindrical.ceiling.fill")
                        .font(.system(size: 10, weight: .semibold))
                    Text(lightCount > 0 ? L("Lumières (\(lightCount))", "Lights (\(lightCount))") : L("Lumières", "Lights"))
                        .font(.system(size: 10.5, weight: isStageLightMode ? .bold : .medium))
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(isStageLightMode ? Theme.accent.swiftUI.opacity(0.22) : Color.white.opacity(0.03))
                        .overlay(
                            RoundedRectangle(cornerRadius: 5)
                                .strokeBorder(isStageLightMode ? Theme.accent.swiftUI.opacity(0.65) : Color.white.opacity(0.07), lineWidth: 1)
                        )
                )
                .foregroundStyle(isStageLightMode ? Theme.accent.swiftUI : Theme.textDim.swiftUI)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Theme.header.swiftUI.opacity(0.65))
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.separator.swiftUI).frame(height: 1)
        }
    }

    private var videoProjectorAddMenu: some View {
        Menu {
            ForEach(ProjectorCatalog.videoProjectorSpecs) { spec in
                Button {
                    model.addVideoProjector(spec: spec)
                } label: {
                    Label("\(spec.displayName) (\(Format.integer(spec.lumens)) lm)", systemImage: "videoprojector")
                }
            }
        } label: {
            Image(systemName: "plus.circle.fill")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(Theme.alive.swiftUI)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(L("Ajouter un vidéoprojecteur au point de vue de la caméra", "Add a video projector at camera viewpoint"))
    }

    private var stageLightAddMenu: some View {
        Menu {
            Section(L("Projecteurs de plateau", "Stage Fixtures")) {
                ForEach(ProjectorCatalog.stageLightSpecs) { spec in
                    Button {
                        model.addVideoProjector(spec: spec)
                    } label: {
                        Label(
                            "\(spec.displayName) (\(Int(spec.minBeamAngleDegrees))°–\(Int(spec.maxBeamAngleDegrees))°)",
                            systemImage: spec.kind == .profileSpot ? "flashlight.on.fill" : "light.cylindrical.ceiling.fill"
                        )
                    }
                }
            }

            let oflFixtures = OFLFixtureLibrary.shared.allFixtures
            if !oflFixtures.isEmpty {
                Menu(L("Librairie Millumin Light-fixtures (\(oflFixtures.count))", "Millumin Light-fixtures Library (\(oflFixtures.count))")) {
                    ForEach(oflFixtures) { def in
                        if def.modes.count <= 1 {
                            Button {
                                model.addOFLStageLight(definition: def, modeName: def.modes.first?.name)
                            } label: {
                                Text("\(def.displayName) (\(def.modes.first?.channels.count ?? 1) ch)")
                            }
                        } else {
                            Menu(def.displayName) {
                                ForEach(def.modes) { mode in
                                    Button {
                                        model.addOFLStageLight(definition: def, modeName: mode.name)
                                    } label: {
                                        Text("\(mode.name) (\(mode.channels.count) ch)")
                                    }
                                }
                            }
                        }
                    }
                }
            }

            Divider()

            Button {
                model.promptImportMillumin()
            } label: {
                Label(L("Importer lumières & conduite depuis Millumin (.millumin)…", "Import lights & cues from Millumin (.millumin)…"), systemImage: "square.and.arrow.down")
            }
        } label: {
            Image(systemName: "plus.circle.fill")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(Theme.accent.swiftUI)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(L("Ajouter une lumière (Découpe, Wash, PAR, fixture Millumin OFL) ou importer une conduite .millumin",
                "Add a stage light (Profile, Wash, PAR, Millumin OFL fixture) or import a .millumin cue sheet"))
    }

    // MARK: - Video Projector Inspector Body

    @ViewBuilder
    private var videoProjectorInspectorBody: some View {
        if model.onlyVideoProjectorIndices.isEmpty {
            emptyVideoProjectorStateCard
        } else if let proj = activeProjectorInCategory {
            // A. Group / Multi-Selection Switcher & Actions (Video Projectors only)
            selectionAndGroupBar

            // B. 3D Movement & Positioning (Group or Single)
            movementSection(primary: proj)

            Rectangle().fill(Theme.separator.swiftUI).frame(height: 1)

            // C. Optics (Throw Ratio, Lens Shift H/V, VP Model)
            opticsSection(primary: proj)

            Rectangle().fill(Theme.separator.swiftUI).frame(height: 1)

            // D. Beam Shaping (Shutters, Focus & Color Tint)
            beamShapingSection(primary: proj)

            Rectangle().fill(Theme.separator.swiftUI).frame(height: 1)

            // E. Photometrics & Realistic Lux Simulation
            photometricsSection(primary: proj)

            Rectangle().fill(Theme.separator.swiftUI).frame(height: 1)

            // F. Pattern, Syphon/NDI Stream, Intensity & Reverb
            patternAndPowerSection(primary: proj)

            FineTuningHintFooter()
        }
    }

    // MARK: - Stage Light Inspector Body (Dedicated Lighting UI — No VP Settings)

    @ViewBuilder
    private var stageLightInspectorBody: some View {
        if !model.milluminCues.isEmpty {
            milluminCueSheetSection
        }

        if model.stageLightIndices.isEmpty {
            emptyStageLightStateCard
        } else if let light = activeProjectorInCategory {
            // A. Stage Light Selection & Group Actions
            stageLightSelectionAndGroupBar

            // B. Dimmer (Gradateur), Color / Gel & Reverberation
            stageLightDimmerAndColorSection(primary: light)

            Rectangle().fill(Theme.separator.swiftUI).frame(height: 1)

            // C. Fixture Model, Beam Zoom (°), Focus & Framing Shutters / Barn Doors
            stageLightOpticsAndShuttersSection(primary: light)

            Rectangle().fill(Theme.separator.swiftUI).frame(height: 1)

            // D. 3D Position, Aiming & Overhead ("Douche 90°")
            stageLightMovementSection(primary: light)

            Rectangle().fill(Theme.separator.swiftUI).frame(height: 1)

            // E. Stage Light Photometrics (Lux & Beam Diameter Ø m)
            stageLightPhotometricsSection(primary: light)

            Rectangle().fill(Theme.separator.swiftUI).frame(height: 1)

            // F. DMX Patch, Art-Net & Millumin OFL Light-Fixture Channels
            stageLightDMXAndOFLSection(primary: light)

            FineTuningHintFooter()
        }
    }

    // MARK: - Subviews (Empty States)

    private var emptyVideoProjectorStateCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "videoprojector.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(Theme.alive.swiftUI)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("Vidéoprojection Scénographique", "Scenographic Video Projection"))
                        .font(.system(size: 12.5, weight: .bold))
                        .foregroundStyle(Theme.text.swiftUI)
                    Text("Optique · Lens Shift · Mires · Syphon / NDI · Lux")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Theme.textDim.swiftUI)
                }
            }
            Text(L("Ajoutez un vidéoprojecteur pour simuler le rapport de projection, le décentrement optique (Lens Shift H/V), la photométrie ANSI et les flux Syphon/NDI.",
                   "Add a video projector to simulate throw ratio, H/V lens shift, ANSI photometrics and live Syphon/NDI streams."))
                .font(.system(size: 11))
                .foregroundStyle(Theme.textFaint.swiftUI)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 5) {
                Button {
                    model.addVideoProjector(spec: .optomaZU920ST)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "videoprojector")
                        Text(L("Ajouter un Optoma ZU920ST (Laser 9 800 lm · 0.65:1)", "Add Optoma ZU920ST (9 800 lm Laser · 0.65:1)"))
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(Theme.background.swiftUI)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 5.5)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Theme.alive.swiftUI))
                }
                .buttonStyle(.plain)

                HStack(spacing: 5) {
                    Button {
                        model.addVideoProjector(spec: .panasonicPTRQ32K_ETD3LEW50)
                    } label: {
                        Text("PT-RQ32K (0.70:1)")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Theme.text.swiftUI)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 5)
                            .background(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.08)))
                    }
                    .buttonStyle(.plain)

                    Button {
                        model.addVideoProjector(spec: .panasonicPTRQ32K_ETD75LE30)
                    } label: {
                        Text("PT-RQ32K (2.4–4.7:1)")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Theme.text.swiftUI)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 5)
                            .background(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.08)))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.white.opacity(0.04))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
        )
    }

    private var emptyStageLightStateCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "light.cylindrical.ceiling.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(Theme.accent.swiftUI)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("Éclairage Scénique & Conduite Millumin", "Stage Lighting & Millumin Cue Sheet"))
                        .font(.system(size: 12.5, weight: .bold))
                        .foregroundStyle(Theme.text.swiftUI)
                    Text("Découpes · Lyres Wash · Panneaux LED · Art-Net · OFL")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Theme.textDim.swiftUI)
                }
            }
            Text(L("Ajoutez des projecteurs lumière (Découpes, Wash, PAR) ou importez directement le plan de feux, les fixtures OFL (/Library/Millumin/Light-fixtures) et la conduite depuis un fichier .millumin.",
                   "Add stage lights (Profiles, Washes, PARs) or import the lighting rig, OFL fixtures (/Library/Millumin/Light-fixtures) and cue sheet directly from a .millumin project."))
                .font(.system(size: 11))
                .foregroundStyle(Theme.textFaint.swiftUI)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 5) {
                Button {
                    model.promptImportMillumin()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "square.and.arrow.down")
                        Text(L("Importer Lumières & Conduite depuis Millumin (.millumin)…", "Import Lights & Cue Sheet from Millumin (.millumin)…"))
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(Theme.background.swiftUI)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 5.5)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Theme.accent.swiftUI))
                }
                .buttonStyle(.plain)

                HStack(spacing: 5) {
                    Button {
                        model.addShowtecProfileMini()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "flashlight.on.fill")
                            Text("Profile Mini")
                                .font(.system(size: 10, weight: .semibold))
                        }
                        .foregroundStyle(Theme.text.swiftUI)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.08)))
                    }
                    .buttonStyle(.plain)

                    Button {
                        model.addVarytecHeroWash300()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "light.beacon.max.fill")
                            Text("Hero Wash 300")
                                .font(.system(size: 10, weight: .semibold))
                        }
                        .foregroundStyle(Theme.text.swiftUI)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.08)))
                    }
                    .buttonStyle(.plain)

                    Button {
                        model.addEurolitePLL480()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "square.grid.3x3.fill")
                            Text("PLL-480 Wash")
                                .font(.system(size: 10, weight: .semibold))
                        }
                        .foregroundStyle(Theme.text.swiftUI)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.08)))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.white.opacity(0.04))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
        )
    }

    private var selectionAndGroupBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            selectionHeaderRow
            selectionChipsRow
            selectionActionsRow
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.035)))
    }

    private var selectionHeaderRow: some View {
        let vpIndices = model.onlyVideoProjectorIndices
        let selectedVPs = selectedCategoryIndices
        return HStack(spacing: 4) {
            Text(L("Vidéoprojecteurs (\(selectedVPs.count)/\(vpIndices.count))",
                   "Video Projectors (\(selectedVPs.count)/\(vpIndices.count))"))
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Theme.textDim.swiftUI)

            if selectedVPs.count > 1 {
                let totalLumens = selectedVPs.reduce(0) { $0 + model.videoProjectors[$1].spec.lumens }
                Text("· \(Format.integer(totalLumens)) lm")
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(Theme.alive.swiftUI)
            }

            Spacer()

            if vpIndices.count > 1 {
                Button {
                    model.selectAllOnlyVideoProjectors()
                } label: {
                    Text(L("Tout", "All"))
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(Theme.alive.swiftUI)
                }
                .buttonStyle(.plain)
                .help(L("Sélectionner tous les VPs pour modification groupée", "Select all VPs for group editing"))

                Text("·")
                    .font(.system(size: 9.5))
                    .foregroundStyle(Theme.textFaint.swiftUI)

                Button {
                    if let first = selectedVPs.first ?? vpIndices.first {
                        model.selectVideoProjector(first)
                    }
                } label: {
                    Text(L("Seul", "Single"))
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(Theme.textDim.swiftUI)
                }
                .buttonStyle(.plain)
                .help(L("Ne sélectionner que le VP actif", "Select only active VP"))
            }
        }
    }

    private var selectionChipsRow: some View {
        let vpIndices = model.onlyVideoProjectorIndices
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(Array(vpIndices.enumerated()), id: \.element) { vpNumber, index in
                    let item = model.videoProjectors[index]
                    let isSel = model.selectedVideoProjectorIndices.contains(index)
                    Button {
                        let flags = NSApp.currentEvent?.modifierFlags ?? NSEvent.modifierFlags
                        if flags.contains(.command) {
                            model.selectVideoProjector(index, toggling: true)
                        } else if flags.contains(.shift) {
                            model.selectVideoProjector(index, extending: true)
                        } else {
                            model.selectVideoProjector(index)
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(item.isEnabled ? Theme.alive.swiftUI : Theme.textFaint.swiftUI)
                                .frame(width: 5, height: 5)
                            Text("VP \(vpNumber + 1)")
                                .font(.system(size: 10, weight: isSel ? .bold : .regular))
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: 4.5)
                                .fill(isSel ? Theme.alive.swiftUI.opacity(0.20) : Color.white.opacity(0.04))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 4.5)
                                        .strokeBorder(isSel ? Theme.alive.swiftUI.opacity(0.65) : Color.white.opacity(0.08), lineWidth: 1)
                                )
                        )
                        .foregroundStyle(isSel ? Theme.alive.swiftUI : Theme.text.swiftUI)
                    }
                    .buttonStyle(.plain)
                    .help(L("\(item.name) — Clic : sélectionner · ⌘-clic : ajouter au groupe",
                            "\(item.name) — Click: select · ⌘-click: toggle in group"))
                }
            }
        }
    }

    private var selectionActionsRow: some View {
        let allEnabled = model.selectedVideoProjectors.allSatisfy(\.isEnabled)
        let allFrustum = model.selectedVideoProjectors.allSatisfy(\.showsFrustum)

        return HStack(spacing: 4) {
            ToolbarPillButton(
                title: allEnabled ? L("Éteindre", "Off") : L("Allumer", "On"),
                symbol: allEnabled ? "lightswitch.off" : "lightswitch.on",
                active: allEnabled,
                tooltip: L("Allumer ou éteindre la sélection", "Turn on or off selected projectors")
            ) {
                model.setSelectedVideoProjectorsEnabled(!allEnabled)
            }

            ToolbarPillButton(
                title: L("Faisceau", "Beam"),
                symbol: "cone.fill",
                active: allFrustum,
                tooltip: L("Afficher ou masquer les faisceaux 3D de la sélection", "Show or hide 3D beams for selection")
            ) {
                model.setSelectedVideoProjectorsFrustum(!allFrustum)
            }

            ToolbarPillButton(
                title: L("Dupl.", "Dupl."),
                symbol: "plus.square.on.square",
                active: false,
                tooltip: L("Dupliquer la sélection de projecteurs", "Duplicate selected projectors")
            ) {
                model.duplicateSelectedVideoProjectors()
            }

            ToolbarPillButton(
                title: L("Sym X=0", "Sym X=0"),
                symbol: "arrow.left.and.right",
                active: false,
                tooltip: L("Dupliquer en symétrie par rapport au milieu du plateau (X = 0) avec inversion du lens shift",
                           "Duplicate symmetrically across stage center (X = 0) with inverted lens shift")
            ) {
                model.duplicateSelectedProjectorSymmetricAcrossStage()
            }

            Spacer(minLength: 0)

            Button {
                model.removeSelectedVideoProjectors()
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.danger.swiftUI)
                    .frame(width: 22, height: 22)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Theme.danger.swiftUI.opacity(0.12)))
            }
            .buttonStyle(.plain)
            .help(L("Supprimer les vidéoprojecteurs sélectionnés", "Delete selected video projectors"))
        }
    }

    private func movementSection(primary proj: VideoProjector) -> some View {
        let isGroup = model.isMultipleProjectorSelection
        let range = model.pointLightCoordinateRange

        return VStack(alignment: .leading, spacing: 8) {
            SectionHeader(L("Déplacement & Visée 3D (m)", "3D Move & Aim (m)")) {
                if isGroup {
                    HStack(spacing: 3) {
                        Image(systemName: "link")
                            .font(.system(size: 9))
                            .foregroundStyle(Theme.alive.swiftUI)
                        Text(L("Groupe (\(model.selectedProjectorCount))", "Group (\(model.selectedProjectorCount))"))
                            .font(.system(size: 9.5, weight: .bold))
                            .foregroundStyle(Theme.alive.swiftUI)
                    }
                }
            }

            nudgeControlGroup(isGroup: isGroup)

            coordinatesControlGroup(primary: proj, range: range)

            placementToolsGroup

            orientationControlGroup(primary: proj)
        }
    }

    private func nudgeControlGroup(isGroup: Bool) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            // Quick Nudge Step Selector
            HStack(spacing: 4) {
                Text(L("Pas :", "Step:"))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Theme.textDim.swiftUI)

                ForEach([0.05, 0.10, 0.50, 1.00, 2.00], id: \.self) { s in
                    let isCurrent = abs(nudgeStep - Float(s)) < 0.001
                    Button {
                        nudgeStep = Float(s)
                    } label: {
                        Text(String(format: s < 1.0 ? "%.2f m" : "%.0f m", s))
                            .font(.system(size: 9.5, weight: isCurrent ? .bold : .regular, design: .monospaced))
                            .padding(.horizontal, 4.5)
                            .padding(.vertical, 2)
                            .background(
                                RoundedRectangle(cornerRadius: 3.5)
                                    .fill(isCurrent ? Theme.accent.swiftUI.opacity(0.22) : Color.white.opacity(0.04))
                                    .overlay(RoundedRectangle(cornerRadius: 3.5).strokeBorder(isCurrent ? Theme.accent.swiftUI.opacity(0.5) : Color.clear, lineWidth: 1))
                            )
                            .foregroundStyle(isCurrent ? Theme.accent.swiftUI : Theme.textDim.swiftUI)
                    }
                    .buttonStyle(.plain)
                }
            }

            // Fast Nudge Buttons for X, Y, Z
            VStack(spacing: 3.5) {
                nudgeRow(
                    axis: "X",
                    axisLabel: L("Jardin / Cour", "Left / Right"),
                    negText: "← -X",
                    posText: "+X →",
                    negTooltip: L("Déplacer vers Jardin (-X de \(String(format: "%.2f", nudgeStep)) m)", "Move Stage Left (-X by \(String(format: "%.2f", nudgeStep)) m)"),
                    posTooltip: L("Déplacer vers Cour (+X de \(String(format: "%.2f", nudgeStep)) m)", "Move Stage Right (+X by \(String(format: "%.2f", nudgeStep)) m)"),
                    color: NSColor(srgbRed: 0.92, green: 0.28, blue: 0.26, alpha: 1.0),
                    onNeg: { model.nudgeSelectedProjectors(deltaX: -nudgeStep) },
                    onPos: { model.nudgeSelectedProjectors(deltaX: +nudgeStep) }
                )
                nudgeRow(
                    axis: "Y",
                    axisLabel: L("Face / Lointain", "Front / Back"),
                    negText: "↓ -Y",
                    posText: "+Y ↑",
                    negTooltip: L("Déplacer vers la Face (-Y de \(String(format: "%.2f", nudgeStep)) m)", "Move towards Front (-Y by \(String(format: "%.2f", nudgeStep)) m)"),
                    posTooltip: L("Déplacer vers le Lointain (+Y de \(String(format: "%.2f", nudgeStep)) m)", "Move towards Back (+Y by \(String(format: "%.2f", nudgeStep)) m)"),
                    color: NSColor(srgbRed: 0.25, green: 0.78, blue: 0.36, alpha: 1.0),
                    onNeg: { model.nudgeSelectedProjectors(deltaY: -nudgeStep) },
                    onPos: { model.nudgeSelectedProjectors(deltaY: +nudgeStep) }
                )
                nudgeRow(
                    axis: "Z",
                    axisLabel: L("Sol / Grill", "Floor / Grid"),
                    negText: "↓ -Z",
                    posText: "+Z ↑",
                    negTooltip: L("Descendre vers le Sol (-Z de \(String(format: "%.2f", nudgeStep)) m)", "Lower towards Floor (-Z by \(String(format: "%.2f", nudgeStep)) m)"),
                    posTooltip: L("Monter vers le Grill (+Z de \(String(format: "%.2f", nudgeStep)) m)", "Raise towards Grid (+Z by \(String(format: "%.2f", nudgeStep)) m)"),
                    color: NSColor(srgbRed: 0.24, green: 0.54, blue: 0.96, alpha: 1.0),
                    onNeg: { model.nudgeSelectedProjectors(deltaZ: -nudgeStep) },
                    onPos: { model.nudgeSelectedProjectors(deltaZ: +nudgeStep) }
                )
            }
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.025)))

            if isGroup {
                Text(L("Le déplacement par pas translate la position et la visée de tous les VPs sélectionnés en conservant leur écart.",
                       "Nudging translates position and aim of all selected VPs while preserving their spacing."))
                    .font(.system(size: 9.5))
                    .foregroundStyle(Theme.alive.swiftUI.opacity(0.85))
            }
        }
    }

    private func coordinatesControlGroup(primary proj: VideoProjector, range: ClosedRange<Double>) -> some View {
        VStack(spacing: 5) {
            vpCoordRow(
                axis: "X",
                color: NSColor(srgbRed: 0.92, green: 0.28, blue: 0.26, alpha: 1.0),
                value: proj.position.x,
                range: range,
                onSliderChange: { newX in
                    let deltaX = newX - proj.position.x
                    model.moveSelectedProjectors(delta: SIMD3<Float>(deltaX, 0, 0), coalesceKey: "pos-x")
                },
                onDiscreteChange: { newX in
                    let deltaX = newX - proj.position.x
                    model.moveSelectedProjectors(delta: SIMD3<Float>(deltaX, 0, 0))
                }
            )

            vpCoordRow(
                axis: "Y",
                color: NSColor(srgbRed: 0.25, green: 0.78, blue: 0.36, alpha: 1.0),
                value: proj.position.y,
                range: range,
                onSliderChange: { newY in
                    let deltaY = newY - proj.position.y
                    model.moveSelectedProjectors(delta: SIMD3<Float>(0, deltaY, 0), coalesceKey: "pos-y")
                },
                onDiscreteChange: { newY in
                    let deltaY = newY - proj.position.y
                    model.moveSelectedProjectors(delta: SIMD3<Float>(0, deltaY, 0))
                }
            )

            vpCoordRow(
                axis: "Z",
                color: NSColor(srgbRed: 0.24, green: 0.54, blue: 0.96, alpha: 1.0),
                value: proj.position.z,
                range: range,
                onSliderChange: { newZ in
                    let deltaZ = newZ - proj.position.z
                    model.moveSelectedProjectors(delta: SIMD3<Float>(0, 0, deltaZ), coalesceKey: "pos-z")
                },
                onDiscreteChange: { newZ in
                    let deltaZ = newZ - proj.position.z
                    model.moveSelectedProjectors(delta: SIMD3<Float>(0, 0, deltaZ))
                }
            )
        }
    }

    private var placementToolsGroup: some View {
        HStack(spacing: 4) {
            ToolbarPillButton(
                title: L("Caméra", "Camera"),
                symbol: "video",
                active: false,
                tooltip: L("Placer à la position et visée de la caméra", "Place at camera position and aim")
            ) {
                model.moveSelectedProjectorToCamera()
            }

            ToolbarPillButton(
                title: L("Clic pos.", "Pick pos."),
                symbol: "scope",
                active: model.projectorPickMode == .position,
                tooltip: L("Cliquer dans la vue 3D pour placer la position du vidéoprojecteur",
                           "Click in 3D view to place projector lens")
            ) {
                model.startPickingProjectorPosition()
            }

            ToolbarPillButton(
                title: L("Clic cible", "Pick tgt."),
                symbol: "target",
                active: model.projectorPickMode == .target,
                tooltip: L("Cliquer dans la vue 3D pour viser la cible du vidéoprojecteur",
                           "Click in 3D view to aim projector target")
            ) {
                model.startPickingProjectorTarget()
            }

            ToolbarPillButton(
                title: L("Voir VP", "View VP"),
                symbol: "eye",
                active: false,
                tooltip: L("Placer la caméra dans l'axe du projecteur sélectionné", "Look through selected projector")
            ) {
                model.lookThroughSelectedProjector()
            }
        }
    }

    private func orientationControlGroup(primary proj: VideoProjector) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(L("Azimut (Pan)", "Azimuth (Pan)"))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textDim.swiftUI)
                Spacer()
                EditableNumericValue(
                    value: proj.panDegrees,
                    displayFormat: "%+.1f°",
                    editFormat: "%.2f",
                    width: 58
                ) { newPan in
                    model.updateSelectedVideoProjector(actionName: L("Azimut VP", "VP Azimuth")) {
                        $0.setPanTilt(panDegrees: newPan, tiltDegrees: $0.tiltDegrees)
                    }
                }
                FineStepButtons(normalStep: 1.0, fineStep: 0.1, coarseStep: 10.0, unit: "°") { delta in
                    model.updateSelectedVideoProjector(actionName: L("Azimut VP", "VP Azimuth")) {
                        $0.setPanTilt(panDegrees: $0.panDegrees + delta, tiltDegrees: $0.tiltDegrees)
                    }
                }
            }
            Slider(
                value: Binding(
                    get: { Double(proj.panDegrees) },
                    set: { newPan in
                        model.updateSelectedVideoProjector(actionName: L("Azimut VP", "VP Azimuth"), coalesceKey: "pan") {
                            $0.setPanTilt(panDegrees: Float(newPan), tiltDegrees: $0.tiltDegrees)
                        }
                    }
                ),
                in: -180.0...180.0
            )
            .controlSize(.small)
            .tint(Theme.accent.swiftUI)

            HStack(spacing: 6) {
                Text(L("Inclinaison (Tilt)", "Elevation (Tilt)"))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textDim.swiftUI)
                Spacer()
                EditableNumericValue(
                    value: proj.tiltDegrees,
                    displayFormat: "%+.1f°",
                    editFormat: "%.2f",
                    width: 58
                ) { newTilt in
                    model.updateSelectedVideoProjector(actionName: L("Inclinaison VP", "VP Tilt")) {
                        $0.setPanTilt(panDegrees: $0.panDegrees, tiltDegrees: newTilt)
                    }
                }
                FineStepButtons(normalStep: 1.0, fineStep: 0.1, coarseStep: 10.0, unit: "°") { delta in
                    model.updateSelectedVideoProjector(actionName: L("Inclinaison VP", "VP Tilt")) {
                        $0.setPanTilt(panDegrees: $0.panDegrees, tiltDegrees: $0.tiltDegrees + delta)
                    }
                }
            }
            Slider(
                value: Binding(
                    get: { Double(proj.tiltDegrees) },
                    set: { newTilt in
                        model.updateSelectedVideoProjector(actionName: L("Inclinaison VP", "VP Tilt"), coalesceKey: "tilt") {
                            $0.setPanTilt(panDegrees: $0.panDegrees, tiltDegrees: Float(newTilt))
                        }
                    }
                ),
                in: -89.0...89.0
            )
            .controlSize(.small)
            .tint(Theme.accent.swiftUI)

            HStack(spacing: 4) {
                Text(L("Roulis", "Roll"))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textDim.swiftUI)
                Spacer()
                ForEach([0, 90, -90, 180], id: \.self) { angle in
                    ToolbarPillButton(
                        title: "\(angle)°",
                        active: abs(proj.rollDegrees - Float(angle)) < 0.5
                    ) {
                        model.updateSelectedVideoProjector(actionName: L("Roulis VP", "VP Roll")) {
                            $0.rollDegrees = Float(angle)
                        }
                    }
                }
                EditableNumericValue(
                    value: proj.rollDegrees,
                    displayFormat: "%+.1f°",
                    editFormat: "%.1f",
                    width: 50
                ) { newRoll in
                    model.updateSelectedVideoProjector(actionName: L("Roulis VP", "VP Roll")) {
                        $0.rollDegrees = newRoll
                    }
                }
            }
        }
    }

    private func nudgeRow(
        axis: String,
        axisLabel: String,
        negText: String,
        posText: String,
        negTooltip: String,
        posTooltip: String,
        color: NSColor,
        onNeg: @escaping () -> Void,
        onPos: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 5) {
            Text(axis)
                .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                .foregroundStyle(Color(nsColor: color))
                .frame(width: 14, alignment: .leading)

            Button(action: onNeg) {
                Text(negText)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.text.swiftUI)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 3.5)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.06)))
            }
            .buttonStyle(.plain)
            .help(negTooltip)

            Text(axisLabel)
                .font(.system(size: 9.5))
                .foregroundStyle(Theme.textDim.swiftUI)
                .frame(width: 80, alignment: .center)
                .lineLimit(1)

            Button(action: onPos) {
                Text(posText)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.text.swiftUI)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 3.5)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.06)))
            }
            .buttonStyle(.plain)
            .help(posTooltip)
        }
    }

    private func opticsSection(primary proj: VideoProjector) -> some View {
        let spec = proj.spec

        return VStack(alignment: .leading, spacing: 7) {
            SectionHeader(L("Optique & Objectif", "Optics & Lens")) {
                if abs(proj.lensShiftH) > 0.005 || abs(proj.lensShiftV) > 0.005 || abs(proj.throwRatio - spec.defaultThrowRatio) > 0.005 {
                    Button {
                        model.updateSelectedVideoProjector(actionName: L("Centrer optique VP", "Center VP Optics")) {
                            $0.throwRatio = spec.defaultThrowRatio
                            $0.lensShiftH = 0
                            $0.lensShiftV = 0
                        }
                    } label: {
                        Text(L("Centrer", "Center"))
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Theme.accent.swiftUI)
                    }
                    .buttonStyle(.plain)
                }
            }

            // Name field & Model Selector
            VStack(spacing: 5) {
                EditableStringField(
                    text: proj.name,
                    placeholder: L("Nom du VP", "VP Name")
                ) { newName in
                    model.updateSelectedVideoProjector(actionName: L("Renommer VP", "Rename VP")) {
                        $0.name = newName
                    }
                }

                Menu {
                    ForEach(ProjectorCatalog.videoProjectorSpecs) { item in
                        Button {
                            if model.isMultipleProjectorSelection {
                                model.setSelectedVideoProjectorsSpec(item)
                            } else {
                                model.updateSelectedVideoProjector(actionName: L("Modèle VP", "VP Model")) { $0.applySpec(item) }
                            }
                        } label: {
                            HStack {
                                Text(item.displayName)
                                if item.id == proj.specID {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "videoprojector")
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.alive.swiftUI)
                        Text(spec.displayName)
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(Theme.text.swiftUI)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 4)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 8.5, weight: .bold))
                            .foregroundStyle(Theme.textDim.swiftUI)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4.5)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(Color.white.opacity(0.06))
                            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.white.opacity(0.10), lineWidth: 1))
                    )
                }
                .menuStyle(.borderlessButton)
            }

            // Specs pill
            HStack(spacing: 6) {
                Text("\(spec.resolutionLabel) · \(Format.integer(spec.lumens)) lm")
                    .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Theme.alive.swiftUI)
                    .lineLimit(1)
                Spacer(minLength: 2)
                Text(String(
                    format: "D %.2f m → %.2f × %.2f m",
                    proj.throwDistance,
                    proj.projectedWidth(),
                    proj.projectedHeight()
                ))
                .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(Theme.text.swiftUI)
                .lineLimit(1)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 4.5).fill(Color.white.opacity(0.045)))

            // Throw Ratio
            let isFixedLens = (spec.maxThrowRatio - spec.minThrowRatio) < 0.001
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(isFixedLens ? L("Rapport (Focale fixe)", "Ratio (Fixed)") : L("Rapport de projection (Zoom)", "Throw ratio (Zoom)"))
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textDim.swiftUI)
                    Spacer()
                    if isFixedLens {
                        Text(String(format: "%.3g : 1", spec.defaultThrowRatio))
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(Theme.text.swiftUI)
                    } else {
                        EditableNumericValue(
                            value: proj.throwRatio,
                            displayFormat: "%.3f : 1",
                            editFormat: "%.3f",
                            width: 76
                        ) { newTR in
                            model.updateSelectedVideoProjector(actionName: L("Zoom VP", "VP Zoom")) {
                                $0.throwRatio = simd_clamp(newTR, spec.minThrowRatio, spec.maxThrowRatio)
                            }
                        }
                        FineStepButtons(normalStep: 0.01, fineStep: 0.001, coarseStep: 0.05, unit: "") { delta in
                            model.updateSelectedVideoProjector(actionName: L("Zoom VP", "VP Zoom")) {
                                $0.throwRatio = simd_clamp($0.throwRatio + delta, spec.minThrowRatio, spec.maxThrowRatio)
                            }
                        }
                    }
                }
                if !isFixedLens {
                    Slider(
                        value: Binding(
                            get: { Double(simd_clamp(proj.throwRatio, spec.minThrowRatio, spec.maxThrowRatio)) },
                            set: { val in
                                model.updateSelectedVideoProjector(actionName: L("Zoom VP", "VP Zoom"), coalesceKey: "zoom") {
                                    $0.throwRatio = simd_clamp(Float(val), spec.minThrowRatio, spec.maxThrowRatio)
                                }
                            }
                        ),
                        in: Double(spec.minThrowRatio)...Double(max(spec.maxThrowRatio, spec.minThrowRatio + 0.01))
                    )
                    .controlSize(.small)
                    .tint(Theme.alive.swiftUI)
                }
            }

            // Lens Shift Vertical
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(L("Lens Shift V (±\(Int((spec.maxLensShiftV * 100).rounded())) %)",
                           "Vertical Shift (±\(Int((spec.maxLensShiftV * 100).rounded()))%)"))
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textDim.swiftUI)
                    Spacer()
                    EditableNumericValue(
                        value: proj.lensShiftV * 100.0,
                        displayFormat: "%+.1f %%",
                        editFormat: "%.1f",
                        width: 58
                    ) { newPct in
                        model.updateSelectedVideoProjector(actionName: L("Lens Shift V", "Vertical Shift")) {
                            $0.lensShiftV = simd_clamp(newPct / 100.0, -spec.maxLensShiftV, spec.maxLensShiftV)
                        }
                    }
                    FineStepButtons(normalStep: 1.0, fineStep: 0.1, coarseStep: 5.0, unit: " %") { deltaPct in
                        model.updateSelectedVideoProjector(actionName: L("Lens Shift V", "Vertical Shift")) {
                            $0.lensShiftV = simd_clamp($0.lensShiftV + deltaPct / 100.0, -spec.maxLensShiftV, spec.maxLensShiftV)
                        }
                    }
                }
                Slider(
                    value: Binding(
                        get: { Double(proj.lensShiftV) },
                        set: { val in
                            model.updateSelectedVideoProjector(actionName: L("Lens Shift V", "Vertical Shift"), coalesceKey: "shift-v") {
                                $0.lensShiftV = simd_clamp(Float(val), -spec.maxLensShiftV, spec.maxLensShiftV)
                            }
                        }
                    ),
                    in: Double(-spec.maxLensShiftV)...Double(spec.maxLensShiftV)
                )
                .controlSize(.small)
                .tint(Theme.accent.swiftUI)
            }

            // Lens Shift Horizontal
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(L("Lens Shift H (±\(Int((spec.maxLensShiftH * 100).rounded())) %)",
                           "Horizontal Shift (±\(Int((spec.maxLensShiftH * 100).rounded()))%)"))
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textDim.swiftUI)
                    Spacer()
                    EditableNumericValue(
                        value: proj.lensShiftH * 100.0,
                        displayFormat: "%+.1f %%",
                        editFormat: "%.1f",
                        width: 58
                    ) { newPct in
                        model.updateSelectedVideoProjector(actionName: L("Lens Shift H", "Horizontal Shift")) {
                            $0.lensShiftH = simd_clamp(newPct / 100.0, -spec.maxLensShiftH, spec.maxLensShiftH)
                        }
                    }
                    FineStepButtons(normalStep: 1.0, fineStep: 0.1, coarseStep: 5.0, unit: " %") { deltaPct in
                        model.updateSelectedVideoProjector(actionName: L("Lens Shift H", "Horizontal Shift")) {
                            $0.lensShiftH = simd_clamp($0.lensShiftH + deltaPct / 100.0, -spec.maxLensShiftH, spec.maxLensShiftH)
                        }
                    }
                }
                Slider(
                    value: Binding(
                        get: { Double(proj.lensShiftH) },
                        set: { val in
                            model.updateSelectedVideoProjector(actionName: L("Lens Shift H", "Horizontal Shift"), coalesceKey: "shift-h") {
                                $0.lensShiftH = simd_clamp(Float(val), -spec.maxLensShiftH, spec.maxLensShiftH)
                            }
                        }
                    ),
                    in: Double(-spec.maxLensShiftH)...Double(spec.maxLensShiftH)
                )
                .controlSize(.small)
                .tint(Theme.accent.swiftUI)
            }
        }
    }

    // MARK: - Beam Shaping Section (Couteaux, Volets & Netteté)

    private func beamShapingSection(primary proj: VideoProjector) -> some View {
        let isProfile = (proj.spec.kind == .profileSpot)
        let isWash = (proj.spec.kind == .washPanel)

        let sectionTitle: String
        let shutterLabel: String
        if isProfile {
            sectionTitle = L("Couteaux de cadrage (Découpe)", "Framing Shutters (Profile)")
            shutterLabel = L("Couteau", "Shutter")
        } else if isWash {
            sectionTitle = L("Coupe-flux & Volets (Wash)", "Barn Doors (Wash)")
            shutterLabel = L("Volet", "Door")
        } else {
            sectionTitle = L("Masquage & Cadrage (Shutters)", "Beam Framing (Shutters)")
            shutterLabel = L("Masque", "Mask")
        }

        return VStack(alignment: .leading, spacing: 7) {
            SectionHeader(sectionTitle) {
                if proj.shutterTop > 0 || proj.shutterBottom > 0 || proj.shutterLeft > 0 || proj.shutterRight > 0 {
                    Button {
                        model.setSelectedProjectorShutters(top: 0, bottom: 0, left: 0, right: 0)
                    } label: {
                        Text(L("Ouvrir tout", "Open All"))
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Theme.alive.swiftUI)
                    }
                    .buttonStyle(.plain)
                    .help(L("Ouvrir complètement les 4 couteaux/volets", "Fully open all 4 shutters/doors"))
                }
            }

            // 4 Shutters: Top, Bottom, Left, Right
            shutterSliderRow(title: "\(shutterLabel) \(L("Haut", "Top"))", value: proj.shutterTop) { val in
                model.setSelectedProjectorShutters(top: val)
            }
            shutterSliderRow(title: "\(shutterLabel) \(L("Bas", "Bottom"))", value: proj.shutterBottom) { val in
                model.setSelectedProjectorShutters(bottom: val)
            }
            shutterSliderRow(title: "\(shutterLabel) \(L("Gauche", "Left"))", value: proj.shutterLeft) { val in
                model.setSelectedProjectorShutters(left: val)
            }
            shutterSliderRow(title: "\(shutterLabel) \(L("Droit", "Right"))", value: proj.shutterRight) { val in
                model.setSelectedProjectorShutters(right: val)
            }

            // Edge Softness / Focus
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(isWash ? L("Diffusion douce", "Soft Diffusion") : L("Netteté du faisceau (Focus)", "Beam Focus / Softness"))
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textDim.swiftUI)
                    Spacer()
                    Text(String(format: "%.0f %%", proj.edgeSoftness * 100))
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(Theme.text.swiftUI)
                }
                Slider(
                    value: Binding(
                        get: { Double(proj.edgeSoftness) },
                        set: { val in model.setSelectedProjectorEdgeSoftness(Float(val)) }
                    ),
                    in: 0.0...1.0
                )
                .controlSize(.small)
                .tint(Theme.accent.swiftUI)
            }

            // Light Color Tint / Gel filter
            HStack(spacing: 6) {
                Text(L("Teinte / Gélatine", "Color Tint / Gel"))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textDim.swiftUI)
                Spacer()

                // Quick presets
                ToolbarPillButton(title: "3200K", active: abs(proj.lightColor.x - 1.0) < 0.05 && abs(proj.lightColor.y - 0.86) < 0.05) {
                    model.setSelectedProjectorLightColor(SIMD3<Float>(1.0, 0.86, 0.68))
                }
                ToolbarPillButton(title: L("Blanc", "White"), active: abs(proj.lightColor.x - 1.0) < 0.02 && abs(proj.lightColor.y - 1.0) < 0.02 && abs(proj.lightColor.z - 1.0) < 0.02) {
                    model.setSelectedProjectorLightColor(SIMD3<Float>(1.0, 1.0, 1.0))
                }

                ColorPicker("", selection: Binding(
                    get: {
                        Color(red: Double(proj.lightColor.x), green: Double(proj.lightColor.y), blue: Double(proj.lightColor.z))
                    },
                    set: { newColor in
                        if let cg = newColor.cgColor, let comp = cg.components, comp.count >= 3 {
                            model.setSelectedProjectorLightColor(SIMD3<Float>(Float(comp[0]), Float(comp[1]), Float(comp[2])))
                        }
                    }
                ))
                .labelsHidden()
                .scaleEffect(0.85)
            }
        }
    }

    private func shutterSliderRow(title: String, value: Float, onChange: @escaping (Float) -> Void) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.textDim.swiftUI)
                .frame(width: 95, alignment: .leading)

            Slider(
                value: Binding(
                    get: { Double(value) },
                    set: { onChange(Float($0)) }
                ),
                in: 0.0...1.0
            )
            .controlSize(.small)
            .tint(Theme.alive.swiftUI)

            Text(String(format: "%.0f %%", value * 100))
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundStyle(value > 0.01 ? Theme.alive.swiftUI : Theme.textDim.swiftUI)
                .frame(width: 36, alignment: .trailing)
        }
    }

    // MARK: - Photometrics & Illuminance Section

    private func photometricsSection(primary proj: VideoProjector) -> some View {
        let surfaceDist = model.actualSurfaceDistance(for: proj)
        let evalDistance = surfaceDist ?? proj.throwDistance
        let isSurfaceHit = (surfaceDist != nil)

        return VStack(alignment: .leading, spacing: 7) {
            SectionHeader(L("Photométrie & Éclairement", "Photometrics & Illuminance")) {
                Button {
                    model.togglePhotometricSimulation()
                } label: {
                    HStack(spacing: 3) {
                        Circle()
                            .fill(model.photometricSimulation ? Theme.alive.swiftUI : Theme.textDim.swiftUI)
                            .frame(width: 6, height: 6)
                        Text(model.photometricSimulation ? L("Simu 3D ON", "3D Sim ON") : L("Simu OFF", "Sim OFF"))
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(model.photometricSimulation ? Theme.alive.swiftUI : Theme.textDim.swiftUI)
                    }
                }
                .buttonStyle(.plain)
                .help(L("Activer la simulation réaliste dans le viewport 3D (loi 1/d², lumens et ouverture)",
                        "Toggle realistic 3D simulation in viewport (1/d² law, lumens and lens spread)"))
            }

            photometricsCard(proj: proj, evalDistance: evalDistance, isSurfaceHit: isSurfaceHit)
            photometricsImageMetricsRow(proj: proj, evalDistance: evalDistance)
            photometricsOpticalEfficiencyRow(proj: proj)
            photometricsSimulationControls()
        }
    }

    private func photometricsCard(proj: VideoProjector, evalDistance: Float, isSurfaceHit: Bool) -> some View {
        let lux = proj.illuminanceLux(atDistance: evalDistance)
        let nits = proj.surfaceLuminanceNits(atDistance: evalDistance)
        let fl = proj.surfaceLuminanceFootLamberts(atDistance: evalDistance)
        let rating = proj.photometricRating(atDistance: evalDistance)
        let color = ratingColor(rating)

        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(Format.integer(Int(lux.rounded())))
                    .font(.system(size: 19, weight: .bold, design: .monospaced))
                    .foregroundStyle(color)
                Text("lx")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(color)

                Spacer()

                Text(rating.localizedTitle)
                    .font(.system(size: 9.5, weight: .semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2.5)
                    .background(Capsule().fill(color.opacity(0.18)))
                    .foregroundStyle(color)
            }

            HStack(spacing: 4) {
                Text("≈ \(Format.integer(Int(nits.rounded()))) cd/m² · \(Format.integer(Int(fl.rounded()))) fL")
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(Theme.textDim.swiftUI)
                Spacer()
                Text(isSurfaceHit ? String(format: "à %.2f m (surface)", evalDistance) : String(format: "à %.2f m (cible)", evalDistance))
                    .font(.system(size: 9.5))
                    .foregroundStyle(Theme.textFaint.swiftUI)
            }

            Text(rating.localizedHint)
                .font(.system(size: 9))
                .foregroundStyle(Theme.textFaint.swiftUI)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.white.opacity(0.04))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(color.opacity(0.25), lineWidth: 1))
        )
    }

    private func ratingColor(_ rating: VideoProjector.PhotometricRating) -> Color {
        switch rating {
        case .optimalMapping:
            return Theme.alive.swiftUI
        case .highPunch:
            return Theme.accent.swiftUI
        case .theaterAmbiance:
            return Color.orange.opacity(0.95)
        case .lowContrast:
            return Color.red.opacity(0.85)
        }
    }

    private func photometricsImageMetricsRow(proj: VideoProjector, evalDistance: Float) -> some View {
        let w = proj.projectedWidth(atDistance: evalDistance)
        let h = proj.projectedHeight(atDistance: evalDistance)
        let diag = proj.projectedDiagonal(atDistance: evalDistance)
        let area = proj.projectedArea(atDistance: evalDistance)

        return HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(L("Taille image", "Image Size"))
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.textFaint.swiftUI)
                Text(String(format: "%.2f × %.2f m", w, h))
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Theme.text.swiftUI)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                Text(L("Surface & Diagonale", "Area & Diagonal"))
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.textFaint.swiftUI)
                Text(String(format: "%.1f m² · %.1f m (%.0f\")", area, diag, diag * 39.3701))
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Theme.text.swiftUI)
            }
        }
        .padding(.horizontal, 4)
    }

    private func photometricsOpticalEfficiencyRow(proj: VideoProjector) -> some View {
        HStack(spacing: 6) {
            Text(L("Flux émis :", "Emitted Flux:"))
                .font(.system(size: 9.5))
                .foregroundStyle(Theme.textDim.swiftUI)
            Text("\(Format.integer(Int(proj.effectiveLumens.rounded()))) ANSI lm")
                .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(Theme.text.swiftUI)
            Text(String(format: "(optique %.0f %%)", proj.lensTransmission * 100))
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(Theme.textFaint.swiftUI)
            Spacer()
            Text(proj.spec.displayName)
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(Theme.textDim.swiftUI)
        }
        .padding(.horizontal, 4)
    }

    private func photometricsSimulationControls() -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Toggle(isOn: Binding(
                    get: { model.photometricSimulation },
                    set: { val in model.setPhotometricSimulation(val) }
                )) {
                    Text(L("Rendu 3D photométrique réaliste", "Realistic 3D Photometric Render"))
                        .font(.system(size: 10.5))
                        .foregroundStyle(model.photometricSimulation ? Theme.text.swiftUI : Theme.textDim.swiftUI)
                }
                .toggleStyle(.checkbox)

                Spacer()
            }

            if model.photometricSimulation {
                HStack(spacing: 3) {
                    Text(L("Réf.", "Ref."))
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.textFaint.swiftUI)
                        .frame(width: 24, alignment: .leading)
                    ForEach([150, 250, 400, 600], id: \.self) { refVal in
                        ToolbarPillButton(
                            title: "\(refVal) lx",
                            active: abs(model.photometricReferenceLux - Float(refVal)) < 30
                        ) {
                            model.setPhotometricReferenceLux(Float(refVal))
                        }
                    }
                }
            }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.025)))
    }

    private func patternAndPowerSection(primary proj: VideoProjector) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader(L("Mire & Puissance", "Pattern & Power"))

            // Pattern Buttons
            HStack(spacing: 4) {
                ToolbarPillButton(
                    title: L("Mire", "Grid"),
                    symbol: "squareshape.split.3x3",
                    active: proj.pattern == .testGrid
                ) {
                    if model.isMultipleProjectorSelection {
                        model.setSelectedVideoProjectorsPattern(.testGrid)
                    } else {
                        model.updateSelectedVideoProjector(actionName: L("Mire VP", "VP Pattern")) { $0.pattern = .testGrid }
                    }
                }
                ToolbarPillButton(
                    title: L("Barres", "Bars"),
                    symbol: "chart.bar.fill",
                    active: proj.pattern == .colorBars
                ) {
                    if model.isMultipleProjectorSelection {
                        model.setSelectedVideoProjectorsPattern(.colorBars)
                    } else {
                        model.updateSelectedVideoProjector(actionName: L("Mire VP", "VP Pattern")) { $0.pattern = .colorBars }
                    }
                }
                ToolbarPillButton(
                    title: L("Cadre", "Frame"),
                    symbol: "rectangle.inset.filled",
                    active: proj.pattern == .whiteFrame
                ) {
                    if model.isMultipleProjectorSelection {
                        model.setSelectedVideoProjectorsPattern(.whiteFrame)
                    } else {
                        model.updateSelectedVideoProjector(actionName: L("Mire VP", "VP Pattern")) { $0.pattern = .whiteFrame }
                    }
                }
                ToolbarPillButton(
                    title: L("Image…", "Image…"),
                    symbol: "photo",
                    active: proj.pattern == .customImage
                ) {
                    model.chooseCustomImageForSelectedProjector()
                }
            }

            // Live stream buttons
            HStack(spacing: 4) {
                ToolbarPillButton(
                    title: L("Syphon", "Syphon"),
                    symbol: "bolt.horizontal.circle",
                    active: proj.pattern == .syphon,
                    tooltip: L("Projeter un flux vidéo Syphon temps réel", "Project a live Syphon stream")
                ) {
                    model.activateLiveStreamPattern(.syphon)
                }
                ToolbarPillButton(
                    title: L("NDI", "NDI"),
                    symbol: "antenna.radiowaves.left.and.right",
                    active: proj.pattern == .ndi,
                    tooltip: L("Projeter un flux vidéo NDI réseau", "Project a live NDI stream")
                ) {
                    model.activateLiveStreamPattern(.ndi)
                }
                Spacer(minLength: 0)
            }

            if proj.pattern == .syphon || proj.pattern == .ndi {
                liveStreamPickerRow(proj: proj)
            }

            // Light Intensity
            HStack(spacing: 6) {
                Text(L("Intensité", "Intensity"))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textDim.swiftUI)
                Spacer()
                EditableNumericValue(
                    value: proj.intensity * 100.0,
                    displayFormat: "%.0f %%",
                    editFormat: "%.1f",
                    width: 54
                ) { newPct in
                    let clamped = simd_clamp(Float(newPct) / 100.0, 0.0, 3.0)
                    if model.isMultipleProjectorSelection {
                        model.setSelectedVideoProjectorsIntensity(clamped)
                    } else {
                        model.updateSelectedVideoProjector(actionName: L("Intensité VP", "VP Intensity")) {
                            $0.intensity = clamped
                        }
                    }
                }
                FineStepButtons(normalStep: 5.0, fineStep: 1.0, coarseStep: 25.0, unit: " %") { deltaPct in
                    let clamped = simd_clamp(proj.intensity + Float(deltaPct) / 100.0, 0.0, 3.0)
                    if model.isMultipleProjectorSelection {
                        model.setSelectedVideoProjectorsIntensity(clamped)
                    } else {
                        model.updateSelectedVideoProjector(actionName: L("Intensité VP", "VP Intensity")) {
                            $0.intensity = clamped
                        }
                    }
                }
            }
            Slider(
                value: Binding(
                    get: { Double(proj.intensity) },
                    set: { val in
                        let fVal = Float(val)
                        if model.isMultipleProjectorSelection {
                            model.setSelectedVideoProjectorsIntensity(fVal, coalesceKey: "intensity")
                        } else {
                            model.updateSelectedVideoProjector(actionName: L("Intensité VP", "VP Intensity"), coalesceKey: "intensity") {
                                $0.intensity = fVal
                            }
                        }
                    }
                ),
                in: 0.0...2.5
            )
            .controlSize(.small)
            .tint(Theme.alive.swiftUI)

            // Reverb Intensity
            HStack(spacing: 6) {
                Text(L("Réverbération", "Reverberation"))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textDim.swiftUI)
                Spacer()
                EditableNumericValue(
                    value: proj.reverbIntensity * 100.0,
                    displayFormat: "%.0f %%",
                    editFormat: "%.1f",
                    width: 54
                ) { newPct in
                    let clamped = simd_clamp(Float(newPct) / 100.0, 0.0, 2.5)
                    if model.isMultipleProjectorSelection {
                        model.setSelectedVideoProjectorsReverb(clamped)
                    } else {
                        model.updateSelectedVideoProjector(actionName: L("Réverbération VP", "VP Reverberation")) {
                            $0.reverbIntensity = clamped
                        }
                    }
                }
                FineStepButtons(normalStep: 5.0, fineStep: 1.0, coarseStep: 25.0, unit: " %") { deltaPct in
                    let clamped = simd_clamp(proj.reverbIntensity + Float(deltaPct) / 100.0, 0.0, 2.5)
                    if model.isMultipleProjectorSelection {
                        model.setSelectedVideoProjectorsReverb(clamped)
                    } else {
                        model.updateSelectedVideoProjector(actionName: L("Réverbération VP", "VP Reverberation")) {
                            $0.reverbIntensity = clamped
                        }
                    }
                }
            }
            Slider(
                value: Binding(
                    get: { Double(proj.reverbIntensity) },
                    set: { val in
                        let fVal = Float(val)
                        if model.isMultipleProjectorSelection {
                            model.setSelectedVideoProjectorsReverb(fVal, coalesceKey: "reverb")
                        } else {
                            model.updateSelectedVideoProjector(actionName: L("Réverbération VP", "VP Reverberation"), coalesceKey: "reverb") {
                                $0.reverbIntensity = fVal
                            }
                        }
                    }
                ),
                in: 0.0...2.0
            )
            .controlSize(.small)
            .tint(Theme.accent.swiftUI)

            // Frustum Only toggle & Save .sskp
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Toggle(isOn: Binding(
                        get: { proj.showsFrustum || model.projectorsFrustumOnly },
                        set: { val in
                            if model.projectorsFrustumOnly && !val {
                                model.setProjectorsFrustumOnly(false)
                            }
                            if model.isMultipleProjectorSelection {
                                model.setSelectedVideoProjectorsFrustum(val)
                            } else {
                                model.updateSelectedVideoProjector(actionName: L("Faisceau 3D VP", "VP 3D Frustum")) {
                                    $0.showsFrustum = val
                                }
                            }
                        }
                    )) {
                        Text(L("Afficher le faisceau 3D (Frustum)", "Show 3D beam frustum"))
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.text.swiftUI)
                    }
                    .toggleStyle(.checkbox)

                    Spacer()

                    TextButton(
                        title: L("Sauver .sskp", "Save .sskp"),
                        symbol: "square.and.arrow.down",
                        compact: true
                    ) {
                        model.saveSSKPProject()
                    }
                }

                Toggle(isOn: Binding(
                    get: { model.projectorsFrustumOnly },
                    set: { val in model.setProjectorsFrustumOnly(val) }
                )) {
                    Text(L("Frustum seul (réglage rapide, sans projection)", "Frustum only (fast setup, no projection)"))
                        .font(.system(size: 11))
                        .foregroundStyle(model.projectorsFrustumOnly ? Theme.alive.swiftUI : Theme.textDim.swiftUI)
                }
                .toggleStyle(.checkbox)
                .help(L("Afficher uniquement les faisceaux 3D (frustums) sans calculer la projection lumineuse ni les ombres",
                        "Show only 3D frustums without computing light projection or shadows"))
            }
        }
    }

    private func liveStreamPickerRow(proj: VideoProjector) -> some View {
        let isSyphon = (proj.pattern == .syphon)
        let sources = isSyphon ? model.availableSyphonSources : model.availableNDISources
        let selectedID = proj.liveSourceID ?? ""
        let matchedSource = sources.first(where: { $0.id == selectedID }) ?? sources.first(where: {
            guard let savedName = proj.liveSourceName, !savedName.isEmpty else { return false }
            return $0.displayTitle.caseInsensitiveCompare(savedName) == .orderedSame ||
                   $0.name.caseInsensitiveCompare(savedName) == .orderedSame
        })
        let isOnline = (matchedSource != nil)

        return HStack(spacing: 5) {
            Circle()
                .fill(isOnline ? Theme.alive.swiftUI : Color.orange.opacity(0.85))
                .frame(width: 6.5, height: 6.5)
            Text(isSyphon ? "Syphon" : "NDI")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Theme.textDim.swiftUI)
            Spacer()
            if sources.isEmpty {
                Text(
                    (proj.liveSourceName?.isEmpty == false)
                    ? "\(proj.liveSourceName ?? "") (\(L("hors ligne", "offline")))"
                    : (isSyphon ? L("Aucun serveur Syphon", "No Syphon server") : L("Aucune source NDI", "No NDI source"))
                )
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundStyle(Theme.textDim.swiftUI)
                .lineLimit(1)
            } else {
                Menu {
                    ForEach(sources) { src in
                        Button {
                            model.selectLiveVideoSource(id: src.id, forKind: proj.pattern)
                        } label: {
                            Text(src.displayTitle)
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(matchedSource?.displayTitle ?? proj.liveSourceName ?? L("Choisir…", "Select…"))
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Theme.text.swiftUI)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 8.5, weight: .bold))
                            .foregroundStyle(Theme.textDim.swiftUI)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.07)))
                }
                .menuStyle(.borderlessButton)
                .frame(maxWidth: 190, alignment: .trailing)
            }

            Button {
                model.refreshLiveVideoSources()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(Theme.text.swiftUI)
                    .frame(width: 18, height: 18)
                    .background(RoundedRectangle(cornerRadius: 3.5).fill(Color.white.opacity(0.08)))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 4.5).fill(Color.white.opacity(0.045)))
        .onAppear { model.refreshLiveVideoSources() }
    }

    // MARK: - Dedicated Stage Light Inspector Sections

    private var milluminCueSheetSection: some View {
        let cues = model.milluminCues
        let activeIdx = model.activeMilluminCueIndex

        return VStack(alignment: .leading, spacing: 6) {
            SectionHeader(L("Conduite Lumière Millumin", "Millumin Cue Sheet")) {
                HStack(spacing: 4) {
                    if let board = model.milluminBoardName, !board.isEmpty {
                        Text(board)
                            .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Theme.accent.swiftUI)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(maxWidth: 85, alignment: .trailing)
                    }
                    Button {
                        model.previousMilluminCue()
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 9.5, weight: .bold))
                            .foregroundStyle(Theme.text.swiftUI)
                            .frame(width: 18, height: 18)
                            .background(RoundedRectangle(cornerRadius: 3.5).fill(Color.white.opacity(0.08)))
                    }
                    .buttonStyle(.plain)
                    .help(L("État / Cue lumière précédent", "Previous lighting cue"))

                    Button {
                        model.nextMilluminCue()
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9.5, weight: .bold))
                            .foregroundStyle(Theme.text.swiftUI)
                            .frame(width: 18, height: 18)
                            .background(RoundedRectangle(cornerRadius: 3.5).fill(Color.white.opacity(0.08)))
                    }
                    .buttonStyle(.plain)
                    .help(L("État / Cue lumière suivant", "Next lighting cue"))
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 5) {
                    ForEach(Array(cues.enumerated()), id: \.element.id) { idx, cue in
                        let isSelected = (activeIdx == idx)
                        Button {
                            model.applyMilluminCue(at: idx)
                        } label: {
                            HStack(spacing: 4) {
                                Text("\(idx + 1).")
                                    .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                                    .foregroundStyle(isSelected ? Theme.accent.swiftUI : Theme.textDim.swiftUI)
                                Text(cue.title)
                                    .font(.system(size: 10, weight: isSelected ? .bold : .medium))
                                    .lineLimit(1)
                                if cue.transitionDuration > 0 {
                                    Text(String(format: "%.0fs", cue.transitionDuration))
                                        .font(.system(size: 8.5, design: .monospaced))
                                        .foregroundStyle(Theme.textFaint.swiftUI)
                                }
                            }
                            .padding(.horizontal, 7)
                            .padding(.vertical, 4)
                            .background(
                                RoundedRectangle(cornerRadius: 4.5)
                                    .fill(isSelected ? Theme.accent.swiftUI.opacity(0.22) : Color.white.opacity(0.045))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 4.5)
                                            .strokeBorder(isSelected ? Theme.accent.swiftUI.opacity(0.7) : Color.white.opacity(0.08), lineWidth: 1)
                                    )
                            )
                            .foregroundStyle(isSelected ? Theme.accent.swiftUI : Theme.text.swiftUI)
                        }
                        .buttonStyle(.plain)
                        .help(L("Rappeler la conduite « \(cue.title) » (\(cue.valuesByLightName.count) lumières)",
                                "Recall cue “\(cue.title)” (\(cue.valuesByLightName.count) lights)"))
                    }
                }
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Theme.accent.swiftUI.opacity(0.06))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.accent.swiftUI.opacity(0.22), lineWidth: 1))
        )
    }

    private var stageLightSelectionAndGroupBar: some View {
        let lightIndices = model.stageLightIndices
        let selectedLights = selectedCategoryIndices

        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text(L("Lumières (\(selectedLights.count)/\(lightIndices.count))",
                       "Lights (\(selectedLights.count)/\(lightIndices.count))"))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Theme.textDim.swiftUI)

                if selectedLights.count > 1 {
                    let totalLumens = selectedLights.reduce(0) { $0 + model.videoProjectors[$1].spec.lumens }
                    Text("· \(Format.integer(totalLumens)) lm")
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(Theme.accent.swiftUI)
                }

                Spacer()

                if lightIndices.count > 1 {
                    Button {
                        model.selectAllStageLights()
                    } label: {
                        Text(L("Tout", "All"))
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(Theme.accent.swiftUI)
                    }
                    .buttonStyle(.plain)
                    .help(L("Sélectionner toutes les lumières pour modification groupée", "Select all stage lights for group editing"))

                    Text("·")
                        .font(.system(size: 9.5))
                        .foregroundStyle(Theme.textFaint.swiftUI)

                    Button {
                        if let first = selectedLights.first ?? lightIndices.first {
                            model.selectVideoProjector(first)
                        }
                    } label: {
                        Text(L("Seul", "Single"))
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(Theme.textDim.swiftUI)
                    }
                    .buttonStyle(.plain)
                    .help(L("Ne sélectionner que la lumière active", "Select only active light"))
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(lightIndices, id: \.self) { index in
                        let item = model.videoProjectors[index]
                        let isSel = model.selectedVideoProjectorIndices.contains(index)
                        let effRGB = simd_clamp(item.effectiveBeamRGB, SIMD3<Float>(repeating: 0), SIMD3<Float>(repeating: 1))
                        let dotColor = Color(
                            red: Double(effRGB.x),
                            green: Double(effRGB.y),
                            blue: Double(effRGB.z)
                        )
                        Button {
                            let flags = NSApp.currentEvent?.modifierFlags ?? NSEvent.modifierFlags
                            if flags.contains(.command) {
                                model.selectVideoProjector(index, toggling: true)
                            } else if flags.contains(.shift) {
                                model.selectVideoProjector(index, extending: true)
                            } else {
                                model.selectVideoProjector(index)
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Circle()
                                    .fill(item.isEnabled ? dotColor : Theme.textFaint.swiftUI)
                                    .frame(width: 6, height: 6)
                                    .overlay(Circle().strokeBorder(Color.white.opacity(0.3), lineWidth: 0.5))
                                Text(item.name)
                                    .font(.system(size: 10, weight: isSel ? .bold : .regular))
                                    .lineLimit(1)
                                Text("\(Int((item.intensity * 100).rounded()))%")
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundStyle(isSel ? Theme.accent.swiftUI : Theme.textDim.swiftUI)
                            }
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(
                                RoundedRectangle(cornerRadius: 4.5)
                                    .fill(isSel ? Theme.accent.swiftUI.opacity(0.20) : Color.white.opacity(0.04))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 4.5)
                                            .strokeBorder(isSel ? Theme.accent.swiftUI.opacity(0.65) : Color.white.opacity(0.08), lineWidth: 1)
                                    )
                            )
                            .foregroundStyle(isSel ? Theme.accent.swiftUI : Theme.text.swiftUI)
                        }
                        .buttonStyle(.plain)
                        .help(L("\(item.name) — Clic : sélectionner · ⌘-clic : ajouter au groupe",
                                "\(item.name) — Click: select · ⌘-click: toggle in group"))
                    }
                }
            }

            selectionActionsRow
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.035)))
    }

    private func stageLightDimmerAndColorSection(primary light: VideoProjector) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            SectionHeader(L("Gradateur & Couleur", "Dimmer & Color")) {
                HStack(spacing: 2.5) {
                    ForEach([0, 25, 50, 75, 100], id: \.self) { pct in
                        let fVal = Float(pct) / 100.0
                        let isCur = abs(light.intensity - fVal) < 0.02
                        Button {
                            if model.isMultipleProjectorSelection {
                                model.setSelectedVideoProjectorsIntensity(fVal)
                            } else {
                                model.updateSelectedVideoProjector(actionName: L("Gradateur Lumière", "Light Dimmer")) {
                                    $0.intensity = fVal
                                }
                            }
                        } label: {
                            Text("\(pct)%")
                                .font(.system(size: 8.5, weight: isCur ? .bold : .medium, design: .monospaced))
                                .padding(.horizontal, 3.5)
                                .padding(.vertical, 1.5)
                                .background(
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(isCur ? Theme.accent.swiftUI.opacity(0.24) : Color.white.opacity(0.05))
                                )
                                .foregroundStyle(isCur ? Theme.accent.swiftUI : Theme.textDim.swiftUI)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            // Dimmer (Intensity)
            HStack(spacing: 6) {
                Text(L("Intensité (Dimmer)", "Dimmer Intensity"))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textDim.swiftUI)
                Spacer()
                EditableNumericValue(
                    value: light.intensity * 100.0,
                    displayFormat: "%.0f %%",
                    editFormat: "%.1f",
                    width: 54
                ) { newPct in
                    let clamped = simd_clamp(Float(newPct) / 100.0, 0.0, 3.0)
                    if model.isMultipleProjectorSelection {
                        model.setSelectedVideoProjectorsIntensity(clamped)
                    } else {
                        model.updateSelectedVideoProjector(actionName: L("Intensité Lumière", "Light Dimmer")) {
                            $0.intensity = clamped
                        }
                    }
                }
                FineStepButtons(normalStep: 5.0, fineStep: 1.0, coarseStep: 25.0, unit: " %") { deltaPct in
                    let clamped = simd_clamp(light.intensity + Float(deltaPct) / 100.0, 0.0, 3.0)
                    if model.isMultipleProjectorSelection {
                        model.setSelectedVideoProjectorsIntensity(clamped)
                    } else {
                        model.updateSelectedVideoProjector(actionName: L("Intensité Lumière", "Light Dimmer")) {
                            $0.intensity = clamped
                        }
                    }
                }
            }
            Slider(
                value: Binding(
                    get: { Double(light.intensity) },
                    set: { val in
                        let fVal = Float(val)
                        if model.isMultipleProjectorSelection {
                            model.setSelectedVideoProjectorsIntensity(fVal, coalesceKey: "light-intensity")
                        } else {
                            model.updateSelectedVideoProjector(actionName: L("Intensité Lumière", "Light Dimmer"), coalesceKey: "light-intensity") {
                                $0.intensity = fVal
                            }
                        }
                    }
                ),
                in: 0.0...2.5
            )
            .controlSize(.small)
            .tint(Theme.accent.swiftUI)

            // Color / Gel presets, ColorPicker & RGB / RGBW Sliders
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 4) {
                    Text(L("Couleur / RGBW", "Color / RGBW"))
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textDim.swiftUI)
                    Spacer()

                    ToolbarPillButton(title: "2800K", active: abs(light.lightColor.x - 1.0) < 0.03 && abs(light.lightColor.y - 0.76) < 0.05 && light.whiteChannel < 0.05) {
                        model.setSelectedProjectorLightColor(SIMD3<Float>(1.0, 0.76, 0.52), white: 0.0)
                    }
                    ToolbarPillButton(title: "3200K", active: abs(light.lightColor.x - 1.0) < 0.03 && abs(light.lightColor.y - 0.86) < 0.05 && light.whiteChannel < 0.05) {
                        model.setSelectedProjectorLightColor(SIMD3<Float>(1.0, 0.86, 0.68), white: 0.0)
                    }
                    ToolbarPillButton(title: "4200K", active: abs(light.lightColor.x - 1.0) < 0.03 && abs(light.lightColor.y - 0.94) < 0.04 && light.whiteChannel < 0.05) {
                        model.setSelectedProjectorLightColor(SIMD3<Float>(1.0, 0.94, 0.86), white: 0.0)
                    }
                    ToolbarPillButton(title: "5600K", active: abs(light.lightColor.x - 1.0) < 0.02 && abs(light.lightColor.y - 1.0) < 0.02 && abs(light.lightColor.z - 1.0) < 0.02 && light.whiteChannel < 0.05) {
                        model.setSelectedProjectorLightColor(SIMD3<Float>(1.0, 1.0, 1.0), white: 0.0)
                    }
                    ToolbarPillButton(title: "RGB+W", active: light.whiteChannel > 0.85 && light.lightColor.x > 0.85 && light.lightColor.y > 0.85 && light.lightColor.z > 0.85) {
                        model.setSelectedProjectorLightColor(SIMD3<Float>(1.0, 1.0, 1.0), white: 1.0)
                    }
                }

                HStack(spacing: 4) {
                    ToolbarPillButton(title: L("Ambre", "Amber"), active: abs(light.lightColor.x - 1.0) < 0.04 && abs(light.lightColor.y - 0.58) < 0.06 && light.lightColor.z < 0.25) {
                        model.setSelectedProjectorLightColor(SIMD3<Float>(1.0, 0.58, 0.14), white: 0.0)
                    }
                    ToolbarPillButton(title: L("Rouge", "Red"), active: light.lightColor.x > 0.9 && light.lightColor.y < 0.25 && light.lightColor.z < 0.25) {
                        model.setSelectedProjectorLightColor(SIMD3<Float>(1.0, 0.12, 0.08), white: 0.0)
                    }
                    ToolbarPillButton(title: L("Vert", "Green"), active: light.lightColor.y > 0.85 && light.lightColor.x < 0.25 && light.lightColor.z < 0.35) {
                        model.setSelectedProjectorLightColor(SIMD3<Float>(0.10, 0.95, 0.22), white: 0.0)
                    }
                    ToolbarPillButton(title: L("Bleu", "Blue"), active: light.lightColor.x < 0.30 && light.lightColor.y < 0.45 && light.lightColor.z > 0.85) {
                        model.setSelectedProjectorLightColor(SIMD3<Float>(0.14, 0.34, 1.0), white: 0.0)
                    }
                    ToolbarPillButton(title: "Cyan", active: light.lightColor.x < 0.25 && light.lightColor.y > 0.80 && light.lightColor.z > 0.85) {
                        model.setSelectedProjectorLightColor(SIMD3<Float>(0.10, 0.88, 1.0), white: 0.0)
                    }
                    ToolbarPillButton(title: "Magenta", active: light.lightColor.x > 0.85 && light.lightColor.y < 0.28 && light.lightColor.z > 0.75) {
                        model.setSelectedProjectorLightColor(SIMD3<Float>(1.0, 0.14, 0.86), white: 0.0)
                    }

                    Spacer(minLength: 2)

                    let previewRGB = simd_clamp(light.effectiveBeamRGB, SIMD3<Float>(repeating: 0), SIMD3<Float>(repeating: 1))
                    ColorPicker("", selection: Binding(
                        get: {
                            Color(red: Double(previewRGB.x), green: Double(previewRGB.y), blue: Double(previewRGB.z))
                        },
                        set: { newColor in
                            if let cg = newColor.cgColor, let comp = cg.components, comp.count >= 3 {
                                model.setSelectedProjectorLightColor(SIMD3<Float>(Float(comp[0]), Float(comp[1]), Float(comp[2])), white: 0.0)
                            }
                        }
                    ))
                    .labelsHidden()
                    .scaleEffect(0.85)
                }

                // Direct R / G / B / W LED Diode Sliders (0–100% / DMX 0–255)
                VStack(spacing: 3) {
                    rgbwChannelRow(
                        label: "R",
                        color: Color(red: 0.96, green: 0.28, blue: 0.26),
                        value: light.lightColor.x
                    ) { newVal in
                        model.setSelectedProjectorRGBW(r: newVal, coalesceKey: "rgbw-r")
                    }
                    rgbwChannelRow(
                        label: "G",
                        color: Color(red: 0.26, green: 0.88, blue: 0.42),
                        value: light.lightColor.y
                    ) { newVal in
                        model.setSelectedProjectorRGBW(g: newVal, coalesceKey: "rgbw-g")
                    }
                    rgbwChannelRow(
                        label: "B",
                        color: Color(red: 0.32, green: 0.58, blue: 1.00),
                        value: light.lightColor.z
                    ) { newVal in
                        model.setSelectedProjectorRGBW(b: newVal, coalesceKey: "rgbw-b")
                    }
                    rgbwChannelRow(
                        label: "W",
                        color: Color(red: 1.00, green: 0.93, blue: 0.78),
                        value: light.whiteChannel
                    ) { newVal in
                        model.setSelectedProjectorRGBW(w: newVal, coalesceKey: "rgbw-w")
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color.white.opacity(0.03))
                        .overlay(
                            RoundedRectangle(cornerRadius: 5)
                                .strokeBorder(Color.white.opacity(0.06), lineWidth: 0.5)
                        )
                )
            }

            // Indirect bounce / Reverberation
            HStack(spacing: 6) {
                Text(L("Réverbération (rebond)", "Indirect Bounce"))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textDim.swiftUI)
                Spacer()
                EditableNumericValue(
                    value: light.reverbIntensity * 100.0,
                    displayFormat: "%.0f %%",
                    editFormat: "%.1f",
                    width: 54
                ) { newPct in
                    let clamped = simd_clamp(Float(newPct) / 100.0, 0.0, 2.5)
                    if model.isMultipleProjectorSelection {
                        model.setSelectedVideoProjectorsReverb(clamped)
                    } else {
                        model.updateSelectedVideoProjector(actionName: L("Réverbération Lumière", "Light Bounce")) {
                            $0.reverbIntensity = clamped
                        }
                    }
                }
                FineStepButtons(normalStep: 5.0, fineStep: 1.0, coarseStep: 25.0, unit: " %") { deltaPct in
                    let clamped = simd_clamp(light.reverbIntensity + Float(deltaPct) / 100.0, 0.0, 2.5)
                    if model.isMultipleProjectorSelection {
                        model.setSelectedVideoProjectorsReverb(clamped)
                    } else {
                        model.updateSelectedVideoProjector(actionName: L("Réverbération Lumière", "Light Bounce")) {
                            $0.reverbIntensity = clamped
                        }
                    }
                }
            }
            Slider(
                value: Binding(
                    get: { Double(light.reverbIntensity) },
                    set: { val in
                        let fVal = Float(val)
                        if model.isMultipleProjectorSelection {
                            model.setSelectedVideoProjectorsReverb(fVal, coalesceKey: "light-reverb")
                        } else {
                            model.updateSelectedVideoProjector(actionName: L("Réverbération Lumière", "Light Bounce"), coalesceKey: "light-reverb") {
                                $0.reverbIntensity = fVal
                            }
                        }
                    }
                ),
                in: 0.0...2.0
            )
            .controlSize(.small)
            .tint(Theme.accent.swiftUI)
        }
    }

    private func rgbwChannelRow(
        label: String,
        color: Color,
        value: Float,
        onChange: @escaping (Float) -> Void
    ) -> some View {
        let dmxInt = Int((simd_clamp(value, 0.0, 1.0) * 255.0).rounded())
        return HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(color)
                .frame(width: 14, alignment: .leading)
            Slider(
                value: Binding(
                    get: { Double(simd_clamp(value, 0.0, 1.0)) },
                    set: { onChange(Float($0)) }
                ),
                in: 0.0...1.0
            )
            .controlSize(.mini)
            .tint(color)
            Text("\(Int((simd_clamp(value, 0.0, 1.0) * 100.0).rounded()))%")
                .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                .foregroundStyle(Theme.text.swiftUI)
                .frame(width: 34, alignment: .trailing)
            Text("(\(dmxInt))")
                .font(.system(size: 8.5, design: .monospaced))
                .foregroundStyle(Theme.textDim.swiftUI)
                .frame(width: 32, alignment: .trailing)
        }
    }

    private func stageLightOpticsAndShuttersSection(primary light: VideoProjector) -> some View {
        let spec = light.spec
        let minDeg = spec.minBeamAngleDegrees
        let maxDeg = max(spec.maxBeamAngleDegrees, minDeg + 1.0)
        let isZoomable = (maxDeg - minDeg) > 1.5
        let isProfile = (spec.kind == .profileSpot)
        let shutterLabel = isProfile ? L("Couteau", "Shutter") : L("Volet", "Barn Door")

        return VStack(alignment: .leading, spacing: 7) {
            SectionHeader(L("Projecteur, Ouverture (°) & Couteaux", "Fixture, Beam Angle (°) & Shutters")) {
                if light.shutterTop > 0 || light.shutterBottom > 0 || light.shutterLeft > 0 || light.shutterRight > 0 {
                    Button {
                        model.setSelectedProjectorShutters(top: 0, bottom: 0, left: 0, right: 0)
                    } label: {
                        Text(L("Ouvrir tout", "Open All"))
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Theme.accent.swiftUI)
                    }
                    .buttonStyle(.plain)
                }
            }

            // Light Name & Stage Fixture Model Selector
            VStack(spacing: 5) {
                EditableStringField(
                    text: light.name,
                    placeholder: L("Nom de la lumière", "Light Name")
                ) { newName in
                    model.updateSelectedVideoProjector(actionName: L("Renommer Lumière", "Rename Light")) {
                        $0.name = newName
                    }
                }

                Menu {
                    ForEach(ProjectorCatalog.stageLightSpecs) { item in
                        Button {
                            if model.isMultipleProjectorSelection {
                                model.setSelectedVideoProjectorsSpec(item)
                            } else {
                                model.updateSelectedVideoProjector(actionName: L("Type de projecteur", "Fixture Model")) { $0.applySpec(item) }
                            }
                        } label: {
                            HStack {
                                Text(item.displayName)
                                if item.id == light.specID {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: isProfile ? "flashlight.on.fill" : "light.cylindrical.ceiling.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.accent.swiftUI)
                        Text(spec.displayName)
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(Theme.text.swiftUI)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 4)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 8.5, weight: .bold))
                            .foregroundStyle(Theme.textDim.swiftUI)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4.5)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(Color.white.opacity(0.06))
                            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.white.opacity(0.10), lineWidth: 1))
                    )
                }
                .menuStyle(.borderlessButton)
            }

            // Beam Angle in Degrees (°)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(isZoomable
                         ? L("Ouverture / Zoom (\(Int(minDeg))°–\(Int(maxDeg))°)", "Beam Zoom (\(Int(minDeg))°–\(Int(maxDeg))°)")
                         : L("Ouverture du faisceau", "Beam Angle"))
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textDim.swiftUI)
                    Spacer()
                    EditableNumericValue(
                        value: light.beamAngleDegrees,
                        displayFormat: "%.1f°",
                        editFormat: "%.1f",
                        width: 58
                    ) { newDeg in
                        model.setSelectedStageLightBeamAngle(simd_clamp(newDeg, minDeg, maxDeg))
                    }
                    FineStepButtons(normalStep: 1.0, fineStep: 0.2, coarseStep: 5.0, unit: "°") { delta in
                        model.setSelectedStageLightBeamAngle(simd_clamp(light.beamAngleDegrees + delta, minDeg, maxDeg))
                    }
                }
                Slider(
                    value: Binding(
                        get: { Double(simd_clamp(light.beamAngleDegrees, minDeg, maxDeg)) },
                        set: { val in
                            model.setSelectedStageLightBeamAngle(Float(val), coalesceKey: "beam-angle")
                        }
                    ),
                    in: Double(minDeg)...Double(maxDeg)
                )
                .controlSize(.small)
                .tint(Theme.accent.swiftUI)
            }

            // Focus / Frost / Edge Softness
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(isProfile ? L("Focus / Netteté des bords", "Edge Focus / Frost") : L("Diffusion (Frost / Wash)", "Wash Diffusion"))
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textDim.swiftUI)
                    Spacer()
                    Text(String(format: "%.0f %%", light.edgeSoftness * 100))
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(Theme.text.swiftUI)
                }
                Slider(
                    value: Binding(
                        get: { Double(light.edgeSoftness) },
                        set: { val in model.setSelectedProjectorEdgeSoftness(Float(val)) }
                    ),
                    in: 0.0...1.0
                )
                .controlSize(.small)
                .tint(Theme.accent.swiftUI)
            }

            // 4 Shutters / Barn doors
            shutterSliderRow(title: "\(shutterLabel) \(L("Haut", "Top"))", value: light.shutterTop) { val in
                model.setSelectedProjectorShutters(top: val)
            }
            shutterSliderRow(title: "\(shutterLabel) \(L("Bas", "Bottom"))", value: light.shutterBottom) { val in
                model.setSelectedProjectorShutters(bottom: val)
            }
            shutterSliderRow(title: "\(shutterLabel) \(L("Gauche", "Left"))", value: light.shutterLeft) { val in
                model.setSelectedProjectorShutters(left: val)
            }
            shutterSliderRow(title: "\(shutterLabel) \(L("Droit", "Right"))", value: light.shutterRight) { val in
                model.setSelectedProjectorShutters(right: val)
            }
        }
    }

    private func stageLightMovementSection(primary light: VideoProjector) -> some View {
        let isGroup = selectedCategoryIndices.count > 1
        let range = model.pointLightCoordinateRange

        return VStack(alignment: .leading, spacing: 8) {
            SectionHeader(L("Position au Grill & Pointage 3D (m)", "Rig Position & 3D Aiming (m)")) {
                if isGroup {
                    HStack(spacing: 3) {
                        Image(systemName: "link")
                            .font(.system(size: 9))
                            .foregroundStyle(Theme.accent.swiftUI)
                        Text(L("Groupe (\(selectedCategoryIndices.count))", "Group (\(selectedCategoryIndices.count))"))
                            .font(.system(size: 9.5, weight: .bold))
                            .foregroundStyle(Theme.accent.swiftUI)
                    }
                }
            }

            nudgeControlGroup(isGroup: isGroup)

            coordinatesControlGroup(primary: light, range: range)

            // Stage Light Quick Aiming Tools (including "Douche 90°")
            HStack(spacing: 4) {
                ToolbarPillButton(
                    title: L("Douche 90°", "Down 90°"),
                    symbol: "arrow.down.to.line",
                    active: abs(light.tiltDegrees + 89.9) < 1.5,
                    tooltip: L("Pointer verticalement vers le sol du plateau (Douche à la verticale)", "Aim straight down at the stage floor (Top-down wash/spot)")
                ) {
                    model.aimSelectedProjectorStraightDown()
                }

                ToolbarPillButton(
                    title: L("Clic pos.", "Pick pos."),
                    symbol: "scope",
                    active: model.projectorPickMode == .position,
                    tooltip: L("Cliquer dans la vue 3D pour placer le projecteur", "Click in 3D view to place fixture")
                ) {
                    model.startPickingProjectorPosition()
                }

                ToolbarPillButton(
                    title: L("Clic cible", "Pick tgt."),
                    symbol: "target",
                    active: model.projectorPickMode == .target,
                    tooltip: L("Cliquer sur le plateau 3D pour pointer le faisceau", "Click on 3D stage to aim beam")
                ) {
                    model.startPickingProjectorTarget()
                }

                ToolbarPillButton(
                    title: L("Voir axe", "Look"),
                    symbol: "eye",
                    active: false,
                    tooltip: L("Placer la caméra dans l'axe du projecteur", "Look through fixture beam")
                ) {
                    model.lookThroughSelectedProjector()
                }
            }

            orientationControlGroup(primary: light)
        }
    }

    private func stageLightPhotometricsSection(primary light: VideoProjector) -> some View {
        let surfaceDist = model.actualSurfaceDistance(for: light)
        let evalDistance = surfaceDist ?? light.throwDistance
        let isSurfaceHit = (surfaceDist != nil)
        let diameter = light.projectedWidth(atDistance: evalDistance)

        return VStack(alignment: .leading, spacing: 7) {
            SectionHeader(L("Photométrie & Diamètre de Tache", "Photometrics & Beam Diameter")) {
                Text(String(format: "Ø %.2f m · %.1f°", diameter, light.beamAngleDegrees))
                    .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Theme.accent.swiftUI)
            }

            photometricsCard(proj: light, evalDistance: evalDistance, isSurfaceHit: isSurfaceHit)

            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(L("Diamètre au sol / cible", "Spot Diameter at Target"))
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.textFaint.swiftUI)
                    Text(String(format: "Ø %.2f m (%.1f m²)", diameter, light.projectedArea(atDistance: evalDistance)))
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Theme.text.swiftUI)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 1) {
                    Text(L("Flux lumineux", "Luminous Flux"))
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.textFaint.swiftUI)
                    Text("\(Format.integer(Int(light.effectiveLumens.rounded()))) lm")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Theme.text.swiftUI)
                }
            }
            .padding(.horizontal, 4)

            // Frustum visibility & Save .sskp
            HStack {
                Toggle(isOn: Binding(
                    get: { light.showsFrustum || model.projectorsFrustumOnly },
                    set: { val in
                        if model.projectorsFrustumOnly && !val {
                            model.setProjectorsFrustumOnly(false)
                        }
                        if model.isMultipleProjectorSelection {
                            model.setSelectedVideoProjectorsFrustum(val)
                        } else {
                            model.updateSelectedVideoProjector(actionName: L("Faisceau 3D Lumière", "Light 3D Cone")) {
                                $0.showsFrustum = val
                            }
                        }
                    }
                )) {
                    Text(L("Afficher le cône lumineux 3D", "Show 3D beam cone"))
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.text.swiftUI)
                }
                .toggleStyle(.checkbox)

                Spacer()

                TextButton(
                    title: L("Sauver .sskp", "Save .sskp"),
                    symbol: "square.and.arrow.down",
                    compact: true
                ) {
                    model.saveSSKPProject()
                }
            }
        }
    }

    private func stageLightDMXAndOFLSection(primary light: VideoProjector) -> some View {
        let oflFixtures = OFLFixtureLibrary.shared.allFixtures
        let currentDef = light.oflFixtureID.flatMap { OFLFixtureLibrary.shared.fixture(forIdentifier: $0) }

        return VStack(alignment: .leading, spacing: 7) {
            SectionHeader(L("Patch DMX, Art-Net & Fixture Millumin", "DMX Patch, Art-Net & Millumin Fixture")) {
                HStack(spacing: 4) {
                    Circle()
                        .fill(model.isArtNetActive ? Theme.alive.swiftUI : Color.orange.opacity(0.8))
                        .frame(width: 6, height: 6)
                    Text(model.isArtNetActive ? L("Art-Net Live", "Art-Net Live") : L("UDP 6454", "UDP 6454"))
                        .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(model.isArtNetActive ? Theme.alive.swiftUI : Theme.textDim.swiftUI)
                }
            }

            // Universe and Start Channel
            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("Univers Art-Net", "Art-Net Universe"))
                        .font(.system(size: 9.5))
                        .foregroundStyle(Theme.textDim.swiftUI)
                    Menu {
                        ForEach(0..<16, id: \.self) { u in
                            Button("Uni \(u)") {
                                model.setSelectedProjectorDMX(universe: u)
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text("Uni \(light.dmxUniverse)")
                                .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                                .foregroundStyle(Theme.text.swiftUI)
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(Theme.textDim.swiftUI)
                        }
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.white.opacity(0.06))
                                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
                        )
                    }
                    .menuStyle(.borderlessButton)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(L("Adresse DMX (1–512)", "DMX Address (1–512)"))
                        .font(.system(size: 9.5))
                        .foregroundStyle(Theme.textDim.swiftUI)
                    EditableNumericValue(
                        value: Float(light.dmxChannel),
                        displayFormat: "Ch %.0f",
                        editFormat: "%.0f",
                        width: 74
                    ) { newCh in
                        model.setSelectedProjectorDMX(channel: Int(newCh.rounded()))
                    }
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    Text(L("Plage DMX", "DMX Footprint"))
                        .font(.system(size: 9.5))
                        .foregroundStyle(Theme.textDim.swiftUI)
                    let endCh = min(512, light.dmxChannel + max(light.dmxChannelCount, 1) - 1)
                    Text("Ch \(light.dmxChannel)–\(endCh)")
                        .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                        .foregroundStyle(Theme.accent.swiftUI)
                }
            }

            // OFL Light-Fixture Selector (/Users/adrien/Library/Millumin/Light-fixtures)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(L("Fixture OFL (Millumin)", "OFL Fixture (Millumin)"))
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.textDim.swiftUI)
                    Spacer(minLength: 4)
                    Menu {
                        ForEach(oflFixtures) { def in
                            if def.modes.count <= 1 {
                                Button {
                                    model.setSelectedStageLightOFLFixture(definition: def, modeName: def.modes.first?.name)
                                } label: {
                                    Text("\(def.displayName) (\(def.modes.first?.channels.count ?? 1) ch)")
                                }
                            } else {
                                Menu(def.displayName) {
                                    ForEach(def.modes) { mode in
                                        Button {
                                            model.setSelectedStageLightOFLFixture(definition: def, modeName: mode.name)
                                        } label: {
                                            Text("\(mode.name) (\(mode.channels.count) ch)")
                                        }
                                    }
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(currentDef?.displayName ?? light.oflFixtureID ?? light.spec.displayName)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(Theme.text.swiftUI)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            if let mode = light.oflModeName, !mode.isEmpty {
                                Text("· \(mode)")
                                    .font(.system(size: 9.5, design: .monospaced))
                                    .foregroundStyle(Theme.accent.swiftUI)
                                    .lineLimit(1)
                            }
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(Theme.textDim.swiftUI)
                        }
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3.5)
                        .background(
                            RoundedRectangle(cornerRadius: 4.5)
                                .fill(Color.white.opacity(0.06))
                                .overlay(RoundedRectangle(cornerRadius: 4.5).strokeBorder(Color.white.opacity(0.10), lineWidth: 1))
                        )
                    }
                    .menuStyle(.borderlessButton)
                }
            }

            // Live DMX Channels Breakdown Table
            if !light.dmxChannelNames.isEmpty {
                VStack(alignment: .leading, spacing: 2.5) {
                    Text(L("Canaux DMX (\(light.dmxChannelNames.count) ch)", "DMX Channels (\(light.dmxChannelNames.count) ch)"))
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(Theme.textDim.swiftUI)

                    ForEach(Array(light.dmxChannelNames.enumerated()), id: \.offset) { offset, chName in
                        let absCh = light.dmxChannel + offset
                        let role = offset < light.dmxChannelRoles.count ? light.dmxChannelRoles[offset] : .ignored
                        let liveByte = model.liveDMXByte(universe: light.dmxUniverse, channel1Based: absCh)

                        HStack(spacing: 6) {
                            Text(String(format: "%03d", absCh))
                                .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                                .foregroundStyle(Theme.accent.swiftUI)
                                .frame(width: 26, alignment: .leading)

                            Text(chName)
                                .font(.system(size: 9.5))
                                .foregroundStyle(role == .ignored ? Theme.textFaint.swiftUI : Theme.text.swiftUI)
                                .lineLimit(1)

                            Spacer()

                            if let byte = liveByte {
                                Text("\(byte)")
                                    .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                                    .foregroundStyle(byte > 0 ? Theme.alive.swiftUI : Theme.textDim.swiftUI)
                                    .frame(width: 28, alignment: .trailing)
                            } else {
                                Text(role.rawValue)
                                    .font(.system(size: 8.5, design: .monospaced))
                                    .foregroundStyle(Theme.textFaint.swiftUI)
                            }
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 3.5).fill(Color.white.opacity(offset.isMultiple(of: 2) ? 0.035 : 0.015)))
                    }
                }
            }
        }
    }

    private func vpCoordRow(
        axis: String,
        color: NSColor,
        value: Float,
        range: ClosedRange<Double>,
        onSliderChange: @escaping (Float) -> Void,
        onDiscreteChange: @escaping (Float) -> Void
    ) -> some View {
        let clampedRange = min(range.lowerBound, Double(value) - 1.0)...max(range.upperBound, Double(value) + 1.0)
        return HStack(spacing: 5) {
            Text(axis)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(Color(nsColor: color))
                .frame(width: 14, alignment: .leading)

            Slider(
                value: Binding(
                    get: { Double(value) },
                    set: { onSliderChange(Float($0)) }
                ),
                in: clampedRange
            )
            .controlSize(.small)
            .tint(Color(nsColor: color))

            EditableNumericValue(
                value: value,
                displayFormat: "%+.2f m",
                editFormat: "%.3f",
                width: 62,
                onCommit: onDiscreteChange
            )

            FineStepButtons(
                normalStep: 0.10,
                fineStep: 0.01,
                coarseStep: 1.00,
                unit: " m"
            ) { delta in
                onDiscreteChange(value + delta)
            }
        }
    }
}

// Backward-compatibility alias
typealias ProjectorPopover = ProjectorInspectorView

// MARK: - Shared Fine-Tuning & Popover Undo/Redo Controls

private struct PopoverUndoRedoButtons: View {
    let model: DocumentModel

    var body: some View {
        HStack(spacing: 4) {
            Button {
                model.undo()
            } label: {
                HStack(spacing: 2) {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 10, weight: .semibold))
                }
                .padding(.horizontal, 5)
                .padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(model.canUndo ? 0.09 : 0.03)))
                .foregroundStyle(model.canUndo ? Theme.text.swiftUI : Theme.textDim.swiftUI.opacity(0.35))
            }
            .buttonStyle(.plain)
            .disabled(!model.canUndo)
            .keyboardShortcut("z", modifiers: [.command])
            .help(model.undoMenuTitle + " (⌘Z)")

            Button {
                model.redo()
            } label: {
                HStack(spacing: 2) {
                    Image(systemName: "arrow.uturn.forward")
                        .font(.system(size: 10, weight: .semibold))
                }
                .padding(.horizontal, 5)
                .padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(model.canRedo ? 0.09 : 0.03)))
                .foregroundStyle(model.canRedo ? Theme.text.swiftUI : Theme.textDim.swiftUI.opacity(0.35))
            }
            .buttonStyle(.plain)
            .disabled(!model.canRedo)
            .keyboardShortcut("z", modifiers: [.command, .shift])
            .help(model.redoMenuTitle + " (⇧⌘Z)")
        }
    }
}

/// Click-to-edit numeric badge: avoids auto-focusing a `TextField` when a popover opens, and lets the user
/// click any numeric value to type an exact value (supporting `.` or `,` decimal separators).
private struct EditableNumericValue: View {
    let value: Float
    let displayFormat: String
    let editFormat: String
    var width: CGFloat = 62
    let onCommit: (Float) -> Void

    @State private var isEditing = false
    @State private var draft = ""
    @State private var isHovering = false
    @FocusState private var isFocused: Bool

    var body: some View {
        if isEditing {
            TextField("", text: $draft)
                .textFieldStyle(.plain)
                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                .foregroundStyle(Theme.text.swiftUI)
                .multilineTextAlignment(.trailing)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .frame(width: width)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.black.opacity(0.45))
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .strokeBorder(Theme.accent.swiftUI, lineWidth: 1)
                        )
                )
                .focused($isFocused)
                .onSubmit { commit() }
                .onExitCommand { isEditing = false }
                .onChange(of: isFocused) { _, focused in
                    if !focused && isEditing {
                        commit()
                    }
                }
        } else {
            Button {
                draft = String(format: editFormat, value)
                isEditing = true
                DispatchQueue.main.async {
                    isFocused = true
                }
            } label: {
                Text(String(format: displayFormat, value))
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(Theme.text.swiftUI)
                    .lineLimit(1)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .frame(width: width, alignment: .trailing)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.white.opacity(isHovering ? 0.11 : 0.05))
                            .overlay(
                                RoundedRectangle(cornerRadius: 4)
                                    .strokeBorder(isHovering ? Theme.accent.swiftUI.opacity(0.65) : Color.white.opacity(0.08), lineWidth: 1)
                            )
                    )
            }
            .buttonStyle(.plain)
            .onHover { isHovering = $0 }
            .help(L("Cliquer pour saisir une valeur numérique exacte (Entrée pour valider, Échap pour annuler)",
                    "Click to type an exact numeric value (Enter to confirm, Esc to cancel)"))
        }
    }

    private func commit() {
        isEditing = false
        let cleaned = draft
            .replacingOccurrences(of: ",", with: ".")
            .replacingOccurrences(of: "%", with: "")
            .replacingOccurrences(of: "°", with: "")
            .replacingOccurrences(of: "m", with: "")
            .replacingOccurrences(of: ":1", with: "")
            .replacingOccurrences(of: ": 1", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let parsed = Float(cleaned), parsed.isFinite {
            onCommit(parsed)
        }
    }
}

/// Click-to-edit string badge for projector names so the popover never steals keyboard focus on open.
private struct EditableStringField: View {
    let text: String
    let placeholder: String
    let onCommit: (String) -> Void

    @State private var isEditing = false
    @State private var draft = ""
    @State private var isHovering = false
    @FocusState private var isFocused: Bool

    var body: some View {
        if isEditing {
            TextField(placeholder, text: $draft)
                .textFieldStyle(.plain)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Theme.text.swiftUI)
                .padding(.horizontal, 7)
                .padding(.vertical, 3.5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color.black.opacity(0.45))
                        .overlay(
                            RoundedRectangle(cornerRadius: 5)
                                .strokeBorder(Theme.accent.swiftUI, lineWidth: 1)
                        )
                )
                .focused($isFocused)
                .onSubmit { commit() }
                .onExitCommand { isEditing = false }
                .onChange(of: isFocused) { _, focused in
                    if !focused && isEditing {
                        commit()
                    }
                }
        } else {
            Button {
                draft = text
                isEditing = true
                DispatchQueue.main.async {
                    isFocused = true
                }
            } label: {
                HStack(spacing: 5) {
                    Text(text.isEmpty ? placeholder : text)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(text.isEmpty ? Theme.textFaint.swiftUI : Theme.text.swiftUI)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Image(systemName: "pencil")
                        .font(.system(size: 9.5))
                        .foregroundStyle(Theme.textFaint.swiftUI)
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 3.5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color.white.opacity(isHovering ? 0.10 : 0.05))
                        .overlay(
                            RoundedRectangle(cornerRadius: 5)
                                .strokeBorder(isHovering ? Theme.accent.swiftUI.opacity(0.6) : Color.white.opacity(0.08), lineWidth: 1)
                        )
                )
            }
            .buttonStyle(.plain)
            .onHover { isHovering = $0 }
            .help(L("Cliquer pour renommer ce vidéoprojecteur", "Click to rename this projector"))
        }
    }

    private func commit() {
        isEditing = false
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty && trimmed != text {
            onCommit(trimmed)
        }
    }
}

/// Pair of `-` / `+` stepper buttons with modifier-aware step sizes:
/// - Normal click: `±normalStep`
/// - `⌥-click` (`Alt`): `±fineStep` (fine adjustment)
/// - `⇧-click` (`Shift`): `±coarseStep` (coarse adjustment)
private struct FineStepButtons: View {
    let normalStep: Float
    let fineStep: Float
    let coarseStep: Float
    let unit: String
    let onStep: (Float) -> Void

    private static func resolvedStep(normal: Float, fine: Float, coarse: Float) -> Float {
        let flags = NSEvent.modifierFlags
        if flags.contains(.option) && flags.contains(.shift) {
            return fine * 0.25
        } else if flags.contains(.option) {
            return fine
        } else if flags.contains(.shift) {
            return coarse
        }
        return normal
    }

    private static func formatStep(_ v: Float) -> String {
        if abs(v - v.rounded()) < 1e-4 {
            return String(format: "%.0f", v)
        } else if abs(v * 10 - (v * 10).rounded()) < 1e-3 {
            return String(format: "%.1f", v)
        } else if abs(v * 100 - (v * 100).rounded()) < 1e-3 {
            return String(format: "%.2f", v)
        }
        return String(format: "%.3f", v)
    }

    private var tooltipText: String {
        let n = Self.formatStep(normalStep) + unit
        let f = Self.formatStep(fineStep) + unit
        let c = Self.formatStep(coarseStep) + unit
        return L(
            "Clic : ±\(n) · ⌥-clic (pas fin) : ±\(f) · ⇧-clic (grand pas) : ±\(c)",
            "Click: ±\(n) · ⌥-click (fine): ±\(f) · ⇧-click (coarse): ±\(c)"
        )
    }

    var body: some View {
        HStack(spacing: 2) {
            Button {
                let s = Self.resolvedStep(normal: normalStep, fine: fineStep, coarse: coarseStep)
                onStep(-s)
            } label: {
                Image(systemName: "minus")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 16, height: 16)
                    .background(RoundedRectangle(cornerRadius: 3).fill(Color.white.opacity(0.08)))
            }
            .buttonStyle(.plain)
            .help(tooltipText)

            Button {
                let s = Self.resolvedStep(normal: normalStep, fine: fineStep, coarse: coarseStep)
                onStep(s)
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 16, height: 16)
                    .background(RoundedRectangle(cornerRadius: 3).fill(Color.white.opacity(0.08)))
            }
            .buttonStyle(.plain)
            .help(tooltipText)
        }
        .foregroundStyle(Theme.textDim.swiftUI)
    }
}

private struct FineTuningHintFooter: View {
    var body: some View {
        HStack(alignment: .top, spacing: 5) {
            Image(systemName: "slider.horizontal.below.rectangle")
                .font(.system(size: 9.5))
                .foregroundStyle(Theme.textFaint.swiftUI)
                .padding(.top, 1)
            Text(L("Clic valeur : saisir · Boutons −/+ : ⌥-clic pas fin · ⇧-clic grand pas · ⌘Z annuler",
                   "Click value: type · −/+ buttons: ⌥-click fine · ⇧-click coarse · ⌘Z undo"))
                .font(.system(size: 9.5))
                .foregroundStyle(Theme.textFaint.swiftUI)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 2)
    }
}

// MARK: - Viewport HUD Overlay

private struct ViewportHUDOverlay: View {
    let model: DocumentModel

    var body: some View {
        ZStack {
            if let construction = model.constructionProgress {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Rectangle()
                            .fill(Color.white.opacity(0.08))
                        Rectangle()
                            .fill(
                                LinearGradient(
                                    colors: [Theme.accent.swiftUI.opacity(0.85), Theme.accent.swiftUI],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .frame(width: max(24, geo.size.width * min(max(construction.fraction, 0.05), 1.0)))
                            .animation(.easeOut(duration: 0.08), value: construction.fraction)
                    }
                    .frame(height: 3.0)
                }
                .allowsHitTesting(false)
            }

            VStack {
                // Top banners (Free-fly / Measurement / View Construction / Flash feedback)
                HStack {
                    Spacer()
                    if model.isFreeFlying {
                        HStack(spacing: 10) {
                            Image(systemName: "airplane")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Theme.accent.swiftUI)
                            Text(L("Mode vol libre — Souris pour regarder · ZQSD / Flèches pour avancer · Échap pour sortir",
                                   "Free fly mode — Mouse to look · WASD / Arrows to move · Esc to exit"))
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(Theme.text.swiftUI)
                            TextButton(title: L("Quitter (Échap)", "Exit (Esc)"), compact: true) {
                                model.toggleFreeFlight()
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            Capsule()
                                .fill(Theme.panel.swiftUI.opacity(0.92))
                                .overlay(Capsule().strokeBorder(Theme.accent.swiftUI.opacity(0.45), lineWidth: 1))
                        )
                        .shadow(color: .black.opacity(0.35), radius: 8, y: 2)
                    } else if model.isMeasuring {
                        MeasurementBannerView(model: model)
                    } else if model.projectorPickMode != .none {
                        HStack(spacing: 10) {
                            Image(systemName: model.projectorPickMode == .position ? "scope" : "target")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Theme.alive.swiftUI)
                            Text(model.projectorPickMode == .position
                                 ? L("Cliquez un point dans la vue 3D pour placer l’objectif du vidéoprojecteur (Échap pour annuler)",
                                     "Click a point in the 3D view to place the projector lens (Esc to cancel)")
                                 : L("Cliquez une paroi dans la vue 3D pour orienter la cible du vidéoprojecteur (Échap pour annuler)",
                                     "Click a surface in the 3D view to aim the projector target (Esc to cancel)"))
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(Theme.text.swiftUI)
                            TextButton(title: L("Annuler", "Cancel"), compact: true) {
                                model.cancelProjectorPick()
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            Capsule()
                                .fill(Theme.panel.swiftUI.opacity(0.94))
                                .overlay(Capsule().strokeBorder(Theme.alive.swiftUI.opacity(0.55), lineWidth: 1))
                        )
                        .shadow(color: .black.opacity(0.35), radius: 8, y: 2)
                    } else if let construction = model.constructionProgress {
                        let dotColor = model.layerDisplayColor(construction.currentLayerIndex) ?? Theme.accent.swiftUI
                        HStack(spacing: 8) {
                            Circle()
                                .fill(dotColor)
                                .frame(width: 8, height: 8)
                                .overlay(Circle().strokeBorder(Color.white.opacity(0.45), lineWidth: 0.6))
                            Text(L("Construction de la vue :", "Building view:"))
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(Theme.textDim.swiftUI)
                            Text(construction.currentLayerName)
                                .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                                .foregroundStyle(Theme.text.swiftUI)
                                .lineLimit(1)
                                .frame(maxWidth: 220, alignment: .leading)
                            Text("(\(construction.completedLayers)/\(construction.totalLayers))")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(Theme.textFaint.swiftUI)
                            if construction.edgesBuilt > 0 {
                                Rectangle().fill(Theme.separator.swiftUI).frame(width: 1, height: 12)
                                Text(Format.count(construction.edgesBuilt, L("arête", "edge")))
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(Theme.textDim.swiftUI)
                            }
                            Text("\(Int((construction.fraction * 100).rounded())) %")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundStyle(Theme.accent.swiftUI)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            Capsule()
                                .fill(Theme.panel.swiftUI.opacity(0.94))
                                .overlay(Capsule().strokeBorder(dotColor.opacity(0.55), lineWidth: 1))
                        )
                        .shadow(color: .black.opacity(0.35), radius: 8, y: 2)
                        .allowsHitTesting(false)
                    } else if let flash = model.flashMessage {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.alive.swiftUI)
                            Text(flash)
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(Theme.text.swiftUI)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            Capsule()
                                .fill(Theme.panel.swiftUI.opacity(0.92))
                                .overlay(Capsule().strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
                        )
                        .shadow(color: .black.opacity(0.35), radius: 8, y: 2)
                    }
                    Spacer()
                }
                .padding(.top, 10)

            Spacer()

            // Bottom-left hovered layer pill & Bottom-right orientation gizmo + quick camera pill
            HStack(alignment: .bottom) {
                if let hoveredName = model.hoveredLayerName {
                    let dotColor = model.hoveredLayerColor ?? Theme.accent.swiftUI
                    HStack(spacing: 6) {
                        Circle()
                            .fill(dotColor)
                            .frame(width: 7.5, height: 7.5)
                            .overlay(Circle().strokeBorder(Color.white.opacity(0.35), lineWidth: 0.5))
                        Text(hoveredName)
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(Theme.text.swiftUI)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        Capsule()
                            .fill(Theme.panel.swiftUI.opacity(0.92))
                            .overlay(Capsule().strokeBorder(dotColor.opacity(0.55), lineWidth: 1))
                    )
                    .shadow(color: .black.opacity(0.32), radius: 6, y: 2)
                    .allowsHitTesting(false)
                }
                Spacer()
                HStack(alignment: .center, spacing: 8) {
                    Button {
                        model.resetView()
                    } label: {
                        AxisGizmoView(model: model)
                            .frame(width: 44, height: 44)
                            .background(
                                Circle()
                                    .fill(Theme.panel.swiftUI.opacity(0.84))
                                    .overlay(Circle().strokeBorder(Color.white.opacity(0.10), lineWidth: 1))
                            )
                    }
                    .buttonStyle(.plain)
                    .help(L("Repère 3D (X rouge, Y vert, Z bleu) — Cliquer pour réinitialiser la vue (Z)",
                            "3D axes gizmo (X red, Y green, Z blue) — Click to reset view (Z)"))

                    HStack(spacing: 2) {
                        IconButton(
                            symbol: "minus.magnifyingglass",
                            tooltip: L("Dézoomer", "Zoom out")
                        ) {
                            model.zoomOut()
                        }
                        IconButton(
                            symbol: "plus.magnifyingglass",
                            tooltip: L("Zoomer", "Zoom in")
                        ) {
                            model.zoomIn()
                        }
                        Rectangle()
                            .fill(Theme.separator.swiftUI)
                            .frame(width: 1, height: 14)
                            .padding(.horizontal, 2)
                        ToolbarPillButton(
                            title: "Z",
                            tooltip: L("Réinitialiser la vue (Z)", "Reset view (Z)")
                        ) {
                            model.resetView()
                        }
                        ToolbarPillButton(
                            title: "⇧Z",
                            tooltip: L("Zoom étendu (⇧Z)", "Zoom extents (⇧Z)")
                        ) {
                            model.zoomExtents()
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .background(
                        Capsule()
                            .fill(Theme.panel.swiftUI.opacity(0.86))
                            .overlay(Capsule().strokeBorder(Color.white.opacity(0.10), lineWidth: 1))
                    )
                }
                .shadow(color: .black.opacity(0.28), radius: 6, y: 2)
            }
            .padding(12)
            }
        }
    }
}

// MARK: - Measurement Tool Overlay & Banner (⌘D)

private struct MeasurementBannerView: View {
    let model: DocumentModel

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "ruler.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.accent.swiftUI)

            if let start = model.measureStart, let end = model.activeMeasureEnd {
                let d = end.position - start.position
                let dist = simd_length(d)
                let xyDist = hypot(d.x, d.y)
                let angleDeg = atan2(d.y, d.x) * 180.0 / .pi

                Button {
                    model.copyMeasurement()
                } label: {
                    HStack(spacing: 8) {
                        Text(DocumentModel.formatDistance(dist))
                            .font(.system(size: 13, weight: .bold, design: .monospaced))
                            .foregroundStyle(Theme.accent.swiftUI)

                        Rectangle().fill(Theme.separator.swiftUI).frame(width: 1, height: 13)

                        HStack(spacing: 6) {
                            axisDeltaBadge("ΔX", d.x, color: Color(red: 0.95, green: 0.36, blue: 0.34))
                            axisDeltaBadge("ΔY", d.y, color: Color(red: 0.30, green: 0.86, blue: 0.48))
                            if abs(d.z) > 1e-3 || !model.is2DCAD {
                                axisDeltaBadge("ΔZ", d.z, color: Color(red: 0.38, green: 0.68, blue: 0.98))
                            }
                        }

                        if xyDist > 1e-4 {
                            Rectangle().fill(Theme.separator.swiftUI).frame(width: 1, height: 13)
                            Text(String(format: "%.1f°", angleDeg))
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .foregroundStyle(Theme.textDim.swiftUI)
                        }
                    }
                }
                .buttonStyle(.plain)
                .help(L("Cliquer pour copier la mesure dans le presse-papiers", "Click to copy measurement to clipboard"))

                TextButton(title: L("Copier", "Copy"), symbol: "doc.on.doc", compact: true) {
                    model.copyMeasurement()
                }
                TextButton(title: L("Effacer", "Clear"), compact: true) {
                    model.clearMeasurement()
                }
            } else if model.measureStart != nil {
                Text(L("Cliquez le 2e point (Points / Milieux / Arêtes · ⇧ : axe)",
                       "Click 2nd point (Endpoints / Midpoints / Edges · ⇧: axis)"))
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Theme.text.swiftUI)
                TextButton(title: L("Annuler", "Cancel"), compact: true) {
                    model.clearMeasurement()
                }
            } else {
                Text(L("Mesurer (⌘D) — Cliquez un 1er point ou une arête (magnétisme actif · Échap : quitter)",
                       "Measure (⌘D) — Click 1st point or edge (snapping active · Esc: exit)"))
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Theme.text.swiftUI)
            }

            TextButton(title: L("Quitter", "Exit"), compact: true) {
                model.setMeasureTool(false)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            Capsule()
                .fill(Theme.panel.swiftUI.opacity(0.94))
                .overlay(Capsule().strokeBorder(Theme.accent.swiftUI.opacity(0.50), lineWidth: 1))
        )
        .shadow(color: .black.opacity(0.38), radius: 8, y: 2)
    }

    private func axisDeltaBadge(_ label: String, _ value: Float, color: Color) -> some View {
        HStack(spacing: 3) {
            Text(label)
                .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                .foregroundStyle(color)
            Text(String(format: "%+.2f m", value))
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(Theme.text.swiftUI)
        }
    }
}

/// Projects the SketchUp world axes (X red, Y green, Z blue) into the current camera basis.
/// Isolated leaf view so `ViewportHUDOverlay` is never invalidated during 60–120 Hz camera rotations.
private struct AxisGizmoView: View {
    let model: DocumentModel

    var body: some View {
        let yaw = model.cameraYaw
        let pitch = model.cameraPitch
        Canvas { ctx, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let radius = min(size.width, size.height) * 0.36

            let cy = cos(yaw), sy = sin(yaw)
            let cp = cos(pitch), sp = sin(pitch)
            // Camera basis in SketchUp Z-up world coordinates (matching CameraRig.Pose)
            let forward = SIMD3<Float>(-sy * cp, cy * cp, sp)
            let right = SIMD3<Float>(cy, sy, 0)
            let up = simd_cross(right, forward)

            let axes: [(SIMD3<Float>, Color, String)] = [
                (SIMD3<Float>(1, 0, 0), Color(red: 0.95, green: 0.32, blue: 0.32), "X"),
                (SIMD3<Float>(0, 1, 0), Color(red: 0.28, green: 0.84, blue: 0.48), "Y"),
                (SIMD3<Float>(0, 0, 1), Color(red: 0.35, green: 0.68, blue: 0.98), "Z"),
            ]

            // Draw back-to-front by depth along forward
            let sorted = axes.sorted { simd_dot($0.0, forward) > simd_dot($1.0, forward) }
            for (dir, color, _) in sorted {
                let sx = CGFloat(simd_dot(dir, right)) * radius
                let syScreen = -CGFloat(simd_dot(dir, up)) * radius
                let end = CGPoint(x: center.x + sx, y: center.y + syScreen)

                var line = Path()
                line.move(to: center)
                line.addLine(to: end)
                ctx.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: 2.0, lineCap: .round))

                let dotRect = CGRect(x: end.x - 2.6, y: end.y - 2.6, width: 5.2, height: 5.2)
                ctx.fill(Path(ellipseIn: dotRect), with: .color(color))
            }

            let originRect = CGRect(x: center.x - 2, y: center.y - 2, width: 4, height: 4)
            ctx.fill(Path(ellipseIn: originRect), with: .color(Color.white.opacity(0.85)))
        }
    }
}

private struct FailureBanner: View {
    let message: String
    let openInSketchUp: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 15))
                .foregroundStyle(Theme.danger.swiftUI)
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(Theme.text.swiftUI)
                .fixedSize(horizontal: false, vertical: true)
            if let openInSketchUp {
                TextButton(title: L("Ouvrir dans SketchUp", "Open in SketchUp"), symbol: "arrow.up.forward.app", compact: true, action: openInSketchUp)
            }
        }
        .padding(14)
        .frame(maxWidth: 560)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.panel.swiftUI))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.white.opacity(0.08)))
        .shadow(color: .black.opacity(0.4), radius: 12, y: 4)
        .padding(20)
    }
}

// MARK: - Sidebar

struct SidebarView: View {
    @Bindable var model: DocumentModel

    var body: some View {
        ScrollViewReader { scrollProxy in
            ScrollView {
                // Not lazy: in a LazyVStack the first layer row was laid out but not drawn (seen in --snapshot).
                VStack(alignment: .leading, spacing: 3) {
                if let skp = model.skp {
                    if !skp.scenes.isEmpty {
                        SectionHeader(L("Scènes", "Scenes")) {
                            HStack(spacing: 4) {
                                Chip(text: "\(skp.scenes.count)")
                                if skp.scenes.count > 1 {
                                    Button { model.previousScene() } label: {
                                        Image(systemName: "chevron.left")
                                            .font(.system(size: 9.5, weight: .bold))
                                            .foregroundStyle(Theme.textDim.swiftUI)
                                            .frame(width: 16, height: 16)
                                    }
                                    .buttonStyle(.plain)
                                    .help(L("Scène précédente (⌘[)", "Previous scene (⌘[)"))
                                    Button { model.nextScene() } label: {
                                        Image(systemName: "chevron.right")
                                            .font(.system(size: 9.5, weight: .bold))
                                            .foregroundStyle(Theme.textDim.swiftUI)
                                            .frame(width: 16, height: 16)
                                    }
                                    .buttonStyle(.plain)
                                    .help(L("Scène suivante (⌘])", "Next scene (⌘])"))
                                }
                            }
                        }
                        ForEach(skp.scenes.indices, id: \.self) { index in
                            sceneRow(skp.scenes[index].name, hasCamera: skp.scenes[index].camera != nil, index: index)
                        }
                        Spacer().frame(height: 10)
                    }

                    if !model.onlyVideoProjectorIndices.isEmpty {
                        videoProjectorsSidebarSection
                        Spacer().frame(height: 10)
                    }

                    stageLightsSidebarSection
                    Spacer().frame(height: 10)

                    let multiGroupCount = skp.layerGroups.filter { !$0.isSingleLayer }.count
                    SectionHeader(L("Calques", "Layers")) {
                        HStack(spacing: 5) {
                            if multiGroupCount > 0 {
                                let allExpanded = model.expandedLayerGroups.count >= multiGroupCount
                                Button {
                                    withAnimation(.easeInOut(duration: 0.16)) {
                                        model.setAllLayerGroupsExpanded(!allExpanded)
                                    }
                                } label: {
                                    Image(systemName: allExpanded ? "rectangle.compress.vertical" : "rectangle.expand.vertical")
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundStyle(Theme.textDim.swiftUI)
                                }
                                .buttonStyle(.plain)
                                .help(allExpanded
                                    ? L("Replier tous les groupes de calques", "Collapse all layer groups")
                                    : L("Déplier tous les groupes de calques", "Expand all layer groups"))
                            }

                            if skp.layers.count > 1 {
                                Button {
                                    model.setAllLayers(visible: true)
                                } label: {
                                    Text(L("Tout", "All"))
                                        .font(.system(size: 10, weight: .medium))
                                        .foregroundStyle(Theme.accent.swiftUI)
                                }
                                .buttonStyle(.plain)
                                .help(L("Afficher tous les calques", "Show all layers"))

                                Text("·")
                                    .font(.system(size: 10))
                                    .foregroundStyle(Theme.textFaint.swiftUI)

                                Button {
                                    model.setAllLayers(visible: false)
                                } label: {
                                    Text(L("Aucun", "None"))
                                        .font(.system(size: 10, weight: .medium))
                                        .foregroundStyle(Theme.textDim.swiftUI)
                                }
                                .buttonStyle(.plain)
                                .help(L("Masquer tous les calques", "Hide all layers"))
                            }
                            Chip(text: "\(model.visibleLayerCount)/\(skp.layers.count)")
                        }
                    }

                    if skp.layers.count > 4 {
                        HStack(spacing: 6) {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 10.5))
                                .foregroundStyle(Theme.textFaint.swiftUI)
                            TextField(L("Filtrer les calques…", "Filter layers…"), text: $model.layerFilter)
                                .textFieldStyle(.plain)
                                .font(.system(size: 11.5))
                                .foregroundStyle(Theme.text.swiftUI)
                            if !model.layerFilter.isEmpty {
                                Button {
                                    model.layerFilter = ""
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 10.5))
                                        .foregroundStyle(Theme.textDim.swiftUI)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4.5)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(Color.white.opacity(0.05))
                                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.white.opacity(0.07)))
                        )
                        .padding(.bottom, 4)
                    }

                    let query = model.layerFilter.trimmingCharacters(in: .whitespacesAndNewlines)
                    ForEach(skp.layerGroups) { group in
                        let matchingIndices = matchingIndices(in: group, skp: skp, query: query)
                        if !matchingIndices.isEmpty {
                            if group.isSingleLayer, let index = matchingIndices.first {
                                LayerRow(
                                    name: skp.layers[index].name,
                                    fullTooltip: L(
                                        "\(skp.layers[index].name) — Clic : repérer · Double-clic : zoomer dessus",
                                        "\(skp.layers[index].name) — Click: highlight · Double-click: zoom to layer"
                                    ),
                                    layerColor: model.layerDisplayColor(index),
                                    isVisible: model.layerVisible.indices.contains(index) && model.layerVisible[index],
                                    isSelected: model.selectedLayerIndex == index,
                                    isHoveredFromViewport: model.hoveredLayerIndex == index || model.constructionProgress?.currentLayerIndex == index,
                                    canSolo: skp.layers.count > 1,
                                    indented: false,
                                    onToggle: { model.toggleLayer(index) },
                                    onSelect: { model.selectLayer(index) },
                                    onZoom: { model.zoomToLayer(index) },
                                    onSolo: { model.soloLayer(index) },
                                    onHoverChange: { hovering in
                                        model.setHoveredLayer(hovering ? index : (model.hoveredLayerIndex == index ? nil : model.hoveredLayerIndex))
                                    }
                                )
                                .id("layer-row-\(index)")
                            } else {
                                let isExpanded = !query.isEmpty || model.isLayerGroupExpanded(group.id)
                                LayerGroupRow(
                                    group: group,
                                    visibleCount: model.visibleCount(in: group),
                                    isVisible: model.isLayerGroupVisible(group),
                                    isPartiallyVisible: model.isLayerGroupPartiallyVisible(group),
                                    isExpanded: isExpanded,
                                    isSelected: model.selectedLayerGroupID == group.id,
                                    isHoveredFromViewport: model.hoveredLayerIndex.map { group.layerIndices.contains($0) } ?? false,
                                    canSolo: skp.layers.count > group.layerIndices.count,
                                    onToggleExpand: {
                                        withAnimation(.easeInOut(duration: 0.14)) {
                                            model.toggleLayerGroupExpanded(group.id)
                                        }
                                    },
                                    onToggleVisibility: {
                                        model.toggleLayerGroup(group)
                                    },
                                    onSelect: {
                                        model.selectLayerGroup(group)
                                    },
                                    onZoom: {
                                        model.zoomToLayerGroup(group)
                                    },
                                    onSolo: {
                                        model.soloLayerGroup(group)
                                    }
                                )
                                if isExpanded {
                                    VStack(alignment: .leading, spacing: 2) {
                                        ForEach(matchingIndices, id: \.self) { index in
                                            LayerRow(
                                                name: group.memberLabels[index] ?? skp.layers[index].name,
                                                fullTooltip: L(
                                                    "\(skp.layers[index].name) — Clic : repérer · Double-clic : zoomer dessus",
                                                    "\(skp.layers[index].name) — Click: highlight · Double-click: zoom to layer"
                                                ),
                                                layerColor: model.layerDisplayColor(index),
                                                isVisible: model.layerVisible.indices.contains(index) && model.layerVisible[index],
                                                isSelected: model.selectedLayerIndex == index,
                                                isHoveredFromViewport: model.hoveredLayerIndex == index || model.constructionProgress?.currentLayerIndex == index,
                                                canSolo: skp.layers.count > 1,
                                                indented: true,
                                                onToggle: { model.toggleLayer(index) },
                                                onSelect: { model.selectLayer(index) },
                                                onZoom: { model.zoomToLayer(index) },
                                                onSolo: { model.soloLayer(index) },
                                                onHoverChange: { hovering in
                                                    model.setHoveredLayer(hovering ? index : (model.hoveredLayerIndex == index ? nil : model.hoveredLayerIndex))
                                                }
                                            )
                                            .id("layer-row-\(index)")
                                        }
                                    }
                                    .padding(.leading, 14)
                                    .overlay(alignment: .leading) {
                                        Rectangle()
                                            .fill(Color.white.opacity(0.08))
                                            .frame(width: 1)
                                            .padding(.leading, 11)
                                            .padding(.vertical, 2)
                                    }
                                }
                            }
                        }
                    }

                    Spacer().frame(height: 12)
                    ModelInspectorSection(skp: skp, visibleSize: model.visibleSize)
                }
            }
            .padding(10)
            }
            .onChange(of: model.scrollToLayerTrigger) { _, _ in
                if let index = model.selectedLayerIndex {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        scrollProxy.scrollTo("layer-row-\(index)", anchor: .center)
                    }
                }
            }
        }
        .background(Theme.panel.swiftUI)
    }

    private func matchingIndices(in group: SKPModel.LayerGroup, skp: SKPModel, query: String) -> [Int] {
        guard !query.isEmpty else { return group.layerIndices }
        if !group.isSingleLayer && group.name.localizedCaseInsensitiveContains(query) {
            return group.layerIndices
        }
        return group.layerIndices.filter { idx in
            guard skp.layers.indices.contains(idx) else { return false }
            if skp.layers[idx].name.localizedCaseInsensitiveContains(query) { return true }
            if let short = group.memberLabels[idx], short.localizedCaseInsensitiveContains(query) { return true }
            return false
        }
    }

    private func sceneRow(_ name: String, hasCamera: Bool, index: Int) -> some View {
        let selected = model.selectedScene == index
        return Button { model.selectScene(index) } label: {
            HStack(spacing: 6) {
                Image(systemName: hasCamera ? "video.fill" : "square.stack.3d.up")
                    .font(.system(size: 10))
                    .foregroundStyle(selected ? Theme.accent.swiftUI : Theme.textFaint.swiftUI)
                Text(name)
                    .font(.system(size: 12, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Theme.accent.swiftUI : Theme.text.swiftUI)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 5).fill(selected ? Theme.accent.swiftUI.opacity(0.14) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(L("Aller à la scène « \(name) » (⇧-clic : transition 10× plus lente)",
                "Go to scene “\(name)” (⇧-click: 10× slower transition)"))
    }

    @ViewBuilder
    private var videoProjectorsSidebarSection: some View {
        let vpIndices = model.onlyVideoProjectorIndices
        SectionHeader(L("Vidéoprojecteurs", "Video Projectors")) {
            HStack(spacing: 5) {
                if vpIndices.count > 1 {
                    Button {
                        model.selectAllOnlyVideoProjectors()
                    } label: {
                        Text(L("Tout", "All"))
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Theme.alive.swiftUI)
                    }
                    .buttonStyle(.plain)
                    .help(L("Sélectionner tous les vidéoprojecteurs", "Select all video projectors"))

                    Text("·")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textFaint.swiftUI)

                    Button {
                        model.setAllOnlyVideoProjectors(enabled: false)
                    } label: {
                        Text(L("Aucun", "None"))
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Theme.textDim.swiftUI)
                    }
                    .buttonStyle(.plain)
                    .help(L("Désactiver tous les vidéoprojecteurs", "Disable all video projectors"))
                }

                Button {
                    model.addVideoProjector()
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.alive.swiftUI)
                }
                .buttonStyle(.plain)
                .help(L("Ajouter un vidéoprojecteur depuis le point de vue actuel",
                        "Add a video projector from the current camera viewpoint"))

                Button {
                    model.toggleVideoProjectorInspector()
                } label: {
                    Image(systemName: "sidebar.right")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(model.showProjectorInspector && model.inspectorCategory == .videoProjectors ? Theme.alive.swiftUI : Theme.textDim.swiftUI)
                }
                .buttonStyle(.plain)
                .help(L("Inspecteur vidéoprojecteur (⌥⌘I)", "Projector inspector (⌥⌘I)"))

                Chip(text: "\(model.enabledOnlyVideoProjectorCount)/\(vpIndices.count)")
            }
        }

        VStack(alignment: .leading, spacing: 2) {
            ForEach(vpIndices, id: \.self) { index in
                let proj = model.videoProjectors[index]
                ProjectorSidebarRow(
                    projector: proj,
                    index: index,
                    model: model,
                    isSelected: model.selectedVideoProjectorIndices.contains(index),
                    canSolo: vpIndices.count > 1,
                    onToggle: { model.toggleVideoProjector(index) },
                    onLookThrough: { model.lookThroughVideoProjector(index) },
                    onSolo: { model.soloVideoProjector(index) },
                    onOpenSettings: { model.openInspectorForVideoProjector(index) },
                    onDuplicate: { model.duplicateVideoProjector(index) },
                    onDelete: { model.removeVideoProjector(index) }
                )
                .id("projector-row-\(proj.id.uuidString)")
            }
        }
    }

    @ViewBuilder
    private var stageLightsSidebarSection: some View {
        let lightIndices = model.stageLightIndices
        SectionHeader(L("Lumières", "Stage Lights")) {
            HStack(spacing: 5) {
                if lightIndices.count > 1 {
                    Button {
                        model.selectAllStageLights()
                    } label: {
                        Text(L("Tout", "All"))
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Theme.accent.swiftUI)
                    }
                    .buttonStyle(.plain)
                    .help(L("Sélectionner toutes les lumières", "Select all stage lights"))

                    Text("·")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textFaint.swiftUI)

                    Button {
                        model.setAllStageLights(enabled: false)
                    } label: {
                        Text(L("Aucun", "None"))
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Theme.textDim.swiftUI)
                    }
                    .buttonStyle(.plain)
                    .help(L("Éteindre toutes les lumières", "Turn off all stage lights"))
                }

                Menu {
                    Section(L("Projecteurs de plateau", "Stage Fixtures")) {
                        ForEach(ProjectorCatalog.stageLightSpecs) { spec in
                            Button {
                                model.addVideoProjector(spec: spec)
                            } label: {
                                Label(spec.displayName, systemImage: spec.kind == .profileSpot ? "flashlight.on.fill" : "light.cylindrical.ceiling.fill")
                            }
                        }
                    }

                    let oflFixtures = OFLFixtureLibrary.shared.allFixtures
                    if !oflFixtures.isEmpty {
                        Menu(L("Librairie Millumin Light-fixtures (\(oflFixtures.count))", "Millumin Light-fixtures Library (\(oflFixtures.count))")) {
                            ForEach(oflFixtures) { def in
                                if def.modes.count <= 1 {
                                    Button {
                                        model.addOFLStageLight(definition: def, modeName: def.modes.first?.name)
                                    } label: {
                                        Text("\(def.displayName) (\(def.modes.first?.channels.count ?? 1) ch)")
                                    }
                                } else {
                                    Menu(def.displayName) {
                                        ForEach(def.modes) { mode in
                                            Button {
                                                model.addOFLStageLight(definition: def, modeName: mode.name)
                                            } label: {
                                                Text("\(mode.name) (\(mode.channels.count) ch)")
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }

                    Divider()

                    Button {
                        model.promptImportMillumin()
                    } label: {
                        Label(L("Importer depuis Millumin (.millumin)…", "Import from Millumin (.millumin)…"), systemImage: "square.and.arrow.down")
                    }
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.accent.swiftUI)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help(L("Ajouter une lumière ou importer depuis Millumin", "Add a stage light or import from Millumin"))

                Button {
                    model.toggleStageLightInspector()
                } label: {
                    Image(systemName: "sidebar.right")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(model.showProjectorInspector && model.inspectorCategory == .stageLights ? Theme.accent.swiftUI : Theme.textDim.swiftUI)
                }
                .buttonStyle(.plain)
                .help(L("Inspecteur lumières", "Stage lights inspector"))

                if !lightIndices.isEmpty {
                    Chip(text: "\(model.enabledStageLightCount)/\(lightIndices.count)")
                }
            }
        }

        // Compact Millumin Conduite Bar if cues were imported
        if !model.milluminCues.isEmpty {
            HStack(spacing: 4) {
                Button {
                    model.previousMilluminCue()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Theme.text.swiftUI)
                        .frame(width: 18, height: 18)
                        .background(RoundedRectangle(cornerRadius: 3.5).fill(Color.white.opacity(0.08)))
                }
                .buttonStyle(.plain)
                .help(L("Cue lumière précédent", "Previous lighting cue"))

                Menu {
                    ForEach(Array(model.milluminCues.enumerated()), id: \.element.id) { idx, cue in
                        Button {
                            model.applyMilluminCue(at: idx)
                        } label: {
                            Text("\(idx + 1). \(cue.title)")
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "list.number")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Theme.accent.swiftUI)
                        if let activeIdx = model.activeMilluminCueIndex,
                           model.milluminCues.indices.contains(activeIdx) {
                            Text("\(activeIdx + 1). \(model.milluminCues[activeIdx].title)")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(Theme.accent.swiftUI)
                                .lineLimit(1)
                        } else {
                            Text(L("Conduite (\(model.milluminCues.count))", "Cues (\(model.milluminCues.count))"))
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(Theme.textDim.swiftUI)
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .menuStyle(.borderlessButton)

                Button {
                    model.nextMilluminCue()
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Theme.text.swiftUI)
                        .frame(width: 18, height: 18)
                        .background(RoundedRectangle(cornerRadius: 3.5).fill(Color.white.opacity(0.08)))
                }
                .buttonStyle(.plain)
                .help(L("Cue lumière suivant", "Next lighting cue"))
            }
            .padding(.horizontal, 5)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 4.5).fill(Theme.accent.swiftUI.opacity(0.10)))
            .padding(.bottom, 2)
        }

        if lightIndices.isEmpty {
            HStack(spacing: 4) {
                Button {
                    model.addShowtecProfileMini()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "plus")
                            .font(.system(size: 9, weight: .bold))
                        Text(L("Ajouter Lumière", "Add Light"))
                            .font(.system(size: 10, weight: .medium))
                    }
                    .foregroundStyle(Theme.textDim.swiftUI)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 4.5).fill(Color.white.opacity(0.04)))
                }
                .buttonStyle(.plain)

                Button {
                    model.promptImportMillumin()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "square.and.arrow.down")
                            .font(.system(size: 9, weight: .bold))
                        Text("Millumin…")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .foregroundStyle(Theme.accent.swiftUI)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 4.5).fill(Theme.accent.swiftUI.opacity(0.10)))
                }
                .buttonStyle(.plain)
            }
        } else {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(lightIndices, id: \.self) { index in
                    let light = model.videoProjectors[index]
                    StageLightSidebarRow(
                        light: light,
                        index: index,
                        model: model,
                        isSelected: model.selectedVideoProjectorIndices.contains(index),
                        canSolo: lightIndices.count > 1,
                        onToggle: { model.toggleVideoProjector(index) },
                        onLookThrough: { model.lookThroughVideoProjector(index) },
                        onSolo: { model.soloVideoProjector(index) },
                        onOpenSettings: { model.openInspectorForVideoProjector(index) },
                        onDuplicate: { model.duplicateVideoProjector(index) },
                        onDelete: { model.removeVideoProjector(index) }
                    )
                    .id("light-row-\(light.id.uuidString)")
                }
            }
        }
    }
}

private struct StageLightSidebarRow: View {
    let light: VideoProjector
    let index: Int
    let model: DocumentModel
    let isSelected: Bool
    let canSolo: Bool
    let onToggle: () -> Void
    let onLookThrough: () -> Void
    let onSolo: () -> Void
    let onOpenSettings: () -> Void
    let onDuplicate: () -> Void
    let onDelete: () -> Void

    @State private var hovering = false
    @State private var lastClickTime: CFTimeInterval = 0

    private var dotColor: Color {
        Color(
            red: Double(light.lightColor.x),
            green: Double(light.lightColor.y),
            blue: Double(light.lightColor.z)
        )
    }

    var body: some View {
        HStack(spacing: 4) {
            Button(action: onToggle) {
                ZStack {
                    RoundedRectangle(cornerRadius: 3.5)
                        .fill(light.isEnabled ? Theme.accent.swiftUI : Color.white.opacity(0.08))
                        .frame(width: 13.5, height: 13.5)
                        .overlay(
                            RoundedRectangle(cornerRadius: 3.5)
                                .strokeBorder(light.isEnabled ? Theme.accent.swiftUI : Color.white.opacity(0.28), lineWidth: 1)
                        )
                    if light.isEnabled {
                        Image(systemName: "checkmark")
                            .font(.system(size: 8.5, weight: .bold))
                            .foregroundStyle(Color.white)
                    }
                }
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L("Allumer ou éteindre cette lumière", "Turn on or off this stage light"))

            Button(action: handleNameClick) {
                HStack(spacing: 5) {
                    Circle()
                        .fill(light.isEnabled ? dotColor : Theme.textFaint.swiftUI)
                        .frame(width: 7, height: 7)
                        .overlay(Circle().strokeBorder(Color.white.opacity(0.35), lineWidth: 0.5))

                    Text(light.name)
                        .font(.system(size: 11.5, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(
                            isSelected
                                ? Theme.accent.swiftUI
                                : (light.isEnabled ? Theme.text.swiftUI : Theme.textFaint.swiftUI)
                        )
                        .strikethrough(!light.isEnabled, color: Theme.textFaint.swiftUI)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 2)
                }
                .padding(.vertical, 3.5)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L(
                "\(light.name) (\(light.spec.displayName) · DMX Ch \(light.dmxChannel)) — Clic : sélectionner · ⌘-clic : groupe · Double-clic : voir axe",
                "\(light.name) (\(light.spec.displayName) · DMX Ch \(light.dmxChannel)) — Click: select · ⌘-click: group · Double-click: look through"
            ))

            if hovering {
                if canSolo {
                    Button(action: onSolo) {
                        Text("Solo")
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Theme.accent.swiftUI)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(RoundedRectangle(cornerRadius: 3).fill(Theme.accent.swiftUI.opacity(0.16)))
                    }
                    .buttonStyle(.plain)
                }

                Button(action: onLookThrough) {
                    Image(systemName: "eye")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(Theme.textDim.swiftUI)
                        .frame(width: 18, height: 18)
                        .background(RoundedRectangle(cornerRadius: 3.5).fill(Color.white.opacity(0.07)))
                }
                .buttonStyle(.plain)

                Button(action: onOpenSettings) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(Theme.accent.swiftUI)
                        .frame(width: 18, height: 18)
                        .background(RoundedRectangle(cornerRadius: 3.5).fill(Theme.accent.swiftUI.opacity(0.15)))
                }
                .buttonStyle(.plain)
            } else {
                Text("\(Int((light.intensity * 100).rounded()))%")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(light.isEnabled && light.intensity > 0.01 ? Theme.accent.swiftUI : Theme.textFaint.swiftUI)
                    .padding(.horizontal, 4.5)
                    .padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 3.5).fill(Color.white.opacity(0.05)))
            }
        }
        .padding(.vertical, 1)
        .padding(.horizontal, 3)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(
                    isSelected
                        ? Theme.accent.swiftUI.opacity(0.16)
                        : Color.white.opacity(hovering ? 0.055 : 0.025)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(isSelected ? Theme.accent.swiftUI.opacity(0.45) : Color.clear, lineWidth: 1)
                )
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu {
            Button {
                onOpenSettings()
            } label: {
                Label(L("Éditer la lumière…", "Edit stage light…"), systemImage: "sidebar.right")
            }
            Button {
                model.selectVideoProjector(index)
                model.aimSelectedProjectorStraightDown()
            } label: {
                Label(L("Pointer en douche verticale (-90°)", "Aim straight down (-90°)"), systemImage: "arrow.down.to.line")
            }
            Button {
                onLookThrough()
            } label: {
                Label(L("Voir dans l'axe du faisceau", "Look through beam"), systemImage: "eye")
            }
            Button {
                model.duplicateSelectedProjectorSymmetricAcrossStage()
            } label: {
                Label(L("Dupliquer en symétrie plateau (X = 0)", "Duplicate symmetric across stage (X = 0)"), systemImage: "arrow.left.and.right")
            }
            Button {
                model.selectAllStageLights()
            } label: {
                Label(L("Sélectionner toutes les lumières", "Select all stage lights"), systemImage: "checklist")
            }
            Divider()
            Button {
                onDuplicate()
            } label: {
                Label(L("Dupliquer la lumière", "Duplicate stage light"), systemImage: "plus.square.on.square")
            }
            Button(role: .destructive) {
                onDelete()
            } label: {
                Label(L("Supprimer la lumière", "Delete stage light"), systemImage: "trash")
            }
        }
    }

    private func handleNameClick() {
        let now = CACurrentMediaTime()
        let eventClicks = NSApp.currentEvent?.clickCount ?? 1
        if eventClicks >= 2 || (now - lastClickTime) <= min(NSEvent.doubleClickInterval, 0.38) {
            lastClickTime = 0
            onLookThrough()
        } else {
            lastClickTime = now
            let flags = NSApp.currentEvent?.modifierFlags ?? NSEvent.modifierFlags
            if flags.contains(.command) {
                model.selectVideoProjector(index, toggling: true)
            } else if flags.contains(.shift) {
                model.selectVideoProjector(index, extending: true)
            } else {
                model.selectVideoProjector(index)
            }
        }
    }
}

private struct ProjectorSidebarRow: View {
    let projector: VideoProjector
    let index: Int
    let model: DocumentModel
    let isSelected: Bool
    let canSolo: Bool
    let onToggle: () -> Void
    let onLookThrough: () -> Void
    let onSolo: () -> Void
    let onOpenSettings: () -> Void
    let onDuplicate: () -> Void
    let onDelete: () -> Void

    @State private var hovering = false
    @State private var lastClickTime: CFTimeInterval = 0

    private var sourceBadge: String {
        switch projector.pattern {
        case .syphon: return "Syphon"
        case .ndi: return "NDI"
        case .customImage: return "Img"
        case .testGrid, .colorBars, .whiteFrame:
            if projector.specID.hasPrefix("panasonic-pt-rq32k") {
                return projector.specID.contains("d3lew50") ? "RQ32K 0.7" : "RQ32K 2.4–4.7"
            }
            return projector.spec.model
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            Button(action: onToggle) {
                ZStack {
                    RoundedRectangle(cornerRadius: 3.5)
                        .fill(projector.isEnabled ? Theme.alive.swiftUI : Color.white.opacity(0.08))
                        .frame(width: 13.5, height: 13.5)
                        .overlay(
                            RoundedRectangle(cornerRadius: 3.5)
                                .strokeBorder(projector.isEnabled ? Theme.alive.swiftUI : Color.white.opacity(0.28), lineWidth: 1)
                        )
                    if projector.isEnabled {
                        Image(systemName: "checkmark")
                            .font(.system(size: 8.5, weight: .bold))
                            .foregroundStyle(Color.white)
                    }
                }
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L("Activer ou désactiver ce vidéoprojecteur", "Enable or disable this video projector"))

            Button(action: handleNameClick) {
                HStack(spacing: 5) {
                    Image(systemName: "videoprojector.fill")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(
                            isSelected
                                ? Theme.alive.swiftUI
                                : (projector.isEnabled ? Theme.alive.swiftUI.opacity(0.85) : Theme.textFaint.swiftUI)
                        )
                    Text(projector.name)
                        .font(.system(size: 11.5, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(
                            isSelected
                                ? Theme.alive.swiftUI
                                : (projector.isEnabled ? Theme.text.swiftUI : Theme.textFaint.swiftUI)
                        )
                        .strikethrough(!projector.isEnabled, color: Theme.textFaint.swiftUI)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 2)
                }
                .padding(.vertical, 3.5)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L(
                "\(projector.name) (\(projector.spec.displayName)) — Clic : sélectionner · ⌘-clic : multi-sélection · Double-clic : vue VP · Clic droit : options",
                "\(projector.name) (\(projector.spec.displayName)) — Click: select · ⌘-click: multi-select · Double-click: look through · Right-click: options"
            ))

            if hovering {
                if canSolo {
                    Button(action: onSolo) {
                        Text("Solo")
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Theme.alive.swiftUI)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(RoundedRectangle(cornerRadius: 3).fill(Theme.alive.swiftUI.opacity(0.16)))
                    }
                    .buttonStyle(.plain)
                    .help(L("Isoler ce vidéoprojecteur (ou réactiver tous les VPs)",
                            "Solo this video projector (or re-enable all VPs)"))
                }

                Button(action: onLookThrough) {
                    Image(systemName: "eye")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(Theme.textDim.swiftUI)
                        .frame(width: 18, height: 18)
                        .background(RoundedRectangle(cornerRadius: 3.5).fill(Color.white.opacity(0.07)))
                }
                .buttonStyle(.plain)
                .help(L("Placer la caméra dans l'axe de ce vidéoprojecteur",
                        "Look through this video projector"))

                Button(action: onOpenSettings) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(Theme.alive.swiftUI)
                        .frame(width: 18, height: 18)
                        .background(RoundedRectangle(cornerRadius: 3.5).fill(Theme.alive.swiftUI.opacity(0.15)))
                }
                .buttonStyle(.plain)
                .help(L("Ouvrir l'inspecteur de ce vidéoprojecteur (⌥⌘I)",
                        "Open inspector for this video projector (⌥⌘I)"))
            } else {
                Text(sourceBadge)
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(projector.isEnabled ? Theme.textDim.swiftUI : Theme.textFaint.swiftUI)
                    .padding(.horizontal, 4.5)
                    .padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 3.5).fill(Color.white.opacity(0.05)))
            }
        }
        .padding(.vertical, 1)
        .padding(.horizontal, 3)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(
                    isSelected
                        ? Theme.alive.swiftUI.opacity(0.15)
                        : Color.white.opacity(hovering ? 0.055 : 0.025)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(isSelected ? Theme.alive.swiftUI.opacity(0.45) : Color.clear, lineWidth: 1)
                )
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu {
            Button {
                onOpenSettings()
            } label: {
                Label(L("Ouvrir dans l'inspecteur…", "Open in Inspector…"), systemImage: "sidebar.right")
            }
            Button {
                onLookThrough()
            } label: {
                Label(L("Voir dans l'axe du VP", "Look through projector"), systemImage: "eye")
            }
            Button {
                model.duplicateSelectedProjectorSymmetricAcrossStage()
            } label: {
                Label(L("Dupliquer en symétrie plateau (X = 0)", "Duplicate symmetric across stage (X = 0)"), systemImage: "arrow.left.and.right")
            }
            Button {
                model.selectAllVideoProjectors()
            } label: {
                Label(L("Tout sélectionner (Groupe)", "Select all (Group)"), systemImage: "checklist")
            }
            Button {
                onToggle()
            } label: {
                Label(
                    projector.isEnabled ? L("Désactiver le VP", "Disable projector") : L("Activer le VP", "Enable projector"),
                    systemImage: projector.isEnabled ? "eye.slash" : "checkmark.circle"
                )
            }
            if canSolo {
                Button {
                    onSolo()
                } label: {
                    Label(L("Isoler (Solo)", "Solo projector"), systemImage: "scope")
                }
            }
            Divider()
            Button {
                onDuplicate()
            } label: {
                Label(L("Dupliquer le vidéoprojecteur", "Duplicate projector"), systemImage: "plus.square.on.square")
            }
            Button(role: .destructive) {
                onDelete()
            } label: {
                Label(L("Supprimer le vidéoprojecteur", "Delete projector"), systemImage: "trash")
            }
        }
    }

    private func handleNameClick() {
        let now = CACurrentMediaTime()
        let eventClicks = NSApp.currentEvent?.clickCount ?? 1
        if eventClicks >= 2 || (now - lastClickTime) <= min(NSEvent.doubleClickInterval, 0.38) {
            lastClickTime = 0
            onLookThrough()
        } else {
            lastClickTime = now
            let flags = NSApp.currentEvent?.modifierFlags ?? NSEvent.modifierFlags
            if flags.contains(.command) {
                model.selectVideoProjector(index, toggling: true)
            } else if flags.contains(.shift) {
                model.selectVideoProjector(index, extending: true)
            } else {
                model.selectVideoProjector(index)
            }
        }
    }
}

private struct LayerGroupRow: View {
    let group: SKPModel.LayerGroup
    let visibleCount: Int
    let isVisible: Bool
    let isPartiallyVisible: Bool
    let isExpanded: Bool
    let isSelected: Bool
    let isHoveredFromViewport: Bool
    let canSolo: Bool
    let onToggleExpand: () -> Void
    let onToggleVisibility: () -> Void
    let onSelect: () -> Void
    let onZoom: () -> Void
    let onSolo: () -> Void

    @State private var hovering = false
    @State private var chevronHovering = false
    @State private var lastClickTime: CFTimeInterval = 0

    var body: some View {
        HStack(spacing: 3) {
            // Generous 24×24 pt disclosure button so expanding/collapsing groups is effortless
            Button(action: onToggleExpand) {
                ZStack {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.white.opacity(chevronHovering ? 0.12 : 0.0))
                        .frame(width: 22, height: 22)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10.5, weight: .bold))
                        .foregroundStyle(chevronHovering ? Theme.text.swiftUI : Theme.textDim.swiftUI)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { chevronHovering = $0 }
            .help(isExpanded
                ? L("Replier le groupe « \(group.name) »", "Collapse group “\(group.name)”")
                : L("Déplier le groupe « \(group.name) »", "Expand group “\(group.name)”"))

            // Dedicated checkbox button: only clicking the checkbox toggles visibility
            Button(action: onToggleVisibility) {
                ZStack {
                    RoundedRectangle(cornerRadius: 3.5)
                        .fill(isVisible ? Theme.accent.swiftUI : Color.white.opacity(0.08))
                        .frame(width: 14, height: 14)
                        .overlay(
                            RoundedRectangle(cornerRadius: 3.5)
                                .strokeBorder(isVisible ? Theme.accent.swiftUI : Color.white.opacity(0.28), lineWidth: 1)
                        )
                    if isPartiallyVisible {
                        Image(systemName: "minus")
                            .font(.system(size: 8.5, weight: .bold))
                            .foregroundStyle(Color.white)
                    } else if isVisible {
                        Image(systemName: "checkmark")
                            .font(.system(size: 8.5, weight: .bold))
                            .foregroundStyle(Color.white)
                    }
                }
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L("Activer ou désactiver tous les calques du groupe « \(group.name) »",
                    "Enable or disable all layers in group “\(group.name)”"))

            // Clicking the group name selects & pulses it; double-clicking zooms onto it in the viewport
            Button(action: handleNameClick) {
                HStack(spacing: 5) {
                    Image(systemName: isExpanded ? "folder.fill" : "folder")
                        .font(.system(size: 10.5))
                        .foregroundStyle(isVisible ? Theme.accent.swiftUI : Theme.textFaint.swiftUI)
                    Text(group.name)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(isSelected ? Theme.accent.swiftUI : (isVisible ? Theme.text.swiftUI : Theme.textDim.swiftUI))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 3)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L(
                "Groupe « \(group.name) » — Clic : repérer · Double-clic : zoomer dessus",
                "Group “\(group.name)” — Click: highlight · Double-click: zoom to group"
            ))

            if canSolo && hovering {
                Button(action: onSolo) {
                    Text("Solo")
                        .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Theme.accent.swiftUI)
                        .padding(.horizontal, 4.5)
                        .padding(.vertical, 1)
                        .background(RoundedRectangle(cornerRadius: 3).fill(Theme.accent.swiftUI.opacity(0.15)))
                }
                .buttonStyle(.plain)
                .help(L("Isoler ce groupe de calques (ou réafficher tous les calques)",
                        "Solo this layer group (or restore all layers)"))
            }

            Text("\(visibleCount)/\(group.layerIndices.count)")
                .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                .foregroundStyle(isVisible ? Theme.textDim.swiftUI : Theme.textFaint.swiftUI)
                .padding(.horizontal, 4.5)
                .padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 3.5).fill(Color.white.opacity(0.05)))
        }
        .padding(.vertical, 1)
        .padding(.horizontal, 3)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(isSelected ? Theme.accent.swiftUI.opacity(0.14) : (isHoveredFromViewport ? Theme.accent.swiftUI.opacity(0.07) : Color.white.opacity(hovering ? 0.055 : 0.025)))
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(isSelected ? Theme.accent.swiftUI.opacity(0.42) : (isHoveredFromViewport ? Theme.accent.swiftUI.opacity(0.24) : Color.clear), lineWidth: 1)
                )
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }

    private func handleNameClick() {
        let now = CACurrentMediaTime()
        let eventClicks = NSApp.currentEvent?.clickCount ?? 1
        if eventClicks >= 2 || (now - lastClickTime) <= min(NSEvent.doubleClickInterval, 0.38) {
            lastClickTime = 0
            onZoom()
        } else {
            lastClickTime = now
            onSelect()
        }
    }
}

private struct LayerRow: View {
    let name: String
    let fullTooltip: String
    let layerColor: Color?
    let isVisible: Bool
    let isSelected: Bool
    let isHoveredFromViewport: Bool
    let canSolo: Bool
    let indented: Bool
    let onToggle: () -> Void
    let onSelect: () -> Void
    let onZoom: () -> Void
    let onSolo: () -> Void
    let onHoverChange: (Bool) -> Void

    @State private var hovering = false
    @State private var lastClickTime: CFTimeInterval = 0

    var body: some View {
        HStack(spacing: 4) {
            // Dedicated checkbox button: only clicking the checkbox toggles visibility
            Button(action: onToggle) {
                ZStack {
                    RoundedRectangle(cornerRadius: 3.5)
                        .fill(isVisible ? Theme.accent.swiftUI : Color.white.opacity(0.08))
                        .frame(width: 13.5, height: 13.5)
                        .overlay(
                            RoundedRectangle(cornerRadius: 3.5)
                                .strokeBorder(isVisible ? Theme.accent.swiftUI : Color.white.opacity(0.28), lineWidth: 1)
                        )
                    if isVisible {
                        Image(systemName: "checkmark")
                            .font(.system(size: 8.5, weight: .bold))
                            .foregroundStyle(Color.white)
                    }
                }
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L("Afficher ou masquer ce calque", "Show or hide this layer"))

            // Clicking the layer name selects & pulses it; double-clicking zooms onto it in the viewport
            Button(action: handleNameClick) {
                HStack(spacing: 5) {
                    if let layerColor {
                        Circle()
                            .fill(layerColor.opacity(isVisible ? 1.0 : 0.45))
                            .frame(width: 7.5, height: 7.5)
                            .overlay(
                                Circle()
                                    .strokeBorder(Color.white.opacity(0.28), lineWidth: 0.5)
                            )
                    }
                    Text(name)
                        .font(.system(size: indented ? 11.5 : 12, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelected ? Theme.accent.swiftUI : (isVisible ? Theme.text.swiftUI : Theme.textDim.swiftUI))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 2.5)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(fullTooltip)

            if canSolo && hovering {
                Button(action: onSolo) {
                    Text("Solo")
                        .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Theme.accent.swiftUI)
                        .padding(.horizontal, 4.5)
                        .padding(.vertical, 1)
                        .background(RoundedRectangle(cornerRadius: 3).fill(Theme.accent.swiftUI.opacity(0.15)))
                }
                .buttonStyle(.plain)
                .help(L("Isoler ce calque (ou réafficher tous les calques)", "Solo this layer (or restore all layers)"))
            }
        }
        .padding(.vertical, 0.5)
        .padding(.horizontal, 3)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(isSelected ? Theme.accent.swiftUI.opacity(0.14) : (isHoveredFromViewport ? Theme.accent.swiftUI.opacity(0.08) : Color.white.opacity(hovering ? 0.04 : 0.0)))
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(isSelected ? Theme.accent.swiftUI.opacity(0.38) : (isHoveredFromViewport ? Theme.accent.swiftUI.opacity(0.28) : Color.clear), lineWidth: 1)
                )
        )
        .contentShape(Rectangle())
        .onHover { isHovering in
            hovering = isHovering
            onHoverChange(isHovering)
        }
    }

    private func handleNameClick() {
        let now = CACurrentMediaTime()
        let eventClicks = NSApp.currentEvent?.clickCount ?? 1
        if eventClicks >= 2 || (now - lastClickTime) <= min(NSEvent.doubleClickInterval, 0.38) {
            lastClickTime = 0
            onZoom()
        } else {
            lastClickTime = now
            onSelect()
        }
    }
}

private struct ModelInspectorSection: View {
    let skp: SKPModel
    let visibleSize: SIMD3<Float>?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader(L("Modèle & Matériaux", "Model & Materials")) {
                Chip(text: "\(skp.materials.count)")
            }

            let size = visibleSize ?? skp.size
            VStack(alignment: .leading, spacing: 4) {
                statRow(L("Dimensions", "Dimensions"), "\(Format.decimal(size.x)) × \(Format.decimal(size.y)) × \(Format.decimal(size.z)) m")
                if skp.stats.splats > 0 {
                    let label = skp.splatCloud?.kind == .gaussianSplats ? L("Gaussian Splats", "Gaussian Splats") : L("Points 3D", "3D Points")
                    statRow(label, Format.integer(skp.stats.splats))
                    if let shDeg = skp.splatCloud?.shDegree, shDeg > 0 {
                        statRow(L("Harmoniques sphériques", "Spherical Harmonics"), "SH\(shDeg)")
                    }
                }
                if skp.stats.faces > 0 || skp.stats.splats == 0 {
                    statRow(L("Faces", "Faces"), Format.integer(skp.stats.faces))
                    statRow(L("Arêtes", "Edges"), Format.integer(skp.stats.edges))
                    statRow(L("Composants", "Components"), Format.integer(skp.stats.instances))
                }
                let textureCount = skp.materials.filter { $0.textureURL != nil }.count
                if textureCount > 0 {
                    statRow(L("Textures", "Textures"), Format.integer(textureCount))
                }
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.03)))

            if !skp.materials.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(Array(skp.materials.prefix(16).enumerated()), id: \.offset) { _, mat in
                            RoundedRectangle(cornerRadius: 3.5)
                                .fill(Color(
                                    red: Double(mat.color.x),
                                    green: Double(mat.color.y),
                                    blue: Double(mat.color.z),
                                    opacity: max(0.35, Double(mat.opacity))
                                ))
                                .frame(width: 16, height: 16)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 3.5)
                                        .strokeBorder(mat.textureURL != nil ? Theme.accent.swiftUI.opacity(0.8) : Color.white.opacity(0.18), lineWidth: 1)
                                )
                                .help(mat.name.isEmpty ? L("Matériau", "Material") : mat.name)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    private func statRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.textDim.swiftUI)
            Spacer()
            Text(value)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(Theme.text.swiftUI)
                .lineLimit(1)
        }
    }
}

// MARK: - StatusBar

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
            if model.syphonOutputEnabled {
                Button {
                    model.toggleSyphonOutput()
                } label: {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(Theme.alive.swiftUI)
                            .frame(width: 6, height: 6)
                        Text("SYPHON \(model.syphonOutputResolution.shortLabel)")
                            .foregroundStyle(Theme.alive.swiftUI)
                    }
                }
                .buttonStyle(.plain)
                .help(L("Sortie vidéo Syphon active (\(model.syphonOutputResolution.label)) — cliquer pour couper (⌥⌘Y)",
                        "Syphon video output active (\(model.syphonOutputResolution.label)) — click to stop (⌥⌘Y)"))
                Divider().frame(height: 12)
            }
            if RemoteControlServer.shared.isOSCListening {
                Text("OSC :\(RemoteControlServer.shared.oscInPort)")
                    .foregroundStyle(Theme.textDim.swiftUI)
                    .help(L("Serveur OSC actif (UDP :\(RemoteControlServer.shared.oscInPort)) · OSCQuery & MCP (TCP :\(RemoteControlServer.shared.httpPort))",
                            "OSC server active (UDP :\(RemoteControlServer.shared.oscInPort)) · OSCQuery & MCP (TCP :\(RemoteControlServer.shared.httpPort))"))
                Divider().frame(height: 12)
            }
            if model.isReady {
                StatusBarFPSBadge()
                Divider().frame(height: 12)
            }
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

/// Isolated leaf view displaying the rolling 1-second FPS count in the status bar; clicking opens the Frame Profiler (`⌥⌘M`).
private struct StatusBarFPSBadge: View {
    @State private var fps: Int = FrameProfiler.shared.framesInLastSecond()

    var body: some View {
        Button {
            FrameProfilerWindowController.shared.toggle()
        } label: {
            Text("\(fps) fps")
                .font(.system(size: 10.5, weight: fps > 0 ? .semibold : .regular, design: .monospaced))
                .foregroundStyle(fps > 0 ? Theme.alive.swiftUI : Theme.textDim.swiftUI)
        }
        .buttonStyle(.plain)
        .help(L("Images rendues sur la dernière seconde — cliquer pour ouvrir le Profileur de frame (⌥⌘M)",
                "Frames rendered over the last second — click to open the Frame Profiler (⌥⌘M)"))
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 250_000_000)
                let current = FrameProfiler.shared.framesInLastSecond()
                if current != fps {
                    fps = current
                }
            }
        }
    }
}
