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

    public static let `default` = AppSettings(
        historyDays: 184, // Six consecutive calendar months can span 184 days (March through August).
        headlineWindowDays: 30,
        refreshCadenceSeconds: 3_600
    )
}
