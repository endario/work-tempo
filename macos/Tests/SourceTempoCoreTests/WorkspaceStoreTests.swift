import Foundation
import XCTest
@testable import SourceTempoCore

final class WorkspaceStoreTests: XCTestCase {
    func testWorkspaceCanonicalizesRootAndUsesDirectoryName() throws {
        let temporary = try makeTemporaryDirectory()
        let root = temporary.appending(path: "projects/../projects/reborn")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let workspace = try Workspace(root: temporary.appending(path: "projects/../projects/reborn"))

        XCTAssertEqual(workspace.root.path, root.standardizedFileURL.resolvingSymlinksInPath().path)
        XCTAssertEqual(workspace.displayName, "reborn")
    }

    func testStateRoundTripsAndReportPathIsDeterministic() throws {
        let base = try makeTemporaryDirectory()
        let root = base.appending(path: "fixture")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let workspace = try Workspace(root: root)
        let store = WorkspaceStore(baseDirectory: base.appending(path: "state"))
        let state = WorkspaceState(
            roots: [workspace.root.path],
            selectedRoot: workspace.root.path,
            selectedScope: workspace.root.path
        )

        try store.save(state)
        let loaded = try store.load()

        XCTAssertEqual(loaded, state)
        XCTAssertEqual(store.reportURL(for: workspace), store.reportURL(for: workspace))
        XCTAssertEqual(store.reportURL(for: workspace).pathExtension, "json")
        XCTAssertEqual(store.reportURL(for: workspace).deletingLastPathComponent().lastPathComponent, "Reports")
    }

    func testSaveReplacesExistingStateWithoutLeavingTemporaryFiles() throws {
        let base = try makeTemporaryDirectory()
        let store = WorkspaceStore(baseDirectory: base)
        try store.save(WorkspaceState(roots: ["/first"], selectedRoot: "/first", selectedScope: "/first"))
        let replacement = WorkspaceState(roots: ["/second"], selectedRoot: nil, selectedScope: "all")

        try store.save(replacement)

        XCTAssertEqual(try store.load(), replacement)
        let names = try FileManager.default.contentsOfDirectory(atPath: base.path)
        XCTAssertEqual(names.filter { $0.contains(".tmp") }, [])
    }

    func testRejectsUnsupportedWorkspaceStateSchema() throws {
        let base = try makeTemporaryDirectory()
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let store = WorkspaceStore(baseDirectory: base)
        let invalid = Data(#"{"schemaVersion":2,"roots":[],"selectedRoot":null}"#.utf8)
        try invalid.write(to: store.stateURL)

        XCTAssertThrowsError(try store.load()) { error in
            XCTAssertEqual(error as? WorkspaceStoreError, .unsupportedSchema(2))
        }
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}
