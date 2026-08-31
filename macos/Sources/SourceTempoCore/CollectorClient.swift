import Darwin
import Foundation

public struct CollectorRequest: Sendable {
    public let workspace: Workspace
    public let reportURL: URL
    public let timeout: Duration?

    public init(workspace: Workspace, reportURL: URL, timeout: Duration?) {
        self.workspace = workspace
        self.reportURL = reportURL
        self.timeout = timeout
    }
}

public enum CollectorError: Error, Equatable, LocalizedError, Sendable {
    case missingWorkspace(String)
    case notRepositoryRoot(String)
    case collectorFailed(String)
    case timedOut
    case cancelled
    case invalidReport(String)

    public var errorDescription: String? {
        switch self {
        case let .missingWorkspace(path):
            "Workspace does not exist: \(path)"
        case let .notRepositoryRoot(path):
            "Workspace is not a Git repository root: \(path)"
        case let .collectorFailed(message):
            message
        case .timedOut:
            "Collection timed out"
        case .cancelled:
            "Collection cancelled"
        case let .invalidReport(message):
            "Collector produced an invalid report: \(message)"
        }
    }
}

public actor CollectorClient {
    private let executable: URL
    private let gitExecutable: URL
    private let environment: [String: String]

    public init(
        executable: URL,
        gitExecutable: URL = URL(fileURLWithPath: "/usr/bin/git"),
        environment: [String: String] = [:]
    ) {
        self.executable = executable
        self.gitExecutable = gitExecutable
        self.environment = environment
    }

    public func collect(_ request: CollectorRequest) async throws -> ReportDocument {
        try preflight(request.workspace)
        try FileManager.default.createDirectory(
            at: request.reportURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let diagnosticURL = FileManager.default.temporaryDirectory
            .appending(path: "source-tempo-\(UUID().uuidString).stderr")
        FileManager.default.createFile(atPath: diagnosticURL.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: diagnosticURL) }

        let diagnosticHandle = try FileHandle(forWritingTo: diagnosticURL)
        defer { try? diagnosticHandle.close() }

        let process = Process()
        process.executableURL = executable
        process.arguments = [
            "--root", request.workspace.root.path,
            "--period", "day",
            "--days", "61",
            "--workers", "2",
            "--no-html",
            "--json", request.reportURL.path,
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = diagnosticHandle
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, override in override }

        let running = RunningProcess(process)
        do {
            try process.run()
            running.establishProcessGroup()
            let status = try await waitForExit(running, timeout: request.timeout)
            guard status == 0 else {
                throw CollectorError.collectorFailed(finalDiagnostic(at: diagnosticURL, status: status))
            }
        } catch is CancellationError {
            running.terminateGroup()
            _ = await running.wait()
            throw CollectorError.cancelled
        } catch let error as CollectorError {
            throw error
        } catch {
            throw CollectorError.collectorFailed(error.localizedDescription)
        }

        do {
            return try ReportDocument.decode(data: Data(contentsOf: request.reportURL))
        } catch {
            throw CollectorError.invalidReport(error.localizedDescription)
        }
    }

    private func preflight(_ workspace: Workspace) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: workspace.root.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw CollectorError.missingWorkspace(workspace.root.path)
        }

        let process = Process()
        let output = Pipe()
        process.executableURL = gitExecutable
        process.arguments = ["-C", workspace.root.path, "rev-parse", "--show-toplevel"]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw CollectorError.notRepositoryRoot(workspace.root.path)
        }
        guard process.terminationStatus == 0,
              let root = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              (try? Workspace(root: URL(fileURLWithPath: root))) == workspace
        else {
            throw CollectorError.notRepositoryRoot(workspace.root.path)
        }
    }

    private func waitForExit(_ running: RunningProcess, timeout: Duration?) async throws -> Int32 {
        guard let timeout else { return await running.wait() }

        return try await withThrowingTaskGroup(of: ExitResult.self) { group in
            group.addTask { .exited(await running.wait()) }
            group.addTask {
                try await Task.sleep(for: timeout)
                return .timedOut
            }

            guard let first = try await group.next() else {
                throw CollectorError.cancelled
            }
            switch first {
            case let .exited(status):
                group.cancelAll()
                return status
            case .timedOut:
                running.terminateGroup()
                _ = await running.wait()
                group.cancelAll()
                throw CollectorError.timedOut
            }
        }
    }

    private func finalDiagnostic(at url: URL, status: Int32) -> String {
        let limit = 64 * 1_024
        let data = (try? Data(contentsOf: url)) ?? Data()
        let tail = data.suffix(limit)
        let lines = String(decoding: tail, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
        return lines.last.map(String.init) ?? "Collector exited with status \(status)"
    }
}

private enum ExitResult: Sendable {
    case exited(Int32)
    case timedOut
}

private final class RunningProcess: @unchecked Sendable {
    private let process: Process
    private let lock = NSLock()
    private var status: Int32?
    private var waiters: [CheckedContinuation<Int32, Never>] = []
    private var ownsProcessGroup = false

    init(_ process: Process) {
        self.process = process
        process.terminationHandler = { [weak self] process in
            self?.complete(process.terminationStatus)
        }
    }

    func establishProcessGroup() {
        let pid = process.processIdentifier
        guard pid > 0 else { return }
        ownsProcessGroup = setpgid(pid, pid) == 0 || getpgid(pid) == pid
    }

    func wait() async -> Int32 {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let status {
                lock.unlock()
                continuation.resume(returning: status)
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }

    func terminateGroup() {
        guard process.isRunning else { return }
        let pid = process.processIdentifier
        if ownsProcessGroup {
            kill(-pid, SIGTERM)
        } else {
            process.terminate()
        }
        usleep(100_000)
        if process.isRunning {
            if ownsProcessGroup {
                kill(-pid, SIGKILL)
            } else {
                kill(pid, SIGKILL)
            }
        }
    }

    private func complete(_ status: Int32) {
        lock.lock()
        guard self.status == nil else {
            lock.unlock()
            return
        }
        self.status = status
        let waiters = self.waiters
        self.waiters.removeAll()
        lock.unlock()
        for waiter in waiters {
            waiter.resume(returning: status)
        }
    }
}
