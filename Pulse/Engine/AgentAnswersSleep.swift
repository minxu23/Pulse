import Foundation

// MARK: - How much sleep

extension HealthAgent {
    /// What a question about the amount of sleep asks. 「我睡得太少怎么办」 asks for advice and stays
    /// with `sleep`; a number in the question (「昨晚只睡了 5 小时」) with `shortNight`.
    enum SleepAmountAsk { case enough, amount, need }

    static func sleepAmountAsk(_ a: AgentQuestion) -> SleepAmountAsk? {
        guard a.form != .how else { return nil }
        if case .sleepHours? = a.reading { return nil }
        if a.has(["该睡多久", "要睡多久", "睡多久", "睡几个小时", "睡几小时", "睡多少小时", "睡多少个小时"]) { return .need }
        if a.has(["睡了多久", "睡了多少", "睡了几个小时", "睡了几小时"]) { return .amount }
        if a.has(["昨晚", "昨天晚上"]), a.has(["睡得怎么样", "睡得好吗", "睡得好不好"]) { return .amount }
        if a.has(["睡够", "睡饱", "睡得够", "睡眠够", "睡眠时间够", "睡太少", "睡得太少", "睡得少吗"]) { return .enough }
        return nil
    }

    /// The nights the question names against the person's own need. Within half an hour of it is
    /// fine for the verdict, as in the sleep summary, but is not called enough: 6.5 of 7 is 「差一点」.
    static func sleepAmount(_ ask: SleepAmountAsk, _ a: AgentQuestion, context c: AgentContext) -> AgentReply {
        let p = c.profile
        let need = p.sleepNeedMinutes
        func hours(_ m: Double) -> String { (m / 60).oneDecimal }
        let lastNight = a.has(["昨晚", "昨天晚上", "昨夜", "昨天"])
        let thisWeek = a.has(["这周", "本周"])
        let nights: [Double]
        let period: String
        if lastNight {
            nights = c.days.first { $0.day == c.logicalToday }?.sleepMinutes.map { [$0] } ?? []
            period = "昨晚"
        } else if thisWeek {
            nights = c.days.filter { $0.day >= c.weekStart && $0.day <= c.logicalToday }.compactMap(\.sleepMinutes)
            period = "这周"
        } else {
            nights = c.sleep.avgMinutes.map { [$0] } ?? []
            period = "近 14 晚"
        }
        guard let average = Stats.mean(nights) else {
            let first = "\(period)还没有睡眠记录，看不出来。"
            return AgentReply(text: first + "佩戴手表入睡，或在「快速记录」里补记睡眠后，我就能算。", followUps: ["我的睡眠怎么样？"], destination: .sleep,
                              intent: .sleep, conclusion: first)
        }
        let enough = average >= need
        let close = !enough && average >= need - 30
        let amount = lastNight ? "睡了 \(hours(average)) 小时" : "平均每晚 \(hours(average)) 小时"
        let goal = "目标 \(hours(need)) 小时"
        var first: String
        switch ask {
        case .need:
            first = "你的目标是每晚 \(hours(need)) 小时；成年人一般需要 7–9 小时。"
        case .amount:
            first = "\(period)\(amount)，\(goal)。"
        case .enough:
            let short = max(need - average, 0)
            if lastNight {
                first = enough ? "昨晚睡够了：\(amount)，\(goal)。" : (close ? "昨晚差一点：\(amount)，\(goal)。" : "昨晚没睡够：\(amount)，\(goal)。")
            } else {
                first = enough ? "睡够了：\(period)\(amount)，\(goal)。"
                    : (close ? "差一点：\(period)\(amount)，\(goal)。" : "还差一些：\(period)\(amount)，\(goal)，每晚少了约 \(hours(short)) 小时。")
            }
        }
        var parts: [String?] = [first]
        if ask == .need { parts.append("你\(period)\(amount)。") }
        if thisWeek, nights.count > 1 { parts.append("这周目前记录了 \(nights.count) 晚。") }
        if lastNight, !enough, !close { parts.append("一晚睡少，当天把强度放轻就好，今晚按平时时间上床，不用一次补很久。") }
        var tips = enough || close ? ["起床时间固定，周末也一样"] : [p.insomnia ? ProfileSnapshot.insomniaAdvice : "每周把上床时间提前 15 分钟，直到睡够", "起床时间固定，周末也一样"]
        if p.shift != nil, !enough, !close { tips[1] = "休息日可以多睡一会儿，但起床时间别比上班日晚太多" }
        parts.append(bullets(tips))
        var r = AgentReply(text: lines(parts), sources: ["睡眠记录"], followUps: ["我的睡眠怎么样？"], destination: .sleep, intent: .sleep, conclusion: first)
        r.status = ask == .need ? nil : (enough ? .good("睡得够") : (close ? .good("差一点") : .attention("睡得不够")))
        // Last night, the week and the two weeks beside each other: the model mixes them up.
        r.asWrittenOnDevice = true
        return r
    }
}
