import XCTest
import SceneKit
@testable import SimpleSKPViewport
import SimpleSKPCore

/// D6 navigation through the camera rig; time advances by `rig.step(dt:)`, events are synthesised.
@MainActor
final class NavigationTests: XCTestCase {
    private func presented(_ model: SKPModel = SyntheticModel.cube()) -> (ViewportView, ViewportScene) {
        let view = ViewportView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let scene = ViewportScene(model: model)
        view.present(scene)
        view.apply(camera: scene.model.scenes[0].camera!, animated: false) // the root cube is under the view centre
        return (view, scene)
    }

    private func mouse(_ type: NSEvent.EventType, _ point: CGPoint, time: TimeInterval = 0, clicks: Int = 1,
                       flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: point, modifierFlags: flags, timestamp: time, windowNumber: 0,
                           context: nil, eventNumber: 0, clickCount: clicks, pressure: 1)!
    }

    private func key(_ code: UInt16, _ characters: String, up: Bool = false, flags: NSEvent.ModifierFlags = [], repeated: Bool = false) -> NSEvent {
        NSEvent.keyEvent(with: up ? .keyUp : .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                         context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: repeated, keyCode: code)!
    }

    private func flags(_ flags: NSEvent.ModifierFlags, keyCode: UInt16) -> NSEvent {
        NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                         context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: keyCode)!
    }

    /// Mouse motion with deltas (AppKit's factory cannot set them), deltaY down-positive like the hardware.
    private func motion(_ type: CGEventType, button: CGMouseButton, dx: Int64, dy: Int64) -> NSEvent {
        let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: .zero, mouseButton: button)!
        event.setIntegerValueField(.mouseEventDeltaX, value: dx)
        event.setIntegerValueField(.mouseEventDeltaY, value: dy)
        return NSEvent(cgEvent: event)!
    }

    /// Trackpad-style scroll: pixel deltas, continuous, with a gesture phase (1 began, 2 changed, 4 ended).
    private func scroll(dx: Int32, dy: Int32, phase: Int64, flags: CGEventFlags = []) -> NSEvent {
        let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0)!
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        event.setIntegerValueField(CGEventField(rawValue: 99)!, value: phase) // kCGScrollWheelEventScrollPhase
        event.location = CGPoint(x: 400, y: 300)
        event.flags = flags
        return NSEvent(cgEvent: event)!
    }

    private func local(_ view: ViewportView, model point: SIMD3<Float>) -> SIMD3<Float> {
        view.cameraNode.simdConvertPosition(point, from: view.cameraNode.parent)
    }

    // MARK: Orbit

    func testOrbitDragTurnsAroundTheHitPivotThenCoasts() throws {
        let (view, _) = presented()
        let yaw = view.rig.pose.yaw
        view.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 440, y: 330)))
        let pivot = try XCTUnwrap(view.rig.pivot, "the cube is under the cursor")
        let pivotBefore = local(view, model: pivot)
        for i in 1...5 { view.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: 440 + 5 * i, y: 330), time: Double(i) / 60)) }
        XCTAssertEqual(view.rig.pose.yaw - yaw, -25 * 0.4 * .pi / 180, accuracy: 1e-4)
        XCTAssertLessThan(simd_distance(local(view, model: pivot), pivotBefore), 1e-4, "the pivot keeps its screen position")

        view.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: 465, y: 330), time: 5.0 / 60 + 0.01))
        XCTAssertTrue(view.rig.isMoving, "inertia")
        let released = view.rig.pose.yaw
        view.rig.step(dt: 1.0 / 60)
        XCTAssertLessThan(view.rig.pose.yaw, released, "keeps turning the same way")
        for _ in 0..<60 { view.rig.step(dt: 1.0 / 60) }
        XCTAssertFalse(view.rig.isMoving, "stopped within a second")
        // 5 pt per frame = 2.1 rad/s; coasting adds about speed / damping = 0.21 rad (0.23 in 60 Hz steps).
        XCTAssertEqual(view.rig.pose.yaw - released, -0.22, accuracy: 0.03)

        // A mouse down stops a running inertia where it is.
        view.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 465, y: 330), time: 1))
        for i in 1...3 { view.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: 465 + 5 * i, y: 330), time: 1 + Double(i) / 60)) }
        view.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: 480, y: 330), time: 1 + 3.0 / 60))
        XCTAssertTrue(view.rig.isMoving)
        view.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 480, y: 330), time: 2))
        XCTAssertFalse(view.rig.isMoving)
    }

    func testReleasingAfterAPauseDoesNotCoast() {
        let (view, _) = presented()
        view.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 440, y: 330)))
        view.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: 460, y: 330), time: 0.1))
        view.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: 460, y: 330), time: 0.5))
        XCTAssertFalse(view.rig.isMoving)
    }

    func testPitchStopsShortOfVertical() {
        let (view, _) = presented()
        view.orbit(dx: 0, dy: -10_000)
        XCTAssertEqual(view.rig.pose.pitch, -89 * .pi / 180, accuracy: 1e-5)
        XCTAssertGreaterThan(view.cameraNode.simdWorldUp.y, 0, "never upside down")
    }

    func testGlideIsInterruptedByAKey() {
        let (view, _) = presented()
        view.look(.top, animated: true)
        view.rig.step(dt: 0.1)
        let midway = view.rig.pose
        view.keyDown(with: key(31, "o")) // not a movement key
        view.rig.step(dt: 1)
        XCTAssertEqual(view.rig.pose.pitch, midway.pitch)
        XCTAssertGreaterThan(view.rig.pose.pitch, -.pi / 2 + 0.01, "stopped before the top view")
    }

    func testDoubleClickRecentresOnTheHitPoint() {
        let (view, scene) = presented()
        let eye = view.cameraNode.simdWorldPosition, front = view.cameraNode.simdWorldFront
        let point = CGPoint(x: 440, y: 330)
        view.mouseDown(with: mouse(.leftMouseDown, point))
        view.mouseUp(with: mouse(.leftMouseUp, point))
        view.mouseDown(with: mouse(.leftMouseDown, point, clicks: 2))
        view.rig.step(dt: 0.15)
        XCTAssertTrue(view.rig.isMoving, "glides")
        view.rig.step(dt: 0.2)
        XCTAssertFalse(view.rig.isMoving)
        let hit = view.target
        let local = view.cameraNode.simdConvertPosition(hit, from: nil)
        XCTAssertEqual(local.x, 0, accuracy: 1e-3, "the hit point is now at the view centre")
        XCTAssertEqual(local.y, 0, accuracy: 1e-3)
        XCTAssertEqual(simd_dot(view.cameraNode.simdWorldFront, front), 1, accuracy: 1e-5, "same direction")
        XCTAssertLessThan(simd_distance(view.cameraNode.simdWorldPosition, hit), simd_distance(eye, hit) / 2, "came closer")
        let model = scene.modelRoot.simdConvertPosition(hit, from: nil)
        XCTAssertEqual(simd_reduce_max(abs(model - SIMD3(0.5, 0.5, 0.5))), 0.5, accuracy: 0.01, "on the near face: \(model)")
        view.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 5, y: 595), clicks: 2)) // empty sky: nothing changes
        view.rig.step(dt: 1)
        XCTAssertEqual(simd_distance(view.target, hit), 0, accuracy: 1e-5)
    }

    // MARK: Game editor

    func testRightDragLooksFromThePosition() {
        let (view, _) = presented()
        let before = view.rig.pose
        view.rightMouseDown(with: mouse(.rightMouseDown, CGPoint(x: 400, y: 300)))
        XCTAssertEqual(view.cursorHides, 1)
        view.rightMouseDragged(with: motion(.rightMouseDragged, button: .right, dx: 100, dy: -40)) // right and up
        XCTAssertEqual(view.rig.pose.yaw - before.yaw, -100 * 0.15 * .pi / 180, accuracy: 1e-4, "turns right")
        XCTAssertEqual(view.rig.pose.pitch - before.pitch, 40 * 0.15 * .pi / 180, accuracy: 1e-4, "looks up")
        XCTAssertEqual(view.rig.pose.position, before.position)
        view.rightMouseUp(with: mouse(.rightMouseUp, CGPoint(x: 400, y: 300)))
        XCTAssertEqual(view.cursorHides, 0)
    }

    func testKeysMoveByPhysicalPosition() {
        let (view, _) = presented()
        let speed = view.rig.speed
        XCTAssertEqual(speed, simd_length(SIMD3<Float>(3, 3, 1)) / 32, accuracy: 1e-5, "model diagonal / 32 per second")
        var start = view.rig.pose.position
        let forward = view.rig.pose.forward
        view.keyDown(with: key(13, "w"))
        view.rig.step(dt: 0.5)
        view.rig.step(dt: 0.5)
        XCTAssertEqual(simd_distance(view.rig.pose.position, start + forward * speed), 0, accuracy: 1e-4, "1 s of W = speed metres ahead")
        view.keyUp(with: key(13, "w", up: true))
        XCTAssertFalse(view.rig.isMoving)

        // AZERTY: the same key types "z"; ⇧ quadruples.
        start = view.rig.pose.position
        view.flagsChanged(with: NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: .shift, timestamp: 0, windowNumber: 0,
                                                 context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 56)!)
        view.keyDown(with: key(13, "z", flags: .shift))
        XCTAssertTrue(view.rig.keys.isEmpty, "⇧Z stays zoom extents unless looking around")
        view.rig.step(dt: 1) // the zoom extents glide
        view.rightMouseDown(with: mouse(.rightMouseDown, CGPoint(x: 400, y: 300)))
        start = view.rig.pose.position
        view.keyDown(with: key(13, "z", flags: .shift))
        view.rig.step(dt: 1)
        XCTAssertEqual(simd_distance(view.rig.pose.position, start), 4 * speed, accuracy: 1e-4)
        view.rightMouseUp(with: mouse(.rightMouseUp, CGPoint(x: 400, y: 300)))
        view.keyUp(with: key(13, "z", up: true))

        // Space goes up the model's Z, whatever the pitch.
        view.flagsChanged(with: NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                                 context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 56)!)
        start = view.rig.pose.position
        view.keyDown(with: key(49, " "))
        view.rig.step(dt: 1)
        XCTAssertEqual(simd_distance(view.rig.pose.position, start + SIMD3(0, 0, speed)), 0, accuracy: 1e-4)
        _ = view.resignFirstResponder()
        XCTAssertFalse(view.rig.isMoving, "losing focus lets go of the keys")
    }

    func testSpeedFollowsTheModelSize() {
        var big = SyntheticModel.cube()
        big.boundsMax = SIMD3(160, 0, 0)
        let (small, _) = presented()
        let (large, _) = presented(big)
        XCTAssertEqual(large.rig.speed, 5, accuracy: 1e-4, "160 m / 32")
        XCTAssertEqual(small.rig.speed, 0.136, accuracy: 1e-3)
        big.boundsMax = SIMD3(1000, 0, 0)
        XCTAssertEqual(presented(big).0.rig.speed, 12.5, accuracy: 1e-4, "capped")
        big.boundsMax = SIMD3(1, 0, 0)
        XCTAssertEqual(presented(big).0.rig.speed, 0.125, accuracy: 1e-4, "floored")
    }

    func testWheelWhileLookingChangesTheSpeed() {
        let (view, _) = presented()
        let event = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: 1, wheel2: 0, wheel3: 0)!
        view.rightMouseDown(with: mouse(.rightMouseDown, CGPoint(x: 400, y: 300)))
        let position = view.rig.pose.position
        view.scrollWheel(with: NSEvent(cgEvent: event)!)
        XCTAssertGreaterThan(view.rig.speedScale, 1)
        XCTAssertEqual(view.rig.pose.position, position, "no zoom while looking")
        for _ in 0..<40 { view.scrollWheel(with: NSEvent(cgEvent: event)!) }
        XCTAssertEqual(view.rig.speedScale, 16, "clamped")
        view.rightMouseUp(with: mouse(.rightMouseUp, CGPoint(x: 400, y: 300)))
    }

    // MARK: Trackpad

    func testTwoFingerScrollOrbitsOrZoomsOrPans() {
        let (view, _) = presented()
        var before = view.rig.pose
        view.scrollWheel(with: scroll(dx: 30, dy: 0, phase: 1))
        view.scrollWheel(with: scroll(dx: 30, dy: 0, phase: 2))
        XCTAssertNotEqual(view.rig.pose.yaw, before.yaw, "orbits")
        view.scrollWheel(with: scroll(dx: 0, dy: 0, phase: 4))

        ViewportView.twoFingerScrollZooms = true
        defer { ViewportView.twoFingerScrollZooms = false }
        before = view.rig.pose
        view.scrollWheel(with: scroll(dx: 0, dy: 20, phase: 1))
        XCTAssertEqual(view.rig.pose.yaw, before.yaw)
        XCTAssertNotEqual(view.rig.pose.position, before.position, "zooms")
        view.scrollWheel(with: scroll(dx: 0, dy: 0, phase: 4))

        before = view.rig.pose
        view.scrollWheel(with: scroll(dx: 40, dy: 0, phase: 1, flags: .maskAlternate))
        XCTAssertEqual(view.rig.pose.yaw, before.yaw)
        XCTAssertGreaterThan(simd_dot(view.rig.pose.position - before.position, before.right), 0, "⌥: pans, the model follows the fingers left")
    }

    /// Pinch = zoom towards the cursor: the point under it stays there, in perspective and in parallel.
    func testZoomKeepsThePointUnderTheCursor() throws {
        let (view, scene) = presented()
        let camera = view.cameraNode.camera!
        let corner = SIMD3<Float>(1, 0, 1)
        func screen(_ p: SIMD3<Float>) -> SIMD2<Float> {
            let l = view.cameraNode.simdConvertPosition(scene.modelRoot.simdConvertPosition(p, to: nil), from: nil)
            if camera.usesOrthographicProjection { return SIMD2(400, 300) + SIMD2(l.x, l.y) / Float(camera.orthographicScale) * 300 }
            return SIMD2(400, 300) + SIMD2(l.x, l.y) / -l.z / Float(tan(camera.fieldOfView * .pi / 360)) * 300
        }
        for perspective in [true, false] {
            view.isPerspective = perspective
            let before = screen(corner)
            XCTAssertGreaterThan(simd_distance(before, SIMD2(400, 300)), 10, "off the view centre")
            view.zoom(ratio: 0.8, at: CGPoint(x: CGFloat(before.x), y: CGFloat(before.y)))
            XCTAssertEqual(simd_distance(screen(corner), before), 0, accuracy: 0.05, "perspective \(perspective)")
        }
    }

    // MARK: Free fly

    func testFreeFlyAlwaysGivesTheCursorBack() {
        let (view, _) = presented()
        var changes: [Bool] = []
        view.onFreeFlyingChange = { changes.append($0) }
        view.isFreeFlying = true
        XCTAssertEqual(view.cursorHides, 1)
        let yaw = view.rig.pose.yaw
        view.mouseMoved(with: motion(.mouseMoved, button: .left, dx: 50, dy: 0))
        XCTAssertLessThan(view.rig.pose.yaw, yaw, "the mouse looks without a click")
        view.keyDown(with: key(53, "\u{1B}"))
        XCTAssertFalse(view.isFreeFlying, "Esc")
        XCTAssertEqual(view.cursorHides, 0)

        view.isFreeFlying = true
        view.rightMouseDown(with: mouse(.rightMouseDown, CGPoint(x: 400, y: 300)))
        view.rightMouseUp(with: mouse(.rightMouseUp, CGPoint(x: 400, y: 300)))
        XCTAssertEqual(view.cursorHides, 1, "still flying after a right click")
        view.keyDown(with: key(13, "w"))
        _ = view.resignFirstResponder()
        XCTAssertFalse(view.isFreeFlying, "losing focus")
        XCTAssertEqual(view.cursorHides, 0)
        XCTAssertFalse(view.rig.isMoving)

        view.rightMouseDown(with: mouse(.rightMouseDown, CGPoint(x: 400, y: 300)))
        view.isFreeFlying = true
        view.isFreeFlying = false
        XCTAssertEqual(view.cursorHides, 1, "the right button still looks")
        view.releaseInput() // window resigned key mid-drag
        XCTAssertEqual(view.cursorHides, 0)
        XCTAssertEqual(changes, [true, false, true, false, true, false])
    }

    // MARK: Polish

    /// A pick goes through edges to the face. SceneKit hit tests a `.line` element's indices as triangles: three
    /// segments above the face make a phantom triangle over the view centre, closer than the face.
    func testHitIgnoresEdgesInFrontOfFaces() throws {
        let quad = SKPModel.Mesh(material: nil, layer: 0, positions: [SIMD3(-5, -5, 0), SIMD3(5, -5, 0), SIMD3(5, 5, 0), SIMD3(-5, 5, 0)],
                                 normals: Array(repeating: SIMD3(0, 0, 1), count: 4), indices: [0, 1, 2, 0, 2, 3])
        let edge = SKPModel.EdgeSet(layer: 0, positions: [SIMD3(-4, -4, 0.5), SIMD3(4, -4, 0.5), SIMD3(0, 4, 0.5),
                                                          SIMD3(1, 4, 0.5), SIMD3(2, 4, 0.5), SIMD3(3, 4, 0.5)])
        let model = SKPModel(root: SKPModel.Definition(name: "", meshes: [quad], edges: [edge]), layers: [SKPModel.Layer(name: "Layer0", isVisible: true)],
                             boundsMin: SIMD3(-5, -5, 0), boundsMax: SIMD3(5, 5, 0.5),
                             fileInfo: SKPFileInfo(url: URL(fileURLWithPath: "/tmp/x.skp"), fileSize: 0, version: nil, versionLabel: nil, thumbnailPNG: nil))
        let view = ViewportView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        view.present(ViewportScene(model: model))
        view.apply(camera: SKPModel.Camera(position: SIMD3(0, 0, 10), target: .zero, up: SIMD3(0, 1, 0)), animated: false)
        let hit = try XCTUnwrap(view.hit(CGPoint(x: 400, y: 300)))
        XCTAssertEqual(hit.z, 0, accuracy: 1e-3, "the face, not the edge above it")
    }

    /// SSAO follows every projection change (it is wrong in parallel).
    func testAmbientOcclusionFollowsProjection() {
        let (view, scene) = presented()
        let camera = view.cameraNode.camera!
        XCTAssertEqual(camera.screenSpaceAmbientOcclusionIntensity, 0, "off by default, like the app")
        view.ambientOcclusionEnabled = true
        XCTAssertEqual(camera.screenSpaceAmbientOcclusionIntensity, 0.7, accuracy: 1e-6)
        view.isPerspective = false
        XCTAssertEqual(camera.screenSpaceAmbientOcclusionIntensity, 0)
        view.isPerspective = true
        XCTAssertEqual(camera.screenSpaceAmbientOcclusionIntensity, 0.7, accuracy: 1e-6)
        var parallel = scene.model.scenes[0].camera!
        parallel.isPerspective = false
        view.apply(camera: parallel, animated: true)
        XCTAssertEqual(camera.screenSpaceAmbientOcclusionIntensity, 0, "a scene glide to a parallel view")
        view.apply(camera: scene.model.scenes[0].camera!, animated: false)
        XCTAssertEqual(camera.screenSpaceAmbientOcclusionIntensity, 0.7, accuracy: 1e-6)
    }

    // MARK: Review fixes

    /// A SketchUp plan view pitched 7° past vertical (forward slightly south, up north) keeps its screen up.
    func testPlanViewPastVerticalKeepsItsUp() {
        let forward = simd_normalize(SIMD3<Float>(0, -0.126, -0.992)), up = simd_normalize(SIMD3<Float>(0, 0.992, -0.126))
        var pose = CameraRig.Pose()
        (pose.yaw, pose.pitch) = CameraRig.orientation(forward: forward, up: up)
        XCTAssertLessThan(acos(min(1, simd_dot(pose.forward, forward))) * 180 / .pi, 0.1)
        XCTAssertLessThan(acos(min(1, simd_dot(pose.up, up))) * 180 / .pi, 0.1, "not turned 180°")
        XCTAssertLessThan(pose.pitch, -.pi / 2, "past vertical")
    }

    /// Every camera of the reference files: the rig's orientation is the look-at's (roll aside), within 0.1°.
    func testReferenceFileCamerasMatchLookAt() throws {
        guard SketchUpAPI.locate() != nil else { throw XCTSkip("SketchUp not installed") }
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/VerreMirroir.skp").path
        let files = [fixture, "/Users/adrien/Dropbox/AMCB-MM-Diff/TOUR 2018/0930-Arles/3D/MM_Arles_3D_V003.skp",
                     "/Users/adrien/Downloads/B-SEINE MUSICALE-GRANDE SALLE TECHNIQ V40.skp"].filter { FileManager.default.fileExists(atPath: $0) }
        var worst: (error: Float, name: String) = (0, "")
        var count = 0
        for file in files {
            let model = try SKPReader.load(URL(fileURLWithPath: file))
            let cameras = [("file camera", model.camera)] + model.scenes.map { ($0.name, $0.camera) }
            for case let (name, camera?) in cameras {
                let node = SCNNode()
                node.simdPosition = camera.position
                node.simdLook(at: camera.target, up: camera.up, localFront: SCNNode.simdLocalFront)
                let pose = CameraRig.pose(camera)
                let error = max(acos(min(1, simd_dot(pose.forward, node.simdWorldFront))), acos(min(1, simd_dot(pose.up, node.simdWorldUp)))) * 180 / .pi
                if error > worst.error { worst = (error, "\((file as NSString).lastPathComponent) / \(name)") }
                count += 1
            }
        }
        print("Camera orientation: \(count) cameras, worst \(worst.error)° (\(worst.name))")
        XCTAssertLessThan(worst.error, 0.1, worst.name)
    }

    /// A scene glide to a parallel view starts from the framing shown (no jump of the scale), and back.
    func testProjectionChangeGlidesFromTheShownFraming() {
        let (view, scene) = presented()
        let camera = view.cameraNode.camera!
        let tanHalf = Double(tan(camera.fieldOfView * .pi / 360))
        camera.orthographicScale = 123 // stale value from an earlier parallel view
        let shown = Double(view.rig.pose.distance) * tanHalf
        var parallel = scene.model.scenes[0].camera!
        parallel.isPerspective = false
        parallel.orthoHeight = 3
        view.apply(camera: parallel, animated: true)
        XCTAssertTrue(camera.usesOrthographicProjection)
        XCTAssertEqual(camera.orthographicScale, shown, accuracy: 1e-4, "first frame: the perspective framing")
        view.rig.step(dt: 1)
        XCTAssertEqual(camera.orthographicScale, 1.5, accuracy: 1e-6, "orthoHeight / 2 at the end")

        let pose = view.rig.pose
        view.apply(camera: scene.model.scenes[0].camera!, animated: true)
        let distance = Float(1.5 / tanHalf)
        let start = pose.position + pose.forward * (pose.distance - distance)
        XCTAssertEqual(simd_distance(view.rig.pose.position, start), 0, accuracy: 1e-4, "the equivalent eye position")
        view.apply(camera: parallel, animated: false)
        XCTAssertEqual(camera.orthographicScale, 1.5, accuracy: 1e-6)
    }

    /// A two-finger orbit coasts after the fingers lift (the end event carries no motion).
    func testTrackpadOrbitCoasts() {
        let (view, _) = presented()
        view.scrollWheel(with: scroll(dx: 20, dy: 0, phase: 1))
        view.scrollWheel(with: scroll(dx: 20, dy: 0, phase: 2))
        view.scrollWheel(with: scroll(dx: 0, dy: 0, phase: 4))
        XCTAssertTrue(view.rig.isMoving, "coasts")
        let yaw = view.rig.pose.yaw
        view.rig.step(dt: 1.0 / 60)
        XCTAssertLessThan(view.rig.pose.yaw, yaw, "keeps turning the same way")
        for _ in 0..<120 { view.rig.step(dt: 1.0 / 60) }
        XCTAssertFalse(view.rig.isMoving, "the spin decays")
    }

    /// AZERTY: holding Z during free-fly or right-click look then pressing ⇧ goes faster; it is not ⇧Z (zoom extents).
    func testShiftWhileHoldingZIsFastNotZoomExtents() {
        let (view, _) = presented()
        view.isFreeFlying = true
        view.keyDown(with: key(13, "z"))
        view.flagsChanged(with: flags(.shift, keyCode: 56))
        view.keyDown(with: key(13, "Z", flags: .shift, repeated: true))
        XCTAssertTrue(view.rig.fast)
        XCTAssertEqual(view.rig.keys, [13])
        view.keyUp(with: key(13, "z", up: true))
        XCTAssertFalse(view.rig.isMoving, "no zoom extents glide")
    }

    /// Z resets the view to its initial framing; ⇧Z zooms extents.
    func testZKeyResetsViewAndShiftZZoomsExtents() {
        let view = ViewportView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        view.present(ViewportScene(model: SyntheticModel.cube()))
        let initialPosition = view.rig.pose.position
        view.look(.top, animated: false)
        XCTAssertGreaterThan(simd_distance(view.rig.pose.position, initialPosition), 0.1)

        var didCallback = false
        view.onResetView = { _ in didCallback = true }
        view.keyDown(with: key(6, "z"))
        view.rig.step(dt: 1)
        XCTAssertTrue(didCallback)
        XCTAssertEqual(simd_distance(view.rig.pose.position, initialPosition), 0, accuracy: 1e-4, "Z restores initial view")

        view.look(.front, animated: false)
        view.keyDown(with: key(6, "Z", flags: .shift))
        XCTAssertTrue(view.rig.isMoving, "⇧Z starts zoom extents glide")
        view.rig.step(dt: 1)
        XCTAssertFalse(view.rig.isMoving)
    }

    /// AppKit sends no keyUp for a key released while ⌘ is held: ⌘ lets go of the movement keys.
    func testCommandReleasesHeldKeys() {
        let (view, _) = presented()
        view.keyDown(with: key(13, "w"))
        XCTAssertTrue(view.rig.isMoving)
        view.flagsChanged(with: flags(.command, keyCode: 55))
        XCTAssertTrue(view.rig.keys.isEmpty)
        XCTAssertFalse(view.rig.isMoving)
    }

    /// Double-click in parallel: a third of the scale, the eye keeps its depth (the near plane must not cut the model).
    func testParallelDoubleClickScalesOnly() {
        let (view, _) = presented()
        view.isPerspective = false
        let camera = view.cameraNode.camera!
        let pose = view.rig.pose, scale = camera.orthographicScale
        view.recentre(at: CGPoint(x: 440, y: 330))
        view.rig.step(dt: 1)
        XCTAssertEqual(camera.orthographicScale, scale / 3, accuracy: 1e-6)
        let depth = simd_dot(view.rig.pose.target - view.rig.pose.position, pose.forward)
        XCTAssertEqual(simd_dot(view.rig.pose.position - pose.position, pose.forward), 0, accuracy: 1e-3, "no move along the view axis")
        XCTAssertGreaterThan(depth, 0)
    }

    // MARK: 2D AutoCAD Navigation

    func test2DCADNavigationPansOnDragAndScrollAndRotatesPlanOnlyWithOption() {
        let edges = SKPModel.EdgeSet(
            layer: 0,
            positions: [
                SIMD3(-10, -5, 0), SIMD3(10, -5, 0),
                SIMD3(10, -5, 0), SIMD3(10, 5, 0),
                SIMD3(10, 5, 0), SIMD3(-10, 5, 0),
                SIMD3(-10, 5, 0), SIMD3(-10, -5, 0),
            ]
        )
        let root = SKPModel.Definition(name: "", meshes: [], edges: [edges], children: [])
        let model = SKPModel(
            root: root,
            definitions: [],
            materials: [],
            layers: [SKPModel.Layer(name: "0", isVisible: true)],
            scenes: [],
            camera: nil,
            boundsMin: SIMD3(-10, -5, 0),
            boundsMax: SIMD3(10, 5, 0),
            fileInfo: SKPFileInfo(url: URL(fileURLWithPath: "/tmp/plan2d.dwg"), fileSize: 512, version: "AC1032", versionLabel: "AutoCAD 2018", thumbnailPNG: nil)
        )
        let view = ViewportView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        view.present(ViewportScene(model: model))

        XCTAssertTrue(view.is2DNavigationMode)
        XCTAssertFalse(view.isPerspective, "2D CAD plan starts in parallel projection")
        XCTAssertEqual(view.rig.pose.pitch, -.pi / 2, accuracy: 1e-5, "looking straight down")

        // 1. Plain left-drag translates (pans) the 2D plan without rotating
        let startPose = view.rig.pose
        view.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 400, y: 300)))
        view.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: 460, y: 340), time: 0.016))
        view.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: 460, y: 340), time: 0.032))
        XCTAssertEqual(view.rig.pose.yaw, startPose.yaw, accuracy: 1e-5, "left-drag does not rotate in 2D mode")
        XCTAssertEqual(view.rig.pose.pitch, -.pi / 2, accuracy: 1e-5, "pitch stays top-down")
        XCTAssertGreaterThan(simd_distance(SIMD2(view.rig.pose.position.x, view.rig.pose.position.y), SIMD2(startPose.position.x, startPose.position.y)), 0.1, "left-drag pans in XY")

        // 2. Two-finger trackpad scroll translates (pans) in the natural direction (dx > 0 moves camera left so plan moves right)
        let beforeScroll = view.rig.pose
        view.scrollWheel(with: scroll(dx: 40, dy: 20, phase: 1))
        view.scrollWheel(with: scroll(dx: 40, dy: 20, phase: 2))
        view.scrollWheel(with: scroll(dx: 0, dy: 0, phase: 4))
        XCTAssertEqual(view.rig.pose.yaw, beforeScroll.yaw, accuracy: 1e-5, "trackpad scroll does not orbit in 2D mode")
        XCTAssertEqual(view.rig.pose.pitch, -.pi / 2, accuracy: 1e-5)
        XCTAssertLessThan(view.rig.pose.position.x, beforeScroll.position.x, "scrolling right moves camera left so plan moves right")
        XCTAssertGreaterThan(view.rig.pose.position.y, beforeScroll.position.y, "scrolling down (dy > 0 -> -dy < 0) moves camera up so plan moves down")

        // 3. Option (Alt) + left-drag rotates the 2D plan in-plane around Z while keeping pitch == -π/2
        let beforeAlt = view.rig.pose
        view.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 400, y: 300), flags: .option))
        view.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: 450, y: 380), time: 0.1, flags: .option))
        view.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: 450, y: 380), time: 0.2, flags: .option))
        XCTAssertEqual(view.rig.pose.yaw - beforeAlt.yaw, -50 * 0.4 * .pi / 180, accuracy: 1e-4, "Option-drag rotates yaw in-plane")
        XCTAssertEqual(view.rig.pose.pitch, -.pi / 2, accuracy: 1e-5, "vertical motion during Option-drag never tilts out of the 2D plane")
        XCTAssertEqual(simd_distance(view.rig.pose.forward, SIMD3(0, 0, -1)), 0, accuracy: 1e-5)

        // 4. Smooth zoom inertia glides smoothly over subsequent frames
        let scaleBeforeZoom = view.orthographicScale
        view.zoomStep(ratio: 0.75)
        let scaleImmediate = view.orthographicScale
        XCTAssertLessThan(scaleImmediate, scaleBeforeZoom, "Immediate 40% zoom step starts on frame 0")
        XCTAssertTrue(view.rig.isMoving, "Remaining 60% zoom glides via CameraRig inertia")
        for _ in 0..<45 { view.rig.step(dt: 1.0 / 60.0) }
        XCTAssertEqual(view.orthographicScale, scaleBeforeZoom * 0.75, accuracy: scaleBeforeZoom * 0.01, "Smooth zoom converges to exact target scale")
    }
}
