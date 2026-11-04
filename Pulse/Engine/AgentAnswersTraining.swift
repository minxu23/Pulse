import Foundation

// MARK: - Weekly running, the week's activity, and exercise around shifts

extension HealthAgent {
    /// What a question about the week's running asks. A question, not a plan change:
    /// 「这周跑量是不是太多了」 is answered, 「跑量减一点」 goes to `PlanChat`.
    enum RunVolumeAsk { case howMuch, enough, tooMuch, more }

    static func runVolumeAsk(_ a: AgentQuestion) -> RunVolumeAsk? {
        guard a.has(["跑量", "跑了多少", "跑了几公里", "跑多少公里了"]), !a.has(["减一点", "减点", "减少", "少跑", "帮我", "调整", "改成", "改为"]) else { return nil }
        if a.has(["太多", "太大", "太高", "过量", "跑多了", "有点多", "多了吗"]) { return .tooMuch }
        if a.has(["要不要加", "该不该加", "能不能加", "可以加", "能加", "该加", "要加吗", "怎么加", "加量"]) { return .more }
        if a.has(["跑了多少", "跑了几公里", "跑多少公里了"]) { return .howMuch }
        if a.has(["够", "达标", "太少", "少了", "怎么样", "合适", "正常"]) { return .enough }
        return nil
    }

    /// The week's kilometres against the race's target, or else the person's own last four weeks.
    /// It never says to make up what is missing: the week's gap is not worth an injury.
    static func runVolume(_ ask: RunVolumeAsk, _ a: AgentQuestion, context c: AgentContext) -> AgentReply {
        let p = c.profile
        let last = a.has(["上周"])
        let period = last ? "上周" : "这周"
        let start = last ? c.weekStart.adding(days: -7) : c.weekStart
        let end = start.adding(days: 7)
        func km(_ from: Date, _ to: Date) -> Double {
            c.workouts.filter { $0.type == .run && $0.start >= from && $0.start < to }.compactMap(\.distanceKm).reduce(0, +)
        }
        let done = km(start, end)
        let previous = km(start.adding(days: -7), start)
        let usual = km(start.adding(days: -28), start) / 4
        let target = last ? nil : c.race?.weeklyKm
        let left = last ? 0 : c.plan.filter { $0.day >= c.logicalToday && $0.day < end && $0.status == .planned && $0.title.contains("跑") }.count
        let held = p.cardiacLimited || p.intensityCapped
        let tooFast = c.load.zone == .high || c.load.zone == .caution
        func text(_ v: Double) -> String { "\(v.oneDecimal) km" }
        let ran = done > 0 ? "\(period)跑了 \(text(done))" : "\(period)还没跑"

        var first: String
        var status: AgentStatus? = nil
        var parts: [String?] = []
        var tips = ["每周加量不超过 10%，每 3–4 周减量一周"]

        if done == 0, usual == 0, target == nil {
            first = "记录里\(period)还没有跑步，近 4 周也没有，谈不上跑量。"
            if !last { parts.append("这周活动 \(Int(c.weekActiveMinutes)) 分钟，每周目标 \(p.weeklyTargetMinutes) 分钟。") }
            tips = ["想开始跑的话，先从每周 3 次、每次 20–30 分钟的轻松跑开始"]
        } else {
            switch ask {
            case .howMuch:
                first = "\(ran)，前一周 \(text(previous))。"
            case .enough:
                if let t = target {
                    if done >= t {
                        first = "够了：\(ran)，目标约 \(text(t))。"
                        status = .good("跑量够了")
                    } else if left > 0 {
                        first = "还没到，但不用急：\(ran)，目标约 \(text(t))，后面还有 \(left) 次跑步。"
                    } else {
                        first = "差一些：\(ran)，目标约 \(text(t))。"
                        parts.append("差的不用硬补，下周按计划来就好。")
                        status = .attention("差一些")
                    }
                } else if done > usual * 1.15 {
                    first = "比平时还多一些：\(ran)，近 4 周平均每周 \(text(usual))。"
                    status = .good("比平时多")
                } else if done >= usual * 0.9 {
                    first = "和平时差不多：\(ran)，近 4 周平均每周 \(text(usual))。"
                    status = .good("和平时差不多")
                } else {
                    first = "比平时少一些：\(ran)，近 4 周平均每周 \(text(usual))。"
                    if !last { parts.append("这周还没过完；差的不用硬补。") }
                }
            case .tooMuch:
                let usualKm = max(previous, usual)
                if tooFast {
                    first = "有点多：\(ran)，最近的训练负荷也涨得偏快（负荷比 \(c.load.ratio.map { String(format: "%.2f", $0) } ?? "—")）。"
                    status = .attention("有点多")
                } else if usualKm > 0, done > usualKm * 1.1 {
                    first = "有点多：\(ran)，平时每周约 \(text(usualKm))，一周加量最好别超过 10%。"
                    status = .attention("有点多")
                } else if let t = target, done > t * 1.1 {
                    first = "有点多：\(ran)，目标约 \(text(t))。"
                    status = .attention("有点多")
                } else {
                    first = "不算多：\(ran)，\(target.map { "目标约 \(text($0))" } ?? "近 4 周平均每周 \(text(usual))")。"
                    status = .good("不算多")
                }
            case .more:
                let base = max(done, previous, usual)
                if held {
                    first = "先别加：你记录了\((p.intensityCaps + (p.cardiacLimited ? ["心血管相关情况"] : [])).joined(separator: "、"))，加量前先问医生。"
                    status = .attention("先别加")
                } else if tooFast {
                    first = "先别加：最近的训练负荷涨得偏快（负荷比 \(c.load.ratio.map { String(format: "%.2f", $0) } ?? "—")），先稳住现在的量。"
                    status = .attention("先别加")
                } else if let t = target {
                    first = "按计划加就好：这周目标约 \(text(t))，后面每周比前一周多 10% 以内。"
                    status = .good("可以加")
                } else {
                    first = "可以加，但慢慢来：下周别超过 \(text(base * 1.1))，也就是比现在多 10% 以内。"
                    status = .good("可以加")
                }
            }
        }
        parts.insert(first, at: 0)
        parts.append(bullets(tips))
        var r = AgentReply(text: lines(parts), sources: ["跑步记录"], followUps: ["今天适合运动吗？"], destination: c.race == nil ? .plan : .marathon,
                           intent: .exercise, conclusion: first)
        r.status = status
        // Every figure here is a different week's or a target: the model takes one for another.
        r.asWrittenOnDevice = true
        return r
    }

    /// 「今天动多久能达标」「这周还差多少分钟」「步数还差多少」: how much is left of a target. 「今天还要
    /// 运动吗」 names no amount and stays with `TrainingCheck`.
    static func asksActivityLeft(_ a: AgentQuestion) -> Bool {
        guard !a.has(["血压", "血糖", "喝水", "水", "睡", "盐", "体重", "跑量", "比赛"]) else { return false }
        if asksSteps(a) { return true }
        let amount = a.has(["多久", "多少", "几分钟"])
        let left = a.has(["达标", "目标", "还差", "还要", "还需要", "才够", "才算"])
        let moving = a.has(["动", "练", "锻炼", "分钟"])
        return (amount && left && moving)
            || (a.has(["今天"]) && a.has(["运动", "活动"]) && a.has(["够了吗", "够吗", "够不够", "达标了吗"]))
            || (a.has(["目标"]) && a.has(["运动", "活动"]) && a.has(["完成了吗", "达标了吗"]))
    }

    private static func asksSteps(_ a: AgentQuestion) -> Bool {
        a.has(["步数", "多少步", "几步"]) && a.has(["今天", "还差", "达标", "够了吗", "够吗", "走了"])
    }

    static func activityLeft(_ a: AgentQuestion, context c: AgentContext) -> AgentReply {
        let p = c.profile
        var parts: [String?]
        var first: String
        var status: AgentStatus? = nil
        var tips: [String] = []
        if asksSteps(a) {
            let steps = c.days.first { $0.day == c.logicalToday }?.steps
            if let steps {
                let gap = p.stepsTarget - steps
                first = gap <= 0 ? "今天的步数够了：走了 \(steps) 步，目标 \(p.stepsTarget) 步。"
                    : "还差 \(gap) 步：今天走了 \(steps) 步，目标 \(p.stepsTarget) 步。"
                status = gap <= 0 ? .good("达标了") : .attention("还差 \(gap) 步")
                if gap > 0 { tips = ["大约再走 \(max(gap / 100, 1)) 分钟就够了，分几次走也行"] }
            } else {
                first = "今天还没有步数记录，看不出还差多少；你的目标是每天 \(p.stepsTarget) 步。"
            }
            parts = [first]
        } else {
            let done = Int(c.weekActiveMinutes)
            let target = p.weeklyTargetMinutes
            let gap = max(target - done, 0)
            let daysLeft = max(1, 7 - c.logicalToday.daysSince(c.weekStart))
            let perDay = Int((Double(gap) / Double(daysLeft)).rounded(.up))
            let today = a.has(["今天", "今日"])
            let dialysis = Dialysis.isDay(c.logicalToday, p)
            let tired = c.readiness.level == .low || c.readiness.level == .rest
            let sessions = c.plan.filter { $0.day >= c.logicalToday && $0.status == .planned && $0.kind.isTraining && $0.day < c.weekStart.adding(days: 7) }
            let planned = sessions.map(\.minutes).reduce(0, +)
            let plannedToday = sessions.filter { $0.day == c.logicalToday }.map(\.minutes).reduce(0, +)
            let doneToday = Int(c.days.first { $0.day == c.logicalToday }?.exerciseMinutes ?? 0)
            let progress = "这周已活动 \(done) 分钟，每周目标 \(target) 分钟"
            if gap == 0 {
                first = "这周已经达标了：\(progress)。"
                status = .good("达标了")
            } else {
                status = .attention("还差 \(gap) 分钟")
                if today, dialysis {
                    first = "今天是透析日，不安排训练：\(progress)，差的 \(gap) 分钟放到不透析的日子。"
                } else if today, tired {
                    first = "今天别为了达标硬练：\(progress)，差的 \(gap) 分钟放到后面几天。"
                } else if today, a.has(["够了吗", "够吗", "够不够", "达标了吗"]) {
                    // There is no target for a day: what it adds up to is the week's.
                    first = "目标是按周算的：今天活动了 \(doneToday) 分钟，\(progress)，还差 \(gap) 分钟。"
                } else if today, plannedToday >= gap {
                    first = "今天按计划练完，这周就达标了：\(progress)，今天计划 \(plannedToday) 分钟。"
                } else if today, planned >= gap {
                    first = "今天不用加练：\(progress)，后面计划里还有 \(sessions.count) 次训练，共 \(planned) 分钟，练完就达标了。"
                } else if today, gap <= p.sessionMinutes {
                    first = "今天动 \(gap) 分钟，这周就达标了：\(progress)。"
                } else if today {
                    first = "今天不用一次补完：\(progress)，还差 \(gap) 分钟，今天动 \(perDay) 分钟左右就好。"
                } else {
                    first = "还差 \(gap) 分钟：\(progress)。"
                }
            }
            parts = [first]
            if gap > 0 {
                if !today, planned >= gap { parts.append("计划里还有 \(sessions.count) 次训练，共 \(planned) 分钟，按计划练完就够了。") }
                else if !today, daysLeft > 1 { parts.append("算上今天还有 \(daysLeft) 天，平均每天 \(perDay) 分钟就够。") }
                tips = ["一次 10 分钟也算，分几次完成就行"]
                if p.intensityCapped || p.cardiacLimited { tips.append("运动强度按医生说的来，确认前不做间歇和大重量") }
            }
        }
        parts.append(bullets(tips))
        var r = AgentReply(text: lines(parts), sources: ["本周活动记录"], followUps: ["今天适合运动吗？"], destination: .plan, intent: .exercise, conclusion: first)
        r.status = status
        // Minutes done, left and planned beside each other: the model takes one for another.
        r.asWrittenOnDevice = true
        return r
    }

    /// 「夜班后什么时候运动最好」: when to train around shifts. For someone on a roster a yes or no
    /// about today stays with `TrainingCheck`, which knows the day's shift; without one the night
    /// shift the question names is taken at its word.
    static func shiftExercise(_ a: AgentQuestion, context c: AgentContext) -> AgentReply? {
        guard a.has(["夜班", "倒班", "轮班", "白班"]), a.has(["运动", "锻炼", "练", "跑", "健身", "训练"]) else { return nil }
        let kinds = a.has(["适合什么", "什么运动", "练什么", "做什么运动"])
        guard kinds || a.has(["什么时候", "几点", "何时", "什么时间", "哪个时间", "怎么安排", "怎么排"]) || c.profile.shift == nil else { return nil }
        let p = c.profile
        let first: String
        var tips: [String]
        // Today's shift bears on anything but a question about day shifts.
        let today = !a.has(["白班"]) || a.has(["夜班"])
        if kinds {
            first = "倒班的人适合时间灵活、强度好调的运动：快走、骑车、游泳和力量训练都行，关键是按班次来排。"
            tips = ["一次 20–30 分钟也算，班次紧的时候别硬撑", "睡前 2–3 小时别做高强度"]
        } else if a.has(["夜班前", "夜班当天", "夜班那天", "上班前"]) {
            first = "上夜班前可以运动：放在出门前 3–4 小时，做中低强度，别把体力用完。"
            tips = ["强度课和长距离放在休息日", "练完吃点东西，再小睡一会儿更好"]
        } else if a.has(["白班"]), !a.has(["夜班"]) {
            first = "上白班的日子，下班后到睡前 3 小时都可以；早上时间够的话，上班前也行。"
            tips = ["下班后先吃点东西，别空腹练", "睡前 2–3 小时别做高强度"]
        } else if !a.has(["夜班"]) {
            first = "按班次来排：夜班后先补觉、醒来再动，上白班的日子下班后练，强度课和长距离放在休息日。"
            tips = ["一次 20–30 分钟也算，班次紧的时候别硬撑", "睡前 2–3 小时别做高强度"]
        } else {
            first = "夜班后先补觉，运动放在醒来以后：下班直接练，身体更兴奋，反而睡不好。"
            tips = ["夜班后的恢复日只做散步、拉伸这样的轻松活动", "强度课和长距离放在休息日，或者睡够以后", "睡前 2–3 小时别做高强度"]
        }
        var parts: [String?] = [first]
        if let s = p.shift {
            if today, c.window.afterNightShift {
                parts.append("今天是夜班后的恢复日：\(Clock.text(c.window.wake.minutesOfDay)) 左右起床后，做 20–30 分钟轻松活动就好，\(Clock.text(c.window.bed.minutesOfDay)) 上床前 2–3 小时别练。")
            } else if today, c.window.kind == .night {
                parts.append("今晚要上夜班：白天别把体力用在强度课上。")
            }
            let rest = (1...7).map { c.logicalToday.adding(days: $0) }.filter { s.kind(on: $0) == .off }.prefix(3).map { Weekday.name($0.weekday) }
            if !rest.isEmpty { parts.append("接下来的休息日是\(rest.joined(separator: "、"))：强度课和长距离放在这几天。") }
        } else {
            parts.append("你还没有设置班次。在「我的 › 作息与倒班」填上后，Pulse 会按班次排计划和提醒。")
        }
        if p.intensityCapped || p.cardiacLimited { tips.append("运动强度按医生说的来，确认前不做间歇和大重量") }
        parts.append(bullets(tips))
        return AgentReply(text: lines(parts), sources: [p.shift == nil ? "倒班常识" : "倒班安排"], followUps: ["夜班后怎么补觉？"], destination: .plan,
                          intent: .exercise, conclusion: first)
    }
}
