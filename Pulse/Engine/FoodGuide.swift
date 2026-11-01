import Foundation

// MARK: - Foods

/// A food or dish the user asks about (「我能吃香蕉吗」「可以吃火锅吗」) and what in it matters for
/// common conditions. Patient-education level: which nutrient, why it matters for this person,
/// and an easier way to eat it. Amounts stay with the doctor (我的 › 饮食限制).
struct Food: Equatable {
    enum Carb: Equatable { case none, fruit, starch, sweet }
    enum Concern: Hashable, CaseIterable { case potassium, phosphorus, salt, sugar, purine, fat, fluid, protein }

    let name: String
    let aliases: [String]
    var potassium = false
    var phosphorus = false
    var salty = false
    var carb: Carb = .none
    var purine = false
    var fatty = false
    var fluid = false
    var protein = false
    /// A dish (火锅, 烧烤): how it is eaten matters more than whether.
    var dish = false
    /// A category (水果, 外卖): which kind is eaten decides.
    var varies = false
    /// Ways to eat it with less of one concern.
    var tips: [Concern: String] = [:]
    /// What it is good for around training, for someone with nothing against it.
    var sport: String? = nil
    /// Where the salt and the purine are in a dish (「锅底、调料和蘸料」).
    var saltIn: String? = nil
    var purineIn: String? = nil

    /// 「可以喝」 for drinks, 「可以吃」 for the rest.
    var verb: String { ["奶茶", "可乐", "含糖饮料", "豆浆", "牛奶", "浓汤", "酸奶"].contains(name) ? "喝" : "吃" }
}

enum FoodGuide {
    static let foods: [Food] = [
        Food(name: "香蕉", aliases: ["香蕉"], potassium: true, carb: .fruit, sport: "跑步前 30–60 分钟吃一根，补充好消化的碳水；长距离后吃也合适。"),
        Food(name: "橙子", aliases: ["橙子", "橘子", "桔子", "橙汁", "柑橘"], potassium: true, carb: .fruit),
        Food(name: "猕猴桃", aliases: ["猕猴桃", "奇异果"], potassium: true, carb: .fruit),
        Food(name: "哈密瓜", aliases: ["哈密瓜", "甜瓜"], potassium: true, carb: .fruit),
        Food(name: "榴莲", aliases: ["榴莲"], potassium: true, carb: .fruit, fatty: true),
        Food(name: "红枣和果干", aliases: ["红枣", "大枣", "葡萄干", "果干", "蜜饯"], potassium: true, carb: .sweet),
        Food(name: "西瓜", aliases: ["西瓜"], carb: .fruit, fluid: true),
        Food(name: "苹果", aliases: ["苹果"], carb: .fruit),
        Food(name: "梨", aliases: ["梨"], carb: .fruit),
        Food(name: "葡萄", aliases: ["葡萄"], carb: .fruit),
        Food(name: "草莓", aliases: ["草莓", "蓝莓"], carb: .fruit),
        Food(name: "水果", aliases: ["水果"], potassium: true, carb: .fruit, varies: true),
        Food(name: "土豆", aliases: ["土豆", "马铃薯"], potassium: true, carb: .starch,
             tips: [.potassium: "切小块，先泡水或焯水再做，钾会少一些"]),
        Food(name: "红薯", aliases: ["红薯", "地瓜", "紫薯", "山药", "芋头"], potassium: true, carb: .starch,
             tips: [.potassium: "切小块焯水后再做，钾会少一些", .sugar: "当主食吃，吃了它就少吃点米饭"]),
        Food(name: "西红柿", aliases: ["西红柿", "番茄"], potassium: true),
        Food(name: "菠菜", aliases: ["菠菜", "苋菜", "空心菜"], potassium: true, tips: [.potassium: "先焯水再炒，钾会少一些"]),
        Food(name: "菌菇", aliases: ["蘑菇", "香菇", "菌菇", "金针菇", "杏鲍菇"], potassium: true, tips: [.potassium: "焯水后再做，量少一点"]),
        Food(name: "坚果", aliases: ["坚果", "花生", "瓜子", "核桃", "杏仁", "腰果"], potassium: true, phosphorus: true, fatty: true,
             tips: [.fat: "一天一小把（约 15 g），选原味的"]),
        Food(name: "豆腐", aliases: ["豆腐", "豆制品", "豆干", "腐竹", "黄豆"], protein: true),
        Food(name: "豆浆", aliases: ["豆浆"], fluid: true, protein: true),
        Food(name: "牛奶", aliases: ["牛奶", "奶粉"], potassium: true, phosphorus: true, fluid: true, protein: true),
        Food(name: "酸奶", aliases: ["酸奶"], phosphorus: true, protein: true, tips: [.sugar: "选无糖的"]),
        Food(name: "奶酪", aliases: ["奶酪", "芝士"], phosphorus: true, salty: true, fatty: true, protein: true),
        Food(name: "鸡蛋", aliases: ["鸡蛋", "鸭蛋", "蛋黄"], protein: true),
        Food(name: "肥肉", aliases: ["肥肉", "五花肉", "红烧肉", "肥牛"], fatty: true, protein: true),
        Food(name: "肉", aliases: ["牛肉", "猪肉", "羊肉", "瘦肉", "鸡肉", "鸡胸", "鸭肉", "鱼肉", "吃鱼", "排骨"], protein: true),
        Food(name: "海鲜", aliases: ["海鲜", "虾", "螃蟹", "生蚝", "蛤蜊", "扇贝"], phosphorus: true, purine: true, protein: true),
        Food(name: "动物内脏", aliases: ["内脏", "猪肝", "鸡肝", "腰子", "肥肠", "毛肚", "鸡胗"], phosphorus: true, purine: true, protein: true),
        Food(name: "火锅", aliases: ["火锅", "麻辣烫", "串串"], potassium: true, phosphorus: true, salty: true, carb: .none, purine: true,
             fatty: true, fluid: true, protein: true, dish: true,
             tips: [.salt: "锅底选清汤，汤不要喝；蘸料用醋、蒜、葱、香菜，少放酱料和芝麻酱",
                    .potassium: "菌菇、土豆、绿叶菜这些含钾多的少涮",
                    .phosphorus: "丸子、午餐肉这类加工肉少点",
                    .purine: "久煮的锅底汤嘌呤很高，汤别喝，海鲜和内脏少点",
                    .fat: "红油锅底和肥牛少点",
                    .protein: "肉按平时一餐的量吃，别一顿吃太多"],
             saltIn: "锅底、调料和蘸料", purineIn: "久煮的锅底汤和海鲜、内脏"),
        Food(name: "烧烤", aliases: ["烧烤", "烤串", "撸串", "烤肉"], salty: true, purine: true, fatty: true, protein: true, dish: true,
             tips: [.salt: "少刷酱、少撒盐和孜然粉", .fat: "多点烤蔬菜，少点五花和肥肉", .purine: "海鲜和内脏少点，别配啤酒"],
             saltIn: "腌料和刷的酱", purineIn: "烤海鲜和内脏"),
        Food(name: "咸菜", aliases: ["咸菜", "榨菜", "腌菜", "酱菜", "泡菜", "腐乳", "咸鸭蛋", "咸鱼"], salty: true,
             tips: [.salt: "换成凉拌黄瓜这类不腌的小菜"]),
        Food(name: "腊肉香肠", aliases: ["腊肉", "香肠", "火腿", "午餐肉", "培根", "腊肠"], phosphorus: true, salty: true, fatty: true,
             tips: [.salt: "当调味用几片，不当主菜"]),
        Food(name: "方便面", aliases: ["方便面", "泡面", "螺蛳粉"], salty: true, carb: .starch, fatty: true,
             tips: [.salt: "调料包只放一半，汤不喝", .sugar: "加个鸡蛋和一把青菜一起吃"]),
        Food(name: "外卖", aliases: ["外卖", "快餐", "下馆子"], salty: true, fatty: true, dish: true, varies: true,
             tips: [.salt: "备注少盐少油，汤汁不拌饭", .sugar: "米饭吃一半，多点一份青菜"], saltIn: "外卖的菜"),
        Food(name: "浓汤", aliases: ["老火汤", "骨头汤", "浓汤", "高汤", "鸡汤"], potassium: true, purine: true, fluid: true,
             tips: [.purine: "汤里的嘌呤比肉还多，喝一小碗就好"]),
        Food(name: "粥", aliases: ["粥", "稀饭"], carb: .starch, fluid: true, tips: [.sugar: "白粥升糖快，换成杂粮粥，配鸡蛋或豆腐一起吃"]),
        Food(name: "主食", aliases: ["米饭", "面条", "馒头", "面包", "主食", "包子", "饺子"], carb: .starch, varies: true),
        Food(name: "可乐", aliases: ["可乐"], phosphorus: true, carb: .sweet, fluid: true, tips: [.sugar: "换成无糖的气泡水"]),
        Food(name: "含糖饮料", aliases: ["汽水", "饮料", "果汁", "雪碧"], carb: .sweet, fluid: true, tips: [.sugar: "换成无糖的气泡水或淡茶"]),
        Food(name: "奶茶", aliases: ["奶茶"], carb: .sweet, fatty: true, fluid: true, tips: [.sugar: "点无糖或三分糖的小杯，不加小料"]),
        Food(name: "甜食", aliases: ["蛋糕", "甜点", "甜食", "糖果", "冰淇淋", "雪糕", "月饼", "饼干", "蜂蜜"], carb: .sweet, fatty: true),
        Food(name: "巧克力", aliases: ["巧克力"], potassium: true, phosphorus: true, carb: .sweet, fatty: true),
        Food(name: "薯片", aliases: ["薯片", "薯条", "零食"], potassium: true, salty: true, fatty: true),
    ]

    /// The food a question names; the longest name wins (「葡萄干」 over 「葡萄」).
    static func find(in q: String) -> Food? {
        var best: (Food, Int)? = nil
        for f in foods {
            for a in f.aliases where q.contains(a) && a.count > (best?.1 ?? 0) { best = (f, a.count) }
        }
        return best?.0
    }

    // MARK: Reading a food for one person

    private enum Level: Int, Comparable {
        case fine, portion, limit, avoid
        static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }
    }

    static func reply(_ f: Food, _ a: AgentQuestion, context c: AgentContext) -> AgentReply {
        let p = c.profile
        let v = f.verb
        let df = Date.FormatStyle().month().day()
        let k = c.lab(.potassium, within: 180)
        let kHigh = k.map { $0.value > 5.0 } ?? false
        // A recent result decides over a recorded condition (「低血钾症」 recorded, potassium 5.4).
        let lowK = !kHigh && (p.extraConditions.contains { $0.id == "hypokalemia" } || (k.map { $0.value < 3.5 } ?? false))
        let limitsK = !lowK && (p.limitsPotassium || kHigh)
        let phos = c.lab(.phosphorus, within: 180)
        let limitsP = p.limitsPhosphorus || (phos.map { $0.value > 1.45 } ?? false)
        let saltReasons = [HealthCondition.hypertension, .ckd, .heartFailure].filter { p.conditions.contains($0) }.map(\.label)
        let diabetes = p.hasDiabetes || p.conditions.contains(.prediabetes)
        let ua = c.lab(.uricAcid, within: 365)
        let gout = p.extraConditions.contains { $0.id == "gout" }
        let uricHigh = gout || (ua.map { $0.value > 420 } ?? false)

        var level = Level.fine
        var reasons: [String] = []
        var concerns: [Food.Concern] = []
        func flag(_ l: Level, _ concern: Food.Concern, _ why: String) {
            level = max(level, l)
            reasons.append(why)
            concerns.append(concern)
        }

        if f.potassium && limitsK {
            var why = f.varies ? "有些\(f.name)含钾高" : (f.dish ? "涮的菌菇、土豆、绿叶菜含钾高" : "\(f.name)含钾高")
            if let k, kHigh { why += "，你\(k.date.formatted(df))的血钾 \(k.valueText) 偏高" }
            if p.limitsPotassium { why += kHigh ? "，医生也让你限钾" : "，医生让你限钾" }
            flag(kHigh && !f.varies && !f.dish ? .avoid : .limit, .potassium, why)
        }
        if f.phosphorus && limitsP {
            flag(.limit, .phosphorus, "\(f.name)含磷多，\(phos.map { "你的血磷 \($0.valueText) 偏高" } ?? "医生让你限磷")")
        }
        if f.salty && !saltReasons.isEmpty {
            flag(.limit, .salt, "\(f.saltIn ?? f.name)盐多，你有\(saltReasons.joined(separator: "和"))，每天盐最好不超过 \(p.saltLimitG.noDecimal) g")
        }
        if diabetes {
            switch f.carb {
            case .sweet: flag(.limit, .sugar, "\(f.name)含糖多，升血糖很快")
            case .fruit: flag(.portion, .sugar, "\(f.varies ? "水果" : f.name)含糖，一次吃多了血糖会升得明显")
            case .starch: flag(.portion, .sugar, "\(f.name)是血糖的主要来源，量和吃法决定餐后血糖")
            case .none: break
            }
        }
        if f.purine && uricHigh {
            flag(.limit, .purine, "\(f.purineIn ?? f.name)嘌呤高，\(gout ? "你有痛风" : "你的尿酸 \(ua?.valueText ?? "") 偏高")")
        }
        if f.fluid && p.fluidLimited {
            flag(.portion, .fluid, "汤水要算进每天 \(p.waterTargetMl) ml 的饮水量里")
        }
        if f.fatty && (p.hasCardiac || p.bmi >= 28) && f.dish == false && f.carb != .sweet {
            flag(.portion, .fat, "\(f.name)油脂多")
        }
        if f.protein, let g = p.proteinTargetG, p.conditions.contains(.ckd) {
            flag(.portion, .protein, "肉蛋奶豆要算进每天的蛋白质，医生给你定的是每天约 \(g) g（一份约 7 g）")
        }
        // Several reasons to be careful with one dish make it a 「换个吃法」, not a ban.
        if f.dish, level == .portion, reasons.count >= 2 { level = .limit }

        let verdict: String
        switch level {
        case .avoid: verdict = "\(f.name)最好先不\(v)。"
        case .limit: verdict = f.dish ? "\(f.name)可以偶尔吃，但要换个吃法。" : (f.varies ? "可以\(v)，但要挑种类、控制量。" : "\(f.name)可以\(v)一点，但要少\(v)。")
        case .portion: verdict = f.varies ? "可以\(v)，注意挑种类和量。" : "\(f.name)可以\(v)，注意量。"
        case .fine: verdict = "\(f.name)可以\(v)。"
        }

        var tips: [String] = []
        for concern in Food.Concern.allCases where concerns.contains(concern) {
            if let t = f.tips[concern] { tips.append(t) }
        }
        if concerns.contains(.potassium) {
            if f.carb == .fruit {
                tips.append(f.varies ? "选苹果、梨、草莓这类含钾少一些的，香蕉、橙子、猕猴桃、哈密瓜少吃"
                                     : "想吃水果，可以换成苹果、梨、草莓这类含钾少一些的，一次半个到一个拳头大小")
            }
            if level == .avoid { tips.append("血钾复查正常、医生同意以后，再问清楚每天能吃多少") }
        }
        if concerns.contains(.sugar), f.tips[.sugar] == nil {
            switch f.carb {
            case .fruit: tips.append(concerns.contains(.potassium) && !f.varies ? "放在两餐之间吃，不喝果汁" : "一次一个拳头大小（约 200 g），放在两餐之间吃，不喝果汁")
            case .sweet: tips.append("实在想吃就吃几口，放在饭后而不是空腹，吃完散步 15 分钟")
            case .starch: tips.append("一餐一拳头左右，换一半成粗粮，先吃菜和肉、最后吃主食")
            case .none: break
            }
        }
        if concerns.contains(.sugar), c.glucose.readings > 0 { tips.append("\(v)完 2 小时看一眼血糖，就知道它对你影响多大") }
        if concerns.contains(.salt), f.tips[.salt] == nil { tips.append("这一餐其他菜就少放盐，酱油、蚝油、咸菜也算盐") }
        if concerns.contains(.fluid), f.tips[.fluid] == nil, !concerns.contains(.sugar) { tips.append("喝了汤，当天其他的水就相应少喝一些") }
        if level == .fine, lowK, f.potassium { tips.append("\(f.name)含钾，对血钾偏低的你是加分项") }
        // Nothing against it: still say how much is about right.
        if level == .fine, f.sport == nil || !(p.goals.contains(where: { [.fitness, .event].contains($0) }) || c.weekTrainingsTotal > 0) {
            switch f.carb {
            case .fruit: tips.append("水果一天 200–350 g 左右比较合适，整个吃比榨汁好")
            case .starch: tips.append("一餐一拳头左右，换一部分粗粮更好")
            case .sweet: tips.append("偶尔吃没问题，别当饭吃，也别空腹吃")
            case .none: if f.protein { tips.append("一餐一掌心大小就够") } else if f.salty || f.fatty { tips.append("偶尔吃没问题，别天天吃") }
            }
        }
        if level == .fine, let s = f.sport, p.goals.contains(where: { [.fitness, .event].contains($0) }) || c.weekTrainingsTotal > 0 { tips.append(s) }

        // The two weightiest reasons go with the verdict; the rest follow it.
        let because = reasons.isEmpty ? nil : reasons.prefix(2).joined(separator: "；") + "。"
        let first = verdict + (because ?? "")
        let text = HealthAgent.lines([
            first,
            reasons.count > 2 ? "另外，" + reasons.dropFirst(2).joined(separator: "；") + "。" : nil,
            HealthAgent.bullets(Array(tips.prefix(3))),
            level >= .limit && (p.conditions.contains(.ckd) || p.tracksNutrients) ? "具体每天能\(v)多少，按肾内科医生或营养师给你的要求。" : nil,
        ])
        return AgentReply(text: text, sources: [kHigh || limitsK ? "化验结果" : nil, saltReasons.isEmpty ? nil : "饮食限制", "健康状况"].compactMap { $0 },
                          followUps: diabetes ? ["血糖老是高怎么办？", "今天吃什么好？"] : ["今天吃什么好？"],
                          destination: concerns.contains(.potassium) && !c.labs.isEmpty ? .labs : (diabetes && concerns.contains(.sugar) ? .glucose : nil), intent: .food,
                          conclusion: first,
                          status: level == .avoid ? .attention("先不\(v)") : (level == .limit ? .attention("少\(v)一点") : .good(level == .fine ? "可以\(v)" : "适量\(v)")))
    }
}
