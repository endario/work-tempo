import Foundation
import XCTest
@testable import WorkTempoCore

final class RefreshCoordinatorTests: XCTestCase {
    func testManualAggregateQueuesEveryWorkspaceSequentially() async throws {
        let coordinator = RefreshCoordinator()
        let first = try workspace("first")
        let second = try workspace("second")
        let now = Date(timeIntervalSince1970: 10_000)

        let targets = [
            RefreshTarget(workspace: first, generatedAt: nil, dayCount: 0),
            RefreshTarget(workspace: second, generatedAt: now, dayCount: 185),
        ]
        let plans = await coordinator.request(
            trigger: .manual,
            scope: .all,
            targets: targets,
            now: now,
            lowPower: false
        )

        XCTAssertEqual(plans?.map(\.workspace), [first, second])
        XCTAssertEqual(plans?.map(\.timeout), [nil, .seconds(120)])
        let duplicate = await coordinator.request(
            trigger: .manual,
            scope: .all,
            targets: targets,
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
                RefreshTarget(workspace: first, generatedAt: now.addingTimeInterval(-9_000), dayCount: 185),
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
                RefreshTarget(workspace: first, generatedAt: now.addingTimeInterval(-9_000), dayCount: 185),
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
                RefreshTarget(workspace: first, generatedAt: now.addingTimeInterval(-9_000), dayCount: 185),
                RefreshTarget(workspace: second, generatedAt: now.addingTimeInterval(-8_000), dayCount: 185),
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
            dayCount: 185
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

    func testFailedTargetDoesNotStarveHealthyUnattendedWork() async throws {
        let now = Date(timeIntervalSince1970: 20_000)
        let failed = try workspace("failed")
        let stale = try workspace("stale")
        var coordinator = RefreshCoordinator()

        var plans = await coordinator.request(
            trigger: .timer,
            scope: .all,
            targets: [
                RefreshTarget(
                    workspace: failed,
                    generatedAt: nil,
                    dayCount: 0,
                    lastAttemptFailed: true
                ),
                RefreshTarget(
                    workspace: stale,
                    generatedAt: now.addingTimeInterval(-7_200),
                    dayCount: 185
                ),
            ],
            now: now,
            lowPower: false
        )
        XCTAssertEqual(plans?.map(\.workspace), [stale])

        coordinator = RefreshCoordinator()
        plans = await coordinator.request(
            trigger: .timer,
            scope: .all,
            targets: [RefreshTarget(
                workspace: failed,
                generatedAt: nil,
                dayCount: 0,
                lastAttemptFailed: true
            )],
            now: now,
            lowPower: false
        )
        XCTAssertEqual(plans?.map(\.workspace), [failed])
        XCTAssertNil(plans?.first?.timeout)
    }

    private func workspace(_ name: String) throws -> Workspace {
        try Workspace(root: URL(fileURLWithPath: "/tmp/\(name)"))
    }
}
