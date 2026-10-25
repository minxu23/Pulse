import Foundation

// 肾脏饮食: salt, protein, potassium and phosphorus, recorded the way people actually can —
// which high-salt, high-potassium and high-phosphorus foods were eaten today, and how many
// servings of meat, eggs, milk and soy (≈ 7 g protein each). Grams of salt only when measured with
// a salt spoon. The amounts to aim for are the doctor's or dietitian's; Pulse only compares.

enum DietFoods {
    static let salt = ["咸菜、腌制品", "酱油、酱料放得多", "香肠、火腿、腊肉", "方便面、速冻食品", "外卖或在外吃", "咸味零食"]
    static let potassium = ["香蕉", "橙子、橘子", "猕猴桃", "土豆、红薯、芋头", "菌菇", "没焯水的绿叶菜", "番茄", "坚果、干果",
                            "豆类", "浓汤、肉汤", "果汁", "低钠盐、代盐"]
    static let phosphorus = ["香肠、午餐肉等加工食品", "可乐等深色汽水", "奶酪、奶制品较多", "动物内脏", "坚果、瓜子", "骨头汤、浓肉汤"]
    /// One serving: an egg, 50 g lean meat or fish, 250 ml milk or 100 g tofu.
    static let proteinPerServing = 7.0
    static let servingHint = "1 份 ≈ 1 个鸡蛋 / 50 g 瘦肉或鱼 / 250 ml 牛奶 / 100 g 豆腐，约 7 g 蛋白质；主食和蔬菜里的蛋白质不算在内。"
}

struct NutrientLine: Equatable {
    enum Tone: Equatable { case good, attention, neutral }
    var tone: Tone
    var text: String
}

/// The last 7 days of recorded kidney-diet days.
struct NutrientWeek: Equatable {
    var days: Int
    var saltyDays: Int
    var proteinAvgG: Double?
    var potassiumPerDay: Double
    var phosphorusPerDay: Double
}

enum KidneyDiet {
    /// Too salty: more than the limit when measured, else two or more high-salt foods.
    static func salty(_ d: DayData, limit: Double) -> Bool {
        if let g = d.saltG { return g > limit }
        return d.saltSources.count >= 2
    }

    /// Today's four lines; empty until the day has been recorded.
    static func lines(_ d: DayData, profile p: ProfileSnapshot) -> [NutrientLine] {
        guard d.nutrientsLogged else { return [] }
        var out: [NutrientLine] = []
        let limit = p.saltLimitG
        if let g = d.saltG {
            out.append(g > limit ? .init(tone: .attention, text: "盐约 \(g.oneDecimal) g，超过 \(limit.oneDecimal) g")
                                 : .init(tone: .good, text: "盐约 \(g.oneDecimal) g（不超过 \(limit.oneDecimal) g）"))
        } else {
            switch d.saltSources.count {
            case 0: out.append(.init(tone: .good, text: "没有记录高盐食物"))
            case 1: out.append(.init(tone: .neutral, text: "1 样高盐食物：\(d.saltSources[0])"))
            default: out.append(.init(tone: .attention, text: "偏咸：\(d.saltSources.prefix(2).joined(separator: "；"))\(d.saltSources.count > 2 ? " 等 \(d.saltSources.count) 样" : "")"))
            }
        }
        if let s = d.proteinServings {
            let g = s * DietFoods.proteinPerServing
            if let t = p.proteinTargetG {
                let target = Double(t)
                if g > target * 1.15 { out.append(.init(tone: .attention, text: "蛋白质约 \(Int(g)) g，超过医生定的 \(t) g")) }
                else if g < target * 0.6 { out.append(.init(tone: .attention, text: "蛋白质约 \(Int(g)) g，明显少于医生定的 \(t) g")) }
                else { out.append(.init(tone: .good, text: "蛋白质约 \(Int(g)) g（医生定的 \(t) g）")) }
            } else {
                out.append(.init(tone: .neutral, text: "蛋白质约 \(Int(g)) g（肉蛋奶豆 \(s.oneDecimal) 份）"))
            }
        }
        out.append(foods(d.potassiumFoods, name: "高钾", limited: p.limitsPotassium))
        out.append(foods(d.phosphorusFoods, name: "高磷", limited: p.limitsPhosphorus))
        return out
    }

    private static func foods(_ list: [String], name: String, limited: Bool) -> NutrientLine {
        guard !list.isEmpty else { return .init(tone: limited ? .good : .neutral, text: "没有\(name)食物") }
        let text = "\(name)食物 \(list.count) 样：\(list.prefix(2).joined(separator: "；"))\(list.count > 2 ? " 等" : "")"
        return .init(tone: limited && list.count >= 2 ? .attention : .neutral, text: text)
    }

    static func week(_ days: [DayData], profile p: ProfileSnapshot, now: Date = .app) -> NutrientWeek? {
        let end = now.startOfDay
        let recent = days.filter { $0.day > end.adding(days: -7) && $0.day <= end && $0.nutrientsLogged }
        guard !recent.isEmpty else { return nil }
        let protein = recent.compactMap(\.proteinServings).map { $0 * DietFoods.proteinPerServing }
        let n = Double(recent.count)
        return NutrientWeek(days: recent.count,
                            saltyDays: recent.filter { salty($0, limit: p.saltLimitG) }.count,
                            proteinAvgG: protein.isEmpty ? nil : protein.reduce(0, +) / Double(protein.count),
                            potassiumPerDay: Double(recent.map(\.potassiumFoods.count).reduce(0, +)) / n,
                            phosphorusPerDay: Double(recent.map(\.phosphorusFoods.count).reduce(0, +)) / n)
    }

    /// One line for the language models and the clinician summary.
    static func digest(_ days: [DayData], profile p: ProfileSnapshot, now: Date = .app) -> String? {
        guard p.tracksNutrients, let w = week(days, profile: p, now: now) else { return nil }
        var parts = ["偏咸 \(w.saltyDays) 天（盐上限 \(p.saltLimitG.oneDecimal) g）"]
        if let g = w.proteinAvgG { parts.append("蛋白质平均约 \(Int(g)) g/天" + (p.proteinTargetG.map { "（医生定的 \($0) g）" } ?? "")) }
        parts.append("高钾食物平均 \(w.potassiumPerDay.oneDecimal) 样/天\(p.limitsPotassium ? "（需要限钾）" : "")")
        parts.append("高磷食物平均 \(w.phosphorusPerDay.oneDecimal) 样/天\(p.limitsPhosphorus ? "（需要限磷）" : "")")
        return "肾脏饮食（近 7 天记录了 \(w.days) 天）：" + parts.joined(separator: "；")
    }
}
