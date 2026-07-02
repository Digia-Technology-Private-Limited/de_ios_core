import XCTest
@testable import DigiaEngage

final class RegionRectMapperTests: XCTestCase {
    func testMapsIntoContentFrame() {
        let r = computeRegionRect(
            RegionFrac(x: 0.10, y: 0.50, w: 0.80, h: 0.05),
            screen: CGSize(width: 1000, height: 2000),
            insets: EdgeInsets2(left: 0, top: 100, right: 0, bottom: 100))
        XCTAssertEqual(r.origin.x, 100, accuracy: 0.5)
        XCTAssertEqual(r.origin.y, 1000, accuracy: 0.5)   // 100 + 0.5*1800
        XCTAssertEqual(r.size.width, 800, accuracy: 0.5)
        XCTAssertEqual(r.size.height, 90, accuracy: 0.5)
    }

    func testClampsOnScreen() {
        let r = computeRegionRect(
            RegionFrac(x: 0.95, y: 0.98, w: 0.40, h: 0.40),
            screen: CGSize(width: 1000, height: 2000),
            insets: EdgeInsets2(left: 0, top: 0, right: 0, bottom: 0))
        XCTAssertGreaterThanOrEqual(r.origin.x, 0)
        XCTAssertLessThanOrEqual(r.maxX, 1000)
        XCTAssertLessThanOrEqual(r.maxY, 2000)
    }
}
