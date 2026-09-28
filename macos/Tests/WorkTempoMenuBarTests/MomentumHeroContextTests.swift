import XCTest
@testable import WorkTempoMenuBar

final class MomentumHeroContextTests: XCTestCase {
    func testAvailableHeadlineNamesItsClosedDayWindow() {
        XCTAssertEqual(MomentumHero.headlineContext(windowDays: 30, isAvailable: true), "LAST 30 CLOSED DAYS")
    }

    func testUnavailableHeadlineDoesNotClaimHistoryExists() {
        XCTAssertEqual(MomentumHero.headlineContext(windowDays: 30, isAvailable: false), "HEADLINE UNAVAILABLE")
    }
}
