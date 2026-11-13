import CryptoKit
import Darwin
import Foundation

public struct CollectorRequest: Sendable {
    public let workspace: Workspace
    public let reportURL: URL
    public let timeout: Duration?
    public let collectorDays: Int

    public init(workspace: Workspace, reportURL: URL, timeout: Duration?, collectorDays: Int) {
        self.workspace = workspace
        self.reportURL = reportURL
        self.timeout = timeout
        self.collectorDays = collectorDays
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
    private let environment: [String: String]
    private let logDirectory: URL
    private let logCapBytes: Int

    public static let defaultLogDirectory: URL = FileManager.default
        .urls(for: .libraryDirectory, in: .userDomainMask)[0]
        .appending(path: "Logs/WorkTempo")

    public init(
        executable: URL,
        environment: [String: String] = [:],
        logDirectory: URL = CollectorClient.defaultLogDirectory,
        logCapBytes: Int = 1_048_576
    ) {
        self.executable = executable
        self.environment = environment
        self.logDirectory = logDirectory
        self.logCapBytes = logCapBytes
    }

    public nonisolated func runLogURL(for workspace: Workspace) -> URL {
        let digest = SHA256.hash(data: Data(workspace.root.path.utf8))
        let hash = digest.prefix(6).map { String(format: "%02x", $0) }.joined()
        return logDirectory.appending(path: "\(Self.logSlug(for: workspace.root))-\(hash).log")
    }

    private static func logSlug(for root: URL) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789")
        let mapped = root.lastPathComponent.lowercased().unicodeScalars.map { scalar -> Character in
            allowed.contains(scalar) ? Character(scalar) : "-"
        }
        let slug = String(mapped).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return slug.isEmpty ? "workspace" : slug
    }

    public func collect(_ request: CollectorRequest) async throws -> ReportDocument {
        try preflight(request.workspace)
        try FileManager.default.createDirectory(
            at: request.reportURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let diagnosticURL = FileManager.default.temporaryDirectory
            .appending(path: "work-tempo-\(UUID().uuidString).stderr")
        FileManager.default.createFile(atPath: diagnosticURL.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: diagnosticURL) }

        let diagnosticHandle = try FileHandle(forWritingTo: diagnosticURL)
        defer { try? diagnosticHandle.close() }

        let runLog = RunLog(
            url: runLogURL(for: request.workspace),
            capBytes: logCapBytes,
            root: request.workspace.root.path,
            days: request.collectorDays,
            timeout: request.timeout
        )
        runLog.open()
        defer { runLog.close() }

        let arguments = [
            "--root", request.workspace.root.path,
            "--period", "day",
            "--days", String(request.collectorDays),
            "--workers", "2",
            "--no-html",
            "--json", request.reportURL.path,
        ]
        let processEnvironment = ProcessInfo.processInfo.environment
            .merging(environment) { _, override in override }

        let started = ContinuousClock.now
        do {
            let running = try RunningProcess.spawn(
                executable: executable,
                arguments: arguments,
                environment: processEnvironment,
                stdoutDescriptor: runLog.stdoutDescriptor,
                diagnosticDescriptor: diagnosticHandle.fileDescriptor
            )
            let status: Int32
            do {
                status = try await waitForExit(running, timeout: request.timeout)
                try Task.checkCancellation()
            } catch is CancellationError {
                runLog.finish(result: "cancelled", started: started)
                throw CollectorError.cancelled
            } catch let error as CollectorError {
                runLog.finish(result: error == .timedOut ? "timed_out" : "failed", started: started)
                throw error
            }
            if status != 0 {
                runLog.finish(result: "failed(\(status))", started: started)
                throw CollectorError.collectorFailed(finalDiagnostic(at: diagnosticURL, status: status))
            }
        } catch {
            // No-op when an inner path already finished and closed the log.
            runLog.finish(result: "spawn_failed", started: started)
            if let collectorError = error as? CollectorError {
                throw collectorError
            }
            throw CollectorError.collectorFailed(error.localizedDescription)
        }

        do {
            let report = try ReportDocument.decode(data: Data(contentsOf: request.reportURL))
            runLog.finish(result: "ok", started: started)
            return report
        } catch {
            runLog.finish(result: "invalid_report", started: started)
            throw CollectorError.invalidReport(error.localizedDescription)
        }
    }

    private func preflight(_ workspace: Workspace) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: workspace.root.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw CollectorError.missingWorkspace(workspace.root.path)
        }
        guard FileManager.default.fileExists(atPath: workspace.root.appending(path: ".git").path) else {
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

/// One collector run's persistent log: a header line, the collector's stdout
/// (its phase timings), and a result footer. The report only carries success
/// data and stderr is discarded on success, so without this file a slow or
/// timed-out run leaves nothing to diagnose. Fails open: a logging problem
/// never fails collection.
private final class RunLog {
    private let url: URL
    private let capBytes: Int
    private let header: String
    private var handle: FileHandle?
    private(set) var stdoutDescriptor: Int32?

    init(url: URL, capBytes: Int, root: String, days: Int, timeout: Duration?, now: Date = Date()) {
        self.url = url
        self.capBytes = max(1, capBytes)
        let stamp = ISO8601DateFormatter().string(from: now)
        let timeoutLabel = timeout.map { "\($0.components.seconds)s" } ?? "none"
        header = "--- \(stamp) root=\(root) days=\(days) timeout=\(timeoutLabel)\n"
    }

    func open() {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            if let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int,
               size > capBytes {
                rotate(keepingLast: capBytes / 2)
            }
            // O_APPEND: a manual CLI run priming the cache while the app
            // refreshes interleaves instead of clobbering shared offsets.
            let descriptor = Darwin.open(url.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
            guard descriptor >= 0 else {
                close()
                return
            }
            let fileHandle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            handle = fileHandle
            stdoutDescriptor = descriptor
            try fileHandle.write(contentsOf: Data(header.utf8))
        } catch {
            close()
        }
    }

    /// Keep only the most recent bytes so history stays bounded without losing
    /// the runs that matter most.
    private func rotate(keepingLast tailBytes: Int) {
        guard let source = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? source.close() }
        let size = Int(source.seekToEndOfFile())
        guard size > tailBytes else { return }
        _ = try? source.seek(toOffset: UInt64(size - tailBytes))
        let tail = source.readDataToEndOfFile()
        try? tail.write(to: url, options: .atomic)
    }

    func finish(result: String, started: ContinuousClock.Instant) {
        guard let handle else { return }
        let elapsed = ContinuousClock.now - started
        let components = elapsed.components
        let seconds = Double(components.seconds) + Double(components.attoseconds) / 1e18
        try? handle.write(contentsOf: Data(String(format: "    result=%@ seconds=%.1f\n", result, seconds).utf8))
        close()
    }

    func close() {
        try? handle?.close()
        handle = nil
        stdoutDescriptor = nil
    }
}

private final class RunningProcess: @unchecked Sendable {
    private let pid: pid_t
    private let lock = NSLock()
    private var status: Int32?
    private var waiters: [CheckedContinuation<Int32, Never>] = []
    private var terminationStarted = false

    private init(pid: pid_t) {
        self.pid = pid
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            var waitStatus: Int32 = 0
            var result: pid_t
            repeat {
                result = waitpid(pid, &waitStatus, 0)
            } while result == -1 && errno == EINTR
            self.complete(result == pid ? Self.exitStatus(from: waitStatus) : 127)
        }
    }

    static func spawn(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        stdoutDescriptor: Int32?,
        diagnosticDescriptor: Int32
    ) throws -> RunningProcess {
        var attributes: posix_spawnattr_t?
        var actions: posix_spawn_file_actions_t?
        guard posix_spawnattr_init(&attributes) == 0 else {
            throw POSIXError(.ENOMEM)
        }
        defer { posix_spawnattr_destroy(&attributes) }
        guard posix_spawn_file_actions_init(&actions) == 0 else {
            throw POSIXError(.ENOMEM)
        }
        defer {
            posix_spawn_file_actions_destroy(&actions)
        }

        let stdoutBound: Bool
        if let stdoutDescriptor {
            stdoutBound = posix_spawn_file_actions_adddup2(&actions, stdoutDescriptor, STDOUT_FILENO) == 0
        } else {
            stdoutBound = posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, "/dev/null", O_WRONLY, 0) == 0
        }
        let flags = Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)
        guard posix_spawnattr_setflags(&attributes, flags) == 0,
              posix_spawnattr_setpgroup(&attributes, 0) == 0,
              stdoutBound,
              posix_spawn_file_actions_adddup2(&actions, diagnosticDescriptor, STDERR_FILENO) == 0 else {
            throw POSIXError(.EINVAL)
        }

        let argumentStrings = [executable.path] + arguments
        let environmentStrings = environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
        var argv = argumentStrings.map { value in
            value.withCString { strdup($0) }
        } + [nil]
        var envp = environmentStrings.map { value in
            value.withCString { strdup($0) }
        } + [nil]
        defer {
            for case let pointer? in argv {
                free(UnsafeMutableRawPointer(pointer))
            }
            for case let pointer? in envp {
                free(UnsafeMutableRawPointer(pointer))
            }
        }

        var pid: pid_t = 0
        let result = argv.withUnsafeMutableBufferPointer { argvBuffer in
            envp.withUnsafeMutableBufferPointer { envpBuffer in
                posix_spawn(
                    &pid,
                    executable.path,
                    &actions,
                    &attributes,
                    argvBuffer.baseAddress!,
                    envpBuffer.baseAddress!
                )
            }
        }
        guard result == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: result) ?? .EIO)
        }
        return RunningProcess(pid: pid)
    }

    func wait() async -> Int32 {
        await withTaskCancellationHandler {
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
        } onCancel: {
            self.terminateGroup()
        }
    }

    func terminateGroup() {
        lock.lock()
        guard status == nil, !terminationStarted else {
            lock.unlock()
            return
        }
        terminationStarted = true
        lock.unlock()

        kill(-pid, SIGTERM)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .milliseconds(100)) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let isRunning = self.status == nil
            self.lock.unlock()
            if isRunning {
                kill(-self.pid, SIGKILL)
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

    private static func exitStatus(from waitStatus: Int32) -> Int32 {
        let signal = waitStatus & 0x7F
        return signal == 0 ? (waitStatus >> 8) & 0xFF : 128 + signal
    }
}
