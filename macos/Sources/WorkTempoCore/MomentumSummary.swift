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
    public let codeAdded: [Int]
    public let testAdded: [Int]
    public let codeDeleted: [Int]
    public let testDeleted: [Int]
    public let docAdded: [Int]
    public let docDeleted: [Int]

    public init(
        labels: [String],
        generatedDate: String,
        loc: [Int],
        docLoc: [Int],
        codeLoc: [Int],
        testLoc: [Int],
        churn: [Int],
        added: [Int],
        deleted: [Int],
        codeAdded: [Int],
        testAdded: [Int],
        codeDeleted: [Int],
        testDeleted: [Int],
        docAdded: [Int],
        docDeleted: [Int]
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
        self.codeAdded = codeAdded
        self.testAdded = testAdded
        self.codeDeleted = codeDeleted
        self.testDeleted = testDeleted
        self.docAdded = docAdded
        self.docDeleted = docDeleted
    }

    public init(report: ReportDocument) {
        let days = report.period.labels.count
        self.init(
            labels: report.period.labels,
            generatedDate: report.generatedDate,
            loc: report.series.loc,
            docLoc: report.series.docLoc,
            codeLoc: report.series.locByKind.code,
            testLoc: report.series.locByKind.test,
            churn: report.series.churn,
            added: report.series.added,
            deleted: report.series.deleted,
            codeAdded: report.series.addedByKind.code,
            testAdded: report.series.addedByKind.test,
            codeDeleted: report.series.deletedByKind.code,
            testDeleted: report.series.deletedByKind.test,
            docAdded: report.series.docAdded ?? Array(repeating: 0, count: days),
            docDeleted: report.series.docDeleted ?? Array(repeating: 0, count: days)
        )
    }
}

public struct ChurnTotals: Equatable, Sendable {
    public let added: Int
    public let deleted: Int

    public init(added: Int, deleted: Int) {
        self.added = added
        self.deleted = deleted
    }

    public var churn: Int { added + deleted }
    public var net: Int { added - deleted }

    static func + (lhs: ChurnTotals, rhs: ChurnTotals) -> ChurnTotals {
        ChurnTotals(added: lhs.added + rhs.added, deleted: lhs.deleted + rhs.deleted)
    }
}

/// What the headline window added and removed, by kind. Source is code plus
/// tests; documentation is counted separately and never enters it.
public struct WindowBreakdown: Equatable, Sendable {
    public let code: ChurnTotals
    public let tests: ChurnTotals
    public let docs: ChurnTotals

    public init(code: ChurnTotals, tests: ChurnTotals, docs: ChurnTotals) {
        self.code = code
        self.tests = tests
        self.docs = docs
    }

    public var source: ChurnTotals { code + tests }

    static func + (lhs: WindowBreakdown, rhs: WindowBreakdown) -> WindowBreakdown {
        WindowBreakdown(code: lhs.code + rhs.code, tests: lhs.tests + rhs.tests, docs: lhs.docs + rhs.docs)
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
    public let breakdown: WindowBreakdown
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

        func total(_ added: [Int], _ deleted: [Int]) -> ChurnTotals {
            ChurnTotals(
                added: added[currentStart..<closedEnd].reduce(0, +),
                deleted: deleted[currentStart..<closedEnd].reduce(0, +)
            )
        }
        breakdown = WindowBreakdown(
            code: total(input.codeAdded, input.codeDeleted),
            tests: total(input.testAdded, input.testDeleted),
            docs: total(input.docAdded, input.docDeleted)
        )
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
