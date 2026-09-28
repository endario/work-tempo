import Accessibility
import XCTest
@testable import WorkTempoCore
@testable import WorkTempoMenuBar

final class MonthlyChartDescriptorTests: XCTestCase {
    func testMonthlySeriesExposeActualAdditionsAndRemovals() {
        let descriptor = MonthlyChartDescriptor(timeline: timeline()).makeChartDescriptor()

        XCTAssertEqual(descriptor.series.compactMap(\.name), [
            "Code added", "Code removed", "Tests added", "Tests removed", "Docs added", "Docs removed",
        ])
        XCTAssertEqual(descriptor.xAxis.title, "Month")
        XCTAssertEqual(descriptor.series[0].dataPoints.map(category), ["2026-08", "2026-09"])
        XCTAssertEqual(descriptor.series.map { $0.dataPoints.map(number) }, [
            [2, 3], [5, 7], [11, 13], [17, 19], [23, 29], [31, 37],
        ])
        XCTAssertTrue(descriptor.series.allSatisfy { !$0.isContinuous })
        XCTAssertEqual(descriptor.series[0].dataPoints.last?.label, "To date")
        XCTAssertNil(descriptor.series[0].dataPoints.first?.label)
        XCTAssertTrue(descriptor.summary?.contains("below zero") == true)
    }

    func testRefreshReplacesAxesSeriesAndSummary() {
        let descriptor = MonthlyChartDescriptor(timeline: timeline()).makeChartDescriptor()
        let oldXAxis = descriptor.xAxis as AnyObject
        let oldYAxis = descriptor.yAxis as AnyObject
        let updated = ChartTimeline(
            labels: ["2027-01-01"], closedDayCount: 1, currentProgress: nil,
            codeLoc: [0], testLoc: [0], docLoc: [0],
            codeAdded: [41], testAdded: [43], codeDeleted: [47], testDeleted: [53],
            docAdded: [-59], docDeleted: [61]
        )

        MonthlyChartDescriptor(timeline: updated).updateChartDescriptor(descriptor)

        XCTAssertFalse((descriptor.xAxis as AnyObject) === oldXAxis)
        XCTAssertFalse((descriptor.yAxis as AnyObject) === oldYAxis)
        XCTAssertEqual(descriptor.series[0].dataPoints.map(category), ["2027-01"])
        XCTAssertEqual(descriptor.series[0].dataPoints.map(number), [41])
        XCTAssertEqual(descriptor.series[4].dataPoints.map(number), [-59])
        XCTAssertLessThanOrEqual(descriptor.yAxis?.range.lowerBound ?? 0, -59)
        XCTAssertFalse(descriptor.summary?.contains("counts are positive") == true)
        XCTAssertNil(descriptor.series[0].dataPoints.last?.label)
    }

    func testNegativeDocumentationIsNotDescribedAsPositive() {
        let malformed = ChartTimeline(
            labels: ["2026-09-01"], closedDayCount: 1, currentProgress: nil,
            codeLoc: [0], testLoc: [0], docLoc: [0],
            codeAdded: [1], testAdded: [2], codeDeleted: [3], testDeleted: [4],
            docAdded: [-5], docDeleted: [-7]
        )
        let descriptor = MonthlyChartDescriptor(timeline: malformed).makeChartDescriptor()

        XCTAssertEqual(descriptor.series[4].dataPoints.map(number), [-5])
        XCTAssertEqual(descriptor.series[5].dataPoints.map(number), [-7])
        XCTAssertFalse(descriptor.summary?.contains("counts are positive") == true)
    }

    private func timeline() -> ChartTimeline {
        ChartTimeline(
            labels: ["2026-08-31", "2026-09-01"], closedDayCount: 1, currentProgress: 0.5,
            codeLoc: [0, 0], testLoc: [0, 0], docLoc: [0, 0],
            codeAdded: [2, 3], testAdded: [11, 13], codeDeleted: [5, 7], testDeleted: [17, 19],
            docAdded: [23, 29], docDeleted: [31, 37]
        )
    }

    private func category(_ point: AXDataPoint) -> String {
        point.xValue.value(forKey: "category") as? String ?? ""
    }

    private func number(_ point: AXDataPoint) -> Double {
        point.yValue?.value(forKey: "number") as? Double ?? -1
    }
}
