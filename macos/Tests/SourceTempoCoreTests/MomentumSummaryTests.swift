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
        XCTAssertEqual(summary.dailyChurn, 10, accuracy: 0.000_001)
        XCTAssertEqual(summary.netGrowth, 90)
        XCTAssertEqual(summary.recentChurn, Array(repeating: 10, count: 30))
        XCTAssertEqual(summary.recentNetGrowth.count, 30)
        XCTAssertEqual(summary.recentNetGrowth.first, 3)
        XCTAssertEqual(summary.recentNetGrowth.last, 90)
    }

    func testUsesReportGeneratedDateInsteadOfCurrentDate() throws {
        let report = try ReportDocument.decode(data: makeReportData(
            generatedDate: "2026-08-31",
            churn: Array(repeating: 1, count: 60) + [50_000]
        ))

        let summary = MomentumSummary(report: report)

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
