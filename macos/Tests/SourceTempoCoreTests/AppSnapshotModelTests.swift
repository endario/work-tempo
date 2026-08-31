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
        XCTAssertEqual(snapshot.menuAccessibilityLabel, "SourceTempo, fixture, no report yet")
        XCTAssertEqual(snapshot.paceLabel, "Awaiting first report")
        XCTAssertTrue(snapshot.metrics.allSatisfy { $0.value == "--" })
    }

    func testCachedSnapshotExposesMetricsAndReadyPace() throws {
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
        XCTAssertEqual(snapshot.menuValue, "12K")
        XCTAssertEqual(snapshot.menuAccessibilityLabel, "SourceTempo, Fixture, 12,345 source lines")
        XCTAssertEqual(snapshot.metrics.map(\.value), ["12K", "8K", "4.3K", "900"])
        XCTAssertEqual(try XCTUnwrap(snapshot.paceShare), 2.0 / 3.0, accuracy: 0.0001)
        XCTAssertEqual(snapshot.paceLabel, "67% recent share")
        XCTAssertEqual(snapshot.paceDetail, "300 current / 150 previous")
        XCTAssertEqual(snapshot.paceAccessibilityLabel, "Recent 30-day churn 300, previous 30-day churn 150, 67 percent recent share")
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
        XCTAssertEqual(refreshing.menuValue, "220")
        XCTAssertEqual(refreshing.menuAccessibilityLabel, "SourceTempo, Fixture, 220 source lines, refreshing")

        let failed = DashboardSnapshot(
            workspace: workspace,
            report: report,
            refreshState: .failed("collector unavailable"),
            now: now
        )
        XCTAssertEqual(failed.dataState, .failedWithCache)
        XCTAssertEqual(failed.errorMessage, "collector unavailable")
        XCTAssertEqual(failed.menuValue, "220")
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
        XCTAssertEqual(snapshot.menuValue, "220")
        XCTAssertEqual(snapshot.menuAccessibilityLabel, "SourceTempo, Fixture, 220 source lines, stale")
    }

    func testPaceEdgeStatesUseLiteralNonProductivityCopy() throws {
        let workspace = try Workspace(root: URL(fileURLWithPath: "/tmp/fixture"))
        let cases: [(ReportDocument, String, String)] = [
            (try report(currentChurn: 20, previousChurn: 0), "New activity", "20 current / 0 previous"),
            (try report(currentChurn: 0, previousChurn: 0), "No recent activity", "0 current / 0 previous"),
            (try report(currentChurn: 20, previousChurn: 10, young: true), "Building history", "60 closed days required"),
        ]

        for (report, label, detail) in cases {
            let snapshot = DashboardSnapshot(
                workspace: workspace,
                report: report,
                refreshState: .idle,
                now: try generatedAt(report)
            )
            XCTAssertEqual(snapshot.paceLabel, label)
            XCTAssertEqual(snapshot.paceDetail, detail)
        }
    }

    private func report(
        currentChurn: Int,
        previousChurn: Int,
        loc: Int = 220,
        code: Int = 140,
        test: Int = 80,
        docs: Int = 50,
        young: Bool = false
    ) throws -> ReportDocument {
        var churn = Array(repeating: 0, count: 61)
        churn.replaceSubrange(0..<30, with: repeatElement(previousChurn / 30, count: 30))
        churn.replaceSubrange(30..<60, with: repeatElement(currentChurn / 30, count: 30))
        if previousChurn % 30 != 0 { churn[0] += previousChurn % 30 }
        if currentChurn % 30 != 0 { churn[30] += currentChurn % 30 }
        var locValues = Array(repeating: loc, count: 61)
        if young { locValues[0] = 0 }
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
