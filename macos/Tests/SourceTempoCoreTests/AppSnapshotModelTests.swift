import Foundation
import XCTest
@testable import SourceTempoCore

final class AppSnapshotModelTests: XCTestCase {
    func testEmptySnapshotHasUsefulMenuAndAccessibilityCopy() throws {
        let workspace = try Workspace(root: URL(fileURLWithPath: "/tmp/fixture"))
        let snapshot = DashboardSnapshot(
            workspace: workspace,
            report: nil,
            refreshState: .idle,
            now: Date(timeIntervalSince1970: 0)
        )

        XCTAssertEqual(snapshot.dataState, .empty)
        XCTAssertEqual(snapshot.menuValue, "--")
        XCTAssertEqual(snapshot.menuAccessibilityLabel, "Source Tempo, fixture, no report yet")
        XCTAssertFalse(snapshot.hasMomentum)
        XCTAssertTrue(snapshot.metrics.allSatisfy { $0.value == "--" })

        let refreshing = DashboardSnapshot(
            workspace: workspace,
            report: nil,
            refreshState: .refreshing,
            now: Date(timeIntervalSince1970: 0)
        )
        XCTAssertFalse(refreshing.hasMomentum)
    }

    func testCachedSnapshotExposesMetricsAndMomentum() throws {
        let report = try report(
            currentChurn: 300,
            previousChurn: 150,
            loc: 12_345,
            code: 8_000,
            test: 4_345,
            docs: 900
        )
        let snapshot = DashboardSnapshot(
            workspace: try Workspace(root: URL(fileURLWithPath: "/tmp/fixture")),
            report: report,
            refreshState: .idle,
            now: try generatedAt(report).addingTimeInterval(300)
        )

        XCTAssertEqual(snapshot.dataState, .ready)
        XCTAssertEqual(snapshot.menuValue, "10/d")
        XCTAssertEqual(snapshot.menuAccessibilityLabel, "Source Tempo, Fixture, 10 source lines changed per day")
        XCTAssertEqual(snapshot.metrics.map(\.value), ["12K", "8K", "4.3K", "900"])
        XCTAssertTrue(snapshot.hasMomentum)
        XCTAssertEqual(snapshot.recentChurn.count, 30)
        XCTAssertEqual(snapshot.recentNetGrowth.last, snapshot.netGrowth)
    }

    func testRefreshingAndFailedSnapshotsRetainCachedValues() throws {
        let report = try self.report(currentChurn: 60, previousChurn: 40)
        let workspace = try Workspace(root: URL(fileURLWithPath: "/tmp/fixture"))
        let now = try generatedAt(report).addingTimeInterval(300)

        let refreshing = DashboardSnapshot(
            workspace: workspace,
            report: report,
            refreshState: .refreshing,
            now: now
        )
        XCTAssertTrue(refreshing.isRefreshing)
        XCTAssertEqual(refreshing.dataState, .ready)
        XCTAssertEqual(refreshing.menuValue, "2/d")
        XCTAssertEqual(refreshing.menuAccessibilityLabel, "Source Tempo, Fixture, 2 source lines changed per day, refreshing")

        let failed = DashboardSnapshot(
            workspace: workspace,
            report: report,
            refreshState: .failed("collector unavailable"),
            now: now
        )
        XCTAssertEqual(failed.dataState, .failedWithCache)
        XCTAssertEqual(failed.errorMessage, "collector unavailable")
        XCTAssertEqual(failed.menuValue, "2/d")
    }

    func testStaleSnapshotMarksMenuWithoutDroppingData() throws {
        let report = try self.report(currentChurn: 60, previousChurn: 40)
        let snapshot = DashboardSnapshot(
            workspace: try Workspace(root: URL(fileURLWithPath: "/tmp/fixture")),
            report: report,
            refreshState: .idle,
            now: try generatedAt(report).addingTimeInterval(3_601)
        )

        XCTAssertEqual(snapshot.dataState, .stale)
        XCTAssertEqual(snapshot.menuValue, "2/d")
        XCTAssertEqual(snapshot.menuAccessibilityLabel, "Source Tempo, Fixture, 2 source lines changed per day, stale")
    }

    func testFractionalCollectorTimestampDoesNotForceFreshReportStale() throws {
        let data = try XCTUnwrap(String(data: makeReportData(), encoding: .utf8))
            .replacingOccurrences(of: "2026-08-31T12:00:00+08:00", with: "2026-08-31T12:00:00.228700+08:00")
        let report = try ReportDocument.decode(data: Data(data.utf8))
        let generatedAt = try XCTUnwrap(ISO8601DateFormatter.fractional.date(from: report.generatedAt))

        let snapshot = DashboardSnapshot(
            workspace: try Workspace(root: URL(fileURLWithPath: "/tmp/fixture")),
            report: report,
            refreshState: .idle,
            now: generatedAt.addingTimeInterval(60)
        )

        XCTAssertEqual(snapshot.dataState, .ready)
        XCTAssertEqual(snapshot.reportGeneratedAt, generatedAt)
    }

    func testAggregateSnapshotPublishesDailyRateAndCoverage() throws {
        let workspace = try Workspace(root: URL(fileURLWithPath: "/tmp/fixture"))
        let report = try ReportDocument.decode(data: makeReportData(
            dayCount: 185,
            churn: Array(repeating: 2, count: 185)
        ))
        let portfolio = try PortfolioMomentum.build(
            workspaces: [workspace],
            reports: [workspace: report]
        ).get()

        let snapshot = DashboardSnapshot(
            portfolio: portfolio,
            refreshState: .idle,
            now: try generatedAt(report)
        )

        XCTAssertEqual(snapshot.workspaceName, "All Workspaces")
        XCTAssertEqual(snapshot.menuValue, "2/d")
        XCTAssertTrue(snapshot.hasMomentum)
        XCTAssertEqual(snapshot.dailyChurn, 2)
        XCTAssertEqual(snapshot.chartTimeline?.closedDayCount, 184)
        XCTAssertEqual(snapshot.chartTimeline?.monthlyChurn.map(\.label), [
            "2026-03", "2026-04", "2026-05", "2026-06", "2026-07", "2026-08",
        ])
    }

    func testZeroChurnIsAvailableMomentum() throws {
        let report = try self.report(currentChurn: 0, previousChurn: 0)
        let snapshot = DashboardSnapshot(
            workspace: try Workspace(root: URL(fileURLWithPath: "/tmp/fixture")),
            report: report,
            refreshState: .idle,
            now: try generatedAt(report)
        )

        XCTAssertTrue(snapshot.hasMomentum)
        XCTAssertEqual(snapshot.menuValue, "0/d")
        XCTAssertEqual(snapshot.dailyChurn, 0)
        XCTAssertEqual(snapshot.netGrowth, 0)
    }

    func testPartialPortfolioUsesNoticeChannel() throws {
        let first = try Workspace(root: URL(fileURLWithPath: "/tmp/first"))
        let second = try Workspace(root: URL(fileURLWithPath: "/tmp/second"))
        let report = try self.report(currentChurn: 30, previousChurn: 0)
        let portfolio = try PortfolioMomentum.build(
            workspaces: [first, second],
            reports: [first: report]
        ).get()

        let snapshot = DashboardSnapshot(
            portfolio: portfolio,
            refreshState: .idle,
            now: try generatedAt(report)
        )

        XCTAssertNil(snapshot.errorMessage)
        XCTAssertEqual(snapshot.noticeMessage, "1 of 2 workspaces contributing")
    }

    private func report(
        currentChurn: Int,
        previousChurn: Int,
        loc: Int = 220,
        code: Int = 140,
        test: Int = 80,
        docs: Int = 50
    ) throws -> ReportDocument {
        var churn = Array(repeating: 0, count: 61)
        churn.replaceSubrange(0..<30, with: repeatElement(previousChurn / 30, count: 30))
        churn.replaceSubrange(30..<60, with: repeatElement(currentChurn / 30, count: 30))
        if previousChurn % 30 != 0 { churn[0] += previousChurn % 30 }
        if currentChurn % 30 != 0 { churn[30] += currentChurn % 30 }
        let locValues = Array(repeating: loc, count: 61)
        return try ReportDocument.decode(data: makeReportData(
            loc: locValues,
            code: Array(repeating: code, count: 61),
            test: Array(repeating: test, count: 61),
            docs: Array(repeating: docs, count: 61),
            churn: churn
        ))
    }

    private func generatedAt(_ report: ReportDocument) throws -> Date {
        try XCTUnwrap(ISO8601DateFormatter().date(from: report.generatedAt))
    }
}

private extension ISO8601DateFormatter {
    static var fractional: ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }
}
