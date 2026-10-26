import SceneKit
import Metal
import SimpleSKPCore

/// Builds the SceneKit scene for a model. May be constructed off the main thread, right after `SKPReader.load`.
/// Root node rotated −90° about X (Z up → Y up). The instance tree is flattened: SketchUp shows an entity iff every layer
/// on its path is visible, so all faces sharing a layer set (the layers along their path) and a resolved material are
/// merged into one geometry in model space, and all edges of a layer set into one `.line` geometry — a few hundred draw
/// calls instead of one per instance. A layer set is built the first time all its layers are visible.
public final class ViewportScene: @unchecked Sendable {
    public let model: SKPModel
    public let scene: SCNScene
    /// The Z-up → Y-up node: everything from `SKPModel` (positions, transforms, camera) lives under it verbatim.
    public let modelRoot = SCNNode()
    /// Node the view attaches to its camera; it holds the low ambient fill (the sun and the sky do the lighting).
    public let fill = SCNNode()
    /// The former name of `fill` (D7 first had a headlight), kept for API compatibility.
    public var headlight: SCNNode { fill }
    /// The sun (D7): directional, elevation 45°, azimuth 135° clockwise from +X (from the south-west: the iso view, seen
    /// from the south-east, then shows two differently lit faces and the shadows in front), soft cascaded shadows.
    public let sun = SCNNode()
    /// Secondary sky counter-light opposite the sun so shadowed faces keep distinct tonal values.
    public let skyFill = SCNNode()

    public static let defaultSunAzimuthDegrees: Float = -135
    public static let defaultSunElevationDegrees: Float = 45

    public var sunAzimuthDegrees: Float = ViewportScene.defaultSunAzimuthDegrees {
        didSet { updateSunDirection() }
    }

    public var sunElevationDegrees: Float = ViewportScene.defaultSunElevationDegrees {
        didSet { updateSunDirection() }
    }

    /// Sun directional light power multiplier (`0.0 ... 3.0`, default `1.0` = 100%).
    public var sunIntensity: Float = Rendering.defaultSunIntensity {
        didSet { updateLightingModeAndPointLights() }
    }

    /// Ambient light power multiplier (`0.0 ... 2.0`, default `1.0` = 100%).
    /// Controls what remains when directional/point lights are set to `0 %`. Setting to `0` eliminates all residual ambient light.
    public var ambientIntensity: Float = Rendering.defaultAmbientIntensity {
        didSet { updateLightingModeAndPointLights() }
    }

    public func resetSun() {
        sunAzimuthDegrees = Self.defaultSunAzimuthDegrees
        sunElevationDegrees = Self.defaultSunElevationDegrees
        sunIntensity = Rendering.defaultSunIntensity
    }

    public var shadowsEnabled = true {
        didSet { updateLightingModeAndPointLights() }
    }

    public var lightingMode: LightingMode = .sun {
        didSet {
            if lightingMode == .point && pointLights.isEmpty {
                pointLights = detectedSceneLights.isEmpty
                    ? [ViewportPointLight(name: L("Lumière 1", "Light 1"), position: defaultPointLightPosition, intensity: 1.0, isFromScene: false)]
                    : detectedSceneLights
            }
            updateLightingModeAndPointLights()
        }
    }

    /// Scene lights detected from light components/groups in the `.skp` model, if any.
    public private(set) var detectedSceneLights: [ViewportPointLight] = []

    /// Active point lights in model space (metres, Z up).
    public var pointLights: [ViewportPointLight] = [] {
        didSet { updateLightingModeAndPointLights() }
    }

    /// Whether to draw the 3D wireframe position marker for point lights when in `.point` mode.
    public var showsPointLightGizmo: Bool = true {
        didSet { updateLightingModeAndPointLights() }
    }

    /// Center of the currently visible geometry in model coordinates (metres, Z up).
    public var defaultPointLightPosition: SIMD3<Float> {
        let b = visibleBounds
        return (b.min + b.max) * 0.5
    }

    public var backdropStyle: BackdropStyle = .architecturalSky {
        didSet { updateBackdrop() }
    }

    public var customBackdropColor: SIMD3<Float> = Rendering.defaultCustomBackdropColor {
        didSet { updateBackdrop() }
    }

    private func updateBackdrop() {
        scene.background.contents = Rendering.backdropImage(for: backdropStyle, customColor: customBackdropColor)
        updateEdgeMaterial()
    }

    /// Adapts the wireframe / edge material color to the active backdrop luminance and shading style so edges always remain contrasted.
    private func updateEdgeMaterial() {
        let effectiveShading: ShadingStyle = (model.fileInfo.isCAD || model.stats.faces == 0) ? .wireframe : shadingStyle
        let rgb = Rendering.contrastingEdgeColor(
            for: backdropStyle,
            customColor: customBackdropColor,
            shadingStyle: effectiveShading
        )
        let luma = 0.2126 * rgb.x + 0.7152 * rgb.y + 0.0722 * rgb.z
        // SceneKit's HDR camera (exposureOffset ≈ -0.62) scales `.constant` material RGB by ~0.65, so boost light edges to render crisp white.
        let hdrBoost: CGFloat = luma > 0.5 ? 1.48 : 1.0
        edgeMaterial.diffuse.contents = NSColor(
            srgbRed: CGFloat(rgb.x) * hdrBoost,
            green: CGFloat(rgb.y) * hdrBoost,
            blue: CGFloat(rgb.z) * hdrBoost,
            alpha: 1.0
        )
        let bgLuma = Rendering.backdropLuminance(for: backdropStyle, customColor: customBackdropColor)
        for (_, entry) in cadEdgeMaterials {
            Self.applyCADEdgeColor(entry.rawRGB, backdropLuminance: bgLuma, to: entry.material)
        }
    }

    private static func applyCADEdgeColor(_ rawRGB: SIMD3<Float>, backdropLuminance: Float, to material: SCNMaterial) {
        let adapted = Rendering.adaptedCADColor(rawRGB, backdropLuminance: backdropLuminance)
        let lineLuma = 0.2126 * adapted.x + 0.7152 * adapted.y + 0.0722 * adapted.z
        let hdrBoost: CGFloat = backdropLuminance < 0.54 ? 1.42 : (lineLuma > 0.5 ? 1.25 : 1.0)
        material.diffuse.contents = NSColor(
            srgbRed: CGFloat(adapted.x) * hdrBoost,
            green: CGFloat(adapted.y) * hdrBoost,
            blue: CGFloat(adapted.z) * hdrBoost,
            alpha: 1.0
        )
    }

    public var shadingStyle: ShadingStyle = .textured {
        didSet {
            guard shadingStyle != oldValue else { return }
            applyShadingStyle()
        }
    }

    public var showsGrid: Bool = false {
        didSet {
            guard showsGrid != oldValue else { return }
            updateGridNode()
        }
    }

    /// High: 3 cascades of 2048²; low: 1 of 1024², for a scene over 33 ms (the app decides; D7).
    public private(set) var shadowQualityIsHigh = true

    public func setShadowQuality(_ high: Bool) {
        shadowQualityIsHigh = high
        sun.light!.shadowCascadeCount = high ? 3 : 1
        sun.light!.shadowMapSize = high ? CGSize(width: 2048, height: 2048) : CGSize(width: 1024, height: 1024)
        if lightingMode == .point {
            updateLightingModeAndPointLights()
        }
    }

    /// The faces and edges drawn under one set of layers; `node` is nil until the set is first visible.
    final class LayerSet {
        let layers: [Int]
        /// Primary layer index in `model.layers`: prefers the most specific non-zero layer along the path, else `0`.
        var primaryLayer: Int { layers.last(where: { $0 != 0 }) ?? (layers.first ?? 0) }
        /// Indices into `placements` whose definition has meshes or edges on this exact set.
        var placements: [Int] = []
        var node: SCNNode?
        init(layers: [Int]) { self.layers = layers }
    }

    private struct EdgeChunk {
        var node: SCNNode
        var buffer: MTLBuffer
        var vertexCount: Int
        var set: LayerSet
        var boundsMin: SIMD3<Float>
        var boundsMax: SIMD3<Float>
    }

    /// A definition placed in the flattened tree (-1 = the root): model-space transform, material its unpainted faces
    /// inherit, sorted layers along its path (its own instance layer included).
    private struct Placement {
        var definition: Int
        var transform: simd_float4x4
        var material: Int?
        var layers: [Int]
    }

    private var materials: [Int: SCNMaterial] = [:]
    private var xrayMaterials: [ObjectIdentifier: SCNMaterial] = [:]
    private var images: [Int: NSImage?] = [:]
    private lazy var defaultMaterial = makeMaterial(nil, uvs: .none)
    private lazy var clayMaterial: SCNMaterial = {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = NSColor(srgbRed: 0.94, green: 0.92, blue: 0.89, alpha: 1)
        m.roughness.contents = 0.85
        m.metalness.contents = 0
        m.isDoubleSided = true
        return m
    }()
    private let edgeMaterial = SCNMaterial()
    private var cadEdgeMaterials: [UInt32: (rawRGB: SIMD3<Float>, material: SCNMaterial)] = [:]
    private var placements: [Placement] = []
    private(set) var layerSets: [[Int]: LayerSet] = [:]
    private var setsByLayer: [Int: [LayerSet]] = [:]
    private var faceNodes: [(node: SCNNode, material: SCNMaterial)] = []
    private var faceNodeSet: [ObjectIdentifier: LayerSet] = [:]
    private var edgeNodes: [SCNNode] = []
    private var edgeChunks: [EdgeChunk] = []
    private var gridNode: SCNNode?
    private let pointLightsRoot = SCNNode()
    private var hiddenLayers = Set<Int>()
    private var cachedVisibleBounds: (min: SIMD3<Float>, max: SIMD3<Float>)?
    public private(set) var activePulseLayers: Set<Int> = []
    private var pulseTimer: Timer?
    private var pulseRestoreActions: [() -> Void] = []
    public private(set) var hoveredLayers: Set<Int> = []
    private var hoverRestoreActions: [() -> Void] = []

    public init(model: SKPModel) {
        self.model = model
        self.scene = SCNScene()
        scene.background.contents = Rendering.skyImage(backdrop: true)
        scene.lightingEnvironment.contents = Rendering.skyImage()
        scene.lightingEnvironment.intensity = 1.05

        edgeMaterial.lightingModel = .constant
        edgeMaterial.readsFromDepthBuffer = true
        edgeMaterial.writesToDepthBuffer = false
        edgeMaterial.shaderModifiers = [.geometry: Self.edgeBias]
        updateEdgeMaterial()

        let start = CFAbsoluteTimeGetCurrent()
        hiddenLayers = Set(model.layers.indices.filter { !model.layers[$0].isVisible })
        modelRoot.name = "model"
        modelRoot.simdEulerAngles.x = -.pi / 2
        scene.rootNode.addChildNode(modelRoot)
        place(-1, transform: matrix_identity_float4x4, material: nil, layers: [])
        build(layerSets.values.filter(isVisible))
        if ProcessInfo.processInfo.environment["SIMPLESKP_TIMING"] == "1" {
            print(String(format: "ViewportScene: %.3f s, %d placements, %d layer sets (%d built), %d nodes", CFAbsoluteTimeGetCurrent() - start,
                         placements.count, layerSets.count, layerSets.values.filter { $0.node != nil }.count,
                         modelRoot.childNodes.reduce(0) { $0 + $1.childNodes.count }))
        }

        let ambient = SCNLight()
        ambient.type = .ambient
        ambient.intensity = 140 // interiors out of the sun are not pitch black
        fill.light = ambient

        let light = SCNLight()
        light.type = .directional
        light.intensity = 1050
        light.temperature = 5800
        light.castsShadow = true
        light.shadowMode = .forward
        light.shadowRadius = 3
        light.shadowSampleCount = 8
        light.automaticallyAdjustsShadowProjection = true
        light.shadowColor = NSColor(srgbRed: 0.05, green: 0.07, blue: 0.12, alpha: 0.48)
        sun.light = light
        sun.name = "sun"
        setShadowQuality(true)

        let counter = SCNLight()
        counter.type = .directional
        counter.intensity = 220
        counter.temperature = 7500
        counter.castsShadow = false
        skyFill.light = counter
        skyFill.name = "skyFill"

        pointLightsRoot.name = "pointLights"
        pointLightsRoot.isHidden = true
        modelRoot.addChildNode(sun)
        modelRoot.addChildNode(skyFill)
        modelRoot.addChildNode(pointLightsRoot)
        detectedSceneLights = Self.extractSceneLights(from: model, placements: placements, hiddenLayers: hiddenLayers)
        if !detectedSceneLights.isEmpty {
            pointLights = detectedSceneLights
        }
        updateSunDirection()
        updateShadowDistance()
        updateLightingModeAndPointLights()
    }

    private func updateSunDirection() {
        let azimuth = sunAzimuthDegrees * .pi / 180
        let elevation = max(5, min(88, sunElevationDegrees)) * .pi / 180
        let toSun = SIMD3(cos(azimuth) * cos(elevation), sin(azimuth) * cos(elevation), sin(elevation))
        let worldDir = modelRoot.simdConvertVector(-toSun, to: nil)
        let worldUp = modelRoot.simdConvertVector(SIMD3(0, 0, 1), to: nil)
        sun.simdLook(at: sun.simdWorldPosition + worldDir, up: worldUp, localFront: SCNNode.simdLocalFront)

        let counterAzimuth = azimuth + .pi
        let counterElevation: Float = 28 * .pi / 180
        let toCounter = SIMD3(cos(counterAzimuth) * cos(counterElevation), sin(counterAzimuth) * cos(counterElevation), sin(counterElevation))
        let counterWorldDir = modelRoot.simdConvertVector(-toCounter, to: nil)
        skyFill.simdLook(at: skyFill.simdWorldPosition + counterWorldDir, up: worldUp, localFront: SCNNode.simdLocalFront)
    }

    /// Shows or hides everything on a layer, by index into `model.layers`: a layer set is shown iff all its layers are.
    /// Sets shown for the first time are built here (main thread, like any scene edit).
    public func setLayer(_ index: Int, visible: Bool) {
        if Thread.isMainThread { MainActor.assumeIsolated { clearHoverVisuals(); cancelLayerPulse() } }
        if visible { hiddenLayers.remove(index) } else { hiddenLayers.insert(index) }
        cachedVisibleBounds = nil
        let sets = setsByLayer[index] ?? []
        build(sets.filter { $0.node == nil && isVisible($0) })
        for set in sets { set.node?.isHidden = !isVisible(set) }
        updateShadowDistance()
        if Thread.isMainThread { MainActor.assumeIsolated { applyHoverVisuals() } }
    }

    /// Applies a whole layer state at once (a scene change): only the sets visible in the end are built.
    public func setLayers(_ visible: [Bool]) {
        if Thread.isMainThread { MainActor.assumeIsolated { clearHoverVisuals(); cancelLayerPulse() } }
        hiddenLayers = Set(visible.indices.filter { !visible[$0] })
        cachedVisibleBounds = nil
        build(layerSets.values.filter { $0.node == nil && isVisible($0) })
        for set in layerSets.values { set.node?.isHidden = !isVisible(set) }
        updateShadowDistance()
        if Thread.isMainThread { MainActor.assumeIsolated { applyHoverVisuals() } }
    }

    /// Cascades spread over what is shown. The distance counts from the eye, which the framing puts up to ~2 diagonals
    /// away: D7's diagonal × 1.5 cut the far shadows off in the iso view, × 4 covers it.
    private func updateShadowDistance() {
        let bounds = visibleBounds
        sun.light!.maximumShadowDistance = CGFloat(simd_distance(bounds.min, bounds.max) * 4)
    }

    public var showsEdges: Bool = true {
        didSet {
            let visible = showsEdges || shadingStyle == .wireframe
            for node in edgeNodes { node.isHidden = !visible }
            cachedVisibleBounds = nil
        }
    }

    /// Bounds of what is shown, in model space (metres, Z up): hidden layer sets are left out.
    /// The model's bounds when nothing is shown. Main thread; recomputed after a layer change.
    public var visibleBounds: (min: SIMD3<Float>, max: SIMD3<Float>) {
        if let cachedVisibleBounds { return cachedVisibleBounds }
        var lo = SIMD3<Float>(repeating: .infinity), hi = SIMD3<Float>(repeating: -.infinity)
        for set in layerSets.values {
            guard let node = set.node, !node.isHidden else { continue }
            for child in node.childNodes where child.geometry != nil && (!child.isHidden || shadingStyle == .wireframe) { // merged geometries are in model space
                let (a, b) = child.geometry!.boundingBox
                lo = simd_min(lo, SIMD3(a)); hi = simd_max(hi, SIMD3(b))
            }
        }
        let bounds = lo.x <= hi.x ? (lo, hi) : (model.boundsMin, model.boundsMax)
        cachedVisibleBounds = bounds
        return bounds
    }

    private func isVisible(_ set: LayerSet) -> Bool { set.layers.allSatisfy { !hiddenLayers.contains($0) } }

    /// Layer sets whose geometry belongs to `targetLayers`.
    /// Since SketchUp/CAD instances placed on layer `L != 0` often contain geometry on `Layer0` (`set.layers == [0, L]`),
    /// selecting a non-zero layer matches any set containing it, while selecting `Layer0` (`[0]`) matches pure `[0]` sets.
    func matchingLayerSets(for targetLayers: Set<Int>) -> [LayerSet] {
        guard !targetLayers.isEmpty else { return [] }
        let nonZeroTargets = targetLayers.subtracting([0])
        if nonZeroTargets.isEmpty {
            let pureZero = layerSets.values.filter { $0.layers == [0] }
            if !pureZero.isEmpty { return Array(pureZero) }
            return layerSets.values.filter { $0.layers.contains(0) }
        }
        return layerSets.values.filter { set in
            if !nonZeroTargets.isDisjoint(with: set.layers) { return true }
            if targetLayers.contains(0) && set.layers == [0] { return true }
            return false
        }
    }

    /// Bounding box in model space (metres, Z up) of all geometry belonging to `targetLayers`.
    /// Builds matching layer sets if they have not been built yet so zooming to a layer works immediately.
    public func bounds(forLayers targetLayers: Set<Int>) -> (min: SIMD3<Float>, max: SIMD3<Float>)? {
        let matching = matchingLayerSets(for: targetLayers)
        guard !matching.isEmpty else { return nil }
        let unbuilt = matching.filter { $0.node == nil }
        if !unbuilt.isEmpty {
            build(unbuilt)
            for set in unbuilt { set.node?.isHidden = !isVisible(set) }
        }
        var lo = SIMD3<Float>(repeating: .infinity), hi = SIMD3<Float>(repeating: -.infinity)
        let visibleMatching = matching.filter { $0.node?.isHidden == false }
        let setsToMeasure = visibleMatching.isEmpty ? matching : visibleMatching
        for set in setsToMeasure {
            guard let node = set.node else { continue }
            for child in node.childNodes where child.geometry != nil {
                let (a, b) = child.geometry!.boundingBox
                lo = simd_min(lo, SIMD3(a))
                hi = simd_max(hi, SIMD3(b))
            }
        }
        guard lo.x <= hi.x else { return nil }
        return (lo, hi)
    }

    /// Applies a subtle hover highlight ("légère surbrillance") on visible faces and edges belonging to `targetLayers`.
    @MainActor
    public func setHoveredLayers(_ targetLayers: Set<Int>) {
        guard targetLayers != hoveredLayers else { return }
        hoveredLayers = targetLayers
        applyHoverVisuals()
    }

    @MainActor
    private func clearHoverVisuals() {
        let actions = hoverRestoreActions
        hoverRestoreActions.removeAll()
        for action in actions { action() }
    }

    @MainActor
    private func applyHoverVisuals() {
        clearHoverVisuals()
        guard !hoveredLayers.isEmpty, activePulseLayers.isEmpty else { return }
        let matching = matchingLayerSets(for: hoveredLayers).filter(isVisible)
        guard !matching.isEmpty else { return }

        let bgLuma = Rendering.backdropLuminance(for: backdropStyle, customColor: customBackdropColor)
        let isDarkBackdrop = bgLuma < 0.54

        // Check if the hovered layer's own CAD color is already warm yellow/orange/amber; if so, highlight in luminous cyan instead of amber-gold.
        var layerIsWarmYellow = false
        if let firstLayer = hoveredLayers.first,
           model.layers.indices.contains(firstLayer),
           let lc = model.layers[firstLayer].color {
            let adapted = Rendering.adaptedCADColor(SIMD3(lc.x, lc.y, lc.z), backdropLuminance: bgLuma)
            if adapted.x > 0.72 && adapted.y > 0.45 && adapted.z < 0.35 {
                layerIsWarmYellow = true
            }
        }

        // Non-clipping HDR highlight: at least one channel is low so tone-mapping after camera exposureOffset (-0.62) preserves a vivid hue.
        let hoverEdgeRGB: SIMD3<Float>
        let faceEmission: NSColor
        if isDarkBackdrop {
            if layerIsWarmYellow {
                hoverEdgeRGB = SIMD3<Float>(0.12, 1.48, 1.95) // Luminous sky-cyan
                faceEmission = NSColor(srgbRed: 0.08, green: 0.34, blue: 0.48, alpha: 1.0)
            } else {
                hoverEdgeRGB = SIMD3<Float>(1.85, 1.18, 0.12) // Luminous amber-gold
                faceEmission = NSColor(srgbRed: 0.44, green: 0.28, blue: 0.05, alpha: 1.0)
            }
        } else {
            hoverEdgeRGB = SIMD3<Float>(0.05, 0.46, 1.42) // Electric azure on light paper
            faceEmission = NSColor(srgbRed: 0.06, green: 0.24, blue: 0.52, alpha: 1.0)
        }

        let hoverEdgeMat = SCNMaterial()
        hoverEdgeMat.lightingModel = .constant
        hoverEdgeMat.diffuse.contents = NSColor(
            srgbRed: CGFloat(hoverEdgeRGB.x),
            green: CGFloat(hoverEdgeRGB.y),
            blue: CGFloat(hoverEdgeRGB.z),
            alpha: 1.0
        )
        hoverEdgeMat.readsFromDepthBuffer = false
        hoverEdgeMat.writesToDepthBuffer = false
        hoverEdgeMat.shaderModifiers = [.geometry: Self.edgeBias]

        var restoreActions: [() -> Void] = []

        for set in matching {
            guard let node = set.node, !node.isHidden else { continue }
            for child in node.childNodes {
                guard let geom = child.geometry else { continue }
                if child.categoryBitMask == Self.edgeCategory {
                    guard !child.isHidden else { continue }
                    let origMaterials = geom.materials
                    let origOrder = child.renderingOrder
                    restoreActions.append {
                        geom.materials = origMaterials
                        child.renderingOrder = origOrder
                    }
                    geom.materials = [hoverEdgeMat]
                    child.renderingOrder = 4
                } else if !child.isHidden, let baseMat = geom.firstMaterial {
                    let origMaterials = geom.materials
                    let hoverMat = baseMat.copy() as! SCNMaterial
                    hoverMat.emission.contents = faceEmission
                    restoreActions.append {
                        geom.materials = origMaterials
                    }
                    geom.materials = [hoverMat]
                }
            }
        }
        hoverRestoreActions = restoreActions
    }

    /// Picks the closest visible layer under the cursor ray in model space (testing both triangle faces and `.line` edges).
    public func pickLayer(
        from: SIMD3<Float>,
        direction: SIMD3<Float>,
        right: SIMD3<Float>,
        up: SIMD3<Float>,
        reach: Float,
        orthoTolerance: Float?,
        tanHalfFOV: Float,
        viewportHeight: Float,
        screenRadiusPoints: Float = 12.0
    ) -> Int? {
        var bestFaceT: Float = .infinity
        var bestFaceSet: LayerSet? = nil

        if shadingStyle != .wireframe {
            let to = from + direction * reach
            let hits = modelRoot.hitTestWithSegment(
                from: SCNVector3(from),
                to: SCNVector3(to),
                options: [
                    SCNHitTestOption.backFaceCulling.rawValue: false,
                    SCNHitTestOption.categoryBitMask.rawValue: 1,
                ]
            )
            for hit in hits {
                guard !hit.node.isHidden, hit.node.parent?.isHidden == false,
                      let set = faceNodeSet[ObjectIdentifier(hit.node)], isVisible(set) else { continue }
                let hitModel = modelRoot.simdConvertPosition(SIMD3<Float>(hit.worldCoordinates), from: nil)
                let t = simd_dot(hitModel - from, direction)
                if t >= 0, t < bestFaceT {
                    bestFaceT = t
                    bestFaceSet = set
                    break
                }
            }
        }

        var bestEdgeSet: LayerSet? = nil
        var bestEdgeScore: Float = .infinity

        if showsEdges || shadingStyle == .wireframe {
            let u: SIMD3<Float>
            let rProj = right - direction * simd_dot(right, direction)
            if simd_length_squared(rProj) > 1e-6 {
                u = simd_normalize(rProj)
            } else {
                let fallback = abs(direction.z) < 0.9 ? SIMD3<Float>(0, 0, 1) : SIMD3<Float>(1, 0, 0)
                u = simd_normalize(simd_cross(direction, fallback))
            }
            let v = simd_cross(direction, u)
            let perspScale = (2.0 * tanHalfFOV / max(1.0, viewportHeight)) * screenRadiusPoints
            let maxDepth = min(reach, bestFaceT < .infinity ? bestFaceT * 1.02 + 0.05 : reach)
            let maxTol = orthoTolerance ?? (maxDepth * perspScale)

            for chunk in edgeChunks {
                guard !chunk.node.isHidden, chunk.set.node?.isHidden == false, isVisible(chunk.set),
                      chunk.vertexCount >= 2 else { continue }
                let bMin = chunk.boundsMin - SIMD3<Float>(repeating: maxTol)
                let bMax = chunk.boundsMax + SIMD3<Float>(repeating: maxTol)
                guard Self.rayIntersectsAABB(origin: from, direction: direction, maxT: maxDepth + maxTol, min: bMin, max: bMax) else {
                    continue
                }

                let ptr = chunk.buffer.contents().bindMemory(to: Float.self, capacity: chunk.vertexCount * 3)
                let segCount = chunk.vertexCount / 2
                for sIdx in 0..<segCount {
                    let o0 = sIdx * 6
                    let p0 = SIMD3<Float>(ptr[o0], ptr[o0 + 1], ptr[o0 + 2]) - from
                    let p1 = SIMD3<Float>(ptr[o0 + 3], ptr[o0 + 4], ptr[o0 + 5]) - from

                    let z0 = simd_dot(p0, direction)
                    let z1 = simd_dot(p1, direction)
                    let zMax = max(z0, z1)
                    let zMin = min(z0, z1)
                    if zMax < 0 || zMin > maxDepth { continue }

                    let segTol = orthoTolerance ?? (max(zMax, 0.01) * perspScale)
                    let x0 = simd_dot(p0, u), x1 = simd_dot(p1, u)
                    if max(x0, x1) < -segTol || min(x0, x1) > segTol { continue }
                    let y0 = simd_dot(p0, v), y1 = simd_dot(p1, v)
                    if max(y0, y1) < -segTol || min(y0, y1) > segTol { continue }

                    let dx = x1 - x0, dy = y1 - y0
                    let lenSq = dx * dx + dy * dy
                    let s: Float = lenSq > 1e-12 ? simd_clamp(-(x0 * dx + y0 * dy) / lenSq, 0.0, 1.0) : 0.0
                    let cz = z0 + s * (z1 - z0)
                    if cz < 0 || cz > maxDepth { continue }

                    let tolAtZ = max(orthoTolerance ?? (max(cz, 0.01) * perspScale), 1e-5)
                    let cx = x0 + s * dx, cy = y0 + s * dy
                    let dist = sqrt(cx * cx + cy * cy)
                    guard dist <= tolAtZ else { continue }
                    guard cz <= bestFaceT + tolAtZ * 1.5 else { continue }

                    let score = cz + (dist / tolAtZ) * (tolAtZ * 2.0)
                    if score < bestEdgeScore {
                        bestEdgeScore = score
                        bestEdgeSet = chunk.set
                    }
                }
            }
        }

        if let bestEdgeSet {
            return bestEdgeSet.primaryLayer
        }
        return bestFaceSet?.primaryLayer
    }

    private static func rayIntersectsAABB(
        origin: SIMD3<Float>,
        direction: SIMD3<Float>,
        maxT: Float,
        min bMin: SIMD3<Float>,
        max bMax: SIMD3<Float>
    ) -> Bool {
        var tMin: Float = 0.0
        var tMax: Float = maxT
        for axis in 0..<3 {
            let o = origin[axis]
            let d = direction[axis]
            let lo = bMin[axis]
            let hi = bMax[axis]
            if abs(d) < 1e-7 {
                if o < lo || o > hi { return false }
            } else {
                let invD = 1.0 / d
                var t0 = (lo - o) * invD
                var t1 = (hi - o) * invD
                if t0 > t1 { swap(&t0, &t1) }
                tMin = max(tMin, t0)
                tMax = min(tMax, t1)
                if tMin > tMax { return false }
            }
        }
        return tMin <= tMax
    }

    /// Triggers a brief brightness pulse on all visible faces and edges belonging to `targetLayers` so the user can visually locate them.
    @MainActor
    public func pulseLayers(_ targetLayers: Set<Int>, onUpdate: (@MainActor () -> Void)? = nil) {
        clearHoverVisuals()
        cancelLayerPulse()
        let matching = matchingLayerSets(for: targetLayers).filter(isVisible)
        guard !matching.isEmpty else {
            applyHoverVisuals()
            return
        }
        let unbuilt = matching.filter { $0.node == nil }
        if !unbuilt.isEmpty {
            build(unbuilt)
            for set in unbuilt { set.node?.isHidden = !isVisible(set) }
        }

        let pulseEdgeMat = SCNMaterial()
        pulseEdgeMat.lightingModel = .constant
        pulseEdgeMat.readsFromDepthBuffer = false
        pulseEdgeMat.writesToDepthBuffer = false

        var pulseFaceMaterials: [SCNMaterial] = []
        var restoreActions: [() -> Void] = []

        for set in matching {
            guard let node = set.node, !node.isHidden else { continue }
            for child in node.childNodes {
                guard let geom = child.geometry else { continue }
                if child.categoryBitMask == Self.edgeCategory {
                    let origMaterials = geom.materials
                    let origOrder = child.renderingOrder
                    let origHidden = child.isHidden
                    restoreActions.append {
                        geom.materials = origMaterials
                        child.renderingOrder = origOrder
                        child.isHidden = origHidden
                    }
                    geom.materials = [pulseEdgeMat]
                    child.renderingOrder = 3
                    child.isHidden = false
                } else if let baseMat = geom.firstMaterial {
                    let origMaterials = geom.materials
                    let pulseMat = baseMat.copy() as! SCNMaterial
                    restoreActions.append {
                        geom.materials = origMaterials
                    }
                    geom.materials = [pulseMat]
                    pulseFaceMaterials.append(pulseMat)
                }
            }
        }

        guard !restoreActions.isEmpty else {
            applyHoverVisuals()
            return
        }
        activePulseLayers = targetLayers
        pulseRestoreActions = restoreActions

        let baseEdgeRGB = Rendering.contrastingEdgeColor(
            for: backdropStyle,
            customColor: customBackdropColor,
            shadingStyle: shadingStyle
        )
        let baseLuma = 0.2126 * baseEdgeRGB.x + 0.7152 * baseEdgeRGB.y + 0.0722 * baseEdgeRGB.z
        // Dark backdrop -> bright HDR white-cyan flash; light backdrop -> vivid luminous azure flash
        let peakEdgeRGB: SIMD3<Float> = baseLuma > 0.5
            ? SIMD3<Float>(1.85, 1.92, 2.05)
            : SIMD3<Float>(0.06, 0.52, 1.45)
        let startEdgeRGB = baseLuma > 0.5 ? baseEdgeRGB * 1.48 : baseEdgeRGB

        func applyEnvelope(_ env: Float) {
            let t = simd_clamp(env, 0, 1)
            let rgb = startEdgeRGB + (peakEdgeRGB - startEdgeRGB) * t
            pulseEdgeMat.diffuse.contents = NSColor(
                srgbRed: CGFloat(rgb.x),
                green: CGFloat(rgb.y),
                blue: CGFloat(rgb.z),
                alpha: 1.0
            )
            let em = CGFloat(t * 0.78)
            let emissionColor = NSColor(srgbRed: em * 0.92, green: em * 0.96, blue: em * 1.05, alpha: 1.0)
            for faceMat in pulseFaceMaterials {
                faceMat.emission.contents = emissionColor
            }
        }

        applyEnvelope(1.0)
        onUpdate?()

        let startTime = CACurrentMediaTime()
        let duration: CFTimeInterval = 0.55
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            MainActor.assumeIsolated {
                let elapsed = CACurrentMediaTime() - startTime
                if elapsed >= duration {
                    self.cancelLayerPulse()
                    onUpdate?()
                } else {
                    let progress = Float(elapsed / duration)
                    let env = pow(1.0 - progress, 1.75)
                    applyEnvelope(env)
                    onUpdate?()
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pulseTimer = timer
    }

    @MainActor
    public func cancelLayerPulse() {
        pulseTimer?.invalidate()
        pulseTimer = nil
        let actions = pulseRestoreActions
        pulseRestoreActions.removeAll()
        activePulseLayers.removeAll()
        for action in actions { action() }
        if !hoveredLayers.isEmpty {
            applyHoverVisuals()
        }
    }

    // MARK: - Flattening

    private func definition(_ index: Int) -> SKPModel.Definition { index < 0 ? model.root : model.definitions[index] }

    /// Records a placement and joins it to the layer sets of its meshes and edges, then recurses into its instances.
    private func place(_ index: Int, transform: simd_float4x4, material: Int?, layers: [Int]) {
        let definition = definition(index)
        let p = placements.count
        placements.append(Placement(definition: index, transform: transform, material: material, layers: layers))
        var joined: [[Int]] = []
        for layer in definition.meshes.map(\.layer) + definition.edges.filter({ !$0.positions.isEmpty }).map(\.layer) {
            let key = Self.adding(layer, to: layers)
            guard !joined.contains(key) else { continue }
            joined.append(key)
            layerSet(key).placements.append(p)
        }
        for instance in definition.children {
            place(instance.definition, transform: transform * instance.transform, material: instance.material ?? material,
                  layers: Self.adding(instance.layer, to: layers))
        }
    }

    private func layerSet(_ layers: [Int]) -> LayerSet {
        if let set = layerSets[layers] { return set }
        let set = LayerSet(layers: layers)
        layerSets[layers] = set
        for layer in layers { setsByLayer[layer, default: []].append(set) }
        return set
    }

    private static func adding(_ layer: Int, to layers: [Int]) -> [Int] {
        layers.contains(layer) ? layers : (layers + [layer]).sorted()
    }

    // MARK: - Merging

    /// Faces of one placement's mesh (or one edge set when `material` is nil) going into a merged geometry.
    private struct Piece { var placement: Int; var item: Int }

    /// One merged geometry to build: a material (nil = edges), whether it carries UVs, its pieces and sizes.
    private struct Chunk {
        var set: LayerSet
        var material: SCNMaterial?
        var edgeMaterial: SCNMaterial? = nil
        var textured = false
        var pieces: [Piece] = []
        var vertices = 0
        var indices = 0
    }

    /// Edge nodes' category: a pick passes `.categoryBitMask: 1` (faces) so lines, hit with a tolerance, never win.
    public static let edgeCategory = 2

    /// Chunks stay under this many triangles (or segments): spatially compact pieces keep frustum culling, shadow
    /// cascades and hit tests cheap, for a few more draw calls.
    static var chunkLimit = 250_000

    /// Resolves the raw sRGB color (`0…1`) for an edge set in a CAD model (`model.fileInfo.isCAD`), checking:
    /// 1) edge-specific material (`edgeSet.material`), 2) enclosing instance material (`placement.material`),
    /// 3) the edge's own non-zero layer color (`edgeSet.layer`), 4) the path's primary layer color (`set.primaryLayer`).
    private func resolvedCADEdgeRGB(edgeSet: SKPModel.EdgeSet, placement: Placement, set: LayerSet) -> SIMD3<Float> {
        if let matIdx = edgeSet.material ?? placement.material, model.materials.indices.contains(matIdx) {
            let c = model.materials[matIdx].color
            return SIMD3<Float>(c.x, c.y, c.z)
        }
        let effectiveLayer = (edgeSet.layer != 0) ? edgeSet.layer : set.primaryLayer
        if model.layers.indices.contains(effectiveLayer), let lc = model.layers[effectiveLayer].color {
            return SIMD3<Float>(lc.x, lc.y, lc.z)
        }
        if model.layers.indices.contains(edgeSet.layer), let lc = model.layers[edgeSet.layer].color {
            return SIMD3<Float>(lc.x, lc.y, lc.z)
        }
        return SIMD3<Float>(1, 1, 1)
    }

    private func cadEdgeMaterial(for rawRGB: SIMD3<Float>) -> SCNMaterial {
        let r8 = UInt32(simd_clamp(rawRGB.x * 255.0, 0, 255).rounded())
        let g8 = UInt32(simd_clamp(rawRGB.y * 255.0, 0, 255).rounded())
        let b8 = UInt32(simd_clamp(rawRGB.z * 255.0, 0, 255).rounded())
        let key = (r8 << 16) | (g8 << 8) | b8
        if let cached = cadEdgeMaterials[key] {
            return cached.material
        }
        let mat = SCNMaterial()
        mat.lightingModel = .constant
        mat.readsFromDepthBuffer = true
        mat.writesToDepthBuffer = false
        mat.shaderModifiers = [.geometry: Self.edgeBias]
        let bgLuma = Rendering.backdropLuminance(for: backdropStyle, customColor: customBackdropColor)
        Self.applyCADEdgeColor(rawRGB, backdropLuminance: bgLuma, to: mat)
        cadEdgeMaterials[key] = (rawRGB, mat)
        return mat
    }

    /// Builds the nodes of `sets`: grouping (serial: materials are resolved and cached), merging (parallel), nodes (serial).
    private func build(_ sets: [LayerSet]) {
        guard !sets.isEmpty else { return }
        let useCADEdgeColors = model.fileInfo.isCAD
        var chunks: [Chunk] = []
        for set in sets {
            var groups: [ObjectIdentifier: [(piece: Piece, key: UInt32, size: Int, vertices: Int)]] = [:]
            var groupMaterial: [ObjectIdentifier: SCNMaterial] = [:]
            var edges: [(piece: Piece, key: UInt32, size: Int, vertices: Int)] = []
            var cadEdgeGroups: [ObjectIdentifier: [(piece: Piece, key: UInt32, size: Int, vertices: Int)]] = [:]
            var cadEdgeGroupMaterial: [ObjectIdentifier: SCNMaterial] = [:]
            for p in set.placements {
                let placement = placements[p], definition = definition(placement.definition)
                for (i, mesh) in definition.meshes.enumerated() where Self.adding(mesh.layer, to: placement.layers) == set.layers {
                    let material = resolvedMaterial(mesh, inherited: placement.material)
                    let id = ObjectIdentifier(material)
                    groupMaterial[id] = material
                    groups[id, default: []].append((Piece(placement: p, item: i), spatialKey(mesh.positions.first ?? .zero, placement.transform),
                                                    mesh.indices.count / 3, mesh.positions.count))
                }
                for (i, edgeSet) in definition.edges.enumerated()
                where !edgeSet.positions.isEmpty && Self.adding(edgeSet.layer, to: placement.layers) == set.layers {
                    let item = (Piece(placement: p, item: i), spatialKey(edgeSet.positions.first ?? .zero, placement.transform),
                                edgeSet.positions.count / 2, edgeSet.positions.count)
                    if useCADEdgeColors {
                        let rawRGB = resolvedCADEdgeRGB(edgeSet: edgeSet, placement: placement, set: set)
                        let edgeMat = cadEdgeMaterial(for: rawRGB)
                        let id = ObjectIdentifier(edgeMat)
                        cadEdgeGroupMaterial[id] = edgeMat
                        cadEdgeGroups[id, default: []].append(item)
                    } else {
                        edges.append(item)
                    }
                }
            }
            func split(_ items: [(piece: Piece, key: UInt32, size: Int, vertices: Int)], _ material: SCNMaterial?, edgeMaterial: SCNMaterial? = nil) {
                let textured = material?.diffuse.contents is NSImage
                var chunk = Chunk(set: set, material: material, edgeMaterial: edgeMaterial, textured: textured)
                for item in items.sorted(by: { $0.key < $1.key }) {
                    if chunk.indices > 0, chunk.indices + item.size * 3 > Self.chunkLimit * 3 {
                        chunks.append(chunk)
                        chunk = Chunk(set: set, material: material, edgeMaterial: edgeMaterial, textured: textured)
                    }
                    chunk.pieces.append(item.piece)
                    chunk.vertices += item.vertices
                    chunk.indices += item.size * (material == nil ? 2 : 3)
                }
                if !chunk.pieces.isEmpty { chunks.append(chunk) }
            }
            for (id, items) in groups { split(items, groupMaterial[id]) }
            if useCADEdgeColors {
                for (id, items) in cadEdgeGroups { split(items, nil, edgeMaterial: cadEdgeGroupMaterial[id]) }
            } else {
                split(edges, nil)
            }
        }

        if ProcessInfo.processInfo.environment["SIMPLESKP_TIMING"] == "1" {
            let faces = chunks.filter { $0.material != nil }, edges = chunks.filter { $0.material == nil }
            let bytes = faces.reduce(0) { $0 + $1.vertices * ($1.textured ? 32 : 24) + $1.indices * 4 } + edges.reduce(0) { $0 + $1.vertices * 12 }
            let largest = Dictionary(grouping: faces) { ObjectIdentifier($0.set) }.values.map { $0.reduce(0) { $0 + $1.indices / 3 } }.max() ?? 0
            print(String(format: "ViewportScene: building %d layer sets, %d chunks, %.2f M triangles (largest set %.2f M), %.2f M segments, %.0f MB",
                         sets.count, chunks.count, Double(faces.reduce(0) { $0 + $1.indices / 3 }) / 1e6, Double(largest) / 1e6,
                         Double(edges.reduce(0) { $0 + $1.vertices / 2 }) / 1e6, Double(bytes) / 1_048_576))
        }
        var merged = [Merged?](repeating: nil, count: chunks.count)
        merged.withUnsafeMutableBufferPointer { out in
            let out = out // the closure below may not capture an inout parameter
            DispatchQueue.concurrentPerform(iterations: chunks.count) { i in
                out[i] = chunks[i].material == nil ? mergeEdges(chunks[i]) : mergeFaces(chunks[i])
            }
        }

        for set in sets {
            let node = SCNNode()
            node.name = set.layers.map(String.init).joined(separator: ",")
            set.node = node
            modelRoot.addChildNode(node)
        }
        for (chunk, data) in zip(chunks, merged) {
            let mergedData = data!
            let child = SCNNode(geometry: geometry(chunk, mergedData))
            if let material = chunk.material {
                let transparent = Self.isTransparentMaterial(material)
                child.castsShadow = !transparent
                child.renderingOrder = transparent ? 2 : 0
                faceNodes.append((child, material))
                faceNodeSet[ObjectIdentifier(child)] = chunk.set
                if shadingStyle != .textured {
                    applyShadingStyle(to: child, original: material)
                }
            } else {
                child.categoryBitMask = Self.edgeCategory
                child.castsShadow = false
                child.renderingOrder = 1 // after opaque faces (0), before transparent glass (2)
                child.isHidden = !(showsEdges || shadingStyle == .wireframe)
                edgeNodes.append(child)
                edgeChunks.append(EdgeChunk(
                    node: child,
                    buffer: mergedData.positions,
                    vertexCount: chunk.vertices,
                    set: chunk.set,
                    boundsMin: mergedData.boundsMin,
                    boundsMax: mergedData.boundsMax
                ))
            }
            chunk.set.node!.addChildNode(child)
        }
    }

    private static func isTransparentMaterial(_ material: SCNMaterial) -> Bool {
        material.transparency < 1 || !material.writesToDepthBuffer
    }

    private func applyShadingStyle() {
        if Thread.isMainThread {
            MainActor.assumeIsolated { clearHoverVisuals(); cancelLayerPulse() }
        }
        for (node, material) in faceNodes {
            applyShadingStyle(to: node, original: material)
        }
        let edgesVisible = showsEdges || shadingStyle == .wireframe
        for node in edgeNodes {
            node.isHidden = !edgesVisible
        }
        updateEdgeMaterial()
        if Thread.isMainThread {
            MainActor.assumeIsolated { applyHoverVisuals() }
        }
    }

    private func applyShadingStyle(to node: SCNNode, original: SCNMaterial) {
        let transparent = Self.isTransparentMaterial(original)
        switch shadingStyle {
        case .textured:
            node.isHidden = false
            node.geometry?.materials = [original]
            node.castsShadow = !transparent
            node.renderingOrder = transparent ? 2 : 0
        case .clay:
            node.isHidden = false
            // Keep transparent glass transparent even in clay mode
            node.geometry?.materials = [transparent ? original : clayMaterial]
            node.castsShadow = !transparent
            node.renderingOrder = transparent ? 2 : 0
        case .xray:
            node.isHidden = false
            node.geometry?.materials = [xrayMaterial(for: original)]
            node.castsShadow = false
            node.renderingOrder = 2
        case .wireframe:
            node.isHidden = true
            node.geometry?.materials = [original]
        }
    }

    private func xrayMaterial(for original: SCNMaterial) -> SCNMaterial {
        let id = ObjectIdentifier(original)
        if let cached = xrayMaterials[id] { return cached }
        let m = original.copy() as! SCNMaterial
        m.transparency = min(original.transparency, 0.36)
        m.transparencyMode = .dualLayer
        m.writesToDepthBuffer = false
        m.shaderModifiers = [.surface: "_surface.diffuse.a = min(_surface.diffuse.a, 0.36);"]
        xrayMaterials[id] = m
        return m
    }

    private func updateGridNode() {
        if !showsGrid {
            gridNode?.isHidden = true
            return
        }
        if let gridNode {
            gridNode.isHidden = false
            return
        }
        let node = buildGridNode()
        gridNode = node
        modelRoot.addChildNode(node)
    }

    /// Reference ground grid and SketchUp-style X (Red), Y (Green), Z (Blue) axes at the origin.
    /// Uses `.line` primitives with `edgeCategory` so hit tests ignore it and `testMaterialsArePhysicallyBased` is unaffected.
    private func buildGridNode() -> SCNNode {
        let root = SCNNode()
        root.name = "referenceGrid"
        let span = max(simd_length(model.boundsMax - model.boundsMin), 2.0)
        let rawStep = pow(10, floor(log10(max(span / 12, 0.1))))
        let step: Float = span / rawStep > 25 ? rawStep * 2 : (span / rawStep < 8 ? rawStep / 2 : rawStep)
        let halfExtent = ceil((span * 0.85) / (step * 5)) * (step * 5)
        let cx = ((model.boundsMin.x + model.boundsMax.x) * 0.5 / (step * 5)).rounded() * (step * 5)
        let cy = ((model.boundsMin.y + model.boundsMax.y) * 0.5 / (step * 5)).rounded() * (step * 5)
        let z: Float = (model.boundsMin.z <= 0.1 && model.boundsMax.z >= -0.1) ? 0 : model.boundsMin.z

        var minorPts: [SIMD3<Float>] = []
        var majorPts: [SIMD3<Float>] = []
        let count = Int((halfExtent / step).rounded())
        for i in -count...count {
            let offset = Float(i) * step
            let x = cx + offset
            let y = cy + offset
            let isMajor = (i % 5 == 0)
            let xStart = SIMD3<Float>(x, cy - halfExtent, z)
            let xEnd = SIMD3<Float>(x, cy + halfExtent, z)
            let yStart = SIMD3<Float>(cx - halfExtent, y, z)
            let yEnd = SIMD3<Float>(cx + halfExtent, y, z)
            if isMajor {
                majorPts.append(contentsOf: [xStart, xEnd, yStart, yEnd])
            } else {
                minorPts.append(contentsOf: [xStart, xEnd, yStart, yEnd])
            }
        }

        func lineNode(_ points: [SIMD3<Float>], color: NSColor) -> SCNNode {
            let buf = Self.buffer(points.count * 12)
            let ptr = buf.contents().bindMemory(to: Float.self, capacity: points.count * 3)
            for (idx, p) in points.enumerated() {
                ptr[idx * 3] = p.x; ptr[idx * 3 + 1] = p.y; ptr[idx * 3 + 2] = p.z
            }
            let src = SCNGeometrySource(buffer: buf, vertexFormat: .float3, semantic: .vertex, vertexCount: points.count, dataOffset: 0, dataStride: 12)
            let elem = SCNGeometryElement(data: nil, primitiveType: .line, primitiveCount: points.count / 2, bytesPerIndex: 4)
            let geom = SCNGeometry(sources: [src], elements: [elem])
            let mat = SCNMaterial()
            mat.lightingModel = .constant
            mat.diffuse.contents = color
            mat.readsFromDepthBuffer = true
            mat.writesToDepthBuffer = false
            geom.materials = [mat]
            let n = SCNNode(geometry: geom)
            n.categoryBitMask = Self.edgeCategory
            n.castsShadow = false
            n.renderingOrder = -1
            return n
        }

        if !minorPts.isEmpty {
            root.addChildNode(lineNode(minorPts, color: NSColor(white: 0.5, alpha: 0.18)))
        }
        if !majorPts.isEmpty {
            root.addChildNode(lineNode(majorPts, color: NSColor(white: 0.55, alpha: 0.34)))
        }
        let axisLen = max(halfExtent * 0.6, step * 4)
        let origin = SIMD3<Float>(0, 0, z + 0.002)
        root.addChildNode(lineNode([origin, origin + SIMD3(axisLen, 0, 0)], color: NSColor(srgbRed: 0.95, green: 0.32, blue: 0.30, alpha: 0.85)))
        root.addChildNode(lineNode([origin, origin + SIMD3(0, axisLen, 0)], color: NSColor(srgbRed: 0.38, green: 0.80, blue: 0.42, alpha: 0.85)))
        root.addChildNode(lineNode([origin, origin + SIMD3(0, 0, axisLen * 0.6)], color: NSColor(srgbRed: 0.35, green: 0.60, blue: 0.96, alpha: 0.85)))
        return root
    }

    // MARK: - Point Lights & Scene Light Detection

    private func updateLightingModeAndPointLights() {
        let isSun = (lightingMode == .sun)
        let sunGain = CGFloat(pow(Double(max(0, sunIntensity)), 1.25))
        let ambientGain = CGFloat(pow(Double(max(0, ambientIntensity)), 1.25))

        sun.light?.intensity = isSun ? (1050.0 * sunGain) : 0
        sun.light?.castsShadow = isSun && shadowsEnabled && sunIntensity > 0.001
        skyFill.light?.intensity = isSun ? (220.0 * ambientGain) : (45.0 * ambientGain)

        guard !isSun else {
            scene.lightingEnvironment.intensity = 1.05 * ambientGain
            fill.light?.intensity = 140.0 * ambientGain
            pointLightsRoot.isHidden = true
            pointLightsRoot.childNodes.forEach { $0.removeFromParentNode() }
            return
        }
        pointLightsRoot.isHidden = false

        // Ambient light in point-light mode is directly controlled by `ambientIntensity` (0% = pitch black when lights are at 0%).
        scene.lightingEnvironment.intensity = 0.28 * ambientGain
        fill.light?.intensity = 65.0 * ambientGain

        let bounds = visibleBounds
        let size = bounds.max - bounds.min
        let diagonal = max(simd_distance(bounds.min, bounds.max), 1.0)
        let minSpan = max(min(size.x, min(size.y, size.z)), 0.5)
        let refRadius = max(min(minSpan * 0.48, diagonal * 0.22), 0.5)
        // SceneKit's omni light uses 1000 as unit reference and attenuates over startDist..endDist (independent of world scale).
        let baseIntensity: CGFloat = 2400.0
        let startDist = CGFloat(refRadius * 0.08)
        let endDist = CGFloat(diagonal * 0.65)
        let gizmoRadius = max(diagonal * 0.018, 0.06)

        if pointLightsRoot.childNodes.count != pointLights.count {
            pointLightsRoot.childNodes.forEach { $0.removeFromParentNode() }
            // Local Euler angles mapping `SCNNode.simdLocalFront` (0, 0, -1) to the 6 cube faces (-Z, +Z, +Y, -Y, +X, -X)
            let cubeEulers: [SIMD3<Float>] = [
                SIMD3(0, 0, 0),          // -Z (down)
                SIMD3(.pi, 0, 0),        // +Z (up)
                SIMD3(.pi / 2, 0, 0),    // +Y
                SIMD3(-.pi / 2, 0, 0),   // -Y
                SIMD3(0, -.pi / 2, 0),   // +X
                SIMD3(0, .pi / 2, 0),    // -X
            ]
            for item in pointLights {
                let holder = SCNNode()

                // SceneKit's `.omni` light does not support `castsShadow` natively; we use a 6-way `.spot` cube rig
                // (-Z, +Z, +Y, -Y, +X, -X) so each point light illuminates all 360° and casts true perspective shadows when `shadowsEnabled` is true.
                let shadowRig = SCNNode()
                shadowRig.name = "pointLightShadowRig"
                for (faceIdx, euler) in cubeEulers.enumerated() {
                    let spotNode = SCNNode()
                    spotNode.name = "spotFace\(faceIdx)"
                    spotNode.simdEulerAngles = euler
                    let spot = SCNLight()
                    spot.type = .spot
                    spot.temperature = 5400
                    spot.attenuationFalloffExponent = 1.85
                    spot.spotInnerAngle = 82
                    spot.spotOuterAngle = 110
                    spot.castsShadow = shadowsEnabled
                    spot.shadowMode = .forward
                    spot.shadowRadius = 2.8
                    spot.automaticallyAdjustsShadowProjection = true
                    spotNode.light = spot
                    shadowRig.addChildNode(spotNode)
                }
                holder.addChildNode(shadowRig)

                let gizmo = Self.makePointLightGizmo(radius: gizmoRadius, isFromScene: item.isFromScene)
                gizmo.name = "pointLightGizmo"
                holder.addChildNode(gizmo)
                pointLightsRoot.addChildNode(holder)
            }
        }

        let shadowMapDim = shadowQualityIsHigh ? 1024 : 512
        let shadowSamples = shadowQualityIsHigh ? 8 : 4
        let zNear = CGFloat(max(minSpan * 0.02, 0.05))
        let zFar = CGFloat(max(diagonal * 1.4, 8.0))

        for (index, item) in pointLights.enumerated() where index < pointLightsRoot.childNodes.count {
            let holder = pointLightsRoot.childNodes[index]
            holder.name = item.name
            holder.simdPosition = item.position
            let gain = pow(Double(max(0, item.intensity)), 1.35)
            let flux = baseIntensity * CGFloat(gain)
            // Cast 6-way cube shadows for the first 2 active point lights when `shadowsEnabled` is true
            let useCubeShadows = shadowsEnabled && item.intensity > 0.001 && index < 2

            if let shadowRig = holder.childNode(withName: "pointLightShadowRig", recursively: false) {
                for spotNode in shadowRig.childNodes {
                    guard let spot = spotNode.light else { continue }
                    spot.castsShadow = useCubeShadows
                    spot.intensity = flux * 0.86
                    spot.attenuationStartDistance = startDist
                    spot.attenuationEndDistance = endDist
                    spot.shadowMapSize = CGSize(width: shadowMapDim, height: shadowMapDim)
                    spot.shadowSampleCount = shadowSamples
                    spot.zNear = zNear
                    spot.zFar = zFar
                }
            }
            if let gizmo = holder.childNode(withName: "pointLightGizmo", recursively: false) {
                gizmo.isHidden = !showsPointLightGizmo
            }
        }
    }

    /// Builds a 3D wireframe octahedron + crosshair marker using `.line` segments (`edgeCategory`) so hit-testing and
    /// triangle-material tests ignore it.
    private static func makePointLightGizmo(radius r: Float, isFromScene: Bool) -> SCNNode {
        let px = SIMD3<Float>(r, 0, 0), nx = SIMD3<Float>(-r, 0, 0)
        let py = SIMD3<Float>(0, r, 0), ny = SIMD3<Float>(0, -r, 0)
        let pz = SIMD3<Float>(0, 0, r), nz = SIMD3<Float>(0, 0, -r)
        let c = r * 1.65
        let points: [SIMD3<Float>] = [
            // Octahedron diamond
            pz, px, pz, nx, pz, py, pz, ny,
            nz, px, nz, nx, nz, py, nz, ny,
            px, py, py, nx, nx, ny, ny, px,
            // 3D ray crosshairs
            SIMD3(-c, 0, 0), SIMD3(c, 0, 0),
            SIMD3(0, -c, 0), SIMD3(0, c, 0),
            SIMD3(0, 0, -c), SIMD3(0, 0, c),
        ]
        let buf = buffer(points.count * 12)
        let ptr = buf.contents().bindMemory(to: Float.self, capacity: points.count * 3)
        for (i, p) in points.enumerated() {
            ptr[i * 3] = p.x; ptr[i * 3 + 1] = p.y; ptr[i * 3 + 2] = p.z
        }
        let src = SCNGeometrySource(buffer: buf, vertexFormat: .float3, semantic: .vertex, vertexCount: points.count, dataOffset: 0, dataStride: 12)
        let elem = SCNGeometryElement(data: nil, primitiveType: .line, primitiveCount: points.count / 2, bytesPerIndex: 4)
        let geom = SCNGeometry(sources: [src], elements: [elem])
        let mat = SCNMaterial()
        mat.lightingModel = .constant
        mat.diffuse.contents = isFromScene
            ? NSColor(srgbRed: 0.36, green: 0.88, blue: 0.90, alpha: 1)
            : NSColor(srgbRed: 1.00, green: 0.72, blue: 0.30, alpha: 1)
        mat.readsFromDepthBuffer = false // always visible even behind walls so user can see where the light is
        mat.writesToDepthBuffer = false
        geom.materials = [mat]
        let node = SCNNode(geometry: geom)
        node.categoryBitMask = edgeCategory
        node.castsShadow = false
        node.renderingOrder = 2
        return node
    }

    /// Detects light fixtures / point lights placed in the `.skp` scene by inspecting component/group/layer names.
    private static func extractSceneLights(from model: SKPModel, placements: [Placement], hiddenLayers: Set<Int>) -> [ViewportPointLight] {
        let keywords = [
            "pointlight", "point_light", "point light", "omnilight", "omni_light",
            "vraylight", "enscape", "lumiere", "lumière", "ampoule", "projecteur",
            "spot", "fresnel", "decoupe", "découpe", "svoboda", "light", "lamp", "bulb",
        ]
        let excluded = ["lightweight", "highlight", "daylight", "skylight", "moonlight"]

        func matchesLightName(_ raw: String) -> Bool {
            let lower = raw.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current).lowercased()
            guard !lower.isEmpty else { return false }
            if excluded.contains(where: { lower.contains($0) }) { return false }
            for kw in keywords {
                if lower == kw || lower.hasPrefix(kw + " ") || lower.hasPrefix(kw + "_") || lower.hasPrefix(kw + "-")
                    || lower.hasSuffix(" " + kw) || lower.hasSuffix("_" + kw) || lower.hasSuffix("-" + kw)
                    || lower.contains(" " + kw + " ") || lower.contains("_" + kw + "_") {
                    return true
                }
            }
            return false
        }

        var results: [ViewportPointLight] = []
        for placement in placements where placement.definition >= 0 {
            guard placement.layers.allSatisfy({ !hiddenLayers.contains($0) }) else { continue }
            let def = model.definitions[placement.definition]
            let layerNames = placement.layers.compactMap { model.layers.indices.contains($0) ? model.layers[$0].name : nil }
            let isLight = matchesLightName(def.name) || layerNames.contains(where: matchesLightName)
            guard isLight else { continue }

            // Compute local bounding box of this definition's meshes/edges so we reject huge room/rig groups
            var lo = SIMD3<Float>(repeating: .infinity), hi = SIMD3<Float>(repeating: -.infinity)
            for m in def.meshes { for p in m.positions { lo = simd_min(lo, p); hi = simd_max(hi, p) } }
            for e in def.edges { for p in e.positions { lo = simd_min(lo, p); hi = simd_max(hi, p) } }
            let localCenter: SIMD3<Float>
            if lo.x <= hi.x {
                let worldMin = placement.transform * SIMD4(lo, 1)
                let worldMax = placement.transform * SIMD4(hi, 1)
                let span = simd_distance(SIMD3(worldMin.x, worldMin.y, worldMin.z), SIMD3(worldMax.x, worldMax.y, worldMax.z))
                guard span <= 3.5 else { continue } // A single light fixture is under 3.5 m
                localCenter = (lo + hi) * 0.5
            } else {
                localCenter = .zero
            }
            let wp = placement.transform * SIMD4(localCenter, 1)
            let pos = SIMD3<Float>(wp.x, wp.y, wp.z)
            if results.contains(where: { simd_distance($0.position, pos) < 0.08 }) { continue }
            let label = def.name.isEmpty ? L("Lumière scène \(results.count + 1)", "Scene light \(results.count + 1)") : def.name
            results.append(ViewportPointLight(name: label, position: pos, intensity: 1.0, isFromScene: true))
            if results.count >= 12 { break }
        }
        return results
    }

    /// Morton order of a point's model-space position on a 1024³ grid over the model's bounds.
    private func spatialKey(_ point: SIMD3<Float>, _ transform: simd_float4x4) -> UInt32 {
        let w = transform * SIMD4(point, 1)
        let unit = (SIMD3(w.x, w.y, w.z) - model.boundsMin) / simd_max(model.boundsMax - model.boundsMin, SIMD3(repeating: 1e-6))
        let cell = SIMD3<UInt32>(simd_clamp(unit, .zero, SIMD3(repeating: 1)) * 1023)
        func spread(_ v: UInt32) -> UInt32 {
            var x = v & 0x3ff
            x = (x | x << 16) & 0x030000ff; x = (x | x << 8) & 0x0300f00f
            x = (x | x << 4) & 0x030c30c3; x = (x | x << 2) & 0x09249249
            return x
        }
        return spread(cell.x) | spread(cell.y) << 1 | spread(cell.z) << 2
    }

    /// Merged buffers are Metal buffers in shared memory, handed to SceneKit as they are: `Data` sources were kept by
    /// SceneKit and copied once more to the GPU (2 × 750 MB on the Seine file). Hit tests still read these buffers.
    /// shortcut: the system default GPU, the one SCNView uses; a Mac with several GPUs rendering elsewhere would copy.
    nonisolated(unsafe) static let device = MTLCreateSystemDefaultDevice()!

    /// A merged geometry's buffers, one per source (nil: absent); face indices stay `Data`.
    private struct Merged {
        var positions: MTLBuffer, normals: MTLBuffer?, uvs: MTLBuffer?, indices: Data?
        var boundsMin: SIMD3<Float> = .zero
        var boundsMax: SIMD3<Float> = .zero
    }

    private static func buffer(_ bytes: Int) -> MTLBuffer {
        device.makeBuffer(length: max(bytes, 4), options: .storageModeShared)!
    }

    /// Positions, normals (and UVs when textured) in model space, packed `Float`s, one buffer per source; 32-bit indices
    /// rebased per piece.
    private func mergeFaces(_ chunk: Chunk) -> Merged {
        let positions = Self.buffer(chunk.vertices * 12), normals = Self.buffer(chunk.vertices * 12)
        var indices = Data(count: chunk.indices * 4) // observed: an element made from a buffer gets no hit test results
        let uvs = chunk.textured ? Self.buffer(chunk.vertices * 8) : nil
        let pv = positions.contents().bindMemory(to: Float.self, capacity: chunk.vertices * 3)
        let nv = normals.contents().bindMemory(to: Float.self, capacity: chunk.vertices * 3)
        let uv = uvs?.contents().bindMemory(to: SIMD2<Float>.self, capacity: chunk.vertices)
        var vo = 0, io = 0, base: UInt32 = 0
        indices.withUnsafeMutableBytes { ib in
            let ix = ib.bindMemory(to: UInt32.self).baseAddress!
            for piece in chunk.pieces {
                let placement = placements[piece.placement]
                let mesh = definition(placement.definition).meshes[piece.item]
                let m = placement.transform
                let linear = simd_float3x3(SIMD3(m.columns.0.x, m.columns.0.y, m.columns.0.z), SIMD3(m.columns.1.x, m.columns.1.y, m.columns.1.z),
                                           SIMD3(m.columns.2.x, m.columns.2.y, m.columns.2.z))
                let normalMatrix = linear.inverse.transpose // what SceneKit applies per node
                // A mirrored placement reverses the winding: swap two indices so it agrees with the transformed normal.
                let (b, c) = simd_determinant(linear) < 0 ? (2, 1) : (1, 2)
                mesh.positions.withUnsafeBufferPointer { positions in
                    mesh.normals.withUnsafeBufferPointer { normals in
                        for i in 0..<positions.count {
                            let p = m * SIMD4(positions[i], 1), n = simd_normalize(normalMatrix * normals[i])
                            let o = (vo + i) * 3
                            pv[o] = p.x; pv[o + 1] = p.y; pv[o + 2] = p.z
                            nv[o] = n.x; nv[o + 1] = n.y; nv[o + 2] = n.z
                        }
                    }
                }
                if let uv, let meshUVs = mesh.uvs { for (i, t) in meshUVs.enumerated() { uv[vo + i] = t } }
                mesh.indices.withUnsafeBufferPointer { idx in
                    var t = 0
                    while t < idx.count {
                        ix[io] = base + idx[t]; ix[io + 1] = base + idx[t + b]; ix[io + 2] = base + idx[t + c]
                        io += 3; t += 3
                    }
                }
                vo += mesh.positions.count
                base += UInt32(mesh.positions.count)
            }
        }
        return Merged(positions: positions, normals: normals, uvs: uvs, indices: indices)
    }

    /// Packed segment end points in model space; implicit indices (consecutive pairs).
    private func mergeEdges(_ chunk: Chunk) -> Merged {
        let positions = Self.buffer(chunk.vertices * 12)
        let v = positions.contents().bindMemory(to: Float.self, capacity: chunk.vertices * 3)
        var vo = 0
        var lo = SIMD3<Float>(repeating: .infinity)
        var hi = SIMD3<Float>(repeating: -.infinity)
        for piece in chunk.pieces {
            let placement = placements[piece.placement], m = placement.transform
            for point in definition(placement.definition).edges[piece.item].positions {
                let p4 = m * SIMD4(point, 1)
                let p = SIMD3<Float>(p4.x, p4.y, p4.z)
                v[vo] = p.x; v[vo + 1] = p.y; v[vo + 2] = p.z
                vo += 3
                lo = simd_min(lo, p)
                hi = simd_max(hi, p)
            }
        }
        let valid = lo.x <= hi.x
        return Merged(
            positions: positions,
            normals: nil,
            uvs: nil,
            indices: nil,
            boundsMin: valid ? lo : .zero,
            boundsMax: valid ? hi : .zero
        )
    }

    /// Serial side of the build: SceneKit objects are not made from the merge threads. Edges (no material) use implicit indices.
    private func geometry(_ chunk: Chunk, _ merged: Merged) -> SCNGeometry {
        func source(_ buffer: MTLBuffer, _ semantic: SCNGeometrySource.Semantic, _ format: MTLVertexFormat, stride: Int) -> SCNGeometrySource {
            SCNGeometrySource(buffer: buffer, vertexFormat: format, semantic: semantic, vertexCount: chunk.vertices, dataOffset: 0, dataStride: stride)
        }
        var sources = [source(merged.positions, .vertex, .float3, stride: 12)]
        if let normals = merged.normals { sources.append(source(normals, .normal, .float3, stride: 12)) }
        if let uvs = merged.uvs { sources.append(source(uvs, .texcoord, .float2, stride: 8)) }
        let element = chunk.material == nil
            ? SCNGeometryElement(data: nil, primitiveType: .line, primitiveCount: chunk.vertices / 2, bytesPerIndex: 4)
            : SCNGeometryElement(data: merged.indices, primitiveType: .triangles, primitiveCount: chunk.indices / 3, bytesPerIndex: 4)
        let geometry = SCNGeometry(sources: sources, elements: [element])
        if chunk.material == nil {
            geometry.boundingBox = (SCNVector3(merged.boundsMin), SCNVector3(merged.boundsMax))
        }
        geometry.materials = [chunk.material ?? chunk.edgeMaterial ?? edgeMaterial]
        return geometry
    }

    /// SketchUp inheritance: a face without material takes the one of the nearest painted enclosing instance; its UVs
    /// are then in metres. Unpainted all the way up: the default material.
    private func resolvedMaterial(_ mesh: SKPModel.Mesh, inherited: Int?) -> SCNMaterial {
        if let index = mesh.material { return scnMaterial(index, uvs: mesh.uvs == nil ? .none : .repeats) }
        if let index = inherited { return scnMaterial(index, uvs: mesh.uvs == nil ? .none : .metres) }
        return defaultMaterial
    }

    /// How a mesh's UVs are expressed: none, texture repeats (own material), metres (material inherited from an instance).
    private enum UVs: Int { case none, repeats, metres }

    /// One shared `SCNMaterial` per model material and UV kind, so SceneKit can batch identical draws.
    private func scnMaterial(_ index: Int, uvs: UVs) -> SCNMaterial {
        let uvs = image(index) == nil ? .none : uvs // untextured: one material whatever the UVs
        let key = index * 3 + uvs.rawValue
        if let material = materials[key] { return material }
        let material = makeMaterial(index, uvs: uvs)
        materials[key] = material
        return material
    }

    /// One image per textured material, shared by its repeats and metres variants.
    private func image(_ index: Int) -> NSImage? {
        if let image = images[index] { return image }
        let image = model.materials[index].textureURL.flatMap(NSImage.init(contentsOf:))
        images[index] = image
        return image
    }

    private func makeMaterial(_ index: Int?, uvs: UVs) -> SCNMaterial {
        let material = SCNMaterial()
        material.lightingModel = .physicallyBased
        material.roughness.contents = 0.85
        material.metalness.contents = 0
        material.isDoubleSided = true
        guard let index else { material.diffuse.contents = NSColor(white: 0.96, alpha: 1); return material }
        let source = model.materials[index]
        let isTranslucent = source.opacity < 1 || source.isTransparent
        // SceneKit's `.physicallyBased` Metal shader ignores `SCNMaterial.transparency` when `diffuse.contents` has alpha == 1.0.
        // We must therefore pass `effectiveAlpha` in the diffuse NSColor (or multiply `_surface.diffuse.a` in a shader modifier for textures).
        let effectiveAlpha = CGFloat(source.opacity < 1 ? max(source.opacity, 0.08) : 1.0)
        if uvs != .none, let image = image(index) {
            material.diffuse.contents = image
            material.diffuse.wrapS = .repeat
            material.diffuse.wrapT = .repeat
            // SketchUp's v grows upwards, SceneKit samples v = 0 at the image top: flip (after metres → repeats).
            let flip = SCNMatrix4Mult(SCNMatrix4MakeScale(1, -1, 1), SCNMatrix4MakeTranslation(0, 1, 0))
            let scale = uvs == .metres ? SCNMatrix4MakeScale(CGFloat(1 / source.textureScale.x), CGFloat(1 / source.textureScale.y), 1)
                                       : SCNMatrix4Identity
            material.diffuse.contentsTransform = SCNMatrix4Mult(scale, flip)
            if source.opacity < 1 {
                material.shaderModifiers = [.surface: "_surface.diffuse.a *= \(Float(effectiveAlpha));"]
            }
        } else {
            let raw = SIMD3<Float>(source.color.x, source.color.y, source.color.z)
            let rgb: SIMD3<Float>
            if model.fileInfo.isCAD {
                let bgLuma = Rendering.backdropLuminance(for: backdropStyle, customColor: customBackdropColor)
                rgb = Rendering.adaptedCADColor(raw, backdropLuminance: bgLuma)
            } else {
                rgb = raw
            }
            material.diffuse.contents = NSColor(srgbRed: CGFloat(rgb.x), green: CGFloat(rgb.y), blue: CGFloat(rgb.z), alpha: effectiveAlpha)
        }
        if isTranslucent {
            material.transparency = CGFloat(source.opacity)
            material.transparencyMode = .dualLayer
            material.writesToDepthBuffer = false // edges and opaque geometry behind glass stay visible
        }
        return material
    }

    /// Edges lie on their faces: pull them towards the eye so the depth test keeps them in front of coplanar faces but
    /// behind anything really in front. Perspective: ε = 0.1 % of their depth (3 cm at 30 m), a uniform scale in view
    /// space (the projection of x, y is unchanged); orthographic: ε × the visible half-height, so it follows the zoom.
    static let edgeBias = """
    float4 vp = scn_node.modelViewTransform * _geometry.position;
    if (scn_frame.projectionTransform[2][3] != 0.0) { vp.xyz *= 0.999; } else { vp.z += 0.001 / scn_frame.projectionTransform[1][1]; }
    _geometry.position = scn_node.inverseModelViewTransform * vp;
    """
}
