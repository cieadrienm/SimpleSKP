import XCTest
@testable import SimpleSKPCore

final class SimpleSKPCoreTests: XCTestCase {
    static let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/VerreMirroir.skp")

    func testFixtureExists() {
        XCTAssertTrue(FileManager.default.fileExists(atPath: Self.fixture.path))
    }
}
