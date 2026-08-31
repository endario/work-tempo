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
    }

    func testRejectsUnsupportedSchemaVersion() throws {
        XCTAssertThrowsError(try ReportDocument.decode(data: makeReportData(schemaVersion: 2))) { error in
            XCTAssertEqual(error as? ReportError, .unsupportedSchema(2))
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
