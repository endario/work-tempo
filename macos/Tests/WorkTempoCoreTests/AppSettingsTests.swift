import XCTest
@testable import WorkTempoCore

final class AppSettingsTests: XCTestCase {
    func testDefaultValues() {
        XCTAssertEqual(AppSettings.default.historyDays, 365)
        XCTAssertEqual(AppSettings.default.headlineWindowDays, 30)
        XCTAssertEqual(AppSettings.default.refreshCadenceSeconds, 3_600)
        XCTAssertEqual(HistoryWindow(historyDays: AppSettings.default.historyDays).collectorDays, 366)
    }

    private func makeIsolatedDefaults() -> UserDefaults {
        let suiteName = "AppSettingsTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        addTeardownBlock { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }
        return defaults
    }

    func testRoundTripsThroughUserDefaults() {
        let defaults = makeIsolatedDefaults()
        let saved = AppSettings(historyDays: 90, headlineWindowDays: 14, refreshCadenceSeconds: 1_800)

        saved.save(userDefaults: defaults)
        let loaded = AppSettings.load(userDefaults: defaults)

        XCTAssertEqual(loaded, saved)
    }

    func testMissingKeyFallsBackToDefault() {
        let defaults = makeIsolatedDefaults()

        XCTAssertEqual(AppSettings.load(userDefaults: defaults), .default)
    }

    func testCorruptDataFallsBackToDefault() {
        let defaults = makeIsolatedDefaults()
        defaults.set(Data("not json".utf8), forKey: "AppSettings")

        XCTAssertEqual(AppSettings.load(userDefaults: defaults), .default)
    }

    func testLoadClampsAllThreeFieldsToBounds() {
        let defaults = makeIsolatedDefaults()
        let outOfRange = AppSettings(historyDays: 1, headlineWindowDays: 999, refreshCadenceSeconds: 1)
        outOfRange.save(userDefaults: defaults)

        let loaded = AppSettings.load(userDefaults: defaults)

        XCTAssertEqual(loaded.historyDays, 30, "historyDays floors at 30")
        XCTAssertEqual(loaded.headlineWindowDays, 30, "999 clamps against the already-clamped historyDays of 30, not a fixed ceiling — headlineWindowDays has no static upper bound")
        XCTAssertEqual(loaded.refreshCadenceSeconds, 900, "refreshCadenceSeconds floors at 900 (15 minutes)")
    }

    func testLoadClampsHistoryDaysToUpperBound() {
        let defaults = makeIsolatedDefaults()
        let outOfRange = AppSettings(historyDays: 999, headlineWindowDays: 30, refreshCadenceSeconds: 3_600)
        outOfRange.save(userDefaults: defaults)

        let loaded = AppSettings.load(userDefaults: defaults)

        XCTAssertEqual(loaded.historyDays, 730, "historyDays ceilings at 730")
    }

    func testHeadlineClampsAgainstPostClampHistoryNotRawHistory() {
        let defaults = makeIsolatedDefaults()
        // A hand-edited file with historyDays below the floor and a headline
        // that would be valid against the raw value but not the clamped one.
        let outOfRange = AppSettings(historyDays: 10, headlineWindowDays: 20, refreshCadenceSeconds: 3_600)
        outOfRange.save(userDefaults: defaults)

        let loaded = AppSettings.load(userDefaults: defaults)

        XCTAssertEqual(loaded.historyDays, 30)
        XCTAssertEqual(loaded.headlineWindowDays, 20, "20 is valid against the clamped historyDays of 30")
    }
}
