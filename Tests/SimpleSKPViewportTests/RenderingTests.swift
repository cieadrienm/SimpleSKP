import XCTest
import SceneKit
@testable import SimpleSKPViewport
import SimpleSKPCore

/// D7 « réaliste doux »: PBR materials, the sun and its shadows, SSAO toggle, the procedural sky.
@MainActor
final class RenderingTests: XCTestCase {
    func testMaterialsArePhysicallyBased() {
        let scene = ViewportScene(model: SyntheticModel.cube())
        scene.setLayer(1, visible: true)
        var materials: [SCNMaterial] = []
        scene.modelRoot.enumerateHierarchy { node, _ in
            if node.geometry?.elements.first?.primitiveType == .triangles { materials.append(node.geometry!.firstMaterial!) }
        }
        XCTAssertEqual(materials.count, 2, "red, and the default for unpainted B")
        for material in materials {
            XCTAssertEqual(material.lightingModel, .physicallyBased)
            XCTAssertEqual(material.roughness.contents as? Double, 0.85)
            XCTAssertEqual(material.metalness.contents as? Double, 0)
            XCTAssertTrue(material.isDoubleSided)
        }
    }

    func testSunCastsSoftShadowsAndToggles() throws {
        let scene = ViewportScene(model: SyntheticModel.cube())
        let light = try XCTUnwrap(scene.sun.light)
        XCTAssertTrue(scene.sun.parent === scene.modelRoot)
        XCTAssertEqual(light.type, .directional)
        XCTAssertTrue(light.castsShadow)
        XCTAssertEqual(light.shadowCascadeCount, 3)
        XCTAssertEqual(light.shadowMapSize, CGSize(width: 2048, height: 2048))
        // Shines downwards in model space (Z up), from the south-west.
        let direction = scene.sun.simdConvertVector(SIMD3(0, 0, -1), to: scene.modelRoot)
        XCTAssertEqual(direction.z, -sin(.pi / 4), accuracy: 1e-4)
        XCTAssertGreaterThan(direction.x, 0)
        XCTAssertGreaterThan(direction.y, 0)
        XCTAssertGreaterThan(light.maximumShadowDistance, 0)

        scene.shadowsEnabled = false
        XCTAssertFalse(light.castsShadow)
        scene.shadowsEnabled = true
        XCTAssertTrue(light.castsShadow)
        scene.setShadowQuality(false)
        XCTAssertFalse(scene.shadowQualityIsHigh)
        XCTAssertEqual(light.shadowCascadeCount, 1)
        XCTAssertEqual(light.shadowMapSize, CGSize(width: 1024, height: 1024))
    }

    func testAmbientOcclusionToggle() {
        let camera = SCNCamera()
        Rendering.configure(camera: camera)
        XCTAssertTrue(camera.wantsHDR)
        XCTAssertFalse(camera.wantsExposureAdaptation)
        XCTAssertEqual(camera.screenSpaceAmbientOcclusionIntensity, 0.7, accuracy: 1e-6)
        Rendering.setAmbientOcclusion(false, on: camera)
        XCTAssertEqual(camera.screenSpaceAmbientOcclusionIntensity, 0)
        camera.usesOrthographicProjection = true
        Rendering.setAmbientOcclusion(true, on: camera)
        XCTAssertEqual(camera.screenSpaceAmbientOcclusionIntensity, 0, "SSAO is wrong in a parallel projection")
    }

    func testSkyEnvironment() throws {
        let scene = ViewportScene(model: SyntheticModel.cube())
        let sky = try XCTUnwrap(scene.scene.lightingEnvironment.contents as! CGImage?)
        XCTAssertEqual(sky.width, 512)
        XCTAssertEqual(sky.height, 256)
        let rep = NSBitmapImageRep(cgImage: sky)
        let zenith = rep.colorAt(x: 0, y: 0)!, horizon = rep.colorAt(x: 0, y: 127)!, ground = rep.colorAt(x: 0, y: 255)!
        XCTAssertGreaterThan(zenith.blueComponent, zenith.redComponent + 0.2, "blue zenith")
        XCTAssertGreaterThan(horizon.redComponent, 0.9, "warm white horizon")
        XCTAssertLessThan(ground.redComponent, 0.4, "grey ground")
        XCTAssertNotNil(scene.scene.background.contents as! CGImage?, "the sky is the viewport's backdrop")
    }

    func testShadingBackdropGridAndSunControls() {
        let scene = ViewportScene(model: SyntheticModel.cube())
        scene.shadingStyle = .clay
        XCTAssertEqual(scene.shadingStyle, .clay)
        scene.shadingStyle = .xray
        XCTAssertEqual(scene.shadingStyle, .xray)
        scene.shadingStyle = .wireframe
        XCTAssertTrue(scene.showsEdges, "wireframe forces edges visible")
        scene.shadingStyle = .textured

        scene.backdropStyle = .studioDark
        XCTAssertNotNil(scene.scene.background.contents as! CGImage?)
        scene.backdropStyle = .warmPaper
        XCTAssertNotNil(scene.scene.background.contents as! CGImage?)

        XCTAssertFalse(scene.showsGrid)
        scene.showsGrid = true
        XCTAssertTrue(scene.showsGrid)

        scene.sunAzimuthDegrees = -45
        scene.sunElevationDegrees = 60
        let direction = scene.sun.simdConvertVector(SIMD3(0, 0, -1), to: scene.modelRoot)
        XCTAssertEqual(direction.z, -sin(.pi / 3), accuracy: 1e-4)
        scene.resetSun()
        XCTAssertEqual(scene.sunAzimuthDegrees, -135)
        XCTAssertEqual(scene.sunElevationDegrees, 45)
    }

    func testCustomBackdropColorAndAmbientOcclusionStrength() throws {
        let scene = ViewportScene(model: SyntheticModel.cube())
        scene.customBackdropColor = SIMD3<Float>(0.85, 0.25, 0.15)
        scene.backdropStyle = .customColor
        let bg = try XCTUnwrap(scene.scene.background.contents as! CGImage?)
        let rep = NSBitmapImageRep(cgImage: bg)
        let center = try XCTUnwrap(rep.colorAt(x: bg.width / 2, y: bg.height / 2))
        XCTAssertGreaterThan(center.redComponent, center.blueComponent + 0.4, "custom warm red backdrop")

        let camera = SCNCamera()
        Rendering.configure(camera: camera)
        Rendering.setAmbientOcclusion(true, intensity: 1.45, on: camera)
        XCTAssertEqual(camera.screenSpaceAmbientOcclusionIntensity, 1.45, accuracy: 1e-5)
    }

    func testPointLightingDefaultCenterAndSceneLightDetection() {
        // 1. Model without scene lights: switching to .point creates a light at the geometry center.
        let scene = ViewportScene(model: SyntheticModel.cube())
        XCTAssertTrue(scene.detectedSceneLights.isEmpty)
        XCTAssertEqual(scene.lightingMode, .sun)

        scene.lightingMode = .point
        XCTAssertEqual(scene.pointLights.count, 1)
        let expectedCenter = scene.defaultPointLightPosition
        XCTAssertEqual(scene.pointLights[0].position.x, expectedCenter.x, accuracy: 1e-4)
        XCTAssertEqual(scene.pointLights[0].position.y, expectedCenter.y, accuracy: 1e-4)
        XCTAssertEqual(scene.pointLights[0].position.z, expectedCenter.z, accuracy: 1e-4)
        XCTAssertFalse(scene.pointLights[0].isFromScene)

        // Adjusting coordinates updates the point light node.
        scene.pointLights[0].position = SIMD3<Float>(1.25, -2.5, 3.75)
        scene.pointLights[0].intensity = 1.6
        XCTAssertEqual(scene.pointLights[0].position, SIMD3<Float>(1.25, -2.5, 3.75))
        XCTAssertEqual(scene.pointLights[0].intensity, 1.6, accuracy: 1e-5)

        // 2. Model with a component named "Projecteur Spot 1": automatically detected as a scene light.
        let baseCube = SyntheticModel.cube()
        let spotMesh = SKPModel.Mesh(
            material: nil,
            layer: 0,
            positions: [SIMD3(-0.1, -0.1, -0.1), SIMD3(0.1, -0.1, -0.1), SIMD3(0, 0.1, 0.1)],
            normals: [SIMD3(0, 0, 1), SIMD3(0, 0, 1), SIMD3(0, 0, 1)],
            indices: [0, 1, 2]
        )
        let spotDefIndex = baseCube.definitions.count
        var definitions = baseCube.definitions
        definitions.append(
            SKPModel.Definition(
                name: "Projecteur Spot Face",
                meshes: [spotMesh],
                edges: []
            )
        )
        var lightTransform = matrix_identity_float4x4
        lightTransform.columns.3 = SIMD4<Float>(2.0, -3.0, 4.5, 1.0)
        var rootChildren = baseCube.root.children
        rootChildren.append(
            SKPModel.Instance(
                definition: spotDefIndex,
                transform: lightTransform,
                layer: 0,
                isGroup: false,
                material: nil,
                name: "Spot 1"
            )
        )
        let rootWithLight = SKPModel.Definition(
            name: baseCube.root.name,
            meshes: baseCube.root.meshes,
            edges: baseCube.root.edges,
            children: rootChildren
        )
        let modelWithLight = SKPModel(
            root: rootWithLight,
            definitions: definitions,
            materials: baseCube.materials,
            layers: baseCube.layers,
            scenes: baseCube.scenes,
            camera: baseCube.camera,
            boundsMin: baseCube.boundsMin,
            boundsMax: baseCube.boundsMax,
            fileInfo: baseCube.fileInfo
        )

        let sceneWithLight = ViewportScene(model: modelWithLight)
        XCTAssertEqual(sceneWithLight.detectedSceneLights.count, 1)
        XCTAssertTrue(sceneWithLight.detectedSceneLights[0].isFromScene)
        XCTAssertEqual(sceneWithLight.detectedSceneLights[0].position.x, 2.0, accuracy: 0.15)
        XCTAssertEqual(sceneWithLight.detectedSceneLights[0].position.y, -3.0, accuracy: 0.15)
        XCTAssertEqual(sceneWithLight.detectedSceneLights[0].position.z, 4.5, accuracy: 0.15)
    }

    func testAdaptiveWireframeAndEdgeContrastFollowsBackdropLuminance() {
        let scene = ViewportScene(model: SyntheticModel.cube())
        scene.shadingStyle = .wireframe

        // Dark studio backdrop -> bright contrasting edges
        scene.backdropStyle = .studioDark
        let darkEdge = Rendering.contrastingEdgeColor(for: .studioDark, customColor: scene.customBackdropColor, shadingStyle: .wireframe)
        XCTAssertGreaterThan(darkEdge.x, 0.85, "bright silver-white edge on dark background")
        XCTAssertLessThan(Rendering.backdropLuminance(for: .studioDark, customColor: scene.customBackdropColor), 0.30)

        // Warm paper backdrop -> dark charcoal ink edges
        scene.backdropStyle = .warmPaper
        let paperEdge = Rendering.contrastingEdgeColor(for: .warmPaper, customColor: scene.customBackdropColor, shadingStyle: .wireframe)
        XCTAssertLessThan(paperEdge.x, 0.20, "dark charcoal ink edge on light paper background")
        XCTAssertGreaterThan(Rendering.backdropLuminance(for: .warmPaper, customColor: scene.customBackdropColor), 0.70)

        // Custom black vs custom white
        let customDarkEdge = Rendering.contrastingEdgeColor(for: .customColor, customColor: SIMD3<Float>(0.05, 0.05, 0.06), shadingStyle: .wireframe)
        let customLightEdge = Rendering.contrastingEdgeColor(for: .customColor, customColor: SIMD3<Float>(0.95, 0.95, 0.94), shadingStyle: .wireframe)
        XCTAssertGreaterThan(customDarkEdge.x, 0.85)
        XCTAssertLessThan(customLightEdge.x, 0.20)
    }

    func testLogarithmicLightCurveAndAmbientLightControl() throws {
        // Endpoints
        XCTAssertEqual(Rendering.sliderToLightIntensity(0.0, maxIntensity: 3.0), 0.0, accuracy: 1e-6)
        XCTAssertEqual(Rendering.sliderToLightIntensity(1.0, maxIntensity: 3.0), 3.0, accuracy: 1e-6)
        XCTAssertEqual(Rendering.lightIntensityToSlider(0.0, maxIntensity: 3.0), 0.0, accuracy: 1e-6)
        XCTAssertEqual(Rendering.lightIntensityToSlider(3.0, maxIntensity: 3.0), 1.0, accuracy: 1e-6)

        // Logarithmic / power curve gives fine resolution in the low values:
        // At 25% of slider travel, intensity is < 10% (0.10), giving much finer control in low values than linear (0.75).
        let quarterSliderIntensity = Rendering.sliderToLightIntensity(0.25, maxIntensity: 3.0)
        XCTAssertLessThan(quarterSliderIntensity, 0.12, "fine low-value precision")
        XCTAssertGreaterThan(quarterSliderIntensity, 0.01)

        // Round-trip
        for target in [Float(0.02), 0.08, 0.25, 1.0, 2.4, 3.0] {
            let t = Rendering.lightIntensityToSlider(target, maxIntensity: 3.0)
            let roundTripped = Rendering.sliderToLightIntensity(t, maxIntensity: 3.0)
            XCTAssertEqual(roundTripped, target, accuracy: 1e-4)
        }

        // Ambient light control: setting ambientIntensity = 0 and light intensity = 0 produces total darkness (0 illumination)
        let scene = ViewportScene(model: SyntheticModel.cube())
        scene.lightingMode = .point
        scene.pointLights[0].intensity = 0.0
        scene.ambientIntensity = 0.0
        XCTAssertEqual(Float(scene.scene.lightingEnvironment.intensity), 0.0, accuracy: 1e-6)
        XCTAssertEqual(Float(scene.fill.light?.intensity ?? -1), 0.0, accuracy: 1e-6)
        XCTAssertEqual(Float(scene.skyFill.light?.intensity ?? -1), 0.0, accuracy: 1e-6)

        scene.ambientIntensity = 1.5
        XCTAssertGreaterThan(Float(scene.scene.lightingEnvironment.intensity), 0.1)
        XCTAssertGreaterThan(Float(scene.fill.light?.intensity ?? 0), 100)
    }

    func testVectorPDFExporterGeneratesValidVectorPDFInWireframeAndShadedModes() throws {
        let view = ViewportView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let scene = ViewportScene(model: SyntheticModel.cube())
        scene.showsGrid = true
        view.present(scene)
        view.apply(camera: scene.model.scenes[0].camera!, animated: false)

        // 1. Shaded mode (.textured)
        scene.shadingStyle = .textured
        let shadedPDF = try XCTUnwrap(VectorPDFExporter.renderPDF(from: view))
        XCTAssertGreaterThan(shadedPDF.count, 500)
        XCTAssertEqual(String(decoding: shadedPDF.prefix(5), as: UTF8.self), "%PDF-")

        // 2. Wireframe mode on dark studio background
        scene.shadingStyle = .wireframe
        scene.backdropStyle = .studioDark
        let wireframePDF = try XCTUnwrap(VectorPDFExporter.renderPDF(from: view))
        XCTAssertGreaterThan(wireframePDF.count, 500)
        XCTAssertEqual(String(decoding: wireframePDF.prefix(5), as: UTF8.self), "%PDF-")
    }

    func testMaterialTransparencyRendersSeeThroughInPBRAndXRay() throws {
        var model = SyntheticModel.cube()
        // Root cube at (0,0,0)..(1,1,1) is material 0 (opaque Red).
        // Add a second cube directly on the line of sight from camera (5, -6, 4) to (0.5, 0.5, 0.5)
        // at (1.5, -2.0, 1.0) with material 1 (Translucent Blue, opacity 0.25).
        model.materials.append(SKPModel.Material(name: "TransBlue", color: SIMD4(0, 0.5, 1, 0.25), opacity: 0.25))
        var (glassMesh, _) = SyntheticModel.cubeMesh(material: 1, layer: 0)
        glassMesh.positions = glassMesh.positions.map { $0 + SIMD3(1.5, -2.0, 1.0) }
        model.root.meshes.append(glassMesh)

        let view = ViewportView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        let scene = ViewportScene(model: model)
        view.present(scene)
        view.apply(camera: model.scenes[0].camera!, animated: false)

        let rep = try XCTUnwrap(view.snapshot().cgImage(forProposedRect: nil, context: nil, hints: nil).map(NSBitmapImageRep.init(cgImage:)))
        let pixel = try XCTUnwrap(rep.colorAt(x: 100, y: 100)?.usingColorSpace(.sRGB))
        // Because the blue cube is 25% opaque, the red cube behind it must shine through strongly (red > 0.35).
        // Previously, when SceneKit ignored `material.transparency` because diffuse alpha was 1.0, red was 0.000!
        XCTAssertGreaterThan(pixel.redComponent, 0.35, "Opaque red object behind 25%-opacity blue glass must be visible through the glass")

        // Verify transparent face nodes have renderingOrder == 2 and castsShadow == false
        let glassNodes = scene.layerSets[[0]]?.node?.childNodes.filter { ($0.geometry?.firstMaterial?.transparency ?? 1) < 1 } ?? []
        XCTAssertFalse(glassNodes.isEmpty)
        for node in glassNodes {
            XCTAssertEqual(node.renderingOrder, 2)
            XCTAssertFalse(node.castsShadow)
        }

        // Verify X-Ray mode also renders see-through
        scene.shadingStyle = .xray
        let xrayRep = try XCTUnwrap(view.snapshot().cgImage(forProposedRect: nil, context: nil, hints: nil).map(NSBitmapImageRep.init(cgImage:)))
        let xrayPixel = try XCTUnwrap(xrayRep.colorAt(x: 100, y: 100)?.usingColorSpace(.sRGB))
        XCTAssertGreaterThan(xrayPixel.redComponent, 0.25, "X-Ray mode must also allow background/behind geometry to show through")
    }

    func testPointLightCastsShadowsWhenShadowsEnabled() throws {
        var model = SyntheticModel.cube()
        model.root.children = []
        // 1) White floor slab at Z = -0.2 .. 0.0 spanning X,Y in [-3, 3]
        var (floorMesh, _) = SyntheticModel.cubeMesh(material: nil, layer: 0)
        floorMesh.positions = floorMesh.positions.map { p in
            SIMD3((p.x - 0.5) * 6.0, (p.y - 0.5) * 6.0, (p.z - 1.0) * 0.2)
        }
        // 2) Occluder cube hovering at Z = 1.0 .. 1.8 centered at X=0, Y=0
        var (occluderMesh, _) = SyntheticModel.cubeMesh(material: 0, layer: 0)
        occluderMesh.positions = occluderMesh.positions.map { p in
            SIMD3((p.x - 0.5) * 1.2, (p.y - 0.5) * 1.2, 1.0 + p.z * 0.8)
        }
        model.root.meshes = [floorMesh, occluderMesh]
        model.boundsMin = SIMD3(-3, -3, -0.2)
        model.boundsMax = SIMD3(3, 3, 2.0)

        let view = ViewportView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        let scene = ViewportScene(model: model)
        scene.showsEdges = false
        scene.ambientIntensity = 0.0
        scene.lightingMode = .point
        // Place point light directly above the occluder at (0, 0, 3.0)
        scene.pointLights = [ViewportPointLight(name: "TopPoint", position: SIMD3(0, 0, 3.0), intensity: 1.5, isFromScene: false)]
        view.present(scene)
        // Camera looks squarely at the center of the floor (0, 0, 0) from (0, -3.2, 0.45) — seeing under the floating occluder cube
        view.apply(camera: SKPModel.Camera(position: SIMD3(0, -3.2, 0.45), target: SIMD3(0, 0, 0), fovDegrees: 30), animated: false)

        // With shadows OFF: the point light illuminates the floor right through the occluder cube
        scene.shadowsEnabled = false
        let unshadowedRep = try XCTUnwrap(view.snapshot().cgImage(forProposedRect: nil, context: nil, hints: nil).map(NSBitmapImageRep.init(cgImage:)))
        let unshadowedCenter = try XCTUnwrap(unshadowedRep.colorAt(x: 100, y: 100)?.usingColorSpace(.sRGB))

        // With shadows ON: the 6-spot cube shadow rig casts the occluder's shadow onto the floor at (0, 0, 0)
        scene.shadowsEnabled = true
        let shadowedRep = try XCTUnwrap(view.snapshot().cgImage(forProposedRect: nil, context: nil, hints: nil).map(NSBitmapImageRep.init(cgImage:)))
        let shadowedCenter = try XCTUnwrap(shadowedRep.colorAt(x: 100, y: 100)?.usingColorSpace(.sRGB))

        XCTAssertGreaterThan(unshadowedCenter.redComponent, 0.25, "Floor is lit when point light shadows are disabled")
        XCTAssertLessThan(shadowedCenter.redComponent, unshadowedCenter.redComponent * 0.45,
                          "Point light must cast a clear shadow on the floor below the occluder when shadowsEnabled is true (unshadowed=\(unshadowedCenter.redComponent), shadowed=\(shadowedCenter.redComponent))")
    }

    func testCADLayerAndEntityColorAdaptationAndHoverHighlight() throws {
        // 1. Contrast adaptation of AutoCAD ACI 7 (White/Black) and chromatic colors
        let aci7White = SIMD3<Float>(1, 1, 1)
        let onDark = Rendering.adaptedCADColor(aci7White, backdropLuminance: 0.08)
        let onLight = Rendering.adaptedCADColor(aci7White, backdropLuminance: 0.90)
        XCTAssertGreaterThan(onDark.x, 0.88, "ACI 7 renders crisp white on dark CAD canvas")
        XCTAssertLessThan(onLight.x, 0.20, "ACI 7 renders dark charcoal ink on light paper")

        let darkBlue = SIMD3<Float>(0.0, 0.0, 0.5)
        let liftedBlue = Rendering.adaptedCADColor(darkBlue, backdropLuminance: 0.08)
        XCTAssertGreaterThan(liftedBlue.z, 0.65, "Dark blue CAD layer is lifted for legibility on dark canvas")

        // 2. Per-layer colored CAD edges & high-contrast hover highlight in ViewportScene
        let redEdges = SKPModel.EdgeSet(layer: 0, positions: [SIMD3(-5, 0, 0), SIMD3(5, 0, 0)])
        let yellowEdges = SKPModel.EdgeSet(layer: 1, positions: [SIMD3(-5, 2, 0), SIMD3(5, 2, 0)])
        let cadModel = SKPModel(
            root: SKPModel.Definition(name: "", meshes: [], edges: [redEdges, yellowEdges], children: []),
            definitions: [],
            materials: [],
            layers: [
                SKPModel.Layer(name: "AXES_ROUGES", isVisible: true, color: SIMD4(1, 0, 0, 1)),
                SKPModel.Layer(name: "COTES_JAUNES", isVisible: true, color: SIMD4(1, 1, 0, 1)),
            ],
            scenes: [],
            camera: nil,
            boundsMin: SIMD3(-5, 0, 0),
            boundsMax: SIMD3(5, 2, 0),
            fileInfo: SKPFileInfo(url: URL(fileURLWithPath: "/tmp/coupe.dwg"), fileSize: 512, version: "AC1032", versionLabel: "AutoCAD 2018", thumbnailPNG: nil)
        )
        let scene = ViewportScene(model: cadModel)
        scene.backdropStyle = .studioDark
        let redNode = try XCTUnwrap(scene.layerSets[[0]]?.node?.childNodes.first)
        let yellowNode = try XCTUnwrap(scene.layerSets[[1]]?.node?.childNodes.first)
        let baseRedMat = try XCTUnwrap(redNode.geometry?.firstMaterial)
        let baseYellowMat = try XCTUnwrap(yellowNode.geometry?.firstMaterial)
        XCTAssertFalse(baseRedMat === baseYellowMat, "Distinct CAD layer colors receive distinct edge materials")

        // Hovering layer 0 (red) applies the luminous amber-gold hover material with depth-test bypass
        scene.setHoveredLayers([0])
        let hoveredRedMat = try XCTUnwrap(redNode.geometry?.firstMaterial)
        XCTAssertFalse(hoveredRedMat === baseRedMat)
        XCTAssertFalse(hoveredRedMat.readsFromDepthBuffer, "Hovered edges draw on top of overlapping lines")
        XCTAssertEqual(redNode.renderingOrder, 4)

        // Hovering layer 1 (yellow) switches to luminous sky-cyan so yellow CAD lines still pop on hover
        scene.setHoveredLayers([1])
        let hoveredYellowMat = try XCTUnwrap(yellowNode.geometry?.firstMaterial)
        let cyanColor = try XCTUnwrap((hoveredYellowMat.diffuse.contents as? NSColor)?.usingColorSpace(.sRGB))
        XCTAssertGreaterThan(cyanColor.blueComponent, cyanColor.redComponent + 0.5, "Yellow CAD layer uses contrasting sky-cyan hover highlight")

        scene.setHoveredLayers([])
        XCTAssertTrue(redNode.geometry?.firstMaterial === baseRedMat)
        XCTAssertTrue(yellowNode.geometry?.firstMaterial === baseYellowMat)
    }

    func testVideoProjectorIlluminatesFrontWallAndOccludesWallBehindObstacle() throws {
        // Scene geometry:
        // 1) Rear projection screen wall at y = 8 m, spanning x in [-4, +4], z in [-2, +2]
        // 2) Opaque obstacle wall at y = 4 m, blocking ONLY the left side x in [-4, -0.2], z in [-2, +2]
        let rearScreen = SKPModel.Mesh(
            material: 0, layer: 0,
            positions: [
                SIMD3(-4, 8, -2), SIMD3(4, 8, -2), SIMD3(4, 8, 2), SIMD3(-4, 8, 2)
            ],
            normals: [
                SIMD3(0, -1, 0), SIMD3(0, -1, 0), SIMD3(0, -1, 0), SIMD3(0, -1, 0)
            ],
            uvs: [.zero, .zero, .zero, .zero],
            indices: [0, 1, 2, 0, 2, 3]
        )
        let leftObstacle = SKPModel.Mesh(
            material: 0, layer: 0,
            positions: [
                SIMD3(-4, 4, -2), SIMD3(-0.2, 4, -2), SIMD3(-0.2, 4, 2), SIMD3(-4, 4, 2)
            ],
            normals: [
                SIMD3(0, -1, 0), SIMD3(0, -1, 0), SIMD3(0, -1, 0), SIMD3(0, -1, 0)
            ],
            uvs: [.zero, .zero, .zero, .zero],
            indices: [0, 1, 2, 0, 2, 3]
        )
        let model = SKPModel(
            root: SKPModel.Definition(name: "", meshes: [rearScreen, leftObstacle], edges: [], children: []),
            definitions: [],
            materials: [SKPModel.Material(name: "Mat Wall", color: SIMD4(0.35, 0.35, 0.35, 1.0))],
            layers: [SKPModel.Layer(name: "Layer0", isVisible: true)],
            scenes: [],
            camera: nil,
            boundsMin: SIMD3(-4, 0, -2),
            boundsMax: SIMD3(4, 8, 2),
            fileInfo: SKPFileInfo(url: URL(fileURLWithPath: "/tmp/vp_occlusion.skp"), fileSize: 0, version: "test", versionLabel: "test", thumbnailPNG: nil)
        )

        let scene = ViewportScene(model: model)
        scene.backdropStyle = .studioDark
        scene.showsGrid = false
        scene.showsEdges = false
        // Dim scene lights so the projector's contribution is unmistakable
        scene.sunIntensity = 0.0
        scene.ambientIntensity = 0.05

        // Place an Optoma ZU920ST at (0, 0, 0) aiming along +Y at (0, 8, 0) with whiteFrame pattern
        var vp = VideoProjector(
            name: "VP1 Optoma ZU920ST",
            specID: ProjectorSpec.optomaZU920ST.id,
            position: SIMD3<Float>(0, 0, 0),
            target: SIMD3<Float>(0, 8, 0),
            throwRatio: 0.70,
            lensShiftH: 0.0,
            lensShiftV: 0.0,
            intensity: 1.5,
            pattern: .whiteFrame,
            showsFrustum: false
        )
        vp.isEnabled = true
        scene.videoProjectors = [vp]

        // 1. Verify geometric raycast occlusion helper:
        // - Front face of the obstacle at (-1.5, 4, 0) IS illuminated
        XCTAssertTrue(
            scene.isPointIlluminatedByProjector(SIMD3<Float>(-1.5, 4.0, 0.0), projector: vp),
            "Front obstacle surface directly facing the projector must be illuminated"
        )
        // - Unblocked right side of the rear screen at (+1.5, 8, 0) IS illuminated
        XCTAssertTrue(
            scene.isPointIlluminatedByProjector(SIMD3<Float>(1.5, 8.0, 0.0), projector: vp),
            "Unblocked right half of the rear screen must be illuminated"
        )
        // - Blocked left side of the rear screen at (-1.5, 8, 0) behind the obstacle at y=4 MUST be occluded
        XCTAssertFalse(
            scene.isPointIlluminatedByProjector(SIMD3<Float>(-1.5, 8.0, 0.0), projector: vp),
            "Rear screen behind the opaque obstacle wall must be occluded (projection never traverses matter)"
        )

        // 2. Verify Metal GPU shadow depth map + SceneKit surface shader occlusion:
        // Place camera at (0, 5.0, 0) (between the y=4 obstacle and y=8 rear screen) looking at (0, 8, 0),
        // so the camera sees the entire rear screen directly without the obstacle blocking the camera's view,
        // while the projector at (0, 0, 0) IS blocked on the left side (x < -0.2) by the obstacle at y=4!
        let view = ViewportView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        view.present(scene)
        view.apply(camera: SKPModel.Camera(position: SIMD3<Float>(0, 5.0, 0), target: SIMD3<Float>(0, 8.0, 0), fovDegrees: 60), animated: false)

        let rep = try XCTUnwrap(view.snapshot().cgImage(forProposedRect: nil, context: nil, hints: nil).map(NSBitmapImageRep.init(cgImage:)))
        // Left side of image (x = 50, y = 100) corresponds to world x < 0 on rear screen (behind obstacle -> occluded)
        // Right side of image (x = 150, y = 100) corresponds to world x > 0 on rear screen (unblocked -> lit by VP)
        let occludedLeftColor = try XCTUnwrap(rep.colorAt(x: 50, y: 100)?.usingColorSpace(.sRGB))
        let illuminatedRightColor = try XCTUnwrap(rep.colorAt(x: 150, y: 100)?.usingColorSpace(.sRGB))

        XCTAssertGreaterThan(
            illuminatedRightColor.greenComponent, 0.45,
            "Unblocked right side of rear screen must be brightly illuminated by the Optoma ZU920ST (right RGB=(\(illuminatedRightColor.redComponent), \(illuminatedRightColor.greenComponent), \(illuminatedRightColor.blueComponent)), left RGB=(\(occludedLeftColor.redComponent), \(occludedLeftColor.greenComponent), \(occludedLeftColor.blueComponent)))"
        )
        XCTAssertLessThan(
            occludedLeftColor.greenComponent, illuminatedRightColor.greenComponent * 0.35,
            "Occluded left side of rear screen behind the obstacle must NOT receive projected light (occluded=\(occludedLeftColor.greenComponent), lit=\(illuminatedRightColor.greenComponent))"
        )
    }

    func testVideoProjectorIncidenceAngleAndIndirectReverberation() throws {
        // 1. Incidence-angle test:
        // - Right panel at x in [0.2, 2.5], y = 6: normal to the beam (normal = (0, -1, 0), theta ≈ 0°)
        // - Left panel at x in [-2.5, -0.2]: steeply angled (grazing incidence theta ≈ 82° to the beam from origin)
        // - Side wall at x = -4.2, y in [2.5, 5.8], z in [-2, 2] (outside direct frustum, facing +X toward the screen)
        let normalRightPanel = SKPModel.Mesh(
            material: 0, layer: 0,
            positions: [
                SIMD3(0.2, 6.0, -1.5), SIMD3(2.5, 6.0, -1.5), SIMD3(2.5, 6.0, 1.5), SIMD3(0.2, 6.0, 1.5)
            ],
            normals: [
                SIMD3(0, -1, 0), SIMD3(0, -1, 0), SIMD3(0, -1, 0), SIMD3(0, -1, 0)
            ],
            uvs: [.zero, .zero, .zero, .zero],
            indices: [0, 1, 2, 0, 2, 3]
        )
        // Left panel at x around -1.2, y = 6.0, with surface normal almost perpendicular to the ray from (0,0,0)
        // Ray from (0,0,0) to (-1.2, 6.0, 0) has unit direction d ≈ (-0.196, 0.981, 0).
        // A normal n = (0.985, -0.174, 0) has dot(n, -d) = 0.985*0.196 + (-0.174)*(-0.981) ≈ 0.36,
        // or n = (0.96, 0.08, 0) has dot(n, -d) = 0.96*0.196 - 0.08*0.981 ≈ 0.11 (theta ≈ 83.7° grazing!).
        let grazingN = simd_normalize(SIMD3<Float>(0.96, 0.08, 0.0))
        let grazingLeftPanel = SKPModel.Mesh(
            material: 0, layer: 0,
            positions: [
                SIMD3(-2.5, 6.0, -1.5), SIMD3(-0.2, 6.0, -1.5), SIMD3(-0.2, 6.0, 1.5), SIMD3(-2.5, 6.0, 1.5)
            ],
            normals: [grazingN, grazingN, grazingN, grazingN],
            uvs: [.zero, .zero, .zero, .zero],
            indices: [0, 1, 2, 0, 2, 3]
        )
        let sideBounceWall = SKPModel.Mesh(
            material: 0, layer: 0,
            positions: [
                SIMD3(-4.2, 2.5, -2.0), SIMD3(-4.2, 5.8, -2.0), SIMD3(-4.2, 5.8, 2.0), SIMD3(-4.2, 2.5, 2.0)
            ],
            normals: [
                SIMD3(1, 0, 0), SIMD3(1, 0, 0), SIMD3(1, 0, 0), SIMD3(1, 0, 0)
            ],
            uvs: [.zero, .zero, .zero, .zero],
            indices: [0, 1, 2, 0, 2, 3]
        )

        let model = SKPModel(
            root: SKPModel.Definition(name: "", meshes: [normalRightPanel, grazingLeftPanel, sideBounceWall], edges: [], children: []),
            definitions: [],
            materials: [SKPModel.Material(name: "Mat Wall", color: SIMD4(0.65, 0.65, 0.65, 1.0))],
            layers: [SKPModel.Layer(name: "Layer0", isVisible: true)],
            scenes: [],
            camera: nil,
            boundsMin: SIMD3(-4.5, 0, -2),
            boundsMax: SIMD3(3.0, 6.5, 2),
            fileInfo: SKPFileInfo(url: URL(fileURLWithPath: "/tmp/vp_incidence_reverb.skp"), fileSize: 0, version: "test", versionLabel: "test", thumbnailPNG: nil)
        )

        let scene = ViewportScene(model: model)
        scene.backdropStyle = .studioDark
        scene.showsGrid = false
        scene.showsEdges = false
        scene.sunIntensity = 0.0
        scene.ambientIntensity = 0.02

        var vp = VideoProjector(
            name: "VP1 Optoma ZU920ST",
            specID: ProjectorSpec.optomaZU920ST.id,
            position: SIMD3<Float>(0, 0, 0),
            target: SIMD3<Float>(0, 6, 0),
            throwRatio: 0.75,
            lensShiftH: 0.0,
            lensShiftV: 0.0,
            intensity: 1.4,
            reverbIntensity: 0.0,
            pattern: .whiteFrame,
            showsFrustum: false
        )
        scene.videoProjectors = [vp]

        let view = ViewportView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        view.present(scene)
        // Part A: Look at the two front panels from (0, 2.5, 0) -> (0, 6.0, 0)
        view.apply(camera: SKPModel.Camera(position: SIMD3<Float>(0, 2.5, 0), target: SIMD3<Float>(0, 6.0, 0), fovDegrees: 60), animated: false)
        let repPanels = try XCTUnwrap(view.snapshot().cgImage(forProposedRect: nil, context: nil, hints: nil).map(NSBitmapImageRep.init(cgImage:)))
        let grazingLeftColor = try XCTUnwrap(repPanels.colorAt(x: 55, y: 100)?.usingColorSpace(.sRGB))
        let normalRightColor = try XCTUnwrap(repPanels.colorAt(x: 145, y: 100)?.usingColorSpace(.sRGB))

        XCTAssertGreaterThan(
            normalRightColor.greenComponent, 0.50,
            "Normal-incidence panel (theta ≈ 0°) must render at full projected brightness"
        )
        XCTAssertLessThan(
            grazingLeftColor.greenComponent, normalRightColor.greenComponent * 0.30,
            "Grazing-incidence panel (theta ≈ 84°) must be strongly attenuated compared to normal incidence (grazing=\(grazingLeftColor.greenComponent), normal=\(normalRightColor.greenComponent))"
        )

        // Part B: Indirect Reverberation (QuestVR 4-quadrant bounce) on the side wall at x = -4.2 (outside direct frustum)
        // Camera at (0.5, 4.2, 0) looking at (-4.2, 4.2, 0) (directly facing the side wall)
        view.apply(camera: SKPModel.Camera(position: SIMD3<Float>(0.5, 4.2, 0), target: SIMD3<Float>(-4.2, 4.2, 0), fovDegrees: 50), animated: false)
        let repNoReverb = try XCTUnwrap(view.snapshot().cgImage(forProposedRect: nil, context: nil, hints: nil).map(NSBitmapImageRep.init(cgImage:)))
        let sideWallNoReverb = try XCTUnwrap(repNoReverb.colorAt(x: 100, y: 100)?.usingColorSpace(.sRGB))

        vp.reverbIntensity = 1.8
        scene.videoProjectors = [vp]
        let repWithReverb = try XCTUnwrap(view.snapshot().cgImage(forProposedRect: nil, context: nil, hints: nil).map(NSBitmapImageRep.init(cgImage:)))
        let sideWallWithReverb = try XCTUnwrap(repWithReverb.colorAt(x: 100, y: 100)?.usingColorSpace(.sRGB))

        XCTAssertGreaterThan(
            sideWallWithReverb.greenComponent,
            sideWallNoReverb.greenComponent + 0.08,
            "Side wall outside the direct projector frustum must receive indirect bounce light from the illuminated screen (noReverb=\(sideWallNoReverb.greenComponent), withReverb=\(sideWallWithReverb.greenComponent))"
        )
    }
}
