import Foundation
import XCTest
@testable import SourceTempoCore

final class PortfolioMomentumTests: XCTestCase {
    func testUsesOneCohortAndWatermarkForTotalsRatePaceAndCharts() throws {
        let first = try workspace("first")
        let second = try workspace("second")
        let reports = [
            first: try report(root: first.root.path, loc: 200, churn: 2, language: "Swift"),
            second: try report(root: second.root.path, loc: 300, churn: 3, language: "Kotlin"),
        ]

        let portfolio = try PortfolioMomentum.build(workspaces: [first, second], reports: reports).get()

        XCTAssertEqual(portfolio.contributorCount, 2)
        XCTAssertEqual(portfolio.trackedCount, 2)
        XCTAssertEqual(portfolio.totals.source, 500)
        XCTAssertEqual(portfolio.watermark, "2026-08-30")
        let summary = try XCTUnwrap(portfolio.momentum).summary
        XCTAssertEqual(summary.dailyChurn, 5, accuracy: 0.000_001)
        XCTAssertEqual(summary.currentChurn, 150)
        XCTAssertEqual(portfolio.chart?.closedDayCount, 90)
        XCTAssertEqual(portfolio.chart?.labels.last, "2026-08-31")
        XCTAssertEqual(portfolio.chart?.currentProgress, 0.5)
        XCTAssertEqual(Set(portfolio.chart?.languages.map(\.language) ?? []), ["Swift", "Kotlin"])
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
            .overlappingRepository(path: shared, first: "first", second: "second")
        )

        let mixed = PortfolioMomentum.build(workspaces: [first, second], reports: [
            first: try report(root: first.root.path, timezone: "+08 (+08:00)"),
            second: try report(root: second.root.path, timezone: "UTC (+00:00)"),
        ])
        XCTAssertEqual(failure(mixed), .mixedTimezones(["+08 (+08:00)", "UTC (+00:00)"]))
    }

    func testShortHistoryKeepsMetricsButWithholdsBothCharts() throws {
        let first = try workspace("first")
        let second = try workspace("second")
        let portfolio = try PortfolioMomentum.build(workspaces: [first, second], reports: [
            first: try report(root: first.root.path, days: 120),
            second: try report(root: second.root.path, days: 61),
        ]).get()

        XCTAssertEqual(portfolio.momentum?.summary.dailyChurn, 4)
        XCTAssertNil(portfolio.chart)
        XCTAssertEqual(portfolio.historyState, .extending(current: 60, required: 90))
    }

    private func workspace(_ name: String) throws -> Workspace {
        try Workspace(root: URL(fileURLWithPath: "/tmp/\(name)"))
    }

    private func report(
        root: String,
        days: Int = 120,
        loc: Int = 200,
        churn: Int = 2,
        language: String = "Swift",
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
            repositoryPaths: repositories ?? [root],
            timezone: timezone,
            languages: [language: Array(repeating: loc, count: days)]
        ))
    }

    private func failure(
        _ result: Result<PortfolioMomentum, PortfolioError>
    ) -> PortfolioError? {
        guard case let .failure(error) = result else { return nil }
        return error
    }
}
