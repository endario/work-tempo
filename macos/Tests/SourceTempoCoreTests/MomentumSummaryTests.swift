import XCTest
@testable import SourceTempoCore

final class MomentumSummaryTests: XCTestCase {
    func testComparesTwoClosedThirtyDayWindowsAndExcludesDocs() throws {
        let previous = Array(repeating: 5, count: 30)
        let current = Array(repeating: 10, count: 30)
        let report = try ReportDocument.decode(data: makeReportData(
            churn: previous + current + [99_999],
            added: Array(repeating: 0, count: 30) + Array(repeating: 7, count: 30) + [99_999],
            deleted: Array(repeating: 0, count: 30) + Array(repeating: 4, count: 30) + [99_999]
        ))

        let summary = MomentumSummary(report: report)

        XCTAssertEqual(summary.currentChurn, 300)
        XCTAssertEqual(summary.previousChurn, 150)
        XCTAssertEqual(summary.netGrowth, 90)
        guard case let .ready(share) = summary.pace else {
            return XCTFail("Expected a ready pace")
        }
        XCTAssertEqual(share, 2.0 / 3.0, accuracy: 0.000_001)
    }

    func testUsesReportGeneratedDateInsteadOfCurrentDate() throws {
        let report = try ReportDocument.decode(data: makeReportData(
            generatedDate: "2026-08-31",
            churn: Array(repeating: 1, count: 60) + [50_000]
        ))

        let summary = MomentumSummary(report: report)

        XCTAssertEqual(summary.currentChurn, 30)
        XCTAssertEqual(summary.previousChurn, 30)
    }

    func testReportsInsufficientHistoryForShortOrYoungReports() throws {
        let short = try ReportDocument.decode(data: makeReportData(dayCount: 30))
        XCTAssertEqual(MomentumSummary(report: short).pace, .insufficientHistory)

        var youngLoc = Array(repeating: 0, count: 31)
        youngLoc.append(contentsOf: Array(repeating: 100, count: 30))
        let young = try ReportDocument.decode(data: makeReportData(loc: youngLoc))
        XCTAssertEqual(MomentumSummary(report: young).pace, .insufficientHistory)
    }

    func testDistinguishesNewAndNoActivity() throws {
        let newActivity = try ReportDocument.decode(data: makeReportData(
            churn: Array(repeating: 0, count: 30) + Array(repeating: 1, count: 30) + [0]
        ))
        XCTAssertEqual(MomentumSummary(report: newActivity).pace, .newActivity)

        let noActivity = try ReportDocument.decode(data: makeReportData())
        XCTAssertEqual(MomentumSummary(report: noActivity).pace, .noRecentActivity)
    }

    func testTrendDropsLeadingZeroSourceDays() throws {
        let loc = Array(repeating: 0, count: 5) + Array(repeating: 220, count: 56)
        let code = Array(repeating: 0, count: 5) + Array(repeating: 140, count: 56)
        let test = Array(repeating: 0, count: 5) + Array(repeating: 80, count: 56)
        let report = try ReportDocument.decode(data: makeReportData(loc: loc, code: code, test: test))

        let summary = MomentumSummary(report: report)

        XCTAssertEqual(summary.trend.count, 56)
        XCTAssertEqual(summary.trend.first?.code, 140)
        XCTAssertEqual(summary.trend.first?.test, 80)
    }

    func testCompactMetricFormatting() {
        XCTAssertEqual(MetricFormatter.compact(999), "999")
        XCTAssertEqual(MetricFormatter.compact(1_200), "1.2K")
        XCTAssertEqual(MetricFormatter.compact(1_180_141), "1.18M")
    }
}
