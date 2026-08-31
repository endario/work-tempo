import Foundation
import XCTest
@testable import SourceTempoCore

final class CollectorContractTests: XCTestCase {
    func testPythonCollectorOutputDecodesAsSwiftReport() throws {
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
            "-c", "user.name=SourceTempo Test",
            "-c", "user.email=source-tempo@example.invalid",
            "commit", "--quiet", "-m", "fixture",
        ])

        let output = fixture.appending(path: "report.json")
        try run(
            "/usr/bin/env",
            [
                "python3", "-m", "source_tempo",
                "--root", fixture.path,
                "--period", "day",
                "--days", "61",
                "--workers", "2",
                "--no-cache",
                "--no-html",
                "--json", output.path,
            ],
            environment: ["PYTHONPATH": repositoryRoot.appending(path: "src").path]
        )

        let report = try ReportDocument.decode(data: Data(contentsOf: output))
        XCTAssertEqual(report.schemaVersion, 1)
        XCTAssertEqual(
            NSString(string: report.workspace.root).resolvingSymlinksInPath,
            NSString(string: fixture.path).resolvingSymlinksInPath
        )
        XCTAssertEqual(report.period.labels.count, 61)
        XCTAssertEqual(report.series.loc.count, 61)
        XCTAssertGreaterThan(report.series.locByKind.code.last ?? 0, 0)
    }

    private func run(
        _ executable: String,
        _ arguments: [String],
        environment: [String: String] = [:]
    ) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment
            .merging(environment) { _, override in override }
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "Command failed: \(executable) \(arguments.joined(separator: " "))")
    }
}
