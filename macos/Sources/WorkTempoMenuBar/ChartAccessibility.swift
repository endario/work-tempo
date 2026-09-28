import Accessibility
import WorkTempoCore
import SwiftUI

private func copyChartDescriptor(_ source: AXChartDescriptor, into destination: AXChartDescriptor) {
    destination.title = source.title
    destination.summary = source.summary
    destination.xAxis = source.xAxis
    destination.yAxis = source.yAxis
    destination.additionalAxes = source.additionalAxes
    destination.contentDirection = source.contentDirection
    destination.series = source.series
}

struct SourceChartDescriptor: AXChartDescriptorRepresentable {
    let timeline: ChartTimeline

    func makeChartDescriptor() -> AXChartDescriptor {
        let values = timeline.codeLoc + timeline.testLoc + timeline.docLoc
        let minimum = min(0, values.min() ?? 0)
        // Match the visual's stacked source range while speaking each component separately.
        let maximum = max(1, values.max() ?? 0, zip(timeline.codeLoc, timeline.testLoc).map(+).max() ?? 0)
        let xAxis = AXCategoricalDataAxisDescriptor(title: "Day", categoryOrder: timeline.labels)
        let yAxis = AXNumericDataAxisDescriptor(
            title: "Lines",
            range: Double(minimum)...Double(maximum),
            gridlinePositions: [],
            valueDescriptionProvider: { "\(Int($0)) lines" }
        )
        let openIndex = timeline.currentProgress == nil ? nil : timeline.labels.indices.last
        let series: [(String, [Int])] = [
            ("Code", timeline.codeLoc),
            ("Tests", timeline.testLoc),
            ("Docs", timeline.docLoc),
        ]
        let descriptors = series.map { name, values in
            AXDataSeriesDescriptor(
                name: name,
                isContinuous: true,
                dataPoints: timeline.labels.indices.map { index in
                    AXDataPoint(
                        x: timeline.labels[index],
                        y: Double(values[index]),
                        label: index == openIndex ? "To date" : nil
                    )
                }
            )
        }
        let summary = minimum < 0
            ? "Code and tests make up source lines. Documentation is separate. This report contains negative line counts."
            : "Code and tests make up source lines. Documentation is separate: its band is drawn below zero only to distinguish it, and its counts are positive."
        let openSummary = openIndex == nil ? "" : " The current day is partial, to date."
        return AXChartDescriptor(
            title: "Lines over time",
            summary: summary + openSummary,
            xAxis: xAxis,
            yAxis: yAxis,
            series: descriptors
        )
    }

    func updateChartDescriptor(_ descriptor: AXChartDescriptor) {
        copyChartDescriptor(makeChartDescriptor(), into: descriptor)
    }
}

struct MonthlyChartDescriptor: AXChartDescriptorRepresentable {
    let timeline: ChartTimeline

    func makeChartDescriptor() -> AXChartDescriptor {
        let months = timeline.monthlyChurn
        let series: [(String, (MonthlyChurnPoint) -> Int)] = [
            ("Code added", { $0.codeAdded }),
            ("Code removed", { $0.codeDeleted }),
            ("Tests added", { $0.testAdded }),
            ("Tests removed", { $0.testDeleted }),
            ("Docs added", { $0.docAdded }),
            ("Docs removed", { $0.docDeleted }),
        ]
        let values = series.flatMap { _, value in months.map(value) }
        let minimum = min(0, values.min() ?? 0)
        let maximum = max(1, values.max() ?? 0, months.map {
            $0.codeAdded + $0.testAdded + $0.codeDeleted + $0.testDeleted
        }.max() ?? 0)
        let descriptors = series.map { name, value in
            AXDataSeriesDescriptor(
                name: name,
                isContinuous: false,
                dataPoints: months.enumerated().map { index, month in
                    AXDataPoint(
                        x: month.label,
                        y: Double(value(month)),
                        label: index == months.count - 1 && month.currentProgress != nil ? "To date" : nil
                    )
                }
            )
        }
        let summary = minimum < 0
            ? "Monthly additions and removals are separate counts. This report contains negative line counts."
            : "Monthly additions and removals are separate positive counts, not net growth. Documentation is drawn below zero only to distinguish it; its counts are positive."
        let openSummary = months.last?.currentProgress == nil ? "" : " The current month is partial, to date."
        return AXChartDescriptor(
            title: "Monthly activity",
            summary: summary + openSummary,
            xAxis: AXCategoricalDataAxisDescriptor(title: "Month", categoryOrder: months.map(\.label)),
            yAxis: AXNumericDataAxisDescriptor(
                title: "Lines",
                range: Double(minimum)...Double(maximum),
                gridlinePositions: [],
                valueDescriptionProvider: { "\(Int($0)) lines" }
            ),
            series: descriptors
        )
    }

    func updateChartDescriptor(_ descriptor: AXChartDescriptor) {
        copyChartDescriptor(makeChartDescriptor(), into: descriptor)
    }
}
