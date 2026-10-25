import Foundation

// 所处阶段 follows the user's management goals. Each goal has its own path, and the records decide
// where the user is: the first stage whose condition is not met yet, with what is still missing and
// what to do now. A stage is passed by doing it (a baseline, a routine, enough data to compare) —
// only a race runs on the calendar. A stage once reached is kept: if a routine slips later, the
// stage stays passed and the current one says what to pick up again.

/// One management goal's path of stages.
struct GoalJourney: Identifiable, Equatable {
    struct Stage: Identifiable, Equatable {
        let id: String
        let title: String
        /// What the stage is for.
        let focus: String
    }

    /// Where the user stands in a stage.
    struct Standing: Equatable {
        var met: Bool
        /// How far along ("近 4 周训练完成 13%").
        var status: String
        /// 0…1 when it can be measured.
        var progress: Double? = nil
        /// What moves the user on ("近 4 周的训练完成率到 60%（现在 13%）"); nil for a stage that is kept, not passed.
        var toPass: String? = nil
        /// What to do now (said once, in the 长期总结).
        var next: String
        /// A step that needs the doctor; it comes before every other goal's next step.
        var urgent = false
    }

    let id: String
    let title: String
    /// For the goal switcher ("静息心率").
    let short: String
    let stages: [Stage]
    /// The current stage; `stages.count` once every stage is reached.
    let current: Int
    /// The current stage's standing (the last stage's once all are reached).
    let standing: Standing

    var isComplete: Bool { current >= stages.count }
    /// Whether the furthest stage is remembered (a race follows the calendar and a new race starts it again).
    var keepsReached: Bool { id != "race" }
}

enum GoalJourneys {
    /// A path for each of the user's goals, in a fixed order; 配合疾病照护 gets a path per condition managed.
    static func paths(_ c: AgentContext) -> [GoalJourney] {
        let p = c.profile
        var out: [GoalJourney] = []
        if p.goals.contains(.lowerRHR) { out.append(restingHeart(c)) }
        if p.goals.contains(.energy) { out.append(energy(c)) }
        if p.goals.contains(.fitness) { out.append(fitness(c)) }
        if p.goals.contains(.event) || c.marathonActive { out.append(race(c)) }
        if p.goals.contains(.careAligned) {
            let bp = p.conditions.contains(.hypertension) || p.modules.contains(.cardioCare)
            if bp { out.append(bloodPressure(c)) }
            if p.hasDiabetes { out.append(glucose(c)) }
            if !bp && !p.hasDiabetes { out.append(care()) }
        }
        return out.isEmpty ? [restingHeart(c)] : out
    }

    /// The page's one next step: a care step that needs the doctor first, otherwise the first goal's.
    static func nextStep(_ c: AgentContext) -> String? {
        let paths = paths(c)
        return (paths.first { $0.standing.urgent && !$0.isComplete } ?? paths.first)?.standing.next
    }

    private typealias Step = (GoalJourney.Stage, GoalJourney.Standing)

    /// The current stage is the first one not met yet, counting from the furthest one reached before.
    private static func path(_ id: String, _ title: String, _ short: String, reached: Int = 0, _ steps: [Step]) -> GoalJourney {
        let start = min(max(0, reached), steps.count)
        let i = steps.indices.dropFirst(start).first { !steps[$0].1.met } ?? steps.count
        return GoalJourney(id: id, title: title, short: short, stages: steps.map(\.0), current: i, standing: steps[min(i, steps.count - 1)].1)
    }

    private static func pct(_ x: Double) -> String { "\(Int((x * 100).rounded()))%" }

    /// A progress dimension as "起始 78 bpm → 最近 78 bpm", or how long until it can be compared.
    private static func compared(_ d: ProgressDimension?) -> String {
        guard let d, d.status != .insufficient, let from = d.from, let to = d.to else { return "数据积累中，约 6 周后可以比较" }
        return "起始 \(from) → 最近 \(to)"
    }

    // MARK: Goals

    static func restingHeart(_ c: AgentContext) -> GoalJourney {
        let n = c.trend.points.count, need = RHRTrendAnalyzer.minBaselineDays
        let plan = c.adherence("plan")?.rate ?? 0
        let check = c.adherence("checkin")?.rate ?? 0
        let rhr = c.dimension("rhr")
        return path("rhr", "改善静息心率", "静息心率", reached: c.profile.journeyReached["rhr"] ?? 0, [
            (.init(id: "baseline", title: JourneyStage.baseline.title, focus: JourneyStage.baseline.focus),
             .init(met: c.trend.baseline != nil, status: "已记录 \(n) 天", progress: min(1, Double(n) / Double(need)),
                   toPass: "记满 \(need) 天就能算出基线（现在 \(n) 天）", next: "每天早上醒来、起床前测一次，条件越一致越准。")),
            (.init(id: "habits", title: JourneyStage.habits.title, focus: JourneyStage.habits.focus),
             .init(met: plan >= 0.6, status: c.adherence("plan") == nil ? "近 4 周还没有训练计划" : "近 4 周训练完成 \(pct(plan))",
                   progress: min(1, plan / 0.6), toPass: "近 4 周的训练完成率到 60%（现在 \(pct(plan))）",
                   next: plan < 0.4 ? "先让计划更容易坚持，每次练短一点，或者少排一天。" : "按周计划练，忙的时候用精简版，别让一周空着。")),
            (.init(id: "adaptive", title: JourneyStage.adaptive.title, focus: JourneyStage.adaptive.focus),
             .init(met: check >= 0.5, status: "近 4 周有 \(pct(check)) 的早上做了晨起记录", progress: min(1, check / 0.5),
                   toPass: "一半以上的早上做晨起记录（现在 \(pct(check))）",
                   next: "每天早上花 20 秒记录感受，准备度会更贴近你的状态，累的时候就照着调整。")),
            (.init(id: "verify", title: JourneyStage.verify.title, focus: JourneyStage.verify.focus),
             .init(met: rhr?.status == .improved, status: compared(rhr), toPass: "静息心率比起始 4 周明显下降",
                   next: ReviewCoach.nextStep(after: ReviewCoach.verdict(context: c)))),
        ])
    }

    static func energy(_ c: AgentContext) -> GoalJourney {
        let logs = c.days.filter { $0.day > c.now.adding(days: -14) && $0.energy != nil }.count
        let bed = c.adherence("bedtime")
        let onTime = bed?.rate ?? 0
        let comparable = c.associations.filter { $0.metric == "醒后精力" && $0.sufficient }
        let clear = comparable.filter { $0.strength >= .weak }
        return path("energy", "提升日常精力", "日常精力", reached: c.profile.journeyReached["energy"] ?? 0, [
            (.init(id: "log", title: "记录精力", focus: "每天早上记下醒来时的精力，看清自己的规律。"),
             .init(met: logs >= 10, status: "近 14 天记录了 \(logs) 天", progress: min(1, Double(logs) / 10),
                   toPass: "近 14 天记满 10 天（现在 \(logs) 天）", next: "每天早上花 20 秒记下醒来的精力。")),
            (.init(id: "sleep", title: "稳定作息", focus: "先把起床和上床时间固定下来，精力的底子是睡眠。"),
             .init(met: onTime >= 0.6, status: bed?.kept.map { "近 4 周有 \($0.of) 个晚上，\($0.ok) 晚按时上床" } ?? "还没有睡眠记录",
                   progress: min(1, onTime / 0.6), toPass: "按时上床的晚上到 60%（现在 \(pct(onTime))）",
                   next: "先固定起床时间，再一点点提早上床。")),
            (.init(id: "factors", title: "找出影响因素", focus: "比较不同的日子，看哪些事让你第二天更有精神。"),
             .init(met: !comparable.isEmpty, status: comparable.isEmpty ? "可比较的记录还不够" : "已比较 \(comparable.count) 个因素",
                   toPass: "至少一个因素两边各有 4 天以上的记录可以比较",
                   next: clear.first.map { "看看「发现的关联」：\($0.sentence)" } ?? "继续记录晨起精力，也记下咖啡、饮酒和压力。")),
            (.init(id: "improve", title: "精力稳步提升", focus: "保持有效的习惯，比较起始和最近的精力。"),
             .init(met: c.dimension("energy")?.status == .improved, status: compared(c.dimension("energy")),
                   toPass: "醒后精力比起始 4 周明显提高", next: "保持让你精神更好的习惯，一次只改一件事。")),
        ])
    }

    static func fitness(_ c: AgentContext) -> GoalJourney {
        let target = c.profile.weeklyTargetMinutes
        let today = c.now.startOfDay
        let weeks = (0..<4).map { k in
            c.days.filter { $0.day >= today.adding(days: -7 * (k + 1)) && $0.day < today.adding(days: -7 * k) }.map(\.activeMinutes).reduce(0, +)
        }
        let hit = weeks.filter { $0 >= Double(target) }.count
        let hard = c.plan.filter { $0.day >= today.adding(days: -28) && $0.day < today && ($0.kind == .quality || $0.kind == .long) && $0.status == .done }.count
        let capacity = c.dimension("capacity")
        return path("fitness", "提升运动能力", "运动能力", reached: c.profile.journeyReached["fitness"] ?? 0, [
            (.init(id: "base", title: "打好有氧基础", focus: "每周达到有氧目标，先把基础量练稳，强度以轻松为主。"),
             .init(met: hit >= 3, status: "近 4 周有 \(hit) 周达到 \(target) 分钟", progress: min(1, Double(hit) / 3),
                   toPass: "4 周里有 3 周达到每周 \(target) 分钟（现在 \(hit) 周）", next: "先把每周 \(target) 分钟练稳，别急着加强度。")),
            (.init(id: "intensity", title: "加入强度训练", focus: "每周安排一次强度课或长时间有氧，循序加量。"),
             .init(met: hard >= 3, status: "近 4 周完成 \(hard) 次强度课或长时间有氧", progress: min(1, Double(hard) / 3),
                   toPass: "4 周里完成 3 次（现在 \(hard) 次）", next: "每周安排一次强度课或长时间有氧，其余保持轻松。")),
            (.init(id: "measure", title: "评估能力变化", focus: "用轻松训练时的心率或 VO₂max，比较能力有没有提升。"),
             .init(met: capacity.map { $0.status != .insufficient } ?? false, status: compared(capacity),
                   toPass: "有 6 周以上的 VO₂max 或带心率的轻松训练记录", next: "轻松训练时戴上手表记录心率，或让手表估算 VO₂max。")),
            (.init(id: "progress", title: "持续进阶", focus: "能力提升后再逐步加量，每周增加不超过 10%。"),
             .init(met: capacity?.status == .improved, status: compared(capacity),
                   toPass: "运动能力比起始 4 周明显提升", next: "保持轻松为主、每周一次强度的节奏，每 3–4 周留一周轻松些。")),
        ])
    }

    static func race(_ c: AgentContext) -> GoalJourney {
        let phases: [MarathonPhase] = [.base, .build, .peak, .taper, .raceWeek]
        let at = c.race.map { $0.phase == .recovery ? phases.count : (phases.firstIndex(of: $0.phase) ?? 0) } ?? -1
        let set: Step = (.init(id: "set", title: "设定比赛", focus: "确定比赛日期和目标成绩，计划才能按周期安排。"),
                         .init(met: c.race != nil, status: "还没有设定比赛", toPass: "填写比赛日期和目标成绩",
                               next: "在「我的 › 专业模块」开启专项运动支持，填写比赛日期。"))
        let steps: [Step] = phases.enumerated().map { i, ph in
            let w = c.race?.weeksToRace ?? 0
            let until: String? = switch ph {
            case .base: "距比赛 16 周时进入强化期"
            case .build: "距比赛 8 周时进入专项期"
            case .peak: "距比赛 2 周时进入减量期"
            case .taper: "比赛那一周"
            default: nil
            }
            return (.init(id: ph.rawValue, title: ph.label, focus: ph.focus),
                    .init(met: i < at, status: w > 0 ? "距比赛 \(w) 周" : "比赛周", toPass: until,
                          next: c.race.map { "本周跑量约 \($0.weeklyKm.noDecimal) 公里，最长一次 \($0.longRunKm.noDecimal) 公里。" } ?? ph.focus))
        }
        var journey = path("race", c.raceName.isEmpty ? "完成赛事" : c.raceName, c.raceName.isEmpty ? "赛事" : c.raceName, [set] + steps)
        if journey.isComplete {
            journey = GoalJourney(id: journey.id, title: journey.title, short: journey.short, stages: journey.stages, current: journey.current,
                                  standing: .init(met: true, status: "比赛已完成", next: MarathonPhase.recovery.focus))
        }
        return journey
    }

    static func bloodPressure(_ c: AgentContext) -> GoalJourney {
        let p = c.profile
        let bp = c.vitals.filter { $0.kind == .bloodPressure && $0.time >= c.now.adding(days: -30) }
        let days = Set(bp.map(\.time.startOfDay)).count
        let sys = Stats.mean(bp.map(\.value)), dia = Stats.mean(bp.compactMap(\.value2))
        let target = "\(p.bpTargetSys)/\(p.bpTargetDia)"
        let inTarget = sys.map { $0 <= Double(p.bpTargetSys) } == true && (dia ?? 0) <= Double(p.bpTargetDia)
        let high = (sys ?? 0) >= 135 || (dia ?? 0) >= 85
        return path("bp", "控制血压", "血压", reached: c.profile.journeyReached["bp"] ?? 0, [
            (.init(id: "measure", title: "规范测量", focus: "连续 7 天早晚各测一次家庭血压，得到可靠的平均值。"),
             .init(met: days >= 7, status: "近 30 天测了 \(days) 天", progress: min(1, Double(days) / 7),
                   toPass: "测满 7 天，每天早晚各一次（现在 \(days) 天）", next: "早上起床后、晚上睡前各测一次，每次测 2 遍取平均。")),
            (.init(id: "target", title: "达到照护目标", focus: "在医生的指导下，让家庭血压稳定在目标以内。"),
             .init(met: inTarget, status: sys.map { "近 30 天平均 \($0.noDecimal)/\((dia ?? 0).noDecimal) mmHg，目标 \(target)" } ?? "还没有血压记录",
                   toPass: "家庭血压平均在 \(target) mmHg 以内",
                   next: high ? "家庭血压平均值偏高，请带上记录和医生讨论。" : "坚持少盐、规律运动、少喝酒，复诊时带上记录。", urgent: high)),
            (.init(id: "keep", title: "保持与复测", focus: "每月复测一次 7 天家庭血压，按时复诊。"),
             .init(met: false, status: "近 30 天平均在目标以内", next: "每个月挑一周早晚测量，按时复诊。")),
        ])
    }

    static func glucose(_ c: AgentContext) -> GoalJourney {
        let g = c.glucose
        let enough = g.sufficient || (!g.isContinuous && g.readings >= 14)
        let tir = g.tir ?? 0, tbr = g.tbr ?? 0
        return path("glucose", "控制血糖", "血糖", reached: c.profile.journeyReached["glucose"] ?? 0, [
            (.init(id: "monitor", title: "规律监测", focus: "佩戴 CGM 或按医嘱测血糖，让数据足够评估。"),
             .init(met: enough, status: g.isContinuous ? "近 14 天 CGM 数据覆盖 \(pct(g.coverage))" : "近 14 天测了 \(g.readings) 次",
                   progress: min(1, g.isContinuous ? g.coverage / 0.7 : Double(g.readings) / 14),
                   toPass: g.isContinuous ? "数据覆盖到 70%（现在 \(pct(g.coverage))）" : "近 14 天测满 14 次（现在 \(g.readings) 次）",
                   next: "按医嘱佩戴 CGM 或测指尖血糖，饭前饭后都记一记。")),
            (.init(id: "range", title: "达到目标范围", focus: "和医生一起看数据，让大部分时间待在目标范围内，低血糖越少越好。"),
             .init(met: g.tir != nil && tir >= 0.7 && tbr < 0.04,
                   status: g.tir.map { "目标范围内时间 \(pct($0))，低血糖时间 \(pct(g.tbr ?? 0))" } ?? "数据还不够计算",
                   progress: g.tir.map { min(1, $0 / 0.7) }, toPass: "目标范围内时间到 70%，低血糖时间少于 4%",
                   next: tbr >= 0.04 ? "低血糖时间偏多，请尽快和医生沟通。" : "和医生一起看数据，饮食、运动、作息一起调整。", urgent: tbr >= 0.04)),
            (.init(id: "keep", title: "保持与复查", focus: "保持监测，定期复查，把数据带给医生。"),
             .init(met: false, status: "近 14 天在目标范围内", next: "继续规律监测，按时复查。")),
        ])
    }

    static func care() -> GoalJourney {
        path("care", "配合疾病照护", "疾病照护", [
            (.init(id: "setup", title: "设定照护内容", focus: "按医生的要求设定要管理的指标和目标。"),
             .init(met: false, status: "还没有开启照护模块", next: "在「我的 › 专业模块」开启心血管或血糖管理，按医生的要求设定目标。")),
        ])
    }
}
