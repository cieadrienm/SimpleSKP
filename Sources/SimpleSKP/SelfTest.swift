import AppKit
import SceneKit
import SimpleSKPCore
import SimpleSKPViewport

/// `SimpleSKP --self-test [file.skp]`: PASS/FAIL lines, exit 1 on any FAIL. A missing framework is INFO here (the
/// unbundled `.build` binary may have none); reading the given file then fails.
@MainActor
enum SelfTest {
    static func runAndExit(file: String?) -> Never {
        var failures = 0
        func check(_ condition: Bool, _ message: String) {
            if condition {
                print("PASS: \(message)")
            } else {
                failures += 1
                fputs("FAIL: \(message)\n", stderr)
            }
        }

        // 1. Header of a synthetic file, as SketchUp writes it (UTF-16LE with length-prefixed strings).
        var header = Data([0xFF, 0xFE, 0xFF, 0x0E])
        header.append("SketchUp Model".data(using: .utf16LittleEndian)!)
        header.append(contentsOf: [0xFF, 0xFE, 0xFF, 0x0A])
        header.append("{17.3.116}".data(using: .utf16LittleEndian)!)
        let info = SKPFileInfo.parse(header: header, url: URL(fileURLWithPath: "/tmp/self-test.skp"), fileSize: header.count)
        check(info.version == "17.3.116" && info.versionLabel == "SketchUp 2017", "Header parse → 17.3.116, SketchUp 2017")

        // 2. SketchUp's framework.
        if let location = SketchUpAPI.locate() {
            print("PASS: SketchUp framework found at \(location.frameworkURL.path) (\(location.origin ?? "SIMPLESKP_SKETCHUP_SDK"))")
        } else {
            print("INFO: SketchUp framework not found — files show their thumbnail only")
        }

        // 3. Scene of the synthetic cube.
        let scene = ViewportScene(model: SyntheticModel.cube())
        let nodes = scene.scene.rootNode.childNodes { _, _ in true }.count
        check(nodes > 0, "Cube scene has \(nodes) nodes")

        // 4. Rendered view.
        let view = ViewportView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        view.present(scene)
        check(Snapshot.isNonUniform(view.snapshot()), "Viewport snapshot of the cube is non-uniform")

        // 5. A real file.
        if let file {
            do {
                let model = try SKPReader.load(URL(fileURLWithPath: (file as NSString).expandingTildeInPath))
                let s = model.stats
                check(s.faces > 0, "\(file): \(s.faces) faces, \(s.edges) edges, \(s.instances) instances, \(s.definitions) definitions, \(model.layers.count) layers, \(model.scenes.count) scenes in \(String(format: "%.2f", s.loadSeconds)) s")
            } catch {
                check(false, "\(file): \(error.localizedDescription)")
            }
        }

        if failures == 0 {
            print("SimpleSKP self-test: ALL PASSED")
            exit(0)
        }
        fputs("SimpleSKP self-test: \(failures) FAILURE(S)\n", stderr)
        exit(1)
    }
}
