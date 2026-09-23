import XCTest
@testable import WorkTempoCore

final class AppSettingsTests: XCTestCase {
    func testDefaultReproducesTodaysHardcodedValues() {
        XCTAssertEqual(AppSettings.default.historyDays, 184)
        XCTAssertEqual(AppSettings.default.headlineWindowDays, 30)
        XCTAssertEqual(AppSettings.default.refreshCadenceSeconds, 3_600)
        XCTAssertEqual(HistoryWindow(historyDays: AppSettings.default.historyDays).collectorDays, 185)
    }
}
