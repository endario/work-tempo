import Foundation

public enum RefreshTrigger: Sendable {
    case launch
    case timer
    case wake
    case manual
}

public struct RefreshTarget: Equatable, Sendable {
    public let workspace: Workspace
    public let generatedAt: Date?
    public let dayCount: Int
    public let lastAttemptFailed: Bool

    public init(
        workspace: Workspace,
        generatedAt: Date?,
        dayCount: Int,
        lastAttemptFailed: Bool = false
    ) {
        self.workspace = workspace
        self.generatedAt = generatedAt
        self.dayCount = dayCount
        self.lastAttemptFailed = lastAttemptFailed
    }
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
    private let requiredDayCount: Int
    private var isRefreshing = false

    public init(
        staleInterval: TimeInterval = 3_600,
        requiredDayCount: Int = HistoryWindow.collectorDays
    ) {
        self.staleInterval = staleInterval
        self.requiredDayCount = requiredDayCount
    }

    public func request(
        trigger: RefreshTrigger,
        scope: DisplayScope,
        targets: [RefreshTarget],
        now: Date,
        lowPower: Bool
    ) -> [RefreshPlan]? {
        guard !isRefreshing else { return nil }
        let isUnattended = trigger != .manual
        guard !(isUnattended && lowPower) else { return nil }

        let scoped: [RefreshTarget]
        switch scope {
        case .all:
            scoped = targets
        case let .workspace(workspace):
            scoped = targets.filter { $0.workspace == workspace }
        }

        let selected: [RefreshTarget]
        if trigger == .manual {
            selected = scoped
        } else if let target = unattendedTarget(from: scoped, now: now) {
            selected = [target]
        } else {
            selected = []
        }
        guard !selected.isEmpty else { return nil }

        isRefreshing = true
        return selected.map { target in
            RefreshPlan(
                workspace: target.workspace,
                timeout: target.generatedAt == nil || target.dayCount < requiredDayCount
                    ? nil
                    : .seconds(120)
            )
        }
    }

    public func finish() {
        isRefreshing = false
    }

    private func unattendedTarget(from targets: [RefreshTarget], now: Date) -> RefreshTarget? {
        let healthy = targets.filter { !$0.lastAttemptFailed }
        if let missing = healthy.first(where: { $0.generatedAt == nil }) {
            return missing
        }
        if let short = healthy.first(where: { $0.dayCount < requiredDayCount }) {
            return short
        }
        if let stale = healthy.filter({ target in
                target.generatedAt.map { now.timeIntervalSince($0) >= staleInterval } ?? true
            }).min(by: { lhs, rhs in
                (lhs.generatedAt ?? .distantPast) < (rhs.generatedAt ?? .distantPast)
            }) {
            return stale
        }
        return targets
            .filter(\.lastAttemptFailed)
            .min { lhs, rhs in
                (lhs.generatedAt ?? .distantPast) < (rhs.generatedAt ?? .distantPast)
            }
    }
}
