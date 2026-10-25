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
        let location = try XCTUnwrap(SketchUpAPI.locate())
        XCTAssertTrue(location.appVersion?.hasPrefix("23") == true, "\(location)")
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
        }
        let size = model.size
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
}
