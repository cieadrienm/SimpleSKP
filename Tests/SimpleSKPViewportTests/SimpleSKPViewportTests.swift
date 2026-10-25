import XCTest
@testable import SimpleSKPViewport
import SimpleSKPCore

final class SimpleSKPViewportTests: XCTestCase {
    func testStandardViews() {
        XCTAssertEqual(StandardView.allCases.count, 7)
    }
}
