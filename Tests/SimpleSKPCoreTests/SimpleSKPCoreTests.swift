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
