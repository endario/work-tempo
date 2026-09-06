import Foundation

public enum HistoryWindow {
    // Six consecutive calendar months can span 184 days (March through August).
    public static let chartClosedDays = 184
    public static let collectorDays = chartClosedDays + 1
}

public enum PortfolioError: Error, Equatable, LocalizedError, Sendable {
    case overlappingRepository(path: String, first: String, second: String)
    case mixedTimezones([String])

    public var errorDescription: String? {
        switch self {
        case let .overlappingRepository(path, first, second):
            "Repository is counted by both \(first) and \(second): \(path)"
        case let .mixedTimezones(timezones):
            "Refresh workspaces under one timezone before combining: \(timezones.joined(separator: ", "))"
        }
    }
}

public struct PortfolioTotals: Equatable, Sendable {
    public let source: Int
    public let code: Int
    public let test: Int
    public let docs: Int
}

public enum PortfolioHistoryState: Equatable, Sendable {
    case ready
    case extending(current: Int, required: Int)
}

public struct AlignedMomentum: Equatable, Sendable {
    public let input: MomentumInput
    public let summary: MomentumSummary
}

public struct ChartTimeline: Equatable, Sendable {
    public let labels: [String]
    public let closedDayCount: Int
    public let currentProgress: Double?
    public let codeLoc: [Int]
    public let testLoc: [Int]
    public let docLoc: [Int]
    public let codeAdded: [Int]
    public let testAdded: [Int]
    public let codeDeleted: [Int]
    public let testDeleted: [Int]
    public let docAdded: [Int]
    public let docDeleted: [Int]
}

public struct MonthlyChurnPoint: Equatable, Sendable {
    public let label: String
    public let codeAdded: Int
    public let testAdded: Int
    public let codeDeleted: Int
    public let testDeleted: Int
    public let docAdded: Int
    public let docDeleted: Int
    public let currentProgress: Double?
}

public extension ChartTimeline {
    var monthlyChurn: [MonthlyChurnPoint] {
        var accumulators: [MonthAccumulator] = []
        for index in labels.indices {
            let month = String(labels[index].prefix(7))
            if accumulators.last?.label != month {
                accumulators.append(MonthAccumulator(label: month))
            }
            let last = accumulators.count - 1
            accumulators[last].codeAdded += codeAdded[index]
            accumulators[last].testAdded += testAdded[index]
            accumulators[last].codeDeleted += codeDeleted[index]
            accumulators[last].testDeleted += testDeleted[index]
            accumulators[last].docAdded += docAdded[index]
            accumulators[last].docDeleted += docDeleted[index]
        }

        var result = Array(accumulators.suffix(6)).map { item in
            MonthlyChurnPoint(
                label: item.label,
                codeAdded: item.codeAdded,
                testAdded: item.testAdded,
                codeDeleted: item.codeDeleted,
                testDeleted: item.testDeleted,
                docAdded: item.docAdded,
                docDeleted: item.docDeleted,
                currentProgress: nil
            )
        }
        guard currentProgress != nil,
              let label = labels.last,
              let progress = currentMonthProgress(label: label),
              !result.isEmpty else { return result }
        let current = result.removeLast()
        result.append(MonthlyChurnPoint(
            label: current.label,
            codeAdded: current.codeAdded,
            testAdded: current.testAdded,
            codeDeleted: current.codeDeleted,
            testDeleted: current.testDeleted,
            docAdded: current.docAdded,
            docDeleted: current.docDeleted,
            currentProgress: progress
        ))
        return result
    }

    /// The open day is drawn short of its own slot, at the fraction of the day
    /// that has elapsed, so a chart never shows a partial day as a whole one.
    func pointPosition(at index: Int) -> Double {
        guard index == labels.count - 1, index > 0, let currentProgress else { return Double(index) }
        return Double(index - 1) + currentProgress
    }

    /// Rounding the x coordinate would skip the open day whenever it is drawn
    /// more than half a slot short, so pick the nearest drawn point instead.
    func nearestPointIndex(toX x: Double) -> Int? {
        labels.indices.min { abs(pointPosition(at: $0) - x) < abs(pointPosition(at: $1) - x) }
    }

    private func currentMonthProgress(label: String) -> Double? {
        let parts = label.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, let currentProgress else { return nil }
        let days = daysInMonth(year: parts[0], month: parts[1])
        return min(1, (Double(parts[2] - 1) + currentProgress) / Double(days))
    }
}

private struct MonthAccumulator {
    let label: String
    var codeAdded = 0
    var testAdded = 0
    var codeDeleted = 0
    var testDeleted = 0
    var docAdded = 0
    var docDeleted = 0
}

private func daysInMonth(year: Int, month: Int) -> Int {
    switch month {
    case 4, 6, 9, 11: 30
    case 2: (year.isMultiple(of: 400) || (year.isMultiple(of: 4) && !year.isMultiple(of: 100))) ? 29 : 28
    default: 31
    }
}

public struct PortfolioMomentum: Equatable, Sendable {
    public let contributorCount: Int
    public let trackedCount: Int
    public let totals: PortfolioTotals
    public let watermark: String?
    public let generatedAt: String?
    public let warning: String?
    public let momentum: AlignedMomentum?
    public let chart: ChartTimeline?
    public let historyState: PortfolioHistoryState

    public static func build(
        workspaces: [Workspace],
        reports: [Workspace: ReportDocument]
    ) -> Result<PortfolioMomentum, PortfolioError> {
        let contributors = workspaces.compactMap { workspace in
            reports[workspace].map { (workspace, $0) }
        }

        var repositoryOwners: [String: Workspace] = [:]
        for (workspace, report) in contributors {
            for repository in report.scope.repositories {
                if let owner = repositoryOwners[repository.path], owner != workspace {
                    return .failure(.overlappingRepository(
                        path: repository.path,
                        first: owner.root.path,
                        second: workspace.root.path
                    ))
                }
                repositoryOwners[repository.path] = workspace
            }
        }

        let timezones = Set(contributors.map { $0.1.workspace.timezone }).sorted()
        if timezones.count > 1 {
            return .failure(.mixedTimezones(timezones))
        }

        let totals = PortfolioTotals(
            source: contributors.reduce(0) { $0 + ($1.1.series.loc.last ?? 0) },
            code: contributors.reduce(0) { $0 + ($1.1.series.locByKind.code.last ?? 0) },
            test: contributors.reduce(0) { $0 + ($1.1.series.locByKind.test.last ?? 0) },
            docs: contributors.reduce(0) { $0 + ($1.1.series.docLoc.last ?? 0) }
        )
        let warning = contributors.count == workspaces.count
            ? nil
            : "\(contributors.count) of \(workspaces.count) workspaces contributing"

        guard !contributors.isEmpty else {
            return .success(PortfolioMomentum(
                contributorCount: 0,
                trackedCount: workspaces.count,
                totals: totals,
                watermark: nil,
                generatedAt: nil,
                warning: warning,
                momentum: nil,
                chart: nil,
                historyState: .extending(current: 0, required: HistoryWindow.chartClosedDays)
            ))
        }

        let commonClosed = commonClosedLabels(contributors.map(\.1))
        let momentumLabels = Array(commonClosed.suffix(min(30, commonClosed.count)))
        let momentumInput = makeMomentumInput(reports: contributors.map(\.1), labels: momentumLabels)
        let aligned = momentumLabels.count >= 30
            ? AlignedMomentum(input: momentumInput, summary: MomentumSummary(input: momentumInput))
            : nil
        let chart = commonClosed.count >= 2
            ? makeChart(
                reports: contributors.map(\.1),
                closedLabels: Array(commonClosed.suffix(min(HistoryWindow.chartClosedDays, commonClosed.count)))
            )
            : nil

        return .success(PortfolioMomentum(
            contributorCount: contributors.count,
            trackedCount: workspaces.count,
            totals: totals,
            watermark: commonClosed.last,
            generatedAt: contributors.map { $0.1.generatedAt }.min(),
            warning: warning,
            momentum: aligned,
            chart: chart,
            historyState: commonClosed.count >= HistoryWindow.chartClosedDays
                ? .ready
                : .extending(current: commonClosed.count, required: HistoryWindow.chartClosedDays)
        ))
    }

    public static func chart(for report: ReportDocument) -> ChartTimeline? {
        let closed = closedLabels(report)
        guard closed.count >= 2 else { return nil }
        return makeChart(
            reports: [report],
            closedLabels: Array(closed.suffix(min(HistoryWindow.chartClosedDays, closed.count)))
        )
    }

    private static func commonClosedLabels(_ reports: [ReportDocument]) -> [String] {
        guard let first = reports.first else { return [] }
        let common = reports.dropFirst().reduce(Set(closedLabels(first))) { partial, report in
            partial.intersection(closedLabels(report))
        }
        return common.sorted()
    }

    private static func closedLabels(_ report: ReportDocument) -> [String] {
        if report.period.labels.last == report.generatedDate {
            return Array(report.period.labels.dropLast())
        }
        return report.period.labels
    }

    private static func makeMomentumInput(
        reports: [ReportDocument],
        labels: [String]
    ) -> MomentumInput {
        MomentumInput(
            labels: labels,
            generatedDate: "",
            loc: sum(reports, labels: labels) { $0.series.loc },
            docLoc: sum(reports, labels: labels) { $0.series.docLoc },
            codeLoc: sum(reports, labels: labels) { $0.series.locByKind.code },
            testLoc: sum(reports, labels: labels) { $0.series.locByKind.test },
            churn: sum(reports, labels: labels) { $0.series.churn },
            added: sum(reports, labels: labels) { $0.series.added },
            deleted: sum(reports, labels: labels) { $0.series.deleted }
        )
    }

    private static func makeChart(
        reports: [ReportDocument],
        closedLabels: [String]
    ) -> ChartTimeline {
        var labels = closedLabels
        let openLabel = reports.first?.period.labels.last
        let hasSharedOpenDay = openLabel != nil && reports.allSatisfy {
            $0.period.labels.last == openLabel && $0.generatedDate == openLabel
        }
        if hasSharedOpenDay, let openLabel {
            labels.append(openLabel)
        }

        return ChartTimeline(
            labels: labels,
            closedDayCount: closedLabels.count,
            currentProgress: hasSharedOpenDay ? reports.map { $0.timeline.currentProgress }.min() : nil,
            codeLoc: sum(reports, labels: labels) { $0.series.locByKind.code },
            testLoc: sum(reports, labels: labels) { $0.series.locByKind.test },
            docLoc: sum(reports, labels: labels) { $0.series.docLoc },
            codeAdded: sum(reports, labels: labels) { $0.series.addedByKind.code },
            testAdded: sum(reports, labels: labels) { $0.series.addedByKind.test },
            codeDeleted: sum(reports, labels: labels) { $0.series.deletedByKind.code },
            testDeleted: sum(reports, labels: labels) { $0.series.deletedByKind.test },
            docAdded: sum(reports, labels: labels) {
                $0.series.docAdded ?? Array(repeating: 0, count: $0.period.labels.count)
            },
            docDeleted: sum(reports, labels: labels) {
                $0.series.docDeleted ?? Array(repeating: 0, count: $0.period.labels.count)
            }
        )
    }

    private static func sum(
        _ reports: [ReportDocument],
        labels: [String],
        values: (ReportDocument) -> [Int]
    ) -> [Int] {
        var result = Array(repeating: 0, count: labels.count)
        for report in reports {
            let indexes = Dictionary(
                report.period.labels.enumerated().map { ($0.element, $0.offset) },
                uniquingKeysWith: { first, _ in first }
            )
            let series = values(report)
            for (outputIndex, label) in labels.enumerated() {
                if let inputIndex = indexes[label] {
                    result[outputIndex] += series[inputIndex]
                }
            }
        }
        return result
    }
}
