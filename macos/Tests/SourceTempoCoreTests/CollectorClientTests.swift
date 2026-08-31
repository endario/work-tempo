import Darwin
import Foundation
import XCTest
@testable import SourceTempoCore

final class CollectorClientTests: XCTestCase {
    func testCollectsReportWithExactArguments() async throws {
        let fixture = try makeFixtureRepository()
        let reportFixture = fixture.base.appending(path: "fixture.json")
        try makeReportData().write(to: reportFixture)
        let argumentLog = fixture.base.appending(path: "arguments.txt")
        let executable = try makeExecutable(
            in: fixture.base,
            body: """
            printf '%s\\n' "$@" > "$ARGUMENT_LOG"
            last=""
            for argument in "$@"; do last="$argument"; done
            cp "$REPORT_FIXTURE" "$last"
            """
        )
        let reportURL = fixture.base.appending(path: "output/report.json")
        let client = CollectorClient(
            executable: executable,
            environment: [
                "ARGUMENT_LOG": argumentLog.path,
                "REPORT_FIXTURE": reportFixture.path,
            ]
        )
        let workspace = try Workspace(root: fixture.root)

        let report = try await client.collect(CollectorRequest(
            workspace: workspace,
            reportURL: reportURL,
            timeout: .seconds(5)
        ))

        XCTAssertEqual(report.workspace.title, "Fixture")
        let arguments = try String(contentsOf: argumentLog, encoding: .utf8)
            .split(separator: "\n").map(String.init)
        XCTAssertEqual(arguments, [
            "--root", workspace.root.path,
            "--period", "day",
            "--days", "61",
            "--workers", "2",
            "--no-html",
            "--json", reportURL.path,
        ])
    }

    func testPreflightDistinguishesMissingAndNonRootPaths() async throws {
        let base = try makeTemporaryDirectory()
        let executable = try makeExecutable(in: base, body: "exit 99")
        let client = CollectorClient(executable: executable)
        let missing = try Workspace(root: base.appending(path: "missing"))

        await XCTAssertThrowsErrorAsync(try await client.collect(CollectorRequest(
            workspace: missing,
            reportURL: base.appending(path: "missing.json"),
            timeout: .seconds(1)
        ))) { error in
            XCTAssertEqual(error as? CollectorError, .missingWorkspace(missing.root.path))
        }

        let fixture = try makeFixtureRepository()
        let child = fixture.root.appending(path: "child")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        let nested = try Workspace(root: child)
        await XCTAssertThrowsErrorAsync(try await client.collect(CollectorRequest(
            workspace: nested,
            reportURL: base.appending(path: "nested.json"),
            timeout: .seconds(1)
        ))) { error in
            XCTAssertEqual(error as? CollectorError, .notRepositoryRoot(nested.root.path))
        }
    }

    func testReportsOnlyFinalBoundedDiagnostic() async throws {
        let fixture = try makeFixtureRepository()
        let executable = try makeExecutable(
            in: fixture.base,
            body: """
            echo 'first diagnostic' >&2
            echo 'final diagnostic' >&2
            exit 7
            """
        )
        let client = CollectorClient(executable: executable)
        let workspace = try Workspace(root: fixture.root)

        await XCTAssertThrowsErrorAsync(try await client.collect(CollectorRequest(
            workspace: workspace,
            reportURL: fixture.base.appending(path: "report.json"),
            timeout: .seconds(5)
        ))) { error in
            XCTAssertEqual(error as? CollectorError, .collectorFailed("final diagnostic"))
        }
    }

    func testTimeoutTerminatesCollectorProcessGroup() async throws {
        let fixture = try makeFixtureRepository()
        let childPIDFile = fixture.base.appending(path: "child.pid")
        let executable = try makeExecutable(
            in: fixture.base,
            body: """
            sleep 30 &
            child=$!
            echo "$child" > "$CHILD_PID_FILE"
            wait "$child"
            """
        )
        let client = CollectorClient(
            executable: executable,
            environment: ["CHILD_PID_FILE": childPIDFile.path]
        )
        let workspace = try Workspace(root: fixture.root)

        await XCTAssertThrowsErrorAsync(try await client.collect(CollectorRequest(
            workspace: workspace,
            reportURL: fixture.base.appending(path: "report.json"),
            timeout: .seconds(1)
        ))) { error in
            XCTAssertEqual(error as? CollectorError, .timedOut)
        }

        let childPID = try Int32(String(contentsOf: childPIDFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines))!
        for _ in 0..<20 where kill(childPID, 0) == 0 {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertNotEqual(kill(childPID, 0), 0, "Collector child process remained alive")
    }

    private func makeFixtureRepository() throws -> (base: URL, root: URL) {
        let base = try makeTemporaryDirectory()
        let root = base.appending(path: "repo")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["init", "--quiet", root.path]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        return (base, root)
    }

    private func makeExecutable(in directory: URL, body: String) throws -> URL {
        let url = directory.appending(path: "collector.sh")
        try Data("#!/bin/sh\nset -eu\n\(body)\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
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
