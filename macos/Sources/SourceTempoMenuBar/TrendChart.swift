import Charts
import SourceTempoCore
import SwiftUI

struct TrendChart: View {
    let points: [TrendPoint]

    var body: some View {
        Chart(points) { point in
            AreaMark(
                x: .value("Day", point.label),
                yStart: .value("Code baseline", 0),
                yEnd: .value("Code", point.code)
            )
            .foregroundStyle(Color.blue.opacity(0.22))
            .interpolationMethod(.catmullRom)

            AreaMark(
                x: .value("Day", point.label),
                yStart: .value("Test baseline", point.code),
                yEnd: .value("Source", point.code + point.test)
            )
            .foregroundStyle(Color.orange.opacity(0.25))
            .interpolationMethod(.catmullRom)

            LineMark(
                x: .value("Day", point.label),
                y: .value("Code", point.code)
            )
            .foregroundStyle(Color.blue)
            .lineStyle(StrokeStyle(lineWidth: 1.5))
            .interpolationMethod(.catmullRom)

            LineMark(
                x: .value("Day", point.label),
                y: .value("Source", point.code + point.test)
            )
            .foregroundStyle(Color.orange)
            .lineStyle(StrokeStyle(lineWidth: 1.5))
            .interpolationMethod(.catmullRom)
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { value in
                AxisGridLine().foregroundStyle(.clear)
                AxisValueLabel {
                    if let label = value.as(String.self) {
                        Text(String(label.suffix(5)))
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
                    }
                }
            }
        }
        .frame(height: 150)
        .accessibilityLabel("Sixty-day source line trend")
    }
}
