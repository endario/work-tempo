import Foundation
import XCTest
@testable import SourceTempoCore

final class RefreshCoordinatorTests: XCTestCase {
    func testManualAggregateQueuesEveryWorkspaceSequentially() async throws {
        let coordinator = RefreshCoordinator()
        let first = try workspace("first")
        let second = try workspace("second")
        let now = Date(timeIntervalSince1970: 10_000)

        let plans = await coordinator.request(
            trigger: .manual,
            scope: .all,
            targets: [
                RefreshTarget(workspace: first, generatedAt: nil, dayCount: 0),
                RefreshTarget(workspace: second, generatedAt: now, dayCount: 120),
            ],
            now: now,
            lowPower: false
        )

        XCTAssertEqual(plans?.map(\.workspace), [first, second])
        XCTAssertEqual(plans?.map(\.timeout), [nil, .seconds(120)])
        let duplicate = await coordinator.request(
            trigger: .manual,
            scope: .all,
            targets: [],
            now: now,
            lowPower: false
        )
        XCTAssertNil(duplicate)
    }

    func testUnattendedAggregateSelectsOneMissingShortThenOldestStale() async throws {
        let now = Date(timeIntervalSince1970: 20_000)
        let first = try workspace("first")
        let second = try workspace("second")
        let third = try workspace("third")

        var coordinator = RefreshCoordinator()
        var plans = await coordinator.request(
            trigger: .launch,
            scope: .all,
            targets: [
                RefreshTarget(workspace: first, generatedAt: now.addingTimeInterval(-9_000), dayCount: 120),
                RefreshTarget(workspace: second, generatedAt: nil, dayCount: 0),
                RefreshTarget(workspace: third, generatedAt: now.addingTimeInterval(-10_000), dayCount: 61),
            ],
            now: now,
            lowPower: false
        )
        XCTAssertEqual(plans?.map(\.workspace), [second])
        XCTAssertNil(plans?.first?.timeout)

        coordinator = RefreshCoordinator()
        plans = await coordinator.request(
            trigger: .timer,
            scope: .all,
            targets: [
                RefreshTarget(workspace: first, generatedAt: now.addingTimeInterval(-9_000), dayCount: 120),
                RefreshTarget(workspace: third, generatedAt: now.addingTimeInterval(-10_000), dayCount: 61),
            ],
            now: now,
            lowPower: false
        )
        XCTAssertEqual(plans?.map(\.workspace), [third])
        XCTAssertNil(plans?.first?.timeout)

        coordinator = RefreshCoordinator()
        plans = await coordinator.request(
            trigger: .wake,
            scope: .all,
            targets: [
                RefreshTarget(workspace: first, generatedAt: now.addingTimeInterval(-9_000), dayCount: 120),
                RefreshTarget(workspace: second, generatedAt: now.addingTimeInterval(-8_000), dayCount: 120),
            ],
            now: now,
            lowPower: false
        )
        XCTAssertEqual(plans?.map(\.workspace), [first])
        XCTAssertEqual(plans?.first?.timeout, .seconds(120))
    }

    func testIndividualScopeAndLowPowerRemainBounded() async throws {
        let coordinator = RefreshCoordinator()
        let first = try workspace("first")
        let second = try workspace("second")
        let now = Date(timeIntervalSince1970: 20_000)
        let targets = [
            RefreshTarget(workspace: first, generatedAt: nil, dayCount: 0),
            RefreshTarget(workspace: second, generatedAt: nil, dayCount: 0),
        ]

        let suppressed = await coordinator.request(
            trigger: .wake,
            scope: .workspace(second),
            targets: targets,
            now: now,
            lowPower: true
        )
        XCTAssertNil(suppressed)

        let manual = await coordinator.request(
            trigger: .manual,
            scope: .workspace(second),
            targets: targets,
            now: now,
            lowPower: true
        )
        XCTAssertEqual(manual?.map(\.workspace), [second])
    }

    func testFreshUnattendedTargetsDoNotStartFlight() async throws {
        let coordinator = RefreshCoordinator()
        let now = Date(timeIntervalSince1970: 20_000)
        let target = RefreshTarget(
            workspace: try workspace("fresh"),
            generatedAt: now.addingTimeInterval(-3_599),
            dayCount: 120
        )

        let unattended = await coordinator.request(
            trigger: .timer,
            scope: .all,
            targets: [target],
            now: now,
            lowPower: false
        )
        XCTAssertNil(unattended)
        let manual = await coordinator.request(
            trigger: .manual,
            scope: .all,
            targets: [target],
            now: now,
            lowPower: false
        )
        XCTAssertNotNil(manual)
    }

    private func workspace(_ name: String) throws -> Workspace {
        try Workspace(root: URL(fileURLWithPath: "/tmp/\(name)"))
    }
}
