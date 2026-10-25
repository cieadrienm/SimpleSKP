import AppKit
import Observation
import SceneKit
import SimpleSKPCore
import SimpleSKPViewport
import UniformTypeIdentifiers

/// State of one open `.skp`: header first, then the loaded model and its scene. Owns the viewport so the
/// menu actions reach it. Every viewport call is guarded by `.ready`: before that there is no scene.
@Observable
@MainActor
final class DocumentModel {
    enum State {
        case loading(SKPReader.Progress?)
        case ready(ViewportScene)
        case failed(Error)
    }

    var info: SKPFileInfo? {
        didSet {
            thumbnail = info?.thumbnailPNG.flatMap(NSImage.init(data:))
            sketchUpApp = info.flatMap { Self.sketchUpApp(opening: $0.url) } // once: menu validation and banners read it often
        }
    }
    private(set) var thumbnail: NSImage?
    /// The installed SketchUp that opens this file (nil without one).
    private(set) var sketchUpApp: URL?
    var state: State = .loading(nil)
    /// Set with the scene, in `present` (`setModel` alone in the tests).
    private(set) var skp: SKPModel?
    /// Size of what is shown (status bar): the visible bounds, refreshed at `present` and after a layer or scene change.
    private(set) var visibleSize: SIMD3<Float>?
    @ObservationIgnored let viewport = ViewportView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
    var selectedScene: Int?
    var layerVisible: [Bool] = []
    var layerFilter: String = ""
    var showsEdges = Preferences.showsEdges
    var showsGrid = Preferences.showsGrid
    var isPerspective = Preferences.isPerspective
    var shadowsEnabled = Preferences.shadowsEnabled
    var ambientOcclusionEnabled = Preferences.ambientOcclusionEnabled
    var ambientOcclusionIntensity = Preferences.ambientOcclusionIntensity
    var shadingStyle: ShadingStyle = .textured
    var backdropStyle: BackdropStyle = Preferences.backdropStyle
    var customBackdropColor: SIMD3<Float> = Preferences.customBackdropColor
    var lightingMode: LightingMode = .sun
    var pointLights: [ViewportPointLight] = []
    var selectedPointLightIndex: Int = 0
    var showsPointLightGizmo: Bool = true
    var sunAzimuthDegrees: Float = -135
    var sunElevationDegrees: Float = 45
    var activeStandardView: StandardView? = nil
    var cameraYaw: Float = 0
    var cameraPitch: Float = 0
    var showSidebar = false
    var loadSeconds: Double?
    /// Mirrors the viewport, which ends free fly itself (Esc, lost focus): the status bar shows how to get out.
    private(set) var isFreeFlying = false
    /// Short transient toast shown in the viewport header (e.g. "Image copiée").
    var flashMessage: String? = nil
    /// Used by `Snapshot.render` so `cacheDisplay` composites the 3D Metal render below SwiftUI HUD overlays.
    var snapshotPreviewImage: NSImage? = nil

    init() {
        viewport.onFreeFlyingChange = { [weak self] in self?.isFreeFlying = $0 }
        viewport.onPoseChange = { [weak self] yaw, pitch, _ in
            guard let self else { return }
            self.cameraYaw = yaw
            self.cameraPitch = pitch
        }
        viewport.onResetView = { [weak self] isPersp in
            guard let self else { return }
            self.activeStandardView = nil
            self.isPerspective = isPersp
        }
    }

    var scene: ViewportScene? {
        if case .ready(let scene) = state { return scene }
        return nil
    }

    var isReady: Bool { scene != nil }

    var error: Error? {
        if case .failed(let error) = state { return error }
        return nil
    }

    // MARK: Loading

    func setModel(_ model: SKPModel) {
        skp = model
        layerVisible = model.layers.map(\.isVisible)
        showSidebar = Preferences.showSidebar && (!model.scenes.isEmpty || model.layers.count > 1)
    }

    /// Main thread, once the scene is built off-main.
    func present(_ scene: ViewportScene, seconds: Double) {
        setModel(scene.model)
        loadSeconds = seconds
        if !showsEdges { scene.showsEdges = false }
        scene.shadowsEnabled = shadowsEnabled
        scene.shadingStyle = shadingStyle
        scene.customBackdropColor = customBackdropColor
        scene.backdropStyle = backdropStyle
        scene.showsGrid = showsGrid
        scene.sunAzimuthDegrees = sunAzimuthDegrees
        scene.sunElevationDegrees = sunElevationDegrees
        scene.showsPointLightGizmo = showsPointLightGizmo
        if !scene.detectedSceneLights.isEmpty {
            pointLights = scene.detectedSceneLights
            selectedPointLightIndex = 0
        }
        scene.lightingMode = lightingMode
        if !pointLights.isEmpty {
            scene.pointLights = pointLights
        }
        viewport.ambientOcclusionIntensity = CGFloat(ambientOcclusionIntensity)
        viewport.ambientOcclusionEnabled = ambientOcclusionEnabled
        state = .ready(scene)
        viewport.present(scene)
        updateVisibleSize()
        if scene.model.camera == nil, viewport.isPerspective != isPerspective {
            viewport.isPerspective = isPerspective
        }
        isPerspective = viewport.isPerspective
    }

    func fail(_ error: Error) {
        state = .failed(error)
    }

    // MARK: Actions

    func selectScene(_ index: Int) {
        guard let skp, skp.scenes.indices.contains(index) else { return }
        selectedScene = index
        activeStandardView = nil
        if let hidden = skp.scenes[index].hiddenLayers.map(Set.init) {
            layerVisible = layerVisible.indices.map { !hidden.contains($0) }
            scene?.setLayers(layerVisible) // at once: no layer set visible only midway gets built
            updateVisibleSize()
        }
        if isReady, let camera = skp.scenes[index].camera {
            viewport.apply(camera: camera, animated: true)
            isPerspective = camera.isPerspective
        }
    }

    func previousScene() {
        guard let count = skp?.scenes.count, count > 0 else { return }
        selectScene(((selectedScene ?? 0) - 1 + count) % count)
    }

    func nextScene() {
        guard let count = skp?.scenes.count, count > 0 else { return }
        selectScene(((selectedScene ?? -1) + 1) % count)
    }

    func toggleLayer(_ index: Int) {
        guard layerVisible.indices.contains(index) else { return }
        layerVisible[index].toggle()
        scene?.setLayer(index, visible: layerVisible[index])
        updateVisibleSize()
    }

    func setAllLayers(visible: Bool) {
        guard !layerVisible.isEmpty else { return }
        layerVisible = Array(repeating: visible, count: layerVisible.count)
        scene?.setLayers(layerVisible)
        updateVisibleSize()
    }

    /// Isolates a single layer (`Solo`), or restores all layers if it was already the only visible one.
    func soloLayer(_ index: Int) {
        guard layerVisible.indices.contains(index) else { return }
        let isAlreadySolo = layerVisible.indices.allSatisfy { ($0 == index) == layerVisible[$0] }
        if isAlreadySolo {
            setAllLayers(visible: true)
        } else {
            layerVisible = layerVisible.indices.map { $0 == index }
            scene?.setLayers(layerVisible)
            updateVisibleSize()
        }
    }

    var visibleLayerCount: Int {
        layerVisible.filter { $0 }.count
    }

    private func updateVisibleSize() {
        visibleSize = scene.map { $0.visibleBounds.max - $0.visibleBounds.min }
    }

    func resetView() {
        guard isReady else { return }
        activeStandardView = nil
        viewport.resetView(animated: true)
        isPerspective = viewport.isPerspective
    }

    func zoomExtents() {
        if isReady { viewport.zoomExtents(animated: true) }
    }

    func zoomIn() {
        if isReady { viewport.zoomStep(ratio: 1 / 1.28) }
    }

    func zoomOut() {
        if isReady { viewport.zoomStep(ratio: 1.28) }
    }

    func look(_ view: StandardView) {
        guard isReady else { return }
        activeStandardView = view
        viewport.look(view, animated: true)
    }

    func togglePerspective() {
        isPerspective.toggle()
        Preferences.isPerspective = isPerspective
        if isReady { viewport.isPerspective = isPerspective }
    }

    func setShadingStyle(_ style: ShadingStyle) {
        shadingStyle = style
        scene?.shadingStyle = style
        if style == .wireframe, !showsEdges {
            showsEdges = true
        }
        viewport.setNeedsDisplay(viewport.bounds)
    }

    func setBackdropStyle(_ style: BackdropStyle) {
        backdropStyle = style
        Preferences.backdropStyle = style
        scene?.backdropStyle = style
        viewport.setNeedsDisplay(viewport.bounds)
    }

    func setCustomBackdropColor(_ color: SIMD3<Float>) {
        let clamped = simd_clamp(color, .zero, SIMD3(repeating: 1))
        customBackdropColor = clamped
        Preferences.customBackdropColor = clamped
        scene?.customBackdropColor = clamped
        if backdropStyle != .customColor {
            backdropStyle = .customColor
            Preferences.backdropStyle = .customColor
            scene?.backdropStyle = .customColor
        }
        viewport.setNeedsDisplay(viewport.bounds)
    }

    func toggleGrid() {
        showsGrid.toggle()
        Preferences.showsGrid = showsGrid
        scene?.showsGrid = showsGrid
        viewport.setNeedsDisplay(viewport.bounds)
    }

    func toggleShadows() {
        shadowsEnabled.toggle()
        Preferences.shadowsEnabled = shadowsEnabled
        scene?.shadowsEnabled = shadowsEnabled
        viewport.setNeedsDisplay(viewport.bounds)
    }

    func toggleAmbientOcclusion() {
        ambientOcclusionEnabled.toggle()
        Preferences.ambientOcclusionEnabled = ambientOcclusionEnabled
        if ambientOcclusionEnabled && ambientOcclusionIntensity <= 0.01 {
            ambientOcclusionIntensity = Float(Rendering.defaultAmbientOcclusionIntensity)
            Preferences.ambientOcclusionIntensity = ambientOcclusionIntensity
            viewport.ambientOcclusionIntensity = CGFloat(ambientOcclusionIntensity)
        }
        viewport.ambientOcclusionEnabled = ambientOcclusionEnabled
        viewport.setNeedsDisplay(viewport.bounds)
    }

    func setAmbientOcclusionIntensity(_ value: Float) {
        let clamped = max(0, min(2.0, value))
        ambientOcclusionIntensity = clamped
        Preferences.ambientOcclusionIntensity = clamped
        viewport.ambientOcclusionIntensity = CGFloat(clamped)
        let shouldEnable = clamped > 0.01
        if ambientOcclusionEnabled != shouldEnable {
            ambientOcclusionEnabled = shouldEnable
            Preferences.ambientOcclusionEnabled = shouldEnable
            viewport.ambientOcclusionEnabled = shouldEnable
        }
        viewport.setNeedsDisplay(viewport.bounds)
    }

    func setLightingMode(_ mode: LightingMode) {
        lightingMode = mode
        if mode == .point && pointLights.isEmpty {
            if let detected = scene?.detectedSceneLights, !detected.isEmpty {
                pointLights = detected
            } else {
                let center = scene?.defaultPointLightPosition ?? skp?.center ?? .zero
                pointLights = [ViewportPointLight(name: L("Lumière 1", "Light 1"), position: center, intensity: 1.0, isFromScene: false)]
            }
            selectedPointLightIndex = 0
        }
        scene?.pointLights = pointLights
        scene?.lightingMode = mode
        viewport.setNeedsDisplay(viewport.bounds)
    }

    func addPointLight() {
        let center = scene?.defaultPointLightPosition ?? skp?.center ?? .zero
        let offset = Float(pointLights.count) * 0.25
        let newLight = ViewportPointLight(
            name: L("Lumière \(pointLights.count + 1)", "Light \(pointLights.count + 1)"),
            position: center + SIMD3(offset, offset, 0),
            intensity: 1.0,
            isFromScene: false
        )
        pointLights.append(newLight)
        selectedPointLightIndex = pointLights.count - 1
        if lightingMode != .point {
            lightingMode = .point
            scene?.lightingMode = .point
        }
        scene?.pointLights = pointLights
        viewport.setNeedsDisplay(viewport.bounds)
    }

    func removeSelectedPointLight() {
        guard pointLights.indices.contains(selectedPointLightIndex), pointLights.count > 1 else { return }
        pointLights.remove(at: selectedPointLightIndex)
        selectedPointLightIndex = max(0, min(selectedPointLightIndex, pointLights.count - 1))
        scene?.pointLights = pointLights
        viewport.setNeedsDisplay(viewport.bounds)
    }

    func centerSelectedPointLight() {
        guard pointLights.indices.contains(selectedPointLightIndex) else { return }
        let center = scene?.defaultPointLightPosition ?? skp?.center ?? .zero
        pointLights[selectedPointLightIndex].position = center
        scene?.pointLights = pointLights
        viewport.setNeedsDisplay(viewport.bounds)
    }

    func moveSelectedPointLightToCamera() {
        guard pointLights.indices.contains(selectedPointLightIndex), isReady else { return }
        pointLights[selectedPointLightIndex].position = viewport.cameraModelPosition
        scene?.pointLights = pointLights
        viewport.setNeedsDisplay(viewport.bounds)
    }

    func updateSelectedPointLight(position: SIMD3<Float>? = nil, intensity: Float? = nil) {
        guard pointLights.indices.contains(selectedPointLightIndex) else { return }
        if let position { pointLights[selectedPointLightIndex].position = position }
        if let intensity { pointLights[selectedPointLightIndex].intensity = max(0.05, min(3.0, intensity)) }
        scene?.pointLights = pointLights
        viewport.setNeedsDisplay(viewport.bounds)
    }

    func togglePointLightGizmo() {
        showsPointLightGizmo.toggle()
        scene?.showsPointLightGizmo = showsPointLightGizmo
        viewport.setNeedsDisplay(viewport.bounds)
    }

    var selectedPointLight: ViewportPointLight? {
        guard pointLights.indices.contains(selectedPointLightIndex) else { return nil }
        return pointLights[selectedPointLightIndex]
    }

    var pointLightCoordinateRange: ClosedRange<Double> {
        let b = scene?.visibleBounds ?? (min: skp?.boundsMin ?? SIMD3(-5, -5, -5), max: skp?.boundsMax ?? SIMD3(5, 5, 5))
        let center = (b.min + b.max) * 0.5
        let extent = max(simd_length(b.max - b.min) * 1.1, 2.0)
        let lo = Double(min(center.x, min(center.y, center.z)) - extent)
        let hi = Double(max(center.x, max(center.y, center.z)) + extent)
        return lo...hi
    }

    func setSun(azimuth: Float, elevation: Float) {
        sunAzimuthDegrees = azimuth
        sunElevationDegrees = elevation
        scene?.sunAzimuthDegrees = azimuth
        scene?.sunElevationDegrees = elevation
        viewport.setNeedsDisplay(viewport.bounds)
    }

    func resetSun() {
        sunAzimuthDegrees = -135
        sunElevationDegrees = 45
        scene?.resetSun()
        viewport.setNeedsDisplay(viewport.bounds)
    }

    func toggleFreeFlight() {
        if isReady { viewport.isFreeFlying.toggle() }
    }

    func toggleEdges() {
        showsEdges.toggle()
        Preferences.showsEdges = showsEdges
        scene?.showsEdges = showsEdges
        viewport.setNeedsDisplay(viewport.bounds)
    }

    func toggleSidebar() {
        showSidebar.toggle()
        Preferences.showSidebar = showSidebar
    }

    func copyImage() {
        guard isReady, let png = Snapshot.png(of: viewport.snapshot()) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(png, forType: .png)
        flash(L("Image copiée dans le presse-papiers", "Image copied to clipboard"))
    }

    func exportImage() {
        guard isReady, let png = Snapshot.png(of: viewport.snapshot()) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        let baseName = info?.url.deletingPathExtension().lastPathComponent ?? "SimpleSKP"
        panel.nameFieldStringValue = "\(baseName).png"
        panel.title = L("Exporter l'image PNG", "Export PNG Image")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try png.write(to: url, options: .atomic)
            flash(L("Image PNG exportée", "PNG image exported"))
        } catch {
            NSApp.presentError(error)
        }
    }

    func flash(_ message: String) {
        flashMessage = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            if self?.flashMessage == message {
                self?.flashMessage = nil
            }
        }
    }

    /// The one the framework came from when it is a SketchUp.app, else any SketchUp registered for `.skp` (the default
    /// app may be SimpleSKP itself).
    private static func sketchUpApp(opening url: URL) -> URL? {
        let host = SketchUpAPI.locate()?.frameworkURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        if let host, host.pathExtension == "app", host.lastPathComponent.hasPrefix("SketchUp") { return host }
        return NSWorkspace.shared.urlsForApplications(toOpen: url).first { $0.lastPathComponent.hasPrefix("SketchUp") }
    }

    func openInSketchUp() {
        guard let url = info?.url, let app = sketchUpApp else { return }
        NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }

    func revealInFinder() {
        if let url = info?.url { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }

    // MARK: Status bar

    /// Left part of the status bar: the file's numbers once read, else the loading phase or the error.
    var statusText: String {
        if let error { return error.localizedDescription }
        if isFreeFlying { return L("Vol libre — Échap pour sortir", "Free fly — Esc to exit") }
        if let skp {
            let size = visibleSize ?? skp.size
            let parts: [String?] = [
                info?.versionLabel ?? skp.fileInfo.versionLabel,
                Format.count(skp.stats.faces, L("face", "face")),
                Format.count(skp.stats.edges, L("arête", "edge")),
                Format.count(skp.stats.instances, L("composant", "component")),
                "\(Format.decimal(size.x)) × \(Format.decimal(size.y)) × \(Format.decimal(size.z)) m",
            ]
            return parts.compactMap { $0 }.joined(separator: " · ")
        }
        var text = L("Chargement…", "Loading…")
        if case .loading(let progress?) = state {
            text += " \(progress.phase) · " + Format.count(progress.faces, L("face", "face"))
        }
        return text
    }
}

/// Numbers in the interface language: French groups thousands with a narrow no-break space and uses a comma.
@MainActor
enum Format {
    private static var formatters: [String: NumberFormatter] = [:]

    private static func formatter(decimals: Int) -> NumberFormatter {
        let key = "\(Localization.current.resolvedCode)-\(decimals)"
        if let formatter = formatters[key] { return formatter }
        let formatter = NumberFormatter()
        formatter.locale = Localization.current.locale
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        if !Localization.isEnglish { formatter.groupingSeparator = "\u{202F}" }
        formatter.minimumFractionDigits = decimals
        formatter.maximumFractionDigits = decimals
        formatters[key] = formatter
        return formatter
    }

    static func integer(_ value: Int) -> String {
        formatter(decimals: 0).string(from: NSNumber(value: value)) ?? "\(value)"
    }

    static func decimal<T: BinaryFloatingPoint>(_ value: T) -> String {
        formatter(decimals: 1).string(from: NSNumber(value: Double(value))) ?? "\(value)"
    }

    /// "184 320 faces", "1 face", "0 face" in French, "0 faces" in English.
    static func count(_ value: Int, _ singular: String) -> String {
        "\(integer(value)) \(singular)\(Localization.isEnglish ? (value == 1 ? "" : "s") : (value > 1 ? "s" : ""))"
    }

    /// "1,9 s".
    static func seconds(_ value: Double) -> String {
        "\(decimal(value)) s"
    }
}
