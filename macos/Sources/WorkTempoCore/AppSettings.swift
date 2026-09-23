import Foundation

public struct AppSettings: Codable, Equatable, Sendable {
    public var historyDays: Int
    public var headlineWindowDays: Int
    public var refreshCadenceSeconds: Int

    public init(historyDays: Int, headlineWindowDays: Int, refreshCadenceSeconds: Int) {
        self.historyDays = historyDays
        self.headlineWindowDays = headlineWindowDays
        self.refreshCadenceSeconds = refreshCadenceSeconds
    }

    // Six calendar months can span 184 days (March through August).
    public static let `default` = AppSettings(
        historyDays: 184, // Six consecutive calendar months can span 184 days (March through August).
        headlineWindowDays: 30,
        refreshCadenceSeconds: 3_600
    )
}

private enum AppSettingsBounds {
    static let historyDays = 30...365
    static let headlineWindowDaysFloor = 7
    static let refreshCadenceSeconds = 900...14_400
}

public extension AppSettings {
    private static let userDefaultsKey = "AppSettings"

    static func load(userDefaults: UserDefaults = .standard) -> AppSettings {
        guard let data = userDefaults.data(forKey: userDefaultsKey),
              let decoded = try? JSONDecoder().decode(AppSettings.self, from: data) else {
            return .default
        }
        return decoded.clamped()
    }

    func save(userDefaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        userDefaults.set(data, forKey: Self.userDefaultsKey)
    }

    private func clamped() -> AppSettings {
        let clampedHistory = historyDays.clamped(to: AppSettingsBounds.historyDays)
        // Clamp order matters: headline clamps against the already-clamped
        // history, or a hand-edited {historyDays: 0, headlineWindowDays: 90}
        // file could clamp headline into an empty range.
        let clampedHeadline = headlineWindowDays.clamped(
            to: AppSettingsBounds.headlineWindowDaysFloor...clampedHistory
        )
        let clampedCadence = refreshCadenceSeconds.clamped(to: AppSettingsBounds.refreshCadenceSeconds)
        return AppSettings(
            historyDays: clampedHistory,
            headlineWindowDays: clampedHeadline,
            refreshCadenceSeconds: clampedCadence
        )
    }
}

private extension Int {
    func clamped(to range: ClosedRange<Int>) -> Int {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
