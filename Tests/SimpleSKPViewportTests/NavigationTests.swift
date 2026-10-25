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

    private func key(_ code: UInt16, _ characters: String, up: Bool = false, flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: up ? .keyUp : .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                         context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
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
        XCTAssertEqual(speed, simd_length(SIMD3<Float>(3, 3, 1)) / 8, accuracy: 1e-5, "model diagonal / 8 per second")
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
        XCTAssertEqual(large.rig.speed, 20, accuracy: 1e-4, "160 m / 8")
        XCTAssertEqual(small.rig.speed, 0.545, accuracy: 1e-3)
        big.boundsMax = SIMD3(1000, 0, 0)
        XCTAssertEqual(presented(big).0.rig.speed, 50, accuracy: 1e-4, "capped")
        big.boundsMax = SIMD3(1, 0, 0)
        XCTAssertEqual(presented(big).0.rig.speed, 0.5, accuracy: 1e-4, "floored")
    }

    func testWheelWhileLookingChangesTheSpeed() {
        let (view, _) = presented()
        let event = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: 1, wheel2: 0, wheel3: 0)!
        view.rightMouseDown(with: mouse(.rightMouseDown, CGPoint(x: 400, y: 300)))
        let position = view.rig.pose.position
        view.scrollWheel(with: NSEvent(cgEvent: event)!)
        XCTAssertGreaterThan(view.rig.speedScale, 1)
        XCTAssertEqual(view.rig.pose.position, position, "no zoom while looking")
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
}
