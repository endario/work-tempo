import Charts
import SourceTempoCore
import SwiftUI

struct MomentumHero: View {
    let snapshot: DashboardSnapshot

    var body: some View {
        HStack(spacing: 14) {
            metric(
                value: snapshot.hasMomentum ? MetricFormatter.compact(snapshot.dailyChurn) : "--",
                unit: "/ DAY",
                color: TempoPalette.source,
                trend: snapshot.recentChurn,
                help: "Trailing 30-day source churn, averaged per day"
            )

            Divider()
                .frame(height: 56)

            metric(
                value: snapshot.hasMomentum ? signed(snapshot.netGrowth) : "--",
                unit: "/ 30D",
                color: snapshot.netGrowth >= 0 ? TempoPalette.positive : TempoPalette.negative,
                trend: snapshot.recentNetGrowth,
                help: "Net source LOC added over the trailing 30 closed days"
            )
        }
    }

    private func metric(
        value: String,
        unit: String,
        color: Color,
        trend: [Int],
        help: String
    ) -> some View {
        VStack(spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(value)
                    .font(.system(size: 25, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(color)
                Text(unit)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(color.opacity(0.78))
            }
            HeroSparkline(values: trend, color: color)
        }
        .frame(maxWidth: .infinity)
        .help(help)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(value) \(help)")
    }

    private func signed(_ value: Int) -> String {
        value > 0 ? "+\(MetricFormatter.compact(value))" : MetricFormatter.compact(value)
    }
}

private struct HeroSparkline: View {
    let values: [Int]
    let color: Color

    var body: some View {
        Chart(points) { point in
            LineMark(
                x: .value("Day", point.index),
                y: .value("Value", point.value)
            )
            .foregroundStyle(color.opacity(0.9))
            .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartYScale(domain: domain)
        .frame(height: 24)
        .accessibilityHidden(true)
    }

    private var points: [HeroTrendPoint] {
        values.enumerated().map { HeroTrendPoint(index: $0.offset, value: $0.element) }
    }

    private var domain: ClosedRange<Double> {
        let minimum = min(0, values.min() ?? 0)
        let maximum = max(0, values.max() ?? 0)
        let span = max(1, maximum - minimum)
        return Double(minimum) - Double(span) * 0.08...Double(maximum) + Double(span) * 0.08
    }
}

private struct HeroTrendPoint: Identifiable {
    var id: Int { index }
    let index: Int
    let value: Int
}
