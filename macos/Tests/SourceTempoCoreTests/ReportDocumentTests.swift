import XCTest
@testable import SourceTempoCore

final class ReportDocumentTests: XCTestCase {
    func testDecodesSchemaVersionOneDailyReport() throws {
        let report = try ReportDocument.decode(data: makeReportData())

        XCTAssertEqual(report.workspace.title, "Fixture")
        XCTAssertEqual(report.workspace.root, "/tmp/fixture")
        XCTAssertEqual(report.period.labels.count, 61)
        XCTAssertEqual(report.series.loc.last, 220)
        XCTAssertEqual(report.series.locByKind.code.last, 140)
        XCTAssertEqual(report.series.locByKind.test.last, 80)
        XCTAssertEqual(report.scope.repositories.map(\.path), ["/tmp/fixture"])
        XCTAssertEqual(report.timeline.currentProgress, 0.5)
        XCTAssertEqual(report.series.addedByKind.code.count, 61)
        XCTAssertEqual(report.series.deletedByKind.test.count, 61)
        XCTAssertEqual(report.series.docAdded?.count, 61)
        XCTAssertEqual(report.series.docDeleted?.count, 61)
        XCTAssertEqual(Set(report.series.language.map(\.language)), ["Swift", "Test"])
    }

    func testRejectsMisalignedDetailedSeries() throws {
        let names = ["addedByKind.code", "deletedByKind.test", "language.Swift"]
        for name in names {
            var object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: makeReportData()) as? [String: Any]
            )
            var series = try XCTUnwrap(object["series"] as? [String: Any])
            if name == "language.Swift" {
                var languages = try XCTUnwrap(series["language"] as? [[String: Any]])
                let index = try XCTUnwrap(languages.firstIndex { $0["language"] as? String == "Swift" })
                languages[index]["values"] = [1]
                series["language"] = languages
            } else {
                let parts = name.split(separator: ".").map(String.init)
                var kind = try XCTUnwrap(series[parts[0]] as? [String: Any])
                kind[parts[1]] = [1]
                series[parts[0]] = kind
            }
            object["series"] = series

            XCTAssertThrowsError(try ReportDocument.decode(
                data: JSONSerialization.data(withJSONObject: object)
            )) { error in
                XCTAssertEqual(error as? ReportError, .misalignedSeries(name))
            }
        }
    }

    func testLegacyReportWithoutDocumentationDirectionsStillDecodes() throws {
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: makeReportData()) as? [String: Any]
        )
        var series = try XCTUnwrap(object["series"] as? [String: Any])
        series.removeValue(forKey: "docAdded")
        series.removeValue(forKey: "docDeleted")
        object["series"] = series

        let report = try ReportDocument.decode(
            data: JSONSerialization.data(withJSONObject: object)
        )

        XCTAssertNil(report.series.docAdded)
        XCTAssertNil(report.series.docDeleted)
    }

    func testRejectsMisalignedDocumentationDirections() throws {
        for name in ["docAdded", "docDeleted"] {
            var object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: makeReportData()) as? [String: Any]
            )
            var series = try XCTUnwrap(object["series"] as? [String: Any])
            series[name] = [1]
            object["series"] = series

            XCTAssertThrowsError(try ReportDocument.decode(
                data: JSONSerialization.data(withJSONObject: object)
            )) { error in
                XCTAssertEqual(error as? ReportError, .misalignedSeries(name))
            }
        }
    }

    func testRejectsUnsupportedSchemaVersion() throws {
        XCTAssertThrowsError(try ReportDocument.decode(data: makeReportData(schemaVersion: 2))) { error in
            XCTAssertEqual(error as? ReportError, .unsupportedSchema(2))
        }
    }

    func testRejectsDuplicatePeriodLabels() throws {
        let data = try JSONSerialization.jsonObject(with: makeReportData()) as! [String: Any]
        var document = data
        var period = document["period"] as! [String: Any]
        var labels = period["labels"] as! [String]
        labels[1] = labels[0]
        period["labels"] = labels
        document["period"] = period

        XCTAssertThrowsError(try ReportDocument.decode(
            data: JSONSerialization.data(withJSONObject: document)
        )) { error in
            XCTAssertEqual(error as? ReportError, .duplicatePeriodLabel(labels[0]))
        }
    }

    func testRejectsNonDailyReportAndMisalignedSeries() throws {
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: makeReportData()) as? [String: Any]
        )
        object["period"] = ["kind": "month", "labels": ["2026-08"]]
        let monthly = try JSONSerialization.data(withJSONObject: object)
        XCTAssertThrowsError(try ReportDocument.decode(data: monthly)) { error in
            XCTAssertEqual(error as? ReportError, .unsupportedPeriod("month"))
        }

        object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: makeReportData()) as? [String: Any]
        )
        var series = try XCTUnwrap(object["series"] as? [String: Any])
        series["loc"] = [1]
        object["series"] = series
        let misaligned = try JSONSerialization.data(withJSONObject: object)
        XCTAssertThrowsError(try ReportDocument.decode(data: misaligned)) { error in
            XCTAssertEqual(error as? ReportError, .misalignedSeries("loc"))
        }
    }
}
