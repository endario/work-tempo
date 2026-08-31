#if DEBUG
import AppKit
import SwiftUI

@MainActor
final class DebugPreviewDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard ProcessInfo.processInfo.environment["SOURCE_TEMPO_PREVIEW"] == "1" else { return }
        if ProcessInfo.processInfo.environment["SOURCE_TEMPO_DARK_PREVIEW"] == "1" {
            NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        }

        let model = AppModel()
        let view = DashboardView(
            model: model,
            onRefresh: { model.toggleRefresh() },
            onAdd: { model.chooseWorkspace() },
            onRemove: { model.removeSelectedWorkspace() },
            onQuit: { NSApplication.shared.terminate(nil) }
        )
        let controller = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: controller)
        window.title = "Source Tempo Preview"
        window.styleMask = [.titled, .closable]
        window.setContentSize(NSSize(width: 430, height: 565))
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        self.window = window
    }
}
#endif
