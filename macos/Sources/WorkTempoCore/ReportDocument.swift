import Foundation

public enum ReportError: Error, Equatable, LocalizedError, Sendable {
    case unsupportedSchema(Int)
    case unsupportedPeriod(String)
    case invalidGeneratedAt(String)
    case duplicatePeriodLabel(String)
    case misalignedSeries(String)

    public var errorDescription: String? {
        switch self {
        case let .unsupportedSchema(version):
            "Unsupported WorkTempo report schema: \(version)"
        case let .unsupportedPeriod(period):
            "The menu app requires daily reports, not \(period)"
        case let .invalidGeneratedAt(value):
            "Invalid report generation date: \(value)"
        case let .duplicatePeriodLabel(label):
            "Report period contains a duplicate label: \(label)"
        case let .misalignedSeries(name):
            "Report series does not align with period labels: \(name)"
        }
    }
}

public struct ReportDocument: Decodable, Sendable {
    public let schemaVersion: Int
    public let generatedAt: String
    public let workspace: WorkspaceReport
    public let scope: ScopeReport
    public let period: PeriodReport
    public let series: MetricSeries
    public let timeline: TimelineReport

    public var generatedDate: String {
        String(generatedAt.prefix(10))
    }

    public static func decode(data: Data) throws -> ReportDocument {
        let document = try JSONDecoder().decode(ReportDocument.self, from: data)
        guard document.schemaVersion == 1 else {
            throw ReportError.unsupportedSchema(document.schemaVersion)
        }
        guard document.period.kind == "day" else {
            throw ReportError.unsupportedPeriod(document.period.kind)
        }
        guard document.generatedDate.count == 10,
              document.generatedDate[document.generatedDate.index(document.generatedDate.startIndex, offsetBy: 4)] == "-",
              document.generatedDate[document.generatedDate.index(document.generatedDate.startIndex, offsetBy: 7)] == "-"
        else {
            throw ReportError.invalidGeneratedAt(document.generatedAt)
        }
        try document.validateAlignment()
        return document
    }

    private func validateAlignment() throws {
        var seenLabels = Set<String>()
        if let duplicate = period.labels.first(where: { !seenLabels.insert($0).inserted }) {
            throw ReportError.duplicatePeriodLabel(duplicate)
        }
        let count = period.labels.count
        let aligned: [(String, Int)] = [
            ("loc", series.loc.count),
            ("docLoc", series.docLoc.count),
            ("churn", series.churn.count),
            ("docChurn", series.docChurn.count),
            ("added", series.added.count),
            ("deleted", series.deleted.count),
            ("locByKind.code", series.locByKind.code.count),
            ("locByKind.test", series.locByKind.test.count),
            ("churnByKind.code", series.churnByKind.code.count),
            ("churnByKind.test", series.churnByKind.test.count),
            ("addedByKind.code", series.addedByKind.code.count),
            ("addedByKind.test", series.addedByKind.test.count),
            ("deletedByKind.code", series.deletedByKind.code.count),
            ("deletedByKind.test", series.deletedByKind.test.count),
        ]
        let optionalAligned = [
            series.docAdded.map { ("docAdded", $0.count) },
            series.docDeleted.map { ("docDeleted", $0.count) },
        ].compactMap { $0 }
        let languageAligned = series.language.map { ("language.\($0.language)", $0.values.count) }
        if let mismatch = (aligned + optionalAligned + languageAligned).first(where: { $0.1 != count }) {
            throw ReportError.misalignedSeries(mismatch.0)
        }
    }
}

public struct ScopeReport: Decodable, Sendable {
    public let repositories: [RepositoryReport]
}

public struct RepositoryReport: Decodable, Sendable {
    public let label: String
    public let path: String
    public let commit: String?
}

public struct WorkspaceReport: Decodable, Sendable {
    public let root: String
    public let title: String
    public let timezone: String
    public let timezoneAbbreviation: String
}

public struct PeriodReport: Decodable, Sendable {
    public let kind: String
    public let labels: [String]
}

public struct MetricSeries: Decodable, Sendable {
    public let loc: [Int]
    public let docLoc: [Int]
    public let churn: [Int]
    public let docChurn: [Int]
    public let docAdded: [Int]?
    public let docDeleted: [Int]?
    public let added: [Int]
    public let deleted: [Int]
    public let locByKind: KindSeries
    public let churnByKind: KindSeries
    public let addedByKind: KindSeries
    public let deletedByKind: KindSeries
    public let language: [LanguageSeries]
}

public struct KindSeries: Decodable, Sendable {
    public let code: [Int]
    public let test: [Int]
}

public struct LanguageSeries: Decodable, Sendable {
    public let language: String
    public let values: [Int]
}

public struct TimelineReport: Decodable, Sendable {
    public let currentIndex: Int?
    public let currentProgress: Double
}
