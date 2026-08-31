import SourceTempoCore
import SwiftUI

struct MenuBarLabel: View {
    let snapshot: DashboardSnapshot

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: snapshot.isRefreshing ? "arrow.trianglehead.2.clockwise.rotate.90" : "metronome")
            Text(snapshot.menuValue)
                .monospacedDigit()
            if snapshot.dataState == .stale || snapshot.dataState == .failedWithCache {
                Image(systemName: "exclamationmark.circle.fill")
                    .imageScale(.small)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(snapshot.menuAccessibilityLabel)
    }
}
