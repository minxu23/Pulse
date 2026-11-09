import Foundation
import SwiftData

/// The single user profile: personal basics, goals, life constraints, habit targets,
/// care-plan parameters and data preferences (需求 1、10).
@Model
final class UserProfile {
    var createdAt: Date = Date()
    var onboardingDone: Bool = false

    // Basics
    var nickname: String = ""
    var birthYear: Int = 0
    var sexRaw: String = Sex.unspecified.rawValue
    var heightCm: Double = 0
    var weightKg: Double = 0
    var neckCm: Double? = nil

    // Exercise base & health background
    var activityLevelRaw: String = ActivityLevel.light.rawValue
    var weeklyExerciseMinutes: Int = 60
    var conditionsRaw: [String] = []
    var healthBackgroundReviewed: Bool = false
    var otherConditions: String = ""
    /// Conditions recorded from the Health Agent conversation (`ConditionLibrary` ids, or a name it
    /// has no entry for).
    var extraConditionsRaw: [String] = []
    var limitations: String = ""

    // Life constraints
    var availableWeekdays: [Int] = [3, 5, 7]   // Calendar weekday: 1 = 周日 … 7 = 周六
    var sessionMinutes: Int = 40
    var preferredTimeRaw: String = PreferredTime.evening.rawValue
    var shiftWork: Bool = false
    // Roster (倒班): a repeating pattern of shifts starting on `shiftCycleStart`, and the shift times.
    var shiftPatternRaw: [String] = []
    var shiftCycleStart: Date? = nil
    var dayShiftStart: Int = 8 * 60
    var dayShiftEnd: Int = 17 * 60
    var nightShiftStart: Int = 20 * 60
    var nightShiftEnd: Int = 8 * 60

    // Goals
    var goalsRaw: [String] = []
    var usageIntentRaw: String = ""
    var goalNote: String = ""
    var targetDate: Date? = nil
    var weeklyTimeBudget: Int = 180
    var weeklyTargetMinutes: Int = 90
    var weeklyTargetReason: String = ""
    // Next week's plan generated from this week's review (rolled over when that week starts)
    var nextWeekPlannedFor: Date? = nil
    var nextWeekTargetMinutes: Int? = nil
    var nextWeekTargetReason: String = ""

    // Resting heart-rate baseline
    var baselineRHR: Double? = nil
    var targetRHR: Double? = nil
    var baselineSetAt: Date? = nil
    var baselineIsManual: Bool = false
    var rhrMethodRaw: String = RHRSource.device.rawValue

    // Habit targets
    var bedtimeMinutes: Int = 23 * 60
    var wakeMinutes: Int = 7 * 60
    var sleepNeedHours: Double = 7.5
    var caffeineCutoffHour: Int = 14
    var weeklyAlcoholLimit: Double = 4
    var waterTargetMl: Int = 1800
    /// 限水: the doctor limits fluids, so the water target is a daily maximum, not a goal.
    var fluidLimit: Bool = false
    // Kidney diet, with the amounts the doctor or dietitian gave
    var nutrientTracking: Bool = false
    var saltLimitG: Double = 5
    var proteinTargetG: Int? = nil
    var potassiumLimit: Bool = false
    var phosphorusLimit: Bool = false
    /// 血液透析: the session weekdays (Calendar numbering) and the dry weight the doctor gave.
    var dialysis: Bool = false
    /// 「hemo」 血液透析 or 「peritoneal」 腹膜透析.
    var dialysisModeRaw: String = "hemo"
    var dialysisWeekdays: [Int] = []
    var dryWeightKg: Double? = nil
    /// 复盘的优先事项 in the user's own order; empty = Pulse's automatic order.
    var reviewPrioritiesRaw: [String] = []
    var stepsTarget: Int = 8000
    /// Sports the user likes, with their level ("tennis:regular"); see `SportPreference`.
    var favoriteSportsRaw: [String] = []
    /// Baseline questionnaire: smoking, early heart disease in the family, PAR-Q+ answers.
    var smoker: Bool? = nil
    var familyHistoryCVD: Bool? = nil
    /// 基础信息: trouble falling or staying asleep, or waking too early, 3+ nights a week for 3+ months (ICSD-3 chronic insomnia).
    var insomniaSymptoms: Bool? = nil
    var parqAnswers: [Bool] = []
    var parqDate: Date? = nil
    /// Owns a blood-pressure monitor (nil = not asked; readings arriving also count).
    var hasBPMonitor: Bool? = nil

    // 三阶段健康计划: 基线期 → 改善期 (4-week rounds) → 总结期
    var programPhaseRaw: String = ""
    var programBaselineStart: Date? = nil
    var programPackRaw: String = ""
    var programTargetRaw: String = ""
    var programRound: Int = 0
    var programRoundStart: Date? = nil
    var programRoundWeeks: Int = 4
    /// The main target's value at the start of the round, and the round's goal.
    var programTargetBaseline: Double? = nil
    var programTargetGoal: Double? = nil
    var programQuestionsDone: Bool = false
    /// `ProgramPlanInput` as JSON while a pack is running.
    var programPlanData: Data? = nil
    /// Danger signs (raw `RedFlag.Kind`) a doctor has seen and allowed starting the program with. Only for starting
    /// the program: the care limits on intensity keep to `clinicianCleared`.
    var programClearedFlags: [String] = []
    /// The optional strength self-test of 基线期: push-ups to exhaustion, or 30-second chair stands.
    var strengthPushups: Int? = nil
    var strengthChairStands: Int? = nil
    var strengthTestDate: Date? = nil

    // Optional professional modules
    var modulesRaw: [String] = []
    /// The furthest stage reached on each goal's path ("rhr:2"), so a stage once reached is kept.
    var journeyReachedRaw: [String] = []
    var marathonStart: Date? = nil

    // Sleep breathing
    var apneaStatusRaw: String = ApneaStatus.unknown.rawValue
    var apneaTreatmentRaw: String = ApneaTreatment.none.rawValue
    var stopBangAnswers: [Bool] = []
    var stopBangDate: Date? = nil
    var cpapTargetHours: Double = 4

    // Care plan parameters (set together with clinicians)
    var clinicianCleared: Bool = false
    var exerciseHRCap: Int? = nil
    var bpTargetSys: Int = 130
    var bpTargetDia: Int = 80
    var glucoseLow: Double = 3.9
    var glucoseHigh: Double = 10.0
    var glucosePreExerciseMin: Double = 5.0
    var glucoseExerciseMax: Double = 13.9
    var careNotes: String = ""

    // Marathon / specific sport
    var raceName: String = ""
    var raceDate: Date? = nil
    var raceTargetMinutes: Int? = nil
    var currentWeeklyKm: Double = 20
    var longestRecentRunKm: Double = 10
    var thresholdHR: Int? = nil
    var thresholdPace: String = ""
    var fuelCarbsPerHour: Int = 45

    // Data preferences
    var useHealthKit: Bool = false
    var lastSync: Date? = nil
    var usesDemoData: Bool = false
    var demoPersona: String = ""

    init() {}
}

extension UserProfile {
    var sex: Sex {
        get { Sex(rawValue: sexRaw) ?? .unspecified }
        set { sexRaw = newValue.rawValue }
    }
    var activityLevel: ActivityLevel {
        get { ActivityLevel(rawValue: activityLevelRaw) ?? .light }
        set { activityLevelRaw = newValue.rawValue }
    }
    var conditions: Set<HealthCondition> {
        get { Set(conditionsRaw.compactMap(HealthCondition.init(rawValue:))) }
        set { conditionsRaw = newValue.map(\.rawValue).sorted() }
    }
    var goals: Set<GoalDirection> {
        get { Set(goalsRaw.compactMap(GoalDirection.init(rawValue:))) }
        set { goalsRaw = newValue.map(\.rawValue).sorted() }
    }
    var journeyReached: [String: Int] {
        get {
            Dictionary(journeyReachedRaw.compactMap { e -> (String, Int)? in
                let p = e.split(separator: ":")
                return p.count == 2 ? (String(p[0]), Int(p[1]) ?? 0) : nil
            }, uniquingKeysWith: max)
        }
        set { journeyReachedRaw = newValue.map { "\($0.key):\($0.value)" }.sorted() }
    }
    var reviewPriorities: [PriorityArea] {
        get { reviewPrioritiesRaw.compactMap(PriorityArea.init(rawValue:)) }
        set { reviewPrioritiesRaw = newValue.map(\.rawValue) }
    }
    var favoriteSports: [SportPreference] {
        get { favoriteSportsRaw.compactMap(SportPreference.init(raw:)) }
        set { favoriteSportsRaw = newValue.map(\.raw) }
    }
    var modules: Set<ProModule> {
        get { Set(modulesRaw.compactMap(ProModule.init(rawValue:))) }
        set { modulesRaw = newValue.map(\.rawValue).sorted() }
    }
    var preferredTime: PreferredTime {
        get { PreferredTime(rawValue: preferredTimeRaw) ?? .flexible }
        set { preferredTimeRaw = newValue.rawValue }
    }
    var rhrMethod: RHRSource {
        get { RHRSource(rawValue: rhrMethodRaw) ?? .device }
        set { rhrMethodRaw = newValue.rawValue }
    }
    var apneaStatus: ApneaStatus {
        get { ApneaStatus(rawValue: apneaStatusRaw) ?? .unknown }
        set { apneaStatusRaw = newValue.rawValue }
    }
    var apneaTreatment: ApneaTreatment {
        get { ApneaTreatment(rawValue: apneaTreatmentRaw) ?? .none }
        set { apneaTreatmentRaw = newValue.rawValue }
    }
    /// nil when the birth year was left out (stored as 0).
    var age: Int? { hasAge ? max(0, Calendar(identifier: .gregorian).component(.year, from: .app) - birthYear) : nil }
    var bmi: Double { hasBodySize ? weightKg / pow(heightCm / 100, 2) : 0 }
    var displayName: String { nickname.isEmpty ? "你" : nickname }

    func hasModule(_ module: ProModule) -> Bool { modulesRaw.contains(module.rawValue) }
    func setModule(_ module: ProModule, enabled: Bool) {
        var set = modules
        if enabled { set.insert(module) } else { set.remove(module) }
        modules = set
        if module == .marathon, enabled, marathonStart == nil { marathonStart = .app }
    }
}

extension UserProfile {
    var shiftPattern: [ShiftKind] {
        get { shiftPatternRaw.compactMap(ShiftKind.init(rawValue:)) }
        set { shiftPatternRaw = newValue.map(\.rawValue) }
    }
    /// The roster in effect, if shift work is on and a pattern is set.
    var shiftSchedule: ShiftSchedule? {
        guard shiftWork, !shiftPattern.isEmpty, let start = shiftCycleStart else { return nil }
        return ShiftSchedule(pattern: shiftPattern, cycleStart: start, dayStart: dayShiftStart, dayEnd: dayShiftEnd,
                             nightStart: nightShiftStart, nightEnd: nightShiftEnd)
    }
}
