import Foundation

// 主靶点 (三阶段计划): the main target's value now, at baseline, the round's goal, and the line shown on
// 今日 in place of resting heart rate. Goals are what four weeks can move beyond the noise of the
// measurement (Docs/三阶段健康计划设计.md, 3.1 and 附录 A).

struct TargetPoint: Equatable {
    var day: Date
    var value: Double
}

struct TargetReading: Equatable {
    var target: TargetMetric
    /// The current value: a 7-day mean, or the latest reading for slow or sparse measures.
    var value: Double?
    /// Diastolic, for blood pressure.
    var value2: Double?
    var count = 0
    var latest: Date?
    var series: [TargetPoint] = []
    /// Weekly distance: kilometres run this week and the plan's kilometres for it.
    var runKm: Double?
    var plannedKm: Double?
    /// Clinic or pharmacy readings: the mean systolic of the last 4 weeks.
    var average: Double?

    var valueText: String {
        guard let v = value else { return "—" }
        switch target {
        case .homeBP, .clinicBP: return "\(Int(v.rounded()))/\(value2.map { String(Int($0.rounded())) } ?? "—")"
        case .vo2max, .weight, .fastingGlucose, .postMealGlucose, .sleepDuration: return v.shortDecimal
        case .restingHR, .cgmTIR, .weeklyRunKm, .sleepRegularity: return String(Int(v.rounded()))
        }
    }

    /// The label above the number on 今日.
    var label: String {
        switch target {
        case .vo2max: "最大摄氧量 · 最近估算"
        case .weeklyRunKm: "周跑量 · 完成计划"
        case .homeBP: "血压 · 7 日均值"
        case .clinicBP: "血压 · 最近一次"
        case .restingHR: "静息心率 · 7 日均值"
        case .cgmTIR: "血糖达标时间 · 14 天"
        case .postMealGlucose: "高于 7.8 的时间 · 7 天"
        case .weight: "体重 · 7 日均值"
        case .fastingGlucose: "空腹血糖 · 7 天"
        case .sleepDuration: "睡眠时长 · 7 晚平均"
        case .sleepRegularity: "入睡时间波动 · 7 晚"
        }
    }

    var unitShort: String {
        switch target {
        case .vo2max: ""
        case .homeBP, .clinicBP: "mmHg"
        case .restingHR: "bpm"
        case .cgmTIR, .postMealGlucose, .weeklyRunKm: "%"
        case .weight: "kg"
        case .fastingGlucose: "mmol/L"
        case .sleepDuration: "小时"
        case .sleepRegularity: "分钟"
        }
    }
}

enum TargetTracker {
    /// The target's value over a window ending at `end` (exclusive). Weekly distance needs the profile with its
    /// race, for the plan's kilometres.
    static func reading(_ t: TargetMetric, days: [DayData], vitals: [VitalPoint], workouts: [WorkoutPoint], end: Date,
                        profile: ProfileSnapshot? = nil) -> TargetReading {
        var r = TargetReading(target: t)
        let week = end.adding(days: -7)
        func inRange(_ d: Date, from: Date) -> Bool { d >= from && d < end }
        switch t {
        case .vo2max:
            let est = days.filter { $0.vo2Max != nil && inRange($0.day, from: end.adding(days: -60)) }
            r.series = est.map { TargetPoint(day: $0.day, value: $0.vo2Max!) }
            // The mean of the estimates of the last 14 days (or the latest within 30), since one estimate scatters.
            let recent = est.filter { $0.day >= end.adding(days: -14) }.compactMap(\.vo2Max)
            if let m = Stats.mean(recent) { r.value = m; r.count = recent.count }
            else if let last = est.last(where: { $0.day >= end.adding(days: -30) }) { r.value = last.vo2Max; r.count = 1 }
            r.latest = est.last?.day
        case .weeklyRunKm:
            // Distance run against the marathon plan's distance for the week (Docs 3.4: 实际 / 计划).
            let ws = end.adding(days: -1).weekStart
            func runs(_ s: Date) -> [WorkoutPoint] { workouts.filter { $0.type == .run && $0.start >= s && $0.start < min(end, s.adding(days: 7)) } }
            func km(_ s: Date) -> Double { runs(s).compactMap(\.distanceKm).reduce(0, +) }
            func planned(_ s: Date) -> Double? {
                guard let p = profile, let race = p.race else { return nil }
                let k = MarathonPlanner.week(profile: p, race: race, weekStart: s).weeklyKm
                return k > 0 ? k : nil
            }
            r.runKm = km(ws)
            r.plannedKm = planned(ws)
            r.count = runs(ws).count
            r.value = r.plannedKm.map { km(ws) / $0 * 100 }
            r.latest = workouts.last { $0.type == .run && $0.start < end }?.start
            // Whole weeks only: the week under way would show as a drop on the chart.
            let first = end >= ws.adding(days: 7) ? 0 : 1
            for i in first..<first + 8 {
                let s = ws.adding(days: -7 * i)
                if let p = planned(s) { r.series.insert(TargetPoint(day: s, value: km(s) / p * 100), at: 0) }
            }
        case .homeBP, .clinicBP:
            let bp = vitals.filter { $0.kind == .bloodPressure && $0.time < end }.sorted { $0.time < $1.time }
            r.latest = bp.last?.time
            r.series = Dictionary(grouping: bp.filter { $0.time >= end.adding(days: -42) }, by: { $0.time.startOfDay })
                .map { TargetPoint(day: $0.key, value: Stats.mean($0.value.map(\.value)) ?? 0) }.sorted { $0.day < $1.day }
            if t == .homeBP {
                let w = bp.filter { $0.time >= week }
                r.count = w.count
                r.value = Stats.mean(w.map(\.value))
                r.value2 = Stats.mean(w.compactMap(\.value2))
            } else if let last = bp.last {
                // The latest reading and date, with the 4-week mean beside it (Docs 3.1).
                let month = bp.filter { $0.time >= end.adding(days: -28) }
                r.value = last.value; r.value2 = last.value2; r.count = month.count
                r.average = Stats.mean(month.map(\.value))
            }
        case .restingHR:
            let w = days.filter { inRange($0.day, from: week) }.compactMap(\.rhr)
            r.value = Stats.mean(w); r.count = w.count
            r.series = days.filter { $0.rhr != nil && inRange($0.day, from: end.adding(days: -42)) }.map { TargetPoint(day: $0.day, value: $0.rhr!) }
        case .cgmTIR, .postMealGlucose:
            // Time in range needs 14 days of CGM to stand for the usual (Battelino 2019); post-meal highs show in a week.
            let from = t == .cgmTIR ? end.adding(days: -14) : week
            let g = vitals.filter { $0.kind == .glucose && $0.time >= from && $0.time < end }.map(\.value)
            r.count = g.count
            if g.count >= (t == .cgmTIR ? 96 * 7 : 96) {
                let n = Double(g.count)
                r.value = t == .cgmTIR ? Double(g.filter { $0 >= 3.9 && $0 <= 10 }.count) / n * 100 : Double(g.filter { $0 > 7.8 }.count) / n * 100
            }
            r.latest = vitals.last { $0.kind == .glucose && $0.time < end }?.time
        case .weight:
            let w = vitals.filter { $0.kind == .weight && $0.time < end }.sorted { $0.time < $1.time }
            let recent = w.filter { $0.time >= week }
            r.value = Stats.mean(recent.map(\.value)) ?? w.last.flatMap { $0.time >= end.adding(days: -14) ? $0.value : nil }
            r.count = recent.count
            r.latest = w.last?.time
            r.series = w.filter { $0.time >= end.adding(days: -42) }.map { TargetPoint(day: $0.time.startOfDay, value: $0.value) }
        case .fastingGlucose:
            let f = vitals.filter { $0.kind == .glucose && ($0.context == .fasting || $0.context == .morning) && $0.time >= week && $0.time < end }
            r.value = Stats.mean(f.map(\.value)); r.count = f.count
        case .sleepDuration:
            // A night belongs to the morning it ends on. Three nights at least: one night scatters by an hour.
            let nights = days.filter { $0.sleepMinutes != nil && inRange($0.day, from: week) }
            r.count = nights.count
            if nights.count >= 3 { r.value = Stats.mean(nights.compactMap(\.sleepMinutes)).map { $0 / 60 } }
            r.latest = days.last { $0.sleepMinutes != nil && $0.day < end }?.day
            r.series = days.filter { $0.sleepMinutes != nil && inRange($0.day, from: end.adding(days: -42)) }
                .map { TargetPoint(day: $0.day, value: $0.sleepMinutes! / 60) }
        case .sleepRegularity:
            let nights = days.filter { $0.sleepStart != nil && inRange($0.day, from: week) }
            r.count = nights.count
            r.value = bedtimeSD(nights)
            r.latest = days.last { $0.sleepStart != nil && $0.day < end }?.day
            // Whole weeks, one point each: a spread needs a week of nights.
            let ws = end.adding(days: -1).weekStart
            let first = end >= ws.adding(days: 7) ? 0 : 1
            for i in first..<first + 6 {
                let s = ws.adding(days: -7 * i)
                if let sd = bedtimeSD(days.filter { $0.day >= s && $0.day < s.adding(days: 7) }) { r.series.insert(TargetPoint(day: s, value: sd), at: 0) }
            }
        }
        return r
    }

    /// How much the time of falling asleep varies, as the SD in minutes; four nights at least.
    static func bedtimeSD(_ days: [DayData]) -> Double? {
        let starts = days.compactMap(\.sleepStart).map { Double(Clock.nightOffset($0.minutesOfDay)) }
        return starts.count >= 4 ? Stats.sd(starts) : nil
    }

    /// The round's goal from the baseline value (Docs 3.1): what four weeks can move beyond the noise.
    static func goal(_ t: TargetMetric, baseline b: Double, profile p: ProfileSnapshot, report: BaselineReport? = nil) -> Double {
        switch t {
        case .vo2max:
            // Within 3 weeks VO2max starts rising; the watch's own scatter is ~1.2 mL/kg/min.
            let fit = (report?.metric(.vo2max)?.rank?.band ?? .upperMid) >= .top25
            return (b + max(1.5, b * (fit ? 0.03 : 0.05))).rounded(to: 0.1)
        case .restingHR:
            // Endurance training lowers resting heart rate by about 3–6 bpm, more from a higher start.
            return (b - (b >= 70 ? 3 : 2)).rounded()
        case .homeBP:
            // 5 mmHg lower, or the doctor's or the home target, whichever is reached first (the nearer one);
            // already under the target: stay there, never a goal above the baseline.
            return min(b, max(b - 5, bpTarget(p))).rounded()
        case .clinicBP:
            // A single pharmacy or clinic reading scatters by ~11–15 mmHg: 10 lower, or the target.
            return min(b, max(b - 10, bpTarget(p))).rounded()
        case .weight:
            return (b * 0.98).rounded(to: 0.1)
        case .cgmTIR:
            // 5 percentage points more, up to 70%; at 70% or more already: stay there.
            return (b >= 70 ? b : min(b + 5, 70)).rounded()
        case .postMealGlucose:
            // A third less, down to what healthy adults show; already there: stay there, never a goal above the baseline.
            let usual = p.isAtLeast(age: 60) ? 8.6 : 3.9
            return floorTenth(min(b, max(usual, b * 0.67)))
        case .fastingGlucose:
            return floorTenth(min(b, max(p.hasDiabetes ? 6.5 : 5.6, b - 0.5)))
        case .weeklyRunKm:
            return 90
        case .sleepDuration:
            // Half an hour more, up to 7 hours; 7 or more already: stay there.
            return (b >= 7 ? b : min(7, b + 0.5)).rounded(to: 0.1)
        case .sleepRegularity:
            // 20 minutes less spread, down to 30 (a steady schedule); 30 or less already: stay there.
            return (b <= 30 ? b : max(30, b - 20)).rounded()
        }
    }

    /// The goal when the baseline has no value: blood pressure aims for its target, weekly distance for 90% of
    /// the plan; the others wait for readings.
    static func defaultGoal(_ t: TargetMetric, profile p: ProfileSnapshot) -> Double? {
        switch t {
        case .homeBP, .clinicBP: bpTarget(p)
        case .weeklyRunKm: 90
        default: nil
        }
    }

    /// The doctor's systolic target with hypertension, otherwise under the home threshold of 135.
    static func bpTarget(_ p: ProfileSnapshot) -> Double {
        p.conditions.contains(.hypertension) ? Double(p.bpTargetSys) : 134
    }

    /// Rounded down to 0.1, so a lower-is-better goal never ends up above the value it came from.
    static func floorTenth(_ v: Double) -> Double { (v * 10).rounded(.down) / 10 }

    /// Whether the value has reached the goal (lower is better except for VO2max, weekly distance and time in range).
    static func reached(_ t: TargetMetric, value: Double?, goal: Double?) -> Bool {
        guard let v = value, let g = goal else { return false }
        return t.higherIsBetter ? v >= g : v <= g
    }

    /// 「基线 143 · 目标 138」 or what is missing, under the number on 今日.
    static func footnote(_ r: TargetReading, goal t: TargetGoal?, now: Date) -> String {
        let baseline = t?.baseline, goal = t?.goal
        if r.target == .vo2max, let last = r.latest {
            let ago = now.daysSince(last)
            if ago >= 7 { return "\(ago) 天没有新估算 · 去户外快走 20 分钟" }
        }
        if r.target.isBloodPressure {
            let b = baseline.map { "基线收缩压 " + text(r.target, $0) } ?? "基线待补充"
            let g = goal.map { "目标 ≤ " + text(r.target, $0) } ?? "目标待确认"
            let measured = r.target == .clinicBP
                ? (r.latest.map { " · 最近 " + $0.formatted(.dateTime.month().day()) } ?? " · 还没有读数") + (r.average.map { " · 4 周平均 \(Int($0.rounded()))" } ?? "")
                : ""
            return b + " · " + g + measured
        }
        if r.target == .weeklyRunKm {
            guard let planned = r.plannedKm else { return "在「专项运动」里填好比赛日期后，按计划跑量来算" }
            return "本周 \((r.runKm ?? 0).shortDecimal) / \(planned.shortDecimal) 公里 · 目标 ≥ \(Int(goal ?? 90))%"
        }
        if r.value == nil { return r.target.howToMeasure }
        var parts: [String] = []
        if let b = baseline { parts.append("基线 \(text(r.target, b))") }
        if let g = goal { parts.append("目标 \(text(r.target, g))") }
        return parts.joined(separator: " · ")
    }

    static func text(_ t: TargetMetric, _ v: Double) -> String {
        switch t {
        case .homeBP, .clinicBP, .restingHR, .cgmTIR, .weeklyRunKm, .sleepRegularity: String(Int(v.rounded()))
        default: v.shortDecimal
        }
    }
}
