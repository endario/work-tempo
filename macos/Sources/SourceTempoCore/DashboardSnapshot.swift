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
    public let menuValue: String
    public let menuAccessibilityLabel: String
    public let metrics: [SnapshotMetric]
    public let currentChurn: Int
    public let previousChurn: Int
    public let netGrowth: Int
    public let paceShare: Double?
    public let paceLabel: String
    public let paceDetail: String
    public let paceAccessibilityLabel: String
    public let trend: [TrendPoint]

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

        guard let report else {
            dataState = errorMessage == nil ? .empty : .failedEmpty
            menuValue = "--"
            metrics = Self.emptyMetrics
            currentChurn = 0
            previousChurn = 0
            netGrowth = 0
            paceShare = nil
            paceLabel = isRefreshing ? "Collecting history" : "Awaiting first report"
            if isRefreshing {
                paceDetail = "First collection in progress"
            } else if workspace == nil {
                paceDetail = "Add a Git workspace to begin"
            } else {
                paceDetail = "No report available"
            }
            paceAccessibilityLabel = paceLabel
            trend = []
            let status = isRefreshing ? ", refreshing" : ""
            menuAccessibilityLabel = "SourceTempo, \(workspaceName), no report yet\(status)"
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

        menuValue = MetricFormatter.compact(summary.sourceLOC)
        metrics = [
            SnapshotMetric(id: "source", label: "SOURCE", value: MetricFormatter.compact(summary.sourceLOC)),
            SnapshotMetric(id: "code", label: "CODE", value: MetricFormatter.compact(summary.codeLOC)),
            SnapshotMetric(id: "tests", label: "TESTS", value: MetricFormatter.compact(summary.testLOC)),
            SnapshotMetric(id: "docs", label: "DOCS", value: MetricFormatter.compact(summary.docsLOC)),
        ]
        currentChurn = summary.currentChurn
        previousChurn = summary.previousChurn
        netGrowth = summary.netGrowth
        trend = summary.trend

        switch summary.pace {
        case let .ready(share):
            paceShare = share
            let percent = Int((share * 100).rounded())
            paceLabel = "\(percent)% recent share"
            paceDetail = "\(Self.decimal(summary.currentChurn)) current / \(Self.decimal(summary.previousChurn)) previous"
            paceAccessibilityLabel = "Recent 30-day churn \(Self.decimal(summary.currentChurn)), previous 30-day churn \(Self.decimal(summary.previousChurn)), \(percent) percent recent share"
        case .insufficientHistory:
            paceShare = nil
            paceLabel = "Building history"
            paceDetail = "60 closed days required"
            paceAccessibilityLabel = "Pace unavailable, 60 closed days required"
        case .newActivity:
            paceShare = nil
            paceLabel = "New activity"
            paceDetail = "\(Self.decimal(summary.currentChurn)) current / 0 previous"
            paceAccessibilityLabel = "New activity, recent 30-day churn \(Self.decimal(summary.currentChurn)), previous churn zero"
        case .noRecentActivity:
            paceShare = nil
            paceLabel = "No recent activity"
            paceDetail = "0 current / 0 previous"
            paceAccessibilityLabel = "No source churn in either 30-day period"
        }

        var menuStatus = ""
        if isRefreshing {
            menuStatus = ", refreshing"
        } else if dataState == .stale || dataState == .failedWithCache {
            menuStatus = ", stale"
        }
        menuAccessibilityLabel = "SourceTempo, \(workspaceName), \(Self.decimal(summary.sourceLOC)) source lines\(menuStatus)"
    }

    private static let emptyMetrics = [
        SnapshotMetric(id: "source", label: "SOURCE", value: "--"),
        SnapshotMetric(id: "code", label: "CODE", value: "--"),
        SnapshotMetric(id: "tests", label: "TESTS", value: "--"),
        SnapshotMetric(id: "docs", label: "DOCS", value: "--"),
    ]

    private static func decimal(_ value: Int) -> String {
        value.formatted(.number.grouping(.automatic))
    }

    private static func parseTimestamp(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}
