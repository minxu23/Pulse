import Foundation

// MARK: - What one thing does to another

/// 「喝酒对血压有影响吗」「睡得少血糖会高吗」: a question about what one thing does to another. The
/// topic word it holds (血压) must not turn it into the blood-pressure report: it is answered
/// about the two things it names, with this person's own days compared where the records allow.
struct AskedEffect: Equatable {
    enum Cause: CaseIterable {
        case alcohol, caffeine, tea, water, walk, exercise, shortSleep, lateMeal, stress, salt, weightLoss, smoking, spicy, cold, highBP, highGlucose

        var words: [String] {
            switch self {
            case .alcohol: ["喝酒", "饮酒", "酒后", "喝了酒", "啤酒", "白酒", "红酒", "酒精"]
            case .caffeine: ["咖啡", "奶茶", "浓茶", "功能饮料", "能量饮料"]
            case .tea: ["喝茶", "茶"]
            case .water: ["喝水", "饮水", "喝很多水"]
            case .walk: ["饭后散步", "餐后散步", "饭后走", "散步"]
            case .exercise: ["运动", "跑步", "锻炼", "训练", "健身", "有氧", "快走", "游泳", "骑车"]
            case .shortSleep: ["睡眠", "睡不好", "睡得少", "睡得不好", "睡不够", "没睡好", "少睡", "熬夜", "失眠", "晚睡"]
            case .lateMeal: ["晚饭太晚", "晚饭吃得晚", "吃得晚", "吃夜宵", "夜宵", "宵夜"]
            case .stress: ["压力", "紧张", "焦虑"]
            case .salt: ["盐", "吃咸", "太咸", "口味重", "重口味"]
            case .weightLoss: ["减肥", "减重", "减脂", "瘦下来", "瘦一点"]
            case .smoking: ["抽烟", "吸烟", "戒烟"]
            case .spicy: ["吃辣", "辣椒", "辛辣"]
            case .cold: ["天冷", "天气冷", "冬天", "降温", "气温低"]
            case .highBP: ["血压高", "血压偏高", "高血压"]
            case .highGlucose: ["血糖高", "血糖偏高", "高血糖", "糖尿病"]
            }
        }
    }

    enum Outcome: CaseIterable {
        case bp, glucose, sleep, kidney

        var words: [String] {
            switch self {
            case .bp: ["血压", "高压", "低压"]
            case .glucose: ["血糖", "糖化"]
            case .sleep: ["睡眠", "睡觉", "入睡", "睡不着", "失眠", "睡得"]
            case .kidney: ["肾", "肌酐", "eGFR", "egfr", "蛋白尿"]
            }
        }
    }

    /// What a question says when it asks about an effect rather than a value or a plan.
    private static let asking = ["影响", "帮助", "好处", "坏处", "有害", "有用", "管用", "好吗", "好不好", "有关", "关系", "伤", "控制",
                                 "会高", "会低", "会升", "会降", "能降", "能升", "可以降", "降血", "升血", "升高", "为什么", "为啥"]

    let cause: Cause
    let outcomes: [Outcome]

    /// The first thing named that has something to say about what the question asks after.
    /// 「我血压高，喝酒有影响吗」 is about the drink; medicines are always the doctor's call.
    static func find(in q: String) -> AskedEffect? {
        guard asking.contains(where: { q.contains($0) }), !["药", "胰岛素"].contains(where: { q.contains($0) }) else { return nil }
        let outcomes = Outcome.allCases.filter { $0.words.contains { q.contains($0) } }
        guard !outcomes.isEmpty else { return nil }
        let named = Cause.allCases
            .compactMap { c in c.words.compactMap { q.range(of: $0)?.lowerBound }.min().map { (c, $0) } }
            .sorted { $0.1 < $1.1 }
        for (cause, _) in named {
            let known = outcomes.filter { cause.effect(on: $0, profile: ProfileSnapshot()) != nil }
            if !known.isEmpty { return AskedEffect(cause: cause, outcomes: known) }
        }
        return nil
    }
}

extension AskedEffect.Cause {
    typealias Effect = (lead: String, tips: [String])

    /// What is generally known, in one direct sentence, and what to do about it.
    func effect(on o: AskedEffect.Outcome, profile p: ProfileSnapshot) -> Effect? {
        let need = (p.sleepNeedMinutes / 60).oneDecimal
        let sleepEnough = "尽量睡够 \(need) 小时，起床时间固定"
        let breathe = "压力大时做 5–10 分钟慢呼吸或散步"
        let saltLimit = "盐每天不超过 \(p.saltLimitG.noDecimal) g，酱油、咸菜、外卖都算"
        let eatLess = "每餐先吃菜，主食减三分之一"
        let kidneyCheck = "每年查一次尿白蛋白和 eGFR"
        let quit = "能戒就戒，医院的戒烟门诊可以帮忙"
        switch (self, o) {
        case (.alcohol, .bp): return ("会。酒会让血压升高，喝得越多、越经常，升得越明显。",
                                      ["能不喝就不喝；要喝的话，每周别超过你定的 \(p.weeklyAlcoholLimit.noDecimal) 个单位", "喝过酒的第二天早上测一次血压，和平时比一比"])
        case (.alcohol, .glucose): return ("会。酒会让血糖忽高忽低：啤酒和甜酒会升血糖，空腹喝酒几小时后又可能偏低。",
                                           ["别空腹喝，喝的时候吃点东西", "啤酒、甜酒少喝"])
        case (.alcohol, .sleep): return ("会。酒让人更快睡着，但后半夜睡得浅、容易醒。",
                                         ["离睡觉 3 小时前停", "第二天先看准备度，再决定练不练"])
        case (.alcohol, .kidney): return ("偶尔少喝一点一般不直接伤肾，但常喝、喝多会升血压、造成脱水，都会加重肾的负担。",
                                          ["有慢性肾病或血压高的话，最好不喝；其他情况也别超过你定的每周 \(p.weeklyAlcoholLimit.noDecimal) 个单位"])

        case (.caffeine, .bp): return ("会，但主要是短时的：咖啡因会让血压暂时升高几小时，常喝的人影响小一些。",
                                       ["测血压前 30 分钟别喝咖啡、浓茶", "喝完心慌或血压明显升高的话，少喝或换成低因"])
        case (.caffeine, .glucose): return ("黑咖啡本身几乎不含糖，影响不大；加糖的咖啡和奶茶才是升血糖的主因。",
                                            ["咖啡别加糖", "奶茶选无糖，或者少喝"])
        case (.caffeine, .sleep): return ("会。咖啡因的作用可持续 5–6 小时以上，下午和晚上喝最影响入睡。",
                                          ["\(p.caffeineCutoffHour):00 以后别喝，下午可以换成低因或无咖啡因的饮品"])
        case (.caffeine, .kidney): return ("适量喝咖啡一般不伤肾。",
                                           ["限水的话，咖啡也算进每天的饮水量", "限钾的话，每天喝多少问一下肾内科医生或营养师"])

        case (.tea, .bp): return ("淡茶一般没问题；浓茶含咖啡因，会让血压短时升高。", ["测血压前 30 分钟别喝浓茶"])
        case (.tea, .glucose): return ("不加糖的茶基本不影响血糖；奶茶和加糖的茶饮才会升血糖。", ["喝茶别加糖，奶茶少喝"])
        case (.tea, .sleep): return ("会。茶也含咖啡因，下午和晚上喝浓茶最影响入睡。", ["\(p.caffeineCutoffHour):00 以后换成白水或无咖啡因的饮品"])
        case (.tea, .kidney): return ("淡茶适量喝一般没问题。", ["限水的话，茶也算进每天的饮水量"])

        case (.water, .kidney):
            if p.fluidLimited { return ("你在限水，多喝水对你没有好处：喝多了肾排不出去，水肿和血压都会加重。", ["每天喝水不超过 \(p.waterTargetMl) ml，汤、粥、水果里的水也算"]) }
            return ("喝够水对肾有好处，尿量足、不容易长结石；但不是越多越好。", ["一般每天 1500–2000 ml，分几次喝", "有慢性肾病或水肿的话，喝多少听医生的"])
        case (.water, .bp):
            if p.fluidLimited { return ("你在限水，喝多了身体留住水分，血压和水肿都会加重。", ["每天喝水不超过 \(p.waterTargetMl) ml，汤、粥、水果里的水也算"]) }
            return ("正常喝水对血压影响不大。", ["一般每天 1500–2000 ml，分几次喝"])
        case (.water, .glucose): return ("白水本身不影响血糖；一直口渴、尿多的话，测一下血糖。", p.fluidLimited ? ["喝水还是按医生定的量"] : ["饮料换成白水或无糖茶"])
        case (.water, .sleep): return ("睡前喝太多水容易起夜，影响睡眠。", ["睡前 2 小时少喝"])

        case (.walk, .glucose): return ("有用。饭后走 10–15 分钟，肌肉会用掉一部分血糖，餐后的高峰能压低一些。",
                                        ["吃完半小时内开始走", "走到微微出汗就够，不用快"])
        case (.walk, .bp), (.exercise, .bp): return ("有帮助。规律的有氧运动长期能让血压降下来；运动时血压暂时升高是正常的。",
                                                     ["每周 150 分钟以上的有氧，比如快走、骑车", "血压明显偏高或头晕时先别练，问过医生再说"])
        case (.exercise, .glucose): return ("能。运动时肌肉直接用糖，规律运动还能让身体对胰岛素更敏感；高强度运动后血糖可能短时升高，这是正常的。",
                                            ["饭后 30–60 分钟走一走最管用", "每周加 2 次力量训练"])
        case (.walk, .sleep), (.exercise, .sleep): return ("有帮助。规律运动能让人更快入睡、睡得更深，只是睡前 2–3 小时别做高强度。",
                                                           ["白天或傍晚运动最好", "睡前换成拉伸或散步"])
        case (.walk, .kidney), (.exercise, .kidney): return ("适度运动对肾有好处，它能帮你控制血压和血糖；大强度运动和脱水才会加重肾的负担。",
                                                             ["以快走、骑车这样的中低强度为主", "化验前 1–2 天别做剧烈运动，肌酐可能暂时偏高"])

        case (.shortSleep, .bp): return ("会。睡得少、睡不好时血压容易偏高，第二天早上尤其明显。",
                                         [sleepEnough, "打鼾、夜里憋醒的话，去查一下睡眠呼吸"])
        case (.shortSleep, .glucose): return ("会。睡不够时身体对胰岛素没那么敏感，第二天血糖容易偏高，也更想吃甜的。",
                                              [sleepEnough, "没睡好的第二天，早饭少吃甜的和精米白面"])
        case (.shortSleep, .kidney): return ("有一定关系：长期睡不好会抬高血压和血糖，这两样都伤肾。", [sleepEnough])

        case (.lateMeal, .glucose): return ("会。晚饭太晚或吃夜宵，第二天早上血糖容易偏高。", ["晚饭在睡前 2–3 小时吃完", "饿了吃点清淡的，别吃主食和甜的"])
        case (.lateMeal, .sleep): return ("会。吃得太晚，肠胃还在工作，入睡慢、睡得浅。", ["晚饭在睡前 2–3 小时吃完"])

        case (.stress, .bp): return ("会。压力大时血压会短时升高；长期压力大还常常伴随睡不好、吃得咸、动得少，血压更难控制。",
                                     [breathe, "别在紧张或刚忙完时测血压，静坐 5 分钟再测"])
        case (.stress, .glucose): return ("会。压力激素会让血糖升高，有糖尿病的人更明显。", [breathe, "睡够、按时吃饭，血糖更稳"])
        case (.stress, .sleep): return ("会。压力大时大脑放松不下来，入睡慢、容易醒。", ["睡前 30 分钟放下手机，做几分钟慢呼吸", "把明天要做的事写下来再睡"])

        case (.salt, .bp): return ("会。盐吃多了身体会留住水分，血压跟着升高；少吃盐，血压通常能降一些。", [saltLimit, "多用醋、葱姜蒜和香料提味"])
        case (.salt, .kidney): return ("会。盐吃多了血压会升高，肾也要更费力地排盐，尿蛋白往往也更多。", [saltLimit, "低钠盐含钾，有肾病或限钾时先问医生再用"])
        case (.salt, .glucose): return ("盐本身不直接升血糖；有糖尿病的人控盐，主要是为了保护血压和肾。", [saltLimit])

        case (.weightLoss, .bp): return ("有帮助。超重的话，减几公斤血压就能降一些。", [eatLess, "每周活动 150 分钟以上"])
        case (.weightLoss, .glucose): return ("有帮助。超重的话，减重能让身体对胰岛素更敏感，血糖更好控制。", [eatLess, "每周活动 150 分钟以上"])
        case (.weightLoss, .kidney): return ("超重的话，减重能减轻肾的负担；但有慢性肾病时别节食，也别靠高蛋白减肥。", [eatLess, "有慢性肾病的话，减重前先问医生"])
        case (.weightLoss, .sleep): return ("超重又打鼾的话，减重后打鼾往往减轻，睡得更好。", [eatLess])

        case (.smoking, .bp): return ("会。每抽一支烟，血压和心率都会短时升高，长期还伤血管。", [quit, "测血压前 30 分钟别抽烟"])
        case (.smoking, .glucose): return ("会。吸烟让身体对胰岛素没那么敏感，血糖更难控制。", [quit])
        case (.smoking, .kidney): return ("会。吸烟伤肾里的小血管，会加快肾功能下降。", [quit])
        case (.smoking, .sleep): return ("会。尼古丁让人兴奋，睡前抽烟入睡更慢，也更容易醒。", [quit, "睡前 2 小时别抽"])

        case (.spicy, .bp): return ("辣本身和血压没有明确的关系；要留意的是辣味菜往往更咸、更油。", ["吃辣的时候少放盐和油，汤别喝完"])
        case (.spicy, .glucose): return ("辣本身不升血糖；要留意的是辣味菜容易下饭，主食吃得多。", ["吃辣的时候主食照常定量"])

        case (.cold, .bp): return ("会。天冷时血管收缩，血压通常比暖和的时候高一些，冬天早上尤其明显。",
                                   ["冬天起床别太猛，注意保暖", "天冷时血压持续偏高，就告诉医生"])

        case (.highBP, .kidney): return ("会。长期血压高会损伤肾里的小血管，肾功能下降后血压又更难控制。", ["把血压控制在目标以下", kidneyCheck])
        case (.highGlucose, .kidney): return ("会。长期血糖高会损伤肾小球，是慢性肾病最常见的原因之一。", ["把血糖控制在目标内", kidneyCheck])
        default: return nil
        }
    }
}

extension HealthAgent {
    static func effectAnswer(_ e: AskedEffect, _ a: AgentQuestion, context c: AgentContext) -> AgentReply {
        let p = c.profile
        let said = e.outcomes.compactMap { e.cause.effect(on: $0, profile: p) }
        let leads = said.enumerated().map { i, s in lead(s.lead, a, first: i == 0) }
        var parts: [String?] = leads
        for o in e.outcomes {
            parts.append(standing(o, context: c))
            parts.append(ownDays(e.cause, o, context: c))
        }
        if e.cause == .weightLoss { parts.append(p.bmi >= 24 ? "你现在 BMI \(p.bmi.oneDecimal)，偏高，减一点就有用。" : "你现在 BMI \(p.bmi.oneDecimal)，已经在正常范围，减重不是重点。") }
        var tips: [String] = []
        for t in said.flatMap(\.tips) where !tips.contains(t) { tips.append(t) }
        if e.cause == .exercise, p.intensityCapped || p.cardiacLimited { tips.append("运动强度按医生说的来，确认前不做间歇和大重量") }
        parts.append(bullets(Array(tips.prefix(4))))
        // What it means for this person's conditions comes last, and stays however the answer is reworded.
        let caution: String? = switch e.cause {
        case .alcohol: alcoholCautions(c)
        case .exercise, .walk: e.outcomes.contains(.glucose) && p.hasDiabetes && p.hypoRiskMeds(at: c.now) ? "你用的药有低血糖风险：运动前后测血糖，身边带点糖。" : nil
        default: nil
        }
        parts.append(caution)
        return AgentReply(text: lines(parts), sources: sources(e), followUps: ["接下来我该关注什么？"], destination: destination(e.outcomes[0]),
                          intent: topic(e), conclusion: leads[0], safety: caution)
    }

    /// 「会。」 answers 「会…吗」, not 「少吃盐有好处吗」 or 「为什么…」, and is said once.
    private static func lead(_ text: String, _ a: AgentQuestion, first: Bool) -> String {
        let word = ["会。", "能。", "有帮助。", "有用。"].first { text.hasPrefix($0) }
        guard let word else { return text }
        let rest = String(text.dropFirst(word.count))
        if !first || a.form == .why || a.has(["升高"]) { return rest }
        return word == "会。" && a.has(["好处", "帮助", "有用", "管用"]) ? "有帮助。" + rest : text
    }

    /// Where the person stands on what the question asks after.
    private static func standing(_ o: AskedEffect.Outcome, context c: AgentContext) -> String? {
        switch o {
        case .bp:
            guard c.bp.count > 0, let s = c.bp.avgSys, let d = c.bp.avgDia else { return nil }
            return "你近 30 天血压平均 \(Int(s))/\(Int(d))，目标是 \(c.profile.bpTargetSys)/\(c.profile.bpTargetDia) 以下。"
        case .glucose:
            guard c.glucose.readings > 0, let tir = c.glucose.tir else { return nil }
            return "你近 14 天 \(Int((tir * 100).rounded()))% 的时间在目标范围内，一般希望 70% 以上。"
        case .sleep:
            guard let m = c.sleep.avgMinutes else { return nil }
            return "你近 14 晚平均睡 \((m / 60).oneDecimal) 小时，目标 \((c.profile.sleepNeedMinutes / 60).oneDecimal) 小时。"
        case .kidney:
            guard let e = c.lab(.egfr, within: 365) else { return nil }
            return "你最近一次 eGFR 是 \(e.valueText)（\(e.date.formatted(.dateTime.month().day()))）。"
        }
    }

    /// This person's days with the cause against the days without, for causes the records hold.
    /// Silent below 4 of either, the same bar the associations use; never called a cause, and a gap
    /// that is small or runs the other way is said to show nothing.
    static func ownDays(_ cause: AskedEffect.Cause, _ o: AskedEffect.Outcome, context c: AgentContext, morning: Bool = false) -> String? {
        let p = c.profile
        let factor: (name: String, lag: Int, on: (DayData) -> Bool?)
        switch cause {
        case .alcohol: factor = ("喝过酒", 1, { $0.hadAlcohol })
        case .shortSleep: factor = ("睡不够", 0, { d in d.sleepMinutes.map { $0 < p.sleepNeedMinutes - 30 } })
        case .stress: factor = ("压力大", 1, { d in d.stress.map { _ in d.highStress } ?? (d.tags.contains(.highStress) ? true : nil) })
        case .lateMeal: factor = ("晚饭吃得晚", 1, { $0.lateMeal })
        case .salt: factor = ("吃得偏咸", 1, { d in d.saltG.map { $0 > p.saltLimitG } })
        case .exercise: factor = ("运动过", 1, { ($0.exerciseMinutes ?? 0) >= 20 })
        case .caffeine, .tea: factor = ("下午还喝咖啡因", 1, { d in d.caffeineCups > 0 ? d.lateCaffeine(cutoff: p.caffeineCutoffHour) : false })
        default: return nil
        }
        // What is measured, on which days, and which way the cause is expected to move it.
        let time = factor.lag == 0 ? "那天" : "第二天"
        let values: [Date: Double], label: String, others: String, metric: String, unit: String, margin: Double, expectHigher: Bool
        switch o {
        case .bp:
            guard ![.exercise, .caffeine, .tea].contains(cause) else { return nil }
            let morning = c.vitals.filter { $0.kind == .bloodPressure && $0.time.hour < 12 }
            values = Dictionary(grouping: morning, by: \.time.startOfDay).compactMapValues { Stats.mean($0.map(\.value)) }
            label = factor.lag == 0 ? "\(factor.name)的早上" : "\(factor.name)的第二天早上"
            (others, metric, unit, margin, expectHigher) = ("其他早上", "收缩压", "", 3, true)
        case .glucose:
            guard ![.exercise, .caffeine, .tea].contains(cause) else { return nil }
            let points = c.vitals.filter { $0.kind == .glucose && (!morning || (4..<9).contains($0.time.hour)) }
            values = Dictionary(grouping: points, by: \.time.startOfDay).compactMapValues { Stats.mean($0.map(\.value)) }
            label = "\(factor.name)的\(time)\(morning ? "早上" : "")"
            (others, metric, unit, margin, expectHigher) = ("其他日子", "平均血糖", " mmol/L", 0.3, true)
        case .sleep:
            guard cause != .shortSleep else { return nil }
            values = Dictionary(c.days.compactMap { d in d.sleepMinutes.map { (d.day, $0 / 60) } }, uniquingKeysWith: { a, _ in a })
            label = "\(factor.name)的那晚"
            (others, metric, unit, margin, expectHigher) = ("其他晚上", "平均睡", " 小时", 0.2, cause == .exercise)
        case .kidney:
            return nil
        }
        var with: [Double] = [], without: [Double] = []
        for d in c.days where !d.isIll {
            guard let flag = factor.on(d), let y = values[d.day.adding(days: factor.lag)] else { continue }
            if flag { with.append(y) } else { without.append(y) }
        }
        guard with.count >= 4, without.count >= 4, let x = Stats.mean(with), let y = Stats.mean(without) else { return nil }
        func show(_ v: Double) -> String { o == .bp ? "\(Int(v.rounded()))" : v.oneDecimal }
        let compared = "\(label)\(metric) \(show(x))\(unit)，\(others) \(show(y))\(unit)"
        let shows = (expectHigher ? x - y : y - x) >= margin
        return shows ? "从你的记录看，\(compared)（观察到的关联，不一定是原因）。" : "从你的记录还看不出这个影响：\(compared)。"
    }

    private static func sources(_ e: AskedEffect) -> [String] {
        e.outcomes.map { o in
            switch o {
            case .bp: "血压记录"
            case .glucose: "血糖记录"
            case .sleep: "睡眠记录"
            case .kidney: "化验结果"
            }
        } + ["健康常识"]
    }

    private static func destination(_ o: AskedEffect.Outcome) -> AgentDestination {
        switch o {
        case .bp: .vitals
        case .glucose: .glucose
        case .sleep: .sleep
        case .kidney: .labs
        }
    }

    /// The topic an answer counts under: what the model sees alongside it, the chips under it.
    private static func topic(_ e: AskedEffect) -> AgentIntent {
        switch e.cause {
        case .alcohol: .alcohol
        case .caffeine, .tea: .caffeine
        case .water: .diet
        case .walk, .exercise: .exercise
        case .shortSleep: .sleep
        case .stress: .stress
        case .salt, .weightLoss, .spicy, .lateMeal: .diet
        case .smoking, .cold, .highBP: .bp
        case .highGlucose: .glucose
        }
    }
}
