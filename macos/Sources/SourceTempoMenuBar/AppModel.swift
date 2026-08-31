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
    @Published private(set) var scope: DisplayScope = .all
    @Published private(set) var selectedWorkspace: Workspace?
    @Published private(set) var snapshot: DashboardSnapshot
    @Published private(set) var workspaceRows: [WorkspaceRowModel] = []
    @Published private(set) var refreshProgress: String?

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
                apply(try await controller.select(workspace))
                requestRefresh(.launch)
            } catch {
                applyError(error.localizedDescription)
            }
        }
    }

    func selectAll() {
        Task {
            await cancelActiveRefresh()
            do {
                apply(try await controller.selectAll())
                requestRefresh(.launch)
            } catch {
                applyError(error.localizedDescription)
            }
        }
    }

    func chooseWorkspace() {
        NSApp.activate(ignoringOtherApps: true)
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
                if let workspace = state.workspaces.last {
                    requestRefresh(.manual, scopeOverride: .workspace(workspace))
                }
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
                apply(try await controller.remove(workspace))
            } catch {
                applyError(error.localizedDescription)
            }
        }
    }

    private func start() async {
        guard !started else { return }
        started = true
        do {
            apply(try await controller.load())
            requestRefresh(.launch)
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

    private func requestRefresh(_ trigger: RefreshTrigger, scopeOverride: DisplayScope? = nil) {
        guard !workspaces.isEmpty, refreshTask == nil else { return }
        let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled

        refreshTask = Task { [weak self] in
            guard let self else { return }
            let state = await controller.state()
            let targets = state.workspaces.map { workspace in
                let report = state.report(for: workspace)
                return RefreshTarget(
                    workspace: workspace,
                    generatedAt: report.flatMap { Self.parseTimestamp($0.generatedAt) },
                    dayCount: report?.period.labels.count ?? 0
                )
            }
            guard let plans = await coordinator.request(
                trigger: trigger,
                scope: scopeOverride ?? state.scope,
                targets: targets,
                now: Date(),
                lowPower: lowPower
            ) else {
                refreshTask = nil
                return
            }

            for (index, plan) in plans.enumerated() {
                guard !Task.isCancelled else { break }
                refreshProgress = "\(plan.workspace.displayName) · \(index + 1) of \(plans.count)"
                let ticket = await controller.beginRefresh(plan.workspace)
                apply(await controller.state())
                do {
                    let executable = try resolver.resolve()
                    let report = try await CollectorClient(executable: executable).collect(CollectorRequest(
                        workspace: plan.workspace,
                        reportURL: store.reportURL(for: plan.workspace),
                        timeout: plan.timeout
                    ))
                    apply(await controller.succeedRefresh(ticket, workspace: plan.workspace, report: report))
                } catch CollectorError.cancelled {
                    apply(await controller.cancelRefresh(ticket, workspace: plan.workspace))
                    break
                } catch is CancellationError {
                    apply(await controller.cancelRefresh(ticket, workspace: plan.workspace))
                    break
                } catch {
                    apply(await controller.failRefresh(
                        ticket,
                        workspace: plan.workspace,
                        message: error.localizedDescription
                    ))
                }
            }
            refreshProgress = nil
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
        scope = state.scope
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
                churnValue: summary.map { MetricFormatter.compact($0.dailyChurn) } ?? "--",
                hasError: hasError
            )
        }

        switch state.scope {
        case .all:
            let refreshState = aggregateRefreshState(state)
            switch PortfolioMomentum.build(
                workspaces: state.workspaces,
                reports: state.reportsByWorkspace
            ) {
            case let .success(portfolio):
                snapshot = DashboardSnapshot(
                    portfolio: portfolio,
                    refreshState: refreshState,
                    now: Date()
                )
            case let .failure(error):
                snapshot = DashboardSnapshot(
                    workspace: nil,
                    report: nil,
                    refreshState: .failed(error.localizedDescription),
                    now: Date()
                )
            }
        case let .workspace(workspace):
            snapshot = DashboardSnapshot(
                workspace: workspace,
                report: state.report(for: workspace),
                refreshState: state.refreshState(for: workspace),
                now: Date()
            )
        }
    }

    private func aggregateRefreshState(_ state: WorkspaceControllerState) -> SnapshotRefreshState {
        let states = state.workspaces.map(state.refreshState(for:))
        if states.contains(.refreshing) { return .refreshing }
        if let failure = states.first(where: {
            if case .failed = $0 { return true }
            return false
        }), case let .failed(message) = failure {
            return .failed(message)
        }
        return .idle
    }

    private func applyError(_ message: String) {
        snapshot = DashboardSnapshot(
            workspace: selectedWorkspace,
            report: selectedReport,
            refreshState: .failed(message),
            now: Date()
        )
    }

    private static func parseTimestamp(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}
