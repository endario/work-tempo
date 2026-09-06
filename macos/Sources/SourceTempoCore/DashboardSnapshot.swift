import Foundation

public enum SnapshotRefreshState: Equatable, Sendable {
    case idle
    case refreshing
    case failed(String)
}

public enum SnapshotDataState: Equatable, Sendable {
    case empty
    case ready
    case stale
    case failedWithCache
    case failedEmpty
}

public struct SnapshotMetric: Identifiable, Equatable, Sendable {
    public let id: String
    public let label: String
    public let value: String

    public init(id: String, label: String, value: String) {
        self.id = id
        self.label = label
        self.value = value
    }
}

public struct DashboardSnapshot: Equatable, Sendable {
    public let workspaceName: String
    public let workspacePath: String?
    public let reportGeneratedAt: Date?
    public let dataState: SnapshotDataState
    public let isRefreshing: Bool
    public let errorMessage: String?
    public let noticeMessage: String?
    public let menuValue: String
    public let menuAccessibilityLabel: String
    public let metrics: [SnapshotMetric]
    public let hasMomentum: Bool
    public let dailyChurn: Double
    public let netGrowth: Int
    public let recentChurn: [Int]
    public let recentNetGrowth: [Int]
    public let recentLabels: [String]
    public let recentAdded: [Int]
    public let recentDeleted: [Int]
    public let chartTimeline: ChartTimeline?
    public let historyMessage: String?

    public init(
        workspace: Workspace?,
        report: ReportDocument?,
        refreshState: SnapshotRefreshState,
        now: Date,
        staleInterval: TimeInterval = 3_600
    ) {
        workspaceName = report?.workspace.title ?? workspace?.displayName ?? "No workspace"
        workspacePath = workspace?.root.path
        reportGeneratedAt = report.flatMap { Self.parseTimestamp($0.generatedAt) }
        isRefreshing = refreshState == .refreshing
        if case let .failed(message) = refreshState {
            errorMessage = message
        } else {
            errorMessage = nil
        }
        noticeMessage = nil

        guard let report else {
            dataState = errorMessage == nil ? .empty : .failedEmpty
            menuValue = "--"
            metrics = Self.emptyMetrics
            hasMomentum = false
            dailyChurn = 0
            netGrowth = 0
            recentChurn = []
            recentNetGrowth = []
            recentLabels = []
            recentAdded = []
            recentDeleted = []
            chartTimeline = nil
            historyMessage = nil
            let status = isRefreshing ? ", refreshing" : ""
            menuAccessibilityLabel = "Source Tempo, \(workspaceName), no report yet\(status)"
            return
        }

        let summary = MomentumSummary(report: report)
        let stale = reportGeneratedAt.map { now.timeIntervalSince($0) > staleInterval } ?? true
        if errorMessage != nil {
            dataState = .failedWithCache
        } else if stale {
            dataState = .stale
        } else {
            dataState = .ready
        }

        menuValue = MetricFormatter.compact(summary.dailyChurn) + "/d"
        metrics = [
            SnapshotMetric(id: "source", label: "SOURCE", value: MetricFormatter.compact(summary.sourceLOC)),
            SnapshotMetric(id: "code", label: "CODE", value: MetricFormatter.compact(summary.codeLOC)),
            SnapshotMetric(id: "tests", label: "TESTS", value: MetricFormatter.compact(summary.testLOC)),
            SnapshotMetric(id: "docs", label: "DOCS", value: MetricFormatter.compact(summary.docsLOC)),
        ]
        hasMomentum = true
        dailyChurn = summary.dailyChurn
        netGrowth = summary.netGrowth
        recentChurn = summary.recentChurn
        recentNetGrowth = summary.recentNetGrowth
        recentLabels = summary.recentLabels
        recentAdded = summary.recentAdded
        recentDeleted = summary.recentDeleted
        chartTimeline = PortfolioMomentum.chart(for: report)
        historyMessage = chartTimeline == nil
            ? "Extending history to \(HistoryWindow.chartClosedDays) days"
            : nil

        var menuStatus = ""
        if isRefreshing {
            menuStatus = ", refreshing"
        } else if dataState == .stale || dataState == .failedWithCache {
            menuStatus = ", stale"
        }
        menuAccessibilityLabel = "Source Tempo, \(workspaceName), \(MetricFormatter.compact(summary.dailyChurn)) source lines changed per day\(menuStatus)"
    }

    public init(
        portfolio: PortfolioMomentum,
        refreshState: SnapshotRefreshState,
        now: Date
    ) {
        workspaceName = "All Workspaces"
        workspacePath = nil
        reportGeneratedAt = portfolio.generatedAt.flatMap(Self.parseTimestamp)
        isRefreshing = refreshState == .refreshing
        if case let .failed(message) = refreshState {
            errorMessage = message
            noticeMessage = nil
        } else {
            errorMessage = nil
            noticeMessage = portfolio.warning
        }

        let summary = portfolio.momentum?.summary
        let stale = reportGeneratedAt.map { now.timeIntervalSince($0) > 86_400 } ?? true
        if case .failed = refreshState, portfolio.contributorCount > 0 {
            dataState = .failedWithCache
        } else if portfolio.contributorCount == 0 {
            dataState = errorMessage == nil ? .empty : .failedEmpty
        } else if stale {
            dataState = .stale
        } else {
            dataState = .ready
        }

        menuValue = summary.map { MetricFormatter.compact($0.dailyChurn) + "/d" } ?? "--"
        metrics = portfolio.contributorCount == 0 ? Self.emptyMetrics : [
            SnapshotMetric(id: "source", label: "SOURCE", value: MetricFormatter.compact(portfolio.totals.source)),
            SnapshotMetric(id: "code", label: "CODE", value: MetricFormatter.compact(portfolio.totals.code)),
            SnapshotMetric(id: "tests", label: "TESTS", value: MetricFormatter.compact(portfolio.totals.test)),
            SnapshotMetric(id: "docs", label: "DOCS", value: MetricFormatter.compact(portfolio.totals.docs)),
        ]
        hasMomentum = summary != nil
        dailyChurn = summary?.dailyChurn ?? 0
        netGrowth = summary?.netGrowth ?? 0
        recentChurn = summary?.recentChurn ?? []
        recentNetGrowth = summary?.recentNetGrowth ?? []
        recentLabels = summary?.recentLabels ?? []
        recentAdded = summary?.recentAdded ?? []
        recentDeleted = summary?.recentDeleted ?? []
        chartTimeline = portfolio.chart
        if case let .extending(current, required) = portfolio.historyState {
            historyMessage = "Extending history · \(current) of \(required) closed days"
        } else {
            historyMessage = nil
        }

        var menuStatus = ""
        if isRefreshing {
            menuStatus = ", refreshing"
        } else if dataState == .stale || dataState == .failedWithCache {
            menuStatus = ", stale"
        }
        menuAccessibilityLabel = "Source Tempo, all workspaces, \(menuValue) source churn\(menuStatus)"
    }

    private static let emptyMetrics = [
        SnapshotMetric(id: "source", label: "SOURCE", value: "--"),
        SnapshotMetric(id: "code", label: "CODE", value: "--"),
        SnapshotMetric(id: "tests", label: "TESTS", value: "--"),
        SnapshotMetric(id: "docs", label: "DOCS", value: "--"),
    ]

    private static func parseTimestamp(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}
