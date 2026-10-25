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
        XCTAssertEqual(camera.screenSpaceAmbientOcclusionIntensity, 1)
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
}
