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

    struct ViewConstructionProgress {
        var currentLayerIndex: Int
        var currentLayerName: String
        var completedLayers: Int
        var totalLayers: Int
        var edgesBuilt: Int
        var facesBuilt: Int
        var fraction: Double
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
    enum ProjectorPickMode: Equatable {
        case none
        case position
        case target
    }

    var backdropStyle: BackdropStyle = Preferences.backdropStyle
    var customBackdropColor: SIMD3<Float> = Preferences.customBackdropColor
    var lightingMode: LightingMode = .sun
    var pointLights: [ViewportPointLight] = []
    var selectedPointLightIndex: Int = 0
    var showsPointLightGizmo: Bool = true
    var hiddenFeaturesEnabled: Bool = Preferences.hiddenFeatures
    var videoProjectors: [VideoProjector] = []
    var selectedVideoProjectorIndex: Int = 0
    var projectorPickMode: ProjectorPickMode = .none
    var sskpURL: URL? = nil
    var pendingSSKPProject: SSKPProject? = nil
    @ObservationIgnored private var hiddenFeaturesObserver: NSObjectProtocol?
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
    var isMeasuring = false
    var measureStart: MeasureSnap? = nil
    var measureEnd: MeasureSnap? = nil
    var measureHoverSnap: MeasureSnap? = nil
    var loadSeconds: Double?
    /// Didactic visual construction state shown while layers are progressively built and revealed in the viewport.
    var constructionProgress: ViewConstructionProgress? = nil
    @ObservationIgnored private var constructionTimer: Timer?
    /// Mirrors the viewport, which ends free fly itself (Esc, lost focus): the status bar shows how to get out.
    private(set) var isFreeFlying = false
    /// Short transient toast shown in the viewport header (e.g. "Image copiée").
    var flashMessage: String? = nil
    /// Used by `Snapshot.render` so `cacheDisplay` composites the 3D Metal render below SwiftUI HUD overlays.
    var snapshotPreviewImage: NSImage? = nil
    /// Callback invoked when the camera state changes so `RemoteControlServer` can emit OSC feedback if enabled.
    @ObservationIgnored var onCameraFeedback: ((DocumentModel) -> Void)?

    // MARK: - Undo / Redo (100 levels)

    static let maxUndoLevels = 100
    private static let undoCoalesceWindow: TimeInterval = 0.85

    struct UndoSnapshot: Equatable {
        var selectedScene: Int?
        var activeStandardView: StandardView?
        var layerVisible: [Bool]
        var selectedLayerIndex: Int?
        var selectedLayerGroupID: String?
        var showsEdges: Bool
        var showsGrid: Bool
        var isPerspective: Bool
        var shadowsEnabled: Bool
        var ambientOcclusionEnabled: Bool
        var ambientOcclusionIntensity: Float
        var shadingStyle: ShadingStyle
        var backdropStyle: BackdropStyle
        var customBackdropColor: SIMD3<Float>
        var lightingMode: LightingMode
        var pointLights: [ViewportPointLight]
        var selectedPointLightIndex: Int
        var showsPointLightGizmo: Bool
        var sunAzimuthDegrees: Float
        var sunElevationDegrees: Float
        var sunIntensity: Float
        var ambientIntensity: Float
        var videoProjectors: [VideoProjector]
        var selectedVideoProjectorIndex: Int
        var isMeasuring: Bool
        var measureStart: MeasureSnap?
        var measureEnd: MeasureSnap?
        var cameraPose: CameraRig.Pose
        var cameraFOV: Float
        var cameraExposure: Float
        var cameraOrthoScale: Float
    }

    struct UndoEntry {
        var actionName: String
        var coalesceKey: String?
        var timestamp: TimeInterval
        var restoresCameraPose: Bool
        var before: UndoSnapshot
        var after: UndoSnapshot
    }

    private(set) var undoStack: [UndoEntry] = []
    private(set) var redoStack: [UndoEntry] = []
    @ObservationIgnored private var isRecordingOrApplyingUndo = false

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    var undoActionName: String? { undoStack.last?.actionName }
    var redoActionName: String? { redoStack.last?.actionName }

    var undoMenuTitle: String {
        if let name = undoActionName, !name.isEmpty {
            return L("Annuler \(name)", "Undo \(name)")
        }
        return L("Annuler", "Undo")
    }

    var redoMenuTitle: String {
        if let name = redoActionName, !name.isEmpty {
            return L("Rétablir \(name)", "Redo \(name)")
        }
        return L("Rétablir", "Redo")
    }

    func clearUndoHistory() {
        undoStack.removeAll()
        redoStack.removeAll()
    }

    private func captureUndoSnapshot() -> UndoSnapshot {
        let pose = isReady ? viewport.targetCameraPose : CameraRig.Pose(
            position: cameraPosition,
            yaw: cameraYaw,
            pitch: cameraPitch,
            distance: cameraDistance
        )
        let ortho = isReady ? viewport.targetOrthographicScale : cameraOrthoScale
        let fov = isReady ? viewport.fieldOfView : cameraFOV
        let exp = isReady ? viewport.exposureOffset : cameraExposure
        return UndoSnapshot(
            selectedScene: selectedScene,
            activeStandardView: activeStandardView,
            layerVisible: layerVisible,
            selectedLayerIndex: selectedLayerIndex,
            selectedLayerGroupID: selectedLayerGroupID,
            showsEdges: showsEdges,
            showsGrid: showsGrid,
            isPerspective: isPerspective,
            shadowsEnabled: shadowsEnabled,
            ambientOcclusionEnabled: ambientOcclusionEnabled,
            ambientOcclusionIntensity: ambientOcclusionIntensity,
            shadingStyle: shadingStyle,
            backdropStyle: backdropStyle,
            customBackdropColor: customBackdropColor,
            lightingMode: lightingMode,
            pointLights: pointLights,
            selectedPointLightIndex: selectedPointLightIndex,
            showsPointLightGizmo: showsPointLightGizmo,
            sunAzimuthDegrees: sunAzimuthDegrees,
            sunElevationDegrees: sunElevationDegrees,
            sunIntensity: sunIntensity,
            ambientIntensity: ambientIntensity,
            videoProjectors: videoProjectors,
            selectedVideoProjectorIndex: selectedVideoProjectorIndex,
            isMeasuring: isMeasuring,
            measureStart: measureStart,
            measureEnd: measureEnd,
            cameraPose: pose,
            cameraFOV: fov,
            cameraExposure: exp,
            cameraOrthoScale: ortho
        )
    }

    func recordUndoable(
        _ actionName: String,
        coalesceKey: String? = nil,
        restoresCameraPose: Bool = false,
        _ body: () -> Void
    ) {
        guard !isRecordingOrApplyingUndo else {
            body()
            return
        }
        let before = captureUndoSnapshot()
        isRecordingOrApplyingUndo = true
        body()
        isRecordingOrApplyingUndo = false
        let after = captureUndoSnapshot()
        guard before != after else { return }

        let now = ProcessInfo.processInfo.systemUptime
        if let key = coalesceKey,
           redoStack.isEmpty,
           let last = undoStack.last,
           last.coalesceKey == key,
           now - last.timestamp <= Self.undoCoalesceWindow {
            undoStack[undoStack.count - 1].after = after
            undoStack[undoStack.count - 1].timestamp = now
            undoStack[undoStack.count - 1].actionName = actionName
            return
        }

        let entry = UndoEntry(
            actionName: actionName,
            coalesceKey: coalesceKey,
            timestamp: now,
            restoresCameraPose: restoresCameraPose,
            before: before,
            after: after
        )
        undoStack.append(entry)
        if undoStack.count > Self.maxUndoLevels {
            undoStack.removeFirst(undoStack.count - Self.maxUndoLevels)
        }
        redoStack.removeAll()
    }

    private func applyUndoSnapshot(_ snapshot: UndoSnapshot, restoresCameraPose: Bool) {
        let wasRecording = isRecordingOrApplyingUndo
        isRecordingOrApplyingUndo = true
        defer { isRecordingOrApplyingUndo = wasRecording }

        selectedScene = snapshot.selectedScene
        activeStandardView = snapshot.activeStandardView

        if layerVisible != snapshot.layerVisible {
            layerVisible = snapshot.layerVisible
            scene?.setLayers(layerVisible)
            updateVisibleSize()
        }
        selectedLayerIndex = snapshot.selectedLayerIndex
        selectedLayerGroupID = snapshot.selectedLayerGroupID

        showsEdges = snapshot.showsEdges
        Preferences.showsEdges = showsEdges
        showsGrid = snapshot.showsGrid
        Preferences.showsGrid = showsGrid
        shadowsEnabled = snapshot.shadowsEnabled
        Preferences.shadowsEnabled = shadowsEnabled
        ambientOcclusionEnabled = snapshot.ambientOcclusionEnabled
        Preferences.ambientOcclusionEnabled = ambientOcclusionEnabled
        ambientOcclusionIntensity = snapshot.ambientOcclusionIntensity
        Preferences.ambientOcclusionIntensity = ambientOcclusionIntensity
        shadingStyle = snapshot.shadingStyle
        backdropStyle = snapshot.backdropStyle
        Preferences.backdropStyle = backdropStyle
        customBackdropColor = snapshot.customBackdropColor
        Preferences.customBackdropColor = customBackdropColor

        lightingMode = snapshot.lightingMode
        pointLights = snapshot.pointLights
        selectedPointLightIndex = snapshot.selectedPointLightIndex
        showsPointLightGizmo = snapshot.showsPointLightGizmo
        sunAzimuthDegrees = snapshot.sunAzimuthDegrees
        sunElevationDegrees = snapshot.sunElevationDegrees
        sunIntensity = snapshot.sunIntensity
        ambientIntensity = snapshot.ambientIntensity

        if let scene {
            scene.showsEdges = showsEdges
            scene.showsGrid = showsGrid
            scene.shadowsEnabled = shadowsEnabled
            scene.shadingStyle = shadingStyle
            scene.customBackdropColor = customBackdropColor
            scene.backdropStyle = backdropStyle
            scene.sunAzimuthDegrees = sunAzimuthDegrees
            scene.sunElevationDegrees = sunElevationDegrees
            scene.sunIntensity = sunIntensity
            scene.ambientIntensity = ambientIntensity
            scene.showsPointLightGizmo = showsPointLightGizmo
            scene.pointLights = pointLights
            scene.lightingMode = lightingMode
        }

        viewport.ambientOcclusionIntensity = CGFloat(ambientOcclusionIntensity)
        viewport.ambientOcclusionEnabled = ambientOcclusionEnabled

        videoProjectors = snapshot.videoProjectors
        selectedVideoProjectorIndex = snapshot.selectedVideoProjectorIndex
        if videoProjectors.isEmpty {
            cancelProjectorPick()
        }
        syncProjectorsToScene()

        measureStart = snapshot.measureStart
        measureEnd = snapshot.measureEnd
        if isMeasuring != snapshot.isMeasuring {
            isMeasuring = snapshot.isMeasuring
            viewport.isMeasuring = snapshot.isMeasuring
        }
        syncMeasurementToScene()

        if restoresCameraPose {
            isPerspective = snapshot.isPerspective
            Preferences.isPerspective = snapshot.isPerspective
            cameraFOV = snapshot.cameraFOV
            cameraExposure = snapshot.cameraExposure
            cameraOrthoScale = snapshot.cameraOrthoScale
            cameraPosition = snapshot.cameraPose.position
            cameraYaw = snapshot.cameraPose.yaw
            cameraPitch = snapshot.cameraPose.pitch
            cameraDistance = snapshot.cameraPose.distance
            if isReady {
                viewport.restoreCameraState(
                    pose: snapshot.cameraPose,
                    isPerspective: snapshot.isPerspective,
                    fovDegrees: snapshot.cameraFOV,
                    orthographicScale: snapshot.cameraOrthoScale,
                    exposureOffset: snapshot.cameraExposure,
                    animated: true
                )
                syncCameraStateFromViewport()
            }
        }

        viewport.requestRedraw()
    }

    func undo() {
        guard let entry = undoStack.popLast() else { return }
        applyUndoSnapshot(entry.before, restoresCameraPose: entry.restoresCameraPose)
        redoStack.append(entry)
        if redoStack.count > Self.maxUndoLevels {
            redoStack.removeFirst(redoStack.count - Self.maxUndoLevels)
        }
        flash(L("Annuler : \(entry.actionName)", "Undo: \(entry.actionName)"))
    }

    func redo() {
        guard let entry = redoStack.popLast() else { return }
        applyUndoSnapshot(entry.after, restoresCameraPose: entry.restoresCameraPose)
        undoStack.append(entry)
        if undoStack.count > Self.maxUndoLevels {
            undoStack.removeFirst(undoStack.count - Self.maxUndoLevels)
        }
        flash(L("Rétablir : \(entry.actionName)", "Redo: \(entry.actionName)"))
    }

    init() {
        hiddenFeaturesObserver = NotificationCenter.default.addObserver(
            forName: .hiddenFeaturesChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.hiddenFeaturesEnabled = Preferences.hiddenFeatures
            }
        }
        viewport.onFreeFlyingChange = { [weak self] in
            guard let self else { return }
            self.isFreeFlying = $0
            if $0, self.isMeasuring { self.setMeasureTool(false) }
            if $0, self.projectorPickMode != .none { self.cancelProjectorPick() }
        }
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
        viewport.onHideSelectedLayer = { [weak self] in
            self?.hideSelectedLayer()
        }
        viewport.onMeasureHover = { [weak self] snap, shift in
            self?.handleMeasureHover(snap, shiftLocked: shift)
        }
        viewport.onMeasureClick = { [weak self] snap, shift in
            self?.handleMeasureClick(snap, shiftLocked: shift)
        }
        viewport.onMeasureEscape = { [weak self] in
            self?.handleMeasureEscape()
        }
        viewport.onPickProjectorPoint = { [weak self] snap in
            self?.handleProjectorPointPick(snap)
        }
        viewport.onCancelProjectorPick = { [weak self] in
            self?.cancelProjectorPick()
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
        clearUndoHistory()
    }

    /// Main thread, once the scene is built off-main.
    func present(_ scene: ViewportScene, seconds: Double, progressiveConstruction: Bool = false) {
        cancelProgressiveConstruction()
        let wasRecording = isRecordingOrApplyingUndo
        isRecordingOrApplyingUndo = true
        defer {
            isRecordingOrApplyingUndo = wasRecording
            clearUndoHistory()
        }
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

        if let project = pendingSSKPProject {
            pendingSSKPProject = nil
            scene.finishDeferredLayerBuild()
            applySSKPProject(project)
            return
        }

        if !videoProjectors.isEmpty {
            scene.selectedVideoProjectorIndex = selectedVideoProjectorIndex
            scene.videoProjectors = videoProjectors
        }

        if progressiveConstruction {
            startProgressiveConstruction(for: scene)
        }
    }

    private func startProgressiveConstruction(for scene: ViewportScene) {
        let primaryLayers = scene.orderedVisiblePrimaryLayers
        guard primaryLayers.count > 1 else {
            scene.finishDeferredLayerBuild()
            updateVisibleSize()
            viewport.requestRedraw()
            return
        }
        let targetSteps = min(max(primaryLayers.count, 4), 18)
        let batchSize = max(1, (primaryLayers.count + targetSteps - 1) / targetSteps)
        var batches: [[Int]] = []
        var idx = 0
        while idx < primaryLayers.count {
            let end = min(idx + batchSize, primaryLayers.count)
            batches.append(Array(primaryLayers[idx..<end]))
            idx = end
        }
        var currentBatchIndex = 0
        let totalLayers = primaryLayers.count
        var completedLayers = 0

        func stepBatch() {
            guard self.scene === scene, currentBatchIndex < batches.count else {
                finishProgressiveConstruction()
                return
            }
            let batch = batches[currentBatchIndex]
            currentBatchIndex += 1
            completedLayers += batch.count
            let built = scene.buildVisibleSets(forPrimaryLayers: Set(batch))
            let repLayer = batch.last ?? 0
            let layerName = scene.model.layers.indices.contains(repLayer) ? scene.model.layers[repLayer].name : "Layer0"
            if hoveredLayerIndex == nil, scene.activePulseLayers.isEmpty {
                scene.setHoveredLayers([repLayer])
            }
            constructionProgress = ViewConstructionProgress(
                currentLayerIndex: repLayer,
                currentLayerName: layerName,
                completedLayers: completedLayers,
                totalLayers: totalLayers,
                edgesBuilt: built.edgesBuilt,
                facesBuilt: built.facesBuilt,
                fraction: Double(completedLayers) / Double(max(1, totalLayers))
            )
            viewport.requestRedraw()
        }

        // Build first batch immediately so the view is never completely empty on frame 1
        stepBatch()
        let timer = Timer(timeInterval: 0.028, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard self != nil else { return }
                stepBatch()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        constructionTimer = timer
    }

    func finishProgressiveConstruction() {
        cancelProgressiveConstruction()
        guard let scene else { return }
        scene.finishDeferredLayerBuild()
        if hoveredLayerIndex == nil {
            scene.setHoveredLayers([])
        }
        updateVisibleSize()
        viewport.requestRedraw()
    }

    func cancelProgressiveConstruction() {
        constructionTimer?.invalidate()
        constructionTimer = nil
        constructionProgress = nil
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
        recordUndoable(L("Scène", "Scene"), restoresCameraPose: true) {
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
        recordUndoable(L("Visibilité du calque", "Layer Visibility")) {
            layerVisible[index].toggle()
            scene?.setLayer(index, visible: layerVisible[index])
            updateVisibleSize()
            viewport.requestRedraw()
        }
    }

    /// Updates the subtle hover highlight in the viewport and sidebar when the mouse moves over geometry (AutoCAD mode only).
    func setHoveredLayer(_ index: Int?) {
        let validIndex: Int?
        if isCAD, let index, let skp, skp.layers.indices.contains(index) {
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

    /// Clicking an object directly in the viewport (AutoCAD mode only): reveals and expands its group in the hierarchy, scrolls to it, and selects + pulses it.
    func selectLayerFromViewport(_ index: Int) {
        guard isCAD, let skp, skp.layers.indices.contains(index) else { return }
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

    /// Pressing `H` in AutoCAD mode hides the currently selected object/layer (or selected layer group, or hovered layer if none is selected).
    func hideSelectedLayer() {
        guard isCAD, let skp else { return }
        recordUndoable(L("Masquer le calque", "Hide Layer")) {
            if let idx = selectedLayerIndex, layerVisible.indices.contains(idx), layerVisible[idx] {
                layerVisible[idx] = false
                scene?.setLayer(idx, visible: false)
                if hoveredLayerIndex == idx {
                    setHoveredLayer(nil)
                }
                updateVisibleSize()
                viewport.requestRedraw()
                flash(L("Calque « \(skp.layers[idx].name) » masqué (H)", "Layer “\(skp.layers[idx].name)” hidden (H)"))
                return
            }
            if let groupID = selectedLayerGroupID,
               let group = skp.layerGroups.first(where: { $0.id == groupID }),
               isLayerGroupVisible(group) {
                setLayerGroup(group, visible: false)
                if let hoverIdx = hoveredLayerIndex, group.layerIndices.contains(hoverIdx) {
                    setHoveredLayer(nil)
                }
                flash(L("Groupe « \(group.name) » masqué (H)", "Group “\(group.name)” hidden (H)"))
                return
            }
            if let hoverIdx = hoveredLayerIndex, layerVisible.indices.contains(hoverIdx), layerVisible[hoverIdx] {
                selectedLayerIndex = hoverIdx
                selectedLayerGroupID = nil
                layerVisible[hoverIdx] = false
                scene?.setLayer(hoverIdx, visible: false)
                setHoveredLayer(nil)
                updateVisibleSize()
                viewport.requestRedraw()
                flash(L("Calque « \(skp.layers[hoverIdx].name) » masqué (H)", "Layer “\(skp.layers[hoverIdx].name)” hidden (H)"))
            }
        }
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
        recordUndoable(L("Zoom sur le calque", "Zoom to Layer"), restoresCameraPose: true) {
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
    }

    /// Double-clicking a layer group name in the sidebar: ensures its layers are visible, pulses them, and smoothly glides the camera to frame the group.
    func zoomToLayerGroup(_ group: SKPModel.LayerGroup, animated: Bool = true) {
        recordUndoable(L("Zoom sur le groupe", "Zoom to Group"), restoresCameraPose: true) {
            if !isLayerGroupVisible(group) {
                setLayerGroup(group, visible: true)
            }
            selectLayerGroup(group)
            guard let bounds = scene?.bounds(forLayers: Set(group.layerIndices)) else { return }
            activeStandardView = nil
            viewport.frameBounds(min: bounds.min, max: bounds.max, animated: animated)
            syncCameraStateFromViewport()
        }
    }

    func setAllLayers(visible: Bool) {
        guard !layerVisible.isEmpty else { return }
        let title = visible ? L("Afficher tous les calques", "Show All Layers") : L("Masquer tous les calques", "Hide All Layers")
        recordUndoable(title) {
            layerVisible = Array(repeating: visible, count: layerVisible.count)
            scene?.setLayers(layerVisible)
            updateVisibleSize()
            viewport.requestRedraw()
        }
    }

    /// Isolates a single layer (`Solo`), or restores all layers if it was already the only visible one.
    func soloLayer(_ index: Int) {
        guard layerVisible.indices.contains(index) else { return }
        recordUndoable(L("Isoler le calque", "Solo Layer")) {
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
        recordUndoable(L("Visibilité du groupe", "Group Visibility")) {
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
    }

    func toggleLayerGroup(_ group: SKPModel.LayerGroup) {
        setLayerGroup(group, visible: !isLayerGroupVisible(group))
    }

    /// Isolates all layers of a `LayerGroup` (`Solo`), or restores all layers if that group was already the only visible one.
    func soloLayerGroup(_ group: SKPModel.LayerGroup) {
        let memberSet = Set(group.layerIndices)
        guard !memberSet.isEmpty else { return }
        recordUndoable(L("Isoler le groupe", "Solo Group")) {
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
        recordUndoable(L("Réinitialiser la vue", "Reset View"), restoresCameraPose: true) {
            activeStandardView = nil
            viewport.resetView(animated: true)
            isPerspective = viewport.isPerspective
        }
    }

    func zoomExtents() {
        guard isReady else { return }
        recordUndoable(L("Zoom étendu", "Zoom Extents"), restoresCameraPose: true) {
            viewport.zoomExtents(animated: true)
        }
    }

    func zoomIn() {
        if isReady { viewport.zoomStep(ratio: 1 / 1.28) }
    }

    func zoomOut() {
        if isReady { viewport.zoomStep(ratio: 1.28) }
    }

    func look(_ view: StandardView) {
        guard isReady else { return }
        recordUndoable(L("Vue standard", "Standard View"), restoresCameraPose: true) {
            activeStandardView = view
            viewport.look(view, animated: true)
        }
    }

    func togglePerspective() {
        setPerspective(!isPerspective)
    }

    func setPerspective(_ enabled: Bool) {
        guard isPerspective != enabled || (isReady && viewport.isPerspective != enabled) else { return }
        recordUndoable(L("Projection", "Projection"), restoresCameraPose: true) {
            isPerspective = enabled
            Preferences.isPerspective = enabled
            if isReady {
                viewport.isPerspective = enabled
                syncCameraStateFromViewport()
            }
        }
    }

    func setCameraFOV(_ degrees: Float) {
        let clamped = max(10.0, min(120.0, degrees))
        recordUndoable(L("Focale caméra", "Camera FOV"), coalesceKey: "camera-fov", restoresCameraPose: true) {
            cameraFOV = clamped
            viewport.fieldOfView = clamped
        }
    }

    func setCameraFocalLength(_ mm: Float) {
        let fov = ViewportView.verticalFOVDegrees(forFocalLengthMM: mm)
        setCameraFOV(fov)
    }

    func setCameraExposure(_ ev: Float) {
        let clamped = max(-3.0, min(3.0, ev))
        recordUndoable(L("Exposition caméra", "Camera Exposure"), coalesceKey: "camera-exposure", restoresCameraPose: true) {
            cameraExposure = clamped
            viewport.exposureOffset = clamped
        }
    }

    func setCameraOrthoScale(_ scale: Float) {
        let clamped = max(0.05, min(10_000.0, scale))
        recordUndoable(L("Échelle orthographique", "Orthographic Scale"), coalesceKey: "camera-ortho", restoresCameraPose: true) {
            cameraOrthoScale = clamped
            viewport.orthographicScale = clamped
        }
    }

    func setCameraSpeedScale(_ scale: Float) {
        let clamped = max(1.0 / 16.0, min(16.0, scale))
        cameraSpeedScale = clamped
        viewport.movementSpeedScale = clamped
    }

    func setCameraPosition(_ position: SIMD3<Float>) {
        recordUndoable(L("Position caméra", "Camera Position"), coalesceKey: "camera-pos", restoresCameraPose: true) {
            activeStandardView = nil
            viewport.setCameraPose(position: position)
            syncCameraStateFromViewport()
        }
    }

    func setCameraOrientation(yawDegrees: Float? = nil, pitchDegrees: Float? = nil) {
        recordUndoable(L("Orientation caméra", "Camera Orientation"), coalesceKey: "camera-orient", restoresCameraPose: true) {
            activeStandardView = nil
            viewport.setCameraPose(yawDegrees: yawDegrees, pitchDegrees: pitchDegrees)
            syncCameraStateFromViewport()
        }
    }

    func setCameraDistance(_ distance: Float) {
        recordUndoable(L("Distance cible caméra", "Camera Target Distance"), coalesceKey: "camera-dist", restoresCameraPose: true) {
            viewport.setCameraPose(distance: max(0.05, distance))
            syncCameraStateFromViewport()
        }
    }

    func setCameraTarget(_ target: SIMD3<Float>, animated: Bool = false) {
        recordUndoable(L("Cible caméra", "Camera Target"), coalesceKey: "camera-target", restoresCameraPose: true) {
            activeStandardView = nil
            viewport.setCameraTarget(target, animated: animated)
            syncCameraStateFromViewport()
        }
    }

    func setCameraLookAt(position: SIMD3<Float>, target: SIMD3<Float>, animated: Bool = false) {
        recordUndoable(L("Cadrage caméra", "Camera Framing"), restoresCameraPose: true) {
            activeStandardView = nil
            viewport.setCameraLookAt(position: position, target: target, animated: animated)
            syncCameraStateFromViewport()
        }
    }

    func orbitCameraByDegrees(yaw dYawDegrees: Float, pitch dPitchDegrees: Float) {
        recordUndoable(L("Rotation caméra", "Camera Orbit"), coalesceKey: "camera-orbit", restoresCameraPose: true) {
            activeStandardView = nil
            viewport.orbitByDegrees(yaw: dYawDegrees, pitch: dPitchDegrees)
            syncCameraStateFromViewport()
        }
    }

    func levelCameraHorizon(animated: Bool = true) {
        recordUndoable(L("Horizon à niveau", "Level Horizon"), restoresCameraPose: true) {
            activeStandardView = nil
            viewport.levelHorizon(animated: animated)
            syncCameraStateFromViewport()
        }
    }

    /// Places the camera at human eye height (`1.70 m` above the model floor or Z=0) and levels the horizon.
    func setCameraEyeHeight(_ heightAboveFloor: Float = 1.70) {
        recordUndoable(L("Hauteur d'œil", "Eye Height"), restoresCameraPose: true) {
            activeStandardView = nil
            let bMinZ = scene?.visibleBounds.min.z ?? skp?.boundsMin.z ?? 0
            let bMaxZ = scene?.visibleBounds.max.z ?? skp?.boundsMax.z ?? 3
            let floorZ = (bMinZ <= 0.2 && bMaxZ >= 1.5) ? 0.0 : bMinZ
            var pos = viewport.cameraModelPosition
            pos.z = floorZ + heightAboveFloor
            viewport.setCameraPose(position: pos, pitchDegrees: 0)
            syncCameraStateFromViewport()
        }
    }

    /// Places the camera at the geometric center of the model and levels the horizon.
    func centerCameraInModel() {
        recordUndoable(L("Centrer la caméra", "Center Camera"), restoresCameraPose: true) {
            activeStandardView = nil
            let center = scene?.defaultPointLightPosition ?? skp?.center ?? .zero
            viewport.setCameraPose(position: center, pitchDegrees: 0)
            syncCameraStateFromViewport()
        }
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
        recordUndoable(L("Style de rendu", "Shading Style")) {
            shadingStyle = style
            scene?.shadingStyle = style
            if style == .wireframe, !showsEdges {
                showsEdges = true
            }
            viewport.requestRedraw()
        }
    }

    func setBackdropStyle(_ style: BackdropStyle) {
        recordUndoable(L("Fond de scène", "Backdrop Style")) {
            backdropStyle = style
            Preferences.backdropStyle = style
            scene?.backdropStyle = style
            viewport.requestRedraw()
        }
    }

    func setCustomBackdropColor(_ color: SIMD3<Float>) {
        recordUndoable(L("Couleur de fond", "Backdrop Color"), coalesceKey: "backdrop-color") {
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
    }

    func toggleGrid() {
        recordUndoable(L("Grille et axes", "Grid and Axes")) {
            showsGrid.toggle()
            Preferences.showsGrid = showsGrid
            scene?.showsGrid = showsGrid
            viewport.requestRedraw()
        }
    }

    func toggleShadows() {
        recordUndoable(L("Ombres", "Shadows")) {
            shadowsEnabled.toggle()
            Preferences.shadowsEnabled = shadowsEnabled
            scene?.shadowsEnabled = shadowsEnabled
            viewport.requestRedraw()
        }
    }

    func toggleAmbientOcclusion() {
        recordUndoable(L("Occlusion ambiante", "Ambient Occlusion")) {
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
    }

    func setAmbientOcclusionIntensity(_ value: Float) {
        recordUndoable(L("Intensité AO", "AO Intensity"), coalesceKey: "ao-intensity") {
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
    }

    func setLightingMode(_ mode: LightingMode) {
        recordUndoable(L("Mode d'éclairage", "Lighting Mode")) {
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
    }

    func addPointLight() {
        recordUndoable(L("Ajout lumière", "Add Light")) {
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
    }

    func removeSelectedPointLight() {
        guard pointLights.indices.contains(selectedPointLightIndex), pointLights.count > 1 else { return }
        recordUndoable(L("Suppression lumière", "Remove Light")) {
            pointLights.remove(at: selectedPointLightIndex)
            selectedPointLightIndex = max(0, min(selectedPointLightIndex, pointLights.count - 1))
            scene?.pointLights = pointLights
            viewport.requestRedraw()
        }
    }

    func centerSelectedPointLight() {
        guard pointLights.indices.contains(selectedPointLightIndex) else { return }
        recordUndoable(L("Centrer la lumière", "Center Light")) {
            let center = scene?.defaultPointLightPosition ?? skp?.center ?? .zero
            pointLights[selectedPointLightIndex].position = center
            scene?.pointLights = pointLights
            viewport.requestRedraw()
        }
    }

    func moveSelectedPointLightToCamera() {
        guard pointLights.indices.contains(selectedPointLightIndex), isReady else { return }
        recordUndoable(L("Lumière sur la caméra", "Move Light to Camera")) {
            pointLights[selectedPointLightIndex].position = viewport.cameraModelPosition
            scene?.pointLights = pointLights
            viewport.requestRedraw()
        }
    }

    func updateSelectedPointLight(position: SIMD3<Float>? = nil, intensity: Float? = nil) {
        guard pointLights.indices.contains(selectedPointLightIndex) else { return }
        recordUndoable(L("Réglage lumière", "Adjust Light"), coalesceKey: "point-light-\(selectedPointLightIndex)") {
            if let position { pointLights[selectedPointLightIndex].position = position }
            if let intensity { pointLights[selectedPointLightIndex].intensity = max(0.0, min(3.0, intensity)) }
            scene?.pointLights = pointLights
            viewport.requestRedraw()
        }
    }

    func togglePointLightGizmo() {
        recordUndoable(L("Repère de lumière", "Light Gizmo")) {
            showsPointLightGizmo.toggle()
            scene?.showsPointLightGizmo = showsPointLightGizmo
            viewport.requestRedraw()
        }
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
        recordUndoable(L("Orientation du soleil", "Sun Orientation"), coalesceKey: "sun-orient") {
            sunAzimuthDegrees = azimuth
            sunElevationDegrees = elevation
            scene?.sunAzimuthDegrees = azimuth
            scene?.sunElevationDegrees = elevation
            viewport.requestRedraw()
        }
    }

    func setSunIntensity(_ intensity: Float) {
        recordUndoable(L("Intensité du soleil", "Sun Intensity"), coalesceKey: "sun-intensity") {
            let clamped = max(0.0, min(3.0, intensity))
            sunIntensity = clamped
            scene?.sunIntensity = clamped
            viewport.requestRedraw()
        }
    }

    func setAmbientIntensity(_ intensity: Float) {
        recordUndoable(L("Lumière ambiante", "Ambient Light"), coalesceKey: "ambient-intensity") {
            let clamped = max(0.0, min(2.0, intensity))
            ambientIntensity = clamped
            scene?.ambientIntensity = clamped
            viewport.requestRedraw()
        }
    }

    func resetSun() {
        recordUndoable(L("Réinitialiser l'éclairage", "Reset Lighting")) {
            sunAzimuthDegrees = -135
            sunElevationDegrees = 45
            sunIntensity = Rendering.defaultSunIntensity
            ambientIntensity = Rendering.defaultAmbientIntensity
            scene?.resetSun()
            scene?.ambientIntensity = ambientIntensity
            viewport.requestRedraw()
        }
    }

    func toggleFreeFlight() {
        if isReady { viewport.isFreeFlying.toggle() }
    }

    // MARK: Measurement Tool (⌘D)

    func toggleMeasureTool() {
        guard isReady else { return }
        setMeasureTool(!isMeasuring)
    }

    func setMeasureTool(_ enabled: Bool) {
        guard isMeasuring != enabled else { return }
        if enabled, isFreeFlying {
            viewport.isFreeFlying = false
        }
        isMeasuring = enabled
        viewport.isMeasuring = enabled
        if !enabled {
            measureStart = nil
            measureEnd = nil
            measureHoverSnap = nil
            viewport.measureFallbackZ = nil
        }
        syncMeasurementToScene()
    }

    func clearMeasurement() {
        recordUndoable(L("Effacer la mesure", "Clear Measurement")) {
            measureStart = nil
            measureEnd = nil
            viewport.measureFallbackZ = nil
            syncMeasurementToScene()
        }
    }

    func handleMeasureEscape() {
        if measureStart != nil || measureEnd != nil {
            clearMeasurement()
        } else {
            setMeasureTool(false)
        }
    }

    private func resolvedMeasureSnap(_ snap: MeasureSnap, shiftLocked: Bool) -> MeasureSnap {
        guard shiftLocked, let start = measureStart, measureEnd == nil,
              snap.kind != .vertex, snap.kind != .midpoint else {
            return snap
        }
        let d = snap.position - start.position
        let ax = abs(d.x), ay = abs(d.y), az = abs(d.z)
        var locked = start.position
        if ax >= ay && ax >= az {
            locked.x = snap.position.x
        } else if ay >= ax && ay >= az {
            locked.y = snap.position.y
        } else {
            locked.z = snap.position.z
        }
        return MeasureSnap(position: locked, kind: snap.kind, segmentStart: nil, segmentEnd: nil, layerIndex: snap.layerIndex)
    }

    func handleMeasureHover(_ snap: MeasureSnap?, shiftLocked: Bool) {
        guard isMeasuring || projectorPickMode != .none else { return }
        if let snap {
            measureHoverSnap = isMeasuring ? resolvedMeasureSnap(snap, shiftLocked: shiftLocked) : snap
        } else {
            measureHoverSnap = nil
        }
        syncMeasurementToScene()
    }

    func handleMeasureClick(_ snap: MeasureSnap, shiftLocked: Bool) {
        guard isMeasuring else { return }
        recordUndoable(L("Mesure", "Measurement")) {
            let resolved = resolvedMeasureSnap(snap, shiftLocked: shiftLocked)
            if measureStart == nil || measureEnd != nil {
                measureStart = resolved
                measureEnd = nil
                viewport.measureFallbackZ = resolved.position.z
            } else {
                measureEnd = resolved
            }
            measureHoverSnap = resolved
            syncMeasurementToScene()
        }
    }

    private func syncMeasurementToScene() {
        guard let scene else { return }
        viewport.refreshMeasurementCamera()
        let endSnap = isMeasuring ? activeMeasureEnd : nil
        let distText: String?
        if isMeasuring, let start = measureStart, let end = endSnap {
            let d = simd_distance(start.position, end.position)
            distText = d > 1e-5 ? Self.formatDistance(d, compact: true) : nil
        } else {
            distText = nil
        }
        let hoverBadgeText: String?
        if let hover = measureHoverSnap {
            if projectorPickMode == .position {
                hoverBadgeText = L("Position VP", "VP Position") + " · " + Self.snapKindLabel(hover.kind)
            } else if projectorPickMode == .target {
                hoverBadgeText = L("Cible VP", "VP Target") + " · " + Self.snapKindLabel(hover.kind)
            } else {
                hoverBadgeText = Self.snapKindLabel(hover.kind)
            }
        } else {
            hoverBadgeText = nil
        }
        scene.updateMeasurement(
            isActive: isMeasuring || projectorPickMode != .none,
            start: isMeasuring ? measureStart : nil,
            end: endSnap,
            hover: measureHoverSnap,
            distanceText: distText,
            hoverBadgeText: hoverBadgeText
        )
        viewport.setNeedsDisplay(viewport.bounds)
    }

    // MARK: - Video Projectors & .sskp Project

    /// Whether the hidden features UI (video projectors + `.sskp` save) is unlocked.
    var showsHiddenFeaturesUI: Bool {
        hiddenFeaturesEnabled || !videoProjectors.isEmpty || sskpURL != nil
    }

    var selectedVideoProjector: VideoProjector? {
        guard videoProjectors.indices.contains(selectedVideoProjectorIndex) else { return nil }
        return videoProjectors[selectedVideoProjectorIndex]
    }

    func selectVideoProjector(_ index: Int) {
        guard videoProjectors.indices.contains(index) else { return }
        selectedVideoProjectorIndex = index
        scene?.selectedVideoProjectorIndex = index
        viewport.requestRedraw()
    }

    func addVideoProjector(spec: ProjectorSpec = .optomaZU920ST) {
        recordUndoable(L("Ajout vidéoprojecteur", "Add Video Projector")) {
            let count = videoProjectors.count + 1
            let camPos = viewport.cameraModelPosition
            let camTarget = viewport.cameraPose.target
            let offsetRight = viewport.cameraPose.right * (Float(videoProjectors.count) * 0.65)
            let pos: SIMD3<Float>
            let tgt: SIMD3<Float>
            if isReady, simd_distance(camPos, camTarget) > 0.3 {
                // Place at 65% of the way from camera to target (or at least 3.5 m from target) so the projector is immediately visible in front of the camera
                let toCamera = camPos - camTarget
                let d = simd_length(toCamera)
                let dir = toCamera / max(d, 1e-4)
                let throwDist = min(max(d * 0.55, 2.5), max(d * 0.85, 4.0))
                pos = camTarget + dir * throwDist + offsetRight
                tgt = camTarget + offsetRight * 0.3
            } else {
                let center = scene?.defaultPointLightPosition ?? skp?.center ?? .zero
                pos = center + SIMD3<Float>(0, -5.0, 2.5)
                tgt = center
            }

            let proj = VideoProjector(
                name: "VP \(count) — \(spec.model)",
                specID: spec.id,
                isEnabled: true,
                position: pos,
                target: tgt,
                rollDegrees: 0,
                throwRatio: spec.defaultThrowRatio,
                lensShiftH: 0,
                lensShiftV: 0,
                intensity: 1.0,
                pattern: .testGrid,
                showsFrustum: true
            )
            videoProjectors.append(proj)
            selectedVideoProjectorIndex = videoProjectors.count - 1
            syncProjectorsToScene()
        }
    }

    func duplicateSelectedVideoProjector() {
        guard var copy = selectedVideoProjector else { return }
        recordUndoable(L("Duplication vidéoprojecteur", "Duplicate Video Projector")) {
            copy.id = UUID()
            copy.name = "\(copy.name) (\(videoProjectors.count + 1))"
            let (right, _, _) = copy.opticalBasis()
            copy.position += right * 1.0
            copy.target += right * 1.0
            videoProjectors.append(copy)
            selectedVideoProjectorIndex = videoProjectors.count - 1
            syncProjectorsToScene()
        }
    }

    func removeSelectedVideoProjector() {
        guard videoProjectors.indices.contains(selectedVideoProjectorIndex) else { return }
        recordUndoable(L("Suppression vidéoprojecteur", "Remove Video Projector")) {
            videoProjectors.remove(at: selectedVideoProjectorIndex)
            selectedVideoProjectorIndex = max(0, min(selectedVideoProjectorIndex, videoProjectors.count - 1))
            if videoProjectors.isEmpty {
                cancelProjectorPick()
            }
            syncProjectorsToScene()
        }
    }

    func updateSelectedVideoProjector(_ mutate: (inout VideoProjector) -> Void) {
        guard videoProjectors.indices.contains(selectedVideoProjectorIndex) else { return }
        recordUndoable(L("Réglage vidéoprojecteur", "Adjust Video Projector"), coalesceKey: "vp-edit-\(selectedVideoProjectorIndex)") {
            mutate(&videoProjectors[selectedVideoProjectorIndex])
            syncProjectorsToScene()
        }
    }

    func moveSelectedProjectorToCamera() {
        guard videoProjectors.indices.contains(selectedVideoProjectorIndex), isReady else { return }
        recordUndoable(L("Placer VP sur la caméra", "Place VP at Camera")) {
            videoProjectors[selectedVideoProjectorIndex].position = viewport.cameraModelPosition
            videoProjectors[selectedVideoProjectorIndex].target = viewport.cameraPose.target
            syncProjectorsToScene()
        }
    }

    func aimSelectedProjectorAtCameraTarget() {
        guard videoProjectors.indices.contains(selectedVideoProjectorIndex), isReady else { return }
        recordUndoable(L("Viser la cible caméra", "Aim VP at Camera Target")) {
            videoProjectors[selectedVideoProjectorIndex].target = viewport.cameraPose.target
            syncProjectorsToScene()
        }
    }

    func lookThroughSelectedProjector() {
        guard let proj = selectedVideoProjector, isReady else { return }
        recordUndoable(L("Vue depuis le VP", "Look Through VP"), restoresCameraPose: true) {
            setCameraLookAt(position: proj.position, target: proj.target, animated: true)
        }
    }

    func startPickingProjectorPosition() {
        guard isReady, selectedVideoProjector != nil else { return }
        if isMeasuring { setMeasureTool(false) }
        projectorPickMode = (projectorPickMode == .position) ? .none : .position
        viewport.isPickingProjectorPoint = (projectorPickMode != .none)
        syncMeasurementToScene()
    }

    func startPickingProjectorTarget() {
        guard isReady, selectedVideoProjector != nil else { return }
        if isMeasuring { setMeasureTool(false) }
        projectorPickMode = (projectorPickMode == .target) ? .none : .target
        viewport.isPickingProjectorPoint = (projectorPickMode != .none)
        syncMeasurementToScene()
    }

    func cancelProjectorPick() {
        guard projectorPickMode != .none || viewport.isPickingProjectorPoint else { return }
        projectorPickMode = .none
        viewport.isPickingProjectorPoint = false
        measureHoverSnap = nil
        syncMeasurementToScene()
    }

    private func handleProjectorPointPick(_ snap: MeasureSnap) {
        guard videoProjectors.indices.contains(selectedVideoProjectorIndex) else {
            cancelProjectorPick()
            return
        }
        let mode = projectorPickMode
        cancelProjectorPick()
        switch mode {
        case .position:
            recordUndoable(L("Position du vidéoprojecteur", "Projector Position")) {
                videoProjectors[selectedVideoProjectorIndex].position = snap.position
                syncProjectorsToScene()
            }
            flash(L("Position du vidéoprojecteur placée", "Projector position placed"))
        case .target:
            recordUndoable(L("Cible du vidéoprojecteur", "Projector Target")) {
                videoProjectors[selectedVideoProjectorIndex].target = snap.position
                syncProjectorsToScene()
            }
            flash(L("Cible du vidéoprojecteur visée", "Projector target aimed"))
        case .none:
            break
        }
    }

    func chooseCustomImageForSelectedProjector() {
        guard videoProjectors.indices.contains(selectedVideoProjectorIndex) else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.image, .png, .jpeg, .tiff]
        panel.title = L("Choisir une image à projeter", "Choose an Image to Project")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        recordUndoable(L("Image du vidéoprojecteur", "Projector Image")) {
            videoProjectors[selectedVideoProjectorIndex].customImagePath = url.path
            videoProjectors[selectedVideoProjectorIndex].pattern = .customImage
            syncProjectorsToScene()
        }
    }

    func syncProjectorsToScene() {
        guard let scene else { return }
        scene.selectedVideoProjectorIndex = selectedVideoProjectorIndex
        scene.videoProjectors = videoProjectors
        viewport.requestRedraw()
    }

    /// URL of the underlying 3D geometry file (`.skp`, `.dwg`, `.dxf`, `.dae`, `.obj`).
    var underlyingModelURL: URL? {
        if let skpURL = skp?.fileInfo.url, skpURL.pathExtension.lowercased() != "sskp" {
            return skpURL
        }
        if let infoURL = info?.url, infoURL.pathExtension.lowercased() != "sskp" {
            return infoURL
        }
        return nil
    }

    func buildSSKPProject(relativeTo targetSSKPURL: URL? = nil) -> SSKPProject? {
        guard let modelURL = underlyingModelURL else { return nil }
        syncCameraStateFromViewport()
        let relPath = targetSSKPURL.flatMap { SSKPProject.relativePath(from: $0.deletingLastPathComponent(), to: modelURL) }
        let camState = SSKPProject.CameraState(
            position: cameraPosition,
            target: cameraTarget,
            fovDegrees: cameraFOV,
            isPerspective: isPerspective,
            orthoScale: cameraOrthoScale,
            exposureOffset: cameraExposure
        )
        let lightState = SSKPProject.LightingState(
            lightingMode: lightingMode == .point ? "point" : "sun",
            sunAzimuthDegrees: sunAzimuthDegrees,
            sunElevationDegrees: sunElevationDegrees,
            sunIntensity: sunIntensity,
            ambientIntensity: ambientIntensity,
            shadowsEnabled: shadowsEnabled,
            shadingStyle: shadingStyle.rawValue,
            backdropStyle: backdropStyle.rawValue,
            customBackdropColor: customBackdropColor,
            showsEdges: showsEdges,
            showsGrid: showsGrid,
            pointLights: pointLights.map {
                SSKPProject.PointLightState(
                    name: $0.name,
                    position: $0.position,
                    intensity: $0.intensity,
                    isFromScene: $0.isFromScene
                )
            }
        )
        var hiddenNames: [String] = []
        if let skp {
            for (idx, layer) in skp.layers.enumerated() where layerVisible.indices.contains(idx) && !layerVisible[idx] {
                hiddenNames.append(layer.name)
            }
        }
        return SSKPProject(
            modelPath: modelURL.path,
            modelRelativePath: relPath,
            projectors: videoProjectors,
            camera: camState,
            lighting: lightState,
            hiddenLayerNames: hiddenNames
        )
    }

    func applySSKPProject(_ project: SSKPProject) {
        if let hiddenNames = project.hiddenLayerNames, let skp {
            let hiddenSet = Set(hiddenNames)
            layerVisible = skp.layers.map { !hiddenSet.contains($0.name) }
            scene?.setLayers(layerVisible)
            updateVisibleSize()
        }
        if let lighting = project.lighting {
            showsEdges = lighting.showsEdges
            showsGrid = lighting.showsGrid
            shadowsEnabled = lighting.shadowsEnabled
            sunAzimuthDegrees = lighting.sunAzimuthDegrees
            sunElevationDegrees = lighting.sunElevationDegrees
            sunIntensity = lighting.sunIntensity
            ambientIntensity = lighting.ambientIntensity
            customBackdropColor = lighting.customBackdropColor
            if let style = ShadingStyle(rawValue: lighting.shadingStyle) {
                shadingStyle = style
            }
            if let bg = BackdropStyle(rawValue: lighting.backdropStyle) {
                backdropStyle = bg
            }
            if !lighting.pointLights.isEmpty {
                pointLights = lighting.pointLights.map {
                    ViewportPointLight(name: $0.name, position: $0.position, intensity: $0.intensity, isFromScene: $0.isFromScene)
                }
            }
            lightingMode = (lighting.lightingMode == "point") ? .point : .sun
            if let scene {
                scene.showsEdges = showsEdges
                scene.showsGrid = showsGrid
                scene.shadowsEnabled = shadowsEnabled
                scene.shadingStyle = shadingStyle
                scene.customBackdropColor = customBackdropColor
                scene.backdropStyle = backdropStyle
                scene.sunAzimuthDegrees = sunAzimuthDegrees
                scene.sunElevationDegrees = sunElevationDegrees
                scene.sunIntensity = sunIntensity
                scene.ambientIntensity = ambientIntensity
                scene.pointLights = pointLights
                scene.lightingMode = lightingMode
            }
        }
        if let cam = project.camera, isReady {
            setPerspective(cam.isPerspective)
            setCameraFOV(cam.fovDegrees)
            setCameraExposure(cam.exposureOffset)
            if !cam.isPerspective {
                setCameraOrthoScale(cam.orthoScale)
            }
            setCameraLookAt(position: cam.position, target: cam.target, animated: false)
        }
        videoProjectors = project.projectors
        selectedVideoProjectorIndex = 0
        syncProjectorsToScene()
    }

    func saveSSKPProject() {
        if let existingURL = sskpURL {
            writeSSKPProject(to: existingURL)
        } else {
            saveSSKPProjectAs()
        }
    }

    func saveSSKPProjectAs() {
        guard isReady, underlyingModelURL != nil else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [DocumentController.sskpContentType]
        panel.allowsOtherFileTypes = false
        let baseURL = sskpURL ?? underlyingModelURL ?? info?.url
        let baseName = baseURL?.deletingPathExtension().lastPathComponent ?? "Scene"
        if let dir = baseURL?.deletingLastPathComponent() {
            panel.directoryURL = dir
        }
        panel.nameFieldStringValue = "\(baseName).sskp"
        panel.title = L("Enregistrer le projet SimpleSKP (.sskp)", "Save SimpleSKP Project (.sskp)")
        guard panel.runModal() == .OK, var url = panel.url else { return }
        if url.pathExtension.lowercased() != "sskp" {
            url = url.appendingPathExtension("sskp")
        }
        writeSSKPProject(to: url)
    }

    @discardableResult
    func writeSSKPProject(to url: URL) -> Bool {
        guard let project = buildSSKPProject(relativeTo: url) else { return false }
        do {
            try project.write(to: url)
            sskpURL = url
            flash(L("Projet enregistré : \(url.lastPathComponent)", "Project saved: \(url.lastPathComponent)"))
            return true
        } catch {
            NSApp.presentError(error)
            return false
        }
    }

    var activeMeasureEnd: MeasureSnap? {
        measureEnd ?? measureHoverSnap
    }

    static func formatDistance(_ metres: Float, compact: Bool = false) -> String {
        let a = abs(metres)
        if a < 0.01 {
            return String(format: "%.1f mm", metres * 1000.0)
        } else if a < 1.0 {
            if compact {
                return String(format: "%.1f cm", metres * 100.0)
            }
            return String(format: "%.1f cm (%.0f mm)", metres * 100.0, metres * 1000.0)
        } else {
            return String(format: compact ? "%.2f m" : "%.3f m", metres)
        }
    }

    static func snapKindLabel(_ kind: MeasureSnap.Kind) -> String {
        switch kind {
        case .vertex: return L("Point", "Endpoint")
        case .midpoint: return L("Milieu", "Midpoint")
        case .edge: return L("Arête", "Edge")
        case .face: return L("Surface", "On Face")
        case .plane: return L("Plan", "Plane")
        }
    }

    func copyMeasurement() {
        guard let a = measureStart?.position, let b = activeMeasureEnd?.position else { return }
        let d = b - a
        let dist = simd_length(d)
        let text = String(
            format: "L = %.3f m (%.1f cm) · ΔX = %+.3f m · ΔY = %+.3f m · ΔZ = %+.3f m",
            dist, dist * 100.0, d.x, d.y, d.z
        )
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        flash(L("Mesure copiée : \(Self.formatDistance(dist, compact: true))", "Measurement copied: \(Self.formatDistance(dist, compact: true))"))
    }

    func toggleEdges() {
        recordUndoable(L("Arêtes", "Edges")) {
            showsEdges.toggle()
            Preferences.showsEdges = showsEdges
            scene?.showsEdges = showsEdges
            viewport.setNeedsDisplay(viewport.bounds)
        }
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
