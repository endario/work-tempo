import SourceTempoCore
import SwiftUI

struct PaceGauge: View {
    let snapshot: DashboardSnapshot

    private var gaugeValue: Double {
        snapshot.paceShare ?? (snapshot.currentChurn > 0 ? 1 : 0)
    }

    var body: some View {
        HStack(spacing: 18) {
            ZStack {
                Circle()
                    .stroke(Color.secondary.opacity(0.16), lineWidth: 10)
                Circle()
                    .trim(from: 0, to: max(0, min(gaugeValue, 1)))
                    .stroke(gaugeColor, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                VStack(spacing: 1) {
                    Text(snapshot.paceShare.map { "\(Int(($0 * 100).rounded()))%" } ?? "--")
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                        .monospacedDigit()
                    Text("PACE")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 108, height: 108)

            VStack(alignment: .leading, spacing: 7) {
                Text(snapshot.paceLabel)
                    .font(.title3.weight(.semibold))
                Text(snapshot.paceDetail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Divider()
                HStack(spacing: 6) {
                    Image(systemName: snapshot.netGrowth >= 0 ? "arrow.up.right" : "arrow.down.right")
                    Text("\(signed(snapshot.netGrowth)) net source LOC")
                        .monospacedDigit()
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(snapshot.netGrowth >= 0 ? Color.green : Color.red)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(snapshot.paceAccessibilityLabel)
    }

    private var gaugeColor: Color {
        guard let share = snapshot.paceShare else { return .secondary }
        if share > 0.52 { return .green }
        if share < 0.48 { return .orange }
        return .blue
    }

    private func signed(_ value: Int) -> String {
        value > 0 ? "+\(MetricFormatter.compact(value))" : MetricFormatter.compact(value)
    }
}
