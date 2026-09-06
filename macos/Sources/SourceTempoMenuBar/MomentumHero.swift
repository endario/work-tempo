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
                readoutLabel: "Churn",
                help: "Trailing 30-day source churn, averaged per day"
            )

            Divider()
                .frame(height: 56)

            metric(
                value: snapshot.hasMomentum ? signed(snapshot.netGrowth) : "--",
                unit: "/ 30D",
                color: snapshot.netGrowth >= 0 ? TempoPalette.positive : TempoPalette.negative,
                trend: snapshot.recentNetGrowth,
                readoutLabel: "Net",
                help: "Net source LOC added over the trailing 30 closed days"
            )
        }
    }

    private func metric(
        value: String,
        unit: String,
        color: Color,
        trend: [Int],
        readoutLabel: String,
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
                    .foregroundStyle(.secondary)
            }
            HeroSparkline(
                values: trend,
                labels: snapshot.recentLabels,
                readoutLabel: readoutLabel,
                color: color
            )
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
    let labels: [String]
    let readoutLabel: String
    let color: Color

    @State private var hovered: Int?

    var body: some View {
        Chart {
            ForEach(points) { point in
                LineMark(
                    x: .value("Day", point.index),
                    y: .value("Value", point.value)
                )
                .foregroundStyle(color.opacity(0.9))
                .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            }

            if let hovered, points.indices.contains(hovered) {
                RuleMark(x: .value("Day", hovered))
                    .foregroundStyle(Color.primary.opacity(0.3))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 2]))
                PointMark(
                    x: .value("Day", hovered),
                    y: .value("Value", points[hovered].value)
                )
                .symbolSize(34)
                .foregroundStyle(color)
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartXScale(domain: -0.5...max(0.5, Double(points.count) - 0.5))
        .chartYScale(domain: domain)
        .chartOverlay { proxy in
            SparklineHoverLayer(
                proxy: proxy,
                count: points.count,
                hovered: $hovered,
                title: { labels.indices.contains($0) ? dayTitle(labels[$0]) : "Day \($0 + 1)" },
                rows: { index in
                    [HoverRow(
                        id: "value",
                        label: readoutLabel,
                        value: MetricFormatter.compact(values[index]),
                        color: color
                    )]
                }
            )
        }
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

private struct SparklineHoverLayer: View {
    let proxy: ChartProxy
    let count: Int
    @Binding var hovered: Int?
    let title: (Int) -> String
    let rows: (Int) -> [HoverRow]

    var body: some View {
        GeometryReader { geometry in
            Rectangle()
                .fill(.clear)
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    guard case let .active(point) = phase, count > 0,
                          let anchor = proxy.plotFrame else {
                        hovered = nil
                        return
                    }
                    let plot = geometry[anchor]
                    guard plot.contains(point),
                          let raw = proxy.value(atX: point.x - plot.minX, as: Double.self) else {
                        hovered = nil
                        return
                    }
                    hovered = min(count - 1, max(0, Int(raw.rounded())))
                }
                .overlay(alignment: .topLeading) {
                    if let hovered {
                        ChartReadout(title: title(hovered), rows: rows(hovered), compact: true)
                            .offset(x: readoutX(for: hovered, in: geometry), y: 1)
                    }
                }
        }
    }

    private func readoutX(for index: Int, in geometry: GeometryProxy) -> CGFloat {
        guard let anchor = proxy.plotFrame,
              let position = proxy.position(forX: Double(index)) else { return 0 }
        let cursor = geometry[anchor].minX + position
        let width = ChartReadout.compactWidth
        return min(max(0, cursor - width / 2), max(0, geometry.size.width - width))
    }
}
