import WorkTempoCore
import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @State private var historyDays: Int
    @State private var headlineWindowDays: Int
    @State private var refreshCadenceSeconds: Int

    private static let headlineWindowOptions = [7, 14, 30, 60, 90]

    init(model: AppModel) {
        self.model = model
        _historyDays = State(initialValue: model.settings.historyDays)
        _headlineWindowDays = State(initialValue: model.settings.headlineWindowDays)
        _refreshCadenceSeconds = State(initialValue: model.settings.refreshCadenceSeconds)
    }

    private var headlineOptions: [Int] {
        Self.headlineWindowOptions.filter { $0 <= historyDays }
    }

    private var refreshCadenceLabel: String {
        switch refreshCadenceSeconds {
        case 900: "15 minutes"
        case 1_800: "30 minutes"
        case 3_600: "1 hour"
        case 7_200: "2 hours"
        case 14_400: "4 hours"
        default: "\(refreshCadenceSeconds / 60) minutes"
        }
    }

    var body: some View {
        Form {
            Section {
                Picker("History", selection: $historyDays) {
                    Text("1 month (30d)").tag(30)
                    Text("3 months (90d)").tag(90)
                    Text("6 months (184d)").tag(184)
                    Text("12 months (365d)").tag(365)
                }
                .onChange(of: historyDays) { _, newValue in
                    if headlineWindowDays > newValue {
                        headlineWindowDays = Self.headlineWindowOptions
                            .filter { $0 <= newValue }
                            .last ?? Self.headlineWindowOptions[0]
                    }
                }
                Text("How far back Work Tempo collects and charts.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("Headline window", selection: $headlineWindowDays) {
                    ForEach(headlineOptions, id: \.self) { days in
                        Text("\(days)d").tag(days)
                    }
                }
                Text("The rolling window behind the churn/day and net growth hero metrics.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("Refresh cadence", selection: $refreshCadenceSeconds) {
                    Text("15 minutes").tag(900)
                    Text("30 minutes").tag(1_800)
                    Text("1 hour").tag(3_600)
                    Text("2 hours").tag(7_200)
                    Text("4 hours").tag(14_400)
                }
                Text("Checks about every \(refreshCadenceLabel) in the background — Work Tempo also refreshes on launch and when your Mac wakes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button("Restore Defaults") {
                    historyDays = AppSettings.default.historyDays
                    headlineWindowDays = AppSettings.default.headlineWindowDays
                    refreshCadenceSeconds = AppSettings.default.refreshCadenceSeconds
                }
                Spacer()
                Button("Save") {
                    model.applySettings(AppSettings(
                        historyDays: historyDays,
                        headlineWindowDays: headlineWindowDays,
                        refreshCadenceSeconds: refreshCadenceSeconds
                    ))
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 360)
    }
}
