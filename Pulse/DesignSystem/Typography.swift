import SwiftUI
import Charts

extension Theme {
    /// Two content sizes, both scaled by the user's preferred text size.
    /// System navigation and date/keyboard controls retain native accessibility behaviour.
    enum TypeScale {
        static let body: Font = .custom("PingFangSC-Regular", size: 16, relativeTo: .body)
        static let title: Font = .custom("PingFangSC-Regular", size: 22, relativeTo: .title3).weight(.semibold)
    }
}

extension View {
    /// Chart labels use the same reading size; fewer ticks leave room for the larger labels.
    func pulseChartAxes() -> some View {
        self.chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 3)) { value in
                AxisGridLine()
                AxisTick()
                AxisValueLabel(collisionResolution: .greedy) {
                    if let date = value.as(Date.self) {
                        Text(date.formatted(.dateTime.month().day())).fixedSize()
                    } else if let number = value.as(Double.self) {
                        Text(number.formatted(.number.precision(.fractionLength(0...1)))).fixedSize()
                    } else if let label = value.as(String.self) {
                        Text(label).fixedSize()
                    }
                }.font(Theme.TypeScale.body)
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) {
                AxisGridLine()
                AxisTick()
                AxisValueLabel().font(Theme.TypeScale.body)
            }
        }
    }
}
