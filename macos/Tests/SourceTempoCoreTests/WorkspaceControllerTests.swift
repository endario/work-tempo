import Foundation
import XCTest
@testable import SourceTempoCore

final class WorkspaceControllerTests: XCTestCase {
    func testAddCanonicalizesSelectsAndRejectsDuplicate() async throws {
        let fixture = try Fixture()
        let controller = WorkspaceController(store: fixture.store)
        _ = try await controller.load()

        let added = try await controller.add(root: fixture.first.root.appending(path: "."))
        XCTAssertEqual(added.workspaces, [fixture.first])
        XCTAssertEqual(added.selectedWorkspace, fixture.first)

        await XCTAssertThrowsErrorAsync(try await controller.add(root: fixture.first.root)) { error in
            XCTAssertEqual(error as? WorkspaceControllerError, .duplicateWorkspace(fixture.first.root.path))
        }

        let reloaded = try await WorkspaceController(store: fixture.store).load()
        XCTAssertEqual(reloaded.selectedWorkspace, fixture.first)
    }

    func testLoadReadsCachedReportsAndSelectionPersists() async throws {
        let fixture = try Fixture()
        let report = try ReportDocument.decode(data: makeReportData(loc: Array(repeating: 321, count: 61)))
        try makeReportData(loc: Array(repeating: 321, count: 61))
            .write(to: fixture.store.reportURL(for: fixture.second))
        try fixture.store.save(WorkspaceState(
            roots: [fixture.first.root.path, fixture.second.root.path],
            selectedRoot: fixture.first.root.path
        ))
        let controller = WorkspaceController(store: fixture.store)

        _ = try await controller.load()
        let selected = try await controller.select(fixture.second)

        XCTAssertEqual(selected.selectedWorkspace, fixture.second)
        XCTAssertEqual(selected.selectedReport?.series.loc.last, report.series.loc.last)
        XCTAssertEqual(try fixture.store.load().selectedRoot, fixture.second.root.path)
    }

    func testRemoveSelectsRemainingWorkspace() async throws {
        let fixture = try Fixture()
        let controller = WorkspaceController(store: fixture.store)
        _ = try await controller.load()
        _ = try await controller.add(root: fixture.first.root)
        _ = try await controller.add(root: fixture.second.root)

        let state = try await controller.remove(fixture.second)

        XCTAssertEqual(state.workspaces, [fixture.first])
        XCTAssertEqual(state.selectedWorkspace, fixture.first)
    }

    func testRemoveDeletesCachedReportBeforeWorkspaceCanBeReadded() async throws {
        let fixture = try Fixture()
        let reportURL = fixture.store.reportURL(for: fixture.first)
        try makeReportData(loc: Array(repeating: 777, count: 61)).write(to: reportURL)
        try fixture.store.save(WorkspaceState(
            roots: [fixture.first.root.path],
            selectedRoot: fixture.first.root.path
        ))
        let controller = WorkspaceController(store: fixture.store)
        let loaded = try await controller.load()
        XCTAssertEqual(loaded.selectedReport?.series.loc.last, 777)

        _ = try await controller.remove(fixture.first)
        let readded = try await controller.add(root: fixture.first.root)

        XCTAssertNil(readded.selectedReport)
        XCTAssertFalse(FileManager.default.fileExists(atPath: reportURL.path))
    }

    func testRefreshFailureKeepsPriorReport() async throws {
        let fixture = try Fixture()
        let existing = try ReportDocument.decode(data: makeReportData(loc: Array(repeating: 777, count: 61)))
        let controller = WorkspaceController(store: fixture.store)
        _ = try await controller.load()
        _ = try await controller.add(root: fixture.first.root)
        let ticket = await controller.beginRefresh(fixture.first)
        _ = await controller.succeedRefresh(ticket, workspace: fixture.first, report: existing)
        let retry = await controller.beginRefresh(fixture.first)

        let failed = await controller.failRefresh(retry, workspace: fixture.first, message: "offline")

        XCTAssertEqual(failed.selectedReport?.series.loc.last, 777)
        XCTAssertEqual(failed.refreshState(for: fixture.first), .failed("offline"))

        let cancelledTicket = await controller.beginRefresh(fixture.first)
        let cancelled = await controller.cancelRefresh(cancelledTicket, workspace: fixture.first)
        XCTAssertEqual(cancelled.selectedReport?.series.loc.last, 777)
        XCTAssertEqual(cancelled.refreshState(for: fixture.first), .idle)
    }

    func testLateCompletionCannotReplaceNewSelection() async throws {
        let fixture = try Fixture()
        let controller = WorkspaceController(store: fixture.store)
        _ = try await controller.load()
        _ = try await controller.add(root: fixture.first.root)
        _ = try await controller.add(root: fixture.second.root)
        _ = try await controller.select(fixture.first)
        let ticket = await controller.beginRefresh(fixture.first)
        _ = try await controller.select(fixture.second)
        let firstReport = try ReportDocument.decode(data: makeReportData(loc: Array(repeating: 999, count: 61)))

        let state = await controller.succeedRefresh(ticket, workspace: fixture.first, report: firstReport)

        XCTAssertEqual(state.selectedWorkspace, fixture.second)
        XCTAssertNil(state.selectedReport)
        XCTAssertEqual(state.report(for: fixture.first)?.series.loc.last, 999)
    }
}

private struct Fixture {
    let base: URL
    let store: WorkspaceStore
    let first: Workspace
    let second: Workspace

    init() throws {
        base = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        store = WorkspaceStore(baseDirectory: base.appending(path: "Support"))
        first = try Workspace(root: base.appending(path: "first"))
        second = try Workspace(root: base.appending(path: "second"))
        try FileManager.default.createDirectory(at: first.root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second.root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: store.reportsDirectory, withIntermediateDirectories: true)
    }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ handler: (Error) -> Void
) async {
    do {
        _ = try await expression()
        XCTFail("Expected expression to throw")
    } catch {
        handler(error)
    }
}
