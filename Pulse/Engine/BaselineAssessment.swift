import Foundation

// 基线期 (三阶段计划): a week of records becomes a health portrait (four abilities, each metric placed
// among peers where a defensible reference exists), a habit profile (when and how the user moves, how
// the heart behaves in each sport), what is still missing, and danger signs that come before any plan.
// Pure functions of the records, so the report can be frozen as a snapshot and tested.

enum Ability: String, CaseIterable, Identifiable, Codable {
    case heart, fitness, metabolic, sleep
    var id: String { rawValue }
    var title: String {
        switch self {
        case .heart: "心脏健康"
        case .fitness: "心肺与运动能力"
        case .metabolic: "代谢健康"
        case .sleep: "睡眠与恢复"
        }
    }
    var icon: String {
        switch self {
        case .heart: "heart"
        case .fitness: "figure.run"
        case .metabolic: "flame"
        case .sleep: "bed.double"
        }
    }
}

/// How a metric reads, worst last.
enum Verdict: Int, Comparable, Codable {
    case good, fair, attention, urgent
    static func < (a: Verdict, b: Verdict) -> Bool { a.rawValue < b.rawValue }
    var label: String {
        switch self {
        case .good: "良好"
        case .fair: "一般"
        case .attention: "需要关注"
        case .urgent: "建议就医"
        }
    }
}

enum DataQuality: String, Codable {
    case measured, estimated, missing
    var label: String {
        switch self {
        case .measured: "实测"
        case .estimated: "估算"
        case .missing: "数据不足"
        }
    }
}

struct BaselineMetric: Identifiable, Equatable, Codable {
    enum Kind: String, Codable {
        case rhr, hrv, rhythm, hrRecovery, bloodPressure
        case vo2max, steps, activeMinutes, strength
        case bmi, waist, bodyFat, glucose, hba1c
        case sleepDuration, sleepRegularity, breathing
    }
    let kind: Kind
    var id: Kind { kind }
    var title: String
    /// The number other parts compare (bpm, mL/kg/min, steps, %, mmHg systolic…); nil when missing.
    var value: Double?
    var valueText: String
    var quality: DataQuality
    var rank: PeerRank? = nil
    var verdict: Verdict? = nil
    /// One plain sentence on what it means.
    var detail: String
    /// About the data: how many readings, which reference, what to do to get it.
    var note: String? = nil
}

struct AbilityCard: Identifiable, Equatable, Codable {
    let ability: Ability
    var id: Ability { ability }
    var metrics: [BaselineMetric]
    /// The worst verdict among its metrics.
    var verdict: Verdict? { metrics.compactMap(\.verdict).max() }
    /// The lowest peer band among its ranked metrics.
    var band: RankBand? { metrics.compactMap { $0.rank?.band }.min() }
    var summary: String {
        let flagged = metrics.filter { ($0.verdict ?? .good) >= .attention }
        if flagged.isEmpty {
            let fair = metrics.filter { $0.verdict == .fair }
            return fair.isEmpty ? (metrics.contains { $0.verdict != nil } ? "各项都在合适的范围" : "数据还不够")
                : "\(fair.map(\.title).joined(separator: "、"))还有提升空间"
        }
        return "\(flagged.map(\.title).joined(separator: "、"))需要关注"
    }
}

enum TimeSlot: String, CaseIterable, Codable {
    case earlyMorning, morning, noon, afternoon, evening, night
    init(hour h: Int) {
        switch h {
        case 5..<9: self = .earlyMorning
        case 9..<11: self = .morning
        case 11..<14: self = .noon
        case 14..<17: self = .afternoon
        case 17..<20: self = .evening
        default: self = .night
        }
    }
    var label: String {
        switch self {
        case .earlyMorning: "早晨"
        case .morning: "上午"
        case .noon: "午间"
        case .afternoon: "下午"
        case .evening: "傍晚"
        case .night: "晚上"
        }
    }
}

/// One sport as the user actually does it, from the last 4 weeks.
struct SportHabit: Identifiable, Equatable, Codable {
    var type: WorkoutType
    var id: WorkoutType { type }
    var sessions: Int
    var perWeek: Double
    var minutes: Double
    /// Most common weekdays (Calendar numbers), most frequent first.
    var weekdays: [Int]
    var slot: TimeSlot?
    /// Mean heart rate as a share of heart-rate reserve (0–1), when heart rate was read.
    var reserveShare: Double?
    /// Share of the time at vigorous heart rate (0–1).
    var vigorousShare: Double?
    var intensity: Intensity
    var recovery: Double?
}

struct HabitProfile: Equatable, Codable {
    var days = 0
    var stepsMean: Double?
    var weekdaySteps: Double?
    var weekendSteps: Double?
    /// Average steps in each clock hour.
    var hourly: [Double] = []
    var peakHours: [Int] = []
    var daysAtPlateau = 0
    var standHours: Double?

    /// Sessions in the last 4 weeks, by time of day.
    var slots: [TimeSlot: Int] = [:]
    var mainSlot: TimeSlot?
    /// Weekdays the user usually exercised on, most frequent first; nil in reports saved before this was kept.
    var usualWeekdays: [Int]? = nil
    var sessions = 0
    /// Sessions that started within 2 hours after a meal; nil when meals aren't known.
    var afterMeal: Int?
    /// Meals came from glucose rises, not from the meal log.
    var mealsFromGlucose = false
    var sports: [SportHabit] = []

    /// Per week.
    var moderateMinutes = 0.0
    var vigorousMinutes = 0.0
    /// Moderate + 2 × vigorous, the guideline's 150-minute count.
    var guidelineMinutes: Double { moderateMinutes + 2 * vigorousMinutes }
    var hrMax = 0.0
    var hrMaxMeasured = false
    var restingHR = 0.0
    /// False on heart-rate-lowering medicines: zones from heart rate aren't reliable.
    var zonesReliable = true

    var alcoholPerWeek = 0.0
    var lateCaffeineDays = 0
    var lateMealDays = 0
    /// Bedtime in minutes after midnight (can exceed 24 h for after-midnight bedtimes).
    var bedtimeMean: Double?
    var bedtimeSD: Double?
    /// Wake time in minutes after midnight (nil in reports saved before).
    var wakeMean: Double? = nil
    /// How much later bedtime is on Friday and Saturday nights (minutes).
    var weekendShift: Double?

    var moderateFloor: Double { restingHR + 0.4 * (hrMax - restingHR) }
    var vigorousFloor: Double { restingHR + 0.6 * (hrMax - restingHR) }
}

struct BaselineCompleteness: Equatable, Codable {
    struct Item: Equatable, Codable {
        var label: String
        var have: Int
        var need: Int
        var required: Bool
        var hint: String
        var met: Bool { have >= need }
    }
    var items: [Item]
    var isReady: Bool { items.filter(\.required).allSatisfy(\.met) }
    var missing: [Item] { items.filter { $0.required && !$0.met } }
    /// What still needs doing with `daysLeft` days to go: one-off items (the outdoor walk for the VO2max estimate)
    /// until they are done; daily ones only once the days left can't fill them, since wearing the watch fills them.
    func stillToDo(daysLeft: Int) -> [Item] { missing.filter { $0.need <= 1 || $0.need - $0.have > daysLeft } }
}

struct BaselineReport: Equatable, Codable {
    var window: DateInterval
    var completeness: BaselineCompleteness
    var cards: [AbilityCard]
    var habits: HabitProfile
    /// Things to see a doctor about before training harder.
    var redFlags: [String]
    /// Worth a word with a doctor, without holding the plan back.
    var cautions: [String] = []
    /// What kind each red flag is (raw `RedFlag.Kind`); nil in reports saved before kinds were kept.
    var redFlagKinds: [String]? = nil

    /// The kinds of danger sign in this report.
    var dangerKinds: Set<RedFlag.Kind> { Set((redFlagKinds ?? []).compactMap(RedFlag.Kind.init(rawValue:))) }

    func metric(_ k: BaselineMetric.Kind) -> BaselineMetric? { cards.lazy.flatMap(\.metrics).first { $0.kind == k } }
    func card(_ a: Ability) -> AbilityCard? { cards.first { $0.ability == a } }
}

struct BaselineInput {
    var profile: ProfileSnapshot
    var days: [DayData]
    var workouts: [WorkoutPoint]
    var vitals: [VitalPoint]
    /// Logged meal times.
    var meals: [Date] = []
    var labs: [LabPoint] = []
    /// Irregular-rhythm notifications and ECG AF results.
    var rhythmAlerts: [Date] = []
    /// The baseline days, [start, end).
    var window: DateInterval
}

enum BaselineAssessment {
    static let windowDays = 7
    /// Sports and timing look further back: a week holds too few sessions to see a habit.
    static let habitDays = 28

    static func assess(_ x: BaselineInput) -> BaselineReport {
        let p = x.profile
        let start = x.window.start.startOfDay, end = x.window.end
        let days = x.days.filter { $0.day >= start && $0.day < end }
        let habitStart = min(start, end.startOfDay.adding(days: -habitDays))
        let recentWorkouts = x.workouts.filter { $0.start >= habitStart && $0.start < end }
        let habits = habitProfile(x, days: days, workouts: recentWorkouts, habitStart: habitStart)
        var cards = [heart(x, days: days, workouts: recentWorkouts, habits: habits), fitness(x, days: days, habits: habits),
                     metabolic(x, days: days), sleep(x, days: days)]
        // Never rank against a fabricated age/sex, or treat unknown body measurements as low BMI.
        if !p.ageKnown || p.sex == .unspecified {
            for i in cards.indices {
                for j in cards[i].metrics.indices {
                    let kind = cards[i].metrics[j].kind
                    if [.rhr, .vo2max, .bodyFat, .waist].contains(kind) {
                        cards[i].metrics[j].rank = nil
                        if cards[i].metrics[j].verdict != .urgent { cards[i].metrics[j].verdict = nil }
                        cards[i].metrics[j].detail = "补充年龄、性别后提供同龄评价；当前仅展示记录。"
                    }
                }
            }
        }
        let signs = dangerSigns(x, cards: cards)
        return BaselineReport(window: x.window, completeness: completeness(x, days: days),
                              cards: cards, habits: habits, redFlags: signs.map(\.text),
                              cautions: cautions(x, habits: habits), redFlagKinds: signs.map(\.kind.rawValue))
    }

    // MARK: Completeness

    static func completeness(_ x: BaselineInput, days: [DayData]) -> BaselineCompleteness {
        let vo2Back = x.window.end.startOfDay.adding(days: -30)
        let vo2 = x.days.filter { $0.day >= vo2Back && $0.day < x.window.end && $0.vo2Max != nil }.count
        var items: [BaselineCompleteness.Item] = [
            .init(label: "睡眠", have: days.filter { $0.sleepMinutes != nil }.count, need: 5, required: true,
                  hint: "睡觉时戴着手表"),
            .init(label: "晨起静息心率", have: days.filter { $0.rhr != nil }.count, need: 5, required: true,
                  hint: "夜里戴着手表，早上就有静息心率"),
            .init(label: "步数", have: days.filter { ($0.steps ?? 0) > 0 }.count, need: 5, required: true,
                  hint: "白天戴着手表"),
            .init(label: "心肺能力估算", have: vo2, need: 1, required: true,
                  hint: "戴着手表做一次 20 分钟以上的户外快走或慢跑"),
        ]
        let weighIns = x.vitals.filter { $0.kind == .weight && $0.time >= x.window.start && $0.time < x.window.end }.count
        items.append(.init(label: "体重和体脂", have: weighIns, need: 2, required: false,
                           hint: "早上起床、排便后空腹称"))
        if x.profile.conditions.contains(.hypertension) || x.profile.hasBPMonitor == true {
            let bp = x.vitals.filter { $0.kind == .bloodPressure && $0.time >= x.window.start && $0.time < x.window.end }.count
            items.append(.init(label: "家庭血压", have: bp, need: 12, required: false,
                               hint: "每天早晚各测 2 次"))
        }
        return BaselineCompleteness(items: items)
    }

    // MARK: Habits

    static func habitProfile(_ x: BaselineInput, days: [DayData], workouts: [WorkoutPoint], habitStart: Date) -> HabitProfile {
        let p = x.profile
        var h = HabitProfile()
        let full = days.filter { $0.day < x.window.end.startOfDay || x.window.end.startOfDay == x.window.end }
        h.days = full.count

        // Steps
        let stepDays = full.filter { $0.steps != nil }
        h.stepsMean = Stats.mean(stepDays.compactMap { $0.steps.map(Double.init) })
        let weekend = { (d: DayData) in [1, 7].contains(Calendar.pulse.component(.weekday, from: d.day)) }
        h.weekdaySteps = Stats.mean(stepDays.filter { !weekend($0) }.compactMap { $0.steps.map(Double.init) })
        h.weekendSteps = Stats.mean(stepDays.filter(weekend).compactMap { $0.steps.map(Double.init) })
        let hourly = stepDays.map(\.stepsByHour).filter { $0.count == 24 }
        if !hourly.isEmpty {
            h.hourly = (0..<24).map { i in Double(hourly.map { $0[i] }.reduce(0, +)) / Double(hourly.count) }
            h.peakHours = Array((0..<24).sorted { h.hourly[$0] > h.hourly[$1] }.prefix(3)).sorted()
        }
        let plateau = Double(PopulationNorms.stepPlateau(age: p.age).lowerBound)
        h.daysAtPlateau = stepDays.filter { Double($0.steps ?? 0) >= plateau }.count
        h.standHours = Stats.mean(full.compactMap { $0.standHours.map(Double.init) })

        // Heart-rate zones: resting from the baseline, maximum from the formula unless sessions went higher.
        h.restingHR = Stats.median(days.compactMap(\.rhr)) ?? p.baselineRHR ?? 65
        let formula = p.estimatedMaxHR
        let observed = workouts.compactMap { w -> Double? in
            let s = w.hrSeries.sorted()
            return s.count >= 3 ? Double(s[s.count - 2]) : w.maxHR
        }.max()
        // Without an age there is no formula and the zones are not used (zonesReliable).
        if let formula, let o = observed, o > formula, o < formula + 15 { h.hrMax = o; h.hrMaxMeasured = true } else { h.hrMax = formula ?? 0 }
        let slowing: Set<MedicationCategory> = [.betaBlocker, .rateLimitingCCB, .antiarrhythmic]
        h.zonesReliable = p.ageKnown && !p.medications.contains { slowing.contains($0.category) && ($0.end ?? .distantFuture) > x.window.start }

        // Minutes by intensity, per week.
        let weeks = Double(max(1, x.window.end.daysSince(habitStart))) / 7
        var moderate = 0.0, vigorous = 0.0
        for w in workouts {
            let z = zones(w, h)
            moderate += z.moderate
            vigorous += z.vigorous
        }
        h.moderateMinutes = (moderate / weeks).rounded()
        h.vigorousMinutes = (vigorous / weeks).rounded()

        // Timing
        h.sessions = workouts.count
        for w in workouts { h.slots[TimeSlot(hour: w.start.hour), default: 0] += 1 }
        h.mainSlot = h.slots.max { $0.value < $1.value || ($0.value == $1.value && $0.key.rawValue > $1.key.rawValue) }?.key
        // The weekdays with exercise at least twice in these weeks, most frequent first (walks of under 20 minutes don't count).
        let byWeekday = Dictionary(grouping: workouts.filter { $0.type != .walk || $0.minutes >= 20 }, by: { Calendar.pulse.component(.weekday, from: $0.start) })
        h.usualWeekdays = byWeekday.filter { $0.value.count >= 2 }
            .sorted { $0.value.count != $1.value.count ? $0.value.count > $1.value.count : PlanGenerator.order($0.key) < PlanGenerator.order($1.key) }
            .map(\.key)
        var meals = x.meals.filter { $0 >= habitStart && $0 < x.window.end }
        if meals.count < 5 {
            let fromGlucose = mealRises(x.vitals.filter { $0.kind == .glucose && $0.time >= habitStart && $0.time < x.window.end })
            if fromGlucose.count >= 5 { meals = fromGlucose; h.mealsFromGlucose = true }
        }
        if meals.count >= 5 {
            h.afterMeal = workouts.filter { w in meals.contains { w.start.timeIntervalSince($0) >= 10 * 60 && w.start.timeIntervalSince($0) <= 120 * 60 } }.count
        }

        // Sports
        for (type, list) in Dictionary(grouping: workouts, by: \.type) {
            let series = list.flatMap(\.hrSeries).map(Double.init)
            let avgs = list.compactMap { $0.hrSeries.isEmpty ? $0.avgHR : Stats.mean($0.hrSeries.map(Double.init)) }
            let reserve = h.zonesReliable ? Stats.mean(avgs).map { ($0 - h.restingHR) / max(1, h.hrMax - h.restingHR) } : nil
            let vig = h.zonesReliable && !series.isEmpty ? Double(series.filter { $0 >= h.vigorousFloor }.count) / Double(series.count) : nil
            let rpe = Stats.mean(list.map { Double($0.rpe ?? $0.type.defaultRPE) }) ?? 4
            let intensity: Intensity
            if let r = reserve { intensity = r >= 0.6 ? .hard : r >= 0.4 ? .moderate : .easy }
            else { intensity = rpe >= 7 ? .hard : rpe >= 4 ? .moderate : .easy }
            let wd = Dictionary(grouping: list) { Calendar.pulse.component(.weekday, from: $0.start) }
            let slots = Dictionary(grouping: list) { TimeSlot(hour: $0.start.hour) }
            h.sports.append(SportHabit(
                type: type, sessions: list.count, perWeek: (Double(list.count) / weeks).rounded(to: 0.1),
                minutes: (Stats.mean(list.map(\.minutes)) ?? 0).rounded(),
                weekdays: wd.filter { $0.value.count >= 2 }.sorted { $0.value.count > $1.value.count }.prefix(3).map(\.key),
                slot: slots.max { $0.value.count < $1.value.count }?.key,
                reserveShare: reserve.map { $0.rounded(to: 0.01) }, vigorousShare: vig.map { $0.rounded(to: 0.01) },
                intensity: intensity, recovery: Stats.median(list.compactMap(\.hrRecovery))))
        }
        h.sports.sort { $0.sessions > $1.sessions || ($0.sessions == $1.sessions && $0.type.rawValue < $1.type.rawValue) }

        // Lifestyle
        let n = Double(max(1, full.count))
        h.alcoholPerWeek = (full.map(\.alcoholUnits).reduce(0, +) * 7 / n).rounded(to: 0.5)
        h.lateCaffeineDays = full.filter { ($0.lastCaffeineHour ?? 0) >= p.caffeineCutoffHour && $0.caffeineCups > 0 }.count
        h.lateMealDays = full.filter(\.lateMeal).count
        let beds = days.compactMap { d -> (Double, Bool)? in
            guard let s = d.sleepStart else { return nil }
            var m = Double(s.hour * 60 + Calendar.pulse.component(.minute, from: s))
            if m < 12 * 60 { m += 24 * 60 }
            return (m, weekend(d))
        }
        h.bedtimeMean = Stats.mean(beds.map(\.0))
        h.bedtimeSD = beds.count >= 3 ? Stats.sd(beds.map(\.0)) : nil
        if let we = Stats.mean(beds.filter(\.1).map(\.0)), let wd = Stats.mean(beds.filter { !$0.1 }.map(\.0)) { h.weekendShift = we - wd }
        h.wakeMean = Stats.mean(days.compactMap { $0.sleepEnd.map { Double($0.minutesOfDay) } })
        return h
    }

    /// Minutes at moderate and vigorous effort: from minute-by-minute heart rate when it is reliable,
    /// otherwise from the session's average heart rate or how hard it felt.
    static func zones(_ w: WorkoutPoint, _ h: HabitProfile) -> (moderate: Double, vigorous: Double) {
        if h.zonesReliable, !w.hrSeries.isEmpty {
            let scale = w.minutes / Double(w.hrSeries.count)
            let vig = Double(w.hrSeries.filter { Double($0) >= h.vigorousFloor }.count) * scale
            let mod = Double(w.hrSeries.filter { Double($0) >= h.moderateFloor && Double($0) < h.vigorousFloor }.count) * scale
            return (mod, vig)
        }
        if h.zonesReliable, let a = w.avgHR {
            return a >= h.vigorousFloor ? (0, w.minutes) : a >= h.moderateFloor ? (w.minutes, 0) : (0, 0)
        }
        let rpe = w.rpe ?? w.type.defaultRPE
        return rpe >= 7 ? (0, w.minutes) : rpe >= 4 ? (w.minutes, 0) : (0, 0)
    }

    /// Meals read from a CGM: the low point before a rise of 1.5 mmol/L or more within 45 minutes.
    static func mealRises(_ glucose: [VitalPoint]) -> [Date] {
        let g = glucose.sorted { $0.time < $1.time }
        guard g.count >= 48 else { return [] }
        var out: [Date] = []
        for (i, v) in g.enumerated() {
            guard out.last.map({ v.time.timeIntervalSince($0) > 2 * 3600 }) ?? true else { continue }
            let before = g[max(0, i - 6)..<i].map(\.value)
            guard before.allSatisfy({ $0 >= v.value - 0.05 }) else { continue }
            if g[(i + 1)...].prefix(while: { $0.time.timeIntervalSince(v.time) <= 45 * 60 }).contains(where: { $0.value >= v.value + 1.5 }) {
                out.append(v.time)
            }
        }
        return out
    }

    // MARK: Abilities

    /// The age a peer rank is worked out for. Without a known age `assess` takes the ranks off again, so a
    /// rank against a made-up age is never shown.
    private static func rankAge(_ p: ProfileSnapshot) -> Int { p.age ?? 40 }

    static func heart(_ x: BaselineInput, days: [DayData], workouts: [WorkoutPoint], habits h: HabitProfile) -> AbilityCard {
        let p = x.profile
        var m: [BaselineMetric] = []

        if let rhr = Stats.median(days.compactMap(\.rhr)) {
            let r = PopulationNorms.restingHR.rank(rhr, age: rankAge(p), sex: p.sex)
            let verdict: Verdict = rhr > 100 ? .urgent : r.band.isLow ? .attention : r.band == .lowerMid ? .fair : .good
            m.append(BaselineMetric(kind: .rhr, title: "静息心率", value: rhr, valueText: "\(Int(rhr.rounded())) 次/分",
                                    quality: .measured, rank: r, verdict: verdict,
                                    detail: rhr > 100 ? "一直高于 100 次/分，建议就医查找原因" : "在同龄同性别里\(r.approx)。越低通常说明心脏越省力",
                                    note: r.reference.note))
        } else {
            m.append(missing(.rhr, "静息心率", "夜里戴着手表，早上就有静息心率"))
        }

        let hrv = Stats.median(days.compactMap(\.hrv))
        let usual = Stats.median(x.days.filter { $0.day < x.window.start && $0.day >= x.window.start.adding(days: -60) }.compactMap(\.hrv))
        if let v = hrv {
            let low = usual.map { v < 0.85 * $0 } ?? false
            m.append(BaselineMetric(kind: .hrv, title: "心率变异性", value: v, valueText: "\(Int(v.rounded())) 毫秒", quality: .measured,
                                    verdict: low ? .fair : .good,
                                    detail: low ? "比你之前两个月低（平时约 \(Int(usual!.rounded())) 毫秒），可能是最近累或睡得少" : "HRV 只和自己比：它随年龄下降，测量方式也会让数值差很多",
                                    note: "手表的 HRV 是短时测量，没有可靠的人群排名"))
        }

        let since = x.window.end.adding(days: -90)
        let alerts = x.rhythmAlerts.filter { $0 >= since && $0 < x.window.end }.count
        let burden = x.days.filter { $0.day >= since && $0.day < x.window.end }.compactMap(\.afBurden).max()
        let afECG = x.days.contains { $0.day >= since && $0.day < x.window.end && $0.ecgResult == .afib }
        let hasWatch = days.contains { $0.rhr != nil }
        if alerts > 0 || (burden ?? 0) > 0 || afECG {
            m.append(BaselineMetric(kind: .rhythm, title: "心律", value: 1, valueText: "有提示", quality: .measured, verdict: .urgent,
                                    detail: "手表\(afECG ? "心电图提示房颤" : alerts > 0 ? "近 3 个月有不规则心律通知" : "记录到房颤负荷")。这不是诊断，请就医确认",
                                    note: nil))
        } else if hasWatch {
            m.append(BaselineMetric(kind: .rhythm, title: "心律", value: 0, valueText: "未见提示", quality: .measured, verdict: .good,
                                    detail: "近 3 个月没有不规则心律通知", note: "手表只能提示可能的房颤，不能排除其他心律问题"))
        }

        // Judged only after hard sessions (the drop depends on how high heart rate went); ≤ 12 bpm is slow (Cole 1999).
        let hard = workouts.filter { w in
            guard w.hrRecovery != nil, let avg = w.hrSeries.isEmpty ? w.avgHR : Stats.mean(w.hrSeries.map(Double.init)) else { return false }
            return h.zonesReliable && avg >= h.vigorousFloor
        }
        if hard.count >= 2, let hrr = Stats.median(hard.compactMap(\.hrRecovery)) {
            let slow = hrr <= 12
            m.append(BaselineMetric(kind: .hrRecovery, title: "心率恢复", value: hrr, valueText: "1 分钟降 \(Int(hrr.rounded())) 次",
                                    quality: .measured, verdict: slow ? .attention : .good,
                                    detail: slow ? "运动后心率降得偏慢，常见于体能基础较弱" : "运动后心率下降正常",
                                    note: "来自 \(hard.count) 次较高强度运动结束后的 1 分钟。手表没有公布这项的人群参考，只看快慢和自己的变化"))
        } else if let hrr = Stats.median(workouts.compactMap(\.hrRecovery)) {
            m.append(BaselineMetric(kind: .hrRecovery, title: "心率恢复", value: hrr, valueText: "1 分钟降 \(Int(hrr.rounded())) 次",
                                    quality: .measured, verdict: nil,
                                    detail: "最近运动时心率升得还不够高，暂不评价",
                                    note: "心率升得不高时，运动后降得也少，这个数不能说明快慢"))
        }

        let bp = x.vitals.filter { $0.kind == .bloodPressure && $0.time >= x.window.start && $0.time < x.window.end }
        if bp.count >= 4, let sys = Stats.mean(bp.map(\.value)), let dia = Stats.mean(bp.compactMap(\.value2)) {
            let treated = p.conditions.contains(.hypertension)
            let target = treated ? (Double(p.bpTargetSys), Double(p.bpTargetDia)) : (135.0, 85.0)
            let peak = bp.contains { $0.value >= 180 || ($0.value2 ?? 0) >= 110 }
            // Home readings: 135/85 is the line (it matches 140/90 in the clinic), or the doctor's target.
            let verdict: Verdict = peak || sys >= 160 || dia >= 100 ? .urgent : (sys >= target.0 || dia >= target.1) ? .attention : .good
            let text = "\(Int(sys.rounded()))/\(Int(dia.rounded()))"
            m.append(BaselineMetric(kind: .bloodPressure, title: "家庭血压", value: sys, valueText: text, quality: .measured, verdict: verdict,
                                    detail: verdict == .urgent ? "明显偏高，请先就医" : verdict == .attention
                                        ? (treated ? "高于医生给的目标 \(p.bpTargetSys)/\(p.bpTargetDia)" : "家庭血压平均达到 135/85，建议去医院确认")
                                        : treated ? "在医生给的目标以内" : "在家庭血压的正常范围（< 135/85）",
                                    note: "\(bp.count) 次读数的平均"))
        } else if p.conditions.contains(.hypertension) {
            m.append(missing(.bloodPressure, "家庭血压", "每天早晚各测 2 次，连续 7 天"))
        }
        return AbilityCard(ability: .heart, metrics: m)
    }

    static func fitness(_ x: BaselineInput, days: [DayData], habits h: HabitProfile) -> AbilityCard {
        let p = x.profile
        var m: [BaselineMetric] = []

        var estimates = days.compactMap(\.vo2Max)
        var stale: Int? = nil
        if estimates.isEmpty, let last = x.days.last(where: { $0.day < x.window.end && $0.day >= x.window.end.adding(days: -30) && $0.vo2Max != nil }) {
            estimates = [last.vo2Max!]
            stale = x.window.end.daysSince(last.day)
        }
        if let vo2 = Stats.mean(estimates) {
            let r = PopulationNorms.vo2max.rank(vo2, age: rankAge(p), sex: p.sex)
            let age = PopulationNorms.fitnessAge(vo2: vo2, sex: p.sex)
            var note = r.reference.note
            if estimates.count < 3 { note += stale.map { "最近一次估算在 \($0) 天前。" } ?? "这周只有 \(estimates.count) 次估算，多做几次户外快走会更准。" }
            if !h.zonesReliable { note += "服用控制心率的药物时，手表的估算可能偏差更大。" }
            m.append(BaselineMetric(kind: .vo2max, title: "最大摄氧量", value: vo2, valueText: "\(vo2.shortDecimal)",
                                    quality: .estimated, rank: r,
                                    verdict: r.band.isLow ? .attention : r.band == .lowerMid ? .fair : .good,
                                    detail: "在同龄同性别里\(r.approx)，心肺年龄约 \(age) 岁", note: note))
        } else {
            m.append(missing(.vo2max, "最大摄氧量", "戴着手表做一次 20 分钟以上的户外快走或慢跑，手表才会估算"))
        }

        if let s = strength(p) { m.append(s) }

        if let steps = h.stepsMean {
            let band = PopulationNorms.stepBand(steps, age: p.age)
            let plateau = PopulationNorms.stepPlateau(age: p.age)
            m.append(BaselineMetric(kind: .steps, title: "日均步数", value: steps, valueText: "\(Int(steps.rounded())) 步", quality: .measured,
                                    verdict: band == .sedentary ? .attention : band == .low ? .fair : .good,
                                    detail: band >= .good ? "研究显示步数越多风险越低，到 \(plateau.lowerBound)–\(plateau.upperBound) 步以后获益趋于平稳，你已经走到这里"
                                        : "\(band.label)。研究显示步数越多风险越低，你这个年龄到 \(plateau.lowerBound)–\(plateau.upperBound) 步以后获益趋于平稳",
                                    note: "没有可靠的中国人群步数排名，所以和研究里的获益曲线比"))
        }

        let g = h.guidelineMinutes
        m.append(BaselineMetric(kind: .activeMinutes, title: "中高强度运动", value: g, valueText: "每周 \(Int(g)) 分钟", quality: h.sessions > 0 ? .measured : .missing,
                                verdict: g >= 150 ? .good : g >= 75 ? .fair : .attention,
                                detail: "指南建议每周 150–300 分钟中等强度，高强度 1 分钟算 2 分钟",
                                note: h.zonesReliable ? "按运动中的心率算，近 4 周平均" : "你在服用控制心率的药物，按运动项目和自我感觉估算"))
        return AbilityCard(ability: .fitness, metrics: m)
    }

    static func metabolic(_ x: BaselineInput, days: [DayData]) -> AbilityCard {
        let p = x.profile
        var m: [BaselineMetric] = []
        let back30 = x.window.end.adding(days: -30)

        let weights = x.vitals.filter { $0.kind == .weight && $0.time >= back30 && $0.time < x.window.end }.sorted { $0.time < $1.time }
        // BMI from the latest weighed weight when there is one, otherwise from the profile.
        let bmi = (130...220).contains(p.heightCm) ? (weights.last.map { $0.value / pow(p.heightCm / 100, 2) } ?? p.bmi) : 0
        if bmi.isFinite && bmi > 0 {
        let c = PopulationNorms.bmiClass(bmi)
        m.append(BaselineMetric(kind: .bmi, title: "BMI", value: bmi, valueText: bmi.shortDecimal,
                                quality: .measured,
                                verdict: c == .obese ? .attention : c == .normal ? .good : .fair,
                                detail: "按中国成人标准：\(c.label)（正常 18.5–24）"))
        } else { m.append(missing(.bmi, "BMI", "补充身高和体重后计算")) }

        if let waist = x.days.last(where: { $0.day >= x.window.end.adding(days: -90) && $0.day < x.window.end && $0.waistCm != nil })?.waistCm {
            let w = PopulationNorms.waistClass(waist, sex: p.sex)
            let limit = p.sex == .female ? 85 : 90
            m.append(BaselineMetric(kind: .waist, title: "腰围", value: waist, valueText: "\(waist.cleanText) 厘米", quality: .measured,
                                    verdict: w == .central ? .attention : w == .pre ? .fair : .good,
                                    detail: w == .central ? "达到中心型肥胖（≥ \(limit) 厘米）" : w == .pre ? "接近中心型肥胖的界线 \(limit) 厘米" : "在正常范围"))
        }

        var fats = days.compactMap(\.bodyFatPct)
        if fats.isEmpty, let last = x.days.last(where: { $0.day >= back30 && $0.day < x.window.end && $0.bodyFatPct != nil })?.bodyFatPct { fats = [last] }
        if let fat = Stats.mean(fats) {
            let r = PopulationNorms.bodyFat.rank(fat, age: rankAge(p), sex: p.sex)
            m.append(BaselineMetric(kind: .bodyFat, title: "体脂率", value: fat, valueText: "\(fat.shortDecimal)%", quality: .estimated,
                                    rank: r, verdict: r.goodness < 25 ? .attention : r.goodness < 50 ? .fair : .good,
                                    detail: "在同龄同性别里\(r.approx)（体脂越低排名越靠前）", note: r.reference.note))
        }

        if let g = glucoseMetric(x) { m.append(g) }

        if let a1c = x.labs.filter({ $0.kind == .hba1c && $0.date >= x.window.end.adding(days: -180) && $0.date < x.window.end }).max(by: { $0.date < $1.date }) {
            let v = a1c.value
            let verdict: Verdict = p.hasDiabetes ? (v <= 7 ? .good : v <= 8 ? .fair : .attention) : (v >= 6.5 ? .attention : v >= 5.7 ? .fair : .good)
            m.append(BaselineMetric(kind: .hba1c, title: "糖化血红蛋白", value: v, valueText: "\(v.cleanText)%", quality: .measured, verdict: verdict,
                                    detail: p.hasDiabetes ? "多数糖尿病患者的目标在 7% 以下，以医生的目标为准"
                                        : v >= 6.5 ? "达到糖尿病的诊断范围，请就医确认" : v >= 5.7 ? "偏高，属于糖尿病前期范围" : "正常",
                                    note: "化验于 \(a1c.date.formatted(.dateTime.month().day()))，反映过去 2–3 个月的平均血糖"))
        }
        return AbilityCard(ability: .metabolic, metrics: m)
    }

    /// From a CGM when worn (time in range against the consensus; healthy-adult values without diabetes),
    /// otherwise from fasting finger-stick readings.
    static func glucoseMetric(_ x: BaselineInput) -> BaselineMetric? {
        let p = x.profile
        let g = x.vitals.filter { $0.kind == .glucose && $0.time >= x.window.start && $0.time < x.window.end }
        let perDay = Double(g.count) / Double(max(1, x.window.end.daysSince(x.window.start)))
        if perDay >= 24, g.count >= 200 {
            let v = g.map(\.value)
            let n = Double(v.count)
            let tir = Double(v.filter { $0 >= 3.9 && $0 <= 10 }.count) / n * 100
            let below = Double(v.filter { $0 < 3.9 }.count) / n * 100
            let over78 = Double(v.filter { $0 > 7.8 }.count) / n * 100
            let mean = Stats.mean(v) ?? 0
            if p.hasDiabetes {
                let verdict: Verdict = below > 4 || tir < 50 ? .attention : tir < 70 ? .fair : .good
                return BaselineMetric(kind: .glucose, title: "血糖达标时间", value: tir, valueText: "\(Int(tir.rounded()))%", quality: .measured,
                                      verdict: verdict,
                                      detail: "CGM 显示 \(Int(tir.rounded()))% 的时间在 3.9–10.0 之间（国际共识目标 > 70%），低于 3.9 的时间 \(below.shortDecimal)%（目标 < 4%）",
                                      note: "CGM 戴满 14 天更能代表日常")
            }
            // Healthy adults: about 2% of the time above 7.8 (IQR up to 3.9%, 8.6% from 60; Shah 2019); the upper
            // limits in healthy Chinese adults are a 24-h mean of 6.6 and 17% above 7.8 (Zhou 2009).
            let usual = p.isAtLeast(age: 60) ? 8.6 : 3.9
            let verdict: Verdict = over78 >= 17 || mean >= 6.6 ? .attention : over78 > usual ? .fair : .good
            return BaselineMetric(kind: .glucose, title: "餐后血糖", value: over78, valueText: "\(over78.shortDecimal)%", quality: .measured,
                                  verdict: verdict,
                                  detail: "CGM 显示 \(over78.shortDecimal)% 的时间高于 7.8，平均 \(mean.shortDecimal)。"
                                      + (verdict == .good ? "在健康成人常见的范围内" : verdict == .fair ? "比健康成人常见的多一些（多数人在 \(usual.cleanText)% 以内）" : "超出了健康成人的上限（高于 7.8 的时间 17%、平均 6.6）"),
                                  note: "和没有糖尿病的健康成人比（美国 Shah 2019、中国 Zhou 2009）。一周的数据受这周饮食影响大，CGM 戴满 14 天更能代表日常")
        }
        let fasting = g.filter { $0.context == .fasting || $0.context == .morning }
        guard fasting.count >= 3, let mean = Stats.mean(fasting.map(\.value)) else { return nil }
        let verdict: Verdict = p.hasDiabetes ? (mean <= 7 ? .good : mean <= 8.5 ? .fair : .attention) : (mean >= 7 ? .attention : mean >= 6.1 ? .fair : .good)
        return BaselineMetric(kind: .glucose, title: "空腹血糖", value: mean, valueText: mean.shortDecimal, quality: .measured, verdict: verdict,
                              detail: p.hasDiabetes ? "空腹血糖的目标以医生的为准" : mean >= 7 ? "达到糖尿病的诊断范围，请就医确认" : mean >= 6.1 ? "偏高（空腹血糖受损范围 6.1–7.0）" : "正常（< 6.1）",
                              note: "\(fasting.count) 次空腹读数的平均")
    }

    static func sleep(_ x: BaselineInput, days: [DayData]) -> AbilityCard {
        var m: [BaselineMetric] = []
        if let mins = Stats.mean(days.compactMap(\.sleepMinutes)) {
            let h = mins / 60
            m.append(BaselineMetric(kind: .sleepDuration, title: "睡眠时长", value: h, valueText: "\(h.shortDecimal) 小时", quality: .measured,
                                    verdict: h >= 7 ? .good : h >= 6 ? .fair : .attention,
                                    detail: h >= 7 ? "达到成人每晚 7 小时以上的建议" : "低于成人每晚 7 小时的建议"))
        } else {
            m.append(missing(.sleepDuration, "睡眠时长", "睡觉时戴着手表"))
        }
        let beds = days.compactMap { d -> Double? in
            guard let s = d.sleepStart else { return nil }
            var v = Double(s.hour * 60 + Calendar.pulse.component(.minute, from: s))
            if v < 12 * 60 { v += 24 * 60 }
            return v
        }
        if beds.count >= 4, let sd = Stats.sd(beds) {
            m.append(BaselineMetric(kind: .sleepRegularity, title: "作息规律", value: sd, valueText: "波动约 \(Int(sd.rounded())) 分钟", quality: .measured,
                                    verdict: sd <= 30 ? .good : sd <= 60 ? .fair : .attention,
                                    detail: sd <= 30 ? "每天入睡时间比较固定" : "入睡时间每天相差较多，规律的作息对心率和血糖都有好处"))
        }
        if days.contains(where: { $0.sleepMinutes != nil }) {
            let cues = SleepAnalyzer.breathingCues(days: x.days.filter { $0.day < x.window.end }, now: x.window.end.adding(days: -1), window: 30)
            let verdict: Verdict = cues.level == .notable ? .attention : cues.level == .some ? .fair : .good
            m.append(BaselineMetric(kind: .breathing, title: "夜间呼吸", value: cues.avgDisturbances, valueText: cues.level == .none ? "未见明显线索" : cues.level == .some ? "有少量线索" : "线索较多",
                                    quality: .measured, verdict: verdict, detail: cues.message))
        }
        return AbilityCard(ability: .sleep, metrics: m)
    }

    /// 肌肉力量 from the optional self-test: chair stands from 60 (where they have norms), push-ups below 70.
    static func strength(_ p: ProfileSnapshot) -> BaselineMetric? {
        guard let t = p.strengthTest else { return nil }
        let when = "自测于 \(t.date.formatted(.dateTime.month().day()))"
        func metric(_ value: Int, _ text: String, _ table: NormTable?) -> BaselineMetric {
            guard let table, let age = p.age else {
                return BaselineMetric(kind: .strength, title: "肌肉力量", value: Double(value), valueText: text, quality: .measured,
                                      detail: p.ageKnown ? "这个年龄没有可靠的人群数据，以后和自己比" : "补充年龄后提供同龄评价；当前仅展示记录",
                                      note: when)
            }
            let r = table.rank(Double(value), age: age, sex: p.sex)
            return BaselineMetric(kind: .strength, title: "肌肉力量", value: Double(value), valueText: text, quality: .measured, rank: r,
                                  verdict: r.band.isLow ? .attention : r.band == .lowerMid ? .fair : .good,
                                  detail: "在同龄同性别里\(r.approx)", note: "\(when)。" + r.reference.note)
        }
        if let n = t.chairStands, p.isAtLeast(age: 60) || t.pushups == nil {
            return metric(n, "30 秒坐站 \(n) 次", p.isAtLeast(age: 60) ? PopulationNorms.chairStands : nil)
        }
        if let n = t.pushups {
            return metric(n, "俯卧撑 \(n) 个", p.isAtLeast(age: 70) ? nil : PopulationNorms.pushups)
        }
        return nil
    }

    static func missing(_ k: BaselineMetric.Kind, _ title: String, _ hint: String) -> BaselineMetric {
        BaselineMetric(kind: k, title: title, value: nil, valueText: "数据不足", quality: .missing, detail: hint)
    }

    // MARK: Danger signs

    /// What needs a doctor first, each with a stable kind: a doctor's go-ahead is kept per kind, so a new
    /// danger sign after it asks again.
    static func dangerSigns(_ x: BaselineInput, cards: [AbilityCard]) -> [RedFlag] {
        let p = x.profile
        let all = cards.flatMap(\.metrics)
        var out: [RedFlag] = []
        if let r = all.first(where: { $0.kind == .rhythm && $0.verdict == .urgent }) {
            out.append(RedFlag(kind: .rhythm, text: "\(r.detail)。确认之前不安排高强度训练。"))
        }
        if let b = all.first(where: { $0.kind == .bloodPressure && $0.verdict == .urgent }) {
            out.append(RedFlag(kind: .bloodPressure, text: "家庭血压 \(b.valueText) 明显偏高。请先就医，期间只做步行等低强度活动；单次超过 180/110 的那天不运动。"))
        }
        if all.contains(where: { $0.kind == .rhr && $0.verdict == .urgent }) {
            out.append(RedFlag(kind: .restingHR, text: "静息心率一直高于 100 次/分。请先就医查找原因（比如发热、贫血、甲状腺问题）。"))
        }
        let g = x.vitals.filter { $0.kind == .glucose && $0.time >= x.window.start && $0.time < x.window.end }
        if p.hasDiabetes, g.count >= 200, Double(g.filter { $0.value < 3.0 }.count) / Double(g.count) > 0.01 {
            out.append(RedFlag(kind: .lowGlucose, text: "CGM 显示低于 3.0 的时间超过 1%。运动会让血糖更低，请先和医生商量用药和运动安排。"))
        }
        // PAR-Q+: any 「是」 means asking a doctor first; the base layer stays open meanwhile (Docs 2.9).
        let said = ParQ.allCases.filter(p.said)
        if !said.isEmpty {
            out.append(RedFlag(kind: .parq, text: "运动前安全问题里，你对「\(said.map(\.short).joined(separator: "、"))」回答了「是」。建议先咨询医生，确认可以运动后再开始方案；期间可以做基础层的步行、拉伸和作息调整。"))
        }
        return out
    }

    /// A chronic condition in someone who doesn't exercise regularly yet: a check-up before starting is
    /// recommended (ACSM pre-participation screening), and the plan starts at low to moderate effort anyway.
    static func cautions(_ x: BaselineInput, habits h: HabitProfile) -> [String] {
        let p = x.profile
        let known = p.hasCardiac || p.hasDiabetes || p.conditions.contains(.ckd)
        guard known, h.guidelineMinutes < 90 else { return [] }
        return ["你有慢性病，平时运动又不多：开始方案前最好让医生看一下。方案会先从中低强度开始。"]
    }
}

/// The optional strength self-test (基线期): push-ups to exhaustion (women from the knees) or 30-second chair stands.
struct StrengthTest: Equatable {
    var pushups: Int?
    var chairStands: Int?
    var date: Date
}

/// Something to see a doctor about before the program starts.
struct RedFlag: Equatable {
    enum Kind: String, Codable { case rhythm, bloodPressure, restingHR, lowGlucose, parq }
    var kind: Kind
    var text: String
}

/// The seven safety questions before exercise, modelled on the PAR-Q+ general questions, in the order asked.
enum ParQ: Int, CaseIterable {
    case heartOrBP, chestPain, dizziness, otherChronic, prescriptions, bonesJoints, supervised

    var question: String {
        switch self {
        case .heartOrBP: "医生是否说过你有心脏病或高血压？"
        case .chestPain: "休息、日常活动或运动时，是否感到过胸痛？"
        case .dizziness: "过去 12 个月里，是否因为头晕失去平衡，或失去过意识？（因呼吸太急引起的头晕除外）"
        case .otherChronic: "是否被诊断过其他慢性病（心脏病、高血压以外）？"
        case .prescriptions: "目前是否在服用治疗慢性病的处方药？"
        case .bonesJoints: "是否有骨骼、关节或软组织问题，运动后可能加重？"
        case .supervised: "医生是否说过你只能在医疗监督下运动？"
        }
    }
    /// A few words for the report.
    var short: String {
        switch self {
        case .heartOrBP: "心脏病或高血压"
        case .chestPain: "胸痛"
        case .dizziness: "头晕失去平衡或意识"
        case .otherChronic: "其他慢性病"
        case .prescriptions: "服用慢性病处方药"
        case .bonesJoints: "骨骼关节问题"
        case .supervised: "需要医疗监督下运动"
        }
    }
}

extension ProfileSnapshot {
    /// Whether the user answered 「是」 to this safety question.
    func said(_ q: ParQ) -> Bool { q.rawValue < parqAnswers.count && parqAnswers[q.rawValue] }
}
