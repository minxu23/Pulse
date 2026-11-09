import Foundation

enum UsageIntent: String, CaseIterable, Identifiable {
    case recording, fitness, event, cardio, metabolic, sleep
    var id: String { rawValue }
    var label: String {
        switch self {
        case .recording: "记录身体状况"
        case .fitness: "提升运动能力"
        case .event: "准备一场赛事"
        case .cardio: "改善心血管健康"
        case .metabolic: "改善代谢健康"
        case .sleep: "改善睡眠"
        }
    }
    var pack: ProgramPack? { ProgramPack(rawValue: rawValue) }
}

extension UserProfile {
    var usageIntent: UsageIntent {
        get {
            if let explicit = UsageIntent(rawValue: usageIntentRaw) { return explicit }
            // Existing profiles keep their previous intention; new empty profiles start with recording.
            if goals.contains(.event) { return .event }
            if goals.contains(.fitness) { return .fitness }
            if goals.contains(.careAligned) { return hasDiabetesIntent ? .metabolic : .cardio }
            return goals.isEmpty ? .recording : .cardio
        }
        set {
            usageIntentRaw = newValue.rawValue
            switch newValue {
            case .recording: goals = []
            case .fitness: goals = [.fitness]
            case .event: goals = [.event]
            case .cardio: goals = [.lowerRHR]
            case .metabolic: goals = [.careAligned]
            case .sleep: goals = [.energy]
            }
        }
    }
    private var hasDiabetesIntent: Bool { conditions.contains { $0.isDiabetes } }
    var hasAge: Bool { birthYear >= 1900 && birthYear <= Calendar(identifier: .gregorian).component(.year, from: .app) }
    var hasBodySize: Bool { heightCm.isFinite && weightKg.isFinite && (130...220).contains(heightCm) && (30...200).contains(weightKg) }
    var basicsSummary: String {
        [age.map { "\($0) 岁" } ?? "年龄待补充", sex.label, hasBodySize ? "BMI \(bmi.oneDecimal)" : "身高体重待补充"].joined(separator: " · ")
    }
    var canStartImprovement: Bool { hasAge && programQuestionsDone && parqAnswers.count == ParQ.allCases.count }
}
