import SwiftUI

// The Apple Health category colour of each pack and main target. Blue stays for what can be tapped; calm
// secondary pages turn these neutral on icons and chips, and keep them on data marks.

extension TargetMetric {
    var color: Color {
        switch self {
        case .homeBP, .clinicBP, .restingHR: Theme.heartData
        case .vo2max, .weeklyRunKm: Theme.activity
        case .cgmTIR, .postMealGlucose, .fastingGlucose: Theme.glucose
        case .weight: Theme.body
        case .sleepDuration, .sleepRegularity: Theme.sleep
        }
    }
}

extension ProgramPack {
    var color: Color {
        switch self {
        case .fitness, .event: Theme.activity
        case .cardio: Theme.heartData
        case .metabolic: Theme.glucose
        case .sleep: Theme.sleep
        }
    }
}
