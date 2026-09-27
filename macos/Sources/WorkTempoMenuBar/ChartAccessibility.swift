import Accessibility
import WorkTempoCore
import SwiftUI

struct SourceChartDescriptor: AXChartDescriptorRepresentable {
    let timeline: ChartTimeline

    func makeChartDescriptor() -> AXChartDescriptor {
        let values = timeline.codeLoc + timeline.testLoc + timeline.docLoc
        let minimum = min(0, values.min() ?? 0)
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
            ("Docs (separate)", timeline.docLoc),
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
            title: "Source lines over time",
            summary: summary + openSummary,
            xAxis: xAxis,
            yAxis: yAxis,
            series: descriptors
        )
    }

    func updateChartDescriptor(_ descriptor: AXChartDescriptor) {
        let updated = makeChartDescriptor()
        descriptor.title = updated.title
        descriptor.summary = updated.summary
        descriptor.xAxis = updated.xAxis
        descriptor.yAxis = updated.yAxis
        descriptor.series = updated.series
    }
}
