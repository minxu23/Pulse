import Foundation

struct PlannedSession: Equatable {
    var weekday: Int
    var kind: PlanKind
    var title: String
    var detail: String
    var guidance: String
    var minutes: Int
    var minimumMinutes: Int
    var minimumDetail: String
    var intensity: Intensity
    var isKey: Bool
}

struct WeekPlan: Equatable {
    var sessions: [PlannedSession]
    var weeklyTargetMinutes: Int
    var notes: [String]
    var marathon: MarathonWeek?
}

/// Builds a sustainable weekly plan from the user's level, goals, available days, time,
/// health conditions and care-plan limits (需求 4).
enum PlanGenerator {
    /// Gradual progression: grow ~10 % after a well-completed week, hold or ease off otherwise.
    static func nextWeeklyTarget(current: Int, lastWeekCompletion: Double?, profile: ProfileSnapshot) -> (minutes: Int, reason: String) {
        let levelCap: Int = [150, 200, 300, 420, 600][profile.level.rank]
        let cap = max(60, min(levelCap, Int(Double(profile.weeklyTimeBudget) * 0.8)))
        guard let c = lastWeekCompletion else {
            return (min(current, cap), "按当前基础设置本周有氧目标。")
        }
        if c >= 0.85 {
            let next = min(cap, Int((Double(current) * 1.1)).roundedTo5())
            return next > current
                ? (next, "上周完成 \(Int(c * 100))%，本周有氧目标小幅增加约 10%。")
                : (current, "上周完成良好，已接近你可投入的时间上限，本周保持。")
        } else if c >= 0.6 {
            return (min(current, cap), "上周完成 \(Int(c * 100))%，本周保持相同目标，巩固规律。")
        } else {
            return (max(45, Int(Double(current) * 0.85).roundedTo5()), "上周完成 \(Int(c * 100))%，本周适当降低目标，先让计划更容易坚持。")
        }
    }

    static func generate(profile: ProfileSnapshot, weekStart: Date) -> WeekPlan {
        if profile.modules.contains(.marathon), let race = profile.race,
           race.date >= weekStart.adding(days: -21) {
            return marathonWeek(profile: profile, race: race, weekStart: weekStart)
        }
        return generalWeek(profile: profile, weekStart: weekStart)
    }

    // MARK: General health plan

    static func generalWeek(profile p: ProfileSnapshot, weekStart: Date? = nil) -> WeekPlan {
        var days = Weekday.mondayFirst.filter { p.availableWeekdays.contains($0) }
        if days.isEmpty { days = [3, 5, 7] }
        // On a roster: no training on night-shift days or the recovery day right after a run of nights.
        var shiftKinds: [Int: (kind: ShiftKind, afterNight: Bool)] = [:]
        if let s = p.shift, let ws = weekStart {
            for wd in Weekday.mondayFirst {
                let d = ws.adding(days: order(wd))
                shiftKinds[wd] = (s.kind(on: d), s.kind(on: d.adding(days: -1)) == .night && s.kind(on: d) != .night)
            }
            let fit = days.filter { shiftKinds[$0]?.kind != .night && shiftKinds[$0]?.afterNight != true }
            let fallback = Weekday.mondayFirst.filter { shiftKinds[$0]?.kind != .night && shiftKinds[$0]?.afterNight != true }
            days = fit.count >= 2 ? fit : Array(fallback.prefix(max(2, min(3, fit.count))))
        }
        if days.count > 6 { days = Array(days.prefix(6)) }
        let n = days.count

        let allowQuality = p.level.rank >= ActivityLevel.moderate.rank
            && !p.goals.isDisjoint(with: [.fitness, .event])
            && !p.cardiacLimited
            && !p.conditions.contains(.pregnancy)
            && !p.conditions.contains(.heartFailure)
            && !p.intensityCapped

        enum Role { case aerobic, aerobicPlusStrength, strength, quality, long }
        var roles: [Role]
        switch n {
        case 1: roles = [.aerobicPlusStrength]
        case 2: roles = [.aerobicPlusStrength, .long]
        case 3: roles = [.aerobic, .strength, .long]
        case 4: roles = [.aerobicPlusStrength, .strength, allowQuality ? .quality : .aerobic, .long]
        case 5: roles = [.aerobic, .strength, allowQuality ? .quality : .aerobic, .strength, .long]
        default: roles = [.aerobic, .strength, allowQuality ? .quality : .aerobic, .aerobic, .strength, .long]
        }

        // Distribute the aerobic budget.
        let weightOf: (Role) -> Double = { r in
            switch r {
            case .aerobic: 1
            case .aerobicPlusStrength: 0.8
            case .quality: 0.8
            case .long: 1.5
            case .strength: 0
            }
        }
        let totalW = roles.map(weightOf).reduce(0, +)
        let budget = Double(p.weeklyTargetMinutes)
        let session = max(15, p.sessionMinutes)

        var sessions: [PlannedSession] = []
        for (i, wd) in days.enumerated() {
            let role = roles[i]
            let share = totalW > 0 ? budget * weightOf(role) / totalW : 0
            switch role {
            case .aerobic:
                let m = clamp(Int(share).roundedTo5(), 15, session)
                sessions.append(aerobic(wd, minutes: m, p))
            case .aerobicPlusStrength:
                let m = clamp(Int(share).roundedTo5(), 15, max(15, session - 10))
                var s = aerobic(wd, minutes: m, p)
                s.title += " + 10 分钟力量"
                s.detail += " 结束后做 10 分钟徒手力量（深蹲、俯卧撑、臀桥、平板支撑）。"
                s.minutes = m + 10
                sessions.append(s)
            case .strength:
                sessions.append(strength(wd, minutes: clamp(min(30, session), 15, 40), p))
            case .quality:
                sessions.append(quality(wd, minutes: clamp(Int(share).roundedTo5(), 25, session), p))
            case .long:
                let longCap = min(Int(Double(session) * 1.5), 90)
                sessions.append(long(wd, minutes: clamp(Int(share).roundedTo5(), 20, max(20, longCap)), p))
            }
        }

        // Days without training: daily activity, plus one dedicated recovery day.
        let restDays = Weekday.mondayFirst.filter { !days.contains($0) }
        for (i, wd) in restDays.enumerated() {
            if let k = shiftKinds[wd], k.kind == .night || k.afterNight {
                sessions.append(k.kind == .night
                    ? PlannedSession(weekday: wd, kind: .walk, title: "夜班日",
                                     detail: "不安排训练。上班前散步或拉伸 15 分钟，夜班中有空就起身走动；下班后尽快回家睡觉。",
                                     guidance: Intensity.easy.talkTest, minutes: 15, minimumMinutes: 0, minimumDetail: "",
                                     intensity: .easy, isKey: false)
                    : PlannedSession(weekday: wd, kind: .rest, title: "夜班后恢复",
                                     detail: "先补觉，醒后轻松散步、晒晒太阳，晚上按时上床，把作息调回来。",
                                     guidance: Intensity.rest.talkTest, minutes: 0, minimumMinutes: 0, minimumDetail: "",
                                     intensity: .rest, isKey: false))
                continue
            }
            if i == restDays.count - 1 {
                sessions.append(PlannedSession(weekday: wd, kind: .rest, title: "休息恢复",
                                               detail: "不安排训练。可以轻松散步、拉伸，早点休息。", guidance: Intensity.rest.talkTest,
                                               minutes: 0, minimumMinutes: 0, minimumDetail: "", intensity: .rest, isKey: false))
            } else {
                sessions.append(PlannedSession(weekday: wd, kind: .walk, title: "日常活动日",
                                               detail: "步数目标 \(p.stepsTarget) 步，可分散完成：通勤多走一段、饭后散步、久坐每小时起身。",
                                               guidance: Intensity.easy.talkTest, minutes: 20, minimumMinutes: 10,
                                               minimumDetail: "饭后散步 10 分钟", intensity: .easy, isKey: false))
            }
        }

        var notes: [String] = [
            "以「可以说话」的中低强度有氧为主，这是改善静息心率最核心、也最容易坚持的方式。",
            "每次训练都有「精简版」：忙碌时完成精简版，比跳过更有利于保持规律。",
        ]
        if p.cardiacLimited {
            notes.insert("你记录了心血管相关情况：计划暂以低–中等强度为主。请与医生确认适合的运动强度范围（可在「心血管健康」中记录），再考虑加入较高强度训练。热身与放松各 ≥10 分钟；如出现胸痛、胸闷、明显气短、头晕或心悸，立即停止活动。", at: 0)
        }
        if p.hasDiabetes {
            notes.append("运动前后按照护计划检测血糖；使用胰岛素或磺脲类药物时随身携带 15–20 g 快速碳水，运动后数小时及夜间注意低血糖。")
        }
        if p.conditions.contains(.pregnancy) {
            notes.append("妊娠期运动请先与产科医生确认，避免仰卧位长时间训练和有跌倒、碰撞风险的运动。")
        }
        if p.conditions.contains(.ckd) {
            notes.append("慢性肾病：规律的中低强度运动对血压、血糖和体能都有好处。\(p.kidneyLimited ? "医生确认强度范围之前，不安排间歇等高强度训练；" : "")有内瘘的手臂不做负重，运动日饮水\(p.fluidLimited ? "仍按医生定的上限" : "按医生的要求")。")
        }
        if p.onHemodialysis { notes.append("血液透析：透析日（\(Dialysis.schedule(p))）不安排训练，透析后以休息为主。") }
        if p.onPeritoneal { notes.append(Dialysis.peritonealExercise) }
        for x in p.extraConditions where !x.exercise.isEmpty {
            notes.append("\(x.name)：" + x.exercise.joined())
        }
        if p.shift != nil {
            notes.append("训练安排在白班和休息日，避开夜班当天和夜班后的恢复日；白班日训练放在下班后、睡前 3 小时结束。")
        }
        if !p.limitations.isEmpty {
            notes.append("已考虑你的身体限制：「\(p.limitations)」。如动作引起疼痛，请替换为无痛的动作。")
        }
        return WeekPlan(sessions: sessions.sorted { order($0.weekday) < order($1.weekday) },
                        weeklyTargetMinutes: p.weeklyTargetMinutes, notes: notes, marathon: nil)
    }

    private static func aerobic(_ wd: Int, minutes: Int, _ p: ProfileSnapshot) -> PlannedSession {
        let title: String
        switch p.level {
        case .sedentary: title = "快走"
        case .light: title = "快走 / 轻松骑行"
        default: title = p.goals.contains(.fitness) ? "轻松跑 / 骑行" : "轻松有氧"
        }
        return PlannedSession(weekday: wd, kind: .aerobic, title: title,
                              detail: "保持可以完整说话的强度持续进行。规律的中低强度有氧是改善静息心率的基础。",
                              guidance: guidance(.easy, p), minutes: minutes, minimumMinutes: max(10, minutes / 3),
                              minimumDetail: "快走 \(max(10, minutes / 3)) 分钟", intensity: .easy, isKey: false)
    }

    private static func long(_ wd: Int, minutes: Int, _ p: ProfileSnapshot) -> PlannedSession {
        PlannedSession(weekday: wd, kind: .long, title: p.level.rank <= 1 ? "较长时间步行 / 徒步" : "长时间轻松有氧",
                       detail: "本周最长的一次有氧，强度保持轻松，重点是时长。可以选择户外、和家人朋友一起。",
                       guidance: guidance(.easy, p), minutes: minutes, minimumMinutes: max(15, minutes / 2),
                       minimumDetail: "缩短为 \(max(15, minutes / 2)) 分钟轻松有氧", intensity: .easy, isKey: true)
    }

    private static func strength(_ wd: Int, minutes: Int, _ p: ProfileSnapshot) -> PlannedSession {
        var detail = "全身力量：深蹲（或坐站起）、俯卧撑（可扶墙 / 跪姿）、弹力带划船、臀桥、平板支撑，各 2–3 组，每组 8–12 次，动作平稳、不憋气。"
        if p.hasCardiac { detail += " 避免长时间憋气用力（如极限重量）。" }
        return PlannedSession(weekday: wd, kind: .strength, title: "全身力量训练", detail: detail,
                              guidance: Intensity.moderate.talkTest, minutes: minutes, minimumMinutes: 10,
                              minimumDetail: "10 分钟：深蹲 + 俯卧撑 + 平板支撑各 2 组", intensity: .moderate, isKey: false)
    }

    private static func quality(_ wd: Int, minutes: Int, _ p: ProfileSnapshot) -> PlannedSession {
        PlannedSession(weekday: wd, kind: .quality, title: "间歇训练",
                       detail: "热身 10 分钟 → 4–6 组 × 2–3 分钟较高强度 + 2 分钟轻松 → 放松 10 分钟。提升心肺能力，每周 1 次即可。",
                       guidance: guidance(.hard, p), minutes: minutes, minimumMinutes: 20,
                       minimumDetail: "以 20 分钟轻松有氧替代", intensity: .hard, isKey: true)
    }

    static func guidance(_ intensity: Intensity, _ p: ProfileSnapshot) -> String {
        guard intensity != .rest else { return intensity.talkTest }
        if p.onRateLoweringMeds() {
            return intensity.talkTest + "。你正在使用可能降低心率的药物，心率区间参考性有限，请以主观感受为准。"
        }
        let range: (Double, Double)
        if let lthr = p.thresholdHR.map(Double.init) {
            switch intensity {
            case .easy: range = (0.72 * lthr, 0.85 * lthr)
            case .moderate: range = (0.85 * lthr, 0.95 * lthr)
            default: range = (0.95 * lthr, 1.02 * lthr)
            }
        } else {
            let mx = p.estimatedMaxHR
            switch intensity {
            case .easy: range = (0.60 * mx, 0.70 * mx)
            case .moderate: range = (0.70 * mx, 0.80 * mx)
            default: range = (0.80 * mx, 0.90 * mx)
            }
        }
        var lo = Int(range.0), hi = Int(range.1)
        if let cap = p.hrCap { hi = min(hi, cap); lo = min(lo, hi - 5) }
        var text = "\(intensity.talkTest)，参考心率 \(lo)–\(hi) bpm"
        if let cap = p.hrCap { text += "（照护计划上限 \(cap) bpm）" }
        if p.thresholdHR == nil { text += "。心率区间按年龄估算，个体差异较大，感受优先" }
        return text
    }

    // MARK: Marathon

    static func marathonWeek(profile p: ProfileSnapshot, race: RaceInfo, weekStart: Date) -> WeekPlan {
        let mw = MarathonPlanner.week(profile: p, race: race, weekStart: weekStart)
        var notes = mw.notes
        if p.cardiacLimited {
            notes.insert("你记录了心血管相关情况：专项训练中的较高强度内容需要医生评估确认后再进行。", at: 0)
        }
        if p.hasDiabetes {
            notes.append("长距离和强度课前后按照护计划监测血糖，提前规划补给与胰岛素 / 药物调整。")
        }
        let minutes = mw.sessions.filter { $0.kind != .strength }.map(\.minutes).reduce(0, +)
        return WeekPlan(sessions: mw.sessions, weeklyTargetMinutes: minutes, notes: notes, marathon: mw)
    }

    static func order(_ weekday: Int) -> Int { Weekday.mondayFirst.firstIndex(of: weekday) ?? 0 }
    private static func clamp(_ v: Int, _ lo: Int, _ hi: Int) -> Int { max(lo, min(hi, v)) }
}

// MARK: - Marathon planner (专项运动支持)

enum MarathonPhase: String, Equatable {
    case base, build, peak, taper, raceWeek, recovery
    var label: String {
        switch self {
        case .base: "基础期"
        case .build: "强化期"
        case .peak: "专项期"
        case .taper: "减量期"
        case .raceWeek: "比赛周"
        case .recovery: "赛后恢复"
        }
    }
    var focus: String {
        switch self {
        case .base: "建立有氧基础与跑量，强度以轻松为主，加入力量训练预防伤病。"
        case .build: "逐步延长长距离，加入阈值跑提升可持续速度。"
        case .peak: "以马拉松配速跑和最长距离为核心，演练比赛补给。"
        case .taper: "减少跑量、保留少量配速刺激，让身体充分恢复。"
        case .raceWeek: "保持轻松，睡眠、饮食与补给按演练执行。"
        case .recovery: "以休息和轻松活动为主，逐步恢复跑量。"
        }
    }
}

struct MarathonWeek: Equatable {
    var phase: MarathonPhase
    var weeksToRace: Int
    var weeklyKm: Double
    var longRunKm: Double
    var easyPace: Double     // min per km
    var marathonPace: Double
    var thresholdPace: Double
    var sessions: [PlannedSession]
    var notes: [String]
    var warnings: [String]
}

enum MarathonPlanner {
    static func weeksBetween(_ a: Date, _ b: Date) -> Int {
        Int((Double(b.weekStart.daysSince(a.weekStart)) / 7).rounded(.down))
    }

    static func phase(weeksToRace w: Int) -> MarathonPhase {
        switch w {
        case ..<0: .recovery
        case 0: .raceWeek
        case 1...2: .taper
        case 3...8: .peak
        case 9...16: .build
        default: .base
        }
    }

    /// Paces in minutes per km derived from the target finishing time.
    static func paces(targetMinutes: Int?) -> (easy: Double, mp: Double, threshold: Double) {
        let mp = targetMinutes.map { Double($0) / 42.195 } ?? 6.6
        return (easy: mp * 1.18, mp: mp, threshold: mp * 0.93)
    }

    static func paceText(_ v: Double) -> String {
        let total = Int((v * 60).rounded())
        return String(format: "%d:%02d/km", total / 60, total % 60)
    }

    static func week(profile p: ProfileSnapshot, race: RaceInfo, weekStart: Date) -> MarathonWeek {
        let weeksToRace = weeksBetween(weekStart, race.date)
        let total = max(4, weeksBetween(race.startDate, race.date))
        let elapsed = max(0, total - weeksToRace)
        let ph = phase(weeksToRace: weeksToRace)
        let pace = paces(targetMinutes: race.targetMinutes)
        var warnings: [String] = []

        let current = max(10, race.currentWeeklyKm)
        var peak = min(80, max(current * 2, 50))
        let buildWeeks = max(1, total - 3)
        let maxPeak = current * pow(1.1, Double(buildWeeks))
        if peak > maxPeak {
            peak = maxPeak
            warnings.append("距比赛时间较紧：为控制伤病风险，周跑量增长已限制在每周约 10% 以内（峰值约 \(Int(peak)) km）。建议以安全完赛为目标，或考虑更晚的赛事。")
        }

        var km: Double
        var cutback = false
        switch weeksToRace {
        case ..<0: km = peak * 0.35
        case 0: km = peak * 0.35
        case 1: km = peak * 0.55
        case 2: km = peak * 0.7
        default:
            let frac = min(1, Double(elapsed) / Double(buildWeeks))
            km = current + (peak - current) * frac
            if elapsed > 0 && elapsed % 4 == 3 { km *= 0.8; cutback = true }
        }
        km = km.rounded()

        let longCap: Double
        switch ph {
        case .base: longCap = 18
        case .build: longCap = 26
        case .peak: longCap = 32
        case .taper: longCap = weeksToRace == 2 ? 22 : 14
        case .raceWeek: longCap = 42.195
        case .recovery: longCap = 10
        }
        var longKm: Double
        if ph == .raceWeek {
            longKm = 42.195
        } else {
            // Grow the long run ~1.5 km per week from the current longest run.
            let progressive = race.longestRunKm + 1.5 * Double(elapsed)
            let fraction = km < 50 ? 0.55 : 0.45
            longKm = min(longCap, progressive, max(8, km * fraction))
            if cutback { longKm *= 0.8 }
            longKm = longKm.rounded()
        }

        var days = Weekday.mondayFirst.filter { p.availableWeekdays.contains($0) }
        if days.count < 3 {
            warnings.append("全马训练建议每周至少跑 3 次。可用训练日较少时，计划以完赛为目标。")
            if days.isEmpty { days = [3, 5, 7] }
        }
        if days.count > 6 { days = Array(days.prefix(6)) }

        var sessions: [PlannedSession] = []
        let longDay = days.last!
        let qualityDay = days.count >= 3 ? days[days.count / 2 - (days.count % 2 == 0 ? 1 : 0)] : nil
        // Strength pairs with an easy day so it never lands on the quality or long-run day.
        let easyDays = days.filter { $0 != longDay && $0 != qualityDay }
        let strengthDay = days.count >= 4 ? easyDays.first : nil

        // Long run / race
        if ph == .raceWeek {
            sessions.append(PlannedSession(weekday: race.date.weekday, kind: .long, title: "比赛日：\(race.name.isEmpty ? "全程马拉松" : race.name)",
                                           detail: "前半程控制在目标配速 \(paceText(pace.mp)) 或稍慢，按演练补给：每小时约 \(race.fuelCarbsPerHour) g 碳水，少量多次补水。",
                                           guidance: "按目标配速与身体感受执行", minutes: Int(42.195 * pace.mp), minimumMinutes: 0,
                                           minimumDetail: "", intensity: .hard, isKey: true))
        } else {
            let longMin = Int(longKm * pace.easy)
            var detail = "\(Int(longKm)) km 轻松配速 \(paceText(pace.easy)) 左右。"
            if longMin >= 90 {
                detail += " 超过 90 分钟：每小时补充约 \(race.fuelCarbsPerHour) g 碳水（常见建议 30–60 g/h，经过肠胃训练可更高），少量多次补水，演练比赛日补给。"
            }
            if ph == .peak && weeksToRace <= 6 && weeksToRace >= 4 {
                detail += " 最后 \(Int(longKm * 0.3)) km 可尝试马拉松配速。"
            }
            sessions.append(PlannedSession(weekday: longDay, kind: .long, title: "长距离跑 \(Int(longKm)) km", detail: detail,
                                           guidance: PlanGenerator.guidance(.easy, p), minutes: longMin, minimumMinutes: Int(longKm * 0.6 * pace.easy),
                                           minimumDetail: "缩短至 \(Int(longKm * 0.6)) km，不在其他日子补回", intensity: .easy, isKey: true))
        }

        // Quality
        if let qd = qualityDay, ph != .raceWeek, ph != .recovery {
            let (title, detail, qkm): (String, String, Double)
            switch ph {
            case .base:
                (title, detail, qkm) = ("轻松跑 + 加速跑", "轻松跑后做 6 × 20 秒加速跑（放松、步频快），间歇充分走路恢复。", 7)
            case .build:
                (title, detail, qkm) = ("阈值跑", "热身 2 km → 20–30 分钟阈值配速 \(paceText(pace.threshold)) → 放松 2 km。", 9)
            case .peak:
                let mpKm = min(16, max(8, km * 0.2)).rounded()
                (title, detail, qkm) = ("马拉松配速跑", "热身 2 km → \(Int(mpKm)) km 马拉松配速 \(paceText(pace.mp)) → 放松 2 km，同时演练补给。", mpKm + 4)
            default:
                (title, detail, qkm) = ("配速保持", "热身 2 km → 3 × 2 km 马拉松配速，间歇慢跑 2 分钟 → 放松。", 9)
            }
            sessions.append(PlannedSession(weekday: qd, kind: .quality, title: title, detail: detail,
                                           guidance: PlanGenerator.guidance(.hard, p), minutes: Int(qkm * pace.easy * 0.95),
                                           minimumMinutes: 25, minimumDetail: "改为 25 分钟轻松跑", intensity: ph == .base ? .moderate : .hard, isKey: true))
        }

        // Strength
        if let sd = strengthDay {
            sessions.append(PlannedSession(weekday: sd, kind: .strength, title: "跑者力量",
                                           detail: "单腿蹲、提踵、臀桥、侧桥、死虫，各 2–3 组。减量期减半。",
                                           guidance: Intensity.moderate.talkTest, minutes: ph == .taper ? 15 : 25, minimumMinutes: 10,
                                           minimumDetail: "10 分钟核心 + 提踵", intensity: .moderate, isKey: false))
        }

        // Easy runs absorb the remaining distance.
        let used = sessions.reduce(0.0) { acc, s in
            s.kind == .strength ? acc : acc + Double(s.minutes) / pace.easy
        }
        let remaining = max(0, km - (ph == .raceWeek ? 0 : used))
        let perEasy = easyDays.isEmpty ? 0 : max(4, (remaining / Double(easyDays.count)).rounded())
        for wd in easyDays where !(ph == .raceWeek && wd == race.date.weekday) {
            let k = ph == .raceWeek ? 5 : perEasy
            sessions.append(PlannedSession(weekday: wd, kind: .aerobic, title: "轻松跑 \(Int(k)) km",
                                           detail: "轻松配速 \(paceText(pace.easy)) 或更慢，能完整说话。",
                                           guidance: PlanGenerator.guidance(.easy, p), minutes: Int(k * pace.easy), minimumMinutes: 20,
                                           minimumDetail: "20 分钟轻松跑或快走", intensity: .easy, isKey: false))
        }

        let used2 = Set(sessions.map(\.weekday))
        for wd in Weekday.mondayFirst where !used2.contains(wd) {
            sessions.append(PlannedSession(weekday: wd, kind: .rest, title: "休息 / 交叉训练",
                                           detail: "完全休息，或 20–30 分钟低冲击活动（骑行、游泳、拉伸）。",
                                           guidance: Intensity.rest.talkTest, minutes: 0, minimumMinutes: 0,
                                           minimumDetail: "", intensity: .rest, isKey: false))
        }

        var notes = ["\(ph.label)：\(ph.focus)"]
        if ph == .build || ph == .base {
            notes.append("如有条件，可在专业人员指导下进行乳酸阈测试（标准化热身、递增负荷、相同饮食与时段），用测得的阈值心率 / 配速替代估算值。")
        }
        if weeksToRace >= 0 {
            notes.append("距比赛 \(weeksToRace) 周 · 本周目标跑量约 \(Int(km)) km · 长距离 \(Int(longKm)) km")
        }

        return MarathonWeek(phase: ph, weeksToRace: weeksToRace, weeklyKm: km, longRunKm: longKm,
                            easyPace: pace.easy, marathonPace: pace.mp, thresholdPace: pace.threshold,
                            sessions: sessions.sorted { PlanGenerator.order($0.weekday) < PlanGenerator.order($1.weekday) },
                            notes: notes, warnings: warnings)
    }

    /// Carbohydrate & fluid plan for a run of the given duration.
    static func fuelPlan(minutes: Int, carbsPerHour: Int) -> (carbs: Int, fluidLow: Int, fluidHigh: Int, note: String) {
        let hours = Double(minutes) / 60
        guard minutes >= 75 else {
            return (0, 0, Int(hours * 500), "75 分钟以内通常不需要额外碳水，按口渴补水即可。")
        }
        let carbs = Int(hours * Double(carbsPerHour))
        return (carbs, Int(hours * 400), Int(hours * 800),
                "从第 30–45 分钟开始，每 20–30 分钟补一次；炎热天气需更多液体与电解质。比赛日只使用训练中试过的补给。")
    }
}
