import Foundation

func makeReportData(
    schemaVersion: Int = 1,
    dayCount: Int = 61,
    generatedDate: String = "2026-08-31",
    loc: [Int]? = nil,
    code: [Int]? = nil,
    test: [Int]? = nil,
    docs: [Int]? = nil,
    churn: [Int]? = nil,
    added: [Int]? = nil,
    deleted: [Int]? = nil,
    repositoryPaths: [String] = ["/tmp/fixture"],
    timezone: String = "+08 (+08:00)",
    languages: [String: [Int]]? = nil
) throws -> Data {
    let calendar = Calendar(identifier: .gregorian)
    let formatter = DateFormatter()
    formatter.calendar = calendar
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyy-MM-dd"
    let end = formatter.date(from: "2026-08-31")!
    let labels = (0..<dayCount).map { offset in
        formatter.string(from: calendar.date(byAdding: .day, value: offset - dayCount + 1, to: end)!)
    }

    func values(_ supplied: [Int]?, default value: Int) -> [Int] {
        supplied ?? Array(repeating: value, count: dayCount)
    }

    let locValues = values(loc, default: 220)
    let codeValues = values(code, default: 140)
    let testValues = values(test, default: 80)
    let docValues = values(docs, default: 50)
    let churnValues = values(churn, default: 0)
    let addedValues = values(added, default: 0)
    let deletedValues = values(deleted, default: 0)

    let document: [String: Any] = [
        "schemaVersion": schemaVersion,
        "generatedAt": "\(generatedDate)T12:00:00+08:00",
        "workspace": [
            "root": "/tmp/fixture",
            "title": "Fixture",
            "timezone": timezone,
            "timezoneAbbreviation": "+08",
        ],
        "scope": [
            "includeVendor": false,
            "includeNonProduct": false,
            "repositories": repositoryPaths.enumerated().map { index, path in
                ["label": "repo-\(index)", "path": path, "commit": "commit-\(index)"]
            },
            "skipped": [
                "vendor_like": [],
                "non_product": [],
                "unavailable_submodule": [],
                "unavailable_extra": [],
            ],
        ],
        "period": ["kind": "day", "labels": labels],
        "timeline": ["currentIndex": dayCount - 1, "currentProgress": 0.5],
        "series": [
            "loc": locValues,
            "docLoc": docValues,
            "churn": churnValues,
            "docChurn": values(nil, default: 9_999),
            "added": addedValues,
            "deleted": deletedValues,
            "locByKind": ["code": codeValues, "test": testValues],
            "churnByKind": ["code": churnValues, "test": values(nil, default: 0)],
            "addedByKind": ["code": addedValues, "test": values(nil, default: 0)],
            "deletedByKind": ["code": deletedValues, "test": values(nil, default: 0)],
            "language": (languages ?? ["Swift": codeValues, "Test": testValues]).map {
                ["language": $0.key, "values": $0.value]
            },
        ],
    ]
    return try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
}
