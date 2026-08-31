import Foundation

public enum PaceState: Equatable, Sendable {
    case ready(share: Double)
    case insufficientHistory
    case newActivity
    case noRecentActivity
}

public struct TrendPoint: Identifiable, Equatable, Sendable {
    public var id: String { label }
    public let label: String
    public let code: Int
    public let test: Int
    public let docs: Int
}

public struct MomentumSummary: Equatable, Sendable {
    public let sourceLOC: Int
    public let codeLOC: Int
    public let testLOC: Int
    public let docsLOC: Int
    public let currentChurn: Int
    public let previousChurn: Int
    public let netGrowth: Int
    public let pace: PaceState
    public let trend: [TrendPoint]

    public init(report: ReportDocument) {
        sourceLOC = report.series.loc.last ?? 0
        codeLOC = report.series.locByKind.code.last ?? 0
        testLOC = report.series.locByKind.test.last ?? 0
        docsLOC = report.series.docLoc.last ?? 0

        let closedEnd = report.period.labels.last == report.generatedDate
            ? max(0, report.period.labels.count - 1)
            : report.period.labels.count
        let currentStart = max(0, closedEnd - 30)
        currentChurn = report.series.churn[currentStart..<closedEnd].reduce(0, +)
        netGrowth = zip(
            report.series.added[currentStart..<closedEnd],
            report.series.deleted[currentStart..<closedEnd]
        ).reduce(0) { $0 + $1.0 - $1.1 }

        if let range = report.closedDayRange {
            let midpoint = range.lowerBound + 30
            previousChurn = report.series.churn[range.lowerBound..<midpoint].reduce(0, +)
            let completeCurrent = report.series.churn[midpoint..<range.upperBound].reduce(0, +)
            if report.series.loc[range.lowerBound] == 0 {
                pace = .insufficientHistory
            } else if previousChurn == 0, completeCurrent == 0 {
                pace = .noRecentActivity
            } else if previousChurn == 0 {
                pace = .newActivity
            } else {
                pace = .ready(share: Double(completeCurrent) / Double(completeCurrent + previousChurn))
            }
        } else {
            previousChurn = 0
            pace = .insufficientHistory
        }

        let firstSourceIndex = report.series.loc.firstIndex(where: { $0 > 0 }) ?? report.series.loc.count
        trend = (firstSourceIndex..<report.period.labels.count).map { index in
            TrendPoint(
                label: report.period.labels[index],
                code: report.series.locByKind.code[index],
                test: report.series.locByKind.test[index],
                docs: report.series.docLoc[index]
            )
        }
    }
}

public enum MetricFormatter {
    public static func compact(_ value: Int) -> String {
        let absolute = abs(Double(value))
        let sign = value < 0 ? "-" : ""
        if absolute < 1_000 {
            return "\(value)"
        }
        if absolute < 1_000_000 {
            return sign + decimal(absolute / 1_000, places: absolute < 10_000 ? 1 : 0) + "K"
        }
        return sign + decimal(absolute / 1_000_000, places: absolute < 10_000_000 ? 2 : 1) + "M"
    }

    private static func decimal(_ value: Double, places: Int) -> String {
        var formatted = String(format: "%.*f", places, value)
        if formatted.contains(".") {
            while formatted.last == "0" { formatted.removeLast() }
            if formatted.last == "." { formatted.removeLast() }
        }
        return formatted
    }
}
