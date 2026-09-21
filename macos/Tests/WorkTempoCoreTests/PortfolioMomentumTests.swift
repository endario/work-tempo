import Foundation
import XCTest
@testable import WorkTempoCore

final class PortfolioMomentumTests: XCTestCase {
    func testUsesOneCohortAndWatermarkForTotalsRateAndCharts() throws {
        let first = try workspace("first")
        let second = try workspace("second")
        let reports = [
            first: try report(
                root: first.root.path,
                loc: 200,
                churn: 2,
                codeAdded: 1,
                testAdded: 2,
                codeDeleted: 3,
                testDeleted: 4,
                docAdded: 5,
                docDeleted: 6
            ),
            second: try report(
                root: second.root.path,
                loc: 300,
                churn: 3,
                codeAdded: 10,
                testAdded: 20,
                codeDeleted: 30,
                testDeleted: 40,
                docAdded: 50,
                docDeleted: 60
            ),
        ]

        let portfolio = try PortfolioMomentum.build(workspaces: [first, second], reports: reports).get()

        XCTAssertEqual(portfolio.contributorCount, 2)
        XCTAssertEqual(portfolio.trackedCount, 2)
        XCTAssertEqual(portfolio.totals.source, 500)
        XCTAssertEqual(portfolio.watermark, "2026-08-30")
        let summary = try XCTUnwrap(portfolio.momentum).summary
        XCTAssertEqual(summary.dailyChurn, 5, accuracy: 0.000_001)
        XCTAssertEqual(summary.currentChurn, 150)
        XCTAssertEqual(portfolio.chart?.closedDayCount, 184)
        XCTAssertEqual(portfolio.chart?.labels.last, "2026-08-31")
        XCTAssertEqual(portfolio.chart?.currentProgress, 0.5)
        XCTAssertEqual(portfolio.chart?.codeLoc.last, 460)
        XCTAssertEqual(portfolio.chart?.testLoc.last, 40)
        XCTAssertEqual(portfolio.chart?.codeAdded.last, 11)
        XCTAssertEqual(portfolio.chart?.testAdded.last, 22)
        XCTAssertEqual(portfolio.chart?.codeDeleted.last, 33)
        XCTAssertEqual(portfolio.chart?.testDeleted.last, 44)
        XCTAssertEqual(portfolio.chart?.docAdded.last, 55)
        XCTAssertEqual(portfolio.chart?.docDeleted.last, 66)
    }

    func testMissingReportProducesOnePartialCohort() throws {
        let first = try workspace("first")
        let second = try workspace("second")
        let portfolio = try PortfolioMomentum.build(
            workspaces: [first, second],
            reports: [first: try report(root: first.root.path)]
        ).get()

        XCTAssertEqual(portfolio.contributorCount, 1)
        XCTAssertEqual(portfolio.totals.source, 200)
        XCTAssertEqual(portfolio.warning, "1 of 2 workspaces contributing")
        XCTAssertEqual(portfolio.momentum?.summary.dailyChurn, 2)
    }

    func testRefusesRepositoryOverlapAndMixedTimezones() throws {
        let first = try workspace("first")
        let second = try workspace("second")
        let shared = "/tmp/shared-repository"
        let overlap = PortfolioMomentum.build(workspaces: [first, second], reports: [
            first: try report(root: first.root.path, repositories: [first.root.path, shared]),
            second: try report(root: second.root.path, repositories: [second.root.path, shared]),
        ])
        XCTAssertEqual(
            failure(overlap),
            .overlappingRepository(
                path: shared,
                first: first.root.path,
                second: second.root.path
            )
        )

        let mixed = PortfolioMomentum.build(workspaces: [first, second], reports: [
            first: try report(root: first.root.path, timezone: "+08 (+08:00)"),
            second: try report(root: second.root.path, timezone: "UTC (+00:00)"),
        ])
        XCTAssertEqual(failure(mixed), .mixedTimezones(["+08 (+08:00)", "UTC (+00:00)"]))
    }

    func testRefusesRepositoryOverlapForSameBasenameWorkspaces() throws {
        let first = try Workspace(root: URL(fileURLWithPath: "/tmp/work/api"))
        let second = try Workspace(root: URL(fileURLWithPath: "/tmp/oss/api"))
        let shared = "/tmp/shared-repository"

        let result = PortfolioMomentum.build(workspaces: [first, second], reports: [
            first: try report(root: first.root.path, repositories: [first.root.path, shared]),
            second: try report(root: second.root.path, repositories: [second.root.path, shared]),
        ])

        XCTAssertEqual(
            failure(result),
            .overlappingRepository(
                path: shared,
                first: first.root.path,
                second: second.root.path
            )
        )
    }

    func testShortHistoryKeepsMetricsAndRendersCommonChartInterval() throws {
        let first = try workspace("first")
        let second = try workspace("second")
        let portfolio = try PortfolioMomentum.build(workspaces: [first, second], reports: [
            first: try report(root: first.root.path, days: 185),
            second: try report(root: second.root.path, days: 61),
        ]).get()

        XCTAssertEqual(portfolio.momentum?.summary.dailyChurn, 4)
        XCTAssertEqual(portfolio.chart?.closedDayCount, 60)
        XCTAssertEqual(portfolio.historyState, .extending(current: 60, required: 184))
    }

    private func workspace(_ name: String) throws -> Workspace {
        try Workspace(root: URL(fileURLWithPath: "/tmp/\(name)"))
    }

    private func report(
        root: String,
        days: Int = 185,
        loc: Int = 200,
        churn: Int = 2,
        codeAdded: Int? = nil,
        testAdded: Int = 0,
        codeDeleted: Int = 0,
        testDeleted: Int = 0,
        docAdded: Int = 0,
        docDeleted: Int = 0,
        repositories: [String]? = nil,
        timezone: String = "+08 (+08:00)"
    ) throws -> ReportDocument {
        try ReportDocument.decode(data: makeReportData(
            dayCount: days,
            loc: Array(repeating: loc, count: days),
            code: Array(repeating: loc - 20, count: days),
            test: Array(repeating: 20, count: days),
            churn: Array(repeating: churn, count: days),
            added: Array(repeating: churn, count: days),
            deleted: Array(repeating: 0, count: days),
            codeAdded: Array(repeating: codeAdded ?? churn, count: days),
            testAdded: Array(repeating: testAdded, count: days),
            codeDeleted: Array(repeating: codeDeleted, count: days),
            testDeleted: Array(repeating: testDeleted, count: days),
            docAdded: Array(repeating: docAdded, count: days),
            docDeleted: Array(repeating: docDeleted, count: days),
            repositoryPaths: repositories ?? [root],
            timezone: timezone
        ))
    }

    private func failure(
        _ result: Result<PortfolioMomentum, PortfolioError>
    ) -> PortfolioError? {
        guard case let .failure(error) = result else { return nil }
        return error
    }

    func testMonthlyChurnGroupsCalendarMonthsAndPositionsOpenMonth() throws {
        let timeline = ChartTimeline(
            labels: ["2026-07-30", "2026-07-31", "2026-08-01", "2026-08-02"],
            closedDayCount: 3,
            currentProgress: 0.5,
            codeLoc: [1, 1, 1, 1],
            testLoc: [1, 1, 1, 1],
            docLoc: [0, 0, 0, 0],
            codeAdded: [1, 2, 3, 4],
            testAdded: [2, 3, 4, 5],
            codeDeleted: [3, 4, 5, 6],
            testDeleted: [4, 5, 6, 7],
            docAdded: [5, 6, 7, 8],
            docDeleted: [6, 7, 8, 9]
        )

        let months = timeline.monthlyChurn

        XCTAssertEqual(months.map(\.label), ["2026-07", "2026-08"])
        XCTAssertEqual(months[0].codeAdded, 3)
        XCTAssertEqual(months[0].docAdded, 11)
        XCTAssertEqual(months[0].docDeleted, 13)
        XCTAssertEqual(months[1].testDeleted, 13)
        XCTAssertNil(months[0].currentProgress)
        XCTAssertEqual(try XCTUnwrap(months[1].currentProgress), 1.5 / 31, accuracy: 0.000_001)
    }

    // The open day is drawn short of its slot, so an x coordinate that rounds to
    // the previous whole index must still resolve to the open day.
    func testNearestPointIndexPicksTheOpenDayDrawnShortOfItsSlot() throws {
        let timeline = ChartTimeline(
            labels: ["2026-08-01", "2026-08-02", "2026-08-03"],
            closedDayCount: 2,
            currentProgress: 0.25,
            codeLoc: [1, 1, 1],
            testLoc: [1, 1, 1],
            docLoc: [1, 1, 1],
            codeAdded: [1, 1, 1],
            testAdded: [1, 1, 1],
            codeDeleted: [1, 1, 1],
            testDeleted: [1, 1, 1],
            docAdded: [1, 1, 1],
            docDeleted: [1, 1, 1]
        )

        XCTAssertEqual(timeline.pointPosition(at: 2), 1.25, accuracy: 0.000_001)
        XCTAssertEqual(timeline.nearestPointIndex(toX: 1.25), 2)
        XCTAssertEqual(timeline.nearestPointIndex(toX: 1.2), 2)
        XCTAssertEqual(timeline.nearestPointIndex(toX: 0.9), 1)
    }

    func testOpenDayReportsSourceChurnOnlyAndIsAbsentWithoutAnOpenLabel() throws {
        func timeline(progress: Double?) -> ChartTimeline {
            ChartTimeline(
                labels: ["2026-08-01", "2026-08-02"],
                closedDayCount: 1,
                currentProgress: progress,
                codeLoc: [1, 1],
                testLoc: [1, 1],
                docLoc: [1, 1],
                codeAdded: [1, 40],
                testAdded: [1, 2],
                codeDeleted: [1, 7],
                testDeleted: [1, 1],
                docAdded: [1, 500],
                docDeleted: [1, 500]
            )
        }

        let open = try XCTUnwrap(timeline(progress: 0.5).openDay)
        XCTAssertEqual(open.label, "2026-08-02")
        XCTAssertEqual(open.added, 42)
        XCTAssertEqual(open.deleted, 8)
        XCTAssertEqual(open.churn, 50)
        XCTAssertEqual(open.net, 34)
        XCTAssertNil(timeline(progress: nil).openDay)
    }

    func testAggregateRateStartsAtTheCohortsFirstTrackedDay() throws {
        let workspace = try Workspace(root: URL(fileURLWithPath: "/tmp/young"))
        let idle = Array(repeating: 0, count: 195)
        let report = try ReportDocument.decode(data: makeReportData(
            dayCount: 200,
            generatedDate: "2026-08-31",
            loc: idle + [100, 100, 100, 100] + [100],
            churn: idle + [20, 20, 20, 20] + [99_999],
            added: idle + [20, 20, 20, 20] + [99_999],
            deleted: idle + [0, 0, 0, 0] + [99_999]
        ))

        let portfolio = try PortfolioMomentum.build(
            workspaces: [workspace],
            reports: [workspace: report]
        ).get()
        let summary = try XCTUnwrap(portfolio.momentum?.summary)

        XCTAssertEqual(summary.windowDays, 4)
        XCTAssertEqual(summary.dailyChurn, 20, accuracy: 0.000_001)
    }

}
