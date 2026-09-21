import Foundation
import XCTest
@testable import WorkTempoCore

final class CollectorContractTests: XCTestCase {
    func testPythonCollectorOutputDecodesAsSwiftReport() async throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fixture = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture) }

        try run("/usr/bin/git", ["init", "--quiet", fixture.path])
        try Data("let tempo = 1\n".utf8).write(to: fixture.appending(path: "Tempo.swift"))
        try run("/usr/bin/git", ["-C", fixture.path, "add", "Tempo.swift"])
        try run("/usr/bin/git", [
            "-C", fixture.path,
            "-c", "user.name=WorkTempo Test",
            "-c", "user.email=work-tempo@example.invalid",
            "commit", "--quiet", "-m", "fixture",
        ])

        let executable = fixture.appending(path: "work-tempo")
        try Data("#!/bin/sh\nexec /usr/bin/env python3 -m work_tempo \"$@\"\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let workspace = try Workspace(root: fixture)
        let output = fixture.appending(path: "report.json")
        let report = try await CollectorClient(
            executable: executable,
            environment: [
                "HOME": fixture.path,
                "PYTHONPATH": repositoryRoot.appending(path: "src").path,
            ]
        ).collect(CollectorRequest(workspace: workspace, reportURL: output, timeout: .seconds(30)))

        XCTAssertEqual(report.schemaVersion, 1)
        XCTAssertEqual(
            NSString(string: report.workspace.root).resolvingSymlinksInPath,
            NSString(string: fixture.path).resolvingSymlinksInPath
        )
        XCTAssertEqual(report.period.labels.count, 185)
        XCTAssertEqual(report.series.loc.count, 185)
        XCTAssertGreaterThan(report.series.locByKind.code.last ?? 0, 0)
    }

    private func run(
        _ executable: String,
        _ arguments: [String]
    ) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "Command failed: \(executable) \(arguments.joined(separator: " "))")
    }
}
