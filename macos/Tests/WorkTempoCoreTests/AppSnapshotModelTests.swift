import Foundation
import XCTest
@testable import WorkTempoCore

final class AppSnapshotModelTests: XCTestCase {
    func testEmptySnapshotHasUsefulMenuAndAccessibilityCopy() throws {
        let workspace = try Workspace(root: URL(fileURLWithPath: "/tmp/fixture"))
        let snapshot = DashboardSnapshot(
            workspace: workspace,
            report: nil,
            refreshState: .idle,
            now: Date(timeIntervalSince1970: 0),
            staleInterval: 3_600,
            maxWindowDays: 30,
            historyWindow: HistoryWindow(historyDays: 184)
        )

        XCTAssertEqual(snapshot.dataState, .empty)
        XCTAssertEqual(snapshot.menuValue, "--")
        XCTAssertEqual(snapshot.menuAccessibilityLabel, "Work Tempo, fixture, no report yet")
        XCTAssertFalse(snapshot.hasMomentum)
        XCTAssertTrue(snapshot.metrics.allSatisfy { $0.value == "--" })
        XCTAssertNil(snapshot.windowBreakdown)

        let refreshing = DashboardSnapshot(
            workspace: workspace,
            report: nil,
            refreshState: .refreshing,
            now: Date(timeIntervalSince1970: 0),
            staleInterval: 3_600,
            maxWindowDays: 30,
            historyWindow: HistoryWindow(historyDays: 184)
        )
        XCTAssertFalse(refreshing.hasMomentum)
    }

    func testEmptyPortfolioUsesUnavailableMetricValues() throws {
        let workspace = try Workspace(root: URL(fileURLWithPath: "/tmp/fixture"))
        let portfolio = try PortfolioMomentum.build(
            workspaces: [workspace],
            reports: [:],
            historyWindow: HistoryWindow(historyDays: 184),
            windowDays: 30
        ).get()

        let snapshot = DashboardSnapshot(
            portfolio: portfolio,
            refreshState: .idle,
            now: Date(timeIntervalSince1970: 0),
            maxWindowDays: 30
        )

        XCTAssertEqual(snapshot.dataState, .empty)
        XCTAssertTrue(snapshot.metrics.allSatisfy { $0.value == "--" })
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
            now: try generatedAt(report).addingTimeInterval(300),
            staleInterval: 3_600,
            maxWindowDays: 30,
            historyWindow: HistoryWindow(historyDays: 184)
        )

        XCTAssertEqual(snapshot.dataState, .ready)
        XCTAssertEqual(snapshot.menuValue, "10/d")
        XCTAssertEqual(snapshot.menuAccessibilityLabel, "Work Tempo, Fixture, 10 code and test lines changed per day")
        XCTAssertEqual(snapshot.metrics.map(\.value), ["12K", "8K", "4.3K", "900"])
        XCTAssertTrue(snapshot.hasMomentum)
        XCTAssertEqual(snapshot.recentChurn.count, 30)
        XCTAssertEqual(snapshot.recentNetGrowth.last, snapshot.netGrowth)
    }

    // The window ends today, so the total by kind counts today's lines.
    func testWindowBreakdownEndsWithToday() throws {
        let report = try reportWithOpenDay()
        let snapshot = DashboardSnapshot(
            workspace: try Workspace(root: URL(fileURLWithPath: "/tmp/fixture")),
            report: report,
            refreshState: .idle,
            now: try generatedAt(report),
            staleInterval: 3_600,
            maxWindowDays: 30,
            historyWindow: HistoryWindow(historyDays: 184)
        )

        assertTodayIsCounted(snapshot.windowBreakdown)
    }

    func testAggregateWindowBreakdownEndsWithTodayToo() throws {
        let report = try reportWithOpenDay()
        let workspace = try Workspace(root: URL(fileURLWithPath: "/tmp/fixture"))
        let portfolio = try PortfolioMomentum.build(
            workspaces: [workspace],
            reports: [workspace: report],
            historyWindow: HistoryWindow(historyDays: 184),
            windowDays: 30
        ).get()
        let snapshot = DashboardSnapshot(
            portfolio: portfolio,
            refreshState: .idle,
            now: try generatedAt(report),
            maxWindowDays: 30
        )

        assertTodayIsCounted(snapshot.windowBreakdown)
    }

    /// A steady rate, then a busy open day.
    private func reportWithOpenDay() throws -> ReportDocument {
        func days(_ closed: Int, today: Int) -> [Int] { Array(repeating: closed, count: 60) + [today] }
        return try ReportDocument.decode(data: makeReportData(
            added: days(11, today: 730),
            deleted: days(3, today: 6),
            codeAdded: days(10, today: 700),
            testAdded: days(1, today: 30),
            codeDeleted: days(2, today: 5),
            testDeleted: days(1, today: 1),
            docAdded: days(5, today: 9),
            docDeleted: days(3, today: 2)
        ))
    }

    private func assertTodayIsCounted(_ breakdown: WindowBreakdown?, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(breakdown?.code, ChurnTotals(added: 29 * 10 + 700, deleted: 29 * 2 + 5), file: file, line: line)
        XCTAssertEqual(breakdown?.tests, ChurnTotals(added: 29 * 1 + 30, deleted: 29 * 1 + 1), file: file, line: line)
        XCTAssertEqual(breakdown?.docs, ChurnTotals(added: 29 * 5 + 9, deleted: 29 * 3 + 2), file: file, line: line)
    }

    func testRefreshingAndFailedSnapshotsRetainCachedValues() throws {
        let report = try self.report(currentChurn: 60, previousChurn: 40)
        let workspace = try Workspace(root: URL(fileURLWithPath: "/tmp/fixture"))
        let now = try generatedAt(report).addingTimeInterval(300)

        let refreshing = DashboardSnapshot(
            workspace: workspace,
            report: report,
            refreshState: .refreshing,
            now: now,
            staleInterval: 3_600,
            maxWindowDays: 30,
            historyWindow: HistoryWindow(historyDays: 184)
        )
        XCTAssertTrue(refreshing.isRefreshing)
        XCTAssertEqual(refreshing.dataState, .ready)
        XCTAssertEqual(refreshing.menuValue, "2/d")
        XCTAssertEqual(refreshing.menuAccessibilityLabel, "Work Tempo, Fixture, 2 code and test lines changed per day, refreshing")

        let failed = DashboardSnapshot(
            workspace: workspace,
            report: report,
            refreshState: .failed("collector unavailable"),
            now: now,
            staleInterval: 3_600,
            maxWindowDays: 30,
            historyWindow: HistoryWindow(historyDays: 184)
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
            now: try generatedAt(report).addingTimeInterval(3_601),
            staleInterval: 3_600,
            maxWindowDays: 30,
            historyWindow: HistoryWindow(historyDays: 184)
        )

        XCTAssertEqual(snapshot.dataState, .stale)
        XCTAssertEqual(snapshot.menuValue, "2/d")
        XCTAssertEqual(snapshot.menuAccessibilityLabel, "Work Tempo, Fixture, 2 code and test lines changed per day, stale")
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
            now: generatedAt.addingTimeInterval(60),
            staleInterval: 3_600,
            maxWindowDays: 30,
            historyWindow: HistoryWindow(historyDays: 184)
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
            reports: [workspace: report],
            historyWindow: HistoryWindow(historyDays: 184),
            windowDays: 30
        ).get()

        let snapshot = DashboardSnapshot(
            portfolio: portfolio,
            refreshState: .idle,
            now: try generatedAt(report),
            maxWindowDays: 30
        )

        XCTAssertEqual(snapshot.workspaceName, "All Workspaces")
        XCTAssertEqual(snapshot.menuValue, "2/d")
        XCTAssertTrue(snapshot.hasMomentum)
        XCTAssertEqual(snapshot.dailyChurn, 2)
        XCTAssertEqual(snapshot.chartTimeline?.closedDayCount, 184)
        XCTAssertEqual(snapshot.chartTimeline?.monthlyChurn.map(\.label), [
            "2026-03", "2026-04", "2026-05", "2026-06", "2026-07", "2026-08",
        ])
        XCTAssertNil(snapshot.coverageMessage)
        XCTAssertNil(snapshot.noticeMessage)
    }

    func testZeroChurnIsAvailableMomentum() throws {
        let report = try self.report(currentChurn: 0, previousChurn: 0)
        let snapshot = DashboardSnapshot(
            workspace: try Workspace(root: URL(fileURLWithPath: "/tmp/fixture")),
            report: report,
            refreshState: .idle,
            now: try generatedAt(report),
            staleInterval: 3_600,
            maxWindowDays: 30,
            historyWindow: HistoryWindow(historyDays: 184)
        )

        XCTAssertTrue(snapshot.hasMomentum)
        XCTAssertEqual(snapshot.menuValue, "0/d")
        XCTAssertEqual(snapshot.dailyChurn, 0)
        XCTAssertEqual(snapshot.netGrowth, 0)
    }

    func testLastFetchedSourceNoticeSurvivesAggregateCoverageWarning() throws {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: makeReportData()) as? [String: Any])
        var scope = try XCTUnwrap(object["scope"] as? [String: Any])
        var repositories = try XCTUnwrap(scope["repositories"] as? [[String: Any]])
        repositories[0]["sourceRef"] = "origin/main"
        repositories[0]["sourceOid"] = "abc123"
        repositories[0]["fetchOutcome"] = "failed"
        scope["repositories"] = repositories
        object["scope"] = scope
        let report = try ReportDocument.decode(data: JSONSerialization.data(withJSONObject: object))
        let first = try Workspace(root: URL(fileURLWithPath: "/tmp/fixture"))
        let second = try Workspace(root: URL(fileURLWithPath: "/tmp/other"))
        let individual = DashboardSnapshot(
            workspace: first,
            report: report,
            refreshState: .idle,
            now: try generatedAt(report),
            staleInterval: 3_600,
            maxWindowDays: 30,
            historyWindow: HistoryWindow(historyDays: 184)
        )
        XCTAssertEqual(individual.noticeMessage, "1 repository using last-fetched origin/main")
        XCTAssertNil(individual.coverageMessage)

        let portfolio = try PortfolioMomentum.build(
            workspaces: [first, second],
            reports: [first: report],
            historyWindow: HistoryWindow(historyDays: 184),
            windowDays: 30
        ).get()
        let aggregate = DashboardSnapshot(
            portfolio: portfolio,
            refreshState: .idle,
            now: try generatedAt(report),
            maxWindowDays: 30
        )
        XCTAssertEqual(aggregate.coverageMessage, "1 of 2 workspaces contributing")
        XCTAssertEqual(aggregate.noticeMessage, "1 repository using last-fetched origin/main")
        let failed = DashboardSnapshot(
            portfolio: portfolio,
            refreshState: .failed("collector unavailable"),
            now: try generatedAt(report),
            maxWindowDays: 30
        )
        XCTAssertEqual(failed.errorMessage, "collector unavailable")
        XCTAssertEqual(failed.coverageMessage, aggregate.coverageMessage)
        XCTAssertEqual(failed.noticeMessage, aggregate.noticeMessage)
    }

    func testPartialPortfolioKeepsCoverageWithoutFallbackNotice() throws {
        let first = try Workspace(root: URL(fileURLWithPath: "/tmp/first"))
        let second = try Workspace(root: URL(fileURLWithPath: "/tmp/second"))
        let report = try self.report(currentChurn: 30, previousChurn: 0)
        let portfolio = try PortfolioMomentum.build(
            workspaces: [first, second],
            reports: [first: report],
            historyWindow: HistoryWindow(historyDays: 184),
            windowDays: 30
        ).get()

        let snapshot = DashboardSnapshot(
            portfolio: portfolio,
            refreshState: .idle,
            now: try generatedAt(report),
            maxWindowDays: 30
        )

        XCTAssertNil(snapshot.errorMessage)
        XCTAssertEqual(snapshot.coverageMessage, "1 of 2 workspaces contributing")
        XCTAssertNil(snapshot.noticeMessage)
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
        churn.replaceSubrange(1..<31, with: repeatElement(previousChurn / 30, count: 30))
        churn.replaceSubrange(31..<61, with: repeatElement(currentChurn / 30, count: 30))
        if previousChurn % 30 != 0 { churn[1] += previousChurn % 30 }
        if currentChurn % 30 != 0 { churn[31] += currentChurn % 30 }
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

    // The sparklines read today off the snapshot, so both initializers have to
    // publish it rather than leaving the timeline to be re-derived downstream.
    func testBothSnapshotsPublishTheOpenDayFromTheirTimeline() throws {
        let workspace = try Workspace(root: URL(fileURLWithPath: "/tmp/fixture"))
        let data = try makeReportData(
            dayCount: 200,
            generatedDate: "2026-08-31",
            codeAdded: Array(repeating: 3, count: 199) + [40],
            testAdded: Array(repeating: 1, count: 199) + [2],
            codeDeleted: Array(repeating: 1, count: 199) + [7],
            testDeleted: Array(repeating: 1, count: 199) + [1],
            docAdded: Array(repeating: 5, count: 199) + [500],
            docDeleted: Array(repeating: 5, count: 199) + [500]
        )
        let report = try ReportDocument.decode(data: data)
        let expected = OpenDay(label: "2026-08-31", added: 42, deleted: 8)

        let individual = DashboardSnapshot(
            workspace: workspace,
            report: report,
            refreshState: .idle,
            now: Date(timeIntervalSince1970: 0),
            staleInterval: 3_600,
            maxWindowDays: 30,
            historyWindow: HistoryWindow(historyDays: 184)
        )
        XCTAssertEqual(individual.openDay, expected)

        let portfolio = try PortfolioMomentum.build(
            workspaces: [workspace],
            reports: [workspace: report],
            historyWindow: HistoryWindow(historyDays: 184),
            windowDays: 30
        ).get()
        let aggregate = DashboardSnapshot(
            portfolio: portfolio,
            refreshState: .idle,
            now: Date(timeIntervalSince1970: 0),
            maxWindowDays: 30
        )
        XCTAssertEqual(aggregate.openDay, expected)
    }

    func testAggregateAccessibilityLabelStatesTheRateOnceWithItsUnit() throws {
        let workspace = try Workspace(root: URL(fileURLWithPath: "/tmp/fixture"))
        let report = try ReportDocument.decode(data: makeReportData(
            churn: Array(repeating: 10, count: 61)
        ))
        let portfolio = try PortfolioMomentum.build(
            workspaces: [workspace],
            reports: [workspace: report],
            historyWindow: HistoryWindow(historyDays: 184),
            windowDays: 30
        ).get()

        let snapshot = DashboardSnapshot(
            portfolio: portfolio,
            refreshState: .idle,
            now: Date(timeIntervalSince1970: 0),
            maxWindowDays: 30
        )

        XCTAssertEqual(snapshot.menuValue, "10/d")
        XCTAssertEqual(
            snapshot.menuAccessibilityLabel,
            "Work Tempo, all workspaces, 10 code and test lines changed per day"
        )
    }

}

private extension ISO8601DateFormatter {
    static var fractional: ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }
}
