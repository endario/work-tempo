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

    public init(staleInterval: TimeInterval, requiredDayCount: Int) {
        self.staleInterval = staleInterval
        self.requiredDayCount = requiredDayCount
    }

    public init(settings: AppSettings) {
        self.init(
            staleInterval: TimeInterval(settings.refreshCadenceSeconds),
            requiredDayCount: HistoryWindow(historyDays: settings.historyDays).collectorDays
        )
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
        // A workspace that can never fill the window (dayCount < required)
        // would otherwise be reselected unconditionally, forever. Floored at
        // today's fixed hourly rate regardless of a lower configured
        // cadence: a naive `>= staleInterval` gate has no effect on its own,
        // since the timer already ticks at exactly that interval.
        let shortFloor = max(staleInterval, 3_600)
        if let short = healthy.first(where: { target in
            target.dayCount < requiredDayCount
                && (target.generatedAt.map { now.timeIntervalSince($0) >= shortFloor } ?? true)
        }) {
            return short
        }
        // Short targets are excluded here, not just gated by the floor
        // above: this filter runs over every healthy target regardless of
        // dayCount, so without this exclusion a short-but-old-enough-by-
        // staleInterval-alone workspace would still be picked up through
        // this branch — bypassing the floor entirely, since request()'s own
        // timeout choice keys off dayCount < requiredDayCount independent of
        // which branch made the selection.
        if let stale = healthy.filter({ target in
                target.dayCount >= requiredDayCount
                    && (target.generatedAt.map { now.timeIntervalSince($0) >= staleInterval } ?? true)
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
