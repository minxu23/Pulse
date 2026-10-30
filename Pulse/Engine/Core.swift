import Foundation

// MARK: - Calendar helpers

extension Calendar {
    /// Gregorian calendar with Monday as the first weekday (中国习惯).
    static let pulse: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.locale = Locale(identifier: "zh_CN")
        c.firstWeekday = 2
        c.minimumDaysInFirstWeek = 4
        return c
    }()
}

extension Date {
    var startOfDay: Date { Calendar.pulse.startOfDay(for: self) }
    func adding(days: Int) -> Date { Calendar.pulse.date(byAdding: .day, value: days, to: self) ?? self }
    func adding(minutes: Int) -> Date { addingTimeInterval(Double(minutes) * 60) }
    var weekStart: Date { Calendar.pulse.dateInterval(of: .weekOfYear, for: self)?.start ?? startOfDay }
    var monthStart: Date { Calendar.pulse.dateInterval(of: .month, for: self)?.start ?? startOfDay }
    var daysInMonth: Int { Calendar.pulse.range(of: .day, in: .month, for: self)?.count ?? 30 }
    func adding(months: Int) -> Date { Calendar.pulse.date(byAdding: .month, value: months, to: self) ?? self }
    /// Calendar weekday: 1 = 周日 … 7 = 周六.
    var weekday: Int { Calendar.pulse.component(.weekday, from: self) }
    var hour: Int { Calendar.pulse.component(.hour, from: self) }
    var minutesOfDay: Int {
        let c = Calendar.pulse.dateComponents([.hour, .minute], from: self)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }
    func daysSince(_ other: Date) -> Int {
        Calendar.pulse.dateComponents([.day], from: other.startOfDay, to: startOfDay).day ?? 0
    }
    func isSameDay(_ other: Date) -> Bool { Calendar.pulse.isDate(self, inSameDayAs: other) }
}

enum Weekday {
    /// Calendar weekday numbers in Monday-first order.
    static let mondayFirst = [2, 3, 4, 5, 6, 7, 1]
    static func short(_ weekday: Int) -> String {
        ["日", "一", "二", "三", "四", "五", "六"][(weekday - 1 + 7) % 7]
    }
    static func name(_ weekday: Int) -> String { "周" + short(weekday) }
}

/// The day boundary people live by: until 5 am the night is not over and it is still the previous day —
/// unless the user says they are already up (「我已经起床了」, offered from 3 am).
/// The app's clock: the real time, or in the demo a chosen moment (演示时间) from which it keeps running.
/// Everything that asks "now" asks this.
extension Date {
    static var app: Date { Date().addingTimeInterval(DemoClock.offset) }
}

enum DemoClock {
    static let key = "demo.clockOffset"
    static var offset: TimeInterval { UserDefaults.standard.double(forKey: key) }
    static var isShifted: Bool { offset != 0 }
    /// Sets the app's clock to `date`; nil goes back to the real time.
    static func set(_ date: Date?) {
        UserDefaults.standard.set(date.map { $0.timeIntervalSinceNow } ?? 0, forKey: key)
    }
}

enum DayClock {
    static let rolloverHour = 5
    /// When the user started the day early (seconds since 1970; 0 = not set). Kept on this device.
    static let earlyStartKey = "day.earlyStart"
    static var earlyStart: Date? {
        let t = UserDefaults.standard.double(forKey: earlyStartKey)
        return t > 0 ? Date(timeIntervalSince1970: t) : nil
    }
    /// The user's profile for views that have no snapshot at hand (kept by the 今日 and agent readers).
    /// Engine code always passes the profile explicitly.
    static var current: ProfileSnapshot?

    /// The user is already up for the day, before the usual boundary.
    static func startedEarly(_ now: Date, _ p: ProfileSnapshot? = nil) -> Bool {
        guard let s = earlyStart else { return false }
        return s.isSameDay(now) && s <= now && now < rollover(on: now, profile: p)
    }
    /// 「我已经起床了」 is offered in the two hours before the boundary (3–5 am on a regular schedule).
    static func canStartEarly(_ now: Date, _ p: ProfileSnapshot? = nil) -> Bool {
        let r = rollover(on: now, profile: p)
        return now >= r.addingTimeInterval(-2 * 3600) && now < r && !startedEarly(now, p)
    }
    /// A mis-tap can be undone for five minutes.
    static func canUndoEarlyStart(_ now: Date, _ p: ProfileSnapshot? = nil) -> Bool {
        guard startedEarly(now, p), let s = earlyStart else { return false }
        return now.timeIntervalSince(s) < 5 * 60
    }
    static func startEarly(at now: Date = .app) { UserDefaults.standard.set(now.timeIntervalSince1970, forKey: earlyStartKey) }
    static func undoEarlyStart() { UserDefaults.standard.set(0.0, forKey: earlyStartKey) }

    /// Before the boundary the previous day is still going on.
    static func isBeforeWake(_ now: Date, _ p: ProfileSnapshot? = nil) -> Bool {
        now < rollover(on: now, profile: p) && !startedEarly(now, p)
    }
    /// The day the user is living in (yesterday's date until the boundary).
    static func logicalToday(_ now: Date, _ p: ProfileSnapshot? = nil) -> Date {
        isBeforeWake(now, p) ? now.startOfDay.adding(days: -1) : now.startOfDay
    }
}

enum Clock {
    /// Minutes past midnight → "23:30".
    static func text(_ minutes: Int) -> String {
        let m = ((minutes % 1440) + 1440) % 1440
        return String(format: "%02d:%02d", m / 60, m % 60)
    }
    /// Bedtimes straddle midnight; map to minutes after 12:00 so 23:30 and 00:30 compare sensibly.
    static func nightOffset(_ minutesOfDay: Int) -> Int {
        (minutesOfDay - 720 + 1440) % 1440
    }
}

// MARK: - Statistics

enum Stats {
    static func mean(_ xs: [Double]) -> Double? {
        xs.isEmpty ? nil : xs.reduce(0, +) / Double(xs.count)
    }
    static func sd(_ xs: [Double]) -> Double? {
        guard xs.count >= 2, let m = mean(xs) else { return nil }
        let v = xs.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(xs.count - 1)
        return v.squareRoot()
    }
    static func median(_ xs: [Double]) -> Double? {
        guard !xs.isEmpty else { return nil }
        let s = xs.sorted()
        let mid = s.count / 2
        return s.count.isMultiple(of: 2) ? (s[mid - 1] + s[mid]) / 2 : s[mid]
    }
    static func quantile(_ xs: [Double], _ q: Double) -> Double? {
        guard !xs.isEmpty else { return nil }
        let s = xs.sorted()
        let pos = q * Double(s.count - 1)
        let lo = Int(pos.rounded(.down)), hi = Int(pos.rounded(.up))
        return s[lo] + (s[hi] - s[lo]) * (pos - Double(lo))
    }
    /// Least-squares slope of y on x.
    static func slope(_ pts: [(x: Double, y: Double)]) -> Double? {
        guard pts.count >= 2 else { return nil }
        let mx = pts.map(\.x).reduce(0, +) / Double(pts.count)
        let my = pts.map(\.y).reduce(0, +) / Double(pts.count)
        let num = pts.reduce(0) { $0 + ($1.x - mx) * ($1.y - my) }
        let den = pts.reduce(0) { $0 + ($1.x - mx) * ($1.x - mx) }
        return den == 0 ? nil : num / den
    }
    /// Cohen's d with pooled SD.
    static func effectSize(_ a: [Double], _ b: [Double]) -> Double? {
        guard a.count >= 2, b.count >= 2, let ma = mean(a), let mb = mean(b),
              let sa = sd(a), let sb = sd(b) else { return nil }
        let pooled = (((Double(a.count) - 1) * sa * sa + (Double(b.count) - 1) * sb * sb) / Double(a.count + b.count - 2)).squareRoot()
        return pooled == 0 ? nil : (ma - mb) / pooled
    }
    /// Piecewise-linear interpolation through sorted (x, y) knots, clamped at both ends.
    static func interp(_ x: Double, _ knots: [(Double, Double)]) -> Double {
        guard let first = knots.first, let last = knots.last else { return 0 }
        if x <= first.0 { return first.1 }
        if x >= last.0 { return last.1 }
        for i in 1..<knots.count where x <= knots[i].0 {
            let (x0, y0) = knots[i - 1], (x1, y1) = knots[i]
            return y0 + (y1 - y0) * (x - x0) / (x1 - x0)
        }
        return last.1
    }
}

extension Double {
    func rounded(to step: Double) -> Double { (self / step).rounded() * step }
    var signedText: String { String(format: "%+.1f", self) }
    var oneDecimal: String { String(format: "%.1f", self) }
    var noDecimal: String { String(format: "%.0f", self) }
}

extension Int {
    func roundedTo5() -> Int { Int((Double(self) / 5).rounded()) * 5 }
}

// MARK: - Engine inputs (value snapshots, independent of persistence)

struct DayData: Identifiable, Equatable {
    var id: Date { day }
    let day: Date
    var rhr: Double?
    var rhrSource: RHRSource?
    var hrv: Double?
    var sleepMinutes: Double?
    var sleepStart: Date?
    var sleepEnd: Date?
    var deepMinutes: Double?
    var spo2Min: Double?
    var breathingDisturbances: Double?
    var respiratoryRate: Double?
    var vo2Max: Double?
    var steps: Int?
    var exerciseMinutes: Double?
    var energy: Int?
    var sleepFeel: Int?
    var soreness: Int?
    var stress: Int?
    var illness: Bool = false
    var tags: Set<ContextTag> = []
    var alcoholUnits: Double = 0
    var caffeineCups: Int = 0
    var lastCaffeineHour: Int?
    var waterMl: Int = 0
    var lateMeal: Bool = false
    var dietQuality: Int?
    var nutrientsLogged = false
    var saltG: Double?
    var saltSources: [String] = []
    var proteinServings: Double?
    var proteinFoods: [String] = []
    var potassiumFoods: [String] = []
    var phosphorusFoods: [String] = []
    var edema: Int?
    var edemaPlaces: [String] = []
    var urineOutput: Int?
    var urineMl: Int?
    var foamyUrine: Bool?
    var snoring = false
    var gasping = false
    var witnessedApnea = false
    var morningHeadache = false
    var daytimeSleepy = false
    var cpapHours: Double?
    var eveningFatigue: Int?
    var eveningSoreness: Int?
    var eveningStress: Int?
    var plannedBedtime: Date?
    var load: Double = 0
    var hardSession = false
    var sessionMinutes: Double = 0
    var checkedIn = false
    var medsTaken: Bool?

    init(day: Date) { self.day = day.startOfDay }

    var isIll: Bool { illness || tags.contains(.illness) }
    var highStress: Bool { (stress ?? 0) >= 4 || tags.contains(.highStress) }
    var hadAlcohol: Bool { alcoholUnits > 0 || tags.contains(.alcohol) }
    func lateCaffeine(cutoff: Int) -> Bool {
        tags.contains(.lateCaffeine) || (caffeineCups > 0 && (lastCaffeineHour ?? 0) >= cutoff)
    }
    /// Activity minutes for the day: the larger of device exercise minutes and logged sessions.
    var activeMinutes: Double { max(exerciseMinutes ?? 0, sessionMinutes) }
}

struct MedicationInfo: Equatable {
    var name: String
    var category: MedicationCategory
    var start: Date
    var end: Date?
    func isActive(on date: Date) -> Bool { start <= date && (end.map { $0 > date } ?? true) }
}

struct RaceInfo: Equatable {
    var name: String
    var date: Date
    var targetMinutes: Int?
    var startDate: Date
    var currentWeeklyKm: Double
    var longestRunKm: Double
    var fuelCarbsPerHour: Int
}

struct ProfileSnapshot: Equatable {
    var age: Int = 38
    var sex: Sex = .unspecified
    var bmi: Double = 23
    var neckCm: Double?
    var level: ActivityLevel = .light
    var conditions: Set<HealthCondition> = []
    var medications: [MedicationInfo] = []
    var goals: Set<GoalDirection> = [.lowerRHR]
    var modules: Set<ProModule> = []
    /// The furthest stage reached on each goal's path.
    var journeyReached: [String: Int] = [:]
    var availableWeekdays: [Int] = [3, 5, 7]
    var sessionMinutes: Int = 40
    var weeklyTimeBudget: Int = 180
    var weeklyTargetMinutes: Int = 90
    var baselineRHR: Double?
    var sleepNeedMinutes: Double = 450
    var bedtimeMinutes: Int = 23 * 60
    var wakeMinutes: Int = 7 * 60
    var caffeineCutoffHour: Int = 14
    var weeklyAlcoholLimit: Double = 4
    var waterTargetMl: Int = 1800
    /// 限水: `waterTargetMl` is the most to drink in a day; Pulse never says to drink more.
    var fluidLimited = false
    /// Conditions Pulse learned about in conversation, with what it changes for them.
    var extraConditions: [ConditionInfo] = []
    /// Kidney diet: record salt, protein, potassium and phosphorus, against the doctor's amounts.
    var tracksNutrients = false
    var saltLimitG: Double = 5
    var proteinTargetG: Int?
    var potassiumLimit = false
    var phosphorusLimit = false
    var limitsPotassium: Bool { potassiumLimit || extraConditions.contains { $0.id == "hyperkalemia" } }
    var limitsPhosphorus: Bool { phosphorusLimit }
    /// 血液透析: no training on session days, fluids limited, weight watched between sessions.
    var onDialysis = false
    var dialysisWeekdays: [Int] = []
    var dryWeightKg: Double?
    var stepsTarget: Int = 8000
    var hrCap: Int?
    var clinicianCleared: Bool = false
    var thresholdHR: Int?
    var apneaStatus: ApneaStatus = .unknown
    var apneaTreatment: ApneaTreatment = .none
    var cpapTargetHours: Double = 4
    var glucoseLow: Double = 3.9
    var glucoseHigh: Double = 10.0
    var glucosePreExerciseMin: Double = 5.0
    var glucoseExerciseMax: Double = 13.9
    var bpTargetSys: Int = 130
    var bpTargetDia: Int = 80
    var limitations: String = ""
    var race: RaceInfo?
    /// A rotating roster (倒班); nil on a regular schedule.
    var shift: ShiftSchedule?

    var hasCardiac: Bool { conditions.contains { $0.isCardiovascular } || modules.contains(.cardioCare) }
    var hasDiabetes: Bool { conditions.contains { $0.isDiabetes } || modules.contains(.diabetesCare) }
    var cardiacLimited: Bool { hasCardiac && !clinicianCleared }
    /// Kidney disease without a doctor-confirmed intensity range: moderate at most.
    var kidneyLimited: Bool { conditions.contains(.ckd) && !clinicianCleared }
    /// A quick rise in weight is worth an alert (fluid retention).
    var watchesWeight: Bool { fluidLimited || onDialysis || conditions.contains(where: \.watchesFluid) }
    /// Why hot days move outdoor sessions indoors: sweating is a risk, or drinking more is not allowed.
    var heatCauses: [String] { (fluidLimited ? ["限水"] : []) + extraConditions.filter(\.avoidHeat).map(\.name) }
    var heatSensitive: Bool { !heatCauses.isEmpty }
    /// No interval or other hard sessions, because of these conditions.
    var intensityCaps: [String] {
        (kidneyLimited ? [HealthCondition.ckd.label] : []) + extraConditions.filter { $0.moderateOnly || $0.noImpact }.map(\.name)
    }
    var intensityCapped: Bool { !intensityCaps.isEmpty }
    /// Every condition by name, built-in ones first.
    var conditionNames: [String] { conditions.map(\.label).sorted() + extraConditions.map(\.name) }

    /// Counts a condition the user just mentioned, before it is recorded.
    mutating func include(_ x: ConditionInfo) {
        if let n = x.native { conditions.insert(n) }
        else if !extraConditions.contains(where: { $0.id == x.id }) { extraConditions.append(x) }
    }
    func onRateLoweringMeds(at date: Date = .app) -> Bool {
        medications.contains { $0.category.bluntsHeartRate && $0.isActive(on: date) }
    }
    func hypoRiskMeds(at date: Date = .app) -> Bool {
        medications.contains { $0.category.hypoglycemiaRisk && $0.isActive(on: date) }
    }
    var estimatedMaxHR: Double { 208 - 0.7 * Double(age) }
}

/// A plain view of a planned session used by the adjustment and review engines.
struct SessionSnapshot: Identifiable, Equatable {
    var id: UUID
    var day: Date
    var kind: PlanKind
    var title: String
    var minutes: Int
    var minimumMinutes: Int
    var minimumDetail: String
    var intensity: Intensity
    var isKey: Bool
    var status: PlanStatus
    var completedMinutes: Int?
    /// New description when a conversation changed what the session is.
    var newDetail: String? = nil
}

struct WorkoutPoint: Equatable {
    var start: Date
    var type: WorkoutType
    var minutes: Double
    var avgHR: Double?
    var rpe: Int?
    var distanceKm: Double?
}

struct VitalPoint: Equatable {
    var time: Date
    var kind: VitalKind
    var value: Double
    var value2: Double?
    var context: MeasureContext
}

enum Confidence: String {
    case high, medium, low
    var label: String {
        switch self {
        case .high: "依据充分"
        case .medium: "依据部分可用"
        case .low: "依据有限"
        }
    }
}
