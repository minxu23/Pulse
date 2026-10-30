import Foundation

// MARK: - Questions offered under an answer

/// The questions offered under an answer: what someone would ask next about this answer, for this
/// person, and that Pulse answers well. Each candidate is answered by the rules first; one that has
/// no real answer (no data, an open question), repeats the current answer or another suggestion, or
/// was already asked is left out. The builder's own `followUps` only fill in after these.
enum AgentFollowUps {
    static func suggest(after r: AgentReply, question q: String, context c: AgentContext, asked: [String], fallback: Bool = true,
                        limit: Int = 3) -> [String] {
        guard !r.urgent else { return [] }
        var out: [String] = []
        var seen = Set((asked + [q]).map(norm))
        var answers: Set<String> = [String(r.text.prefix(40))]
        // A question about someone else gets know-how on its topic, never prompts about the user's own records.
        let own = fallback && !HealthAgent.aboutSomeoneElse(q) ? r.followUps : []
        for candidate in candidates(after: r, question: q, context: c) + own where out.count < limit {
            guard seen.insert(norm(candidate)).inserted else { continue }
            let resolved = HealthAgent.resolveFollowUp(candidate, previous: q) ?? candidate
            guard !seen.contains(norm(resolved)) || resolved == candidate else { continue }
            let answer = HealthAgent.reply(to: resolved, context: c)
            guard answerable(answer), answers.insert(String(answer.text.prefix(40))).inserted else { continue }
            out.append(candidate)
        }
        return out
    }

    /// Whether the rules give a real answer: not an open question, not 「还没有…数据」.
    private static func answerable(_ a: AgentReply) -> Bool {
        if a.urgent || a.intent == .unknown { return false }
        return !["还没有", "近两周没有", "近 7 天没有"].contains { a.text.hasPrefix($0) }
    }

    private static func norm(_ s: String) -> String { s.filter { !"？?。！!，, ".contains($0) } }

    /// What follows from this answer, most relevant first.
    static func candidates(after r: AgentReply, question q: String, context c: AgentContext) -> [String] {
        let p = c.profile
        let a = AgentQuestion(q)
        let diabetes = p.hasDiabetes
        let onBPMeds = c.medications.contains { [.betaBlocker, .rateLimitingCCB, .otherAntihypertensive].contains($0.category) }
        let saltMatters = !p.conditions.isDisjoint(with: [.hypertension, .ckd, .heartFailure]) || p.tracksNutrients
        let kHigh = c.lab(.potassium, within: 180).map { $0.value > 5.0 } ?? false
        let hasLabs = !c.labs.isEmpty
        let breathing = c.breathing.level != .none
        let alcohol = c.association("alcohol-rhr") != nil
        func when(_ ok: Bool, _ s: String) -> String? { ok ? s : nil }

        if HealthAgent.aboutSomeoneElse(q) {
            return [a.has(["血压", "高血压"]) ? "少吃盐有什么技巧？" : nil, a.has(["糖尿病", "血糖"]) ? "糖尿病人能吃水果吗？" : nil].compactMap { $0 }
        }
        let list: [String?]
        switch r.intent {
        case .food:
            let f = a.food
            let carbs = f.map { $0.carb != .none } ?? false
            list = [
                when(f?.carb == .fruit && f?.potassium == true && (kHigh || p.limitsPotassium), "那苹果呢？"),
                when(r.text.contains("盐多") || (f?.salty == true && saltMatters), "少吃盐有什么技巧？"),
                when(diabetes && (r.text.contains("血糖") || carbs), "血糖老是高怎么办？"),
                when(r.text.contains("嘌呤"), "尿酸高要注意什么？"),
                when(f?.sport != nil && !diabetes, "空腹跑步可以吗？"),
                "今天吃什么好？",
            ]
        case .reading:
            switch a.reading {
            case .bp(let sys, _)?:
                list = [when(sys >= 135, "我的血压控制得怎么样？"), when(sys < 90, "站起来头晕怎么办？"),
                        when(onBPMeds, "降压药是早上吃还是晚上吃？"), when(saltMatters && sys >= 135, "少吃盐有什么技巧？")]
            case .glucose(let v, _)?:
                list = [when(v >= p.glucoseLow, "血糖老是高怎么办？"), when(diabetes, "糖尿病人能吃水果吗？"),
                        when(c.lows.count >= 2 || v < p.glucoseLow, "我需要去看医生吗？"), "今天吃什么好？"]
            case .sleepHours?:
                list = [when(!c.pastBedtime, "今晚该注意什么？"), "熬夜后怎么恢复？", "今天适合运动吗？"]
            case .weightChange?:
                list = [when(saltMatters, "少吃盐有什么技巧？"), when(p.watchesWeight, "我需要去看医生吗？"), "我想减肥该怎么吃？"]
            case nil:
                list = []
            }
        case .symptom:
            switch a.symptom {
            case .fatigue?: list = ["我的睡眠怎么样？", "今天适合运动吗？", when(hasLabs, "我的化验结果怎么样？")]
            case .dizzy?: list = [when(c.bp.count > 0, "我的血压控制得怎么样？"), when(diabetes, "血糖控制得怎么样？"), "我需要去看医生吗？"]
            case .swelling?: list = [when(saltMatters, "少吃盐有什么技巧？"), when(c.lab(.egfr) != nil, "我的肾功能怎么样？"), "我需要去看医生吗？"]
            case .cold?: list = ["这周的训练要怎么调整？", "今天适合运动吗？"]
            case .pain?: list = ["拉伸怎么做？", "这周的训练要怎么调整？", "今天适合运动吗？"]
            case .soreness?: list = ["拉伸怎么做？", "今天适合运动吗？"]
            case .palpitations?: list = [when(c.association("caffeine-sleep") != nil, "咖啡因对我有影响吗？"), when(alcohol, "饮酒对我的影响有多大？"), "我需要去看医生吗？"]
            case .cramps?: list = ["拉伸怎么做？", when(hasLabs, "我的化验结果怎么样？")]
            case .thirst?: list = [when(diabetes, "血糖控制得怎么样？"), when(saltMatters || p.fluidLimited, "少吃盐有什么技巧？")]
            case .urine?: list = [when(c.lab(.uacr) != nil || c.lab(.egfr) != nil, "我的肾功能怎么样？"), when(saltMatters, "少吃盐有什么技巧？")]
            case .headache?: list = [when(c.bp.count > 0, "我的血压控制得怎么样？"), "我的睡眠怎么样？"]
            case nil: list = []
            }
        case .trainingCheck:
            let tomorrow = q.contains("明天") || q.contains("明早")
            let affected = !WeatherPlanner.advice(plan: c.plan, forecast: c.weather, now: c.now, profile: p).affected.isEmpty
            list = [tomorrow ? "那后天呢？" : "那明天呢？", when(c.nearBedtime, "今晚该注意什么？"),
                    when(affected && !q.contains("天气"), "这几天的天气适合户外训练吗？"), "这周的训练完成得怎么样？"]
        case .planChange, .weather:
            list = ["今天适合运动吗？", "这周的训练完成得怎么样？"]
        case .exercise:
            list = ["今天适合运动吗？", when(p.goals.contains(.lowerRHR), "怎么才能把静息心率降下来？"), "热身怎么做？"]
        case .rhr:
            let flat = c.dimension("rhr")?.status != .improved
            list = [when(!q.contains("降"), "怎么才能把静息心率降下来？"), when(flat && !q.contains("为什么"), "为什么静息心率最近没怎么降？"),
                    when(alcohol, "饮酒对我的影响有多大？"), "我的睡眠怎么样？"]
        case .hrv:
            list = a.form == .explain ? ["我的HRV最近怎么样？", "准备度是怎么算的？", "今天适合运动吗？"]
                : ["今天适合运动吗？", "我的睡眠怎么样？", "准备度是怎么算的？"]
        case .readiness:
            list = ["今天适合运动吗？", "我的睡眠怎么样？", "准备度是怎么算的？"]
        case .sleep:
            if case .sleepHours? = a.reading {
                list = [when(!c.pastBedtime, "今晚该注意什么？"), "熬夜后怎么恢复？", "今天适合运动吗？"]
                break
            }
            list = [when(!a.has(["睡不着", "失眠"]), "睡不着怎么办？"), when(c.association("caffeine-sleep") != nil, "咖啡因对我睡眠有影响吗？"),
                    when(breathing, "我需要去看睡眠门诊吗？"), when(p.shift != nil, "夜班后怎么补觉？"), "明天适合运动吗？"]
        case .breathing:
            list = ["我需要去看睡眠门诊吗？", "我的睡眠怎么样？", when(alcohol, "饮酒对我的影响有多大？")]
        case .alcohol:
            let training = a.has(["跑", "练", "运动", "锻炼", "健身"])
            list = [when(!q.contains("影响"), "饮酒对我的影响有多大？"), when(!training, "喝酒后第二天能跑步吗？"),
                    when(training, "今天适合运动吗？"), "我的睡眠怎么样？"]
        case .caffeine:
            list = [when(!q.contains("现在"), "现在可以喝咖啡吗？"), "我的睡眠怎么样？", "睡不着怎么办？"]
        case .stress:
            list = ["睡不着怎么办？", "今天适合运动吗？"]
        case .diet:
            list = [when(saltMatters && !q.contains("盐"), "少吃盐有什么技巧？"), when(diabetes, "糖尿病人能吃水果吗？"),
                    when(kHigh, "我能吃香蕉吗？"), when(!q.contains("饿"), "晚上饿了能吃点什么？"), when(!q.contains("吃什么"), "今天吃什么好？")]
        case .bp:
            list = [when(saltMatters || c.bp.avgSys.map { $0 >= 130 } == true, "少吃盐有什么技巧？"), when(onBPMeds, "降压药是早上吃还是晚上吃？"),
                    "我需要去看医生吗？"]
        case .glucose:
            list = [when(diabetes, "糖尿病人能吃水果吗？"), "今天吃什么好？", when(c.lows.count >= 2, "我需要去看医生吗？"),
                    when(DeviceGuide.usesCGM(c), "CGM 贴在哪里比较好？")]
        case .labs:
            list = [when(kHigh, "我能吃香蕉吗？"), when(p.conditions.contains(.ckd), "少吃盐有什么技巧？"), "我该多久去复查一次？"]
        case .meds:
            list = [when(!q.contains("忘") && !q.contains("漏"), "忘了吃药怎么办？"), when(onBPMeds, "我的血压控制得怎么样？"), when(diabetes, "血糖控制得怎么样？")]
        case .events, .doctor:
            list = [when(!p.conditions.isEmpty, "我该多久去复查一次？"), "接下来我该关注什么？"]
        case .next, .overall:
            let watch = HealthAgent.assess(c).watch.map(\.title).joined()
            list = [when(watch.contains("呼吸"), "我需要去看睡眠门诊吗？"), when(watch.contains("血压"), "我的血压控制得怎么样？"),
                    when(watch.contains("血糖"), "血糖控制得怎么样？"), when(watch.contains("饮酒"), "饮酒对我的影响有多大？"),
                    when(c.dimension("rhr")?.status != .improved, "为什么静息心率最近没怎么降？"), when(r.intent == .overall, "接下来我该关注什么？")]
        case .marathon:
            list = c.marathonActive ? [when(!q.contains("补给"), "马拉松怎么补给？"), "这周的训练完成得怎么样？", "明天能跑间歇吗？"]
                : [when(!q.contains("补给"), "马拉松怎么补给？"), when(!q.contains("适合"), "我适合跑马拉松吗？"), "热身怎么做？"]
        case .device:
            list = [when(DeviceGuide.usesCGM(c), "CGM 贴在哪里比较好？"), "今天适合运动吗？"]
        case .knowledge:
            list = [when(!q.contains("热身"), "热身怎么做？"), when(!q.contains("拉伸") && !q.contains("拉多久"), "拉伸怎么做？"),
                    when(q.contains("跑"), "跑步时怎么呼吸？"), "今天适合运动吗？"]
        case .about:
            list = ["我的数据会上传吗？", "你的建议依据是什么？"]
        case .condition, .greeting, .daySummary, .unknown, .emergency:
            list = []
        }
        return list.compactMap { $0 }
    }
}
