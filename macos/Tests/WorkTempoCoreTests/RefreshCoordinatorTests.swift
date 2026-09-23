import Foundation
import XCTest
@testable import WorkTempoCore

final class RefreshCoordinatorTests: XCTestCase {
    func testManualAggregateQueuesEveryWorkspaceSequentially() async throws {
        let coordinator = RefreshCoordinator(staleInterval: 3_600, requiredDayCount: 185)
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

        var coordinator = RefreshCoordinator(staleInterval: 3_600, requiredDayCount: 185)
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

        coordinator = RefreshCoordinator(staleInterval: 3_600, requiredDayCount: 185)
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

        coordinator = RefreshCoordinator(staleInterval: 3_600, requiredDayCount: 185)
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
        let coordinator = RefreshCoordinator(staleInterval: 3_600, requiredDayCount: 185)
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
        let coordinator = RefreshCoordinator(staleInterval: 3_600, requiredDayCount: 185)
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
        var coordinator = RefreshCoordinator(staleInterval: 3_600, requiredDayCount: 185)

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

        coordinator = RefreshCoordinator(staleInterval: 3_600, requiredDayCount: 185)
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

    func testShortHistoryBranchFloorsAtOneHourRegardlessOfLowerCadence() async throws {
        let now = Date(timeIntervalSince1970: 100_000)
        let workspace = try workspace("young")
        // A 15-minute cadence, with the workspace last collected 20 minutes
        // ago: naive `>= staleInterval` (900s) would re-select it. The
        // floor (max(900, 3_600) = 3_600) must not.
        let coordinator = RefreshCoordinator(staleInterval: 900, requiredDayCount: 185)

        let tooSoon = await coordinator.request(
            trigger: .timer,
            scope: .all,
            targets: [RefreshTarget(
                workspace: workspace,
                generatedAt: now.addingTimeInterval(-1_200),
                dayCount: 60
            )],
            now: now,
            lowPower: false
        )
        XCTAssertNil(tooSoon, "20 minutes since the last short collection is under the 1-hour floor")

        let pastFloor = await RefreshCoordinator(staleInterval: 900, requiredDayCount: 185).request(
            trigger: .timer,
            scope: .all,
            targets: [RefreshTarget(
                workspace: workspace,
                generatedAt: now.addingTimeInterval(-3_601),
                dayCount: 60
            )],
            now: now,
            lowPower: false
        )
        XCTAssertEqual(pastFloor?.map(\.workspace), [workspace], "past the 1-hour floor, the short branch still fires")
        XCTAssertNil(pastFloor?.first?.timeout, "the short branch stays untimed")
    }

    func testShortHistoryBranchUsesTheHigherCadenceWhenAboveTheFloor() async throws {
        let now = Date(timeIntervalSince1970: 100_000)
        let workspace = try workspace("young")
        // A 4-hour cadence: the floor formula is max(staleInterval, 3_600),
        // so at a cadence above the floor, the configured cadence wins.
        let coordinator = RefreshCoordinator(staleInterval: 14_400, requiredDayCount: 185)

        let withinCadence = await coordinator.request(
            trigger: .timer,
            scope: .all,
            targets: [RefreshTarget(
                workspace: workspace,
                generatedAt: now.addingTimeInterval(-7_200),
                dayCount: 60
            )],
            now: now,
            lowPower: false
        )
        XCTAssertNil(withinCadence, "2 hours since the last collection is under a 4-hour cadence")

        let pastCadence = await RefreshCoordinator(staleInterval: 14_400, requiredDayCount: 185).request(
            trigger: .timer,
            scope: .all,
            targets: [RefreshTarget(
                workspace: workspace,
                generatedAt: now.addingTimeInterval(-14_401),
                dayCount: 60
            )],
            now: now,
            lowPower: false
        )
        XCTAssertEqual(pastCadence?.map(\.workspace), [workspace], "past a 4-hour cadence, the short branch fires")
    }

    private func workspace(_ name: String) throws -> Workspace {
        try Workspace(root: URL(fileURLWithPath: "/tmp/\(name)"))
    }
}
