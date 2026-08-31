import Combine
import Foundation
import SourceTempoCore

struct WorkspaceRowModel: Identifiable, Equatable {
    let workspace: Workspace
    let sourceValue: String
    let churnValue: String
    let hasError: Bool

    var id: String { workspace.root.path }
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var workspaces: [Workspace] = []
    @Published private(set) var selectedWorkspace: Workspace?
    @Published private(set) var snapshot: DashboardSnapshot
    @Published private(set) var workspaceRows: [WorkspaceRowModel] = []

    private let store: WorkspaceStore
    private var reports: [String: ReportDocument] = [:]
    private var state = WorkspaceState()

    init(store: WorkspaceStore = WorkspaceStore()) {
        self.store = store
        snapshot = DashboardSnapshot(workspace: nil, report: nil, refreshState: .idle, now: Date())
        loadCachedState()
    }

    func select(_ workspace: Workspace) {
        selectedWorkspace = workspace
        state.selectedRoot = workspace.root.path
        try? store.save(state)
        updateSnapshot()
    }

    private func loadCachedState() {
        do {
            state = try store.load()
            workspaces = state.roots.compactMap { try? Workspace(root: URL(fileURLWithPath: $0)) }
            for workspace in workspaces {
                let url = store.reportURL(for: workspace)
                guard let data = try? Data(contentsOf: url),
                      let report = try? ReportDocument.decode(data: data) else { continue }
                reports[workspace.root.path] = report
            }
            selectedWorkspace = workspaces.first(where: { $0.root.path == state.selectedRoot }) ?? workspaces.first
            rebuildRows()
            updateSnapshot()
        } catch {
            snapshot = DashboardSnapshot(
                workspace: nil,
                report: nil,
                refreshState: .failed(error.localizedDescription),
                now: Date()
            )
        }
    }

    private func rebuildRows() {
        workspaceRows = workspaces.map { workspace in
            let report = reports[workspace.root.path]
            let summary = report.map(MomentumSummary.init)
            return WorkspaceRowModel(
                workspace: workspace,
                sourceValue: summary.map { MetricFormatter.compact($0.sourceLOC) } ?? "--",
                churnValue: summary.map { MetricFormatter.compact($0.currentChurn) } ?? "--",
                hasError: false
            )
        }
    }

    private func updateSnapshot() {
        let report = selectedWorkspace.flatMap { reports[$0.root.path] }
        snapshot = DashboardSnapshot(
            workspace: selectedWorkspace,
            report: report,
            refreshState: .idle,
            now: Date()
        )
    }
}
