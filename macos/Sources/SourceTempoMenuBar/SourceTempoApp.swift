import AppKit
import SourceTempoCore
import SwiftUI

@main
struct SourceTempoApp: App {
    @StateObject private var model = AppModel()
#if DEBUG
    @NSApplicationDelegateAdaptor(DebugPreviewDelegate.self) private var previewDelegate
#endif

    var body: some Scene {
        MenuBarExtra {
            DashboardView(
                model: model,
                onRefresh: { model.toggleRefresh() },
                onAdd: { model.chooseWorkspace() },
                onRemove: { model.removeSelectedWorkspace() },
                onQuit: { NSApplication.shared.terminate(nil) }
            )
        } label: {
            MenuBarLabel(snapshot: model.snapshot)
        }
        .menuBarExtraStyle(.window)
    }
}
