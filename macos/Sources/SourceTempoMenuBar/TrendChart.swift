import Charts
import SourceTempoCore
import SwiftUI

struct TrendChart: View {
    let points: [TrendPoint]

    var body: some View {
        Chart {
            ForEach(Array(points.enumerated()), id: \.element.id) { index, point in
                AreaMark(
                    x: .value("Day", index),
                    yStart: .value("Code baseline", 0),
                    yEnd: .value("Code", point.code),
                    series: .value("Series", "Code")
                )
                .foregroundStyle(Color.blue.opacity(0.22))
                .interpolationMethod(.catmullRom)
            }

            ForEach(Array(points.enumerated()), id: \.element.id) { index, point in
                AreaMark(
                    x: .value("Day", index),
                    yStart: .value("Test baseline", point.code),
                    yEnd: .value("Source", point.code + point.test),
                    series: .value("Series", "Tests")
                )
                .foregroundStyle(Color.orange.opacity(0.25))
                .interpolationMethod(.catmullRom)
            }

            ForEach(Array(points.enumerated()), id: \.element.id) { index, point in
                LineMark(
                    x: .value("Day", index),
                    y: .value("Code", point.code),
                    series: .value("Series", "Code")
                )
                .foregroundStyle(Color.blue)
                .lineStyle(StrokeStyle(lineWidth: 1.5))
                .interpolationMethod(.catmullRom)
            }

            ForEach(Array(points.enumerated()), id: \.element.id) { index, point in
                LineMark(
                    x: .value("Day", index),
                    y: .value("Source", point.code + point.test),
                    series: .value("Series", "Tests")
                )
                .foregroundStyle(Color.orange)
                .lineStyle(StrokeStyle(lineWidth: 1.5))
                .interpolationMethod(.catmullRom)
            }
        }
        .chartXAxis {
            AxisMarks(values: tickIndices) { value in
                AxisGridLine().foregroundStyle(.clear)
                AxisValueLabel {
                    if let index = value.as(Int.self), points.indices.contains(index) {
                        Text(String(points[index].label.suffix(5)))
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
        .accessibilityLabel("Source line trend")
    }

    private var tickIndices: [Int] {
        guard points.count > 1 else { return points.isEmpty ? [] : [0] }
        return [0, points.count / 3, (points.count * 2) / 3, points.count - 1]
    }
}
