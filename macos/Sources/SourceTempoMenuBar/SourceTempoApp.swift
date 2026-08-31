import AppKit
import SourceTempoCore
import SwiftUI

@main
struct SourceTempoApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            DashboardView(
                model: model,
                onRefresh: {},
                onAdd: {},
                onRemove: {},
                onQuit: { NSApplication.shared.terminate(nil) }
            )
        } label: {
            MenuBarLabel(snapshot: model.snapshot)
        }
        .menuBarExtraStyle(.window)
    }
}
