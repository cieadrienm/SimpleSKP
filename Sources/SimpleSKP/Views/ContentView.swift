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
            }
            .clipped()
            .animation(.spring(duration: 0.22, bounce: 0.0), value: model.showSidebar)
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
            if model.isReady {
                ViewportHUDOverlay(model: model)
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

// MARK: - TopBar

struct TopBar: View {
    let model: DocumentModel
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
                    tooltip: L("Ouvrir un fichier SketchUp… (⌘O)", "Open a SketchUp file… (⌘O)")
                ) {
                    NSDocumentController.shared.openDocument(nil)
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
                    active: showCameraPopover || abs(model.cameraFOV - 35) > 0.5 || abs(model.cameraExposure - (-0.62)) > 0.05,
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

            barDivider

            // 3. Shading, Edges, Sun & Grid
            HStack(spacing: 3) {
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

                IconButton(
                    symbol: "square.3.layers.3d.down.right",
                    active: model.showsEdges,
                    disabled: !model.isReady,
                    tooltip: L("Afficher ou masquer les arêtes (⌘E)", "Show or hide edges (⌘E)")
                ) {
                    model.toggleEdges()
                }

                ToolbarPillButton(
                    title: model.lightingMode == .sun ? L("Soleil", "Sun") : L("Ponctuel", "Point"),
                    symbol: model.lightingMode == .sun ? (model.shadowsEnabled ? "sun.max.fill" : "sun.max") : "lightbulb.fill",
                    active: model.lightingMode == .point,
                    disabled: !model.isReady,
                    tooltip: L("Basculer entre éclairage Soleil et éclairage Ponctuel", "Switch between Sun lighting and Point lighting")
                ) {
                    model.setLightingMode(model.lightingMode == .sun ? .point : .sun)
                }

                if model.lightingMode == .sun {
                    IconButton(
                        symbol: model.shadowsEnabled ? "shadow" : "sun.min",
                        active: model.shadowsEnabled,
                        disabled: !model.isReady,
                        tooltip: L("Activer ou couper les ombres portées (⌥⌘O)", "Toggle cast shadows (⌥⌘O)")
                    ) {
                        model.toggleShadows()
                    }
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
            // 1. Lighting Mode Header (Soleil vs Ponctuel)
            SectionHeader(L("Mode d'éclairage", "Lighting mode")) {
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
                    HStack {
                        Text(L("Importance SSAO", "SSAO strength"))
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.textDim.swiftUI)
                        Spacer()
                        Text("\(Int((model.ambientOcclusionIntensity * 100).rounded())) %")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Theme.text.swiftUI)
                    }
                    Slider(
                        value: Binding(
                            get: { Double(model.ambientOcclusionIntensity) },
                            set: { model.setAmbientOcclusionIntensity(Float($0)) }
                        ),
                        in: 0.0...2.0
                    )
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
        }
        .padding(14)
        .frame(width: 318)
        .background(Theme.panel.swiftUI)
        .preferredColorScheme(.dark)
    }

    // MARK: Sun Controls

    private var sunControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(L("Azimut solaire", "Sun azimuth"))
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textDim.swiftUI)
                Spacer()
                Text("\(Int(model.sunAzimuthDegrees.rounded()))°")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.text.swiftUI)
            }
            Slider(
                value: Binding(
                    get: { Double(model.sunAzimuthDegrees) },
                    set: { model.setSun(azimuth: Float($0), elevation: model.sunElevationDegrees) }
                ),
                in: -180...180
            )
            .tint(Theme.accent.swiftUI)

            HStack {
                Text(L("Hauteur solaire", "Sun elevation"))
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textDim.swiftUI)
                Spacer()
                Text("\(Int(model.sunElevationDegrees.rounded()))°")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.text.swiftUI)
            }
            Slider(
                value: Binding(
                    get: { Double(model.sunElevationDegrees) },
                    set: { model.setSun(azimuth: model.sunAzimuthDegrees, elevation: Float($0)) }
                ),
                in: 8...85
            )
            .tint(Theme.accent.swiftUI)

            HStack {
                Text(L("Puissance solaire", "Sun intensity"))
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textDim.swiftUI)
                Spacer()
                Text(Rendering.formatLightPercentage(model.sunIntensity))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.text.swiftUI)
            }
            Slider(
                value: Binding(
                    get: { Rendering.lightIntensityToSlider(model.sunIntensity, maxIntensity: 3.0) },
                    set: { model.setSunIntensity(Rendering.sliderToLightIntensity($0, maxIntensity: 3.0)) }
                ),
                in: 0.0...1.0
            )
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
            HStack {
                Text(L("Lumière ambiante", "Ambient light"))
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textDim.swiftUI)
                Spacer()
                if abs(model.ambientIntensity - Rendering.defaultAmbientIntensity) > 0.02 {
                    Button {
                        model.setAmbientIntensity(Rendering.defaultAmbientIntensity)
                    } label: {
                        Text("100 %")
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(Theme.accent.swiftUI)
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 4)
                }
                Text(Rendering.formatLightPercentage(model.ambientIntensity))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.text.swiftUI)
            }
            Slider(
                value: Binding(
                    get: { Rendering.lightIntensityToSlider(model.ambientIntensity, maxIntensity: 2.0) },
                    set: { model.setAmbientIntensity(Rendering.sliderToLightIntensity($0, maxIntensity: 2.0)) }
                ),
                in: 0.0...1.0
            )
            .tint(Theme.accent.swiftUI)
            .help(L("Lumière ambiante résiduelle lorsque les lumières sont à 0 % (courbe logarithmique)",
                    "Residual ambient light when lights are at 0% (logarithmic curve)"))
        }
    }

    // MARK: Point Light Controls

    private var pointLightControls: some View {
        let range = model.pointLightCoordinateRange
        let span = max(Float(range.upperBound - range.lowerBound), 1.0)
        let step = max(0.05, Double((span / 100.0).rounded(.toNearestOrAwayFromZero)))

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
                    step: Float(step)
                ) { newX in
                    model.updateSelectedPointLight(position: SIMD3<Float>(newX, light.position.y, light.position.z))
                }
                coordinateRow(
                    axis: "Y",
                    color: NSColor(srgbRed: 0.25, green: 0.78, blue: 0.36, alpha: 1.0),
                    value: light.position.y,
                    range: range,
                    step: Float(step)
                ) { newY in
                    model.updateSelectedPointLight(position: SIMD3<Float>(light.position.x, newY, light.position.z))
                }
                coordinateRow(
                    axis: "Z",
                    color: NSColor(srgbRed: 0.24, green: 0.54, blue: 0.96, alpha: 1.0),
                    value: light.position.z,
                    range: range,
                    step: Float(step)
                ) { newZ in
                    model.updateSelectedPointLight(position: SIMD3<Float>(light.position.x, light.position.y, newZ))
                }

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

                HStack {
                    Text(L("Puissance (log)", "Power (log)"))
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.textDim.swiftUI)
                    Spacer()
                    Text(Rendering.formatLightPercentage(light.intensity))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.text.swiftUI)
                }
                Slider(
                    value: Binding(
                        get: { Rendering.lightIntensityToSlider(light.intensity, maxIntensity: 3.0) },
                        set: { model.updateSelectedPointLight(intensity: Rendering.sliderToLightIntensity($0, maxIntensity: 3.0)) }
                    ),
                    in: 0.0...1.0
                )
                .tint(Theme.accent.swiftUI)
                .help(L("Puissance lumineuse à échelle logarithmique (réglage fin dans les basses valeurs, de 0 % à 300 %)",
                        "Logarithmic light power (fine control in low values, from 0% to 300%)"))

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
                Button {
                    onChange(value - step)
                } label: {
                    Image(systemName: "minus")
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: 16, height: 16)
                        .background(RoundedRectangle(cornerRadius: 3).fill(Color.white.opacity(0.08)))
                }
                .buttonStyle(.plain)
                Button {
                    onChange(value + step)
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: 16, height: 16)
                        .background(RoundedRectangle(cornerRadius: 3).fill(Color.white.opacity(0.08)))
                }
                .buttonStyle(.plain)
            }
            .foregroundStyle(Theme.textDim.swiftUI)
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

// MARK: - Viewport HUD Overlay

private struct ViewportHUDOverlay: View {
    let model: DocumentModel

    var body: some View {
        VStack {
            // Top banners (Free-fly / Flash feedback)
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

            // Bottom-right orientation gizmo & quick camera pill
            HStack(alignment: .bottom) {
                Spacer()
                HStack(alignment: .center, spacing: 8) {
                    Button {
                        model.resetView()
                    } label: {
                        AxisGizmoView(yaw: model.cameraYaw, pitch: model.cameraPitch)
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

/// Projects the SketchUp world axes (X red, Y green, Z blue) into the current camera basis.
private struct AxisGizmoView: View {
    let yaw: Float
    let pitch: Float

    var body: some View {
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
                                    fullTooltip: skp.layers[index].name,
                                    isVisible: model.layerVisible.indices.contains(index) && model.layerVisible[index],
                                    canSolo: skp.layers.count > 1,
                                    indented: false,
                                    onToggle: { model.toggleLayer(index) },
                                    onSolo: { model.soloLayer(index) }
                                )
                            } else {
                                let isExpanded = !query.isEmpty || model.isLayerGroupExpanded(group.id)
                                LayerGroupRow(
                                    group: group,
                                    visibleCount: model.visibleCount(in: group),
                                    isVisible: model.isLayerGroupVisible(group),
                                    isPartiallyVisible: model.isLayerGroupPartiallyVisible(group),
                                    isExpanded: isExpanded,
                                    canSolo: skp.layers.count > group.layerIndices.count,
                                    onToggleExpand: {
                                        withAnimation(.easeInOut(duration: 0.14)) {
                                            model.toggleLayerGroupExpanded(group.id)
                                        }
                                    },
                                    onToggleVisibility: {
                                        model.toggleLayerGroup(group)
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
                                                fullTooltip: skp.layers[index].name,
                                                isVisible: model.layerVisible.indices.contains(index) && model.layerVisible[index],
                                                canSolo: skp.layers.count > 1,
                                                indented: true,
                                                onToggle: { model.toggleLayer(index) },
                                                onSolo: { model.soloLayer(index) }
                                            )
                                        }
                                    }
                                    .padding(.leading, 12)
                                    .overlay(alignment: .leading) {
                                        Rectangle()
                                            .fill(Color.white.opacity(0.08))
                                            .frame(width: 1)
                                            .padding(.leading, 6)
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
}

private struct LayerGroupRow: View {
    let group: SKPModel.LayerGroup
    let visibleCount: Int
    let isVisible: Bool
    let isPartiallyVisible: Bool
    let isExpanded: Bool
    let canSolo: Bool
    let onToggleExpand: () -> Void
    let onToggleVisibility: () -> Void
    let onSolo: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 5) {
            Button(action: onToggleExpand) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Theme.textDim.swiftUI)
                    .frame(width: 12, height: 14)
            }
            .buttonStyle(.plain)
            .help(isExpanded
                ? L("Replier le groupe « \(group.name) »", "Collapse group “\(group.name)”")
                : L("Déplier le groupe « \(group.name) »", "Expand group “\(group.name)”"))

            Button(action: onToggleVisibility) {
                ZStack {
                    RoundedRectangle(cornerRadius: 3.5)
                        .fill(isVisible ? Theme.accent.swiftUI : Color.white.opacity(0.08))
                        .frame(width: 13.5, height: 13.5)
                        .overlay(
                            RoundedRectangle(cornerRadius: 3.5)
                                .strokeBorder(isVisible ? Theme.accent.swiftUI : Color.white.opacity(0.26), lineWidth: 1)
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
            }
            .buttonStyle(.plain)
            .help(L("Activer ou désactiver tous les calques du groupe « \(group.name) »",
                    "Enable or disable all layers in group “\(group.name)”"))

            Button(action: onToggleExpand) {
                HStack(spacing: 4) {
                    Image(systemName: isExpanded ? "folder.fill" : "folder")
                        .font(.system(size: 10.5))
                        .foregroundStyle(isVisible ? Theme.accent.swiftUI : Theme.textFaint.swiftUI)
                    Text(group.name)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(isVisible ? Theme.text.swiftUI : Theme.textDim.swiftUI)
                        .lineLimit(1)
                }
            }
            .buttonStyle(.plain)

            Spacer(minLength: 0)

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
        .padding(.vertical, 2.5)
        .padding(.horizontal, 4)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(Color.white.opacity(hovering ? 0.055 : 0.025))
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

private struct LayerRow: View {
    let name: String
    let fullTooltip: String
    let isVisible: Bool
    let canSolo: Bool
    let indented: Bool
    let onToggle: () -> Void
    let onSolo: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 4) {
            Toggle(isOn: Binding(get: { isVisible }, set: { _ in onToggle() })) {
                Text(name)
                    .font(.system(size: indented ? 11.5 : 12))
                    .foregroundStyle(isVisible ? Theme.text.swiftUI : Theme.textDim.swiftUI)
                    .lineLimit(1)
            }
            .toggleStyle(.checkbox)
            .help(fullTooltip)

            Spacer(minLength: 0)

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
        .padding(.vertical, 1.5)
        .padding(.horizontal, 2)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
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
                statRow(L("Faces", "Faces"), Format.integer(skp.stats.faces))
                statRow(L("Arêtes", "Edges"), Format.integer(skp.stats.edges))
                statRow(L("Composants", "Components"), Format.integer(skp.stats.instances))
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
            if RemoteControlServer.shared.isOSCListening {
                Text("OSC :\(RemoteControlServer.shared.oscInPort)")
                    .foregroundStyle(Theme.textDim.swiftUI)
                    .help(L("Serveur OSC actif (UDP :\(RemoteControlServer.shared.oscInPort)) · OSCQuery & MCP (TCP :\(RemoteControlServer.shared.httpPort))",
                            "OSC server active (UDP :\(RemoteControlServer.shared.oscInPort)) · OSCQuery & MCP (TCP :\(RemoteControlServer.shared.httpPort))"))
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
