import XCTest
import SceneKit
import Metal
@testable import SimpleSKPViewport
import SimpleSKPCore

/// Frame-time harness (manual, needs SketchUp): the app's scene and camera (as ViewportView placed it on 2026-10-25,
/// copied here so the navigation rewrite does not move the benchmark views) rendered offscreen by `SCNRenderer` at
/// 2760×1640 with MSAA ×4, mean of N frames (CPU encode + GPU, serial).
/// `SIMPLESKP_BENCH=file.skp [SIMPLESKP_BENCH_SCENES="VUE DESSUS COUPE,FOH"] [SIMPLESKP_BENCH_OUT=dir]
///  [SIMPLESKP_BENCH_REF=dir] [SIMPLESKP_BENCH_AO=0] [SIMPLESKP_BENCH_SHADOWS=0] [SIMPLESKP_BENCH_PLAIN=1]
///  swift test -c release -Xswiftc -enable-testing --filter FrameTimeHarness`
/// Views: the file camera, iso with the file's layers, then each named scene (its layers and camera).
/// OUT writes one PNG per view; REF compares each PNG with the same-named one there.
@MainActor
final class FrameTimeHarness: XCTestCase {
    func testFrameTimes() throws {
        let env = ProcessInfo.processInfo.environment
        guard let file = env["SIMPLESKP_BENCH"] else { throw XCTSkip("bench only") }
        let model = try SKPReader.load(URL(fileURLWithPath: file))
        print(String(format: "BENCH loaded: footprint %.0f MB, peak %.0f MB", footprintMB(), footprintMB(peak: true)))
        let start = CFAbsoluteTimeGetCurrent()
        let scene = ViewportScene(model: model)
        let build = CFAbsoluteTimeGetCurrent() - start
        let rig = Rig(scene)
        let camera = rig.node.camera!
        if env["SIMPLESKP_BENCH_PLAIN"] != "1" { Rendering.configure(camera: camera) } // PLAIN: the camera as before the shading pass
        if env["SIMPLESKP_BENCH_AO"] == "0" { Rendering.setAmbientOcclusion(false, on: camera) }
        if env["SIMPLESKP_BENCH_SHADOWS"] == "0" { scene.shadowsEnabled = false }
        print(String(format: "BENCH %@: scene build %.3f s, footprint %.0f MB", (file as NSString).lastPathComponent, build, footprintMB()))

        let device = MTLCreateSystemDefaultDevice()!
        let queue = device.makeCommandQueue()!
        let renderer = SCNRenderer(device: device, options: nil)
        renderer.scene = scene.scene
        renderer.pointOfView = rig.node
        let (w, h) = (2760, 1640)
        func texture(_ format: MTLPixelFormat, samples: Int) -> MTLTexture {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: w, height: h, mipmapped: false)
            d.textureType = samples > 1 ? .type2DMultisample : .type2D
            d.sampleCount = samples
            d.usage = .renderTarget
            d.storageMode = .private
            return device.makeTexture(descriptor: d)!
        }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture(.bgra8Unorm, samples: 4)
        pass.colorAttachments[0].resolveTexture = texture(.bgra8Unorm, samples: 1)
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .multisampleResolve
        pass.depthAttachment.texture = texture(.depth32Float, samples: 4)
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.storeAction = .dontCare

        var views: [(String, () -> Void)] = [("file camera", {}), ("iso", { rig.iso() })]
        for name in (env["SIMPLESKP_BENCH_SCENES"] ?? "").split(separator: ",").map(String.init) {
            guard let s = model.scenes.first(where: { $0.name == name }) else { print("BENCH no scene \(name)"); continue }
            views.append((name, {
                if let hidden = s.hiddenLayers.map(Set.init) {
                    for i in model.layers.indices { scene.setLayer(i, visible: !hidden.contains(i)) }
                }
                if let c = s.camera { rig.apply(c) }
            }))
        }
        var time = 0.0
        for (name, setUp) in views {
            let setUpStart = CFAbsoluteTimeGetCurrent()
            setUp()
            if env["SIMPLESKP_BENCH_PLAIN"] != "1" { Rendering.setAmbientOcclusion(env["SIMPLESKP_BENCH_AO"] != "0", on: camera) } // projection may have changed
            let setUpMs = (CFAbsoluteTimeGetCurrent() - setUpStart) * 1000
            SCNTransaction.flush() // no run loop here: push the camera and layer changes to the presentation tree
            func frame() -> (cpu: Double, total: Double) {
                let buffer = queue.makeCommandBuffer()!
                let t = CFAbsoluteTimeGetCurrent()
                renderer.render(atTime: time, viewport: CGRect(x: 0, y: 0, width: w, height: h), commandBuffer: buffer, passDescriptor: pass)
                let cpu = CFAbsoluteTimeGetCurrent() - t
                buffer.commit()
                buffer.waitUntilCompleted()
                time += 1 / 60.0
                return (cpu, CFAbsoluteTimeGetCurrent() - t)
            }
            for _ in 0..<5 { _ = frame() }
            let n = 30
            var cpu = 0.0, total = 0.0
            for _ in 0..<n { let f = frame(); cpu += f.cpu; total += f.total }
            // A navigation pick: a segment from the eye along the view axis, faces only.
            let eye = rig.node.simdWorldPosition, far = eye + rig.node.simdWorldFront * 10_000
            let hitStart = CFAbsoluteTimeGetCurrent()
            let hit = scene.scene.rootNode.hitTestWithSegment(from: SCNVector3(eye), to: SCNVector3(far),
                                                              options: [SCNHitTestOption.backFaceCulling.rawValue: false, SCNHitTestOption.categoryBitMask.rawValue: 1])
                .first
            let hitMs = (CFAbsoluteTimeGetCurrent() - hitStart) * 1000
            print(String(format: "BENCH %@: %.1f ms/frame (%.0f fps), CPU encode %.1f ms, footprint %.0f MB, centre hit test %.1f ms (%@), view set-up %.0f ms, %@", name,
                         total / Double(n) * 1000, Double(n) / total, cpu / Double(n) * 1000, footprintMB(), hitMs, hit == nil ? "miss" : "hit", setUpMs, camera.usesOrthographicProjection ? "parallel" : "perspective"))
            if let out = env["SIMPLESKP_BENCH_OUT"] {
                let image = renderer.snapshot(atTime: time, with: CGSize(width: w, height: h), antialiasingMode: .multisampling4X)
                let url = URL(fileURLWithPath: out).appendingPathComponent("\(name).png")
                let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
                try rep.representation(using: .png, properties: [:])!.write(to: url)
                if let ref = env["SIMPLESKP_BENCH_REF"], let old = NSBitmapImageRep(data: (try? Data(contentsOf: URL(fileURLWithPath: ref)
                                                                                    .appendingPathComponent("\(name).png"))) ?? Data()) {
                    print("BENCH \(name): " + compare(old, rep))
                }
            }
        }
        print(String(format: "BENCH peak footprint %.0f MB", footprintMB(peak: true)))
    }

    /// Share of pixels whose largest channel difference exceeds 16 / 255, and the mean absolute difference.
    private func compare(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) -> String {
        guard a.pixelsWide == b.pixelsWide, a.pixelsHigh == b.pixelsHigh, a.bitsPerPixel == b.bitsPerPixel,
              a.bytesPerRow == b.bytesPerRow, let pa = a.bitmapData, let pb = b.bitmapData else { return "format differs" }
        var differing = 0, sum = 0
        let step = a.bitsPerPixel / 8
        for y in 0..<a.pixelsHigh {
            for x in 0..<a.pixelsWide {
                let o = y * a.bytesPerRow + x * step
                let m = max(abs(Int(pa[o]) - Int(pb[o])), abs(Int(pa[o + 1]) - Int(pb[o + 1])), abs(Int(pa[o + 2]) - Int(pb[o + 2])))
                sum += m
                if m > 16 { differing += 1 }
            }
        }
        let total = Double(a.pixelsWide * a.pixelsHigh)
        return String(format: "%.3f %% pixels differ (> 16/255), mean diff %.2f / 255", Double(differing) / total * 100, Double(sum) / total)
    }

    private func footprintMB(peak: Bool = false) -> Double {
        var info = rusage_info_v4()
        let ok = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0) }
        }
        guard ok == 0 else { return -1 }
        return Double(peak ? info.ri_lifetime_max_phys_footprint : info.ri_phys_footprint) / 1_048_576
    }
}

/// The camera the app used when the baseline was measured: under the model root, SketchUp's 35° vertical FOV,
/// file cameras verbatim, iso framed on the visible bounds for a 1380 × 820 pt view; headlight on the camera.
@MainActor
private final class Rig {
    let node = SCNNode()
    let scene: ViewportScene

    init(_ scene: ViewportScene) {
        self.scene = scene
        let camera = SCNCamera()
        camera.automaticallyAdjustsZRange = true
        camera.projectionDirection = .vertical
        camera.fieldOfView = 35
        node.camera = camera
        scene.modelRoot.addChildNode(node)
        node.addChildNode(scene.headlight)
        if let c = scene.model.camera { apply(c) } else { iso() }
    }

    func apply(_ c: SKPModel.Camera) {
        node.simdPosition = c.position
        node.simdLook(at: scene.modelRoot.simdConvertPosition(c.target, to: nil),
                      up: scene.modelRoot.simdConvertVector(c.up, to: nil), localFront: SCNNode.simdLocalFront)
        node.camera!.usesOrthographicProjection = !c.isPerspective
        node.camera!.fieldOfView = CGFloat(c.fovDegrees)
        if !c.isPerspective { node.camera!.orthographicScale = Double(c.orthoHeight / 2) }
    }

    func iso() {
        let bounds = scene.visibleBounds
        let centre = scene.modelRoot.simdConvertPosition((bounds.min + bounds.max) / 2, to: nil)
        let radius = max(simd_length(bounds.max - bounds.min) / 2, 0.01)
        let vfov = Float(node.camera!.fieldOfView) * .pi / 180, hfov = 2 * atan(tan(vfov / 2) * 1380 / 820)
        let direction = scene.modelRoot.simdConvertVector(simd_normalize(SIMD3(1, -1, 1)), to: nil)
        node.simdWorldPosition = centre + direction * (radius / sin(min(vfov, hfov) / 2) * 1.05)
        node.simdLook(at: centre, up: scene.modelRoot.simdConvertVector(SIMD3(0, 0, 1), to: nil), localFront: SCNNode.simdLocalFront)
        if node.camera!.usesOrthographicProjection { node.camera!.orthographicScale = Double(radius * 1.05) }
    }
}
