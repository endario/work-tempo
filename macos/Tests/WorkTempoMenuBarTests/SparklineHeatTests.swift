import XCTest
@testable import WorkTempoMenuBar

final class SparklineHeatTests: XCTestCase {
    // The fill turns from cold to warm at this fraction of its height, so it has
    // to be where the average line is drawn or the colours misreport the days.
    func testTurnsAtTheAverageBetweenTheFloorAndThePeak() {
        XCTAssertEqual(SparklineHeat.averageFraction(average: 25, floor: 0, peak: 100), 0.25, accuracy: 1e-9)
        XCTAssertEqual(SparklineHeat.averageFraction(average: 60, floor: 20, peak: 100), 0.5, accuracy: 1e-9)
    }

    func testStaysInsideTheFillWhenTheAverageIsOutsideIt() {
        XCTAssertEqual(SparklineHeat.averageFraction(average: -5, floor: 0, peak: 10), 0)
        XCTAssertEqual(SparklineHeat.averageFraction(average: 50, floor: 0, peak: 10), 1)
    }

    func testAFlatSeriesHasNothingToTurnOn() {
        XCTAssertEqual(SparklineHeat.averageFraction(average: 7, floor: 0, peak: 0), 0.5)
    }
}
