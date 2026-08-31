import Foundation
import XCTest
@testable import SourceTempoCore

final class RefreshCoordinatorTests: XCTestCase {
    func testFirstRunIsUntimedAndSingleFlight() async throws {
        let coordinator = RefreshCoordinator()
        let workspace = try Workspace(root: URL(fileURLWithPath: "/tmp/fixture"))
        await coordinator.select(workspace)

        let first = await coordinator.request(
            trigger: .manual,
            reportGeneratedAt: nil,
            now: Date(timeIntervalSince1970: 10_000),
            lowPower: false
        )
        let duplicate = await coordinator.request(
            trigger: .timer,
            reportGeneratedAt: nil,
            now: Date(timeIntervalSince1970: 10_000),
            lowPower: false
        )

        XCTAssertEqual(first?.workspace, workspace)
        XCTAssertNil(first?.timeout)
        XCTAssertNil(duplicate)
    }

    func testRoutineRefreshRequiresStaleReportAndUsesTimeout() async throws {
        let coordinator = RefreshCoordinator()
        let workspace = try Workspace(root: URL(fileURLWithPath: "/tmp/fixture"))
        await coordinator.select(workspace)
        let now = Date(timeIntervalSince1970: 10_000)

        let fresh = await coordinator.request(
            trigger: .timer,
            reportGeneratedAt: now.addingTimeInterval(-3_599),
            now: now,
            lowPower: false
        )
        XCTAssertNil(fresh)

        let stale = await coordinator.request(
            trigger: .timer,
            reportGeneratedAt: now.addingTimeInterval(-3_600),
            now: now,
            lowPower: false
        )
        XCTAssertEqual(stale?.timeout, .seconds(120))
    }

    func testLowPowerSuppressesUnattendedButNotManualRefresh() async throws {
        let coordinator = RefreshCoordinator()
        let workspace = try Workspace(root: URL(fileURLWithPath: "/tmp/fixture"))
        await coordinator.select(workspace)
        let now = Date(timeIntervalSince1970: 10_000)
        let stale = now.addingTimeInterval(-7_200)

        let unattended = await coordinator.request(
            trigger: .wake,
            reportGeneratedAt: stale,
            now: now,
            lowPower: true
        )
        XCTAssertNil(unattended)
        let manual = await coordinator.request(
            trigger: .manual,
            reportGeneratedAt: stale,
            now: now,
            lowPower: true
        )
        XCTAssertEqual(manual?.timeout, .seconds(120))
    }

    func testFinishAllowsNextRequestForSelectedWorkspace() async throws {
        let coordinator = RefreshCoordinator()
        let first = try Workspace(root: URL(fileURLWithPath: "/tmp/first"))
        let second = try Workspace(root: URL(fileURLWithPath: "/tmp/second"))
        await coordinator.select(first)
        let now = Date(timeIntervalSince1970: 10_000)
        _ = await coordinator.request(trigger: .manual, reportGeneratedAt: now, now: now, lowPower: false)
        await coordinator.select(second)
        await coordinator.finish()

        let plan = await coordinator.request(
            trigger: .manual,
            reportGeneratedAt: now,
            now: now,
            lowPower: false
        )

        XCTAssertEqual(plan?.workspace, second)
    }
}
