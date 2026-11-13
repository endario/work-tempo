import Darwin
import Foundation
import XCTest
@testable import WorkTempoCore

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
            ],
            logDirectory: fixture.base.appending(path: "logs")
        )
        let workspace = try Workspace(root: fixture.root)

        let report = try await client.collect(CollectorRequest(
            workspace: workspace,
            reportURL: reportURL,
            timeout: .seconds(5),
            collectorDays: 185
        ))

        XCTAssertEqual(report.workspace.title, "Fixture")
        let arguments = try String(contentsOf: argumentLog, encoding: .utf8)
            .split(separator: "\n").map(String.init)
        XCTAssertEqual(arguments, [
            "--root", workspace.root.path,
            "--period", "day",
            "--days", "185",
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
            timeout: .seconds(1),
            collectorDays: 185
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
            timeout: .seconds(1),
            collectorDays: 185
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
        let client = CollectorClient(
            executable: executable,
            logDirectory: fixture.base.appending(path: "logs")
        )
        let workspace = try Workspace(root: fixture.root)

        await XCTAssertThrowsErrorAsync(try await client.collect(CollectorRequest(
            workspace: workspace,
            reportURL: fixture.base.appending(path: "report.json"),
            timeout: .seconds(5),
            collectorDays: 185
        ))) { error in
            XCTAssertEqual(error as? CollectorError, .collectorFailed("final diagnostic"))
        }
    }

    func testRunLogRecordsCollectorOutputAndResult() async throws {
        let fixture = try makeFixtureRepository()
        let reportFixture = fixture.base.appending(path: "fixture.json")
        try makeReportData().write(to: reportFixture)
        let logDirectory = fixture.base.appending(path: "logs")
        let executable = try makeExecutable(
            in: fixture.base,
            body: """
            echo 'phase marker line'
            last=""
            for argument in "$@"; do last="$argument"; done
            cp "$REPORT_FIXTURE" "$last"
            """
        )
        let client = CollectorClient(
            executable: executable,
            environment: ["REPORT_FIXTURE": reportFixture.path],
            logDirectory: logDirectory
        )
        let workspace = try Workspace(root: fixture.root)

        _ = try await client.collect(CollectorRequest(
            workspace: workspace,
            reportURL: fixture.base.appending(path: "report.json"),
            timeout: .seconds(5),
            collectorDays: 185
        ))

        let log = try String(contentsOf: client.runLogURL(for: workspace), encoding: .utf8)
        XCTAssertTrue(log.contains("root=\(workspace.root.path)"), log)
        XCTAssertTrue(log.contains("days=185"), log)
        XCTAssertTrue(log.contains("phase marker line"), log)
        XCTAssertTrue(log.contains("result=ok seconds="), log)
    }

    func testRunLogRecordsTimeoutResult() async throws {
        let fixture = try makeFixtureRepository()
        let logDirectory = fixture.base.appending(path: "logs")
        let executable = try makeExecutable(in: fixture.base, body: "sleep 30")
        let client = CollectorClient(executable: executable, logDirectory: logDirectory)
        let workspace = try Workspace(root: fixture.root)

        await XCTAssertThrowsErrorAsync(try await client.collect(CollectorRequest(
            workspace: workspace,
            reportURL: fixture.base.appending(path: "report.json"),
            timeout: .seconds(1),
            collectorDays: 185
        ))) { error in
            XCTAssertEqual(error as? CollectorError, .timedOut)
        }

        let log = try String(contentsOf: client.runLogURL(for: workspace), encoding: .utf8)
        XCTAssertTrue(log.contains("result=timed_out seconds="), log)
    }

    func testRunLogRotatesOversizedHistory() async throws {
        let fixture = try makeFixtureRepository()
        let reportFixture = fixture.base.appending(path: "fixture.json")
        try makeReportData().write(to: reportFixture)
        let logDirectory = fixture.base.appending(path: "logs")
        let executable = try makeExecutable(
            in: fixture.base,
            body: """
            last=""
            for argument in "$@"; do last="$argument"; done
            cp "$REPORT_FIXTURE" "$last"
            """
        )
        let cap = 4_096
        let client = CollectorClient(
            executable: executable,
            environment: ["REPORT_FIXTURE": reportFixture.path],
            logDirectory: logDirectory,
            logCapBytes: cap
        )
        let workspace = try Workspace(root: fixture.root)
        let logURL = client.runLogURL(for: workspace)
        try FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)
        try Data(repeating: UInt8(ascii: "x"), count: 100 * cap).write(to: logURL)

        _ = try await client.collect(CollectorRequest(
            workspace: workspace,
            reportURL: fixture.base.appending(path: "report.json"),
            timeout: .seconds(5),
            collectorDays: 185
        ))

        let log = try String(contentsOf: logURL, encoding: .utf8)
        let size = try FileManager.default.attributesOfItem(atPath: logURL.path)[.size] as? Int ?? 0
        XCTAssertLessThanOrEqual(size, cap + 2_048, "run log was not rotated down to the cap")
        XCTAssertTrue(log.contains("result=ok seconds="), log)
    }

    func testRunLogRecordsInvalidReportResult() async throws {
        let fixture = try makeFixtureRepository()
        let logDirectory = fixture.base.appending(path: "logs")
        let badReport = fixture.base.appending(path: "bad.json")
        try Data("not json".utf8).write(to: badReport)
        let executable = try makeExecutable(
            in: fixture.base,
            body: """
            last=""
            for argument in "$@"; do last="$argument"; done
            cp "$REPORT_FIXTURE" "$last"
            """
        )
        let client = CollectorClient(
            executable: executable,
            environment: ["REPORT_FIXTURE": badReport.path],
            logDirectory: logDirectory
        )
        let workspace = try Workspace(root: fixture.root)

        await XCTAssertThrowsErrorAsync(try await client.collect(CollectorRequest(
            workspace: workspace,
            reportURL: fixture.base.appending(path: "report.json"),
            timeout: .seconds(5),
            collectorDays: 185
        ))) { error in
            guard case CollectorError.invalidReport = error else {
                return XCTFail("Expected invalidReport, got \(error)")
            }
        }

        let log = try String(contentsOf: client.runLogURL(for: workspace), encoding: .utf8)
        XCTAssertTrue(log.contains("result=invalid_report seconds="), log)
        XCTAssertFalse(log.contains("result=ok"), log)
    }

    func testCollectorDoesNotInheritUnrelatedOpenDescriptors() async throws {
        let fixture = try makeFixtureRepository()
        let reportFixture = fixture.base.appending(path: "fixture.json")
        try makeReportData().write(to: reportFixture)
        let marker = fixture.base.appending(path: "parent-marker")
        FileManager.default.createFile(atPath: marker.path, contents: nil)
        let markerHandle = try FileHandle(forWritingTo: marker)
        defer { try? markerHandle.close() }
        let executable = try makeExecutable(
            in: fixture.base,
            body: """
            if [ -e "/dev/fd/$PARENT_FD" ]; then
              echo 'inherited parent descriptor' >&2
              exit 9
            fi
            last=""
            for argument in "$@"; do last="$argument"; done
            cp "$REPORT_FIXTURE" "$last"
            """
        )
        let client = CollectorClient(
            executable: executable,
            environment: [
                "PARENT_FD": String(markerHandle.fileDescriptor),
                "REPORT_FIXTURE": reportFixture.path,
            ],
            logDirectory: fixture.base.appending(path: "logs")
        )

        _ = try await client.collect(CollectorRequest(
            workspace: try Workspace(root: fixture.root),
            reportURL: fixture.base.appending(path: "report.json"),
            timeout: .seconds(5),
            collectorDays: 185
        ))
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
            environment: ["CHILD_PID_FILE": childPIDFile.path],
            logDirectory: fixture.base.appending(path: "logs")
        )
        let workspace = try Workspace(root: fixture.root)

        await XCTAssertThrowsErrorAsync(try await client.collect(CollectorRequest(
            workspace: workspace,
            reportURL: fixture.base.appending(path: "report.json"),
            timeout: .seconds(1),
            collectorDays: 185
        ))) { error in
            XCTAssertEqual(error as? CollectorError, .timedOut)
        }

        let childPID = try Int32(String(contentsOf: childPIDFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines))!
        for _ in 0..<20 where kill(childPID, 0) == 0 {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertNotEqual(kill(childPID, 0), 0, "Collector child process remained alive")
    }

    func testCancellationTerminatesUntimedCollectorProcessGroup() async throws {
        try await assertCancellationTerminatesProcess(timeout: nil)
    }

    func testCancellationTerminatesTimedCollectorProcessGroup() async throws {
        try await assertCancellationTerminatesProcess(timeout: .seconds(20))
    }

    private func assertCancellationTerminatesProcess(timeout: Duration?) async throws {
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
            environment: ["CHILD_PID_FILE": childPIDFile.path],
            logDirectory: fixture.base.appending(path: "logs")
        )
        let workspace = try Workspace(root: fixture.root)
        let task = Task {
            try await client.collect(CollectorRequest(
                workspace: workspace,
                reportURL: fixture.base.appending(path: "report.json"),
                timeout: timeout,
                collectorDays: 185
            ))
        }

        for _ in 0..<100 where !FileManager.default.fileExists(atPath: childPIDFile.path) {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: childPIDFile.path))
        let childPID = try Int32(
            String(contentsOf: childPIDFile, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        )!

        let started = ContinuousClock.now
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected collection to be cancelled")
        } catch {
            XCTAssertEqual(error as? CollectorError, .cancelled)
        }
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(2))

        for _ in 0..<40 where kill(childPID, 0) == 0 {
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
