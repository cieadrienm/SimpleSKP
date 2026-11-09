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
    enum InspectorCategory: String, CaseIterable {
        case videoProjectors
        case stageLights
    }

    var videoProjectors: [VideoProjector] = []
    var selectedVideoProjectorIndex: Int = 0
    var selectedVideoProjectorIndices: Set<Int> = [0]
    var showProjectorInspector: Bool = false
    var showProjectorPopover: Bool = false
    var inspectorCategory: InspectorCategory = .videoProjectors
    /// When `true`, only the 3D wireframe frustum cones and projector bodies are rendered in the viewport without computing surface projection or shadow maps.
    var projectorsFrustumOnly: Bool = false
    /// When `true`, video projector light emission in the 3D viewport simulates realistic illuminance (Lux),
    /// taking into account nominal lumens, inverse-square beam divergence (`1/d²`), active throw ratio zoom,
    /// lens transmission losses, and optical center-to-corner vignetting.
    var photometricSimulation: Bool = true
    /// Calibrated reference illuminance in Lux corresponding to a nominal 1.0 white level in the viewport.
    /// Default `250.0 lx` corresponds to a standard theatrical stage screen reference.
    var photometricReferenceLux: Float = 250.0
    var projectorPickMode: ProjectorPickMode = .none
    var syphonOutputEnabled: Bool = Preferences.syphonOutputEnabled
    var syphonOutputResolution: SyphonOutputResolution = Preferences.syphonOutputResolution
    var isSyphonAvailable: Bool { ViewportView.isSyphonAvailable }
    var availableSyphonSources: [LiveVideoSource] = LiveVideoSourceManager.shared.syphonSources
    var availableNDISources: [LiveVideoSource] = []
    var sskpURL: URL? = nil
    var pendingSSKPProject: SSKPProject? = nil

    // Art-Net DMX & Millumin Conduite Lumière
    var artNetListening: Bool = false
    var artNetPacketCount: UInt64 = 0
    var isArtNetActive: Bool = false
    var latestDMXChannelsByUniverse: [Int: [UInt8]] = [:]
    var milluminBoardName: String? = nil
    var milluminCues: [MilluminLightingCue] = []
    var activeMilluminCueIndex: Int? = nil
    @ObservationIgnored private var artNetThrottler: DispatchWorkItem?

    @ObservationIgnored private var hiddenFeaturesObserver: NSObjectProtocol?
    @ObservationIgnored private var liveVideoSourcesObserver: NSObjectProtocol?
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
    var hasNonDefaultCameraOptics = false
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
        var selectedVideoProjectorIndices: Set<Int>
        var projectorsFrustumOnly: Bool
        var photometricSimulation: Bool
        var photometricReferenceLux: Float
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
    @ObservationIgnored var isApplyingRemoteControl = false

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
            selectedVideoProjectorIndices: selectedVideoProjectorIndices,
            projectorsFrustumOnly: projectorsFrustumOnly,
            photometricSimulation: photometricSimulation,
            photometricReferenceLux: photometricReferenceLux,
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
        guard !isRecordingOrApplyingUndo && !isApplyingRemoteControl else {
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
        selectedVideoProjectorIndices = snapshot.selectedVideoProjectorIndices
        projectorsFrustumOnly = snapshot.projectorsFrustumOnly
        photometricSimulation = snapshot.photometricSimulation
        photometricReferenceLux = snapshot.photometricReferenceLux
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
        liveVideoSourcesObserver = NotificationCenter.default.addObserver(
            forName: .sskpLiveVideoSourcesDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.availableSyphonSources = LiveVideoSourceManager.shared.syphonSources
                self.availableNDISources = LiveVideoSourceManager.shared.ndiSources
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
        setupArtNetReceiver()
    }

    func performBatchedRemoteUpdate(_ body: () -> Void) {
        let wasRemote = isApplyingRemoteControl
        isApplyingRemoteControl = true
        defer {
            isApplyingRemoteControl = wasRemote
            syncCameraStateFromViewport()
        }
        viewport.performBatchedUpdate {
            body()
        }
    }

    func syncCameraStateFromViewport() {
        let pose = viewport.cameraPose
        if simd_distance_squared(cameraPosition, pose.position) > 1e-8 {
            cameraPosition = pose.position
        }
        if abs(cameraYaw - pose.yaw) > 1e-5 {
            cameraYaw = pose.yaw
        }
        if abs(cameraPitch - pose.pitch) > 1e-5 {
            cameraPitch = pose.pitch
        }
        if abs(cameraDistance - pose.distance) > 1e-5 {
            cameraDistance = pose.distance
        }
        let fov = viewport.fieldOfView
        if abs(cameraFOV - fov) > 1e-4 {
            cameraFOV = fov
        }
        let exp = viewport.exposureOffset
        if abs(cameraExposure - exp) > 1e-4 {
            cameraExposure = exp
        }
        let ortho = viewport.orthographicScale
        if abs(cameraOrthoScale - ortho) > 1e-5 {
            cameraOrthoScale = ortho
        }
        let spd = viewport.movementSpeedScale
        if abs(cameraSpeedScale - spd) > 1e-5 {
            cameraSpeedScale = spd
        }
        let nonDefaultOptics = abs(fov - 35) > 0.5 || abs(exp - (-0.62)) > 0.05
        if hasNonDefaultCameraOptics != nonDefaultOptics {
            hasNonDefaultCameraOptics = nonDefaultOptics
        }
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
        viewport.syphonOutputResolution = syphonOutputResolution
        state = .ready(scene)
        viewport.present(scene)
        if syphonOutputEnabled {
            viewport.syphonOutputEnabled = true
        }
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
            if abs(cameraFOV - clamped) > 1e-4 { cameraFOV = clamped }
            let nonDefaultOptics = abs(clamped - 35) > 0.5 || abs(cameraExposure - (-0.62)) > 0.05
            if hasNonDefaultCameraOptics != nonDefaultOptics { hasNonDefaultCameraOptics = nonDefaultOptics }
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
            if abs(cameraExposure - clamped) > 1e-4 { cameraExposure = clamped }
            let nonDefaultOptics = abs(cameraFOV - 35) > 0.5 || abs(clamped - (-0.62)) > 0.05
            if hasNonDefaultCameraOptics != nonDefaultOptics { hasNonDefaultCameraOptics = nonDefaultOptics }
            viewport.exposureOffset = clamped
        }
    }

    func setCameraOrthoScale(_ scale: Float) {
        let clamped = max(0.05, min(10_000.0, scale))
        recordUndoable(L("Échelle orthographique", "Orthographic Scale"), coalesceKey: "camera-ortho", restoresCameraPose: true) {
            if abs(cameraOrthoScale - clamped) > 1e-5 { cameraOrthoScale = clamped }
            viewport.orthographicScale = clamped
        }
    }

    func setCameraSpeedScale(_ scale: Float) {
        let clamped = max(1.0 / 16.0, min(16.0, scale))
        if abs(cameraSpeedScale - clamped) > 1e-5 { cameraSpeedScale = clamped }
        viewport.movementSpeedScale = clamped
    }

    func setCameraPosition(_ position: SIMD3<Float>) {
        recordUndoable(L("Position caméra", "Camera Position"), coalesceKey: "camera-pos", restoresCameraPose: true) {
            if activeStandardView != nil { activeStandardView = nil }
            viewport.setCameraPose(position: position)
            if !isApplyingRemoteControl { syncCameraStateFromViewport() }
        }
    }

    func setCameraOrientation(yawDegrees: Float? = nil, pitchDegrees: Float? = nil) {
        recordUndoable(L("Orientation caméra", "Camera Orientation"), coalesceKey: "camera-orient", restoresCameraPose: true) {
            if activeStandardView != nil { activeStandardView = nil }
            viewport.setCameraPose(yawDegrees: yawDegrees, pitchDegrees: pitchDegrees)
            if !isApplyingRemoteControl { syncCameraStateFromViewport() }
        }
    }

    func setCameraDistance(_ distance: Float) {
        recordUndoable(L("Distance cible caméra", "Camera Target Distance"), coalesceKey: "camera-dist", restoresCameraPose: true) {
            viewport.setCameraPose(distance: max(0.05, distance))
            if !isApplyingRemoteControl { syncCameraStateFromViewport() }
        }
    }

    func setCameraTarget(_ target: SIMD3<Float>, animated: Bool = false) {
        recordUndoable(L("Cible caméra", "Camera Target"), coalesceKey: "camera-target", restoresCameraPose: true) {
            if activeStandardView != nil { activeStandardView = nil }
            viewport.setCameraTarget(target, animated: animated)
            if !isApplyingRemoteControl { syncCameraStateFromViewport() }
        }
    }

    func setCameraLookAt(position: SIMD3<Float>, target: SIMD3<Float>, animated: Bool = false) {
        recordUndoable(L("Cadrage caméra", "Camera Framing"), coalesceKey: "camera-lookat", restoresCameraPose: true) {
            if activeStandardView != nil { activeStandardView = nil }
            viewport.setCameraLookAt(position: position, target: target, animated: animated)
            if !isApplyingRemoteControl { syncCameraStateFromViewport() }
        }
    }

    func orbitCameraByDegrees(yaw dYawDegrees: Float, pitch dPitchDegrees: Float) {
        recordUndoable(L("Rotation caméra", "Camera Orbit"), coalesceKey: "camera-orbit", restoresCameraPose: true) {
            if activeStandardView != nil { activeStandardView = nil }
            viewport.orbitByDegrees(yaw: dYawDegrees, pitch: dPitchDegrees)
            if !isApplyingRemoteControl { syncCameraStateFromViewport() }
        }
    }

    func levelCameraHorizon(animated: Bool = true) {
        recordUndoable(L("Horizon à niveau", "Level Horizon"), restoresCameraPose: true) {
            if activeStandardView != nil { activeStandardView = nil }
            viewport.levelHorizon(animated: animated)
            if !isApplyingRemoteControl { syncCameraStateFromViewport() }
        }
    }

    /// Places the camera at human eye height (`1.70 m` above the model floor or Z=0) and levels the horizon.
    func setCameraEyeHeight(_ heightAboveFloor: Float = 1.70) {
        recordUndoable(L("Hauteur d'œil", "Eye Height"), restoresCameraPose: true) {
            if activeStandardView != nil { activeStandardView = nil }
            let bMinZ = scene?.visibleBounds.min.z ?? skp?.boundsMin.z ?? 0
            let bMaxZ = scene?.visibleBounds.max.z ?? skp?.boundsMax.z ?? 3
            let floorZ = (bMinZ <= 0.2 && bMaxZ >= 1.5) ? 0.0 : bMinZ
            var pos = viewport.cameraModelPosition
            pos.z = floorZ + heightAboveFloor
            viewport.setCameraPose(position: pos, pitchDegrees: 0)
            if !isApplyingRemoteControl { syncCameraStateFromViewport() }
        }
    }

    /// Places the camera at the geometric center of the model and levels the horizon.
    func centerCameraInModel() {
        recordUndoable(L("Centrer la caméra", "Center Camera"), restoresCameraPose: true) {
            if activeStandardView != nil { activeStandardView = nil }
            let center = scene?.defaultPointLightPosition ?? skp?.center ?? .zero
            viewport.setCameraPose(position: center, pitchDegrees: 0)
            if !isApplyingRemoteControl { syncCameraStateFromViewport() }
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

    func setAmbientOcclusionIntensity(_ value: Float, coalesce: Bool = true) {
        recordUndoable(L("Intensité AO", "AO Intensity"), coalesceKey: coalesce ? "ao-intensity" : nil) {
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

    func updateSelectedPointLight(position: SIMD3<Float>? = nil, intensity: Float? = nil, coalesceKey: String? = "point-light") {
        guard pointLights.indices.contains(selectedPointLightIndex) else { return }
        let key = coalesceKey.map { "\($0)-\(selectedPointLightIndex)" }
        recordUndoable(L("Réglage lumière", "Adjust Light"), coalesceKey: key) {
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

    func setSun(azimuth: Float, elevation: Float, coalesce: Bool = true) {
        let clampedAz = ((azimuth + 180.0).truncatingRemainder(dividingBy: 360.0) + 360.0).truncatingRemainder(dividingBy: 360.0) - 180.0
        let clampedEl = max(8.0, min(85.0, elevation))
        recordUndoable(L("Orientation du soleil", "Sun Orientation"), coalesceKey: coalesce ? "sun-orient" : nil) {
            sunAzimuthDegrees = clampedAz
            sunElevationDegrees = clampedEl
            scene?.sunAzimuthDegrees = clampedAz
            scene?.sunElevationDegrees = clampedEl
            viewport.requestRedraw()
        }
    }

    func setSunIntensity(_ intensity: Float, coalesce: Bool = true) {
        recordUndoable(L("Intensité du soleil", "Sun Intensity"), coalesceKey: coalesce ? "sun-intensity" : nil) {
            let clamped = max(0.0, min(3.0, intensity))
            sunIntensity = clamped
            scene?.sunIntensity = clamped
            viewport.requestRedraw()
        }
    }

    func setAmbientIntensity(_ intensity: Float, coalesce: Bool = true) {
        recordUndoable(L("Lumière ambiante", "Ambient Light"), coalesceKey: coalesce ? "ambient-intensity" : nil) {
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

    /// Indices in `videoProjectors` that are true video projectors (`isStageLight == false`).
    var onlyVideoProjectorIndices: [Int] {
        videoProjectors.indices.filter { !videoProjectors[$0].isStageLight }
    }

    /// Indices in `videoProjectors` that are stage lights (`isStageLight == true`).
    var stageLightIndices: [Int] {
        videoProjectors.indices.filter { videoProjectors[$0].isStageLight }
    }

    var enabledOnlyVideoProjectorCount: Int {
        onlyVideoProjectorIndices.filter { videoProjectors[$0].isEnabled }.count
    }

    var enabledStageLightCount: Int {
        stageLightIndices.filter { videoProjectors[$0].isEnabled }.count
    }

    var selectedVideoProjector: VideoProjector? {
        guard videoProjectors.indices.contains(selectedVideoProjectorIndex) else { return nil }
        return videoProjectors[selectedVideoProjectorIndex]
    }

    var selectedVideoProjectors: [VideoProjector] {
        selectedVideoProjectorIndices.sorted().compactMap { idx in
            videoProjectors.indices.contains(idx) ? videoProjectors[idx] : nil
        }
    }

    var selectedProjectorCount: Int {
        selectedVideoProjectorIndices.count
    }

    var isMultipleProjectorSelection: Bool {
        selectedVideoProjectorIndices.count > 1
    }

    func selectVideoProjector(_ index: Int, extending: Bool = false, toggling: Bool = false) {
        guard videoProjectors.indices.contains(index) else { return }
        let targetIsStageLight = videoProjectors[index].isStageLight
        inspectorCategory = targetIsStageLight ? .stageLights : .videoProjectors
        if toggling {
            if selectedVideoProjectorIndices.contains(index) {
                if selectedVideoProjectorIndices.count > 1 {
                    selectedVideoProjectorIndices.remove(index)
                    if selectedVideoProjectorIndex == index {
                        selectedVideoProjectorIndex = selectedVideoProjectorIndices.sorted().first ?? 0
                    }
                }
            } else {
                // Keep multi-selection homogeneous (either all VPs or all Stage Lights)
                selectedVideoProjectorIndices = selectedVideoProjectorIndices.filter {
                    videoProjectors.indices.contains($0) && videoProjectors[$0].isStageLight == targetIsStageLight
                }
                selectedVideoProjectorIndices.insert(index)
                selectedVideoProjectorIndex = index
            }
        } else if extending {
            let start = min(selectedVideoProjectorIndex, index)
            let end = max(selectedVideoProjectorIndex, index)
            selectedVideoProjectorIndices = selectedVideoProjectorIndices.filter {
                videoProjectors.indices.contains($0) && videoProjectors[$0].isStageLight == targetIsStageLight
            }
            for i in start...end where videoProjectors[i].isStageLight == targetIsStageLight {
                selectedVideoProjectorIndices.insert(i)
            }
            selectedVideoProjectorIndex = index
        } else {
            selectedVideoProjectorIndices = [index]
            selectedVideoProjectorIndex = index
        }
        syncProjectorsToScene()
    }

    func selectAllVideoProjectors() {
        guard !videoProjectors.isEmpty else { return }
        selectedVideoProjectorIndices = Set(videoProjectors.indices)
        selectedVideoProjectorIndex = videoProjectors.indices.first ?? 0
        syncProjectorsToScene()
    }

    func selectAllOnlyVideoProjectors() {
        let indices = onlyVideoProjectorIndices
        guard let first = indices.first else { return }
        inspectorCategory = .videoProjectors
        selectedVideoProjectorIndices = Set(indices)
        selectedVideoProjectorIndex = first
        syncProjectorsToScene()
    }

    func selectAllStageLights() {
        let indices = stageLightIndices
        guard let first = indices.first else { return }
        inspectorCategory = .stageLights
        selectedVideoProjectorIndices = Set(indices)
        selectedVideoProjectorIndex = first
        syncProjectorsToScene()
    }

    func toggleProjectorInspector() {
        toggleVideoProjectorInspector()
    }

    func toggleVideoProjectorInspector() {
        if showProjectorInspector && inspectorCategory == .videoProjectors {
            showProjectorInspector = false
            return
        }
        inspectorCategory = .videoProjectors
        showProjectorInspector = true
        let vpIndices = onlyVideoProjectorIndices
        if let current = selectedVideoProjector, !current.isStageLight {
            // Already selecting a VP
        } else if let firstVP = vpIndices.first {
            selectedVideoProjectorIndex = firstVP
            selectedVideoProjectorIndices = [firstVP]
            syncProjectorsToScene()
        }
    }

    func toggleStageLightInspector() {
        if showProjectorInspector && inspectorCategory == .stageLights {
            showProjectorInspector = false
            return
        }
        inspectorCategory = .stageLights
        showProjectorInspector = true
        let lightIndices = stageLightIndices
        if let current = selectedVideoProjector, current.isStageLight {
            // Already selecting a stage light
        } else if let firstLight = lightIndices.first {
            selectedVideoProjectorIndex = firstLight
            selectedVideoProjectorIndices = [firstLight]
            syncProjectorsToScene()
        }
    }

    func switchInspectorCategory(_ category: InspectorCategory) {
        inspectorCategory = category
        showProjectorInspector = true
        switch category {
        case .videoProjectors:
            if selectedVideoProjector?.isStageLight != false, let firstVP = onlyVideoProjectorIndices.first {
                selectedVideoProjectorIndex = firstVP
                selectedVideoProjectorIndices = [firstVP]
                syncProjectorsToScene()
            }
        case .stageLights:
            if selectedVideoProjector?.isStageLight != true, let firstLight = stageLightIndices.first {
                selectedVideoProjectorIndex = firstLight
                selectedVideoProjectorIndices = [firstLight]
                syncProjectorsToScene()
            }
        }
    }

    func addVideoProjector(spec: ProjectorSpec = .optomaZU920ST) {
        let actionTitle: String
        let defaultPrefix: String
        let pat: ProjectionPattern
        let isLight = spec.isStageLight
        switch spec.kind {
        case .profileSpot:
            actionTitle = L("Ajout découpe LED", "Add Profile Spot")
            defaultPrefix = "Découpe"
            pat = .whiteFrame
        case .washPanel:
            actionTitle = L("Ajout projecteur wash", "Add Wash Light")
            defaultPrefix = "Wash"
            pat = .whiteFrame
        case .videoProjector:
            actionTitle = L("Ajout vidéoprojecteur", "Add Video Projector")
            defaultPrefix = "VP"
            pat = .testGrid
        }

        recordUndoable(actionTitle) {
            let categoryCount = isLight ? (stageLightIndices.count + 1) : (onlyVideoProjectorIndices.count + 1)
            let camPos = viewport.cameraModelPosition
            let camTarget = viewport.cameraPose.target
            let offsetRight = viewport.cameraPose.right * (Float(categoryCount - 1) * 0.65)
            let pos: SIMD3<Float>
            let tgt: SIMD3<Float>
            if isReady, simd_distance(camPos, camTarget) > 0.3 {
                let toCamera = camPos - camTarget
                let d = simd_length(toCamera)
                let dir = toCamera / max(d, 1e-4)
                let throwDist = min(max(d * 0.55, 2.5), max(d * 0.85, 4.0))
                pos = camTarget + dir * throwDist + offsetRight
                tgt = camTarget + offsetRight * 0.3
            } else {
                let center = scene?.defaultPointLightPosition ?? skp?.center ?? .zero
                pos = center + SIMD3<Float>(0, isLight ? 0.0 : -5.0, isLight ? 4.5 : 2.5)
                tgt = center
            }

            // Look up matching OFL definition if this is a stage light
            let oflDef = isLight ? OFLFixtureLibrary.shared.fixture(for: spec.id) : nil
            let oflMode = oflDef?.modes.first
            let chanNames = oflMode?.channels.map(\.name) ?? []
            let chanRoles = oflMode?.channels.map(\.role) ?? []

            let proj = VideoProjector(
                name: "\(defaultPrefix) \(categoryCount) — \(spec.model)",
                specID: spec.id,
                isEnabled: true,
                position: pos,
                target: tgt,
                rollDegrees: 0,
                throwRatio: spec.defaultThrowRatio,
                lensShiftH: 0,
                lensShiftV: 0,
                intensity: 1.0,
                pattern: pat,
                showsFrustum: true,
                dmxMode: !chanRoles.isEmpty ? "ofl" : (spec.kind == .washPanel ? "rgbw4ch" : "dimmer1ch"),
                oflFixtureID: oflDef?.id,
                oflModeName: oflMode?.name,
                dmxChannelNames: chanNames,
                dmxChannelRoles: chanRoles
            )
            videoProjectors.append(proj)
            let newIndex = videoProjectors.count - 1
            selectedVideoProjectorIndex = newIndex
            selectedVideoProjectorIndices = [newIndex]
            inspectorCategory = isLight ? .stageLights : .videoProjectors
            showProjectorInspector = true
            syncProjectorsToScene()
        }
    }

    /// Adds a stage light directly from an Open Fixture Library (`OFLFixtureDefinition`) entry in `/Users/adrien/Library/Millumin/Light-fixtures`.
    func addOFLStageLight(definition: OFLFixtureDefinition, modeName: String? = nil) {
        let mode = definition.resolveMode(named: modeName ?? "") ?? definition.modes.first
        let spec = definition.toProjectorSpec(modeName: mode?.name)
        recordUndoable(L("Ajout lumière \(definition.displayName)", "Add Light \(definition.displayName)")) {
            let lightNumber = stageLightIndices.count + 1
            let camPos = viewport.cameraModelPosition
            let camTarget = viewport.cameraPose.target
            let offsetRight = viewport.cameraPose.right * (Float(lightNumber - 1) * 0.55)
            let pos: SIMD3<Float>
            let tgt: SIMD3<Float>
            if isReady, simd_distance(camPos, camTarget) > 0.3 {
                let toCamera = camPos - camTarget
                let d = simd_length(toCamera)
                let dir = toCamera / max(d, 1e-4)
                let throwDist = min(max(d * 0.55, 2.5), max(d * 0.85, 4.5))
                pos = camTarget + dir * throwDist + offsetRight
                tgt = camTarget + offsetRight * 0.3
            } else {
                let center = scene?.defaultPointLightPosition ?? skp?.center ?? .zero
                pos = SIMD3<Float>(center.x, center.y, max(center.z + 4.0, 4.5))
                tgt = SIMD3<Float>(center.x, center.y, 0.0)
            }
            let chanNames = mode?.channels.map(\.name) ?? []
            let chanRoles = mode?.channels.map(\.role) ?? []
            let proj = VideoProjector(
                name: "\(definition.name) #\(lightNumber)",
                specID: spec.id,
                isEnabled: true,
                position: pos,
                target: tgt,
                rollDegrees: 0,
                throwRatio: spec.defaultThrowRatio,
                lensShiftH: 0,
                lensShiftV: 0,
                intensity: 1.0,
                pattern: .whiteFrame,
                showsFrustum: true,
                dmxMode: !chanRoles.isEmpty ? "ofl" : "dimmer1ch",
                oflFixtureID: definition.id,
                oflModeName: mode?.name,
                dmxChannelNames: chanNames,
                dmxChannelRoles: chanRoles
            )
            videoProjectors.append(proj)
            let newIndex = videoProjectors.count - 1
            selectedVideoProjectorIndex = newIndex
            selectedVideoProjectorIndices = [newIndex]
            inspectorCategory = .stageLights
            showProjectorInspector = true
            syncProjectorsToScene()
        }
    }

    /// Shortcut to add a Showtec Performer Profile Mini (compact 30W COB LED découpe with zoom 19°–36° and 4 framing shutters).
    func addShowtecProfileMini() {
        addVideoProjector(spec: .showtecPerformerProfileMini)
    }

    /// Shortcut to add an Eurolite LED PLL-480 QCL Panel (softlight wash panel with wide 120° flood and 4-leaf barn doors).
    func addEurolitePLL480() {
        addVideoProjector(spec: .euroliteLEDPLL480QCL)
    }

    /// Shortcut to add a Varytec Hero Wash 300 FC (moving head wash with 19×15W RGBW LEDs and motorized zoom 6°–50°).
    func addVarytecHeroWash300() {
        addVideoProjector(spec: .varytecHeroWash300FC)
    }

    var enabledVideoProjectorCount: Int {
        videoProjectors.filter(\.isEnabled).count
    }

    func toggleVideoProjector(_ index: Int) {
        guard videoProjectors.indices.contains(index) else { return }
        recordUndoable(L("Activer/Désactiver projecteur", "Toggle Fixture")) {
            selectedVideoProjectorIndex = index
            videoProjectors[index].isEnabled.toggle()
            syncProjectorsToScene()
        }
    }

    func setAllVideoProjectors(enabled: Bool) {
        guard !videoProjectors.isEmpty else { return }
        let title = enabled ? L("Activer tous les projecteurs", "Enable All Fixtures") : L("Désactiver tous les projecteurs", "Disable All Fixtures")
        recordUndoable(title) {
            for i in videoProjectors.indices {
                videoProjectors[i].isEnabled = enabled
            }
            syncProjectorsToScene()
        }
    }

    func setAllOnlyVideoProjectors(enabled: Bool) {
        let indices = onlyVideoProjectorIndices
        guard !indices.isEmpty else { return }
        let title = enabled ? L("Activer tous les VP", "Enable All VPs") : L("Désactiver tous les VP", "Disable All VPs")
        recordUndoable(title) {
            for i in indices {
                videoProjectors[i].isEnabled = enabled
            }
            syncProjectorsToScene()
        }
    }

    func setAllStageLights(enabled: Bool) {
        let indices = stageLightIndices
        guard !indices.isEmpty else { return }
        let title = enabled ? L("Allumer toutes les lumières", "Enable All Stage Lights") : L("Éteindre toutes les lumières", "Disable All Stage Lights")
        recordUndoable(title) {
            for i in indices {
                videoProjectors[i].isEnabled = enabled
            }
            syncProjectorsToScene()
        }
    }

    func soloVideoProjector(_ index: Int) {
        guard videoProjectors.indices.contains(index) else { return }
        let isLight = videoProjectors[index].isStageLight
        let peerIndices = isLight ? stageLightIndices : onlyVideoProjectorIndices
        guard peerIndices.count > 1 else { return }
        let isAlreadySolo = peerIndices.allSatisfy { i in
            videoProjectors[i].isEnabled == (i == index)
        }
        recordUndoable(isLight ? L("Isoler lumière", "Solo Stage Light") : L("Isoler VP", "Solo VP")) {
            selectedVideoProjectorIndex = index
            selectedVideoProjectorIndices = [index]
            inspectorCategory = isLight ? .stageLights : .videoProjectors
            for i in peerIndices {
                videoProjectors[i].isEnabled = isAlreadySolo ? true : (i == index)
            }
            syncProjectorsToScene()
        }
    }

    func soloSelectedVideoProjectors() {
        guard !selectedVideoProjectorIndices.isEmpty else { return }
        let isLight = (selectedVideoProjector?.isStageLight == true)
        let peerIndices = isLight ? stageLightIndices : onlyVideoProjectorIndices
        guard peerIndices.count > 1 else { return }
        let isAlreadySolo = peerIndices.allSatisfy { i in
            videoProjectors[i].isEnabled == selectedVideoProjectorIndices.contains(i)
        }
        recordUndoable(L("Isoler sélection", "Solo Selection")) {
            for i in peerIndices {
                videoProjectors[i].isEnabled = isAlreadySolo ? true : selectedVideoProjectorIndices.contains(i)
            }
            syncProjectorsToScene()
        }
    }

    func lookThroughVideoProjector(_ index: Int) {
        guard videoProjectors.indices.contains(index) else { return }
        selectedVideoProjectorIndex = index
        selectedVideoProjectorIndices = [index]
        inspectorCategory = videoProjectors[index].isStageLight ? .stageLights : .videoProjectors
        syncProjectorsToScene()
        lookThroughSelectedProjector()
    }

    func openInspectorForVideoProjector(_ index: Int) {
        guard videoProjectors.indices.contains(index) else { return }
        selectedVideoProjectorIndex = index
        selectedVideoProjectorIndices = [index]
        inspectorCategory = videoProjectors[index].isStageLight ? .stageLights : .videoProjectors
        showProjectorInspector = true
        syncProjectorsToScene()
    }

    func duplicateVideoProjector(_ index: Int) {
        guard videoProjectors.indices.contains(index) else { return }
        selectedVideoProjectorIndex = index
        selectedVideoProjectorIndices = [index]
        duplicateSelectedVideoProjector()
    }

    func removeVideoProjector(_ index: Int) {
        guard videoProjectors.indices.contains(index) else { return }
        selectedVideoProjectorIndex = index
        selectedVideoProjectorIndices = [index]
        removeSelectedVideoProjector()
    }

    func duplicateSelectedVideoProjector() {
        if selectedVideoProjectorIndices.count > 1 {
            duplicateSelectedVideoProjectors()
            return
        }
        guard var copy = selectedVideoProjector else { return }
        recordUndoable(L("Duplication vidéoprojecteur", "Duplicate Video Projector")) {
            copy.id = UUID()
            copy.name = "\(copy.name) (\(videoProjectors.count + 1))"
            let (right, _, _) = copy.opticalBasis()
            copy.position += right * 1.0
            copy.target += right * 1.0
            videoProjectors.append(copy)
            let newIndex = videoProjectors.count - 1
            selectedVideoProjectorIndex = newIndex
            selectedVideoProjectorIndices = [newIndex]
            syncProjectorsToScene()
        }
    }

    func removeSelectedVideoProjector() {
        if selectedVideoProjectorIndices.count > 1 {
            removeSelectedVideoProjectors()
            return
        }
        guard videoProjectors.indices.contains(selectedVideoProjectorIndex) else { return }
        recordUndoable(L("Suppression vidéoprojecteur", "Remove Video Projector")) {
            videoProjectors.remove(at: selectedVideoProjectorIndex)
            if videoProjectors.isEmpty {
                selectedVideoProjectorIndices = []
                selectedVideoProjectorIndex = 0
                cancelProjectorPick()
            } else {
                let safeIndex = max(0, min(selectedVideoProjectorIndex, videoProjectors.count - 1))
                selectedVideoProjectorIndex = safeIndex
                selectedVideoProjectorIndices = [safeIndex]
            }
            syncProjectorsToScene()
        }
    }

    func updateSelectedVideoProjector(
        actionName: String? = nil,
        coalesceKey: String? = nil,
        _ mutate: (inout VideoProjector) -> Void
    ) {
        guard videoProjectors.indices.contains(selectedVideoProjectorIndex) else { return }
        let title = actionName ?? L("Réglage vidéoprojecteur", "Adjust Video Projector")
        let key = coalesceKey.map { "vp-\(selectedVideoProjectorIndex)-\($0)" }
        recordUndoable(title, coalesceKey: key) {
            mutate(&videoProjectors[selectedVideoProjectorIndex])
            syncProjectorsToScene()
        }
    }

    // MARK: - Group & Multi-Projector Operations

    func moveSelectedProjectors(
        delta: SIMD3<Float>,
        actionName: String? = nil,
        coalesceKey: String? = nil
    ) {
        guard !selectedVideoProjectorIndices.isEmpty else { return }
        let count = selectedVideoProjectorIndices.count
        let title: String
        if let actionName {
            title = actionName
        } else if count > 1 {
            title = L("Déplacer \(count) vidéoprojecteurs", "Move \(count) Video Projectors")
        } else {
            title = L("Déplacer vidéoprojecteur", "Move Video Projector")
        }
        let key = coalesceKey.map { "vp-move-\($0)" }
        recordUndoable(title, coalesceKey: key) {
            for idx in selectedVideoProjectorIndices where videoProjectors.indices.contains(idx) {
                videoProjectors[idx].position += delta
                videoProjectors[idx].target += delta
            }
            syncProjectorsToScene()
        }
    }

    func nudgeSelectedProjectors(deltaX: Float = 0, deltaY: Float = 0, deltaZ: Float = 0) {
        let delta = SIMD3<Float>(deltaX, deltaY, deltaZ)
        let axisLabel = deltaX != 0 ? "X" : (deltaY != 0 ? "Y" : "Z")
        moveSelectedProjectors(
            delta: delta,
            actionName: L("Déplacement \(axisLabel) VP", "VP \(axisLabel) Move"),
            coalesceKey: "nudge-\(axisLabel)"
        )
    }

    func duplicateSelectedProjectorSymmetricAcrossStage(axisX: Float = 0) {
        guard !selectedVideoProjectorIndices.isEmpty else { return }
        recordUndoable(L("Duplication symétrique plateau", "Duplicate Symmetric Projector")) {
            var newIndices: Set<Int> = []
            for idx in selectedVideoProjectorIndices.sorted() where videoProjectors.indices.contains(idx) {
                var copy = videoProjectors[idx]
                copy.id = UUID()
                let isJardin = copy.position.x < axisX
                let sideSuffix = isJardin ? L("Cour", "Stage Right") : L("Jardin", "Stage Left")
                copy.name = "\(copy.name) (\(sideSuffix))"
                copy.position.x = 2 * axisX - copy.position.x
                copy.target.x = 2 * axisX - copy.target.x
                copy.lensShiftH = -copy.lensShiftH
                videoProjectors.append(copy)
                newIndices.insert(videoProjectors.count - 1)
            }
            if let first = newIndices.sorted().first {
                selectedVideoProjectorIndex = first
                selectedVideoProjectorIndices = newIndices
            }
            syncProjectorsToScene()
        }
    }

    func mirrorSelectedProjectorsAcrossStage(axisX: Float = 0) {
        guard !selectedVideoProjectorIndices.isEmpty else { return }
        recordUndoable(L("Symétrie plateau", "Mirror Projectors Across Stage")) {
            for idx in selectedVideoProjectorIndices where videoProjectors.indices.contains(idx) {
                videoProjectors[idx].position.x = 2 * axisX - videoProjectors[idx].position.x
                videoProjectors[idx].target.x = 2 * axisX - videoProjectors[idx].target.x
                videoProjectors[idx].lensShiftH = -videoProjectors[idx].lensShiftH
            }
            syncProjectorsToScene()
        }
    }

    func setSelectedVideoProjectorsEnabled(_ enabled: Bool) {
        guard !selectedVideoProjectorIndices.isEmpty else { return }
        let title = enabled ? L("Allumer sélection", "Turn On Selection") : L("Éteindre sélection", "Turn Off Selection")
        recordUndoable(title) {
            for idx in selectedVideoProjectorIndices where videoProjectors.indices.contains(idx) {
                videoProjectors[idx].isEnabled = enabled
            }
            syncProjectorsToScene()
        }
    }

    func setSelectedVideoProjectorsFrustum(_ showsFrustum: Bool) {
        guard !selectedVideoProjectorIndices.isEmpty else { return }
        recordUndoable(L("Faisceaux 3D sélection", "Frustum Selection")) {
            for idx in selectedVideoProjectorIndices where videoProjectors.indices.contains(idx) {
                videoProjectors[idx].showsFrustum = showsFrustum
            }
            syncProjectorsToScene()
        }
    }

    func setSelectedVideoProjectorsPattern(_ pattern: ProjectionPattern) {
        guard !selectedVideoProjectorIndices.isEmpty else { return }
        recordUndoable(L("Mire sélection", "Pattern Selection")) {
            for idx in selectedVideoProjectorIndices where videoProjectors.indices.contains(idx) {
                videoProjectors[idx].pattern = pattern
            }
            syncProjectorsToScene()
        }
    }

    func setSelectedVideoProjectorsSpec(_ spec: ProjectorSpec) {
        guard !selectedVideoProjectorIndices.isEmpty else { return }
        recordUndoable(L("Modèle sélection", "Model Selection")) {
            for idx in selectedVideoProjectorIndices where videoProjectors.indices.contains(idx) {
                videoProjectors[idx].applySpec(spec)
            }
            syncProjectorsToScene()
        }
    }

    func setSelectedVideoProjectorsIntensity(_ intensity: Float, coalesceKey: String? = nil) {
        guard !selectedVideoProjectorIndices.isEmpty else { return }
        let key = coalesceKey.map { "intensity-\($0)" }
        recordUndoable(L("Intensité sélection", "Intensity Selection"), coalesceKey: key) {
            for idx in selectedVideoProjectorIndices where videoProjectors.indices.contains(idx) {
                videoProjectors[idx].intensity = intensity
            }
            syncProjectorsToScene()
        }
    }

    func setSelectedVideoProjectorsReverb(_ reverb: Float, coalesceKey: String? = nil) {
        guard !selectedVideoProjectorIndices.isEmpty else { return }
        let key = coalesceKey.map { "reverb-\($0)" }
        recordUndoable(L("Réverbération sélection", "Reverberation Selection"), coalesceKey: key) {
            for idx in selectedVideoProjectorIndices where videoProjectors.indices.contains(idx) {
                videoProjectors[idx].reverbIntensity = reverb
            }
            syncProjectorsToScene()
        }
    }

    func duplicateSelectedVideoProjectors() {
        guard !selectedVideoProjectorIndices.isEmpty else { return }
        recordUndoable(L("Duplication sélection", "Duplicate Selection")) {
            var newIndices: Set<Int> = []
            for idx in selectedVideoProjectorIndices.sorted() where videoProjectors.indices.contains(idx) {
                var copy = videoProjectors[idx]
                copy.id = UUID()
                copy.name = "\(copy.name) (\(videoProjectors.count + 1))"
                let (right, _, _) = copy.opticalBasis()
                copy.position += right * 1.0
                copy.target += right * 1.0
                videoProjectors.append(copy)
                newIndices.insert(videoProjectors.count - 1)
            }
            if let first = newIndices.sorted().first {
                selectedVideoProjectorIndex = first
                selectedVideoProjectorIndices = newIndices
            }
            syncProjectorsToScene()
        }
    }

    func removeSelectedVideoProjectors() {
        guard !selectedVideoProjectorIndices.isEmpty else { return }
        recordUndoable(L("Suppression sélection", "Delete Selection")) {
            let sortedIndices = selectedVideoProjectorIndices.sorted(by: >)
            for idx in sortedIndices where videoProjectors.indices.contains(idx) {
                videoProjectors.remove(at: idx)
            }
            if videoProjectors.isEmpty {
                selectedVideoProjectorIndices = []
                selectedVideoProjectorIndex = 0
                cancelProjectorPick()
            } else {
                let safeIndex = max(0, min(selectedVideoProjectorIndex, videoProjectors.count - 1))
                selectedVideoProjectorIndex = safeIndex
                selectedVideoProjectorIndices = [safeIndex]
            }
            syncProjectorsToScene()
        }
    }

    func moveSelectedProjectorToCamera() {
        guard videoProjectors.indices.contains(selectedVideoProjectorIndex), isReady else { return }
        recordUndoable(L("Placer VP sur la caméra", "Place VP at Camera")) {
            let delta = viewport.cameraModelPosition - videoProjectors[selectedVideoProjectorIndex].position
            if selectedVideoProjectorIndices.count > 1 {
                for idx in selectedVideoProjectorIndices where videoProjectors.indices.contains(idx) {
                    videoProjectors[idx].position += delta
                    videoProjectors[idx].target += delta
                }
            } else {
                videoProjectors[selectedVideoProjectorIndex].position = viewport.cameraModelPosition
                videoProjectors[selectedVideoProjectorIndex].target = viewport.cameraPose.target
            }
            syncProjectorsToScene()
        }
    }

    func aimSelectedProjectorAtCameraTarget() {
        guard videoProjectors.indices.contains(selectedVideoProjectorIndex), isReady else { return }
        recordUndoable(L("Viser la cible caméra", "Aim VP at Camera Target")) {
            for idx in selectedVideoProjectorIndices where videoProjectors.indices.contains(idx) {
                videoProjectors[idx].target = viewport.cameraPose.target
            }
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

    func refreshLiveVideoSources() {
        LiveVideoSourceManager.shared.refreshSources()
        availableSyphonSources = LiveVideoSourceManager.shared.syphonSources
        availableNDISources = LiveVideoSourceManager.shared.ndiSources
        scene?.refreshLiveProjectorFrames()
    }

    func activateLiveStreamPattern(_ kind: ProjectionPattern) {
        guard (kind == .syphon || kind == .ndi),
              videoProjectors.indices.contains(selectedVideoProjectorIndex)
        else { return }
        refreshLiveVideoSources()
        let sources = (kind == .syphon) ? availableSyphonSources : availableNDISources
        let label = (kind == .syphon) ? L("Flux Syphon VP", "VP Syphon Stream") : L("Flux NDI VP", "VP NDI Stream")
        recordUndoable(label) {
            videoProjectors[selectedVideoProjectorIndex].pattern = kind
            let currentID = videoProjectors[selectedVideoProjectorIndex].liveSourceID
            let hasMatchingSource = sources.contains(where: { $0.id == currentID })
            if !hasMatchingSource, let first = sources.first {
                videoProjectors[selectedVideoProjectorIndex].liveSourceID = first.id
                videoProjectors[selectedVideoProjectorIndex].liveSourceName = first.displayTitle
            }
            syncProjectorsToScene()
        }
    }

    func selectLiveVideoSource(id: String, forKind kind: ProjectionPattern) {
        guard (kind == .syphon || kind == .ndi),
              videoProjectors.indices.contains(selectedVideoProjectorIndex)
        else { return }
        let sources = (kind == .syphon) ? availableSyphonSources : availableNDISources
        let matched = sources.first(where: { $0.id == id })
        let label = (kind == .syphon) ? L("Source Syphon VP", "VP Syphon Source") : L("Source NDI VP", "VP NDI Source")
        recordUndoable(label) {
            videoProjectors[selectedVideoProjectorIndex].pattern = kind
            videoProjectors[selectedVideoProjectorIndex].liveSourceID = id
            if let matched {
                videoProjectors[selectedVideoProjectorIndex].liveSourceName = matched.displayTitle
            }
            syncProjectorsToScene()
        }
    }

    func setProjectorsFrustumOnly(_ enabled: Bool) {
        guard projectorsFrustumOnly != enabled else { return }
        recordUndoable(L("Mode Frustum seul VP", "VP Frustum-Only Mode")) {
            projectorsFrustumOnly = enabled
            syncProjectorsToScene()
        }
    }

    func toggleProjectorsFrustumOnly() {
        setProjectorsFrustumOnly(!projectorsFrustumOnly)
    }

    func setPhotometricSimulation(_ enabled: Bool) {
        guard photometricSimulation != enabled else { return }
        recordUndoable(enabled ? L("Activer simulation photométrique", "Enable Photometric Simulation") : L("Désactiver simulation photométrique", "Disable Photometric Simulation")) {
            photometricSimulation = enabled
            syncProjectorsToScene()
        }
    }

    func togglePhotometricSimulation() {
        setPhotometricSimulation(!photometricSimulation)
    }

    func setPhotometricReferenceLux(_ refLux: Float, coalesceKey: String? = nil) {
        let clamped = max(50.0, min(1500.0, refLux))
        guard abs(photometricReferenceLux - clamped) > 0.5 else { return }
        recordUndoable(L("Étalonnage photométrique", "Photometric Calibration"), coalesceKey: coalesceKey) {
            photometricReferenceLux = clamped
            syncProjectorsToScene()
        }
    }

    /// Measures the exact distance in metres from the projector lens along its optical forward axis
    /// to the first physical 3D model surface encountered in the scene, if any.
    func actualSurfaceDistance(for projector: VideoProjector) -> Float? {
        guard let scene else { return nil }
        let (_, _, forward) = projector.opticalBasis()
        let maxReach = max(projector.throwDistance * 2.5, 120.0)
        return scene.raycastModelDistance(from: projector.position, direction: forward, maxDistance: maxReach)
    }

    func syncProjectorsToScene() {
        guard let scene else { return }
        scene.selectedVideoProjectorIndex = selectedVideoProjectorIndex
        scene.selectedVideoProjectorIndices = selectedVideoProjectorIndices
        scene.projectorsFrustumOnly = projectorsFrustumOnly
        scene.photometricSimulation = photometricSimulation
        scene.photometricReferenceLux = photometricReferenceLux
        scene.videoProjectors = videoProjectors
        viewport.requestRedraw()
    }

    // MARK: - Millumin Project & Conduite Lumière Import

    func importMilluminProject(from url: URL) {
        do {
            let parsed = try MilluminImporter.parseProjectFull(at: url)
            let imported = parsed.lights.map { $0.toVideoProjector() }
            guard !imported.isEmpty else { return }
            recordUndoable(L("Importer projet Millumin", "Import Millumin Project")) {
                let startIndex = videoProjectors.count
                videoProjectors.append(contentsOf: imported)
                milluminBoardName = parsed.boardName ?? url.deletingPathExtension().lastPathComponent
                milluminCues = parsed.cues
                if let firstActiveIdx = parsed.cues.firstIndex(where: { cue in
                    cue.valuesByLightName.values.contains(where: { dict in dict.values.contains(where: { $0 > 1.0 }) })
                }) {
                    activeMilluminCueIndex = firstActiveIdx
                } else if !parsed.cues.isEmpty {
                    activeMilluminCueIndex = 0
                } else {
                    activeMilluminCueIndex = nil
                }
                selectedVideoProjectorIndex = startIndex
                selectedVideoProjectorIndices = Set(startIndex..<videoProjectors.count)
                inspectorCategory = .stageLights
                showProjectorInspector = true
                syncProjectorsToScene()
            }
            if parsed.cues.isEmpty {
                flash(L("\(imported.count) lumière(s) importée(s) depuis Millumin", "\(imported.count) light(s) imported from Millumin"))
            } else {
                flash(L("\(imported.count) lumière(s) + \(parsed.cues.count) états de conduite importés depuis Millumin", "\(imported.count) light(s) + \(parsed.cues.count) lighting cues imported from Millumin"))
            }
        } catch {
            flash(L("Erreur d'import Millumin : \(error.localizedDescription)", "Millumin import error: \(error.localizedDescription)"))
        }
    }

    func promptImportMillumin() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if let ut = UTType(filenameExtension: "millumin") {
            panel.allowedContentTypes = [ut]
        }
        panel.message = L("Sélectionnez un projet Millumin (.millumin) à importer :", "Select a Millumin project (.millumin) to import:")
        panel.prompt = L("Importer", "Import")
        if panel.runModal() == .OK, let url = panel.url {
            importMilluminProject(from: url)
        }
    }

    /// Applies a lighting cue (`MilluminLightingCue`) from the imported Millumin conduite to all matching stage lights.
    func applyMilluminCue(at cueIndex: Int) {
        guard milluminCues.indices.contains(cueIndex) else { return }
        let cue = milluminCues[cueIndex]
        recordUndoable(L("Conduite Millumin : \(cue.title)", "Millumin Cue: \(cue.title)")) {
            activeMilluminCueIndex = cueIndex
            for i in videoProjectors.indices where videoProjectors[i].isStageLight {
                let name = videoProjectors[i].name
                if let vals = cue.valuesByLightName[name] {
                    _ = videoProjectors[i].applyMilluminCueValues(vals)
                }
            }
            syncProjectorsToScene()
        }
    }

    func nextMilluminCue() {
        guard !milluminCues.isEmpty else { return }
        let next = ((activeMilluminCueIndex ?? -1) + 1) % milluminCues.count
        applyMilluminCue(at: next)
    }

    func previousMilluminCue() {
        guard !milluminCues.isEmpty else { return }
        let cur = activeMilluminCueIndex ?? 0
        let prev = (cur - 1 + milluminCues.count) % milluminCues.count
        applyMilluminCue(at: prev)
    }

    // MARK: - Beam Shaping, Vertical Douche & DMX Patch Controls

    /// Aims the selected stage light(s) straight down (`Z = 0` vertically beneath `position.x, position.y`).
    func aimSelectedProjectorStraightDown() {
        guard !selectedVideoProjectorIndices.isEmpty else { return }
        recordUndoable(L("Pointer en douche verticale (90°)", "Aim Straight Down (90°)")) {
            let floorZ: Float = {
                let bMinZ = scene?.visibleBounds.min.z ?? skp?.boundsMin.z ?? 0
                let bMaxZ = scene?.visibleBounds.max.z ?? skp?.boundsMax.z ?? 3
                return (bMinZ <= 0.2 && bMaxZ >= 1.5) ? 0.0 : bMinZ
            }()
            for idx in selectedVideoProjectorIndices where videoProjectors.indices.contains(idx) {
                let pos = videoProjectors[idx].position
                let targetZ = (pos.z > floorZ + 0.2) ? floorZ : (pos.z - 3.0)
                videoProjectors[idx].target = SIMD3<Float>(pos.x, pos.y, targetZ)
            }
            syncProjectorsToScene()
        }
    }

    /// Sets the optical beam angle in degrees (`beamAngleDegrees`) on the selected stage light(s).
    func setSelectedStageLightBeamAngle(_ degrees: Float, coalesceKey: String? = "beam-angle") {
        guard !selectedVideoProjectorIndices.isEmpty else { return }
        recordUndoable(L("Ouverture faisceau (°)", "Beam Angle (°)"), coalesceKey: coalesceKey) {
            for idx in selectedVideoProjectorIndices where videoProjectors.indices.contains(idx) {
                videoProjectors[idx].beamAngleDegrees = degrees
            }
            syncProjectorsToScene()
        }
    }

    /// Assigns an Open Fixture Library (`OFLFixtureDefinition`) and mode (`OFLFixtureMode`) from `/Users/adrien/Library/Millumin/Light-fixtures` to the selected stage light(s).
    func setSelectedStageLightOFLFixture(definition: OFLFixtureDefinition, modeName: String? = nil) {
        guard !selectedVideoProjectorIndices.isEmpty else { return }
        let mode = definition.resolveMode(named: modeName ?? "") ?? definition.modes.first
        let newSpec = definition.toProjectorSpec(modeName: mode?.name)
        let chanNames = mode?.channels.map(\.name) ?? []
        let chanRoles = mode?.channels.map(\.role) ?? []
        recordUndoable(L("Fixture OFL : \(definition.displayName)", "OFL Fixture: \(definition.displayName)")) {
            for idx in selectedVideoProjectorIndices where videoProjectors.indices.contains(idx) {
                videoProjectors[idx].applySpec(newSpec)
                videoProjectors[idx].oflFixtureID = definition.id
                videoProjectors[idx].oflModeName = mode?.name
                videoProjectors[idx].dmxChannelNames = chanNames
                videoProjectors[idx].dmxChannelRoles = chanRoles
                if !chanRoles.isEmpty {
                    videoProjectors[idx].dmxMode = "ofl"
                }
            }
            syncProjectorsToScene()
        }
    }

    func setSelectedProjectorShutters(top: Float? = nil, bottom: Float? = nil, left: Float? = nil, right: Float? = nil) {
        guard !selectedVideoProjectorIndices.isEmpty else { return }
        recordUndoable(L("Réglage couteaux/volets", "Adjust Shutters/Barn Doors"), coalesceKey: "shutters") {
            for idx in selectedVideoProjectorIndices where videoProjectors.indices.contains(idx) {
                if let t = top { videoProjectors[idx].shutterTop = simd_clamp(t, 0.0, 1.0) }
                if let b = bottom { videoProjectors[idx].shutterBottom = simd_clamp(b, 0.0, 1.0) }
                if let l = left { videoProjectors[idx].shutterLeft = simd_clamp(l, 0.0, 1.0) }
                if let r = right { videoProjectors[idx].shutterRight = simd_clamp(r, 0.0, 1.0) }
            }
            syncProjectorsToScene()
        }
    }

    func setSelectedProjectorEdgeSoftness(_ value: Float) {
        guard !selectedVideoProjectorIndices.isEmpty else { return }
        recordUndoable(L("Netteté/Flou du faisceau", "Beam Edge Softness"), coalesceKey: "softness") {
            for idx in selectedVideoProjectorIndices where videoProjectors.indices.contains(idx) {
                videoProjectors[idx].edgeSoftness = simd_clamp(value, 0.0, 1.0)
            }
            syncProjectorsToScene()
        }
    }

    func setSelectedProjectorLightColor(_ color: SIMD3<Float>, white: Float? = 0.0) {
        guard !selectedVideoProjectorIndices.isEmpty else { return }
        recordUndoable(L("Couleur du projecteur", "Fixture Color"), coalesceKey: "lightColor") {
            for idx in selectedVideoProjectorIndices where videoProjectors.indices.contains(idx) {
                videoProjectors[idx].lightColor = simd_clamp(color, SIMD3<Float>(repeating: 0), SIMD3<Float>(repeating: 1))
                if let w = white {
                    videoProjectors[idx].whiteChannel = simd_clamp(w, 0.0, 1.0)
                }
            }
            syncProjectorsToScene()
        }
    }

    func setSelectedProjectorRGBW(
        r: Float? = nil,
        g: Float? = nil,
        b: Float? = nil,
        w: Float? = nil,
        coalesceKey: String? = "rgbw"
    ) {
        guard !selectedVideoProjectorIndices.isEmpty else { return }
        recordUndoable(L("Mélange RGBW", "RGBW Mix"), coalesceKey: coalesceKey) {
            for idx in selectedVideoProjectorIndices where videoProjectors.indices.contains(idx) {
                var lc = videoProjectors[idx].lightColor
                if let r { lc.x = simd_clamp(r, 0.0, 1.0) }
                if let g { lc.y = simd_clamp(g, 0.0, 1.0) }
                if let b { lc.z = simd_clamp(b, 0.0, 1.0) }
                videoProjectors[idx].lightColor = lc
                if let w {
                    videoProjectors[idx].whiteChannel = simd_clamp(w, 0.0, 1.0)
                }
            }
            syncProjectorsToScene()
        }
    }

    func setSelectedProjectorDMX(universe: Int? = nil, channel: Int? = nil, mode: String? = nil) {
        guard !selectedVideoProjectorIndices.isEmpty else { return }
        recordUndoable(L("Patch DMX", "DMX Patch")) {
            for idx in selectedVideoProjectorIndices where videoProjectors.indices.contains(idx) {
                if let u = universe { videoProjectors[idx].dmxUniverse = max(0, min(15, u)) }
                if let c = channel { videoProjectors[idx].dmxChannel = max(1, min(512, c)) }
                if let m = mode {
                    videoProjectors[idx].dmxMode = m
                    if m != "ofl" {
                        videoProjectors[idx].dmxChannelRoles = []
                        videoProjectors[idx].dmxChannelNames = []
                    }
                }
            }
            syncProjectorsToScene()
        }
    }

    /// Returns the most recent live DMX byte (`0 ... 255`) received via Art-Net for a 1-based DMX channel, or `nil` if no Art-Net packet was received for that universe.
    func liveDMXByte(universe: Int, channel1Based: Int) -> UInt8? {
        guard let bytes = latestDMXChannelsByUniverse[universe],
              channel1Based >= 1,
              channel1Based <= bytes.count else {
            return nil
        }
        return bytes[channel1Based - 1]
    }

    // MARK: - Art-Net Receiver & Realtime DMX Binding

    private func setupArtNetReceiver() {
        let receiver = ArtNetReceiver.shared
        receiver.onDMXPacket = { [weak self] packet in
            DispatchQueue.main.async {
                self?.handleArtNetPacket(packet)
            }
        }
        let started = receiver.start()
        artNetListening = started && receiver.isListening
    }

    private func handleArtNetPacket(_ packet: ArtNetDMXPacket) {
        artNetPacketCount = ArtNetReceiver.shared.packetCount
        isArtNetActive = true

        let bytes = packet.channels
        latestDMXChannelsByUniverse[packet.universe] = bytes
        if packet.universe < 16 {
            latestDMXChannelsByUniverse[packet.shortUniverse] = bytes
        }
        let normalized = bytes.map { Float($0) / 255.0 }

        var didChange = false
        for i in videoProjectors.indices {
            let p = videoProjectors[i]
            guard p.isEnabled else { continue }
            guard p.dmxUniverse == packet.universe || (packet.universe < 16 && p.dmxUniverse == packet.shortUniverse) else {
                continue
            }
            if videoProjectors[i].applyDMXValues(normalized) {
                didChange = true
            }
        }

        if didChange {
            scheduleProjectorSceneSync()
        }
    }

    private func scheduleProjectorSceneSync() {
        if artNetThrottler == nil {
            let item = DispatchWorkItem { [weak self] in
                self?.artNetThrottler = nil
                self?.syncProjectorsToScene()
            }
            artNetThrottler = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.016, execute: item)
        }
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
            },
            photometricSimulation: photometricSimulation,
            photometricReferenceLux: photometricReferenceLux
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
            if let photoSim = lighting.photometricSimulation {
                photometricSimulation = photoSim
            }
            if let refLux = lighting.photometricReferenceLux {
                photometricReferenceLux = refLux
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
        selectedVideoProjectorIndices = videoProjectors.isEmpty ? [] : [0]
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
            let parts: [String?]
            if skp.stats.splats > 0, skp.stats.faces == 0, skp.stats.edges == 0 {
                let unit = skp.splatCloud?.kind == .gaussianSplats ? L("splat", "splat") : L("point", "point")
                parts = [
                    info?.versionLabel ?? skp.fileInfo.versionLabel,
                    Format.count(skp.stats.splats, unit),
                    "\(Format.decimal(size.x)) × \(Format.decimal(size.y)) × \(Format.decimal(size.z)) m",
                ]
            } else {
                parts = [
                    info?.versionLabel ?? skp.fileInfo.versionLabel,
                    Format.count(skp.stats.faces, L("face", "face")),
                    Format.count(skp.stats.edges, L("arête", "edge")),
                    Format.count(skp.stats.instances, L("composant", "component")),
                    "\(Format.decimal(size.x)) × \(Format.decimal(size.y)) × \(Format.decimal(size.z)) m",
                ]
            }
            return parts.compactMap { $0 }.joined(separator: " · ")
        }
        var text = L("Chargement…", "Loading…")
        if case .loading(let progress?) = state {
            text += " \(progress.phase) · " + Format.count(progress.faces, L("face", "face"))
        }
        return text
    }

    // MARK: - Syphon Video Output

    func toggleSyphonOutput() {
        setSyphonOutputEnabled(!syphonOutputEnabled)
    }

    func setSyphonOutputEnabled(_ enabled: Bool) {
        guard syphonOutputEnabled != enabled else { return }
        syphonOutputEnabled = enabled
        Preferences.syphonOutputEnabled = enabled
        viewport.syphonOutputResolution = syphonOutputResolution
        viewport.syphonOutputEnabled = enabled
        if enabled {
            flash(L("Sortie Syphon activée (\(syphonOutputResolution.shortLabel))", "Syphon output enabled (\(syphonOutputResolution.shortLabel))"))
        } else {
            flash(L("Sortie Syphon désactivée", "Syphon output disabled"))
        }
    }

    func setSyphonOutputResolution(_ resolution: SyphonOutputResolution) {
        guard syphonOutputResolution != resolution else {
            if !syphonOutputEnabled {
                setSyphonOutputEnabled(true)
            }
            return
        }
        syphonOutputResolution = resolution
        Preferences.syphonOutputResolution = resolution
        viewport.syphonOutputResolution = resolution
        if !syphonOutputEnabled {
            setSyphonOutputEnabled(true)
        } else {
            flash(L("Syphon : \(resolution.label)", "Syphon: \(resolution.label)"))
        }
    }

    func stopSyphonOutput() {
        viewport.stopSyphonOutput()
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
