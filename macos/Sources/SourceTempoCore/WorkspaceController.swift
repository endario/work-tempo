import Foundation

public enum WorkspaceControllerError: Error, Equatable, LocalizedError, Sendable {
    case duplicateWorkspace(String)
    case unknownWorkspace(String)

    public var errorDescription: String? {
        switch self {
        case let .duplicateWorkspace(path):
            "Workspace is already tracked: \(path)"
        case let .unknownWorkspace(path):
            "Workspace is not tracked: \(path)"
        }
    }
}

public struct WorkspaceControllerState: Sendable {
    public let workspaces: [Workspace]
    public let scope: DisplayScope
    private let reports: [String: ReportDocument]
    private let refreshStates: [String: SnapshotRefreshState]

    fileprivate init(
        workspaces: [Workspace],
        scope: DisplayScope,
        reports: [String: ReportDocument],
        refreshStates: [String: SnapshotRefreshState]
    ) {
        self.workspaces = workspaces
        self.scope = scope
        self.reports = reports
        self.refreshStates = refreshStates
    }

    public var selectedWorkspace: Workspace? {
        guard case let .workspace(workspace) = scope else { return nil }
        return workspace
    }

    public var selectedReport: ReportDocument? {
        selectedWorkspace.flatMap { reports[$0.root.path] }
    }

    public var reportsByWorkspace: [Workspace: ReportDocument] {
        Dictionary(uniqueKeysWithValues: workspaces.compactMap { workspace in
            reports[workspace.root.path].map { (workspace, $0) }
        })
    }

    public func report(for workspace: Workspace) -> ReportDocument? {
        reports[workspace.root.path]
    }

    public func refreshState(for workspace: Workspace) -> SnapshotRefreshState {
        refreshStates[workspace.root.path] ?? .idle
    }
}

public actor WorkspaceController {
    private let store: WorkspaceStore
    private var workspaces: [Workspace] = []
    private var scope: DisplayScope = .all
    private var reports: [String: ReportDocument] = [:]
    private var refreshStates: [String: SnapshotRefreshState] = [:]
    private var refreshTickets: [String: UUID] = [:]

    public init(store: WorkspaceStore = WorkspaceStore()) {
        self.store = store
    }

    public func load() throws -> WorkspaceControllerState {
        let persisted = try store.load()
        workspaces = persisted.roots.compactMap { try? Workspace(root: URL(fileURLWithPath: $0)) }
        if let persistedScope = persisted.selectedScope,
           persistedScope != "all",
           let workspace = workspaces.first(where: { $0.root.path == persistedScope }) {
            scope = .workspace(workspace)
        } else {
            scope = .all
        }
        reports.removeAll()
        refreshStates.removeAll()

        for workspace in workspaces {
            let reportURL = store.reportURL(for: workspace)
            guard FileManager.default.fileExists(atPath: reportURL.path) else { continue }
            do {
                reports[workspace.root.path] = try ReportDocument.decode(data: Data(contentsOf: reportURL))
            } catch {
                refreshStates[workspace.root.path] = .failed(error.localizedDescription)
            }
        }
        return snapshot()
    }

    public func add(root: URL) throws -> WorkspaceControllerState {
        let workspace = try Workspace(root: root)
        guard !workspaces.contains(workspace) else {
            throw WorkspaceControllerError.duplicateWorkspace(workspace.root.path)
        }
        workspaces.append(workspace)
        try persist()
        return snapshot()
    }

    public func select(_ workspace: Workspace) throws -> WorkspaceControllerState {
        guard workspaces.contains(workspace) else {
            throw WorkspaceControllerError.unknownWorkspace(workspace.root.path)
        }
        scope = .workspace(workspace)
        try persist()
        return snapshot()
    }

    public func selectAll() throws -> WorkspaceControllerState {
        scope = .all
        try persist()
        return snapshot()
    }

    public func remove(_ workspace: Workspace) throws -> WorkspaceControllerState {
        guard let index = workspaces.firstIndex(of: workspace) else {
            throw WorkspaceControllerError.unknownWorkspace(workspace.root.path)
        }
        let reportURL = store.reportURL(for: workspace)
        if FileManager.default.fileExists(atPath: reportURL.path) {
            try? FileManager.default.removeItem(at: reportURL)
        }
        workspaces.remove(at: index)
        reports[workspace.root.path] = nil
        refreshTickets[workspace.root.path] = nil
        refreshStates[workspace.root.path] = nil
        if case let .workspace(selected) = scope, selected == workspace {
            scope = .all
        }
        try persist()
        return snapshot()
    }

    public func beginRefresh(_ workspace: Workspace) -> UUID {
        let ticket = UUID()
        refreshTickets[workspace.root.path] = ticket
        refreshStates[workspace.root.path] = .refreshing
        return ticket
    }

    public func succeedRefresh(
        _ ticket: UUID,
        workspace: Workspace,
        report: ReportDocument
    ) -> WorkspaceControllerState {
        guard refreshTickets[workspace.root.path] == ticket else { return snapshot() }
        reports[workspace.root.path] = report
        refreshStates[workspace.root.path] = .idle
        refreshTickets[workspace.root.path] = nil
        return snapshot()
    }

    public func failRefresh(
        _ ticket: UUID,
        workspace: Workspace,
        message: String
    ) -> WorkspaceControllerState {
        guard refreshTickets[workspace.root.path] == ticket else { return snapshot() }
        refreshStates[workspace.root.path] = .failed(message)
        refreshTickets[workspace.root.path] = nil
        return snapshot()
    }

    public func cancelRefresh(_ ticket: UUID, workspace: Workspace) -> WorkspaceControllerState {
        guard refreshTickets[workspace.root.path] == ticket else { return snapshot() }
        refreshStates[workspace.root.path] = .idle
        refreshTickets[workspace.root.path] = nil
        return snapshot()
    }

    public func state() -> WorkspaceControllerState {
        snapshot()
    }

    private func persist() throws {
        let selectedWorkspace: Workspace?
        if case let .workspace(workspace) = scope {
            selectedWorkspace = workspace
        } else {
            selectedWorkspace = nil
        }
        try store.save(WorkspaceState(
            roots: workspaces.map(\.root.path),
            selectedRoot: selectedWorkspace?.root.path,
            selectedScope: selectedWorkspace?.root.path ?? "all"
        ))
    }

    private func snapshot() -> WorkspaceControllerState {
        WorkspaceControllerState(
            workspaces: workspaces,
            scope: scope,
            reports: reports,
            refreshStates: refreshStates
        )
    }
}
