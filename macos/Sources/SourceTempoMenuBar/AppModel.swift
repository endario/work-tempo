import AppKit
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
    private let controller: WorkspaceController
    private let coordinator: RefreshCoordinator
    private let resolver: CollectorResolver
    private var refreshTask: Task<Void, Never>?
    private var timerTask: Task<Void, Never>?
    private var wakeObserver: AnyCancellable?
    private var started = false
    private var selectedReport: ReportDocument?

    init(
        store: WorkspaceStore = WorkspaceStore(),
        coordinator: RefreshCoordinator = RefreshCoordinator(),
        resolver: CollectorResolver = CollectorResolver()
    ) {
        self.store = store
        controller = WorkspaceController(store: store)
        self.coordinator = coordinator
        self.resolver = resolver
        snapshot = DashboardSnapshot(workspace: nil, report: nil, refreshState: .idle, now: Date())
        Task { [weak self] in await self?.start() }
    }

    func select(_ workspace: Workspace) {
        Task {
            await cancelActiveRefresh()
            do {
                let state = try await controller.select(workspace)
                apply(state)
                await coordinator.select(workspace)
                requestRefresh(.launch)
            } catch {
                applyError(error.localizedDescription)
            }
        }
    }

    func chooseWorkspace() {
        let panel = NSOpenPanel()
        panel.title = "Add Git Workspace"
        panel.prompt = "Add Workspace"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }

        Task {
            await cancelActiveRefresh()
            do {
                let state = try await controller.add(root: url)
                apply(state)
                guard let workspace = state.selectedWorkspace else { return }
                await coordinator.select(workspace)
                requestRefresh(.manual)
            } catch {
                applyError(error.localizedDescription)
            }
        }
    }

    func toggleRefresh() {
        if snapshot.isRefreshing {
            refreshTask?.cancel()
        } else {
            requestRefresh(.manual)
        }
    }

    func removeSelectedWorkspace() {
        guard let workspace = selectedWorkspace else { return }
        Task {
            await cancelActiveRefresh()
            do {
                let state = try await controller.remove(workspace)
                apply(state)
                if let selected = state.selectedWorkspace {
                    await coordinator.select(selected)
                    requestRefresh(.launch)
                }
            } catch {
                applyError(error.localizedDescription)
            }
        }
    }

    private func start() async {
        guard !started else { return }
        started = true
        do {
            let state = try await controller.load()
            apply(state)
            if let workspace = state.selectedWorkspace {
                await coordinator.select(workspace)
                requestRefresh(.launch)
            }
        } catch {
            applyError(error.localizedDescription)
        }

        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3_600))
                guard !Task.isCancelled else { return }
                self?.requestRefresh(.timer)
            }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.didWakeNotification)
            .sink { [weak self] _ in
                Task { @MainActor in self?.requestRefresh(.wake) }
            }
    }

    private func requestRefresh(_ trigger: RefreshTrigger) {
        guard selectedWorkspace != nil, refreshTask == nil else { return }
        let generatedAt = snapshot.reportGeneratedAt
        let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled

        refreshTask = Task { [weak self] in
            guard let self else { return }
            guard let plan = await coordinator.request(
                trigger: trigger,
                reportGeneratedAt: generatedAt,
                now: Date(),
                lowPower: lowPower
            ) else {
                refreshTask = nil
                return
            }

            let ticket = await controller.beginRefresh(plan.workspace)
            apply(await controller.state())
            do {
                let executable = try resolver.resolve()
                let client = CollectorClient(executable: executable)
                let report = try await client.collect(CollectorRequest(
                    workspace: plan.workspace,
                    reportURL: store.reportURL(for: plan.workspace),
                    timeout: plan.timeout
                ))
                apply(await controller.succeedRefresh(ticket, workspace: plan.workspace, report: report))
            } catch CollectorError.cancelled {
                apply(await controller.cancelRefresh(ticket, workspace: plan.workspace))
            } catch is CancellationError {
                apply(await controller.cancelRefresh(ticket, workspace: plan.workspace))
            } catch {
                apply(await controller.failRefresh(
                    ticket,
                    workspace: plan.workspace,
                    message: error.localizedDescription
                ))
            }
            await coordinator.finish()
            refreshTask = nil
        }
    }

    private func cancelActiveRefresh() async {
        guard let task = refreshTask else { return }
        task.cancel()
        await task.value
    }

    private func apply(_ state: WorkspaceControllerState) {
        workspaces = state.workspaces
        selectedWorkspace = state.selectedWorkspace
        selectedReport = state.selectedReport
        workspaceRows = state.workspaces.map { workspace in
            let report = state.report(for: workspace)
            let summary = report.map(MomentumSummary.init)
            let hasError: Bool
            if case .failed = state.refreshState(for: workspace) {
                hasError = true
            } else {
                hasError = false
            }
            return WorkspaceRowModel(
                workspace: workspace,
                sourceValue: summary.map { MetricFormatter.compact($0.sourceLOC) } ?? "--",
                churnValue: summary.map { MetricFormatter.compact($0.currentChurn) } ?? "--",
                hasError: hasError
            )
        }
        snapshot = DashboardSnapshot(
            workspace: state.selectedWorkspace,
            report: selectedReport,
            refreshState: state.selectedWorkspace.map(state.refreshState(for:)) ?? .idle,
            now: Date()
        )
    }

    private func applyError(_ message: String) {
        snapshot = DashboardSnapshot(
            workspace: selectedWorkspace,
            report: selectedReport,
            refreshState: .failed(message),
            now: Date()
        )
    }
}
