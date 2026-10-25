import Foundation

// 复盘 in an AI-native form: the Health Agent drafts the conclusion, proposes concrete changes the
// user can adopt with one tap, and turns the weekly reflection into a short guided conversation.
// Everything here is derived from the user's records; associations stay labelled as observations.

// MARK: - Next week's plan

/// What the user said in this week's review, as far as planning is concerned.
struct ReviewNotes: Equatable {
    var keep: String = ""
    var change: String = ""
    var focus: String = ""
}

struct NextWeekPlan: Equatable {
    var weekStart: Date
    var targetMinutes: Int
    var targetReason: String
    var changes: [AgentPoint]
    var sessions: [PlannedSession]
    var basis: String
}

// MARK: - Week numbers

struct WeekSnapshot: Equatable {
    var weekStart: Date
    var span: Int
    var rhr: Double?
    var sleepHours: Double?
    var activeMinutes: Double
    var energy: Double?
    var alcohol: Double
    var stress: Double?
    var done: Int
    var total: Int
    var completion: Double?
    var missedWeekdays: [Int]
    var daysLogged: Int
}

struct BriefMetric: Identifiable, Equatable {
    enum Trend { case better, worse, flat, none }
    var id: String { name }
    let name: String
    let icon: String
    let value: String
    let unit: String
    let delta: String?
    let trend: Trend
}

struct WeeklyBrief: Equatable {
    var headline: String
    var detail: String
    var metrics: [BriefMetric]
    var watch: [AgentPoint]
    var nextWeek: String
    var story: ReviewStory? = nil
}

/// What a review summary talks about, chosen by the rules: the main thread, one bright spot, one
/// difficulty and one next step — a story, not every number. The model retells it in its own
/// words; `text` is the rules' own wording.
struct ReviewStory: Equatable {
    var main: String
    var bright: String? = nil
    var hard: String? = nil
    var next: String? = nil
    var nextLead = "下周可以先"

    var text: String {
        [main + "。", bright.map { "好的一面是，\($0)。" }, hard.map { "需要留意的是，\($0)。" },
         next.map { nextLead + $0.trimmingCharacters(in: CharacterSet(charactersIn: "。")) + "。" }]
            .compactMap { $0 }.joined()
    }

    var facts: String {
        ["【写作要点】", "主线：\(main)", bright.map { "亮点：\($0)" }, hard.map { "难点：\($0)" }, next.map { "下一步：\($0)" }]
            .compactMap { $0 }.joined(separator: "\n")
    }
}

enum CoachAction: Equatable {
    case dropWeekday(Int)
    case startExperiment(key: String, note: String)
    case setBedtime(Int)
    case setStepsTarget(Int)
    case addTask(title: String, area: CareArea, inDays: Int)
}

struct CoachProposal: Identifiable, Equatable {
    let id: String
    let icon: String
    let title: String
    let rationale: String
    let action: CoachAction
    let adoptLabel: String
}

struct ReflectionStep: Identifiable, Equatable {
    let id: String
    let question: String
    let options: [String]
    /// What the answer is used for, so it is worth giving.
    var why: String = ""
}

struct LongTermVerdict: Equatable {
    enum Kind { case early, fits, partly, adjust }
    var kind: Kind
    var title: String
    var detail: String
}

enum ReviewCoach {
    // MARK: Week snapshot

    /// Numbers for the first `span` days of the week starting at `weekStart`, so an in-progress
    /// week is compared with the same days of the previous week.
    static func week(days: [DayData], plan: [SessionSnapshot], weekStart ws: Date, span: Int,
                     source: RHRSource?, now: Date = .app) -> WeekSnapshot {
        let end = ws.adding(days: span)
        let ds = days.filter { $0.day >= ws && $0.day < end && $0.day <= now.startOfDay }
        let t = plan.filter { $0.day >= ws && $0.day < end && $0.day <= now.startOfDay && $0.kind.isTraining }
        let past = t.filter { $0.day < now.startOfDay }
        let score = t.reduce(0.0) { $0 + ($1.status == .done ? 1 : ($1.status == .partial ? 0.5 : 0)) }
        return WeekSnapshot(
            weekStart: ws, span: span,
            rhr: Stats.mean(ds.filter { source == nil || $0.rhrSource == source }.compactMap(\.rhr)),
            sleepHours: Stats.mean(ds.compactMap(\.sleepMinutes)).map { $0 / 60 },
            activeMinutes: ds.map(\.activeMinutes).reduce(0, +),
            energy: Stats.mean(ds.compactMap(\.energy).map(Double.init)),
            alcohol: ds.map(\.alcoholUnits).reduce(0, +),
            stress: Stats.mean(ds.compactMap(\.stress).map(Double.init)),
            done: t.filter { $0.status == .done }.count, total: t.count,
            completion: t.isEmpty ? nil : score / Double(t.count),
            missedWeekdays: past.filter { $0.status == .skipped || $0.status == .planned }.map { $0.day.weekday },
            daysLogged: ds.count)
    }

    // MARK: Weekly brief

    static func brief(current c: WeekSnapshot, previous p: WeekSnapshot, context: AgentContext,
                      isCurrentWeek: Bool, nextTarget: (minutes: Int, reason: String),
                      priorities: [ReviewPriority] = []) -> WeeklyBrief {
        func metric(_ name: String, _ icon: String, _ v: Double?, _ pv: Double?, unit: String, decimals: Int = 0,
                    lowerIsBetter: Bool = false, threshold: Double) -> BriefMetric {
            let fmt: (Double) -> String = { decimals == 0 ? $0.noDecimal : $0.oneDecimal }
            guard let v else { return BriefMetric(name: name, icon: icon, value: "—", unit: unit, delta: nil, trend: .none) }
            guard let pv else { return BriefMetric(name: name, icon: icon, value: fmt(v), unit: unit, delta: nil, trend: .none) }
            let d = v - pv
            if abs(d) < threshold { return BriefMetric(name: name, icon: icon, value: fmt(v), unit: unit, delta: "持平", trend: .flat) }
            let better = lowerIsBetter ? d < 0 : d > 0
            return BriefMetric(name: name, icon: icon, value: fmt(v), unit: unit, delta: (d > 0 ? "+" : "") + fmt(d), trend: better ? .better : .worse)
        }
        // Sessions read more clearly as "2/3 次" than as a percentage; the change is still the completion rate.
        let rate = metric("训练完成", "checklist", c.completion.map { $0 * 100 }, p.completion.map { $0 * 100 }, unit: "%", threshold: 10)
        let sessions = BriefMetric(name: rate.name, icon: rate.icon, value: c.total > 0 ? "\(c.done)/\(c.total)" : "—", unit: "次",
                                   delta: c.total > 0 ? rate.delta.map { $0 == "持平" ? $0 : $0 + "%" } : nil, trend: c.total > 0 ? rate.trend : .none)
        let metrics = [
            metric("静息心率", "heart.fill", c.rhr, p.rhr, unit: "bpm", lowerIsBetter: true, threshold: 1),
            metric("平均睡眠", "bed.double.fill", c.sleepHours, p.sleepHours, unit: "小时", decimals: 1, threshold: 0.2),
            metric("活动", "figure.walk", c.activeMinutes, p.activeMinutes, unit: "分钟", threshold: max(15, p.activeMinutes * 0.1)),
            sessions,
            metric("醒后精力", "bolt.fill", c.energy, p.energy, unit: "/ 5", decimals: 1, threshold: 0.2),
            metric("饮酒", "wineglass", c.alcohol, p.alcohol, unit: "单位", decimals: 1, lowerIsBetter: true, threshold: 0.5),
        ] + ReviewPriorities.weekMetrics(context, areas: priorities.prefix(3).map(\.area), weekStart: c.weekStart, span: c.span)
        // What the user cares about most is told first.
        let first = priorities.compactMap(\.area.metricName)
        func byPriority(_ ms: [BriefMetric]) -> [BriefMetric] {
            ms.enumerated().sorted { a, b in
                (first.firstIndex(of: a.element.name) ?? first.count, a.offset) < (first.firstIndex(of: b.element.name) ?? first.count, b.offset)
            }.map(\.element)
        }
        let better = byPriority(metrics.filter { $0.trend == .better }), worse = byPriority(metrics.filter { $0.trend == .worse })
        let headline: String
        let behind = c.total >= 2 && (c.completion ?? 1) < 0.5
        if isCurrentWeek && c.span <= 2 {
            headline = "这周刚开始，先看看前 \(c.span) 天"
        } else if behind {
            // Training that has not happened outweighs good numbers elsewhere.
            headline = better.isEmpty ? "这周的训练还没跟上节奏"
                : "训练还没跟上，不过\(better.prefix(2).map(\.name).joined(separator: "、"))比上周好"
        } else if better.count >= 3 {
            headline = "这周在变好，\(better.prefix(2).map(\.name).joined(separator: "、"))都比上周好"
        } else if worse.count >= 2 && worse.count > better.count {
            headline = "这周\(worse.prefix(2).map(\.name).joined(separator: "、"))不如上周，下周一起调整"
        } else if let b = better.first {
            headline = "这周\(b.name)有进步，其他和上周差不多"
        } else {
            headline = "这周整体平稳，和上周差不多"
        }
        // The summary tells one story — what the week was about, a bright spot, a difficulty — not every number.
        let missed = Array(Set(c.missedWeekdays)).sorted { PlanGenerator.order($0) < PlanGenerator.order($1) }.map(Weekday.name)
        var used: Set<String> = []
        let main: String
        if isCurrentWeek && c.span <= 2 {
            main = "这周才过了 \(c.span) 天，还看不出趋势"
        } else if behind {
            main = "这周的训练还没跟上节奏，" + (missed.isEmpty ? "只完成了 \(c.done)/\(c.total) 次"
                : "\(missed.joined(separator: "、"))的训练\(missed.count > 1 ? "都" : "")没练成")
            used.insert(sessions.name)
        } else if better.count >= 3 {
            main = "这周状态在变好，\(better.prefix(2).map(\.name).joined(separator: "、"))都比上周好"
            used.formUnion(better.prefix(2).map(\.name))
        } else if worse.count >= 2 && worse.count > better.count {
            main = "这周\(worse.prefix(2).map(\.name).joined(separator: "、"))都不如上周"
            used.formUnion(worse.prefix(2).map(\.name))
        } else if let b = better.first {
            // Said with its direction: a model turns "静息心率有进步" into "有了提升", which reads as higher.
            let line = phrase(b)
            main = (line.hasPrefix("你") ? line : "这周" + line) + "，其他和上周差不多"
            used.insert(b.name)
        } else {
            main = "这周整体平稳，和上周差不多"
        }
        let bright = better.first { !used.contains($0.name) }.map { phrase($0) }
        // The most actionable difficulty first; resting heart rate joins it as a second one.
        let order = first + ["平均睡眠", "活动", "饮酒", "静息心率", "醒后精力", "训练完成"]
        let hardOnes = worse.filter { !used.contains($0.name) }.sorted { order.firstIndex(of: $0.name) ?? 9 < order.firstIndex(of: $1.name) ?? 9 }
        var hard = hardOnes.prefix(2).enumerated().map { phrase($0.element, also: $0.offset > 0) }.joined(separator: "，")
        if hard.isEmpty {
            if c.alcohol > context.profile.weeklyAlcoholLimit { hard = "这周饮酒 \(c.alcohol.oneDecimal) 单位，超过了每周上限" }
            else if let s = c.sleepHours, s < context.profile.sleepNeedMinutes / 60 - 0.5 { hard = "睡得偏少，平均每晚 \(s.oneDecimal) 小时" }
        }
        let story = ReviewStory(main: main, bright: bright, hard: hard.isEmpty ? nil : hard)
        let watch = HealthAgent.assess(context).watch.filter { $0.destination != .recovery || c.alcohol > 0 }
        return WeeklyBrief(headline: headline, detail: story.text,
                           metrics: priorities.isEmpty ? metrics : ReviewPriorities.ordered(metrics, by: priorities), watch: Array(watch.prefix(3)),
                           nextWeek: nextWeekLine(current: context.profile.weeklyTargetMinutes, next: nextTarget.minutes, completion: c.completion, isCurrentWeek: isCurrentWeek),
                           story: story)
    }

    /// A metric's change, said the way a coach would say it: one number at most, none when it is
    /// the second thing mentioned (`also`).
    static func phrase(_ m: BriefMetric, also: Bool = false) -> String {
        let d = (m.delta ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "+-%"))
        let up = m.trend == .better
        let some = also ? "一些" : ""
        let (who, what): (String, String) = switch m.name {
        case "静息心率": ("静息心率", "比上周\(up ? "低" : "高")了" + (also ? some : " \(d) bpm"))
        case "平均睡眠" where !up && !also: ("睡得", "比上周少，平均每晚 \(m.value) 小时")
        case "平均睡眠": ("睡眠", "比上周\(up ? "多" : "少")了" + (also ? some : " \(d) 小时"))
        case "活动": ("活动", "比上周\(up ? "多" : "少")了" + (also ? some : " \(d) 分钟"))
        case "训练完成": ("训练", up ? "完成得比上周好" : (also ? "完成得不如上周" : "只完成了 \(m.value) 次"))
        case "醒后精力": ("醒来时的精神", up ? "比上周好" : "不如上周")
        case "饮酒" where up && (Double(m.value) ?? 1) == 0: ("你这周", "一点酒都没喝")
        case "饮酒": ("饮酒", "比上周\(up ? "少" : "多")了" + (also ? some : " \(d) 单位"))
        default: (m.name, up ? "比上周好" : "不如上周")
        }
        return who + (also ? "也" : "") + what
    }

    /// The first proposal, as the next step a summary ends on.
    static func nextStep(_ p: CoachProposal) -> String {
        switch p.action {
        case .dropWeekday(let wd): "把\(Weekday.name(wd))换成日常活动，把力气留给能完成的训练"
        // An association still to be tested is not said as an effect.
        case .startExperiment: p.title.replacingOccurrences(of: "验证", with: "看看").replacingOccurrences(of: "对你的影响", with: "是不是真的会影响你")
        case .setBedtime(let t): "把上床时间定在 \(Clock.text(t))，做到了再往前挪"
        case .setStepsTarget(let n): "把每日步数目标调到 \(n) 步"
        case .addTask(let title, _, _): "把「\(title)」加进待办"
        }
    }

    /// How next week's aerobic target follows from this week's completion (it adjusts automatically).
    static func nextWeekLine(current: Int, next: Int, completion: Double?, isCurrentWeek: Bool) -> String {
        guard let c = completion else { return "下周有氧目标先保持 \(current) 分钟。" }
        let done = "这周的有氧\(isCurrentWeek ? "到目前" : "")完成了 \(Int(c * 100))%"
        if next > current { return "\(done)，下周可以稍微增加到 \(next) 分钟。" }
        if next < current { return "\(done)，下周先降到 \(next) 分钟，把节奏找回来。" }
        return "\(done)，下周先保持 \(current) 分钟。"
    }

    // MARK: Proposals

    /// Concrete, one-tap changes. `handledInsights` are association keys already being tested or
    /// decided; `taskTitles` are open care tasks (to avoid duplicates).
    /// The week's suggestions, in the order of the user's priorities (the rules' order without any).
    static func proposals(context c: AgentContext, handledInsights: Set<String>, taskTitles: [String],
                          priorities: [ReviewPriority] = []) -> [CoachProposal] {
        let all = candidates(context: c, handledInsights: handledInsights, taskTitles: taskTitles)
            + ReviewPriorities.proposals(c, priorities: priorities, taskTitles: taskTitles)
        return ReviewPriorities.rank(all, by: priorities)
    }

    private static func candidates(context c: AgentContext, handledInsights: Set<String>, taskTitles: [String]) -> [CoachProposal] {
        var out: [CoachProposal] = []
        let p = c.profile

        // 1. A training day that repeatedly does not happen.
        if let w = InsightEngine.missedWeekdays(plan: c.plan, now: c.now).first(where: { p.availableWeekdays.contains($0.weekday) }),
           p.availableWeekdays.count > 2 {
            let (wd, missed, total) = w
            out.append(CoachProposal(id: "drop-\(wd)", icon: "calendar.badge.minus",
                                     title: "把\(Weekday.name(wd))从训练日中移出",
                                     rationale: "最近 6 周的\(Weekday.name(wd))，\(total) 次训练有 \(missed) 次没练成。不如这天先换成日常活动，其他训练日照旧。",
                                     action: .dropWeekday(wd), adoptLabel: "移出\(Weekday.name(wd))"))
        }

        // 2. A personal experiment for the clearest unfavourable association.
        // (key, name, experiment note, when it happens and what to try — as one would say them)
        let experiments: [(String, String, String, String, String)] = [
            ("alcohol-rhr", "饮酒", "两周内不饮酒，观察次日静息心率与睡眠", "喝过酒的第二天早上", "两周不喝酒"),
            ("caffeine-sleep", "午后咖啡因", "两周内午后不摄入咖啡因，观察睡眠时长", "下午喝了咖啡的那天晚上", "两周下午不喝咖啡"),
            ("latemeal-rhr", "晚餐过晚", "两周内晚餐在睡前 3 小时完成，观察次日静息心率", "晚饭吃得晚的第二天早上", "两周晚饭在睡前 3 小时吃完"),
            ("stress-rhr", "压力", "两周内每天睡前做 5 分钟慢呼吸，观察次日静息心率", "压力大的第二天早上", "两周每天睡前做 5 分钟慢呼吸"),
        ]
        if let e = experiments.first(where: { e in
            !handledInsights.contains(e.0) && (c.association(e.0).map { $0.unfavorable && $0.strength >= .moderate } ?? false)
        }), let a = c.association(e.0) {
            let (key, name, note, when, trial) = e
            let value = a.unit == "分" ? String(format: "%.1f", abs(a.diff)) : abs(a.diff).oneDecimal
            let more = a.metric == "睡眠时长" ? (a.diff > 0 ? "多" : "少") : (a.diff > 0 ? "高" : "低")
            out.append(CoachProposal(id: "exp-\(key)", icon: "flask",
                                     title: "用 2 周验证「\(name)」对你的影响",
                                     rationale: "\(when)，你的\(a.metric)平均\(more) \(value) \(a.unit)。目前只是记录里看到的关联，\(trial)试试，就知道对你是不是真的有影响。",
                                     action: .startExperiment(key: key, note: note), adoptLabel: "开始验证"))
        }

        // 3. A bedtime target that is rarely met → a realistic one first.
        if let h = c.adherence("bedtime"), h.verdict == .struggling || h.verdict == .partial,
           let avg = c.sleep.avgBedtime, Clock.nightOffset(avg) - Clock.nightOffset(p.bedtimeMinutes) >= 30 {
            let target = (p.bedtimeMinutes + min(45, Clock.nightOffset(avg) - Clock.nightOffset(p.bedtimeMinutes)) / 15 * 15) % 1440
            out.append(CoachProposal(id: "bed-\(target)", icon: "moon.stars.fill",
                                     title: "把目标上床时间调整为 \(Clock.text(target))",
                                     rationale: (h.kept.map { "最近 \($0.of) 个晚上，只有 \($0.ok) 晚在 \(Clock.text(p.bedtimeMinutes)) 前后睡下。" } ?? "按时上床的晚上还不多。")
                                         + "先定一个够得着的时间，做到了再每周提前 15 分钟。",
                                     action: .setBedtime(target), adoptLabel: "调整为 \(Clock.text(target))"))
        }

        // 4. A step target that is rarely reached.
        if let h = c.adherence("steps"), (h.rate ?? 1) < 0.4 {
            let recent = Stats.mean(c.days.suffix(28).compactMap(\.steps).map(Double.init)) ?? Double(p.stepsTarget)
            let target = max(4000, Int((recent + 1000) / 500) * 500)
            if target < p.stepsTarget {
                out.append(CoachProposal(id: "steps-\(target)", icon: "figure.walk",
                                         title: "每日步数目标调整为 \(target)",
                                         rationale: (h.kept.map { "最近 \($0.of) 天只有 \($0.ok) 天走到 \(p.stepsTarget) 步。" } ?? "步数目标最近很少达到。")
                                             + "先调到 \(target) 步，比平时多走一点就够，更容易天天做到。",
                                         action: .setStepsTarget(target), adoptLabel: "调整目标"))
            }
        }

        // 5. Care follow-ups that are not yet on the list.
        if c.needsSleepEvaluation && !taskTitles.contains(where: { $0.contains("睡眠") }) {
            out.append(CoachProposal(id: "task-sleep", icon: "stethoscope", title: "添加睡眠门诊评估事项",
                                     rationale: "最近 30 天有 \(c.breathing.snoring) 晚打鼾\(c.stopBangScore.map { "，STOP-BANG \($0)/8" } ?? "")。是不是睡眠呼吸暂停，要做一次专业的睡眠监测才知道。",
                                     action: .addTask(title: "睡眠门诊评估", area: .sleep, inDays: 14), adoptLabel: "添加事项"))
        }
        if let avg = c.homeBP.overallAvg, c.homeBP.progress >= 0.5, avg.sys >= 135 || avg.dia >= 85,
           !taskTitles.contains(where: { $0.contains("血压") }) {
            out.append(CoachProposal(id: "task-bp", icon: "heart.text.square.fill", title: "带上家庭血压记录咨询医生",
                                     rationale: "这 7 天在家量的血压平均 \(Int(avg.sys))/\(Int(avg.dia)) mmHg，已经到了 135/85 的参考线，值得带着记录去问问医生。",
                                     action: .addTask(title: "就家庭血压咨询医生", area: .cardio, inDays: 14), adoptLabel: "添加事项"))
        }
        return out
    }



    // MARK: Guided reflection

    static func reflection(context c: AgentContext, week w: WeekSnapshot, priorities: [ReviewPriority] = []) -> [ReflectionStep] {
        let friendly: [String: String] = ["plan": "按计划运动", "bedtime": "按时上床", "sleepdur": "睡够时长", "alcohol": "控制饮酒",
                                          "caffeine": "下午不喝咖啡", "steps": "日常多走路", "checkin": "晨起记录"]
        var keep = c.adherence.filter { $0.verdict == .sustained }.compactMap { friendly[$0.id] }
        if w.alcohol == 0 { keep.append("这周没喝酒") }
        if let s = w.sleepHours, s >= c.profile.sleepNeedMinutes / 60 - 0.3 { keep.append("睡得比较够") }
        if w.done > 0 { keep.append("练完了 \(w.done) 次训练") }
        // Then the habits that came closest, so there is always something to pick.
        keep += c.adherence.filter { $0.verdict == .partial }.compactMap { friendly[$0.id] }
        keep += ["日常多走路", "规律作息"]
        // 「这周没喝酒」 already says it.
        if w.alcohol == 0 { keep.removeAll { $0 == friendly["alcohol"] } }

        var hard: [String] = Array(Set(w.missedWeekdays)).sorted { PlanGenerator.order($0) < PlanGenerator.order($1) }.map { "\(Weekday.name($0))的训练" }
        hard += c.adherence.filter { $0.verdict == .struggling }.compactMap { friendly[$0.id] }
        if w.alcohol > 0 { hard.append("饮酒") }
        if (w.stress ?? 0) >= 3.5 { hard.append("压力大") }
        hard += ["工作太忙", "睡得太晚"]

        // The user's top priorities are the first answers offered.
        var focus = priorities.prefix(2).map(\.area.focusOption) + HealthAgent.assess(c).nextSteps.map(\.title)
        focus.append("保持现在的节奏")

        func unique(_ xs: [String]) -> [String] { xs.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } } }
        return [
            ReflectionStep(id: "keep", question: "这周哪些事最容易坚持？", options: Array(unique(keep).prefix(5)),
                           why: "下周会保留这些安排。"),
            ReflectionStep(id: "change", question: "哪些安排比较难坚持？", options: Array(unique(hard).prefix(5)),
                           why: "提到的日子下周会先不排训练；选「工作太忙」，单次训练会缩短。"),
            ReflectionStep(id: "focus", question: "下周最想做好的一件事？", options: Array(unique(focus).prefix(4)),
                           why: "下周计划会围绕它来安排。"),
        ]
    }

    /// Turns the guided answers into the saved review fields.
    static func draft(brief: WeeklyBrief, answers: [String: [String]], note: String) -> (summary: String, keep: String, change: String, focus: String) {
        let n = note.trimmingCharacters(in: .whitespacesAndNewlines)
        func list(_ id: String) -> String { (answers[id] ?? []).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: "、") }
        return (brief.headline + "。" + (n.isEmpty ? "" : n), list("keep"), list("change"), list("focus"))
    }

    // MARK: Long-term

    static func verdict(context c: AgentContext) -> LongTermVerdict {
        let r = c.progress
        let improved = r.dimensions.filter { $0.status == .improved }
        let rhr = c.dimension("rhr")
        if r.spanDays < 42 {
            return LongTermVerdict(kind: .early, title: "还在积累：已记录 \(r.spanDays) 天",
                                   detail: "约 6 周后，可以比较起始与当前的多个维度，判断管理方向是否适合你。")
        }
        if rhr?.status == .improved {
            return LongTermVerdict(kind: .fits, title: "现在的方向适合你，继续保持",
                                   detail: "静息心率 \(rhr?.from ?? "") → \(rhr?.to ?? "")\(improved.count > 1 ? "，另外 \(improved.count - 1) 个维度也在改善" : "")。保持当前组合，避免同时做太多改变。")
        }
        if !improved.isEmpty {
            return LongTermVerdict(kind: .partly, title: "方向基本合适，静息心率需要更多时间",
                                   detail: "\(improved.map(\.name).joined(separator: "、"))在改善。静息心率通常滞后于习惯变化 4–8 周以上。")
        }
        return LongTermVerdict(kind: .adjust, title: "现在的计划需要调一调",
                               detail: "各维度变化不明显。先回看哪些安排难以坚持，把计划调整得更可持续。")
    }

    /// What to do once the long-term picture is in, following the verdict (the last stage of 改善静息心率).
    static func nextStep(after v: LongTermVerdict) -> String {
        switch v.kind {
        case .adjust: "先按下面「下一阶段」的建议调整，4 周后再看变化。"
        case .partly: "保持现在的方向，给静息心率多一点时间，4 周后再看。"
        case .fits: "保持现在的组合，一次只改一件事，4 周后再复盘。"
        case .early: "继续记录，约 6 周后就能比较起始和最近的变化。"
        }
    }

    /// The long-term summary's story: the verdict as the main thread, one dimension or habit that
    /// went well, one that needs attention, and the page's one next step — taken from 所处阶段 (see
    /// `GoalJourneys.nextStep`), which no longer says it itself.
    static func story(context c: AgentContext, verdict v: LongTermVerdict) -> ReviewStory {
        let dims = c.progress.dimensions.filter { change($0) != nil }
        var used: Set<String> = []
        let main: String
        switch v.kind {
        case .early:
            main = "才记录了 \(c.progress.spanDays) 天，还需要一些时间才能看出方向"
        case .fits:
            if let r = dims.first(where: { $0.id == "rhr" }), let line = change(r) {
                main = line + "，现在的方向适合你"
                used.insert(r.id)
            } else {
                main = "静息心率在改善，现在的方向适合你"
            }
        case .partly:
            let up = dims.filter { $0.status == .improved }
            main = "\(up.map(\.name).joined(separator: "、"))在改善，静息心率还需要更多时间"
            used.formUnion(up.map(\.id))
        case .adjust:
            main = "这段时间各方面的变化还不明显" + (c.adherence("plan")?.verdict == .struggling ? "，计划也不太容易坚持" : "")
        }
        let bright = dims.first { $0.status == .improved && !used.contains($0.id) }.flatMap(change)
            ?? c.adherence.filter { $0.verdict == .sustained }.max { ($0.rate ?? 0) < ($1.rate ?? 0) }.map { "「\($0.name)」一直坚持得不错" }
            ?? (c.progress.spanDays >= 42 ? "你已经坚持记录了 \(c.progress.spanDays) 天" : nil)
        let hard = dims.first { $0.status == .needsWork && !used.contains($0.id) }.flatMap(change)
            ?? c.planFit.first.map { $0.title.replacingOccurrences(of: "未完成", with: "没练成") }
        return ReviewStory(main: main, bright: bright, hard: hard, next: GoalJourneys.nextStep(c), nextLead: "接下来，")
    }

    /// A dimension's change from the first to the latest weeks, said plainly
    /// ("每周的活动从 75 分钟降到了 44 分钟"); nil until both ends are known.
    static func change(_ d: ProgressDimension) -> String? {
        guard let x = d.from.flatMap({ ReviewCopy.numbers(in: $0).first }), let y = d.to.flatMap({ ReviewCopy.numbers(in: $0).first }),
              let a = Double(x), let b = Double(y) else { return nil }
        let verb = b > a ? "升到了" : (b < a ? "降到了" : "保持在")
        return switch d.id {
        case "rhr": "静息心率从 \(x) \(verb) \(y) bpm"
        case "activity": "每周的活动从 \(x) 分钟\(verb) \(y) 分钟"
        // Sleep can improve through longer nights while bedtimes still vary as much.
        case "sleep" where d.status == .improved && b >= a: "睡眠时长比开始时更长了"
        case "sleep": "入睡时间的波动从 ±\(x) 分钟\(b > a ? "扩大到了" : (b < a ? "缩小到了" : "保持在")) ±\(y) 分钟"
        case "energy": "醒后精力评分从 \(x) \(verb) \(y)"
        case "capacity" where d.from?.hasPrefix("VO₂max") == true: "VO₂max 从 \(x) \(verb) \(y)"
        case "capacity": "同样轻松的训练里，心率从 \(x) \(verb) \(y) bpm"
        default: "\(d.name)从 \(x) \(verb) \(y)"
        }
    }

    /// Next-stage strategy for the long-term review.
    static func strategy(context c: AgentContext) -> [AgentPoint] {
        var out: [AgentPoint] = []
        let dim = Dictionary(uniqueKeysWithValues: c.progress.dimensions.map { ($0.id, $0.status) })
        if dim["activity"] == .improved && dim["rhr"] != .improved {
            out.append(.init(icon: "figure.walk", title: "保持活动量，再给身体 4–8 周", detail: "活动已经比以前规律了，静息心率一般要晚几周才跟上，别着急。", destination: .plan))
        }
        if dim["activity"] == .needsWork || c.adherence("plan")?.verdict == .struggling {
            out.append(.init(icon: "calendar", title: "先让计划更容易坚持", detail: "每次练短一点，或者少排一天，先保证每周都能练上。", destination: .plan))
        }
        if dim["sleep"] == .needsWork || c.adherence("bedtime")?.verdict == .struggling {
            out.append(.init(icon: "moon.stars.fill", title: "把作息作为下一阶段的重点", detail: "先把起床时间固定下来，再一点点提早上床。", destination: .sleep))
        }
        if let a = c.association("alcohol-rhr"), a.strength >= .moderate, a.unfavorable {
            out.append(.init(icon: "wineglass", title: "看看饮酒是不是真的影响你", detail: "喝过酒的第二天早上，静息心率平均高 \(a.diff.oneDecimal) bpm。两周不喝酒试试，就知道对你是不是真的有影响。", destination: .recovery))
        }
        if let fit = c.planFit.first {
            out.append(.init(icon: "arrow.triangle.2.circlepath", title: "调整经常完成不了的安排", detail: fit.detail, destination: .plan))
        }
        if dim["rhr"] == .improved {
            out.append(.init(icon: "heart.fill", title: "保持当前组合", detail: "静息心率在往好的方向走，接下来一次只改一件事，才看得出是什么在起作用。", destination: .heart))
        }
        if c.marathonActive {
            out.append(.init(icon: "flag.checkered", title: "按阶段推进专项目标", detail: "每周加量别超过 10% 左右，每 3–4 周留一周轻松些。", destination: .marathon))
        }
        if out.isEmpty { out.append(.init(icon: "checkmark.circle", title: "继续当前的管理方式", detail: "保持现在的节奏，下个月我们再一起看看。", destination: nil)) }
        return Array(out.prefix(4))
    }

    // MARK: Next week from this week's review

    /// Builds next week's plan from this week's completion, load and recovery signals and what the
    /// user wrote in the review. Changes apply to next week only; profile settings stay as they are.
    static func nextWeekPlan(context c: AgentContext, week w: WeekSnapshot, notes: ReviewNotes?) -> NextWeekPlan {
        let p = c.profile
        // The week after the one being reviewed (until 5 am on Monday that is the week just begun).
        let nextWs = c.weekStart.adding(days: 7)
        var changes: [AgentPoint] = []
        var basis: [String] = []
        if w.total > 0 { basis.append("这周完成 \(w.done)/\(w.total) 次训练") }
        if let n = notes, !n.change.isEmpty { basis.append("复盘：\(n.change)难坚持") }

        // 1. Volume: progress from completion, but hold when recovery or load says so.
        var (target, reason) = PlanGenerator.nextWeeklyTarget(current: p.weeklyTargetMinutes, lastWeekCompletion: w.completion, profile: p)
        var hold: String? = nil
        if c.load.zone == .high || c.load.zone == .caution { hold = "这周训练量涨得有点快" }
        if case .rise = c.trend.sustained { hold = "静息心率最近一直偏高" }
        if c.readiness.level == .rest { hold = "身体今天需要休息" }
        if let h = hold, target > p.weeklyTargetMinutes {
            target = p.weeklyTargetMinutes
            reason = "\(h)，下周有氧目标保持不变。"
        }
        let delta = target - p.weeklyTargetMinutes
        // A target that stays the same is not a change — unless it is held back on purpose.
        if delta != 0 || hold != nil {
            changes.append(AgentPoint(icon: delta > 0 ? "arrow.up.right.circle" : (delta < 0 ? "arrow.down.right.circle" : "equal.circle"),
                                      title: delta == 0 ? "有氧目标保持 \(target) 分钟" : "有氧目标 \(p.weeklyTargetMinutes) → \(target) 分钟",
                                      detail: hold.map { "\($0)，下周先不加量，稳一稳。" }
                                          ?? nextWeekLine(current: p.weeklyTargetMinutes, next: target, completion: w.completion, isCurrentWeek: true)))
        }

        // 2. A training day that did not happen this week and is mentioned in the review (or keeps failing).
        var days = p.availableWeekdays
        let mentioned = (notes?.change ?? "")
        let candidates = Array(Set(w.missedWeekdays)).sorted { PlanGenerator.order($0) < PlanGenerator.order($1) }
        // Otherwise the same day the weekly proposal names.
        let hardest = InsightEngine.missedWeekdays(plan: c.plan, now: c.now).first { days.contains($0.weekday) }?.weekday
        if let wd = (candidates.first { mentioned.contains(Weekday.name($0)) } ?? hardest),
           days.contains(wd), days.count > 2 {
            days.removeAll { $0 == wd }
            changes.append(AgentPoint(icon: "calendar.badge.minus", title: "\(Weekday.name(wd))改为日常活动日",
                                      detail: mentioned.contains(Weekday.name(wd)) ? "你在复盘里说\(Weekday.name(wd))很难坚持，下周这天就先不排训练。"
                                          : "最近 6 周\(Weekday.name(wd))常常练不成，下周这天先换成日常活动。"))
        }

        // 3. Shorter sessions when time is the obstacle or sessions are often cut short.
        var session = p.sessionMinutes
        let busy = mentioned.contains("忙") || (notes?.focus ?? "").contains("更容易完成")
            || c.adherence("plan").map { $0.verdict == .struggling || $0.verdict == .partial } == true
            || c.planFit.contains { $0.title.contains("时长") }
        if busy && session > 25 {
            session = max(20, Int((Double(session) * 0.85 / 5).rounded()) * 5)
            changes.append(AgentPoint(icon: "timer", title: "单次训练缩短到 \(session) 分钟以内",
                                      detail: "每次练短一点、多练几次，忙的时候也更容易挤出时间。"))
        }

        // 4. Recovery focus carried over from the review.
        let focus = notes?.focus ?? ""
        if focus.contains("上床") || focus.contains("睡") {
            changes.append(AgentPoint(icon: "moon.stars.fill", title: "配合下周的睡眠重点",
                                      detail: "晚上的训练尽量在睡前 3 小时练完，强度大的课别排在晚上。"))
        }
        if c.marathonActive, let race = c.race, race.weeksToRace > 0 {
            let next = MarathonPlanner.phase(weeksToRace: race.weeksToRace - 1)
            changes.append(AgentPoint(icon: "flag.checkered", title: "专项：\(next.label)", detail: next.focus))
        }

        var q = p
        q.weeklyTargetMinutes = target
        q.availableWeekdays = days
        q.sessionMinutes = session
        let plan = PlanGenerator.generate(profile: q, weekStart: nextWs)
        return NextWeekPlan(weekStart: nextWs, targetMinutes: target, targetReason: reason, changes: changes,
                            sessions: plan.sessions, basis: basis.isEmpty ? "依据：这周的记录" : "依据：" + basis.joined(separator: " · "))
    }

    /// The question to ask the agent about a progress dimension.
    static func question(for dimension: ProgressDimension) -> String {
        switch dimension.id {
        case "rhr": "静息心率的长期变化说明了什么？"
        case "activity": "这几周的运动完成得怎么样？"
        case "sleep": "我的睡眠怎么样？"
        case "energy": "我最近整体怎么样？"
        default: "怎样安排运动更有效？"
        }
    }
}
