import Accessibility
import XCTest
@testable import WorkTempoCore
@testable import WorkTempoMenuBar

final class SourceChartDescriptorTests: XCTestCase {
    func testDocumentationIsSpokenAsPositiveSeparateSeries() {
        let descriptor = SourceChartDescriptor(timeline: timeline(docs: [5, 6, 7])).makeChartDescriptor()

        XCTAssertEqual(descriptor.title, "Source lines over time")
        XCTAssertTrue(descriptor.summary?.contains("below") == true)
        XCTAssertEqual(descriptor.series.compactMap(\.name), ["Code", "Tests", "Docs (separate)"])
        XCTAssertEqual(descriptor.series[0].dataPoints.map(category), ["2026-08-01", "2026-08-02", "2026-08-03"])
        XCTAssertEqual(descriptor.series[0].dataPoints.map(number), [20, 22, 27])
        XCTAssertEqual(descriptor.series[1].dataPoints.map(number), [10, 10, 13])
        XCTAssertEqual(descriptor.series[2].dataPoints.map(number), [5, 6, 7])
        XCTAssertEqual(descriptor.series[2].dataPoints.last?.label, "To date")
    }

    func testUnexpectedNegativeDocumentationDoesNotClaimPositiveCounts() {
        let descriptor = SourceChartDescriptor(timeline: timeline(docs: [-5, -4, -3])).makeChartDescriptor()

        XCTAssertEqual(descriptor.series[2].dataPoints.map(number), [-5, -4, -3])
        XCTAssertLessThanOrEqual(descriptor.yAxis?.range.lowerBound ?? 0, -5)
        XCTAssertFalse(descriptor.summary?.contains("counts are positive") == true)
    }

    func testRefreshReplacesDescriptorValuesRatherThanLeavingCachedSeries() {
        let old = SourceChartDescriptor(timeline: timeline(docs: [5, 6, 7])).makeChartDescriptor()

        SourceChartDescriptor(timeline: timeline(docs: [8, 9, 10])).updateChartDescriptor(old)

        XCTAssertEqual(old.series[2].dataPoints.map(number), [8, 9, 10])
    }

    private func timeline(docs: [Int]) -> ChartTimeline {
        ChartTimeline(
            labels: ["2026-08-01", "2026-08-02", "2026-08-03"],
            closedDayCount: 2,
            currentProgress: 0.5,
            codeLoc: [20, 22, 27],
            testLoc: [10, 10, 13],
            docLoc: docs,
            codeAdded: [1, 1, 1],
            testAdded: [1, 1, 1],
            codeDeleted: [0, 0, 0],
            testDeleted: [0, 0, 0],
            docAdded: [0, 0, 0],
            docDeleted: [0, 0, 0]
        )
    }

    private func category(_ point: AXDataPoint) -> String {
        point.xValue.value(forKey: "category") as? String ?? ""
    }

    private func number(_ point: AXDataPoint) -> Double {
        point.yValue?.value(forKey: "number") as? Double ?? -1
    }
}
