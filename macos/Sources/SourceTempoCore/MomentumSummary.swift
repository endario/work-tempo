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
}

public struct MomentumInput: Equatable, Sendable {
    public let labels: [String]
    public let generatedDate: String
    public let loc: [Int]
    public let docLoc: [Int]
    public let codeLoc: [Int]
    public let testLoc: [Int]
    public let churn: [Int]
    public let added: [Int]
    public let deleted: [Int]

    public init(
        labels: [String],
        generatedDate: String,
        loc: [Int],
        docLoc: [Int],
        codeLoc: [Int],
        testLoc: [Int],
        churn: [Int],
        added: [Int],
        deleted: [Int]
    ) {
        self.labels = labels
        self.generatedDate = generatedDate
        self.loc = loc
        self.docLoc = docLoc
        self.codeLoc = codeLoc
        self.testLoc = testLoc
        self.churn = churn
        self.added = added
        self.deleted = deleted
    }

    public init(report: ReportDocument) {
        self.init(
            labels: report.period.labels,
            generatedDate: report.generatedDate,
            loc: report.series.loc,
            docLoc: report.series.docLoc,
            codeLoc: report.series.locByKind.code,
            testLoc: report.series.locByKind.test,
            churn: report.series.churn,
            added: report.series.added,
            deleted: report.series.deleted
        )
    }
}

public struct MomentumSummary: Equatable, Sendable {
    public let sourceLOC: Int
    public let codeLOC: Int
    public let testLOC: Int
    public let docsLOC: Int
    public let currentChurn: Int
    public let dailyChurn: Double
    public let previousChurn: Int
    public let netGrowth: Int
    public let pace: PaceState
    public let trend: [TrendPoint]

    public init(report: ReportDocument) {
        self.init(input: MomentumInput(report: report))
    }

    public init(input: MomentumInput) {
        sourceLOC = input.loc.last ?? 0
        codeLOC = input.codeLoc.last ?? 0
        testLOC = input.testLoc.last ?? 0
        docsLOC = input.docLoc.last ?? 0

        let closedEnd = input.labels.last == input.generatedDate
            ? max(0, input.labels.count - 1)
            : input.labels.count
        let currentStart = max(0, closedEnd - 30)
        currentChurn = input.churn[currentStart..<closedEnd].reduce(0, +)
        dailyChurn = Double(currentChurn) / 30.0
        netGrowth = zip(
            input.added[currentStart..<closedEnd],
            input.deleted[currentStart..<closedEnd]
        ).reduce(0) { $0 + $1.0 - $1.1 }

        if closedEnd >= 60 {
            let range = (closedEnd - 60)..<closedEnd
            let midpoint = range.lowerBound + 30
            previousChurn = input.churn[range.lowerBound..<midpoint].reduce(0, +)
            let completeCurrent = input.churn[midpoint..<range.upperBound].reduce(0, +)
            if previousChurn == 0, completeCurrent == 0 {
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

        let firstSourceIndex = input.loc.firstIndex(where: { $0 > 0 }) ?? input.loc.count
        trend = (firstSourceIndex..<input.labels.count).map { index in
            TrendPoint(
                label: input.labels[index],
                code: input.codeLoc[index],
                test: input.testLoc[index]
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
