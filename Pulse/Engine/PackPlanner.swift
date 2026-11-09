import Foundation

// 改善期 (三阶段计划): a week of the chosen pack. The general week generator lays the days out (available
// days, shifts, dialysis, care limits); the pack then sets the core layer for the round's week, puts the
// user's own sports in (a ball game they play hard counts as their vigorous session), and adds the base
// layer: a step target that rises from what they did at baseline, sitting less, sleep and strength.

/// What the plan needs from the baseline, kept on the profile when a round starts.
struct ProgramPlanInput: Codable, Equatable {
    var pack: ProgramPack
    var target: TargetMetric
    var round: Int
    var roundStart: Date
    var weeks: Int = 4
    /// The user's sports as they did them in the 4 weeks before.
    var sports: [SportHabit] = []
    var baselineSteps: Double?
    var baselineMinutes: Double = 0
    var vo2Band: Int?
    /// Weekdays the user exercised on at baseline, most frequent first (nil in plans saved before).
    var usualWeekdays: [Int]? = nil
    /// The time of day they usually exercised.
    var mainSlot: TimeSlot? = nil
    /// Heart rate recovered slowly after hard exercise at baseline: aerobic only for the first two weeks.
    var slowRecovery: Bool? = nil
    /// 睡眠改善: the usual time of falling asleep and of waking at baseline (minutes after midnight; a bedtime
    /// after midnight is past 24 h), and the hours asleep a night.
    var bedtime: Double? = nil
    var wakeTime: Double? = nil
    var sleepHours: Double? = nil
    /// Baseline blood pressure at 160/100 or above (or a single reading at 180/110): no intervals this round (ESC 2020).
    var highBP: Bool? = nil

    /// 1-based week of the round for a week starting `ws`; the week before it starts counts as week 1.
    func week(_ ws: Date) -> Int { max(1, ws.daysSince(roundStart.weekStart) / 7 + 1) }
    /// The same, never past the round's last week (a round that has ended stays at its last week).
    func roundWeek(_ ws: Date) -> Int { min(week(ws), max(1, weeks)) }
}

/// How hard intervals are made.
enum IntervalStyle {
    /// 4×4 at 85–95% of maximum heart rate.
    case standard
    /// 1 minute faster, 2 minutes slow: new to exercise or VO2max in the bottom quarter.
    case beginner
    /// 1 minute brisk walking, 2 minutes slow walking: 65 and over (Docs 4).
    case gentle
}

enum PackPlanner {
    static func week(profile p: ProfileSnapshot, input x: ProgramPlanInput, weekStart ws: Date) -> WeekPlan {
        let maintaining = p.programPhase == .summary
        if x.pack == .event, let race = p.race {
            var plan = PlanGenerator.marathonWeek(profile: p, race: race, weekStart: ws)
            plan.notes.insert("跑量看周跑量，加长距离时注意：单次最长的一跑不超过过去 30 天最长那次的 110%，这比「每周加 10%」更能预测受伤。", at: 0)
            return withBase(plan, p, x, ws)
        }
        // 总结期 keeps the round's last week: the same effort, no more volume.
        let wk = maintaining ? max(1, x.weeks) : x.roundWeek(ws)
        let core = min(wk, 4)
        var q = p
        // Intervals come from the pack's own week rules, not from the general generator.
        q.goals.remove(.fitness); q.goals.remove(.event)
        q.availableWeekdays = trainingWeekdays(p, x)
        var plan = PlanGenerator.generalWeek(profile: q, weekStart: ws)
        // The general week's opening line is about resting heart rate; each pack says what it is about instead.
        if x.target != .restingHR { plan.notes.removeAll { $0.contains("改善静息心率最核心") } }
        let capped = p.cardiacLimited || p.intensityCapped || p.conditions.contains(.pregnancy) || p.conditions.contains(.heartFailure) || x.highBP == true
        // A slow heart-rate recovery: two weeks of aerobic base first (Docs 4).
        let aerobicOnly = x.slowRecovery == true && core <= 2 && !maintaining
        let beginner = p.level.rank <= ActivityLevel.light.rank || (x.vo2Band ?? 2) <= RankBand.bottom25.rawValue
        let style: IntervalStyle = p.isAtLeast(age: 65) ? .gentle : beginner ? .beginner : .standard
        let noIntervals = capped || aerobicOnly

        // The user's own ball game on the day they play it.
        var vigorousFromSport = 0
        // As many of its usual days as the user plays it a week (twice a week: both days).
        for s in x.sports where s.type.isBallGame && s.perWeek >= 0.5 {
            let hard = s.intensity == .hard && !capped
            for wd in s.weekdays.prefix(max(1, Int(s.perWeek.rounded()))) {
                guard let i = plan.sessions.firstIndex(where: { $0.weekday == wd }) else { continue }
                plan.sessions[i] = ballSession(s, weekday: wd, hard: hard, p)
                if hard { vigorousFromSport += 1 }
            }
        }

        switch x.pack {
        case .fitness:
            // Week 1 builds the base; intervals from week 2 (one, then two when there are four or more days).
            let wanted = noIntervals ? 0 : core == 1 ? 0 : (core >= 3 && trainingDays(plan) >= 4 ? 2 : 1)
            addIntervals(&plan, count: max(0, wanted - vigorousFromSport), style: style, p)
            if capped {
                plan.notes.insert(x.highBP == true ? "基线期血压平均在 160/100 以上：血压控制好之前不安排高强度间歇，先用中等强度把有氧基础打牢。"
                                  : "你的情况暂不安排高强度间歇：先用中等强度把有氧基础打牢，医生确认后再加。", at: 0)
            }
            outdoors(&plan, count: 2)
            if wk == x.weeks && !maintaining { addRetest(&plan, p) }
            plan.notes.insert("这一轮看最大摄氧量：大部分训练保持能说话的强度，少量训练让心跳明显加快。手表只在户外平路快走、跑步或徒步后才更新最大摄氧量，骑车、游泳和球类不会，所以每周至少 2 次户外快走或慢跑。", at: 0)
        case .cardio:
            if x.target.isBloodPressure {
                addWallSquats(&plan, p)
                plan.notes.insert("降血压：多数日子做 30 分钟以上中等强度有氧（每次运动后的几个小时血压也会偏低），每周 3 次靠墙静蹲。少盐（每天 5 克以内）、限酒、睡够。", at: 0)
            } else {
                plan.notes.insert("降静息心率：以能说话的中低强度有氧为主，坚持比强度更重要；睡眠、饮酒和压力也会直接影响静息心率。", at: 0)
            }
            if core >= 3, !noIntervals, x.target == .restingHR, !beginner { addIntervals(&plan, count: max(0, 1 - vigorousFromSport), style: style, p) }
            moreAerobicDays(&plan, p)
        case .metabolic:
            afterMealWalks(&plan)
            if core >= 3, !noIntervals, !beginner { addIntervals(&plan, count: max(0, 1 - vigorousFromSport), style: style, p) }
            plan.notes.insert("改善血糖和体重：每天晚饭后走 10–15 分钟，每周 2–3 次力量训练（隔天做），每周 150 分钟以上中等强度运动。", at: 0)
            if p.hasDiabetes { plan.notes.append("用胰岛素或磺脲类药物时，运动前看一眼血糖；低于 5.6 先吃点碳水，随身带糖。饭后约 1 小时再运动，低血糖的风险小一些。") }
        case .sleep:
            sleepNotes(&plan, p, x, week: wk)
        case .event:
            break
        }
        if aerobicOnly { plan.notes.insert("基线期运动后的心率恢复偏慢：前两周只练有氧基础，第 3 周再考虑间歇。", at: 0) }
        if p.jointIssues { lowImpact(&plan) }
        if let slot = x.mainSlot { atUsualTime(&plan, slot) }
        if maintaining { maintenance(&plan) }
        return withBase(plan, p, x, ws)
    }

    /// 睡眠改善: this week's times. The wake time stays where it was at baseline (to the quarter hour); with too
    /// little sleep, bedtime comes 15 minutes earlier each week until the nights reach 7 hours (Docs 3.7).
    /// Bedtime is in minutes after midnight, past 24 h for a bedtime after midnight.
    static func sleepSchedule(_ p: ProfileSnapshot, _ x: ProgramPlanInput, week wk: Int) -> (bed: Int, wake: Int) {
        func quarter(_ m: Double) -> Int { Int((m / 15).rounded()) * 15 }
        let wake = x.wakeTime.map(quarter) ?? p.wakeMinutes
        var bed = x.bedtime.map(quarter) ?? (p.bedtimeMinutes < 12 * 60 ? p.bedtimeMinutes + 24 * 60 : p.bedtimeMinutes)
        // Insomnia said later in the round: no more earlier bedtimes (the pack would not start with it).
        if x.target == .sleepDuration, !p.insomnia, let h = x.sleepHours, h < 7 {
            let short = Int(((7 - h) * 4).rounded(.up)) * 15
            bed -= min(15 * wk, short)
        }
        return (bed, wake)
    }

    /// 睡眠改善 (Docs 3.7): a fixed wake time, bedtime earlier week by week for too little sleep, and the habits
    /// that matter most for falling asleep. Training stays as it is: regular exercise helps sleep too.
    static func sleepNotes(_ plan: inout WeekPlan, _ p: ProfileSnapshot, _ x: ProgramPlanInput, week wk: Int) {
        let (bed, wake) = sleepSchedule(p, x, week: wk)
        let b = Clock.text(bed), w = Clock.text(wake)
        let core = x.target == .sleepDuration
            ? "这一轮睡够：每天 \(w) 起床，周末也不晚于平时 1 小时；这周 \(b) 前上床，之后每周提前 15 分钟，直到每晚睡够 7 小时。"
            : "这一轮睡得规律：每天 \(w) 前后半小时内起床，周末也一样；上床时间固定在 \(b) 前后半小时。"
        // Stimulus control; people prone to falls get up more carefully at night (AASM 2021).
        let fall = p.isAtLeast(age: 65) || p.jointIssues ? "夜里起来时先坐一会儿、开一盏小灯再走。" : ""
        plan.notes.insert(core + "躺下 20 分钟还睡不着，就起来做点放松的事，困了再回床。" + fall, at: 0)
        plan.notes.append("下午 \(p.caffeineCutoffHour) 点后不喝咖啡和功能饮料；晚上尽量不喝酒，两杯以上就会让后半夜睡得浅；白天小睡不超过 30 分钟；起床后尽快到户外或窗边接触亮光；晚上把灯调暗，睡前 1 小时放下工作和手机。")
        if x.mainSlot == .evening || x.mainSlot == .night { plan.notes.append("晚上运动没关系，高强度的在睡前 1 小时以前结束。") }
        plan.notes.append("每周至少 3 个晚上很难入睡、夜里醒来很难再睡或醒得太早，持续 3 个月以上，可能是失眠：这时先别再提前上床，在床上躺得越久越难睡；首选的治疗是失眠认知行为治疗（CBT-I），请去睡眠门诊。打鼾很响、有人看到你睡着时憋气，也请先看医生。")
    }

    /// The days to train on: the weekdays the user exercised on at baseline first, as many as they have days for
    /// (never a dialysis day), then their other available days (Docs 4).
    static func trainingWeekdays(_ p: ProfileSnapshot, _ x: ProgramPlanInput) -> [Int] {
        let usual = (x.usualWeekdays ?? []).filter { !p.dialysisWeekdays.contains($0) }
        guard usual.count >= 2 else { return p.availableWeekdays }
        let n = max(p.availableWeekdays.count, min(usual.count, 6))
        var days = Array(usual.prefix(n))
        for d in p.availableWeekdays where days.count < n && !days.contains(d) { days.append(d) }
        return days
    }

    /// 总结期: the base layer and 2–3 core sessions a week at the same effort (Docs 7).
    static func maintenance(_ plan: inout WeekPlan) {
        // Key sessions (intervals, the user's hard ball game) are the ones kept first.
        let training = plan.sessions.indices.filter { plan.sessions[$0].kind.isTraining }
        let kept = Set((training.filter { plan.sessions[$0].isKey } + training.filter { !plan.sessions[$0].isKey }).prefix(3))
        for i in training where !kept.contains(i) {
            plan.sessions[i] = PlannedSession(weekday: plan.sessions[i].weekday, kind: .walk, title: "日常活动日",
                                              detail: "维持期：走走路、做做拉伸，不额外加训练。", guidance: Intensity.easy.talkTest, minutes: 20,
                                              minimumMinutes: 10, minimumDetail: "走 10 分钟", intensity: .easy, isKey: false)
        }
        plan.notes.insert("维持期：保持基础习惯，每周 2–3 次核心训练，强度和这一轮最后一周一样，不再加量。", at: 0)
    }

    /// Joints that running and jumping would make worse: the same effort on a bike, in the water or on an elliptical.
    static func lowImpact(_ plan: inout WeekPlan) {
        for i in plan.sessions.indices where plan.sessions[i].kind.isTraining && plan.sessions[i].kind != .strength {
            plan.sessions[i].detail += " 关节不适时用骑行、游泳或椭圆机代替跑跳。"
        }
        plan.notes.append("你提到骨骼或关节问题：有氧和间歇优先选骑行、游泳、椭圆机等低冲击运动。")
    }

    /// Training at the time of day the user already exercises (Docs 4: evening exercisers get no morning sessions).
    static func atUsualTime(_ plan: inout WeekPlan, _ slot: TimeSlot) {
        for i in plan.sessions.indices where plan.sessions[i].kind.isTraining {
            plan.sessions[i].detail = "建议\(slot.label)练，和你平时一样。" + plan.sessions[i].detail
        }
        plan.notes.append("训练时间：基线期你大多在\(slot.label)运动，计划也按\(slot.label)安排。")
    }

    // MARK: 基线期

    /// 摸底周 (Docs 2.1): everyday life as usual, one or two outdoor walks or jogs of 20 minutes or more so the
    /// watch estimates VO2max, an optional strength self-test, and weighing on the scale on two mornings.
    static func baselineWeek(profile p: ProfileSnapshot, weekStart ws: Date) -> WeekPlan {
        var days = Weekday.mondayFirst.filter { p.availableWeekdays.contains($0) && !p.dialysisWeekdays.contains($0) }
        if days.isEmpty { days = [3, 5, 7] }
        let outdoor = Array(days.prefix(2))
        let test = days.count > 2 ? days[2] : nil
        var sessions: [PlannedSession] = []
        for wd in Weekday.mondayFirst {
            if outdoor.contains(wd) {
                sessions.append(PlannedSession(weekday: wd, kind: .test, title: "户外快走或慢跑",
                                               detail: "戴着 Apple Watch 在户外平路快走或慢跑 20 分钟以上，按平时的速度。手表会据此估算心肺能力（最大摄氧量）。",
                                               guidance: "平时的速度就好，不用刻意加快。", minutes: 25, minimumMinutes: 20,
                                               minimumDetail: "户外快走 20 分钟", intensity: .moderate, isKey: true))
            } else if wd == test {
                sessions.append(PlannedSession(weekday: wd, kind: .strength, title: "力量自测（可选）",
                                               detail: "热身后做俯卧撑，做到做不动为止（女性可以跪姿），或者 30 秒内从椅子上站起坐下的次数（60 岁以上做这个）。做完记到「基础信息」里。",
                                               guidance: "动作做标准，累了就停，不要憋气。", minutes: 10, minimumMinutes: 0,
                                               minimumDetail: "今天不方便就跳过", intensity: .moderate, isKey: false))
            } else {
                sessions.append(PlannedSession(weekday: wd, kind: .walk, title: "日常活动",
                                               detail: "保持平时的运动和作息，不用刻意多练，否则基线不准。",
                                               guidance: Intensity.easy.talkTest, minutes: 20, minimumMinutes: 10,
                                               minimumDetail: "饭后散步 10 分钟", intensity: .easy, isKey: false))
            }
        }
        return WeekPlan(sessions: sessions, weeklyTargetMinutes: p.weeklyTargetMinutes,
                        notes: ["基线期 · 摸底周：照常生活，记录 7 天。保持平时的运动和作息，不用刻意多练，否则基线不准。",
                                "用体脂秤的话，早上起床、排便后空腹称，这周称 2 次以上。",
                                "平时做的运动照常做，手表会自动记录。"])
    }

    // MARK: Base layer

    /// The week's step target: a rise of about 1000 a week from the baseline, up to where the benefit levels off.
    static func stepsTarget(_ x: ProgramPlanInput, age: Int?, week wk: Int) -> Int? {
        guard let b = x.baselineSteps else { return nil }
        let base = Int((b / 500).rounded()) * 500
        let plateau = PopulationNorms.stepPlateau(age: age).lowerBound
        return base >= plateau ? base : min(plateau, base + 1000 * wk)
    }

    static func withBase(_ plan: WeekPlan, _ p: ProfileSnapshot, _ x: ProgramPlanInput, _ ws: Date) -> WeekPlan {
        var plan = plan
        // The step target rises through the round, then holds (also in 总结期).
        let wk = p.programPhase == .summary ? max(1, x.weeks) : x.roundWeek(ws)
        let steps = stepsTarget(x, age: p.age, week: wk)
        plan.stepsTarget = steps
        if let steps {
            for i in plan.sessions.indices where plan.sessions[i].kind == .walk && plan.sessions[i].title == "日常活动日" {
                plan.sessions[i].detail = plan.sessions[i].detail.replacingOccurrences(of: "步数目标 \(p.stepsTarget) 步", with: "步数目标 \(steps) 步")
            }
        }
        var base = "基础习惯：" + (steps.map { "每天 \($0) 步左右，" } ?? "") + "坐 30–60 分钟起身活动 2–3 分钟，每晚睡够 7 小时，每周 2 次力量。"
        if p.isAtLeast(age: 65) { base += "每周 3 次平衡练习（单脚站、脚跟脚尖走）。" }
        plan.notes.insert(base, at: min(1, plan.notes.count))
        plan.notes.insert(p.programPhase == .summary ? "总结期 · 维持：\(x.pack.title)" : "第 \(x.round) 轮 · 第 \(wk) / \(x.weeks) 周：\(x.pack.title)", at: 0)
        return plan
    }

    // MARK: Building blocks

    static func trainingDays(_ plan: WeekPlan) -> Int { plan.sessions.filter { $0.kind.isTraining }.count }

    static func ballSession(_ s: SportHabit, weekday: Int, hard: Bool, _ p: ProfileSnapshot) -> PlannedSession {
        let why = s.reserveShare.map { "按你近 4 周的心率（平均在心率储备的 \(Int(($0 * 100).rounded()))%），\(s.type.label)对你是\(s.intensity.label)" } ?? "\(s.type.label)按你的感觉是\(s.intensity.label)"
        return PlannedSession(weekday: weekday, kind: hard ? .quality : .aerobic, title: s.type.label,
                              detail: "\(why)，\(hard ? "算作本周的高强度训练" : "算作一次有氧训练")。打之前热身 10 分钟（慢跑、动态拉伸、挥拍），打完拉伸小腿和肩。",
                              guidance: PlanGenerator.guidance(hard ? .hard : .moderate, p), minutes: max(30, Int(s.minutes)),
                              minimumMinutes: 20, minimumDetail: "打不了就快走 20 分钟", intensity: hard ? .hard : .moderate, isKey: hard)
    }

    /// Intervals in place of easy aerobic sessions, never on two days in a row.
    static func addIntervals(_ plan: inout WeekPlan, count: Int, style: IntervalStyle, _ p: ProfileSnapshot) {
        guard count > 0 else { return }
        var used: [Int] = plan.sessions.filter { $0.kind == .quality }.map(\.weekday)
        var added = 0
        for i in plan.sessions.indices where added < count && plan.sessions[i].kind == .aerobic {
            let wd = plan.sessions[i].weekday
            let o = PlanGenerator.order(wd)
            if used.contains(where: { abs(PlanGenerator.order($0) - o) <= 1 }) { continue }
            let minutes = max(25, plan.sessions[i].minutes)
            let (title, detail): (String, String) = switch style {
            case .gentle: ("快慢走交替", "热身 10 分钟 → 快走 1 分钟（有点喘、还能说话）+ 慢走 2 分钟，重复 6–8 次 → 放松 5 分钟。")
            case .beginner: ("快慢交替", "热身 10 分钟 → 1 分钟快走或慢跑（有点喘）+ 2 分钟慢走，重复 6–8 次 → 放松 5 分钟。")
            case .standard: ("4×4 间歇", "热身 10 分钟 → 4 分钟较高强度（约最大心率的 85–95%，只能说几个字）+ 3 分钟轻松，重复 4 次 → 放松 5 分钟。跑步、骑车、游泳都可以。")
            }
            plan.sessions[i] = PlannedSession(
                weekday: wd, kind: .quality, title: title, detail: detail,
                guidance: PlanGenerator.guidance(style == .gentle ? .moderate : .hard, p), minutes: minutes, minimumMinutes: 20,
                minimumDetail: "以 20 分钟轻松有氧替代", intensity: .hard, isKey: true)
            used.append(wd)
            added += 1
        }
    }

    /// The watch estimates VO2max only after outdoor walks, runs or hikes on flat ground: the first easy sessions say so.
    static func outdoors(_ plan: inout WeekPlan, count: Int) {
        var n = 0
        for i in plan.sessions.indices where n < count && [.aerobic, .long].contains(plan.sessions[i].kind) {
            plan.sessions[i].detail += "尽量在户外平路快走或慢跑，手表才会更新最大摄氧量。"
            n += 1
        }
    }

    /// 心肺复测 in week 4: an outdoor walk or run so the watch updates its estimate.
    static func addRetest(_ plan: inout WeekPlan, _ p: ProfileSnapshot) {
        guard let i = plan.sessions.lastIndex(where: { $0.kind == .aerobic || $0.kind == .long }) else { return }
        plan.sessions[i].kind = .test
        plan.sessions[i].title = "心肺复测"
        plan.sessions[i].detail = "戴着手表在户外快走或慢跑 20–30 分钟，路线和配速尽量和平时一样。手表会更新最大摄氧量的估算，用来和基线比。"
    }

    /// Wall squats (isometric) after three sessions: 4 × 2 minutes, 2 minutes' rest, breathing normally. Hand-grip
    /// holds instead for sore knees and for higher-risk hearts (blood pressure rises less with them).
    static func addWallSquats(_ plan: inout WeekPlan, _ p: ProfileSnapshot) {
        let knee = p.jointIssues || p.isAtLeast(age: 65)
            || !p.conditions.isDisjoint(with: [.coronaryDisease, .heartFailure, .arrhythmia])
        let add = knee
            ? "结束后做静力握拳：用力握住一个软球或毛巾卷（约三成力气）2 分钟，换手，共 4 组。不憋气。"
            : "结束后做靠墙静蹲：背靠墙、膝盖弯到能坚持 2 分钟的角度，2 分钟 × 4 组，组间休息 2 分钟。全程正常呼吸，不憋气。"
        var n = 0
        for i in plan.sessions.indices where n < 3 && [.aerobic, .walk, .long].contains(plan.sessions[i].kind) && plan.sessions[i].intensity != .rest {
            if n > 0, let prev = plan.sessions[..<i].last(where: { $0.detail.contains(knee ? "静力握拳" : "靠墙静蹲") }),
               abs(PlanGenerator.order(prev.weekday) - PlanGenerator.order(plan.sessions[i].weekday)) < 2 { continue }
            plan.sessions[i].detail += add
            plan.sessions[i].minutes += 15
            n += 1
        }
    }

    /// Blood pressure answers to aerobic exercise on most days: daily-activity days get a 30-minute brisk walk.
    static func moreAerobicDays(_ plan: inout WeekPlan, _ p: ProfileSnapshot) {
        for i in plan.sessions.indices where plan.sessions[i].kind == .walk && plan.sessions[i].title == "日常活动日" {
            plan.sessions[i].title = "快走日"
            plan.sessions[i].detail = "快走 30 分钟（可以分 2–3 次，每次 10 分钟以上），微微出汗、还能说话。" + plan.sessions[i].detail
            plan.sessions[i].minutes = 30
        }
    }

    /// After-dinner walks on every day: 10–15 minutes lowers the rise in glucose after the meal.
    static func afterMealWalks(_ plan: inout WeekPlan) {
        for i in plan.sessions.indices where plan.sessions[i].intensity != .hard {
            if plan.sessions[i].kind == .walk && plan.sessions[i].title == "日常活动日" {
                plan.sessions[i].title = "饭后散步"
                plan.sessions[i].detail = "晚饭后 15–30 分钟出门走 10–15 分钟，能让餐后血糖低一些。" + plan.sessions[i].detail
                plan.sessions[i].minimumDetail = "晚饭后走 10 分钟"
            } else if plan.sessions[i].kind.isTraining {
                plan.sessions[i].detail += " 能安排在饭后 1 小时内更好。"
            }
        }
    }
}
