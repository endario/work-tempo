import XCTest
@testable import WorkTempoMenuBar

final class DashboardHeightTests: XCTestCase {
    func testTallDisplayFitsMeasuredChartContent() {
        XCTAssertEqual(DashboardView.viewportHeight(content: 540, screenHeight: 1_289), 540)
    }

    func testShortDisplayCapsContentBeforeFixedFooter() {
        XCTAssertEqual(DashboardView.viewportHeight(content: 540, screenHeight: 600), 480)
    }
}
