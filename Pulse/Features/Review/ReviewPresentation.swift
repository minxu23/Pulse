import Foundation

/// The week's activity for the review's figures: whether exercise was recorded at all, and mean steps against
/// the same days of the week before.
struct WeekActivity {
    var known: Bool
    var steps: Double?
    var previousSteps: Double?

    init(days: [DayData], weekStart ws: Date, span: Int) {
        func mean(_ from: Date, _ to: Date) -> Double? {
            Stats.mean(days.filter { $0.day >= from && $0.day < to }.compactMap { $0.steps.map(Double.init) })
        }
        known = days.contains { $0.day >= ws && $0.day < ws.adding(days: span) && ($0.exerciseMinutes != nil || $0.sessionMinutes > 0) }
        steps = mean(ws, ws.adding(days: span))
        previousSteps = mean(ws.adding(days: -7), ws.adding(days: span - 7))
    }
}

/// Keeps the active target first and removes training compliance from a recording-only review.
enum ReviewPresentation {
    static func metrics(_ original: [BriefMetric], target: TargetReading?, recording: Bool, activityKnown: Bool = true, steps: Double? = nil, previousSteps: Double? = nil) -> [BriefMetric] {
        typealias N = BriefMetric.Name
        let metrics = original.filter { !recording || $0.name != N.training }.map { m in
            if m.name == N.activity && !activityKnown {
                return BriefMetric(name: m.name, icon: m.icon, value: "未记录", unit: "", delta: nil, trend: .none)
            }
            return m
        }
        guard !recording, let target else { return metrics }
        let primary = BriefMetric(name: target.label, icon: "target", value: target.value == nil ? "未记录" : target.valueText,
                                  unit: target.unitShort, delta: nil, trend: .none)
        let duplicate: String? = switch target.target {
        case .restingHR: N.rhr
        case .homeBP, .clinicBP: N.homeBP
        case .cgmTIR: N.timeInRange
        case .weight: N.weight
        default: nil
        }
        let stepDelta = steps.flatMap { current in previousSteps.map { previous in
            let difference = Int((current - previous).rounded())
            return (difference > 0 ? "+" : "") + "\(difference) 步"
        } }
        let stepMetric = BriefMetric(name: N.steps, icon: "figure.walk", value: steps.map { String(Int($0.rounded())) } ?? "未记录",
                                     unit: steps == nil ? "" : "步", delta: stepDelta, trend: .none)
        let training = metrics.filter { $0.name == N.training }
        return [primary] + training + [stepMetric] + metrics.filter { $0.name != duplicate && $0.name != target.label && $0.name != N.training }
    }
}
