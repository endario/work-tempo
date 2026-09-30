import XCTest
@testable import WorkTempoCore

final class MomentumSummaryTests: XCTestCase {
    func testComparesTwoClosedThirtyDayWindowsAndExcludesDocs() throws {
        let previous = Array(repeating: 5, count: 30)
        let current = Array(repeating: 10, count: 30)
        let report = try ReportDocument.decode(data: makeReportData(
            churn: previous + current + [99_999],
            added: Array(repeating: 0, count: 30) + Array(repeating: 7, count: 30) + [99_999],
            deleted: Array(repeating: 0, count: 30) + Array(repeating: 4, count: 30) + [99_999]
        ))

        let summary = MomentumSummary(report: report, maxWindowDays: 30)

        XCTAssertEqual(summary.currentChurn, 300)
        XCTAssertEqual(summary.dailyChurn, 10, accuracy: 0.000_001)
        XCTAssertEqual(summary.netGrowth, 90)
        XCTAssertEqual(summary.recentChurn, Array(repeating: 10, count: 30))
        XCTAssertEqual(summary.recentNetGrowth.count, 30)
        XCTAssertEqual(summary.recentNetGrowth.first, 3)
        XCTAssertEqual(summary.recentNetGrowth.last, 90)
        XCTAssertEqual(summary.windowDays, 30)
    }

    // The hero sparklines label each point by day, so a label has to name the
    // same day whose churn sits beside it.
    func testRecentLabelsNameTheDaysBehindTheRecentSeries() throws {
        let report = try ReportDocument.decode(data: makeReportData(
            generatedDate: "2026-08-31",
            churn: Array(repeating: 1, count: 61)
        ))

        let summary = MomentumSummary(report: report, maxWindowDays: 30)

        XCTAssertEqual(summary.recentLabels.count, summary.recentChurn.count)
        XCTAssertEqual(summary.recentLabels.last, "2026-08-30")
        XCTAssertEqual(summary.recentLabels.first, "2026-08-01")
    }

    // A readout puts the day's added and removed beside its churn, so the three
    // series have to be the same slice of the same window.
    func testRecentAddedAndDeletedCoverTheSameWindowAsChurn() throws {
        // Values vary by index so a window off by even one day fails.
        let added = (0..<60).map { $0 }
        let deleted = (0..<60).map { 100 + $0 }
        let report = try ReportDocument.decode(data: makeReportData(
            churn: zip(added, deleted).map(+) + [99_999],
            added: added + [99_999],
            deleted: deleted + [99_999]
        ))

        let summary = MomentumSummary(report: report, maxWindowDays: 30)

        XCTAssertEqual(summary.recentAdded, Array(30..<60))
        XCTAssertEqual(summary.recentDeleted, (30..<60).map { 100 + $0 })
        XCTAssertEqual(zip(summary.recentAdded, summary.recentDeleted).map(+), summary.recentChurn)
    }

    // The table under the hero sums each kind over the window the headline
    // figures use, so an off-by-one window or a crossed kind shows up here.
    func testBreakdownSumsEachKindOverTheHeadlineWindow() throws {
        let codeAdded = (0..<60).map { 1 + $0 }
        let testAdded = (0..<60).map { 1_000 + $0 }
        let codeDeleted = (0..<60).map { 10_000 + $0 }
        let testDeleted = (0..<60).map { 100_000 + $0 }
        let docAdded = (0..<60).map { 1_000_000 + $0 }
        let docDeleted = (0..<60).map { 10_000_000 + $0 }
        let window = 30..<60
        let report = try ReportDocument.decode(data: makeReportData(
            churn: Array(repeating: 1, count: 61),
            added: zip(codeAdded, testAdded).map(+) + [99_999],
            deleted: zip(codeDeleted, testDeleted).map(+) + [99_999],
            codeAdded: codeAdded + [99_999],
            testAdded: testAdded + [99_999],
            codeDeleted: codeDeleted + [99_999],
            testDeleted: testDeleted + [99_999],
            docAdded: docAdded + [99_999],
            docDeleted: docDeleted + [99_999]
        ))

        let breakdown = MomentumSummary(report: report, maxWindowDays: 30).breakdown

        XCTAssertEqual(breakdown.code, ChurnTotals(added: codeAdded[window].reduce(0, +), deleted: codeDeleted[window].reduce(0, +)))
        XCTAssertEqual(breakdown.tests, ChurnTotals(added: testAdded[window].reduce(0, +), deleted: testDeleted[window].reduce(0, +)))
        XCTAssertEqual(breakdown.docs, ChurnTotals(added: docAdded[window].reduce(0, +), deleted: docDeleted[window].reduce(0, +)))
    }

    func testBreakdownSourceIsCodePlusTestsAndMatchesTheHeadline() throws {
        let report = try ReportDocument.decode(data: makeReportData(
            churn: Array(repeating: 10, count: 61),
            added: Array(repeating: 7, count: 61),
            deleted: Array(repeating: 3, count: 61),
            codeAdded: Array(repeating: 5, count: 61),
            testAdded: Array(repeating: 2, count: 61),
            codeDeleted: Array(repeating: 2, count: 61),
            testDeleted: Array(repeating: 1, count: 61),
            docAdded: Array(repeating: 100, count: 61),
            docDeleted: Array(repeating: 100, count: 61)
        ))

        let summary = MomentumSummary(report: report, maxWindowDays: 30)

        XCTAssertEqual(summary.breakdown.source, ChurnTotals(added: 210, deleted: 90))
        XCTAssertEqual(summary.breakdown.source.churn, summary.currentChurn)
        XCTAssertEqual(summary.breakdown.source.net, summary.netGrowth)
        XCTAssertEqual(summary.breakdown.docs.churn, 6_000, "docs stay out of source")
    }

    func testBreakdownStartsAtTheFirstTrackedDayForAYoungWorkspace() throws {
        let idle = Array(repeating: 0, count: 55)
        let report = try ReportDocument.decode(data: makeReportData(
            loc: idle + Array(repeating: 100, count: 5) + [100],
            churn: idle + Array(repeating: 20, count: 5) + [99_999],
            added: idle + Array(repeating: 12, count: 5) + [99_999],
            deleted: idle + Array(repeating: 8, count: 5) + [99_999],
            docAdded: Array(repeating: 9, count: 61)
        ))

        let summary = MomentumSummary(report: report, maxWindowDays: 30)

        XCTAssertEqual(summary.windowDays, 5)
        XCTAssertEqual(summary.breakdown.code, ChurnTotals(added: 60, deleted: 40))
        XCTAssertEqual(summary.breakdown.docs.added, 45, "five tracked days, not the thirty before them")
    }

    func testRateIsMeasuredFromTheFirstTrackedDayForAYoungWorkspace() throws {
        let idle = Array(repeating: 0, count: 55)
        let live = Array(repeating: 100, count: 5)
        let report = try ReportDocument.decode(data: makeReportData(
            loc: idle + live + [100],
            churn: idle + Array(repeating: 20, count: 5) + [99_999],
            added: idle + Array(repeating: 12, count: 5) + [99_999],
            deleted: idle + Array(repeating: 8, count: 5) + [99_999]
        ))

        let summary = MomentumSummary(report: report, maxWindowDays: 30)

        XCTAssertEqual(summary.windowDays, 5)
        XCTAssertEqual(summary.currentChurn, 100)
        XCTAssertEqual(summary.dailyChurn, 20, accuracy: 0.000_001)
        XCTAssertEqual(summary.recentChurn.count, 5)
        XCTAssertEqual(summary.recentLabels.count, 5)
        XCTAssertEqual(summary.netGrowth, 20)
    }

    func testFirstTrackedDayCountsChurnThatLeavesNoLinesBehind() throws {
        let idle = Array(repeating: 0, count: 58)
        let report = try ReportDocument.decode(data: makeReportData(
            loc: idle + [0, 100] + [100],
            churn: idle + [20, 10] + [99_999],
            added: idle + [10, 10] + [99_999],
            deleted: idle + [10, 0] + [99_999]
        ))

        let summary = MomentumSummary(report: report, maxWindowDays: 30)

        XCTAssertEqual(summary.windowDays, 2)
        XCTAssertEqual(summary.currentChurn, 30)
        XCTAssertEqual(summary.dailyChurn, 15, accuracy: 0.000_001)
    }

    func testUsesReportGeneratedDateInsteadOfCurrentDate() throws {
        let report = try ReportDocument.decode(data: makeReportData(
            generatedDate: "2026-08-31",
            churn: Array(repeating: 1, count: 60) + [50_000]
        ))

        let summary = MomentumSummary(report: report, maxWindowDays: 30)

        XCTAssertEqual(summary.currentChurn, 30)
        XCTAssertEqual(summary.dailyChurn, 1)
    }

    func testCompactMetricFormatting() {
        XCTAssertEqual(MetricFormatter.compact(0.33), "0.3")
        XCTAssertEqual(MetricFormatter.compact(2.0), "2")
        XCTAssertEqual(MetricFormatter.compact(999), "999")
        XCTAssertEqual(MetricFormatter.compact(1_200), "1.2K")
        XCTAssertEqual(MetricFormatter.compact(1_180_141), "1.18M")
    }
}
