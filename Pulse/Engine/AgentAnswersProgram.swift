import Foundation

// 三阶段计划 questions for the Health Agent (Docs 8): 「我现在第几周」「这周方案完成得怎么样」「我的排名为什么
// 靠后」. Every number comes from the program's own rules; the answers are shown as written.

/// The 三阶段计划 as the agent sees it, filled by the screen that builds the context.
struct AgentProgram: Equatable {
    var phase: ProgramPhase
    var pack: ProgramPack?
    var goal: TargetGoal?
    var round = 0
    var roundStart: Date?
    var weeks = 4
    var baselineStart: Date?
    /// The frozen baseline report and its possible causes (改善期 and 总结期).
    var report: BaselineReport?
    var concerns: [Concern] = []
}

extension HealthAgent {
    static let programQuestions = ["我现在第几周？", "这周方案完成得怎么样？", "我的排名为什么靠后？"]

    static func program(_ c: AgentContext, question q: String) -> AgentReply {
        guard let x = c.program, x.phase != .none else {
            let text = "你还没有开始三阶段健康计划。可以在「计划」里开始基线评估：先照常记录一周，生成健康画像和同龄排名，再按结果选一个改善方案。"
            return AgentReply(text: text, sources: ["三阶段计划"], followUps: ["今天适合运动吗？"], destination: .plan,
                              intent: .program, conclusion: text, verbatim: true)
        }
        let r: AgentReply
        if ["排名", "靠后", "落后", "垫底", "比同龄"].contains(where: q.contains) { r = ranks(c, x) }
        else if x.phase == .improve, ["完成", "做得", "做到", "怎么样"].contains(where: q.contains) { r = weekProgress(c, x) }
        else { r = whereNow(c, x) }
        var out = r
        out.followUps = programQuestions.filter { $0 != asked(q) }
        return out
    }

    /// The canned question this one is closest to, so it isn't offered again.
    private static func asked(_ q: String) -> String {
        if ["排名", "靠后", "落后"].contains(where: q.contains) { return programQuestions[2] }
        if ["完成", "做得", "做到"].contains(where: q.contains) { return programQuestions[1] }
        return programQuestions[0]
    }

    /// Where the user is: the baseline days and what is missing, the week of the round with the main target,
    /// or 总结期.
    static func whereNow(_ c: AgentContext, _ x: AgentProgram) -> AgentReply {
        let today = DayClock.logicalToday(c.now, c.profile)
        var lines: [String] = []
        switch x.phase {
        case .baseline:
            let start = min(x.baselineStart ?? today, today)
            let days = today.daysSince(start)
            let r = BaselineAssessment.assess(baselineInput(c, window: DateInterval(start: start, end: max(start, today))))
            let ready = (days >= 7 && r.completeness.isReady) || days >= 14
            let todo = r.completeness.stillToDo(daysLeft: max(0, 7 - days))
            lines.append("你在基线期第 \(min(days + 1, 7))/7 天。")
            if ready { lines.append("数据已经够了，可以在「计划」里查看基线报告，再选一个改善方案。") }
            else if !todo.isEmpty { lines.append("还差：" + todo.map { "\($0.label)（\($0.hint)）" }.joined(separator: "；") + "。") }
            else { lines.append("照常生活就好，满 7 天就能生成基线报告。") }
            lines.append("这一周保持平时的运动和作息，不用刻意多练，否则基线不准。")
        case .improve:
            let week = x.roundStart.map { s in today.daysSince(s) < 0 ? 0 : today.daysSince(s) / 7 + 1 } ?? 0
            let pack = x.pack?.title ?? "改善方案"
            lines.append(week == 0 ? "「\(pack)」第 \(x.round) 轮下周一开始。" : "你在「\(pack)」第 \(x.round) 轮第 \(min(week, x.weeks))/\(x.weeks) 周。")
            if x.weeks > 4 { lines.append("有生病或出差的周不计入，这一轮顺延到 \(x.weeks) 周。") }
            if let line = targetLine(c, x) { lines.append(line) }
        case .summary:
            lines.append("「\(x.pack?.title ?? "改善方案")」达到了目标，现在是总结期：保持基础习惯，每周 2–3 次核心训练，强度不变，不再加量。")
            if let line = targetLine(c, x) { lines.append(line) }
            lines.append("3 个月后可以复评一次：重新记录一周，和基线报告对比。")
        case .none:
            break
        }
        return AgentReply(text: lines.joined(separator: "\n"), sources: ["三阶段计划"], destination: .plan, intent: .program,
                          conclusion: lines.first, verbatim: true)
    }

    /// 「主靶点血压：现在 138，基线 143，目标 ≤ 138」.
    static func targetLine(_ c: AgentContext, _ x: AgentProgram) -> String? {
        guard let g = x.goal else { return nil }
        let t = g.target
        let r = TargetTracker.reading(t, days: c.days, vitals: c.vitals, workouts: c.workouts,
                                      end: DayClock.logicalToday(c.now, c.profile).adding(days: 1), profile: c.profile)
        let now = r.value == nil ? "还没有读数" : r.valueText + (t == .weeklyRunKm ? "%" : "")
        var parts = ["现在 \(now)"]
        if let b = g.baseline { parts.append("基线 \(TargetTracker.text(t, b))") }
        if let goal = g.goal { parts.append("目标 \(t.higherIsBetter ? "≥" : "≤") \(TargetTracker.text(t, goal))\(t == .weeklyRunKm ? "%" : "")") }
        return "主靶点\(t.title)：" + parts.joined(separator: "，") + "。"
    }

    /// This week of the round: each behaviour goal with its numbers, the main target against its noise, next week.
    static func weekProgress(_ c: AgentContext, _ x: AgentProgram) -> AgentReply {
        guard let program = c.profile.program else { return whereNow(c, x) }
        let input = ProgramEvaluator.Input(program: program, profile: c.profile, days: c.days, workouts: c.workouts, vitals: c.vitals,
                                           plan: c.plan, baseline: x.goal?.baseline, goal: x.goal?.goal)
        let w = ProgramEvaluator.week(input, weekStart: c.now.weekStart, now: c.now)
        let first = w.excused ? "这周有生病或出差的日子，不计入判定。" : w.met ? "这周的方案目前做到了。" : "这周的方案还差一些。"
        let checks = w.checks.map { "• \($0.title)：\($0.detail)\($0.met ? "" : "（还差）")" }.joined(separator: "\n")
        let text = [first, "第 \(min(w.week, w.weeks))/\(w.weeks) 周：\n" + checks, w.targetLine, "下周：" + w.next].joined(separator: "\n")
        return AgentReply(text: text, sources: ["三阶段计划", "本周记录"], destination: .plan, intent: .program, conclusion: first, verbatim: true)
    }

    /// The ranks in the bottom half of peers, each with its possible causes as the report gives them.
    static func ranks(_ c: AgentContext, _ x: AgentProgram) -> AgentReply {
        var report = x.report
        var concerns = x.concerns
        if report == nil {
            let today = DayClock.logicalToday(c.now, c.profile)
            let start = min(x.baselineStart ?? today.adding(days: -14), today)
            let input = baselineInput(c, window: DateInterval(start: start, end: max(start, today)))
            let r = BaselineAssessment.assess(input)
            report = r
            concerns = CauseInference.concerns(r, input)
        }
        guard let r = report else { return whereNow(c, x) }
        let ranked = r.cards.flatMap(\.metrics).filter { $0.rank != nil }
        let low = ranked.filter { $0.rank!.band <= .lowerMid }.sorted { $0.rank!.goodness < $1.rank!.goodness }
        guard !low.isEmpty else {
            let best = ranked.max { $0.rank!.goodness < $1.rank!.goodness }
            let text = ranked.isEmpty ? "还没有能和同龄人比较的指标：需要年龄、性别，以及静息心率、最大摄氧量或体脂率的读数。"
                : "你有排名的指标都在同龄同性别的中等以上" + (best.map { "，最靠前的是\($0.title)（\($0.rank!.approx)）" } ?? "") + "。"
            return AgentReply(text: text, sources: ["基线报告"], destination: .plan, intent: .program, conclusion: text, verbatim: true)
        }
        var lines: [String] = []
        for m in low.prefix(3) {
            var line = "• \(m.title) \(m.valueText)：在同龄同性别里\(m.rank!.approx)。"
            if let causes = concerns.first(where: { $0.metric == m.kind })?.causes.prefix(2), !causes.isEmpty {
                line += "可能和这些有关：" + causes.map(\.text).joined(separator: "；") + "。"
            }
            lines.append(line)
        }
        let first = "排名靠后的有 \(low.count) 项，下面是可能的原因，不是诊断。"
        let note = "排名参考的人群和手表的误差写在基线报告里，估算的指标可能偏差一档。"
        return AgentReply(text: ([first] + lines + [note]).joined(separator: "\n"), sources: ["基线报告"], destination: .plan,
                          intent: .program, conclusion: first, verbatim: true)
    }

    /// A baseline worked out from what the context holds (the week of 基线期, or the last 14 days).
    static func baselineInput(_ c: AgentContext, window: DateInterval) -> BaselineInput {
        BaselineInput(profile: c.profile, days: c.days, workouts: c.workouts, vitals: c.vitals, labs: c.labs, window: window)
    }
}
