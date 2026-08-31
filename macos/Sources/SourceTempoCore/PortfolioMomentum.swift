import Foundation

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

public struct LanguageTimeline: Equatable, Sendable {
    public let language: String
    public let values: [Int]
}

public struct ChartTimeline: Equatable, Sendable {
    public let labels: [String]
    public let closedDayCount: Int
    public let currentProgress: Double?
    public let languages: [LanguageTimeline]
    public let docLoc: [Int]
    public let codeAdded: [Int]
    public let testAdded: [Int]
    public let codeDeleted: [Int]
    public let testDeleted: [Int]
    public let docChurn: [Int]
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

        var repositoryOwners: [String: String] = [:]
        for (workspace, report) in contributors {
            for repository in report.scope.repositories {
                if let owner = repositoryOwners[repository.path], owner != workspace.displayName {
                    return .failure(.overlappingRepository(
                        path: repository.path,
                        first: owner,
                        second: workspace.displayName
                    ))
                }
                repositoryOwners[repository.path] = workspace.displayName
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
                historyState: .extending(current: 0, required: 90)
            ))
        }

        let commonClosed = commonClosedLabels(contributors.map(\.1))
        let momentumLabels = Array(commonClosed.suffix(min(90, commonClosed.count)))
        let momentumInput = makeMomentumInput(reports: contributors.map(\.1), labels: momentumLabels)
        let aligned = momentumLabels.count >= 30
            ? AlignedMomentum(input: momentumInput, summary: MomentumSummary(input: momentumInput))
            : nil
        let chart = commonClosed.count >= 90
            ? makeChart(reports: contributors.map(\.1), closedLabels: Array(commonClosed.suffix(90)))
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
            historyState: chart == nil
                ? .extending(current: commonClosed.count, required: 90)
                : .ready
        ))
    }

    public static func chart(for report: ReportDocument) -> ChartTimeline? {
        let closed = closedLabels(report)
        guard closed.count >= 90 else { return nil }
        return makeChart(reports: [report], closedLabels: Array(closed.suffix(90)))
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

        let languageNames = Set(reports.flatMap { $0.series.language.map(\.language) })
        let languages = languageNames.map { language in
            LanguageTimeline(
                language: language,
                values: sum(reports, labels: labels) { report in
                    report.series.language.first(where: { $0.language == language })?.values
                        ?? Array(repeating: 0, count: report.period.labels.count)
                }
            )
        }.sorted {
            ($0.values.last ?? 0, $0.language) > ($1.values.last ?? 0, $1.language)
        }

        return ChartTimeline(
            labels: labels,
            closedDayCount: closedLabels.count,
            currentProgress: hasSharedOpenDay ? reports.map { $0.timeline.currentProgress }.min() : nil,
            languages: languages,
            docLoc: sum(reports, labels: labels) { $0.series.docLoc },
            codeAdded: sum(reports, labels: labels) { $0.series.addedByKind.code },
            testAdded: sum(reports, labels: labels) { $0.series.addedByKind.test },
            codeDeleted: sum(reports, labels: labels) { $0.series.deletedByKind.code },
            testDeleted: sum(reports, labels: labels) { $0.series.deletedByKind.test },
            docChurn: sum(reports, labels: labels) { $0.series.docChurn }
        )
    }

    private static func sum(
        _ reports: [ReportDocument],
        labels: [String],
        values: (ReportDocument) -> [Int]
    ) -> [Int] {
        var result = Array(repeating: 0, count: labels.count)
        for report in reports {
            let indexes = Dictionary(uniqueKeysWithValues: report.period.labels.enumerated().map { ($0.element, $0.offset) })
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
