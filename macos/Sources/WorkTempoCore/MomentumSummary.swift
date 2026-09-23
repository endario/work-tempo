import Foundation

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
    public let netGrowth: Int
    public let recentChurn: [Int]
    public let recentNetGrowth: [Int]
    public let recentLabels: [String]
    public let recentAdded: [Int]
    public let recentDeleted: [Int]
    public let windowDays: Int

    public init(report: ReportDocument, maxWindowDays: Int) {
        self.init(input: MomentumInput(report: report), maxWindowDays: maxWindowDays)
    }

    public init(input: MomentumInput, maxWindowDays: Int) {
        sourceLOC = input.loc.last ?? 0
        codeLOC = input.codeLoc.last ?? 0
        testLOC = input.testLoc.last ?? 0
        docsLOC = input.docLoc.last ?? 0

        let closedEnd = input.labels.last == input.generatedDate
            ? max(0, input.labels.count - 1)
            : input.labels.count
        // Churn as well as lines: a first day that adds source and deletes it
        // again ends at zero LOC but is a day the workspace was worked on.
        let firstTrackedDay = (0..<closedEnd).first { input.loc[$0] > 0 || input.churn[$0] > 0 } ?? 0
        let currentStart = max(firstTrackedDay, max(0, closedEnd - maxWindowDays))
        windowDays = max(1, closedEnd - currentStart)
        recentChurn = Array(input.churn[currentStart..<closedEnd])
        recentLabels = Array(input.labels[currentStart..<closedEnd])
        recentAdded = Array(input.added[currentStart..<closedEnd])
        recentDeleted = Array(input.deleted[currentStart..<closedEnd])
        currentChurn = recentChurn.reduce(0, +)
        dailyChurn = Double(currentChurn) / Double(windowDays)
        var cumulativeGrowth = 0
        recentNetGrowth = zip(
            input.added[currentStart..<closedEnd],
            input.deleted[currentStart..<closedEnd]
        ).map { added, deleted in
            cumulativeGrowth += added - deleted
            return cumulativeGrowth
        }
        netGrowth = recentNetGrowth.last ?? 0

    }
}

public enum MetricFormatter {
    public static func compact(_ value: Double) -> String {
        if value != 0, abs(value) < 10, value.rounded() != value {
            return decimal(value, places: 1)
        }
        return compact(Int(value.rounded()))
    }

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
