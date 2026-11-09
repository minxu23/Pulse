import Foundation

// 改善期 (三阶段计划): each week's progress (what was done, where the main target stands against its own
// noise, how next week changes) and the decision at the end of a 4-week round.

struct BehaviorCheck: Equatable, Codable {
    var title: String
    var detail: String
    var met: Bool
}

struct ProgramWeekReport: Equatable {
    var week: Int
    var weeks: Int
    var checks: [BehaviorCheck]
    /// Illness or travel on 3 or more days: the week doesn't count either way.
    var excused: Bool
    var target: TargetReading
    /// Value minus baseline (signed, in the target's unit).
    var change: Double?
    /// The change is larger than the measure's normal wobble.
    var beyondNoise: Bool
    var targetLine: String
    var next: String
    var met: Bool {
        let missed = checks.filter { !$0.met }
        return missed.isEmpty || (missed.count == 1 && checks.first?.met == true && checks.count >= 3)
    }
}

struct ProgramRoundResult: Equatable, Codable {
    enum Outcome: String, Codable {
        case achieved, slowResponse, lowAdherence, notEnoughReadings
        /// 关键事件准备: a look at the training phase every 4 weeks, and the race itself.
        case phaseCheck, raceDone
        /// The round leads to 总结期.
        var endsProgram: Bool { self == .achieved || self == .raceDone }
    }
    var outcome: Outcome
    var round: Int
    var weeksMet: Int
    var weeksCounted: Int
    var baseline: Double?
    var value: Double?
    var goal: Double?
    var headline: String
    var detail: String
    var next: String
    /// The third round in a row without the goal: worth a new baseline (nil in results saved before).
    var suggestsReassessment: Bool? = nil
}

enum ProgramEvaluator {
    /// How much the target moves on its own from week to week; a change beyond this is likely real.
    static func noise(_ t: TargetMetric) -> Double {
        switch t {
        case .homeBP: 9          // SD of the difference of two home-BP weeks ≈ 7 mmHg (Stergiou 2002)
        case .clinicBP: 14       // single clinic or pharmacy readings: SD of differences ≈ 11 mmHg
        case .restingHR: 3       // Fitbit cohort: day-to-day SD 3 bpm, weekly range 3 bpm (Quer 2020)
        case .vo2max: 2.6        // Apple: within-person SD of estimates median 1.2, 90th percentile 2.6
        case .weight: 1.0
        case .cgmTIR: 5
        case .postMealGlucose: 2
        case .fastingGlucose: 0.5
        case .weeklyRunKm: 10    // share of the planned distance, in percentage points
        }
    }

    struct Input {
        var program: ProgramPlanInput
        var profile: ProfileSnapshot
        var days: [DayData]
        var workouts: [WorkoutPoint]
        var vitals: [VitalPoint]
        var plan: [SessionSnapshot]
        /// The main target's baseline and goal for the round (the program's own target decides which metric).
        var targetGoal: TargetGoal?
        /// What each weekly review of this round said was hardest to keep up (一起复盘).
        var hardest: [String] = []
        /// Rounds in a row just before this one that missed their goal.
        var missedBefore = 0

        var baseline: Double? { targetGoal?.baseline }
        var goal: Double? { targetGoal?.goal }
    }

    /// The round's length: 4 weeks, a week more for each week of illness or travel that is over, at most 2 more
    /// (Docs 5). 关键事件准备 follows the race date instead.
    static func roundWeeks(_ x: Input, now: Date) -> Int {
        guard x.program.pack != .event else { return 4 }
        var weeks = 4, i = 0
        while i < weeks {
            let ws = x.program.roundStart.adding(days: 7 * i)
            guard ws.adding(days: 7) <= now.startOfDay else { break }
            if week(x, weekStart: ws, now: now).excused { weeks = min(6, weeks + 1) }
            i += 1
        }
        return weeks
    }

    static func week(_ x: Input, weekStart ws: Date, now: Date) -> ProgramWeekReport {
        let today = now.startOfDay
        let end = min(ws.adding(days: 7), today)          // full days so far
        let elapsed = max(0, end.daysSince(ws))
        let wk = x.program.week(ws)
        let days = x.days.filter { $0.day >= ws && $0.day < end }
        var checks: [BehaviorCheck] = []

        // Training: done counts 1, partial ½, for days already past.
        let items = x.plan.filter { $0.day >= ws && $0.day < end && $0.kind.isTraining }
        let done = items.reduce(0.0) { $0 + ($1.status == .done ? 1 : $1.status == .partial ? 0.5 : 0) }
        // Nil while no session has been due yet: nothing to judge next week by.
        let rate: Double? = items.isEmpty ? nil : done / Double(items.count)
        checks.append(BehaviorCheck(title: "训练", detail: items.isEmpty ? "这几天没有安排训练" : "完成 \(done.shortDecimal) / \(items.count) 次",
                                    met: (rate ?? 1) >= 0.75))

        // Steps against the week's target.
        if let goal = PackPlanner.stepsTarget(x.program, age: x.profile.age, week: wk) {
            let steps = days.compactMap(\.steps).map(Double.init)
            if let m = Stats.mean(steps) {
                checks.append(BehaviorCheck(title: "步数", detail: "日均 \(Int(m.rounded())) 步，目标 \(goal)", met: m >= Double(goal) * 0.95))
            }
        }

        switch (x.program.pack, x.program.target) {
        case (.fitness, _):
            let hard = items.filter { $0.kind == .quality || $0.kind == .test }
            if !hard.isEmpty {
                let n = hard.filter { $0.status == .done || $0.status == .partial }.count
                checks.append(BehaviorCheck(title: "间歇和复测", detail: "完成 \(n) / \(hard.count) 次", met: n >= hard.count))
            }
        case (.cardio, .homeBP):
            let bpDays = Set(x.vitals.filter { $0.kind == .bloodPressure && $0.time >= ws && $0.time < end }.map { $0.time.startOfDay }).count
            let need = due(3, elapsed: elapsed)
            checks.append(BehaviorCheck(title: "测血压", detail: "测了 \(bpDays) 天，每周至少 3 天", met: bpDays >= need))
        case (.cardio, .clinicBP):
            let n = x.vitals.filter { $0.kind == .bloodPressure && $0.time >= ws && $0.time < end }.count
            checks.append(BehaviorCheck(title: "测血压", detail: "测了 \(n) 次，每周至少 2 次", met: n >= due(2, elapsed: elapsed)))
        case (.metabolic, _):
            let walks = days.filter { d in afterDinnerWalk(d, x.workouts) }.count
            let need = due(5, elapsed: elapsed)
            checks.append(BehaviorCheck(title: "晚饭后散步", detail: "走了 \(walks) 天，目标每周 5 天", met: walks >= need))
        default:
            break
        }

        let excused = days.filter { $0.isIll || $0.tags.contains(.travel) }.count >= 3
        let reading = TargetTracker.reading(x.program.target, days: x.days, vitals: x.vitals, workouts: x.workouts, end: end, profile: x.profile)
        let change = reading.value.flatMap { v in x.baseline.map { v - $0 } }
        let beyond = change.map { $0 != 0 && abs($0) >= noise(x.program.target) } ?? false
        return ProgramWeekReport(week: wk, weeks: x.program.weeks, checks: checks, excused: excused, target: reading,
                                 change: change, beyondNoise: beyond,
                                 targetLine: targetLine(x.program.target, reading, change: change, beyond: beyond, goal: x.goal),
                                 next: next(rate: rate, excused: excused, x.program, week: wk))
    }

    /// How many of a weekly goal are due after `elapsed` full days: the share of the week so far, rounded down,
    /// so midweek asks only for what the days so far could hold (3 a week: 1 by Thursday, all 3 by the week's end).
    static func due(_ perWeek: Int, elapsed: Int) -> Int { perWeek * min(max(elapsed, 0), 7) / 7 }

    /// An evening walk: a walk session that starts 18:00–21:30, or 1,000+ steps between 19:00 and 21:00.
    static func afterDinnerWalk(_ d: DayData, _ workouts: [WorkoutPoint]) -> Bool {
        if d.stepsByHour.count == 24, d.stepsByHour[19] + d.stepsByHour[20] >= 1000 { return true }
        return workouts.contains { w in
            w.type == .walk && w.minutes >= 10 && w.start.startOfDay == d.day && (18 * 60...21 * 60 + 30).contains(w.start.hour * 60 + Calendar.pulse.component(.minute, from: w.start))
        }
    }

    static func targetLine(_ t: TargetMetric, _ r: TargetReading, change: Double?, beyond: Bool, goal: Double?) -> String {
        guard r.value != nil else { return "\(t.title)：这周还没有足够的读数。\(t.howToMeasure)。" }
        var s = "\(t.title) \(r.valueText)"
        if t == .weeklyRunKm, let planned = r.plannedKm {
            s = "周跑量完成计划的 \(r.valueText)%（\((r.runKm ?? 0).shortDecimal) / \(planned.shortDecimal) 公里）"
        }
        if let c = change {
            let better = t.higherIsBetter ? c > 0 : c < 0
            let size = TargetTracker.text(t, abs(c))
            s += c == 0 ? "，和基线一样" : "，比基线\(c > 0 ? "高" : "低") \(size)"
            s += beyond ? (better ? "，已超出平时的波动，是真的在变好" : "，超出了平时的波动，值得留意") : "，还在平时的波动范围内"
        }
        if TargetTracker.reached(t, value: r.value, goal: goal) { s += "。已达到这一轮的目标" }
        else if let g = goal { s += "。目标 \(TargetTracker.text(t, g))" }
        return s + "。"
    }

    static func next(rate: Double?, excused: Bool, _ p: ProgramPlanInput, week: Int) -> String {
        if excused { return p.pack == .event ? "这周生病或出差的日子多，不计入判定，下周按比赛日期的计划继续。" : "这周生病或出差的日子多，不计入判定，这一轮顺延一周（每轮最多顺延 2 周），下周照原计划。" }
        guard let rate else { return p.pack == .event ? "还没有到期的训练，下周按比赛日期的计划继续。" : "还没有到期的训练，下周照原计划。" }
        if rate >= 0.85 {
            return p.pack == .fitness && week < 3 ? "这周完成得好：下周小幅加量，并按计划加一次间歇。" : "这周完成得好：下周小幅加量（约 10%）。"
        }
        if rate >= 0.6 { return "完成了大部分：下周保持同样的量，先把规律稳住。" }
        return "这周完成得少：下周减量约 15%，把训练放到你最常运动的时段，或者换成你喜欢的运动。"
    }

    // MARK: Round end

    /// The decision once the round's weeks are over; nil before. 关键事件准备 ends with the race.
    static func round(_ x: Input, now: Date) -> ProgramRoundResult? {
        let start = x.program.roundStart
        let r = x.program.round
        let t = x.program.target
        if x.program.pack == .event, let race = x.profile.race, now.startOfDay > race.date.startOfDay {
            return raceDone(x, race: race, now: now)
        }
        let weeks = roundWeeks(x, now: now)
        let end = start.adding(days: 7 * weeks)
        guard now.startOfDay >= end else { return nil }
        var met = 0, counted: [Date] = []
        for i in 0..<weeks {
            let ws = start.adding(days: 7 * i)
            let w = week(x, weekStart: ws, now: end)
            if w.excused { continue }
            counted.append(ws)
            if w.met { met += 1 }
        }
        let needWeeks = max(1, Int((Double(counted.count) * 0.75).rounded(.up)))
        let hardest = hardestLine(x)
        if x.program.pack == .event { return phaseCheck(x, weeks: counted, met: met, need: needWeeks, end: end, hardest: hardest) }

        let bp = x.vitals.filter { $0.kind == .bloodPressure && $0.time < end }
        let reading = TargetTracker.reading(t, days: x.days, vitals: x.vitals, workouts: x.workouts, end: end, profile: x.profile)
        // Clinic and pharmacy readings scatter: the mean of weeks 3–4, with readings in every week counted (Docs 3.1).
        let lastTwo = bp.filter { $0.time >= end.adding(days: -14) }
        let value = t == .clinicBP ? Stats.mean(lastTwo.map(\.value)) : reading.value
        let reached = TargetTracker.reached(t, value: value, goal: x.goal)
        let enoughReadings: Bool = {
            switch t {
            case .clinicBP: return lastTwo.count >= 2 && counted.allSatisfy { ws in bp.contains { $0.time >= ws && $0.time < ws.adding(days: 7) } }
            case .homeBP: return reading.count >= 6
            default: return value != nil
            }
        }()
        let base = x.baseline.map { TargetTracker.text(t, $0) } ?? "—"
        let current = value.map { TargetTracker.text(t, $0) } ?? "—"
        let goal = x.goal.map { TargetTracker.text(t, $0) } ?? "—"
        let span = counted.count == weeks ? "\(weeks) 周里" : "计入判定的 \(counted.count) 周里"
        let numbers = "\(t.title)：基线 \(base) → 现在 \(current)，目标 \(goal)。\(span)有 \(met) 周做到了计划。" + hardest
        var out: ProgramRoundResult
        if !enoughReadings {
            out = ProgramRoundResult(outcome: .notEnoughReadings, round: r, weeksMet: met, weeksCounted: counted.count, baseline: x.baseline, value: value, goal: x.goal,
                                     headline: "读数不够，判断不了\(t.title)有没有变化", detail: numbers + "这一轮按做到的计划来看。",
                                     next: "下一轮先把测量补上：\(t.howToMeasure)。")
        } else if met >= needWeeks && reached {
            return ProgramRoundResult(outcome: .achieved, round: r, weeksMet: met, weeksCounted: counted.count, baseline: x.baseline, value: value, goal: x.goal,
                                      headline: "第 \(r) 轮达成目标", detail: numbers, next: "进入总结期：看看哪些做法最有效，留下一套能长期坚持的节奏。")
        } else if met >= needWeeks {
            out = ProgramRoundResult(outcome: .slowResponse, round: r, weeksMet: met, weeksCounted: counted.count, baseline: x.baseline, value: value, goal: x.goal,
                                     headline: "计划做到了，\(t.title)还没到目标", detail: numbers + "很多指标需要 8–12 周才完全显现。",
                                     next: "第 \(r + 1) 轮保持同样的习惯，适度加强训练（比如多一次间歇或延长有氧），目标不变。")
        } else {
            out = ProgramRoundResult(outcome: .lowAdherence, round: r, weeksMet: met, weeksCounted: counted.count, baseline: x.baseline, value: value, goal: x.goal,
                                     headline: "这一轮计划做到的不多", detail: numbers,
                                     next: "第 \(r + 1) 轮先降低门槛：训练量减一些，放到你最容易坚持的时段和运动上。")
        }
        // The third round in a row without the goal (Docs 6).
        if x.missedBefore >= 2 {
            let doctor = t.isBloodPressure || [.cgmTIR, .postMealGlucose, .fastingGlucose].contains(t)
            out.next += "已经连续 3 轮没达到目标：建议重新做一次基线评估，或者调整目标" + (doctor ? "；也建议带着这几轮的记录去看医生。" : "。")
            out.suggestsReassessment = true
        }
        return out
    }

    /// 「这几周最难坚持的是步数（2 周）」: the behaviour named most often in the round's weekly reviews.
    static func hardestLine(_ x: Input) -> String {
        let names = ["训练", "步数", "测血压", "晚饭后散步", "间歇和复测"]
        let counts = names.map { n in (n, x.hardest.filter { $0.contains(n) }.count) }.filter { $0.1 > 0 }
        guard let top = counts.max(by: { $0.1 < $1.1 }) else { return "" }
        return "复盘里说最难坚持的是\(top.0)（\(top.1) 周）。"
    }

    /// 关键事件准备, every 4 weeks: how the training went and the phase that comes next.
    static func phaseCheck(_ x: Input, weeks: [Date], met: Int, need: Int, end: Date, hardest: String) -> ProgramRoundResult {
        let shares = weeks.compactMap { ws in
            TargetTracker.reading(.weeklyRunKm, days: x.days, vitals: x.vitals, workouts: x.workouts, end: ws.adding(days: 7), profile: x.profile).value
        }
        let share = Stats.mean(shares)
        let phase = x.profile.race.map { MarathonPlanner.phase(weeksToRace: MarathonPlanner.weeksBetween(end, $0.date)) }
        let detail = "\(weeks.count) 周里有 \(met) 周做到了计划" + (share.map { "，周跑量平均完成计划的 \(Int($0.rounded()))%" } ?? "") + "。" + hardest
        let upcoming = phase.map { "接下来是「\($0.label)」：\($0.focus)" } ?? "接下来按比赛日期继续。"
        return ProgramRoundResult(outcome: .phaseCheck, round: x.program.round, weeksMet: met, weeksCounted: weeks.count, baseline: nil, value: share, goal: 90,
                                  headline: "第 \(x.program.round) 个 4 周：训练阶段检查", detail: detail,
                                  next: met >= need ? upcoming : "先降低门槛：把跑步放到你最容易坚持的日子，长距离按计划的下限跑。" + upcoming)
    }

    /// The race is over: on to 总结期 (Docs 6).
    static func raceDone(_ x: Input, race: RaceInfo, now: Date) -> ProgramRoundResult {
        let name = race.name.isEmpty ? "比赛" : race.name
        return ProgramRoundResult(outcome: .raceDone, round: x.program.round, weeksMet: 0, weeksCounted: 0, baseline: nil, value: nil, goal: nil,
                                  headline: "\(name)结束了", detail: "比赛日期 \(race.date.formatted(.dateTime.month().day())) 已过，这一段准备告一段落。",
                                  next: "进入总结期：比赛后先恢复一两周，再看看这几个月的变化，留下一套能长期坚持的跑步节奏。")
    }
}
