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
                    title: "Source churn",
                    value: snapshot.hasMomentum ? MetricFormatter.oneDecimal(snapshot.dailyChurn) : "--",
                    unit: "LINES / DAY",
                    weight: .bold,
                    color: TempoPalette.source,
                    trend: snapshot.recentChurn,
                    readout: { index in
                        let added = snapshot.recentAdded[index]
                        let removed = snapshot.recentDeleted[index]
                        return [
                            HoverRow(id: "churn", label: "Churn", value: MetricFormatter.compact(added + removed), isTotal: true),
                            HoverRow(id: "added", label: "Added", value: MetricFormatter.compact(added), separated: true),
                            HoverRow(id: "removed", label: "Removed", value: MetricFormatter.compact(removed)),
                        ]
                    },
                    help: "Code and test lines added plus removed per day, averaged over the last \(snapshot.windowDays) days including today. Documentation is counted separately."
                )

                Divider()

                netChange
            }
        }
    }

    private var netChange: some View {
        VStack(alignment: .leading, spacing: 2) {
            figure(
                title: "Total source churn",
                value: snapshot.hasMomentum ? MetricFormatter.compact(snapshot.windowBreakdown?.source.churn ?? 0) : "--",
                unit: "LINES",
                weight: .medium,
                color: .secondary,
                help: "Code and test lines added plus removed over the last \(snapshot.windowDays) days including today. Documentation is counted separately, so it is bracketed."
            )
            ReadoutTable(valueWidth: 50, rows: Self.changeRows(snapshot.hasMomentum ? snapshot.windowBreakdown : nil))
                .padding(.top, 5)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// What the total above is made of. Documentation stays outside it.
    static func changeRows(_ breakdown: WindowBreakdown?) -> [HoverRow] {
        func row(_ id: String, _ label: String, _ totals: ChurnTotals?, _ swatches: [Color], brackets: Bool = false) -> HoverRow {
            let figures = totals.map { ["+" + MetricFormatter.compact($0.added), "\u{2212}" + MetricFormatter.compact($0.deleted)] }
                ?? ["--", "--"]
            return HoverRow(
                id: id,
                label: label,
                values: brackets && totals != nil ? figures.map { "(\($0))" } : figures,
                swatches: swatches
            )
        }
        return [
            row("code", "Code", breakdown?.code, [TempoPalette.codeAdded, TempoPalette.codeDeleted]),
            row("tests", "Tests", breakdown?.tests, [TempoPalette.testAdded, TempoPalette.testDeleted]),
            row("docs", "Docs", breakdown?.docs, [TempoPalette.docsAdded, TempoPalette.docsDeleted], brackets: true),
        ]
    }

    nonisolated static func headlineContext(windowDays: Int, isAvailable: Bool) -> String {
        isAvailable ? "SOURCE CHURN (LAST \(windowDays) DAYS)" : "HEADLINE UNAVAILABLE"
    }

    private func figure(
        title: String,
        value: String,
        unit: String,
        weight: Font.Weight,
        color: Color,
        help: String
    ) -> some View {
        // The headline above names both figures, so the title is only spoken.
        VStack(alignment: .leading, spacing: 2) {
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
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), \(value) \(unit). \(help)")
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
            figure(title: title, value: value, unit: unit, weight: weight, color: color, help: help)
            HeroSparkline(
                values: trend,
                labels: snapshot.recentLabels,
                openIndex: openIndex,
                readout: readout,
                color: color
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), \(value) \(unit). \(help)")
    }

    /// Today is the window's last point, counted like any other day and only
    /// marked as partial where it is drawn.
    private var openIndex: Int? {
        snapshot.openDay.flatMap { snapshot.recentLabels.lastIndex(of: $0.label) }
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
        let average = average
        let floor = domain.lowerBound
        let heat = heat
        Chart {
            // Rises from the ground like any area, coloured by height: cold
            // below the average, warm above it, deeper the further from it.
            // Today is filled too; its dashed line below still marks it partial.
            ForEach(points) { point in
                AreaMark(
                    x: .value("Day", point.index),
                    yStart: .value("Floor", floor),
                    yEnd: .value("Value", Double(point.value))
                )
                .foregroundStyle(heat)
            }

            if !points.isEmpty {
                RuleMark(y: .value("Average", average))
                    .foregroundStyle(color.opacity(0.35))
                    .lineStyle(StrokeStyle(lineWidth: 0.75, dash: [2, 2]))
            }

            ForEach(closedPoints) { point in
                LineMark(
                    x: .value("Day", point.index),
                    y: .value("Value", point.value),
                    series: .value("Part", "closed")
                )
                .foregroundStyle(color.opacity(0.75))
                .lineStyle(StrokeStyle(lineWidth: 1.25, lineCap: .round, lineJoin: .round))
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
        // Fills whatever height the total beside it leaves, so the area meets the
        // bottom of the row rather than floating above it.
        .frame(minHeight: 34, idealHeight: 34, maxHeight: .infinity)
        .accessibilityHidden(true)
    }

    private var points: [HeroTrendPoint] {
        values.enumerated().map { HeroTrendPoint(index: $0.offset, value: $0.element) }
    }

    /// The headline rate: every day in the window, today included.
    private var average: Double {
        values.isEmpty ? 0 : Double(values.reduce(0, +)) / Double(values.count)
    }

    private var heat: LinearGradient {
        let turn = SparklineHeat.averageFraction(
            average: average,
            floor: domain.lowerBound,
            peak: Double(values.max() ?? 0)
        )
        return LinearGradient(
            stops: [
                .init(color: TempoPalette.coldDeep.opacity(0.9), location: 0),
                .init(color: TempoPalette.coldShallow.opacity(0.7), location: max(0, turn - 0.05)),
                .init(color: TempoPalette.warmShallow.opacity(0.8), location: min(1, turn + 0.05)),
                .init(color: TempoPalette.warmHot, location: 1),
            ],
            startPoint: .bottom,
            endPoint: .top
        )
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

    /// Anchored at zero: the fill rises from the ground, so its height is the day's churn.
    private var domain: ClosedRange<Double> {
        0...Double(max(1, values.max() ?? 0)) * 1.08
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
                            // The sparkline is short, so the card hangs below it
                            // rather than under the pointer.
                            y: geometry.size.height + 6
                        )
                    }
                }
        }
    }

}
