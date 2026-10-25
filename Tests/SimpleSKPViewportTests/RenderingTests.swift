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
}
