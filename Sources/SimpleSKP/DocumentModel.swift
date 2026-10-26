import AppKit
import Observation
import SceneKit
import SimpleSKPCore
import SimpleSKPViewport
import SwiftUI
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
    var expandedLayerGroups: Set<String> = []
    var selectedLayerIndex: Int? = nil
    var selectedLayerGroupID: String? = nil
    var hoveredLayerIndex: Int? = nil
    var scrollToLayerTrigger: Int = 0
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
    var sunIntensity: Float = Rendering.defaultSunIntensity
    var ambientIntensity: Float = Rendering.defaultAmbientIntensity
    var activeStandardView: StandardView? = nil
    var cameraPosition: SIMD3<Float> = .zero
    var cameraYaw: Float = 0
    var cameraPitch: Float = 0
    var cameraDistance: Float = 1
    var cameraFOV: Float = 35
    var cameraExposure: Float = -0.62
    var cameraOrthoScale: Float = 1
    var cameraSpeedScale: Float = 1
    var showSidebar = false
    var loadSeconds: Double?
    /// Mirrors the viewport, which ends free fly itself (Esc, lost focus): the status bar shows how to get out.
    private(set) var isFreeFlying = false
    /// Short transient toast shown in the viewport header (e.g. "Image copiée").
    var flashMessage: String? = nil
    /// Used by `Snapshot.render` so `cacheDisplay` composites the 3D Metal render below SwiftUI HUD overlays.
    var snapshotPreviewImage: NSImage? = nil
    /// Callback invoked when the camera state changes so `RemoteControlServer` can emit OSC feedback if enabled.
    @ObservationIgnored var onCameraFeedback: ((DocumentModel) -> Void)?

    init() {
        viewport.onFreeFlyingChange = { [weak self] in self?.isFreeFlying = $0 }
        viewport.onPoseChange = { [weak self] _, _, _ in
            guard let self else { return }
            self.syncCameraStateFromViewport()
            self.onCameraFeedback?(self)
        }
        viewport.onResetView = { [weak self] isPersp in
            guard let self else { return }
            self.activeStandardView = nil
            self.isPerspective = isPersp
            self.syncCameraStateFromViewport()
        }
        viewport.onHoverLayer = { [weak self] index in
            self?.setHoveredLayer(index)
        }
        viewport.onSelectLayer = { [weak self] index in
            self?.selectLayerFromViewport(index)
        }
    }

    func syncCameraStateFromViewport() {
        let pose = viewport.cameraPose
        cameraPosition = pose.position
        cameraYaw = pose.yaw
        cameraPitch = pose.pitch
        cameraDistance = pose.distance
        cameraFOV = viewport.fieldOfView
        cameraExposure = viewport.exposureOffset
        cameraOrthoScale = viewport.orthographicScale
        cameraSpeedScale = viewport.movementSpeedScale
    }

    var cameraTarget: SIMD3<Float> {
        viewport.cameraPose.target
    }

    var cameraYawDegrees: Float {
        let deg = (cameraYaw * 180.0 / .pi).truncatingRemainder(dividingBy: 360.0)
        if deg > 180.0 { return deg - 360.0 }
        if deg < -180.0 { return deg + 360.0 }
        return deg
    }

    var cameraPitchDegrees: Float {
        cameraPitch * 180.0 / .pi
    }

    var cameraFocalLengthMM: Float {
        ViewportView.focalLengthMM(forVerticalFOVDegrees: cameraFOV)
    }

    var scene: ViewportScene? {
        if case .ready(let scene) = state { return scene }
        return nil
    }

    var isReady: Bool { scene != nil }

    /// `true` when the open document is an AutoCAD `.dwg` or `.dxf` file.
    var isCAD: Bool { skp?.fileInfo.isCAD == true || info?.isCAD == true }

    /// `true` when the open document is a 2D AutoCAD plan.
    var is2DCAD: Bool { isCAD && (skp?.isPlanar2D ?? true) }

    var error: Error? {
        if case .failed(let error) = state { return error }
        return nil
    }

    // MARK: Loading

    func setModel(_ model: SKPModel) {
        skp = model
        layerVisible = model.layers.map(\.isVisible)
        let multiGroups = model.layerGroups.filter { !$0.isSingleLayer }
        expandedLayerGroups = model.layers.count <= 32 ? Set(multiGroups.map(\.id)) : []
        showSidebar = Preferences.showSidebar && (!model.scenes.isEmpty || model.layers.count > 1)
    }

    /// Main thread, once the scene is built off-main.
    func present(_ scene: ViewportScene, seconds: Double) {
        setModel(scene.model)
        loadSeconds = seconds
        // AutoCAD files (and pure-edge models) always display edges on load and default to a dark studio canvas for crisp CAD line contrast.
        if scene.model.fileInfo.isCAD || (scene.model.stats.faces == 0 && scene.model.stats.edges > 0) {
            showsEdges = true
        }
        if scene.model.fileInfo.isCAD, backdropStyle == .architecturalSky {
            backdropStyle = .studioDark
        }
        scene.showsEdges = showsEdges
        scene.shadowsEnabled = shadowsEnabled
        scene.shadingStyle = shadingStyle
        scene.customBackdropColor = customBackdropColor
        scene.backdropStyle = backdropStyle
        scene.showsGrid = showsGrid
        scene.sunAzimuthDegrees = sunAzimuthDegrees
        scene.sunElevationDegrees = sunElevationDegrees
        scene.sunIntensity = sunIntensity
        scene.ambientIntensity = ambientIntensity
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
        if scene.model.camera == nil {
            activeStandardView = scene.model.isPlanar2D ? .top : .iso
        }
        updateVisibleSize()
        if scene.model.camera == nil, !viewport.is2DNavigationMode, viewport.isPerspective != isPerspective {
            viewport.isPerspective = isPerspective
        }
        isPerspective = viewport.isPerspective
        syncCameraStateFromViewport()
    }

    func fail(_ error: Error) {
        state = .failed(error)
    }

    // MARK: Actions

    static var isShiftPressed: Bool {
        NSEvent.modifierFlags.contains(.shift)
    }

    func selectScene(_ index: Int, slow: Bool? = nil) {
        guard let skp, skp.scenes.indices.contains(index) else { return }
        selectedScene = index
        activeStandardView = nil
        if let hidden = skp.scenes[index].hiddenLayers.map(Set.init) {
            layerVisible = layerVisible.indices.map { !hidden.contains($0) }
            scene?.setLayers(layerVisible) // at once: no layer set visible only midway gets built
            updateVisibleSize()
        }
        if isReady, let camera = skp.scenes[index].camera {
            let useSlow = slow ?? Self.isShiftPressed
            let duration = useSlow ? CameraRig.slowGlideDuration : CameraRig.defaultGlideDuration
            viewport.apply(camera: camera, animated: true, duration: duration)
            isPerspective = camera.isPerspective
            syncCameraStateFromViewport()
        }
    }

    func previousScene(slow: Bool? = nil) {
        guard let count = skp?.scenes.count, count > 0 else { return }
        selectScene(((selectedScene ?? 0) - 1 + count) % count, slow: slow)
    }

    func nextScene(slow: Bool? = nil) {
        guard let count = skp?.scenes.count, count > 0 else { return }
        selectScene(((selectedScene ?? -1) + 1) % count, slow: slow)
    }

    func toggleLayer(_ index: Int) {
        guard layerVisible.indices.contains(index) else { return }
        layerVisible[index].toggle()
        scene?.setLayer(index, visible: layerVisible[index])
        updateVisibleSize()
        viewport.requestRedraw()
    }

    /// Updates the subtle hover highlight in the viewport and sidebar when the mouse moves over geometry.
    func setHoveredLayer(_ index: Int?) {
        let validIndex: Int?
        if let index, let skp, skp.layers.indices.contains(index) {
            validIndex = index
        } else {
            validIndex = nil
        }
        guard hoveredLayerIndex != validIndex else { return }
        hoveredLayerIndex = validIndex
        scene?.setHoveredLayers(validIndex.map { [$0] } ?? [])
        viewport.requestRedraw()
    }

    var hoveredLayerName: String? {
        guard let index = hoveredLayerIndex, let skp, skp.layers.indices.contains(index) else { return nil }
        return skp.layers[index].name
    }

    /// Contrast-adapted UI swatch color for a layer when the layer carries an explicit CAD/SketchUp color.
    func layerDisplayColor(_ index: Int) -> Color? {
        guard let skp, skp.layers.indices.contains(index), let raw = skp.layers[index].color else { return nil }
        let luma = Rendering.backdropLuminance(for: backdropStyle, customColor: customBackdropColor)
        let rgb = Rendering.adaptedCADColor(SIMD3<Float>(raw.x, raw.y, raw.z), backdropLuminance: luma)
        return Color(.sRGB, red: Double(rgb.x), green: Double(rgb.y), blue: Double(rgb.z), opacity: 1.0)
    }

    var hoveredLayerColor: Color? {
        hoveredLayerIndex.flatMap(layerDisplayColor)
    }

    /// Selects a layer by index in the sidebar and triggers a brief brightness pulse on its geometry in the viewport.
    func selectLayer(_ index: Int) {
        guard let skp, skp.layers.indices.contains(index) else { return }
        selectedLayerIndex = index
        selectedLayerGroupID = nil
        scene?.pulseLayers([index]) { [weak self] in
            self?.viewport.requestRedraw()
        }
    }

    /// Clicking an object directly in the viewport: reveals and expands its group in the hierarchy, scrolls to it, and selects + pulses it.
    func selectLayerFromViewport(_ index: Int) {
        guard let skp, skp.layers.indices.contains(index) else { return }
        if !showSidebar, skp.layers.count > 1 || !skp.scenes.isEmpty {
            withAnimation(.spring(duration: 0.22, bounce: 0.0)) {
                showSidebar = true
            }
            Preferences.showSidebar = true
        }
        if let group = skp.layerGroups.first(where: { !$0.isSingleLayer && $0.layerIndices.contains(index) }) {
            expandedLayerGroups.insert(group.id)
        }
        if !layerFilter.isEmpty {
            let q = layerFilter.trimmingCharacters(in: .whitespacesAndNewlines)
            if !q.isEmpty, !skp.layers[index].name.localizedCaseInsensitiveContains(q) {
                layerFilter = ""
            }
        }
        selectLayer(index)
        scrollToLayerTrigger &+= 1
    }

    /// Selects a layer group in the sidebar and triggers a brief brightness pulse on all visible layers in the group.
    func selectLayerGroup(_ group: SKPModel.LayerGroup) {
        selectedLayerGroupID = group.id
        selectedLayerIndex = nil
        scene?.pulseLayers(Set(group.layerIndices)) { [weak self] in
            self?.viewport.requestRedraw()
        }
    }

    /// Double-clicking a layer name in the sidebar: ensures it is visible, pulses it, and smoothly glides the camera to frame its geometry.
    func zoomToLayer(_ index: Int, animated: Bool = true) {
        guard let skp, skp.layers.indices.contains(index) else { return }
        if layerVisible.indices.contains(index), !layerVisible[index] {
            layerVisible[index] = true
            scene?.setLayer(index, visible: true)
            updateVisibleSize()
        }
        selectLayer(index)
        guard let bounds = scene?.bounds(forLayers: [index]) else { return }
        activeStandardView = nil
        viewport.frameBounds(min: bounds.min, max: bounds.max, animated: animated)
        syncCameraStateFromViewport()
    }

    /// Double-clicking a layer group name in the sidebar: ensures its layers are visible, pulses them, and smoothly glides the camera to frame the group.
    func zoomToLayerGroup(_ group: SKPModel.LayerGroup, animated: Bool = true) {
        if !isLayerGroupVisible(group) {
            setLayerGroup(group, visible: true)
        }
        selectLayerGroup(group)
        guard let bounds = scene?.bounds(forLayers: Set(group.layerIndices)) else { return }
        activeStandardView = nil
        viewport.frameBounds(min: bounds.min, max: bounds.max, animated: animated)
        syncCameraStateFromViewport()
    }

    func setAllLayers(visible: Bool) {
        guard !layerVisible.isEmpty else { return }
        layerVisible = Array(repeating: visible, count: layerVisible.count)
        scene?.setLayers(layerVisible)
        updateVisibleSize()
        viewport.requestRedraw()
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
            viewport.requestRedraw()
        }
    }

    func visibleCount(in group: SKPModel.LayerGroup) -> Int {
        group.layerIndices.reduce(0) { count, idx in
            count + ((layerVisible.indices.contains(idx) && layerVisible[idx]) ? 1 : 0)
        }
    }

    func isLayerGroupVisible(_ group: SKPModel.LayerGroup) -> Bool {
        visibleCount(in: group) > 0
    }

    func isLayerGroupPartiallyVisible(_ group: SKPModel.LayerGroup) -> Bool {
        let count = visibleCount(in: group)
        return count > 0 && count < group.layerIndices.count
    }

    func setLayerGroup(_ group: SKPModel.LayerGroup, visible: Bool) {
        var changed = false
        for idx in group.layerIndices where layerVisible.indices.contains(idx) {
            if layerVisible[idx] != visible {
                layerVisible[idx] = visible
                changed = true
            }
        }
        guard changed else { return }
        scene?.setLayers(layerVisible)
        updateVisibleSize()
        viewport.requestRedraw()
    }

    func toggleLayerGroup(_ group: SKPModel.LayerGroup) {
        setLayerGroup(group, visible: !isLayerGroupVisible(group))
    }

    /// Isolates all layers of a `LayerGroup` (`Solo`), or restores all layers if that group was already the only visible one.
    func soloLayerGroup(_ group: SKPModel.LayerGroup) {
        let memberSet = Set(group.layerIndices)
        guard !memberSet.isEmpty else { return }
        let isAlreadySolo = layerVisible.indices.allSatisfy { memberSet.contains($0) == layerVisible[$0] }
        if isAlreadySolo {
            setAllLayers(visible: true)
        } else {
            layerVisible = layerVisible.indices.map { memberSet.contains($0) }
            scene?.setLayers(layerVisible)
            updateVisibleSize()
            viewport.requestRedraw()
        }
    }

    func isLayerGroupExpanded(_ id: String) -> Bool {
        expandedLayerGroups.contains(id)
    }

    func toggleLayerGroupExpanded(_ id: String) {
        if expandedLayerGroups.contains(id) {
            expandedLayerGroups.remove(id)
        } else {
            expandedLayerGroups.insert(id)
        }
    }

    func setAllLayerGroupsExpanded(_ expanded: Bool) {
        let multiIDs = (skp?.layerGroups ?? []).filter { !$0.isSingleLayer }.map(\.id)
        expandedLayerGroups = expanded ? Set(multiIDs) : []
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
        setPerspective(!isPerspective)
    }

    func setPerspective(_ enabled: Bool) {
        guard isPerspective != enabled || (isReady && viewport.isPerspective != enabled) else { return }
        isPerspective = enabled
        Preferences.isPerspective = enabled
        if isReady {
            viewport.isPerspective = enabled
            syncCameraStateFromViewport()
        }
    }

    func setCameraFOV(_ degrees: Float) {
        let clamped = max(10.0, min(120.0, degrees))
        cameraFOV = clamped
        viewport.fieldOfView = clamped
    }

    func setCameraFocalLength(_ mm: Float) {
        let fov = ViewportView.verticalFOVDegrees(forFocalLengthMM: mm)
        setCameraFOV(fov)
    }

    func setCameraExposure(_ ev: Float) {
        let clamped = max(-3.0, min(3.0, ev))
        cameraExposure = clamped
        viewport.exposureOffset = clamped
    }

    func setCameraOrthoScale(_ scale: Float) {
        let clamped = max(0.05, min(10_000.0, scale))
        cameraOrthoScale = clamped
        viewport.orthographicScale = clamped
    }

    func setCameraSpeedScale(_ scale: Float) {
        let clamped = max(1.0 / 16.0, min(16.0, scale))
        cameraSpeedScale = clamped
        viewport.movementSpeedScale = clamped
    }

    func setCameraPosition(_ position: SIMD3<Float>) {
        activeStandardView = nil
        viewport.setCameraPose(position: position)
        syncCameraStateFromViewport()
    }

    func setCameraOrientation(yawDegrees: Float? = nil, pitchDegrees: Float? = nil) {
        activeStandardView = nil
        viewport.setCameraPose(yawDegrees: yawDegrees, pitchDegrees: pitchDegrees)
        syncCameraStateFromViewport()
    }

    func setCameraDistance(_ distance: Float) {
        viewport.setCameraPose(distance: max(0.05, distance))
        syncCameraStateFromViewport()
    }

    func setCameraTarget(_ target: SIMD3<Float>, animated: Bool = false) {
        activeStandardView = nil
        viewport.setCameraTarget(target, animated: animated)
        syncCameraStateFromViewport()
    }

    func setCameraLookAt(position: SIMD3<Float>, target: SIMD3<Float>, animated: Bool = false) {
        activeStandardView = nil
        viewport.setCameraLookAt(position: position, target: target, animated: animated)
        syncCameraStateFromViewport()
    }

    func orbitCameraByDegrees(yaw dYawDegrees: Float, pitch dPitchDegrees: Float) {
        activeStandardView = nil
        viewport.orbitByDegrees(yaw: dYawDegrees, pitch: dPitchDegrees)
        syncCameraStateFromViewport()
    }

    func levelCameraHorizon(animated: Bool = true) {
        activeStandardView = nil
        viewport.levelHorizon(animated: animated)
        syncCameraStateFromViewport()
    }

    /// Places the camera at human eye height (`1.70 m` above the model floor or Z=0) and levels the horizon.
    func setCameraEyeHeight(_ heightAboveFloor: Float = 1.70) {
        activeStandardView = nil
        let bMinZ = scene?.visibleBounds.min.z ?? skp?.boundsMin.z ?? 0
        let bMaxZ = scene?.visibleBounds.max.z ?? skp?.boundsMax.z ?? 3
        let floorZ = (bMinZ <= 0.2 && bMaxZ >= 1.5) ? 0.0 : bMinZ
        var pos = viewport.cameraModelPosition
        pos.z = floorZ + heightAboveFloor
        viewport.setCameraPose(position: pos, pitchDegrees: 0)
        syncCameraStateFromViewport()
    }

    /// Places the camera at the geometric center of the model and levels the horizon.
    func centerCameraInModel() {
        activeStandardView = nil
        let center = scene?.defaultPointLightPosition ?? skp?.center ?? .zero
        viewport.setCameraPose(position: center, pitchDegrees: 0)
        syncCameraStateFromViewport()
    }

    var cameraCoordinateRange: ClosedRange<Double> {
        pointLightCoordinateRange
    }

    var cameraDistanceRange: ClosedRange<Double> {
        let b = scene?.visibleBounds ?? (min: skp?.boundsMin ?? SIMD3(-5, -5, -5), max: skp?.boundsMax ?? SIMD3(5, 5, 5))
        let diag = Double(max(simd_length(b.max - b.min) * 2.0, 10.0))
        return 0.1...diag
    }

    func setShadingStyle(_ style: ShadingStyle) {
        shadingStyle = style
        scene?.shadingStyle = style
        if style == .wireframe, !showsEdges {
            showsEdges = true
        }
        viewport.requestRedraw()
    }

    func setBackdropStyle(_ style: BackdropStyle) {
        backdropStyle = style
        Preferences.backdropStyle = style
        scene?.backdropStyle = style
        viewport.requestRedraw()
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
        viewport.requestRedraw()
    }

    func toggleGrid() {
        showsGrid.toggle()
        Preferences.showsGrid = showsGrid
        scene?.showsGrid = showsGrid
        viewport.requestRedraw()
    }

    func toggleShadows() {
        shadowsEnabled.toggle()
        Preferences.shadowsEnabled = shadowsEnabled
        scene?.shadowsEnabled = shadowsEnabled
        viewport.requestRedraw()
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
        viewport.requestRedraw()
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
        viewport.requestRedraw()
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
        viewport.requestRedraw()
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
        viewport.requestRedraw()
    }

    func removeSelectedPointLight() {
        guard pointLights.indices.contains(selectedPointLightIndex), pointLights.count > 1 else { return }
        pointLights.remove(at: selectedPointLightIndex)
        selectedPointLightIndex = max(0, min(selectedPointLightIndex, pointLights.count - 1))
        scene?.pointLights = pointLights
        viewport.requestRedraw()
    }

    func centerSelectedPointLight() {
        guard pointLights.indices.contains(selectedPointLightIndex) else { return }
        let center = scene?.defaultPointLightPosition ?? skp?.center ?? .zero
        pointLights[selectedPointLightIndex].position = center
        scene?.pointLights = pointLights
        viewport.requestRedraw()
    }

    func moveSelectedPointLightToCamera() {
        guard pointLights.indices.contains(selectedPointLightIndex), isReady else { return }
        pointLights[selectedPointLightIndex].position = viewport.cameraModelPosition
        scene?.pointLights = pointLights
        viewport.requestRedraw()
    }

    func updateSelectedPointLight(position: SIMD3<Float>? = nil, intensity: Float? = nil) {
        guard pointLights.indices.contains(selectedPointLightIndex) else { return }
        if let position { pointLights[selectedPointLightIndex].position = position }
        if let intensity { pointLights[selectedPointLightIndex].intensity = max(0.0, min(3.0, intensity)) }
        scene?.pointLights = pointLights
        viewport.requestRedraw()
    }

    func togglePointLightGizmo() {
        showsPointLightGizmo.toggle()
        scene?.showsPointLightGizmo = showsPointLightGizmo
        viewport.requestRedraw()
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
        viewport.requestRedraw()
    }

    func setSunIntensity(_ intensity: Float) {
        let clamped = max(0.0, min(3.0, intensity))
        sunIntensity = clamped
        scene?.sunIntensity = clamped
        viewport.requestRedraw()
    }

    func setAmbientIntensity(_ intensity: Float) {
        let clamped = max(0.0, min(2.0, intensity))
        ambientIntensity = clamped
        scene?.ambientIntensity = clamped
        viewport.requestRedraw()
    }

    func resetSun() {
        sunAzimuthDegrees = -135
        sunElevationDegrees = 45
        sunIntensity = Rendering.defaultSunIntensity
        ambientIntensity = Rendering.defaultAmbientIntensity
        scene?.resetSun()
        scene?.ambientIntensity = ambientIntensity
        viewport.requestRedraw()
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
        withAnimation(.spring(duration: 0.22, bounce: 0.0)) {
            showSidebar.toggle()
        }
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

    func renderVectorPDF(pageSize: CGSize? = nil) -> Data? {
        guard isReady else { return nil }
        return VectorPDFExporter.renderPDF(from: viewport, visibleLayers: layerVisible, pageSize: pageSize)
    }

    func exportVectorPDF() {
        guard isReady, let pdf = renderVectorPDF() else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        let baseName = info?.url.deletingPathExtension().lastPathComponent ?? "SimpleSKP"
        panel.nameFieldStringValue = "\(baseName).pdf"
        panel.title = L("Exporter la vue en PDF vectoriel", "Export View as Vector PDF")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try pdf.write(to: url, options: .atomic)
            flash(L("PDF vectoriel exporté", "Vector PDF exported"))
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
