import CryptoKit
import Foundation

public enum WorkspaceStoreError: Error, Equatable, LocalizedError, Sendable {
    case unsupportedSchema(Int)

    public var errorDescription: String? {
        switch self {
        case let .unsupportedSchema(version):
            "Unsupported workspace state schema: \(version)"
        }
    }
}

public struct WorkspaceStore: Sendable {
    public let baseDirectory: URL
    public var stateURL: URL { baseDirectory.appending(path: "workspaces.json") }
    public var reportsDirectory: URL { baseDirectory.appending(path: "Reports", directoryHint: .isDirectory) }

    public init(baseDirectory: URL? = nil) {
        if let baseDirectory {
            self.baseDirectory = baseDirectory
        } else {
            let applicationSupport = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first!
            self.baseDirectory = applicationSupport.appending(path: "SourceTempo", directoryHint: .isDirectory)
        }
    }

    public func load() throws -> WorkspaceState {
        guard FileManager.default.fileExists(atPath: stateURL.path) else {
            return WorkspaceState()
        }
        let state = try JSONDecoder().decode(WorkspaceState.self, from: Data(contentsOf: stateURL))
        guard state.schemaVersion == 1 else {
            throw WorkspaceStoreError.unsupportedSchema(state.schemaVersion)
        }
        return state
    }

    public func save(_ state: WorkspaceState) throws {
        try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(state)
        data.append(0x0A)

        let temporaryURL = baseDirectory.appending(path: ".workspaces.\(UUID().uuidString).tmp")
        try data.write(to: temporaryURL, options: .withoutOverwriting)
        let handle = try FileHandle(forWritingTo: temporaryURL)
        try handle.synchronize()
        try handle.close()

        if FileManager.default.fileExists(atPath: stateURL.path) {
            _ = try FileManager.default.replaceItemAt(stateURL, withItemAt: temporaryURL)
        } else {
            try FileManager.default.moveItem(at: temporaryURL, to: stateURL)
        }
    }

    public func reportURL(for workspace: Workspace) -> URL {
        let digest = SHA256.hash(data: Data(workspace.root.path.utf8))
        let key = digest.prefix(6).map { String(format: "%02x", $0) }.joined()
        return reportsDirectory.appending(path: "\(key).json")
    }
}
