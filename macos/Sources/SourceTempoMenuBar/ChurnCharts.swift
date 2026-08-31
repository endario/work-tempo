import AppKit
import Charts
import SourceTempoCore
import SwiftUI

enum TempoPalette {
    static let source = adaptive(light: 0x596276, dark: 0xB0B8CB)
    static let code = adaptive(light: 0x466F5D, dark: 0x8DC3AA)
    static let codeAdded = adaptive(light: 0x2F5D49, dark: 0xA7D4BE)
    static let codeDeleted = adaptive(light: 0x7DA68F, dark: 0x557D69)
    static let tests = adaptive(light: 0x596A9A, dark: 0xA6B3DD)
    static let testAdded = adaptive(light: 0x364A82, dark: 0xB5C0EA)
    static let testDeleted = adaptive(light: 0x8B9CCB, dark: 0x6474A8)
    static let docs = adaptive(light: 0x845E78, dark: 0xD2A2C2)
    static let docsAdded = adaptive(light: 0x61374F, dark: 0xD9AEC9)
    static let docsDeleted = adaptive(light: 0xB187A3, dark: 0x966685)
    static let positive = adaptive(light: 0x347048, dark: 0x8BCB98)
    static let negative = adaptive(light: 0x934D50, dark: 0xE49B9E)

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

struct CumulativeChurnChart: View {
    let timeline: ChartTimeline

    var body: some View {
        Chart {
            ForEach(cumulativeBands) { point in
                AreaMark(
                    x: .value("Day", point.x),
                    yStart: .value("Baseline", point.start),
                    yEnd: .value("Lines", point.end),
                    series: .value("Change", point.kind)
                )
                .foregroundStyle(point.color.opacity(0.88))
                .interpolationMethod(.linear)
            }

        }
        .chartXAxis { chartXAxis }
        .chartYAxis { chartYAxis }
        .chartXScale(domain: -0.5...max(0.5, Double(timeline.labels.count) - 0.5))
        .chartYScale(domain: yDomain)
        .frame(height: 116)
        .accessibilityLabel("Cumulative code, test, and documentation additions and removals")
    }

    private var cumulativeBands: [CumulativeBandPoint] {
        timeline.cumulativeChanges.flatMap { point in
            let positiveTests = point.codeAdded + point.testAdded
            let positiveCodeDeleted = positiveTests + point.codeDeleted
            let positiveSource = positiveCodeDeleted + point.testDeleted
            let x = xPosition(point.index)
            return [
                CumulativeBandPoint(
                    id: "code-added-\(point.index)",
                    kind: "Code +",
                    x: x,
                    start: 0,
                    end: point.codeAdded,
                    color: TempoPalette.codeAdded
                ),
                CumulativeBandPoint(
                    id: "tests-added-\(point.index)",
                    kind: "Tests +",
                    x: x,
                    start: point.codeAdded,
                    end: positiveTests,
                    color: TempoPalette.testAdded
                ),
                CumulativeBandPoint(
                    id: "code-deleted-\(point.index)",
                    kind: "Code -",
                    x: x,
                    start: positiveTests,
                    end: positiveCodeDeleted,
                    color: TempoPalette.codeDeleted
                ),
                CumulativeBandPoint(
                    id: "tests-deleted-\(point.index)",
                    kind: "Tests -",
                    x: x,
                    start: positiveCodeDeleted,
                    end: positiveSource,
                    color: TempoPalette.testDeleted
                ),
                CumulativeBandPoint(
                    id: "docs-added-\(point.index)",
                    kind: "Docs +",
                    x: x,
                    start: 0,
                    end: -point.docAdded,
                    color: TempoPalette.docsAdded
                ),
                CumulativeBandPoint(
                    id: "docs-deleted-\(point.index)",
                    kind: "Docs -",
                    x: x,
                    start: -point.docAdded,
                    end: -(point.docAdded + point.docDeleted),
                    color: TempoPalette.docsDeleted
                ),
            ]
        }
    }

    private var yDomain: ClosedRange<Double> {
        let points = timeline.cumulativeChanges
        let positive = points.map { $0.codeAdded + $0.testAdded + $0.codeDeleted + $0.testDeleted }.max() ?? 0
        let negative = points.map { $0.docAdded + $0.docDeleted }.max() ?? 0
        return bufferedDomain(positive: positive, negative: negative)
    }

    private func xPosition(_ index: Int) -> Double {
        guard index == timeline.labels.count - 1,
              let progress = timeline.currentProgress,
              index > 0 else { return Double(index) }
        return Double(index - 1) + progress
    }

    private var chartXAxis: some AxisContent {
        AxisMarks(preset: .aligned, values: monthTickIndexes.map(Double.init)) { value in
            AxisGridLine().foregroundStyle(.clear)
            AxisValueLabel(anchor: .center, offsetsMarks: false) {
                if let raw = value.as(Double.self) {
                    let index = Int(raw.rounded())
                    if timeline.labels.indices.contains(index) {
                        Text(monthAbbreviation(timeline.labels[index]))
                    }
                }
            }
        }
    }

    private var chartYAxis: some AxisContent {
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

    private var months: [MonthlyChurnPoint] {
        timeline.monthlyChurn
    }

    var body: some View {
        Chart {
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
                .foregroundStyle(segment.color)
            }

        }
        .chartXAxis {
            AxisMarks(preset: .aligned, values: months.indices.map(Double.init)) { value in
                AxisGridLine().foregroundStyle(.clear)
                AxisValueLabel(anchor: .center, offsetsMarks: false) {
                    if let raw = value.as(Double.self) {
                        let index = Int(raw.rounded())
                        if months.indices.contains(index) {
                            Text(monthAbbreviation(months[index].label))
                        }
                    }
                }
            }
        }
        .chartYAxis {
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
        .chartXScale(domain: -0.5...max(0.5, Double(months.count) - 0.5))
        .chartYScale(domain: yDomain)
        .frame(height: 116)
        .accessibilityLabel("Monthly code, test, and documentation additions and removals")
    }

    private var yDomain: ClosedRange<Double> {
        let positive = months.map { $0.codeAdded + $0.testAdded + $0.codeDeleted + $0.testDeleted }.max() ?? 0
        let negative = months.map { $0.docAdded + $0.docDeleted }.max() ?? 0
        return bufferedDomain(
            positive: positive,
            negative: negative
        )
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

private func monthAbbreviation(_ label: String) -> String {
    let names = ["JAN", "FEB", "MAR", "APR", "MAY", "JUN", "JUL", "AUG", "SEP", "OCT", "NOV", "DEC"]
    let parts = label.split(separator: "-")
    guard parts.count >= 2,
          let month = Int(parts[1]),
          names.indices.contains(month - 1) else { return label }
    return names[month - 1]
}

private func bufferedDomain(positive: Int, negative: Int) -> ClosedRange<Double> {
    let upper = max(1, Double(positive) * 1.06)
    let lower = negative > 0 ? -Double(negative) * 1.06 : 0
    return lower...upper
}

private struct CumulativeBandPoint: Identifiable {
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
