import SwiftUI
import Charts

extension Theme {
    /// Four sizes on one scale (×1.2 steps), all scaled by the user's preferred text size:
    /// title for page sections and key numbers, headline for card titles, body for everything people read,
    /// caption only for chart axes and legends. System navigation and date/keyboard controls keep their own.
    enum TypeScale {
        static let title: Font = .custom("PingFangSC-Regular", size: 22, relativeTo: .title3).weight(.semibold)
        static let headline: Font = .custom("PingFangSC-Regular", size: 19, relativeTo: .headline).weight(.semibold)
        static let body: Font = .custom("PingFangSC-Regular", size: 16, relativeTo: .body)
        static let caption: Font = .custom("PingFangSC-Regular", size: 13, relativeTo: .footnote)
    }
}

extension View {
    /// Chart labels in the caption size, three ticks per axis.
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
                }.font(Theme.TypeScale.caption)
            }
        }
        .pulseChartYAxis()
    }

    /// The y axis only, for a chart that labels its own x axis (hours, minutes): the shared x axis would win
    /// over it and read the numbers as dates (「1月1日」).
    func pulseChartYAxis() -> some View {
        self.chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) {
                AxisGridLine()
                AxisTick()
                AxisValueLabel().font(Theme.TypeScale.caption)
            }
        }
    }
}
