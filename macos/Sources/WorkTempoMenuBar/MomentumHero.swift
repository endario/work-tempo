import Charts
import WorkTempoCore
import SwiftUI

struct MomentumHero: View {
    let snapshot: DashboardSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(Self.headlineContext(windowDays: snapshot.windowDays, isAvailable: snapshot.hasMomentum))
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)

            HStack(alignment: .top, spacing: 14) {
                metric(
                    title: "SOURCE CHURN",
                    value: snapshot.hasMomentum ? MetricFormatter.compact(snapshot.dailyChurn) : "--",
                    unit: "LINES / DAY",
                    weight: .bold,
                    color: TempoPalette.source,
                    trend: snapshot.recentChurn + (snapshot.openDay.map { [$0.churn] } ?? []),
                    readout: { index in
                        let added = self.added(at: index)
                        let removed = self.removed(at: index)
                        return [
                            HoverRow(id: "churn", label: "Churn", value: MetricFormatter.compact(added + removed), isTotal: true),
                            HoverRow(id: "added", label: "Added", value: MetricFormatter.compact(added), separated: true),
                            HoverRow(id: "removed", label: "Removed", value: MetricFormatter.compact(removed)),
                        ]
                    },
                    help: "Code and test lines added plus removed per day, over the last \(snapshot.windowDays) closed days. Documentation is counted separately."
                )

                Divider()
                    .frame(height: 70)

                metric(
                    title: "NET SOURCE CHANGE",
                    value: snapshot.hasMomentum ? signed(snapshot.netGrowth) : "--",
                    unit: "LINES",
                    weight: .medium,
                    color: .secondary,
                    trend: runningNet,
                    readout: { index in
                        let added = self.added(at: index)
                        let removed = self.removed(at: index)
                        return [
                            HoverRow(id: "day", label: "Net", value: signed(added - removed), isTotal: true),
                            HoverRow(id: "added", label: "Added", value: MetricFormatter.compact(added), separated: true),
                            HoverRow(id: "removed", label: "Removed", value: MetricFormatter.compact(removed)),
                            HoverRow(id: "running", label: "Running", value: signed(self.runningNet[index]), isTotal: true, separated: true),
                        ]
                    },
                    help: "Code and test lines added minus removed over the last \(snapshot.windowDays) closed days. Documentation is counted separately."
                )
            }
        }
    }

    nonisolated static func headlineContext(windowDays: Int, isAvailable: Bool) -> String {
        isAvailable ? "LAST \(windowDays) CLOSED DAYS" : "HEADLINE UNAVAILABLE"
    }

    private func metric(
        title: String,
        value: String,
        unit: String,
        weight: Font.Weight,
        color: Color,
        trend: [Int],
        readout: @escaping (Int) -> [HoverRow],
        help: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(value)
                    .font(.system(size: 30, weight: weight, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
                    .layoutPriority(1)
                    .foregroundStyle(color)
                Text(unit)
                    .font(.caption2.weight(.semibold))
                    .fixedSize(horizontal: true, vertical: false)
                    .foregroundStyle(.secondary)
            }
            // What the figure means belongs to the figure. Over the plot the
            // pointer already gets that day's values, and two tooltips at once
            // is one too many.
            .help(help)
            HeroSparkline(
                values: trend,
                labels: dayLabels,
                openIndex: openIndex,
                readout: readout,
                color: color
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), \(value) \(unit). \(help)")
    }

    /// The open day extends both sparklines by one point. It stays out of the
    /// headline figures above them, which count closed days only.
    private var openIndex: Int? {
        snapshot.openDay == nil ? nil : snapshot.recentChurn.count
    }

    private var runningNet: [Int] {
        guard let open = snapshot.openDay, let last = snapshot.recentNetGrowth.last else {
            return snapshot.recentNetGrowth
        }
        return snapshot.recentNetGrowth + [last + open.net]
    }

    private var dayLabels: [String] {
        snapshot.recentLabels + (snapshot.openDay.map { [$0.label] } ?? [])
    }

    private func added(at index: Int) -> Int {
        index == openIndex ? (snapshot.openDay?.added ?? 0) : snapshot.recentAdded[index]
    }

    private func removed(at index: Int) -> Int {
        index == openIndex ? (snapshot.openDay?.deleted ?? 0) : snapshot.recentDeleted[index]
    }

    private func signed(_ value: Int) -> String {
        value > 0 ? "+\(MetricFormatter.compact(value))" : MetricFormatter.compact(value)
    }
}

private struct HeroSparkline: View {
    let values: [Int]
    let labels: [String]
    let openIndex: Int?
    let readout: (Int) -> [HoverRow]
    let color: Color

    @State private var hovered: ChartHoverPoint?

    var body: some View {
        Chart {
            ForEach(closedPoints) { point in
                LineMark(
                    x: .value("Day", point.index),
                    y: .value("Value", point.value),
                    series: .value("Part", "closed")
                )
                .foregroundStyle(color.opacity(0.9))
                .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            }

            // Today is real but partial, so it trails off rather than reading as
            // a finished day beside the closed ones.
            ForEach(openPoints) { point in
                LineMark(
                    x: .value("Day", point.index),
                    y: .value("Value", point.value),
                    series: .value("Part", "open")
                )
                .foregroundStyle(color.opacity(0.42))
                .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [2.5, 2]))
            }

            if let hovered, points.indices.contains(hovered.index) {
                RuleMark(x: .value("Day", hovered.index))
                    .foregroundStyle(Color.primary.opacity(0.3))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 2]))
                PointMark(
                    x: .value("Day", hovered.index),
                    y: .value("Value", points[hovered.index].value)
                )
                .symbolSize(34)
                .foregroundStyle(hovered.index == openIndex ? color.opacity(0.55) : color)
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
                title: title,
                rows: readout
            )
        }
        .frame(height: 24)
        .accessibilityHidden(true)
    }

    private var points: [HeroTrendPoint] {
        values.enumerated().map { HeroTrendPoint(index: $0.offset, value: $0.element) }
    }

    private var closedPoints: [HeroTrendPoint] {
        guard let openIndex else { return points }
        return points.filter { $0.index < openIndex }
    }

    private var openPoints: [HeroTrendPoint] {
        guard let openIndex, openIndex > 0, points.indices.contains(openIndex) else { return [] }
        return [points[openIndex - 1], points[openIndex]]
    }

    private func title(_ index: Int) -> String {
        guard labels.indices.contains(index) else { return "Day \(index + 1)" }
        return dayTitle(labels[index]) + (index == openIndex ? " \u{00B7} TO DATE" : "")
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
    @Binding var hovered: ChartHoverPoint?
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
                    hovered = ChartHoverPoint(
                        index: min(count - 1, max(0, Int(raw.rounded()))),
                        cursorX: point.x
                    )
                }
                .overlay(alignment: .topLeading) {
                    if let hovered {
                        let card = ChartReadout(title: title(hovered.index), rows: rows(hovered.index))
                        card.offset(
                            x: ChartReadout.placement(
                                besideCursor: hovered.cursorX,
                                width: card.width,
                                within: geometry.size.width
                            ),
                            // The sparkline is only 24 points tall, so the card
                            // hangs below it rather than under the pointer.
                            y: geometry.size.height + 6
                        )
                    }
                }
        }
    }

}
