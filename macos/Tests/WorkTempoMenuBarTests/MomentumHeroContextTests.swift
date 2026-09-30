import XCTest
import WorkTempoCore
@testable import WorkTempoMenuBar

final class MomentumHeroContextTests: XCTestCase {
    func testAvailableHeadlineNamesTheMetricAndItsWindow() {
        XCTAssertEqual(MomentumHero.headlineContext(windowDays: 30, isAvailable: true), "SOURCE CHURN (LAST 30 DAYS)")
    }

    func testUnavailableHeadlineDoesNotClaimHistoryExists() {
        XCTAssertEqual(MomentumHero.headlineContext(windowDays: 30, isAvailable: false), "HEADLINE UNAVAILABLE")
    }
}

final class MomentumHeroChangeRowsTests: XCTestCase {
    private let breakdown = WindowBreakdown(
        code: ChurnTotals(added: 400, deleted: 50),
        tests: ChurnTotals(added: 300, deleted: 30),
        docs: ChurnTotals(added: 90, deleted: 100)
    )

    // The net figure above is added minus removed, so a row that showed only
    // additions would read as the net it is not.
    func testEachRowShowsWhatWasAddedAndWhatWasRemoved() {
        let rows = MomentumHero.changeRows(breakdown)

        XCTAssertEqual(rows.map(\.id), ["code", "tests", "docs"])
        XCTAssertEqual(rows.map(\.values), [["+400", "\u{2212}50"], ["+300", "\u{2212}30"], ["(+90)", "(\u{2212}100)"]])
    }

    func testUnavailableHeadlineShowsDashesRatherThanZeros() {
        let rows = MomentumHero.changeRows(nil)

        XCTAssertEqual(rows.map(\.values), [["--", "--"], ["--", "--"], ["--", "--"]])
    }
}
