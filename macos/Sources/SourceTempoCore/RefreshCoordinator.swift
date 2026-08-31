import Foundation

public enum RefreshTrigger: Sendable {
    case launch
    case timer
    case wake
    case manual
}

public struct RefreshPlan: Equatable, Sendable {
    public let workspace: Workspace
    public let timeout: Duration?

    public init(workspace: Workspace, timeout: Duration?) {
        self.workspace = workspace
        self.timeout = timeout
    }
}

public actor RefreshCoordinator {
    private let staleInterval: TimeInterval
    private var selectedWorkspace: Workspace?
    private var isRefreshing = false

    public init(staleInterval: TimeInterval = 3_600) {
        self.staleInterval = staleInterval
    }

    public func select(_ workspace: Workspace) {
        selectedWorkspace = workspace
    }

    public func request(
        trigger: RefreshTrigger,
        reportGeneratedAt: Date?,
        now: Date,
        lowPower: Bool
    ) -> RefreshPlan? {
        guard !isRefreshing, let selectedWorkspace else { return nil }

        let isUnattended = trigger != .manual
        guard !(isUnattended && lowPower) else { return nil }

        if isUnattended,
           let reportGeneratedAt,
           now.timeIntervalSince(reportGeneratedAt) < staleInterval {
            return nil
        }

        isRefreshing = true
        return RefreshPlan(
            workspace: selectedWorkspace,
            timeout: reportGeneratedAt == nil ? nil : .seconds(120)
        )
    }

    public func finish() {
        isRefreshing = false
    }
}
