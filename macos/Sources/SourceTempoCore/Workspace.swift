import Foundation

public enum WorkspaceError: Error, Equatable, Sendable {
    case invalidFileURL
}

public struct Workspace: Equatable, Hashable, Sendable {
    public let root: URL

    public var displayName: String {
        root.lastPathComponent
    }

    public init(root: URL) throws {
        guard root.isFileURL else { throw WorkspaceError.invalidFileURL }
        let path = root.standardizedFileURL.resolvingSymlinksInPath().path
        self.root = URL(fileURLWithPath: path, isDirectory: false)
    }
}

public struct WorkspaceState: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public var roots: [String]
    public var selectedRoot: String?

    public init(roots: [String] = [], selectedRoot: String? = nil) {
        schemaVersion = 1
        self.roots = roots
        self.selectedRoot = selectedRoot
    }
}
