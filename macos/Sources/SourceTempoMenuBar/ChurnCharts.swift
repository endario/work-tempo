import AppKit
import Charts
import SourceTempoCore
import SwiftUI

/// Steps are solved against `fillOpacity` composited over the popover's own
/// window background, not against the raw hex.
enum TempoPalette {
    static let source = adaptive(light: 0x52514E, dark: 0xC3C2B7)
    static let code = codeAdded
    static let tests = testAdded
    static let docs = docsAdded

    static let codeAdded = adaptive(light: 0x2776D3, dark: 0x3D8BE9)
    static let codeDeleted = adaptive(light: 0x0052AD, dark: 0x70B0FF)
    static let testAdded = adaptive(light: 0xCF4E12, dark: 0xE46332)
    static let testDeleted = adaptive(light: 0xA42C00, dark: 0xFF9168)
    static let docsAdded = adaptive(light: 0x00875A, dark: 0x199E70)
    static let docsDeleted = adaptive(light: 0x006140, dark: 0x4DC392)

    static let fillOpacity = 0.85

    static let positive = adaptive(light: 0x009300, dark: 0x0CA30C)
    static let negative = adaptive(light: 0xD03B3B, dark: 0xE5504D)

    private static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? nsColor(dark)
                : nsColor(light)
        })
    }

    private static func nsColor(_ value: UInt32) -> NSColor {
        NSColor(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }
}

struct SourceVolumeChart: View {
    let timeline: ChartTimeline

    @State private var hovered: ChartHoverPoint?

    var body: some View {
        Chart {
            ForEach(volumeBands) { band in
                AreaMark(
                    x: .value("Day", band.x),
                    yStart: .value("Baseline", band.start),
                    yEnd: .value("Lines", band.end),
                    series: .value("Kind", band.kind)
                )
                .foregroundStyle(band.color.opacity(TempoPalette.fillOpacity))
                .interpolationMethod(.linear)
            }

            // Documentation is a guide, not part of the source total: a soft
            // wash under a dashed boundary, matching the HTML report.
            ForEach(docsGuide) { point in
                LineMark(
                    x: .value("Day", point.x),
                    y: .value("Lines", point.value),
                    series: .value("Kind", "Docs guide")
                )
                .foregroundStyle(TempoPalette.docs)
                .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3], dashPhase: 0))
                .interpolationMethod(.linear)
            }

            if let hovered {
                RuleMark(x: .value("Day", timeline.pointPosition(at: hovered.index)))
                    .foregroundStyle(Color.primary.opacity(0.3))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))

                ForEach(hoverMarkers(hovered.index)) { marker in
                    PointMark(
                        x: .value("Day", timeline.pointPosition(at: hovered.index)),
                        y: .value("Lines", marker.value)
                    )
                    .symbolSize(46)
                    .foregroundStyle(marker.color)
                }
            }
        }
        .chartXAxis { AxisMarks(preset: .aligned, values: monthTickIndexes.map(Double.init)) { value in
            AxisGridLine().foregroundStyle(.clear)
            AxisValueLabel(anchor: .center, offsetsMarks: false) {
                if let index = value.as(Double.self).map({ Int($0.rounded()) }),
                   timeline.labels.indices.contains(index) {
                    Text(monthAbbreviation(timeline.labels[index]))
                }
            }
        } }
        .chartYAxis { churnYAxis }
        .chartXScale(domain: -0.5...max(0.5, Double(timeline.labels.count) - 0.5))
        .chartYScale(domain: yDomain)
        .chartOverlay { proxy in
            ChartHoverLayer(
                proxy: proxy,
                hovered: $hovered,
                resolve: timeline.nearestPointIndex(toX:),
                title: { dayTitle(timeline.labels[$0]) },
                columns: [],
                rows: hoverRows
            )
        }
        .frame(height: 116)
        .accessibilityLabel("Code, test, and documentation lines over time")
    }

    private var volumeBands: [VolumeBand] {
        timeline.labels.indices.flatMap { index -> [VolumeBand] in
            let x = timeline.pointPosition(at: index)
            let code = timeline.codeLoc[index]
            let tests = timeline.testLoc[index]
            return [
                VolumeBand(id: "code-\(index)", kind: "Code", x: x, start: 0, end: code, color: TempoPalette.code),
                VolumeBand(id: "tests-\(index)", kind: "Tests", x: x, start: code, end: code + tests, color: TempoPalette.tests),
                VolumeBand(id: "docs-\(index)", kind: "Docs", x: x, start: 0, end: -timeline.docLoc[index], color: TempoPalette.docs),
            ]
        }
    }

    private var docsGuide: [GuidePoint] {
        guard timeline.docLoc.contains(where: { $0 > 0 }) else { return [] }
        return timeline.labels.indices.map {
            GuidePoint(id: $0, x: timeline.pointPosition(at: $0), value: -timeline.docLoc[$0])
        }
    }

    private func hoverMarkers(_ index: Int) -> [HoverMarker] {
        let code = timeline.codeLoc[index]
        let tests = timeline.testLoc[index]
        let docs = timeline.docLoc[index]
        var markers = [
            HoverMarker(id: "code", value: code, color: TempoPalette.code),
            HoverMarker(id: "tests", value: code + tests, color: TempoPalette.tests),
        ]
        if docs > 0 {
            markers.append(HoverMarker(id: "docs", value: -docs, color: TempoPalette.docs))
        }
        return markers
    }

    private func hoverRows(_ index: Int) -> [HoverRow] {
        let code = timeline.codeLoc[index]
        let tests = timeline.testLoc[index]
        let docs = timeline.docLoc[index]
        return [
            HoverRow(id: "code", label: "Code", value: MetricFormatter.compact(code), swatch: TempoPalette.code),
            HoverRow(id: "tests", label: "Tests", value: MetricFormatter.compact(tests), swatch: TempoPalette.tests),
            HoverRow(id: "source", label: "Source", value: MetricFormatter.compact(code + tests), isTotal: true),
            HoverRow(id: "docs", label: "Docs", value: bracketed(docs), swatch: TempoPalette.docs),
        ]
    }

    private var yDomain: ClosedRange<Double> {
        let positive = zip(timeline.codeLoc, timeline.testLoc).map(+).max() ?? 0
        return bufferedDomain(positive: positive, negative: timeline.docLoc.max() ?? 0)
    }

    private var monthTickIndexes: [Int] {
        let groups = Dictionary(grouping: timeline.labels.indices) {
            String(timeline.labels[$0].prefix(7))
        }
        .sorted { $0.key < $1.key }
        guard !groups.isEmpty else { return [] }
        let selected = groups.count <= 3
            ? Array(groups.indices)
            : [0, groups.count / 2, groups.count - 1]
        return selected.map { groupIndex in
            let indices = groups[groupIndex].value
            return indices[indices.count / 2]
        }
    }
}

struct MonthlyChurnChart: View {
    let timeline: ChartTimeline

    @State private var hovered: ChartHoverPoint?

    private var months: [MonthlyChurnPoint] {
        timeline.monthlyChurn
    }

    var body: some View {
        Chart {
            if let hovered, months.indices.contains(hovered.index) {
                RectangleMark(
                    xStart: .value("Bar start", Double(hovered.index) - 0.42),
                    xEnd: .value("Bar end", Double(hovered.index) + 0.42),
                    yStart: .value("Removals", yDomain.lowerBound),
                    yEnd: .value("Additions", yDomain.upperBound)
                )
                .foregroundStyle(Color.primary.opacity(0.08))
            }

            if let current = currentTrack {
                RectangleMark(
                    xStart: .value("Unelapsed start", current.filledEnd),
                    xEnd: .value("Month end", current.end),
                    yStart: .value("Removals", -current.negative),
                    yEnd: .value("Additions", current.positive)
                )
                .foregroundStyle(Color.secondary.opacity(0.11))
            }

            ForEach(churnSegments) { segment in
                RectangleMark(
                    xStart: .value("Month start", segment.startX),
                    xEnd: .value("Month end", segment.endX),
                    yStart: .value("Stack start", segment.startY),
                    yEnd: .value("Stack end", segment.endY)
                )
                .foregroundStyle(segment.color.opacity(TempoPalette.fillOpacity))
            }

            if let hovered {
                RuleMark(x: .value("Month", Double(hovered.index)))
                    .foregroundStyle(Color.primary.opacity(0.3))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
        }
        .chartXAxis {
            AxisMarks(preset: .aligned, values: months.indices.map(Double.init)) { value in
                AxisGridLine().foregroundStyle(.clear)
                AxisValueLabel(anchor: .center, offsetsMarks: false) {
                    if let index = value.as(Double.self).map({ Int($0.rounded()) }),
                       months.indices.contains(index) {
                        Text(monthAbbreviation(months[index].label))
                    }
                }
            }
        }
        .chartYAxis { churnYAxis }
        .chartXScale(domain: -0.5...max(0.5, Double(months.count) - 0.5))
        .chartYScale(domain: yDomain)
        .chartOverlay { proxy in
            ChartHoverLayer(
                proxy: proxy,
                hovered: $hovered,
                resolve: { x in
                    let count = months.count
                    guard count > 0 else { return nil }
                    return min(count - 1, max(0, Int(x.rounded())))
                },
                title: { monthTitle(months[$0].label) },
                columns: ["+", "\u{2212}"],
                rows: hoverRows
            )
        }
        .frame(height: 116)
        .accessibilityLabel("Monthly code, test, and documentation additions and removals")
    }

    private func hoverRows(_ index: Int) -> [HoverRow] {
        let month = months[index]
        return [
            HoverRow(
                id: "code",
                label: "Code",
                values: [MetricFormatter.compact(month.codeAdded), MetricFormatter.compact(month.codeDeleted)],
                swatches: [TempoPalette.codeAdded, TempoPalette.codeDeleted]
            ),
            HoverRow(
                id: "tests",
                label: "Tests",
                values: [MetricFormatter.compact(month.testAdded), MetricFormatter.compact(month.testDeleted)],
                swatches: [TempoPalette.testAdded, TempoPalette.testDeleted]
            ),
            HoverRow(
                id: "source",
                label: "Source",
                values: [
                    MetricFormatter.compact(month.codeAdded + month.testAdded),
                    MetricFormatter.compact(month.codeDeleted + month.testDeleted),
                ],
                isTotal: true
            ),
            HoverRow(
                id: "docs",
                label: "Docs",
                values: [bracketed(month.docAdded), bracketed(month.docDeleted)],
                swatches: [TempoPalette.docsAdded, TempoPalette.docsDeleted]
            ),
        ]
    }

    private var yDomain: ClosedRange<Double> {
        let positive = months.map { $0.codeAdded + $0.testAdded + $0.codeDeleted + $0.testDeleted }.max() ?? 0
        let negative = months.map { $0.docAdded + $0.docDeleted }.max() ?? 0
        return bufferedDomain(positive: positive, negative: negative)
    }

    private var churnSegments: [ChurnSegment] {
        var segments: [ChurnSegment] = []
        for (index, month) in months.enumerated() {
            let bounds = xBounds(index)
            let positive: [(Int, Color)] = [
                (month.codeAdded, TempoPalette.codeAdded),
                (month.testAdded, TempoPalette.testAdded),
                (month.codeDeleted, TempoPalette.codeDeleted),
                (month.testDeleted, TempoPalette.testDeleted),
            ]
            let negative: [(Int, Color)] = [
                (month.docAdded, TempoPalette.docsAdded),
                (month.docDeleted, TempoPalette.docsDeleted),
            ]
            var baseline = 0
            for (part, item) in positive.enumerated() where item.0 > 0 {
                segments.append(ChurnSegment(
                    id: "\(index)-positive-\(part)",
                    startX: bounds.0,
                    endX: bounds.1,
                    startY: baseline,
                    endY: baseline + item.0,
                    color: item.1
                ))
                baseline += item.0
            }
            baseline = 0
            for (part, item) in negative.enumerated() where item.0 > 0 {
                segments.append(ChurnSegment(
                    id: "\(index)-negative-\(part)",
                    startX: bounds.0,
                    endX: bounds.1,
                    startY: baseline,
                    endY: baseline - item.0,
                    color: item.1
                ))
                baseline -= item.0
            }
        }
        return segments
    }

    private var currentTrack: CurrentTrack? {
        guard let month = months.last, let progress = month.currentProgress else { return nil }
        let index = months.count - 1
        let start = Double(index) - 0.32
        let end = Double(index) + 0.32
        return CurrentTrack(
            filledEnd: start + (end - start) * progress,
            end: end,
            positive: month.codeAdded + month.testAdded + month.codeDeleted + month.testDeleted,
            negative: month.docAdded + month.docDeleted
        )
    }

    private func xBounds(_ index: Int) -> (Double, Double) {
        let start = Double(index) - 0.32
        let end = Double(index) + 0.32
        guard index == months.count - 1,
              let progress = months[index].currentProgress else { return (start, end) }
        return (start, start + (end - start) * progress)
    }
}

// MARK: - Hover

struct HoverRow: Identifiable {
    let id: String
    let label: String
    let values: [String]
    var swatches: [Color] = []
    var isTotal = false

    init(id: String, label: String, value: String, swatch: Color? = nil, isTotal: Bool = false) {
        self.init(id: id, label: label, values: [value], swatches: swatch.map { [$0] } ?? [], isTotal: isTotal)
    }

    init(id: String, label: String, values: [String], swatches: [Color] = [], isTotal: Bool = false) {
        self.id = id
        self.label = label
        self.values = values
        self.swatches = swatches
        self.isTotal = isTotal
    }
}

/// The pointer and the point it selects are not the same place: on a sparse
/// chart the nearest datum can sit half a slot away. Content comes from the
/// index, placement from the pointer, so the card never slides under the cursor.
struct ChartHoverPoint: Equatable {
    let index: Int
    let cursorX: CGFloat
}

private struct HoverMarker: Identifiable {
    let id: String
    let value: Int
    let color: Color
}

private struct ChartHoverLayer: View {
    let proxy: ChartProxy
    @Binding var hovered: ChartHoverPoint?
    let resolve: (Double) -> Int?
    let title: (Int) -> String
    let columns: [String]
    let rows: (Int) -> [HoverRow]

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        guard case let .active(point) = phase else {
                            hovered = nil
                            return
                        }
                        hovered = hoverPoint(at: point, in: geometry)
                    }

                if let hovered {
                    let readout = ChartReadout(
                        title: title(hovered.index),
                        columns: columns,
                        rows: rows(hovered.index)
                    )
                    readout.offset(
                        x: ChartReadout.placement(
                            besideCursor: hovered.cursorX,
                            width: readout.width,
                            within: geometry.size.width
                        ),
                        y: 0
                    )
                }
            }
        }
    }

    private func hoverPoint(at point: CGPoint, in geometry: GeometryProxy) -> ChartHoverPoint? {
        guard let anchor = proxy.plotFrame else { return nil }
        let plot = geometry[anchor]
        guard plot.contains(point),
              let raw = proxy.value(atX: point.x - plot.minX, as: Double.self),
              let index = resolve(raw) else { return nil }
        return ChartHoverPoint(index: index, cursorX: point.x)
    }
}

struct ChartReadout: View {
    let title: String
    var columns: [String] = []
    let rows: [HoverRow]

    static let cursorGap: CGFloat = 16

    static func placement(besideCursor cursor: CGFloat, width: CGFloat, within available: CGFloat) -> CGFloat {
        let trailing = cursor + cursorGap
        if trailing + width <= available { return trailing }
        let leading = cursor - cursorGap - width
        if leading >= 0 { return leading }
        return max(0, min(available - width, trailing))
    }

    private var showsSwatches: Bool {
        rows.contains { !$0.swatches.isEmpty }
    }

    var width: CGFloat {
        let labelColumn: CGFloat = 62
        let valueColumn: CGFloat = columns.count > 1 ? 44 : 56
        return labelColumn + valueColumn * CGFloat(max(1, columns.count)) + (showsSwatches ? 22 : 12)
    }

    private var firstTotalID: String? {
        rows.first(where: \.isTotal)?.id
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2.5) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.bottom, 1)

            if columns.count > 1 {
                row(
                    label: "",
                    values: columns,
                    swatches: [],
                    emphasised: false,
                    muted: true
                )
            }

            ForEach(rows) { entry in
                if entry.id == firstTotalID {
                    Divider().padding(.vertical, 2)
                }
                row(
                    label: entry.label,
                    values: entry.values,
                    swatches: entry.swatches,
                    emphasised: entry.isTotal,
                    muted: false
                )
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .frame(width: width, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.primary.opacity(0.12)))
        .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
        .allowsHitTesting(false)
    }

    private func row(
        label: String,
        values: [String],
        swatches: [Color],
        emphasised: Bool,
        muted: Bool
    ) -> some View {
        HStack(spacing: 5) {
            chip(swatches)
            Text(label)
                .foregroundStyle(emphasised ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            Spacer(minLength: 4)
            ForEach(Array(values.enumerated()), id: \.offset) { _, value in
                Text(value)
                    .monospacedDigit()
                    .foregroundStyle(muted ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                    .frame(width: columns.count > 1 ? 40 : nil, alignment: .trailing)
            }
        }
        .font(.system(size: 10, weight: emphasised ? .semibold : .regular))
    }

    @ViewBuilder
    private func chip(_ swatches: [Color]) -> some View {
        if !showsSwatches {
            EmptyView()
        } else if swatches.isEmpty {
            Color.clear.frame(width: 11, height: 7)
        } else {
            HStack(spacing: 1) {
                ForEach(Array(swatches.enumerated()), id: \.offset) { _, color in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(color)
                        .frame(width: swatches.count > 1 ? 5 : 11, height: 7)
                }
            }
            .frame(width: 11, alignment: .leading)
        }
    }
}

// MARK: - Shared chart chrome

private var churnYAxis: some AxisContent {
    AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
        AxisGridLine().foregroundStyle(Color.secondary.opacity(0.12))
        AxisValueLabel {
            if let count = value.as(Int.self) {
                Text(MetricFormatter.compact(count))
                    .frame(width: 38, alignment: .trailing)
            }
        }
    }
}

let monthNames = ["JAN", "FEB", "MAR", "APR", "MAY", "JUN", "JUL", "AUG", "SEP", "OCT", "NOV", "DEC"]

private func monthAbbreviation(_ label: String) -> String {
    let parts = label.split(separator: "-")
    guard parts.count >= 2,
          let month = Int(parts[1]),
          monthNames.indices.contains(month - 1) else { return label }
    return monthNames[month - 1]
}

func dayTitle(_ label: String) -> String {
    let parts = label.split(separator: "-")
    guard parts.count == 3, let month = Int(parts[1]), let day = Int(parts[2]),
          monthNames.indices.contains(month - 1) else { return label }
    return "\(monthNames[month - 1]) \(day)"
}

private func monthTitle(_ label: String) -> String {
    let parts = label.split(separator: "-")
    guard parts.count >= 2, let month = Int(parts[1]),
          monthNames.indices.contains(month - 1) else { return label }
    return "\(monthNames[month - 1]) \(parts[0])"
}

/// Documentation is counted separately from source, and the report prints it in
/// brackets beside the source figure. The readouts follow that.
private func bracketed(_ value: Int) -> String {
    "(" + MetricFormatter.compact(value) + ")"
}

private func bufferedDomain(positive: Int, negative: Int) -> ClosedRange<Double> {
    let upper = max(1, Double(positive) * 1.06)
    let lower = negative > 0 ? -Double(negative) * 1.06 : 0
    return lower...upper
}

private struct GuidePoint: Identifiable {
    let id: Int
    let x: Double
    let value: Int
}

private struct VolumeBand: Identifiable {
    let id: String
    let kind: String
    let x: Double
    let start: Int
    let end: Int
    let color: Color
}

private struct ChurnSegment: Identifiable {
    let id: String
    let startX: Double
    let endX: Double
    let startY: Int
    let endY: Int
    let color: Color
}

private struct CurrentTrack {
    let filledEnd: Double
    let end: Double
    let positive: Int
    let negative: Int
}
