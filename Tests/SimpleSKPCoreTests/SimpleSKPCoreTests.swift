import XCTest
import simd
@testable import SimpleSKPCore

final class SimpleSKPCoreTests: XCTestCase {
    static let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/VerreMirroir.skp")

    // MARK: Header

    func testFixtureHeader() throws {
        let info = try SKPFileInfo.read(Self.fixture)
        XCTAssertEqual(info.version, "8.0.3161")
        XCTAssertEqual(info.versionLabel, "SketchUp 8")
        let png = try XCTUnwrap(info.thumbnailPNG)
        XCTAssertEqual(png.count, 893)
        XCTAssertEqual(Array(png.prefix(8)), [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        XCTAssertEqual(Array(png.suffix(8).prefix(4)), Array("IEND".utf8))
        XCTAssertGreaterThan(info.fileSize, 1901 + 893)
    }

    func testSyntheticHeader() {
        var header = Data([0xFF, 0xFE, 0xFF, 0x0E]) + "SketchUp Model".data(using: .utf16LittleEndian)!
        header += Data([0xFF, 0xFE, 0xFF, 0x0A]) + "{17.3.116}".data(using: .utf16LittleEndian)!
        let info = SKPFileInfo.parse(header: header, url: URL(fileURLWithPath: "/x.skp"), fileSize: header.count)
        XCTAssertEqual(info.version, "17.3.116")
        XCTAssertEqual(info.versionLabel, "SketchUp 2017")
        XCTAssertNil(info.thumbnailPNG)
    }

    func testVersionLabels() {
        XCTAssertEqual(SKPFileInfo.label("3.0.1"), "SketchUp 3")
        XCTAssertEqual(SKPFileInfo.label("7.1.6087"), "SketchUp 7")
        XCTAssertEqual(SKPFileInfo.label("8.0.3161"), "SketchUp 8")
        XCTAssertEqual(SKPFileInfo.label("13.0.4812"), "SketchUp 2013")
        XCTAssertEqual(SKPFileInfo.label("23.0.396"), "SketchUp 2023")
        XCTAssertNil(SKPFileInfo.label("beta.1"), "no numeric major: no label, not « SketchUp 0 »")
    }

    /// A scene that does not save layer visibility maps to nil (layers left as they are), not to « all shown ».
    func testSceneHiddenLayersMapping() {
        XCTAssertNil(SKPReader.hiddenLayers(saved: false) { XCTFail("not read"); return [1] })
        XCTAssertEqual(SKPReader.hiddenLayers(saved: true) { [1, 3] }, [1, 3])
        XCTAssertEqual(SKPReader.hiddenLayers(saved: true) { [] }, [])
    }

    func testNonSketchUpFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("simpleskp-random-\(UUID().uuidString).skp")
        try Data((0..<4096).map { _ in UInt8.random(in: 0...255) }).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let info = try SKPFileInfo.read(url)
        XCTAssertNil(info.version)
        XCTAssertNil(info.versionLabel)
    }

    func testMissingFileThrows() {
        XCTAssertThrowsError(try SKPFileInfo.read(URL(fileURLWithPath: "/nonexistent/none.skp"))) { error in
            guard case SKPError.unreadable = error else { return XCTFail("\(error)") }
        }
    }

    // MARK: Conversions

    func testTransformIdentity() {
        let identity: [Double] = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]
        XCTAssertEqual(SKPReader.transform(identity), matrix_identity_float4x4)
    }

    func testTransformNormalisesUniformScale() {
        let values: [Double] = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 100, 0, 0, 0.5]
        let m = SKPReader.transform(values)
        XCTAssertEqual(m.columns.0, SIMD4(2, 0, 0, 0))
        XCTAssertEqual(m.columns.1, SIMD4(0, 2, 0, 0))
        XCTAssertEqual(m.columns.2, SIMD4(0, 0, 2, 0))
        XCTAssertEqual(m.columns.3.x, Float(200 * 0.0254), accuracy: 1e-5)
        XCTAssertEqual(m.columns.3.w, 1)
    }

    func testVerticalFOV() {
        XCTAssertEqual(SKPReader.verticalFOV(fov: 35, isHeight: true, aspect: 2), 35)
        XCTAssertEqual(SKPReader.verticalFOV(fov: 90, isHeight: false, aspect: 1), 90, accuracy: 1e-4)
        XCTAssertEqual(SKPReader.verticalFOV(fov: 90, isHeight: false, aspect: 2), 53.1301, accuracy: 1e-3)
    }

    // MARK: SketchUp API

    func testLocateSketchUp() throws {
        // Asserted on the SketchUp.app candidate itself: `$SIMPLESKP_SKETCHUP_SDK` may put another copy first.
        let host = SketchUpAPI.candidates().first {
            $0.appVersion != nil && FileManager.default.fileExists(atPath: $0.frameworkURL.appendingPathComponent("SketchUpAPI").path)
        }
        try XCTSkipUnless(host != nil, "no SketchUp.app installed")
        XCTAssertNotNil(SketchUpAPI.locate())
        XCTAssertFalse(host?.appVersion?.isEmpty ?? true, "\(String(describing: host))")
    }

    /// Runs `body` with environment variables set (nil: unset), then restores them.
    private func withEnvironment<T>(_ values: [String: String?], _ body: () throws -> T) rethrows -> T {
        let saved = values.keys.map { ($0, getenv($0).map { String(cString: $0) }) }
        defer { for (name, value) in saved { if let value { setenv(name, value, 1) } else { unsetenv(name) } } }
        for (name, value) in values { if let value { setenv(name, value, 1) } else { unsetenv(name) } }
        return try body()
    }

    func testLocateHonoursSDKVariable() throws {
        let found = withEnvironment(["SIMPLESKP_BUNDLED_SDK_ONLY": nil]) {
            SketchUpAPI.candidates().map(\.frameworkURL.path).first {
                $0.hasPrefix("/Applications/Unity/Hub/Editor/") && FileManager.default.fileExists(atPath: $0 + "/SketchUpAPI")
            }
        }
        guard let unity = found else { throw XCTSkip("no Unity copy of the SDK") }
        try withEnvironment(["SIMPLESKP_SKETCHUP_SDK": unity, "SIMPLESKP_BUNDLED_SDK_ONLY": "1"]) {
            let location = try XCTUnwrap(SketchUpAPI.locate())
            XCTAssertEqual(location.frameworkURL.path, unity)
            XCTAssertNil(location.appVersion)
            XCTAssertFalse(location.isBundled)
        }
    }

    /// The test runner has no bundled framework: with the installed copies ruled out, nothing is found.
    func testBundledOnlyWithoutBundledFrameworkFindsNothing() {
        withEnvironment(["SIMPLESKP_SKETCHUP_SDK": nil, "SIMPLESKP_BUNDLED_SDK_ONLY": "1"]) {
            XCTAssertNil(SketchUpAPI.locate())
            XCTAssertEqual(SketchUpAPI.searchedURLs.count, 1)
            XCTAssertTrue(SketchUpAPI.searchedURLs[0].path.hasSuffix("Contents/Frameworks/SketchUpAPI.framework"))
        }
    }

    func testReadFixture() throws {
        guard SketchUpAPI.locate() != nil else { throw XCTSkip("SketchUp not installed") }
        let model = try SKPReader.load(Self.fixture)
        XCTAssertEqual(model.stats.faces, 18)
        XCTAssertEqual(model.stats.edges, 36)
        XCTAssertEqual(model.materials.count, 2)
        XCTAssertGreaterThanOrEqual(model.layers.count, 1)
        XCTAssertGreaterThanOrEqual(model.stats.triangles, 18)
        XCTAssertEqual(model.fileInfo.version, "8.0.3161")
        let meshes = ([model.root] + model.definitions).flatMap(\.meshes)
        XCTAssertFalse(meshes.isEmpty)
        for mesh in meshes {
            XCTAssertEqual(mesh.positions.count, mesh.normals.count)
            XCTAssertEqual(mesh.indices.count % 3, 0)
            XCTAssertLessThan(Int(mesh.indices.max() ?? 0), mesh.positions.count)
            if let uvs = mesh.uvs { XCTAssertEqual(uvs.count, mesh.positions.count) }
            XCTAssertLessThan(mesh.layer, model.layers.count)
            if let material = mesh.material { XCTAssertLessThan(material, model.materials.count) }
        }
        for child in ([model.root] + model.definitions).flatMap(\.children) {
            XCTAssertLessThan(child.definition, model.definitions.count)
        }
        let size = model.size
        XCTAssertLessThan(size.max(), 10, "positions must be in metres")
        XCTAssertGreaterThan(size.x + size.y + size.z, 0)
        XCTAssertTrue(size.x > 0 && size.y > 0 || size.y > 0 && size.z > 0 || size.x > 0 && size.z > 0)
        XCTAssertGreaterThan(model.stats.loadSeconds, 0)
        XCTAssertNotNil(model.camera)
        XCTAssertTrue(model.scenes.isEmpty)
        if let dir = model.textureDirectory { try? FileManager.default.removeItem(at: dir) }
    }

    func testCancellation() throws {
        guard SketchUpAPI.locate() != nil else { throw XCTSkip("SketchUp not installed") }
        XCTAssertThrowsError(try SKPReader.load(Self.fixture, isCancelled: { true })) { error in
            guard case SKPError.cancelled = error else { return XCTFail("\(error)") }
        }
    }

    /// Cancelled during the face conversion (after materials and textures were read): throws and leaves no texture folder.
    func testCancellationDuringConversionCleansTextures() throws {
        guard SketchUpAPI.locate() != nil else { throw XCTSkip("SketchUp not installed") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SimpleSKP")
        // The fixture has no texture; the Arles file (35 textures) exercises the cleanup when present.
        let arles = URL(fileURLWithPath: "/Users/adrien/Dropbox/AMCB-MM-Diff/TOUR 2018/0930-Arles/3D/MM_Arles_3D_V003.skp")
        for url in [Self.fixture, arles] where FileManager.default.fileExists(atPath: url.path) {
            let start = Date()
            let calls = CallCounter()
            let created = Box<URL?>(nil)
            XCTAssertThrowsError(try SKPReader.load(url, isCancelled: {
                guard calls.next() > 1 else { return false }
                // Textures written, loads serialised by the reader's lock: this load's folder is the newest one. Folders
                // left by other tests' background loads, or other processes, do not count.
                let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.creationDateKey])) ?? []
                created.value = folders.max { ($0.creationDate ?? .distantPast) < ($1.creationDate ?? .distantPast) }
                    .flatMap { ($0.creationDate ?? .distantPast) >= start ? $0 : nil }
                return true
            })) { error in
                guard case SKPError.cancelled = error else { return XCTFail("\(error)") }
            }
            XCTAssertEqual(calls.count, 2, "first check after open passes, the face-0 check cancels")
            if let folder = created.value {
                XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path), url.lastPathComponent)
            } else {
                XCTAssertNotEqual(url, arles, "Arles writes textures before the faces")
            }
        }
    }

    /// Faces without their own material carry UVs in metres (for a texture inherited from a group or instance).
    func testNilMaterialMeshesHaveUVs() throws {
        guard SketchUpAPI.locate() != nil else { throw XCTSkip("SketchUp not installed") }
        var model = try SKPReader.load(Self.fixture)
        var meshes = ([model.root] + model.definitions).flatMap(\.meshes).filter { $0.material == nil }
        if meshes.isEmpty {
            let arles = URL(fileURLWithPath: "/Users/adrien/Dropbox/AMCB-MM-Diff/TOUR 2018/0930-Arles/3D/MM_Arles_3D_V003.skp")
            guard FileManager.default.fileExists(atPath: arles.path) else { throw XCTSkip("no nil-material mesh available") }
            if let dir = model.textureDirectory { try? FileManager.default.removeItem(at: dir) }
            model = try SKPReader.load(arles)
            meshes = ([model.root] + model.definitions).flatMap(\.meshes).filter { $0.material == nil }
        }
        defer { if let dir = model.textureDirectory { try? FileManager.default.removeItem(at: dir) } }
        XCTAssertFalse(meshes.isEmpty)
        for mesh in meshes { XCTAssertEqual(mesh.uvs?.count, mesh.positions.count) }
    }

    func testAutomaticLayerGroupingHierarchy() {
        let layers: [SKPModel.Layer] = [
            .init(name: "Layer0", isVisible: true),
            .init(name: "0_Murs", isVisible: true),
            .init(name: "0_Sol", isVisible: true),
            .init(name: "0_Plafond", isVisible: false),
            .init(name: "FRISS_VP_Sol", isVisible: true),
            .init(name: "FRISS_VP_Fond", isVisible: true),
            .init(name: "FRISS_Régie", isVisible: false),
            .init(name: "Mur-Jardin", isVisible: true),
            .init(name: "Mur-Cour", isVisible: true),
            .init(name: "Mur-Lointain", isVisible: true),
            .init(name: "Spotlight1", isVisible: true),
            .init(name: "Spotlight2", isVisible: false),
            .init(name: "Fond de plan-pdf", isVisible: false),
            .init(name: "Fond de plan-skp", isVisible: false),
            .init(name: "Existant", isVisible: true),
        ]
        let groups = SKPModel.buildLayerGroups(for: layers)
        // Layer0 stays standalone at index 0
        XCTAssertEqual(groups.first?.name, "Layer0")
        XCTAssertTrue(groups.first?.isSingleLayer == true)

        let groupByName = Dictionary(uniqueKeysWithValues: groups.map { ($0.name, $0) })
        XCTAssertEqual(groupByName["0"]?.layerIndices, [1, 2, 3])
        XCTAssertEqual(groupByName["0"]?.memberLabels[1], "Murs")
        XCTAssertEqual(groupByName["FRISS"]?.layerIndices, [4, 5, 6])
        XCTAssertEqual(groupByName["FRISS"]?.memberLabels[4], "VP_Sol")
        XCTAssertEqual(groupByName["Mur"]?.layerIndices, [7, 8, 9])
        XCTAssertEqual(groupByName["Mur"]?.memberLabels[7], "Jardin")
        XCTAssertEqual(groupByName["Spotlight"]?.layerIndices, [10, 11])
        XCTAssertEqual(groupByName["Fond de plan"]?.layerIndices, [12, 13])
        XCTAssertEqual(groupByName["Fond de plan"]?.memberLabels[12], "pdf")
        XCTAssertEqual(groupByName["Existant"]?.isSingleLayer, true)
    }

    func testFixtureBackFaceAndTransparentMaterialsAreRead() throws {
        guard SketchUpAPI.locate() != nil else { throw XCTSkip("SketchUp not installed") }
        let model = try SKPReader.load(Self.fixture)
        defer { if let dir = model.textureDirectory { try? FileManager.default.removeItem(at: dir) } }
        // In VerreMirroir.skp, all 3 painted faces are painted ONLY on SUFaceGetBackMaterial (SUFaceGetFrontMaterial == nil).
        let allMeshes = ([model.root] + model.definitions).flatMap(\.meshes)
        XCTAssertTrue(allMeshes.contains { $0.material != nil }, "back-painted faces in VerreMirroir.skp must retain their back material")

        let orsay = URL(fileURLWithPath: "/Users/adrien/Dropbox/AMCB-Expos/20180200-Orsay/3D/Orsay_3D_V3.skp")
        if FileManager.default.fileExists(atPath: orsay.path) {
            let orsayModel = try SKPReader.load(orsay)
            defer { if let dir = orsayModel.textureDirectory { try? FileManager.default.removeItem(at: dir) } }
            XCTAssertTrue(orsayModel.materials.contains { $0.isTransparent && $0.opacity < 0.99 })
            let multiGroups = orsayModel.layerGroups.filter { !$0.isSingleLayer }
            XCTAssertGreaterThanOrEqual(multiGroups.count, 4)
        }
    }

    // MARK: AutoCAD (.dwg / .dxf)

    func testDWGAndDXFHeaderParsing() {
        let dwgHeader = Data("AC1032\0\0\0\0\0\0".utf8)
        let dwgInfo = SKPFileInfo.parse(header: dwgHeader, url: URL(fileURLWithPath: "/tmp/plan.dwg"), fileSize: 1024)
        XCTAssertTrue(dwgInfo.isDWG)
        XCTAssertFalse(dwgInfo.isDXF)
        XCTAssertTrue(dwgInfo.isCAD)
        XCTAssertEqual(dwgInfo.version, "AC1032")
        XCTAssertEqual(dwgInfo.versionLabel, "AutoCAD 2018")

        let dxfText = "  0\nSECTION\n  2\nHEADER\n  9\n$ACADVER\n  1\nAC1027\n  0\nENDSEC\n"
        let dxfInfo = SKPFileInfo.parse(header: Data(dxfText.utf8), url: URL(fileURLWithPath: "/tmp/coupe.dxf"), fileSize: 2048)
        XCTAssertFalse(dxfInfo.isDWG)
        XCTAssertTrue(dxfInfo.isDXF)
        XCTAssertTrue(dxfInfo.isCAD)
        XCTAssertEqual(dxfInfo.version, "AC1027")
        XCTAssertEqual(dxfInfo.versionLabel, "AutoCAD DXF 2013")
    }

    func testNativeDXFParserLoads2DAnd3DEntities() throws {
        let dxfContent = """
          0
        SECTION
          2
        HEADER
          9
        $ACADVER
          1
        AC1032
          9
        $INSUNITS
         70
        4
          0
        ENDSEC
          0
        SECTION
          2
        TABLES
          0
        TABLE
          2
        LAYER
          0
        LAYER
          2
        Murs
         62
        1
         70
        0
          0
        LAYER
          2
        Cotes_Cachees
         62
        -3
         70
        0
          0
        ENDTAB
          0
        ENDSEC
          0
        SECTION
          2
        BLOCKS
          0
        BLOCK
          2
        Colonne
         10
        0.0
         20
        0.0
         30
        0.0
          0
        CIRCLE
          8
        Murs
         10
        0.0
         20
        0.0
         30
        0.0
         40
        500.0
          0
        ENDBLK
          0
        ENDSEC
          0
        SECTION
          2
        ENTITIES
          0
        LINE
          8
        Murs
         10
        0.0
         20
        0.0
         30
        0.0
         11
        10000.0
         21
        0.0
         31
        0.0
          0
        LWPOLYLINE
          8
        Murs
         70
        1
         10
        0.0
         20
        0.0
         10
        10000.0
         20
        0.0
         10
        10000.0
         20
        8000.0
         10
        0.0
         20
        8000.0
          0
        3DFACE
          8
        Murs
         10
        0.0
         20
        0.0
         30
        0.0
         11
        2000.0
         21
        0.0
         31
        0.0
         12
        2000.0
         22
        2000.0
         32
        0.0
         13
        0.0
         23
        2000.0
         33
        0.0
          0
        INSERT
          2
        Colonne
          8
        Murs
         10
        5000.0
         20
        4000.0
         30
        0.0
          0
        ENDSEC
          0
        EOF
        """
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("simpleskp-test-\(UUID().uuidString).dxf")
        try dxfContent.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let fileInfo = try SKPFileInfo.read(url)
        let model = try DXFNativeParser.parse(url: url, fileInfo: fileInfo, progress: nil, isCancelled: { false })
        XCTAssertTrue(model.fileInfo.isDXF)
        XCTAssertTrue(model.isPlanar2D)
        XCTAssertGreaterThan(model.stats.edges, 10)
        XCTAssertEqual(model.stats.faces, 2)
        XCTAssertEqual(model.stats.instances, 1)
        // 10000 mm × 8000 mm converted to 10 m × 8 m
        XCTAssertEqual(model.size.x, 10.0, accuracy: 0.05)
        XCTAssertEqual(model.size.y, 8.0, accuracy: 0.05)
        let hiddenLayer = model.layers.first { $0.name == "Cotes_Cachees" }
        XCTAssertEqual(hiddenLayer?.isVisible, false)
        // ACI 3 (green) on negative layer color -3 -> green component is 1.0
        XCTAssertEqual(hiddenLayer?.color?.y ?? 0, 1.0, accuracy: 0.01)
        // ACI 1 (red) on Murs layer -> red component is 1.0
        let mursLayer = model.layers.first { $0.name == "Murs" }
        XCTAssertEqual(mursLayer?.color?.x ?? 0, 1.0, accuracy: 0.01)
        XCTAssertEqual(mursLayer?.color?.y ?? 1, 0.0, accuracy: 0.01)
    }

    func testOBJAndMTLLoadWithLayersMaterialsAndEdges() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("simpleskp-obj-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let mtlURL = tempDir.appendingPathComponent("scene.mtl")
        let mtlText = """
        newmtl Brique
        Kd 0.85 0.25 0.18
        d 1.0
        newmtl Verre
        Kd 0.30 0.70 0.90
        d 0.45
        """
        try mtlText.write(to: mtlURL, atomically: true, encoding: .utf8)

        let objURL = tempDir.appendingPathComponent("scene.obj")
        let objText = """
        # Wavefront OBJ test
        mtllib scene.mtl
        o Mur_Principal
        usemtl Brique
        v 0.0 0.0 0.0
        v 4.0 0.0 0.0
        v 4.0 3.0 0.0
        v 0.0 3.0 0.0
        f 1 2 3 4
        o Fenetre
        usemtl Verre
        v 1.0 1.0 -2.0
        v 3.0 1.0 -2.0
        v 3.0 2.5 -2.0
        f 5 6 7
        l 1 5
        """
        try objText.write(to: objURL, atomically: true, encoding: .utf8)

        let model = try SKPReader.load(objURL)
        XCTAssertTrue(model.fileInfo.isOBJ)
        XCTAssertEqual(model.fileInfo.versionLabel, "Wavefront OBJ")
        XCTAssertEqual(model.stats.faces, 2)
        XCTAssertEqual(model.stats.triangles, 3)
        XCTAssertGreaterThan(model.stats.edges, 4)
        XCTAssertTrue(model.layers.contains { $0.name == "Mur_Principal" })
        XCTAssertTrue(model.layers.contains { $0.name == "Fenetre" })
        XCTAssertEqual(model.materials.count, 2)
        let verre = try XCTUnwrap(model.materials.first { $0.name == "Verre" })
        XCTAssertTrue(verre.isTransparent)
        XCTAssertEqual(verre.opacity, 0.45, accuracy: 0.01)
        // Y-up (0..3 in Y) becomes Z-up (0..3 in Z)
        XCTAssertEqual(model.size.x, 4.0, accuracy: 0.01)
        XCTAssertEqual(model.size.z, 3.0, accuracy: 0.01)
    }

    func testColladaDAELoadsGeometryAndUnits() throws {
        let daeURL = FileManager.default.temporaryDirectory.appendingPathComponent("simpleskp-test-\(UUID().uuidString).dae")
        defer { try? FileManager.default.removeItem(at: daeURL) }

        let daeXML = """
        <?xml version="1.0" encoding="utf-8"?>
        <COLLADA xmlns="http://www.collada.org/2005/11/COLLADASchema" version="1.4.1">
          <asset>
            <unit name="meter" meter="1.0"/>
            <up_axis>Z_UP</up_axis>
          </asset>
          <library_geometries>
            <geometry id=" PlateauGeom" name="Plateau">
              <mesh>
                <source id="pos">
                  <float_array id="pos-array" count="12">0 0 0 6 0 0 6 4 0 0 4 2</float_array>
                  <technique_common>
                    <accessor source="#pos-array" count="4" stride="3">
                      <param name="X" type="float"/>
                      <param name="Y" type="float"/>
                      <param name="Z" type="float"/>
                    </accessor>
                  </technique_common>
                </source>
                <vertices id="verts">
                  <input semantic="POSITION" source="#pos"/>
                </vertices>
                <triangles count="2">
                  <input semantic="VERTEX" source="#verts" offset="0"/>
                  <p>0 1 2 0 2 3</p>
                </triangles>
              </mesh>
            </geometry>
          </library_geometries>
          <library_visual_scenes>
            <visual_scene id="Scene" name="Scene">
              <node id="PlateauNode" name="Plateau_Scene" type="NODE">
                <instance_geometry url="#PlateauGeom"/>
              </node>
            </visual_scene>
          </library_visual_scenes>
          <scene>
            <instance_visual_scene url="#Scene"/>
          </scene>
        </COLLADA>
        """
        try daeXML.write(to: daeURL, atomically: true, encoding: .utf8)

        let model = try SKPReader.load(daeURL)
        defer { if let dir = model.textureDirectory { try? FileManager.default.removeItem(at: dir) } }
        XCTAssertTrue(model.fileInfo.isDAE)
        XCTAssertEqual(model.fileInfo.versionLabel, "Collada DAE 1.4.1")
        XCTAssertEqual(model.stats.triangles, 2)
        XCTAssertGreaterThan(model.stats.edges, 0)
        XCTAssertTrue(model.layers.contains { $0.name == "Plateau_Scene" })
        XCTAssertGreaterThan(model.size.x, 1.0)
    }

    func testRealAutoCADDWGFilesLoadAndCalibrate() throws {
        guard CADReader.locatePlugin() != nil else { throw XCTSkip("DWGImporter.plugin not available") }
        let userFiles = [
            "/Users/adrien/Dropbox/AM-VW - Seine musicale/Plans/AUDITORIUM - KIT SON LIGHT 2026-V1.dwg",
            "/Users/adrien/Dropbox/AM-VW - Seine musicale/Docs techniques/SOUCHE Plan de coupe longitudinale sans fosse.dwg",
            "/Users/adrien/Downloads/Conception/Musee-Orsay_Plan 06-N2_masse-coupe_SDF.dwg",
            "/Users/adrien/Downloads/Conception/2023 ODEON POUR PROD+TOURS LATERALES.dwg",
            "/Users/adrien/Dropbox/MaisonCrest/ARCHI/4_3D/3D ATELIER/AMCB-Fabrique - Crest 3D.dwg",
            "/Users/adrien/Dropbox/AMCB-HKN-Diff/TOUR 2019/0114-Poitiers/FICHES TECHNIQUES SALLE/plan DWG/Beaulieu 2016.dwg",
            "/Users/adrien/Dropbox/MaisonCrest/ARCHI/4_3D/3D ATELIER/AMCB-Fabrique - Crest 3D-dwg/MAISON.dwg",
            "/Users/adrien/Dropbox/AMCB-AIR-Diff/TOUR 2019/0224-GrandeSynthe/Docs lieu/4926-CH01-A- Plan de Charges.dwg",
            "/Users/adrien/Dropbox/AMCB-AIR-Diff/TOUR 2019/0224-GrandeSynthe/Docs lieu/4926-0040-C-EQUIPEMENTS de scène.dwg",
            "/Users/adrien/Dropbox/AMCB-MM-Diff/TOUR 2018/1106-Maubeuge/2D/AMCB-MM-MAUBEUGE-CB.dwg",
            "/Users/adrien/Dropbox/AMCB-MM-Diff/TOUR 2018/1104-OloronSteMarie/2D/MM_oloron_V1.dwg",
            "/Users/adrien/Dropbox/AMCB-AIR-Diff/Études 2019/0300 Bogota/Docs lieu/Teatro Mayor-PLANTA y CORTE.dwg",
            "/Users/adrien/Dropbox/AMCB-FEM/TECH/Informatique/Synoptique Installation.dwg",
            "/Users/adrien/Dropbox/AMCB-HKN-Diff/TOUR 2018/1017-Tremblay/plan theatre L Aragon 2012.dwg",
            "/Users/adrien/Dropbox/AMCB-AIR-Diff/Études 2019/0300 Bogota/Docs lieu/Corte Teatro Estudio 249pax.dwg",
        ].map(URL.init(fileURLWithPath:)).filter { FileManager.default.fileExists(atPath: $0.path) }

        try XCTSkipUnless(!userFiles.isEmpty, "no sample DWG files on disk")
        for url in userFiles {
            let model = try SKPReader.load(url)
            defer { if let dir = model.textureDirectory { try? FileManager.default.removeItem(at: dir) } }
            XCTAssertTrue(model.fileInfo.isDWG, url.lastPathComponent)
            XCTAssertGreaterThan(model.stats.edges + model.stats.faces, 0, url.lastPathComponent)
            let maxSpan = max(model.size.x, max(model.size.y, model.size.z))
            XCTAssertGreaterThan(maxSpan, 1.0, "calibrated metric span too small for \(url.lastPathComponent): \(model.size)")
            XCTAssertLessThan(maxSpan, 2500.0, "calibrated metric span too large for \(url.lastPathComponent): \(model.size)")
            let xyOffset = simd_length(SIMD2<Float>(model.center.x, model.center.y))
            XCTAssertLessThan(xyOffset, maxSpan * 3.0, "geodetic offset not recentered for \(url.lastPathComponent): center=\(model.center)")
        }
    }

    // MARK: - Optoma ZU920ST Video Projector & .sskp Project

    func testOptomaZU920STOpticalFrustumAndLensShift() {
        let spec = ProjectorSpec.optomaZU920ST
        XCTAssertEqual(spec.nativeWidth, 1920)
        XCTAssertEqual(spec.nativeHeight, 1200)
        XCTAssertEqual(spec.aspectRatio, 1.6, accuracy: 1e-4)
        XCTAssertEqual(spec.minThrowRatio, 0.65, accuracy: 1e-4)
        XCTAssertEqual(spec.maxThrowRatio, 0.75, accuracy: 1e-4)
        XCTAssertEqual(spec.maxLensShiftH, 0.25, accuracy: 1e-4)
        XCTAssertEqual(spec.maxLensShiftV, 0.55, accuracy: 1e-4)

        // Centered projector at (0, 0, 2) aiming +Y to a screen at (0, 7, 2) -> throw distance D = 7.0 m
        var vp = VideoProjector(
            name: "VP Face",
            specID: spec.id,
            position: SIMD3<Float>(0, 0, 2),
            target: SIMD3<Float>(0, 7, 2),
            throwRatio: 0.70,
            lensShiftH: 0.0,
            lensShiftV: 0.0
        )
        XCTAssertEqual(vp.throwDistance, 7.0, accuracy: 1e-4)
        // W = D / TR = 7.0 / 0.70 = 10.0 m; H = 10.0 / 1.6 = 6.25 m
        XCTAssertEqual(vp.projectedWidth(), 10.0, accuracy: 1e-3)
        XCTAssertEqual(vp.projectedHeight(), 6.25, accuracy: 1e-3)

        // Optical axis center (0, 7, 2) must project to UV (0.5, 0.5) at depth 7.0 m
        let centerProj = vp.projectPoint(SIMD3<Float>(0, 7, 2))
        XCTAssertTrue(centerProj.isInsideFrustum)
        XCTAssertEqual(centerProj.uv.x, 0.5, accuracy: 1e-3)
        XCTAssertEqual(centerProj.uv.y, 0.5, accuracy: 1e-3)
        XCTAssertEqual(centerProj.eyeDepth, 7.0, accuracy: 1e-3)

        // Apply +25% horizontal lens shift (+2.5 m along +X) and -50% vertical shift (-3.125 m along +Z)
        vp.lensShiftH = 0.25
        vp.lensShiftV = -0.50
        let shiftedCenter = SIMD3<Float>(2.5, 7.0, 2.0 - 3.125)
        let shiftedProj = vp.projectPoint(shiftedCenter)
        XCTAssertTrue(shiftedProj.isInsideFrustum)
        XCTAssertEqual(shiftedProj.uv.x, 0.5, accuracy: 1e-3)
        XCTAssertEqual(shiftedProj.uv.y, 0.5, accuracy: 1e-3)
        XCTAssertEqual(shiftedProj.eyeDepth, 7.0, accuracy: 1e-3)

        // Point behind projector must not be inside frustum
        let behindProj = vp.projectPoint(SIMD3<Float>(0, -2, 2))
        XCTAssertFalse(behindProj.isInsideFrustum)

        // Verify Optoma ZH450ST (0.496:1, 1080p 16:9), ZH406ST (0.50:1, 1080p 16:9), and ZU606TSTE (0.79:1, WUXGA 16:10)
        var vpSwitch = vp
        vpSwitch.name = "VP 1 — ZU920ST"
        vpSwitch.applySpec(.optomaZH450ST)
        XCTAssertEqual(vpSwitch.name, "VP 1 — ZH450ST")
        XCTAssertEqual(vpSwitch.throwRatio, 0.496, accuracy: 1e-4)
        XCTAssertEqual(vpSwitch.spec.aspectRatio, 16.0 / 9.0, accuracy: 1e-4)

        vpSwitch.applySpec(.optomaZH406ST)
        XCTAssertEqual(vpSwitch.name, "VP 1 — ZH406ST")
        XCTAssertEqual(vpSwitch.throwRatio, 0.50, accuracy: 1e-4)
        XCTAssertEqual(vpSwitch.spec.aspectRatio, 16.0 / 9.0, accuracy: 1e-4)

        vpSwitch.applySpec(.optomaZU606TSTE)
        XCTAssertEqual(vpSwitch.name, "VP 1 — ZU606TSTE")
        XCTAssertEqual(vpSwitch.throwRatio, 0.79, accuracy: 1e-4)
        XCTAssertEqual(vpSwitch.spec.aspectRatio, 1.6, accuracy: 1e-4)
    }

    func testSSKPProjectRoundTripAndReaderResolution() throws {
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("sskp-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let objURL = tmpDir.appendingPathComponent("plateau.obj")
        let objText = """
        v -5 0 0
        v  5 0 0
        v  5 8 0
        v -5 8 0
        f 1 2 3 4
        """
        try objText.write(to: objURL, atomically: true, encoding: .utf8)

        let sskpURL = tmpDir.appendingPathComponent("implantation.sskp")
        let relPath = SSKPProject.relativePath(from: tmpDir, to: objURL)
        XCTAssertEqual(relPath, "plateau.obj")

        let vp = VideoProjector(
            name: "VP1 Optoma ZU920ST",
            specID: ProjectorSpec.optomaZU920ST.id,
            position: SIMD3<Float>(0, -6, 5),
            target: SIMD3<Float>(0, 4, 1.5),
            throwRatio: 0.68,
            lensShiftH: 0.10,
            lensShiftV: -0.35,
            pattern: .testGrid
        )
        let project = SSKPProject(
            modelPath: objURL.path,
            modelRelativePath: relPath,
            projectors: [vp],
            camera: SSKPProject.CameraState(
                position: SIMD3<Float>(0, -12, 6),
                target: SIMD3<Float>(0, 2, 1),
                fovDegrees: 42,
                isPerspective: true,
                orthoScale: 10,
                exposureOffset: 0
            ),
            lighting: SSKPProject.LightingState(
                lightingMode: "sun",
                sunAzimuthDegrees: 135,
                sunElevationDegrees: 45,
                sunIntensity: 1.0,
                ambientIntensity: 0.5,
                shadowsEnabled: true,
                shadingStyle: "shaded",
                backdropStyle: "studioDark",
                customBackdropColor: SIMD3<Float>(0.1, 0.1, 0.12),
                showsEdges: true,
                showsGrid: true,
                pointLights: []
            ),
            hiddenLayerNames: ["Cote"]
        )

        try project.write(to: sskpURL)

        let decoded = try SSKPProject.read(from: sskpURL)
        XCTAssertEqual(decoded.projectors.count, 1)
        XCTAssertEqual(decoded.projectors.first?.name, "VP1 Optoma ZU920ST")
        XCTAssertEqual(decoded.projectors.first?.specID, ProjectorSpec.optomaZU920ST.id)
        XCTAssertEqual(Double(decoded.projectors.first?.throwRatio ?? 0), 0.68, accuracy: 1e-4)
        XCTAssertEqual(Double(decoded.projectors.first?.lensShiftH ?? 0), 0.10, accuracy: 1e-4)
        XCTAssertEqual(Double(decoded.projectors.first?.lensShiftV ?? 0), -0.35, accuracy: 1e-4)
        XCTAssertEqual(decoded.resolveModelURL(relativeTo: sskpURL).standardizedFileURL, objURL.standardizedFileURL)

        // SKPFileInfo identifies .sskp files, and SKPReader.load transparently loads the referenced 3D model
        let sskpInfo = try SKPFileInfo.read(sskpURL)
        XCTAssertTrue(sskpInfo.isSSKP)
        let loadedModel = try SKPReader.load(sskpURL)
        XCTAssertEqual(loadedModel.fileInfo.url.standardizedFileURL, objURL.standardizedFileURL)
        XCTAssertEqual(loadedModel.stats.faces, 1)
    }

    func testVideoProjectorIncidenceFluxFactor() {
        // 0° incidence (surface normal to beam -> cosTheta = 1.0) -> 100% flux
        let f0 = VideoProjector.incidenceFluxFactor(cosTheta: cos(0.0 * .pi / 180.0))
        XCTAssertEqual(Double(f0), 1.0, accuracy: 1e-5)

        // 45° incidence -> ~62.6%
        let f45 = VideoProjector.incidenceFluxFactor(cosTheta: cos(45.0 * .pi / 180.0))
        XCTAssertLessThan(f45, f0)
        XCTAssertGreaterThan(f45, 0.50)

        // 60° incidence -> ~39.2%
        let f60 = VideoProjector.incidenceFluxFactor(cosTheta: cos(60.0 * .pi / 180.0))
        XCTAssertLessThan(f60, f45)

        // 80° grazing incidence -> < 12%
        let f80 = VideoProjector.incidenceFluxFactor(cosTheta: cos(80.0 * .pi / 180.0))
        XCTAssertLessThan(f80, 0.12)
        XCTAssertGreaterThan(f80, 0.01)

        // 87° extreme grazing -> < 1%
        let f87 = VideoProjector.incidenceFluxFactor(cosTheta: cos(87.0 * .pi / 180.0))
        XCTAssertLessThan(f87, 0.01)

        // 90° tangent to beam -> 0%
        let f90 = VideoProjector.incidenceFluxFactor(cosTheta: cos(90.0 * .pi / 180.0))
        XCTAssertEqual(Double(f90), 0.0, accuracy: 1e-6)
    }

    func testPanasonicPTRQ32KLensSpecs() {
        let le30 = ProjectorSpec.panasonicPTRQ32K_ETD75LE30
        XCTAssertEqual(le30.manufacturer, "Panasonic")
        XCTAssertEqual(le30.lumens, 32000)
        XCTAssertEqual(Double(le30.minThrowRatio), 2.40, accuracy: 1e-4)
        XCTAssertEqual(Double(le30.maxThrowRatio), 4.70, accuracy: 1e-4)
        XCTAssertEqual(Double(le30.aspectRatio), 1.6, accuracy: 1e-4)
        XCTAssertEqual(ProjectorCatalog.spec(for: "ET-D75LE30"), le30)

        let lew50 = ProjectorSpec.panasonicPTRQ32K_ETD3LEW50
        XCTAssertEqual(lew50.manufacturer, "Panasonic")
        XCTAssertEqual(lew50.lumens, 32000)
        XCTAssertEqual(Double(lew50.minThrowRatio), 0.70, accuracy: 1e-4)
        XCTAssertEqual(Double(lew50.maxThrowRatio), 0.70, accuracy: 1e-4)
        XCTAssertEqual(ProjectorCatalog.spec(for: "ET-D3LEW50"), lew50)
    }

    func testStageLightingSpecs() {
        let hero = ProjectorSpec.varytecHeroWash300FC
        XCTAssertEqual(hero.manufacturer, "Varytec")
        XCTAssertEqual(hero.model, "Hero Wash 300 FC")
        XCTAssertEqual(hero.lumens, 6000)
        XCTAssertEqual(hero.kind, .washPanel)
        XCTAssertEqual(Double(hero.minThrowRatio), 1.07, accuracy: 1e-2)
        XCTAssertEqual(Double(hero.maxThrowRatio), 9.54, accuracy: 1e-2)
        XCTAssertTrue(hero.resolutionLabel.contains("Wash Zoom"))
        XCTAssertEqual(ProjectorCatalog.spec(for: "Varytec Hero Wash 300 FC"), hero)
        XCTAssertEqual(ProjectorCatalog.spec(for: "hero wash 300"), hero)

        let profile = ProjectorSpec.showtecPerformerProfileMini
        XCTAssertEqual(profile.kind, .profileSpot)
        XCTAssertEqual(profile.lumens, 1500)
        XCTAssertEqual(profile.colorTemperatureKelvin, 3200)

        let eurolite = ProjectorSpec.euroliteLEDPLL480QCL
        XCTAssertEqual(eurolite.kind, .washPanel)
        XCTAssertEqual(eurolite.lumens, 4500)
    }

    func testVideoProjectorPhotometricsAndLuxSimulation() {
        let zu920 = VideoProjector(
            name: "ZU920ST Test",
            specID: ProjectorSpec.optomaZU920ST.id,
            position: SIMD3<Float>(0, 0, 3.0),
            target: SIMD3<Float>(0, 6.8, 3.0),
            throwRatio: 0.68
        )
        // Throw distance is 6.8 m
        XCTAssertEqual(Double(zu920.throwDistance), 6.8, accuracy: 1e-3)
        // Image width at 6.8 m: 6.8 / 0.68 = 10.0 m
        XCTAssertEqual(Double(zu920.projectedWidth()), 10.0, accuracy: 1e-3)
        // Image height for 16:10: 10.0 / 1.6 = 6.25 m
        XCTAssertEqual(Double(zu920.projectedHeight()), 6.25, accuracy: 1e-3)
        // Image area: 62.5 m²
        XCTAssertEqual(Double(zu920.projectedArea()), 62.5, accuracy: 1e-2)

        // Lens transmission around 85-90%
        XCTAssertGreaterThan(zu920.lensTransmission, 0.80)
        XCTAssertLessThanOrEqual(zu920.lensTransmission, 0.95)

        // Effective lumens
        XCTAssertGreaterThan(zu920.effectiveLumens, 7500)
        XCTAssertLessThanOrEqual(zu920.effectiveLumens, 9800)

        // Illuminance at 6.8 m: ~135 lx
        let lux68 = zu920.illuminanceLux()
        XCTAssertGreaterThan(lux68, 110)
        XCTAssertLessThan(lux68, 160)
        XCTAssertEqual(zu920.photometricRating(), .theaterAmbiance)

        // Closer at 3.4 m: 4x illuminance (~540 lx)
        let lux34 = zu920.illuminanceLux(atDistance: 3.4)
        XCTAssertEqual(Double(lux34), Double(lux68 * 4.0), accuracy: 1.0)
        XCTAssertEqual(zu920.photometricRating(atDistance: 3.4), .optimalMapping)

        // Far at 17.0 m: dim (~21 lx)
        let lux17 = zu920.illuminanceLux(atDistance: 17.0)
        XCTAssertLessThan(lux17, 30)
        XCTAssertEqual(zu920.photometricRating(atDistance: 17.0), .lowContrast)

        // Luminance in Nits (gain 1.0): lux / pi
        let nits = zu920.surfaceLuminanceNits()
        XCTAssertEqual(Double(nits), Double(lux68 / .pi), accuracy: 0.1)
    }

    // MARK: - FBX, 3D Gaussian Splats & Point Clouds

    func testFBXReaderASCII() throws {
        let fbxText = """
        ; FBX 7.4.0 project file
        FBXHeaderExtension:  {
            FBXHeaderVersion: 1003
            FBXVersion: 7400
        }
        GlobalSettings:  {
            Version: 1000
            Properties70:  {
                P: "UnitScaleFactor", "double", "Number", "",100
                P: "OriginalUnitScaleFactor", "double", "Number", "",100
                P: "UpAxis", "int", "Integer", "",2
                P: "UpAxisSign", "int", "Integer", "",1
                P: "FrontAxis", "int", "Integer", "",1
                P: "FrontAxisSign", "int", "Integer", "",-1
                P: "CoordAxis", "int", "Integer", "",0
                P: "CoordAxisSign", "int", "Integer", "",1
            }
        }
        Objects:  {
            Geometry: 1001, "Geometry::CubeMesh", "Mesh" {
                Vertices: *12 {
                    a: 0,0,0, 2,0,0, 2,3,0, 0,3,0
                }
                PolygonVertexIndex: *4 {
                    a: 0, 1, 2, -4
                }
                GeometryVersion: 124
            }
            Model: 2001, "Model::StageFloor", "Mesh" {
                Version: 232
                Properties70:  {
                    P: "Lcl Translation", "Lcl Translation", "", "A",0,0,1.5
                }
            }
            Material: 3001, "Material::StageWood", "" {
                Version: 102
                ShadingModel: "phong"
                Properties70:  {
                    P: "DiffuseColor", "Color", "", "A",0.8,0.4,0.2
                }
            }
        }
        Connections:  {
            C: "OO",2001,0
            C: "OO",1001,2001
            C: "OO",3001,2001
        }
        """
        let fbxURL = FileManager.default.temporaryDirectory.appendingPathComponent("test-stage-\(UUID().uuidString).fbx")
        try fbxText.write(to: fbxURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: fbxURL) }

        let info = try SKPFileInfo.read(fbxURL)
        XCTAssertTrue(info.isFBX)
        XCTAssertEqual(info.version, "FBX 7.4.0")

        let model = try SKPReader.load(fbxURL)
        XCTAssertEqual(model.fileInfo.version, "FBX 7.4")
        XCTAssertEqual(model.stats.faces, 1)
        XCTAssertEqual(model.stats.triangles, 2)
        XCTAssertEqual(model.materials.count, 1)
        XCTAssertEqual(model.materials.first?.name, "StageWood")
        XCTAssertEqual(Double(model.size.x), 2.0, accuracy: 1e-3)
        XCTAssertEqual(Double(model.size.y), 3.0, accuracy: 1e-3)
        XCTAssertEqual(Double(model.boundsMin.z), 1.5, accuracy: 1e-3)
    }

    func testGaussianSplatPLYAndSplatFormats() throws {
        // 1. ASCII 3DGS PLY with SH1 (9 rest floats)
        let plyText = """
        ply
        format ascii 1.0
        element vertex 2
        property float x
        property float y
        property float z
        property float f_dc_0
        property float f_dc_1
        property float f_dc_2
        property float f_rest_0
        property float f_rest_1
        property float f_rest_2
        property float f_rest_3
        property float f_rest_4
        property float f_rest_5
        property float f_rest_6
        property float f_rest_7
        property float f_rest_8
        property float opacity
        property float scale_0
        property float scale_1
        property float scale_2
        property float rot_0
        property float rot_1
        property float rot_2
        property float rot_3
        end_header
        1.0 -2.0 3.0 1.5 -0.5 0.0 0.1 0.2 0.3 0.1 0.2 0.3 0.1 0.2 0.3 2.0 -2.3 -2.3 -2.3 1.0 0.0 0.0 0.0
        -1.0 1.0 2.0 -0.5 1.5 0.5 0.0 0.0 0.0 0.0 0.0 0.0 0.0 0.0 0.0 3.0 -1.6 -1.6 -1.6 1.0 0.0 0.0 0.0
        """
        let plyURL = FileManager.default.temporaryDirectory.appendingPathComponent("test-3dgs-\(UUID().uuidString).ply")
        try plyText.write(to: plyURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: plyURL) }

        let plyInfo = try SKPFileInfo.read(plyURL)
        XCTAssertTrue(plyInfo.isPLY)
        XCTAssertTrue(plyInfo.isGaussianSplat)
        XCTAssertFalse(plyInfo.isPointCloud)

        let gsModel = try SKPReader.load(plyURL)
        XCTAssertEqual(gsModel.stats.splats, 2)
        let cloud = try XCTUnwrap(gsModel.splatCloud)
        XCTAssertEqual(cloud.kind, .gaussianSplats)
        XCTAssertEqual(cloud.shDegree, 1)
        XCTAssertEqual(cloud.shCoefficients.count, 2 * 9)
        XCTAssertFalse(cloud.subBlocks.isEmpty)
        for splat in cloud.splats {
            // Diagonal elements of 3D covariance must be strictly positive
            XCTAssertGreaterThan(splat.covAx, 0)
            XCTAssertGreaterThan(splat.covBx, 0)
            XCTAssertGreaterThan(splat.covBz, 0)
            XCTAssertGreaterThan(Float(splat.colorA), 0.8)
        }

        // 2. Binary .splat (32 bytes per splat: pos Float32x3, scale Float32x3, rgba UInt8x4, rot UInt8x4)
        let splatURL = FileManager.default.temporaryDirectory.appendingPathComponent("test-antimatter-\(UUID().uuidString).splat")
        var splatData = Data()
        for i in 0..<3 {
            var pos = SIMD3<Float>(Float(i) * 2.0, -1.0, Float(i) + 1.0)
            var scale = SIMD3<Float>(0.15, 0.20, 0.10)
            let rgba: [UInt8] = [240, 120, 60, 255]
            let rot: [UInt8] = [255, 128, 128, 128] // identity quaternion (w=1, x=0, y=0, z=0)
            withUnsafeBytes(of: &pos.x) { splatData.append(contentsOf: $0) }
            withUnsafeBytes(of: &pos.y) { splatData.append(contentsOf: $0) }
            withUnsafeBytes(of: &pos.z) { splatData.append(contentsOf: $0) }
            withUnsafeBytes(of: &scale.x) { splatData.append(contentsOf: $0) }
            withUnsafeBytes(of: &scale.y) { splatData.append(contentsOf: $0) }
            withUnsafeBytes(of: &scale.z) { splatData.append(contentsOf: $0) }
            splatData.append(contentsOf: rgba)
            splatData.append(contentsOf: rot)
        }
        try splatData.write(to: splatURL)
        defer { try? FileManager.default.removeItem(at: splatURL) }

        let splatInfo = try SKPFileInfo.read(splatURL)
        XCTAssertTrue(splatInfo.isSplat)
        XCTAssertTrue(splatInfo.isGaussianSplat)

        let splatModel = try SKPReader.load(splatURL)
        XCTAssertEqual(splatModel.stats.splats, 3)
        XCTAssertEqual(splatModel.splatCloud?.kind, .gaussianSplats)
    }

    func testPointCloudFormatsAndPLYMeshFallback() throws {
        // 1. XYZRGB point cloud
        let xyzText = """
        0.0 0.0 0.0 255 0 0
        2.0 0.0 0.0 0 255 0
        0.0 3.0 1.5 0 0 255
        """
        let xyzURL = FileManager.default.temporaryDirectory.appendingPathComponent("test-cloud-\(UUID().uuidString).xyz")
        try xyzText.write(to: xyzURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: xyzURL) }

        let xyzInfo = try SKPFileInfo.read(xyzURL)
        XCTAssertTrue(xyzInfo.isPointCloud)
        let xyzModel = try SKPReader.load(xyzURL)
        XCTAssertEqual(xyzModel.stats.splats, 3)
        XCTAssertEqual(xyzModel.splatCloud?.kind, .pointCloud)
        XCTAssertEqual(Double(xyzModel.size.x), 2.0, accuracy: 1e-4)
        XCTAssertEqual(Double(xyzModel.size.y), 3.0, accuracy: 1e-4)
        XCTAssertEqual(Double(xyzModel.size.z), 1.5, accuracy: 1e-4)

        // 2. PCD v0.7 ASCII point cloud
        let pcdText = """
        # .PCD v0.7 - Point Cloud Data file format
        VERSION 0.7
        FIELDS x y z
        SIZE 4 4 4
        TYPE F F F
        COUNT 1 1 1
        WIDTH 2
        HEIGHT 1
        VIEWPOINT 0 0 0 1 0 0 0
        POINTS 2
        DATA ascii
        -1.0 -2.0 0.5
        3.0 4.0 2.5
        """
        let pcdURL = FileManager.default.temporaryDirectory.appendingPathComponent("test-pcd-\(UUID().uuidString).pcd")
        try pcdText.write(to: pcdURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: pcdURL) }

        let pcdModel = try SKPReader.load(pcdURL)
        XCTAssertEqual(pcdModel.stats.splats, 2)
        XCTAssertEqual(pcdModel.splatCloud?.kind, .pointCloud)
        XCTAssertEqual(Double(pcdModel.size.x), 4.0, accuracy: 1e-4)
        XCTAssertEqual(Double(pcdModel.size.y), 6.0, accuracy: 1e-4)
        XCTAssertEqual(Double(pcdModel.size.z), 2.0, accuracy: 1e-4)

        // 3. PLY Polygon Mesh fallback
        let meshPlyText = """
        ply
        format ascii 1.0
        element vertex 4
        property float x
        property float y
        property float z
        element face 1
        property list uchar int vertex_indices
        end_header
        0 0 0
        2 0 0
        2 2 0
        0 2 0
        4 0 1 2 3
        """
        let meshPlyURL = FileManager.default.temporaryDirectory.appendingPathComponent("test-mesh-\(UUID().uuidString).ply")
        try meshPlyText.write(to: meshPlyURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: meshPlyURL) }

        let meshPlyModel = try SKPReader.load(meshPlyURL)
        XCTAssertNil(meshPlyModel.splatCloud)
        XCTAssertEqual(meshPlyModel.stats.faces, 1)
        XCTAssertEqual(meshPlyModel.stats.triangles, 2)
    }

    // MARK: Art-Net & Stage Lights Tests

    func testArtNetPacketParsing() {
        var dummyChannels = [UInt8](repeating: 0, count: 512)
        dummyChannels[0] = 255   // Ch 1: 100%
        dummyChannels[20] = 128  // Ch 21: ~50%
        dummyChannels[511] = 64  // Ch 512: ~25%

        let raw = ArtNetReceiver.buildOpDmxPacket(universe: 3, sequence: 42, channels: dummyChannels)
        let parsed = ArtNetReceiver.parseOpDmx(data: raw, count: raw.count)
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.universe, 3)
        XCTAssertEqual(parsed?.shortUniverse, 3)
        XCTAssertEqual(parsed?.sequence, 42)
        XCTAssertEqual(parsed?.length, 512)
        XCTAssertEqual(parsed?.value(forChannel: 1), 255)
        XCTAssertEqual(parsed?.normalized(forChannel: 1), 1.0)
        XCTAssertEqual(parsed?.value(forChannel: 21), 128)
        XCTAssertEqual(parsed?.value(forChannel: 512), 64)
        XCTAssertNil(parsed?.value(forChannel: 0))
        XCTAssertNil(parsed?.value(forChannel: 513))
    }

    func testMilluminFileImport() throws {
        let milluminURL = URL(fileURLWithPath: "/Users/adrien/Dropbox/MilluminFiles/Frissons-Sol-ANGERS.millumin")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: milluminURL.path), "Sample Millumin file not present")

        let lights = try MilluminImporter.parseProject(at: milluminURL)
        XCTAssertFalse(lights.isEmpty, "Should find stage lights in Frissons-Sol-ANGERS.millumin")
        XCTAssertEqual(lights.count, 4, "Expected 4 DALLE fixtures")

        let channels = lights.map { $0.dmxChannel }.sorted()
        XCTAssertEqual(channels, [21, 31, 41, 51])

        let projectors = try MilluminImporter.importProjectors(from: milluminURL)
        XCTAssertEqual(projectors.count, 4)
        for p in projectors {
            XCTAssertEqual(p.spec.kind, .washPanel)
            XCTAssertTrue(p.isStageLight)
            XCTAssertEqual(p.dmxUniverse, 0)
            XCTAssertTrue([21, 31, 41, 51].contains(p.dmxChannel))
            XCTAssertEqual(p.oflFixtureID, "eurolite/led-ml-56-rgbw")
            XCTAssertEqual(p.oflModeName, "6-channel")
            XCTAssertEqual(p.dmxChannelCount, 6)
            // Initial stage cue ("ACCUEILGROUPE") is applied automatically from FCLightStateMedia
            XCTAssertGreaterThan(p.intensity, 0.05)
        }

        // Verify full import including Conduite Lumière cues
        let full = try MilluminImporter.parseProjectFull(at: milluminURL)
        XCTAssertEqual(full.lights.count, 4)
        XCTAssertFalse(full.cues.isEmpty, "Should extract lighting cues from FCBoardColumn / FCLightStateMedia")
    }

    func testVideoProjectorAndStageLightCatalogSeparation() {
        XCTAssertFalse(ProjectorCatalog.videoProjectorSpecs.isEmpty)
        XCTAssertFalse(ProjectorCatalog.stageLightSpecs.isEmpty)

        for vpSpec in ProjectorCatalog.videoProjectorSpecs {
            XCTAssertFalse(vpSpec.isStageLight, "\(vpSpec.displayName) should not be a stage light")
            XCTAssertEqual(vpSpec.kind, .videoProjector)
        }

        for lightSpec in ProjectorCatalog.stageLightSpecs {
            XCTAssertTrue(lightSpec.isStageLight, "\(lightSpec.displayName) must be a stage light")
            XCTAssertNotEqual(lightSpec.kind, .videoProjector)
            XCTAssertGreaterThan(lightSpec.maxBeamAngleDegrees, 5.0)
        }
    }

    func testOFLFixtureLibraryAndDMXChannelRoles() {
        let lib = OFLFixtureLibrary.shared
        XCTAssertFalse(lib.allFixtures.isEmpty)

        // 1. Eurolite LED ML-56 RGBW 6-channel (R, G, B, W, Dimmer at index 4, Function at index 5)
        let ml56 = lib.fixture(forIdentifier: "eurolite/led-ml-56-rgbw")
        XCTAssertNotNil(ml56)
        let mode6 = ml56?.mode(named: "6-channel")
        XCTAssertEqual(mode6?.channels.count, 6)
        XCTAssertEqual(mode6?.channels[0].role, .red)
        XCTAssertEqual(mode6?.channels[1].role, .green)
        XCTAssertEqual(mode6?.channels[2].role, .blue)
        XCTAssertEqual(mode6?.channels[4].role, .dimmer)

        var wash = VideoProjector(
            name: "DALLE 1",
            specID: ProjectorSpec.euroliteLEDML56RGBW.id,
            position: SIMD3<Float>(0, 0, 5),
            target: SIMD3<Float>(0, 0, 0),
            dmxUniverse: 0,
            dmxChannel: 21,
            oflFixtureID: "eurolite/led-ml-56-rgbw",
            oflModeName: "6-channel",
            dmxChannelNames: mode6?.channels.map { $0.name } ?? [],
            dmxChannelRoles: mode6?.channels.map { $0.role } ?? []
        )
        var universe = [Float](repeating: 0.0, count: 512)
        universe[20] = 0.20 // Ch 21: Red = 20%
        universe[21] = 0.60 // Ch 22: Green = 60%
        universe[22] = 1.00 // Ch 23: Blue = 100%
        universe[23] = 0.00 // Ch 24: White = 0%
        universe[24] = 0.80 // Ch 25: Dimmer = 80%
        let didChange = wash.applyDMXValues(universe)
        XCTAssertTrue(didChange)
        XCTAssertEqual(Double(wash.intensity), 0.80, accuracy: 1e-4)
        XCTAssertEqual(Double(wash.lightColor.x), 0.20, accuracy: 1e-3)
        XCTAssertEqual(Double(wash.lightColor.y), 0.60, accuracy: 1e-3)
        XCTAssertEqual(Double(wash.lightColor.z), 1.00, accuracy: 1e-3)

        // 2. American DJ Ikon Profile 3-channel (Ch 1: Strobe, Ch 2: Dimmer, Ch 3: Dimmer Mod -> must be ignored)
        let ikon = lib.fixture(forIdentifier: "american-dj/ikon-profile")
        XCTAssertNotNil(ikon)
        let ikonMode = ikon?.modes.first
        XCTAssertEqual(ikonMode?.channels.count, 3)
        XCTAssertTrue(ikonMode?.channels.contains(where: { $0.role == .dimmer }) == true)
        XCTAssertNotEqual(ikonMode?.channels[2].role, .dimmer, "Dimmer Mod must not override master Dimmer")

        // 3. Millumin Cue values application
        var cueLight = wash
        let cueApplied = cueLight.applyMilluminCueValues([
            "___Intensity": 0.55,
            "___Red": 1.0,
            "___Green": 0.4,
            "___Blue": 0.1
        ])
        XCTAssertTrue(cueApplied)
        XCTAssertEqual(Double(cueLight.intensity), 0.55, accuracy: 1e-4)
        XCTAssertEqual(Double(cueLight.lightColor.x), 1.0, accuracy: 1e-3)
        XCTAssertEqual(Double(cueLight.lightColor.y), 0.4, accuracy: 1e-3)
        XCTAssertEqual(Double(cueLight.lightColor.z), 0.1, accuracy: 1e-3)
    }

    func testGLTFAndGLBReaderLoadsMeshesHierarchyMaterialsAndRealGLB() throws {
        // 1. Build a binary buffer with 3 float3 vertices (36 bytes) + 3 UInt16 indices (6 bytes padded to 8) = 44 bytes
        var binData = Data()
        let verts: [Float] = [
            0.0, 0.0, 0.0,
            4.0, 0.0, 0.0,
            0.0, 3.0, 0.0 // Y=3 in glTF -> Z=3 in SimpleSKP
        ]
        for f in verts {
            var bits = f.bitPattern.littleEndian
            binData.append(Data(bytes: &bits, count: 4))
        }
        let indices: [UInt16] = [0, 1, 2, 0] // 8 bytes total
        for idx in indices {
            var le = idx.littleEndian
            binData.append(Data(bytes: &le, count: 2))
        }

        let b64 = binData.base64EncodedString()
        let gltfJSON = """
        {
          "asset": { "version": "2.0", "generator": "SimpleSKP Test" },
          "scene": 0,
          "scenes": [{ "nodes": [0] }],
          "nodes": [
            { "name": "Plateau", "mesh": 0, "translation": [0.0, 1.5, 0.0] }
          ],
          "meshes": [
            {
              "name": "ArcheMesh",
              "primitives": [
                {
                  "attributes": { "POSITION": 0 },
                  "indices": 1,
                  "material": 0
                }
              ]
            }
          ],
          "materials": [
            {
              "name": "VeloursNoir",
              "pbrMetallicRoughness": {
                "baseColorFactor": [0.2, 0.4, 0.8, 1.0]
              }
            }
          ],
          "buffers": [
            {
              "uri": "data:application/octet-stream;base64,\(b64)",
              "byteLength": \(binData.count)
            }
          ],
          "bufferViews": [
            { "buffer": 0, "byteOffset": 0, "byteLength": 36 },
            { "buffer": 0, "byteOffset": 36, "byteLength": 6 }
          ],
          "accessors": [
            { "bufferView": 0, "componentType": 5126, "count": 3, "type": "VEC3" },
            { "bufferView": 1, "componentType": 5123, "count": 3, "type": "SCALAR" }
          ]
        }
        """

        let gltfURL = FileManager.default.temporaryDirectory.appendingPathComponent("test-\(UUID().uuidString).gltf")
        try gltfJSON.write(to: gltfURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: gltfURL) }

        let gltfInfo = try SKPFileInfo.read(gltfURL)
        XCTAssertTrue(gltfInfo.isGLTF)
        XCTAssertTrue(gltfInfo.isGLTFOrGLB)

        let gltfModel = try SKPReader.load(gltfURL)
        XCTAssertEqual(gltfModel.stats.triangles, 1)
        XCTAssertEqual(gltfModel.materials.first?.name, "VeloursNoir")
        XCTAssertTrue(gltfModel.layers.contains(where: { $0.name == "Plateau" }))
        // Translation Y=1.5 + vertex Y=3.0 in glTF -> Z_min = 1.5, Z_max = 4.5 in Z-up SimpleSKP
        XCTAssertEqual(Double(gltfModel.boundsMin.z), 1.5, accuracy: 1e-4)
        XCTAssertEqual(Double(gltfModel.boundsMax.z), 4.5, accuracy: 1e-4)
        XCTAssertEqual(Double(gltfModel.size.x), 4.0, accuracy: 1e-4)

        // 2. Real GLB on disk if present (`venue.glb` from Piano Inside)
        let realGLB = URL(fileURLWithPath: "/Users/adrien/Programmation/QuestVR/piano-inside-mac/Resources/venue.glb")
        if FileManager.default.fileExists(atPath: realGLB.path) {
            let info = try SKPFileInfo.read(realGLB)
            XCTAssertTrue(info.isGLB)
            let venue = try SKPReader.load(realGLB)
            defer {
                if let texDir = venue.textureDirectory {
                    try? FileManager.default.removeItem(at: texDir)
                }
            }
            XCTAssertGreaterThan(venue.stats.triangles, 1000)
            XCTAssertGreaterThan(venue.materials.count, 5)
            XCTAssertTrue(venue.materials.contains(where: { $0.textureURL != nil }))
        }
    }
}

final class Box<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}

private extension URL {
    var creationDate: Date? { try? resourceValues(forKeys: [.creationDateKey]).creationDate }
}

final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var count = 0
    func next() -> Int { lock.lock(); defer { lock.unlock() }; count += 1; return count }
}
