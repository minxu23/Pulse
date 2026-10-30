import Foundation

// 肾脏饮食: salt, protein, potassium and phosphorus, recorded the way people actually can —
// portions of everyday foods (an egg, a bowl of rice, a banana), each with rough amounts, so a day
// adds up to grams of protein and milligrams of potassium and phosphorus from the high-potassium
// and high-phosphorus foods. Grams of salt only when measured with a salt spoon. The amounts to aim
// for are the doctor's or dietitian's; Pulse only compares.

/// A food counted in portions, with rough amounts per portion (Chinese food composition tables,
/// rounded): estimates to compare days with, not a nutrition label.
struct DietFood: Equatable {
    let name: String
    /// 「1 根」「1 两（50 g 生）」.
    let portion: String
    var proteinG = 0.0
    var potassiumMg = 0
    var phosphorusMg = 0
}

enum DietFoods {
    static let salt = ["咸菜、腌制品", "酱油、酱料放得多", "香肠、火腿、腊肉", "方便面、速冻食品", "外卖或在外吃", "咸味零食"]
    static let potassiumFoods: [DietFood] = [
        .init(name: "香蕉", portion: "1 根", potassiumMg: 300),
        .init(name: "橙子、橘子", portion: "1 个", potassiumMg: 230),
        .init(name: "猕猴桃", portion: "1 个", potassiumMg: 230),
        .init(name: "土豆、红薯、芋头", portion: "1 个拳头大", potassiumMg: 450),
        .init(name: "菌菇", portion: "1 小碗", potassiumMg: 300),
        .init(name: "没焯水的绿叶菜", portion: "1 碗", potassiumMg: 450),
        .init(name: "番茄", portion: "1 个", potassiumMg: 250),
        .init(name: "坚果、干果", portion: "1 小把", potassiumMg: 200),
        .init(name: "豆类", portion: "1 小碗", potassiumMg: 400),
        .init(name: "浓汤、肉汤", portion: "1 碗", potassiumMg: 350),
        .init(name: "果汁", portion: "1 杯", potassiumMg: 450),
        .init(name: "低钠盐、代盐", portion: "做菜用了", potassiumMg: 500),
    ]
    static let phosphorusFoods: [DietFood] = [
        .init(name: "香肠、午餐肉等加工食品", portion: "1 份（约 50 g）", phosphorusMg: 150),
        .init(name: "可乐等深色汽水", portion: "1 罐", phosphorusMg: 50),
        .init(name: "奶酪、奶制品较多", portion: "1 片奶酪或 1 杯奶", phosphorusMg: 180),
        .init(name: "动物内脏", portion: "1 两", phosphorusMg: 150),
        .init(name: "坚果、瓜子", portion: "1 小把", phosphorusMg: 130),
        .init(name: "骨头汤、浓肉汤", portion: "1 碗", phosphorusMg: 80),
    ]
    /// Where the day's protein comes from, staples included — they add up to about a third of it.
    static let proteinFoods: [DietFood] = [
        .init(name: "鸡蛋", portion: "1 个", proteinG: 6),
        .init(name: "牛奶、酸奶", portion: "1 杯 250 ml", proteinG: 7),
        .init(name: "瘦肉", portion: "1 两（50 g 生）", proteinG: 10),
        .init(name: "鱼虾", portion: "1 两（50 g 生）", proteinG: 9),
        .init(name: "豆腐、豆制品", portion: "1 块（100 g）", proteinG: 8),
        .init(name: "豆浆", portion: "1 杯 250 ml", proteinG: 5),
        .init(name: "米饭", portion: "1 碗（约 150 g 熟）", proteinG: 4),
        .init(name: "馒头、包子、饼", portion: "1 个（约 100 g）", proteinG: 7),
        .init(name: "面条", portion: "1 碗（约 200 g 熟）", proteinG: 7),
        .init(name: "蔬菜", portion: "1 碗", proteinG: 2),
    ]
    static let potassium = potassiumFoods.map(\.name)
    static let phosphorus = phosphorusFoods.map(\.name)
    /// Days recorded before foods were counted: 「肉蛋奶豆 N 份」, ≈ 7 g protein each.
    static let proteinPerServing = 7.0
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
    /// Portions of high-potassium / high-phosphorus foods a day, and what they add up to.
    var potassiumPerDay: Double
    var phosphorusPerDay: Double
    var potassiumMgPerDay: Double
    var phosphorusMgPerDay: Double
}

enum KidneyDiet {
    /// Portions in the order first eaten: 「香蕉」「香蕉」「番茄」 → 香蕉 ×2, 番茄 ×1.
    static func counted(_ list: [String]) -> [(name: String, n: Int)] {
        var out: [(name: String, n: Int)] = []
        for f in list {
            if let i = out.firstIndex(where: { $0.name == f }) { out[i].n += 1 } else { out.append((f, 1)) }
        }
        return out
    }

    /// 「香蕉 ×2；番茄」.
    static func names(_ list: [String], limit: Int = 2) -> String {
        let c = counted(list)
        return c.prefix(limit).map { $0.n > 1 ? "\($0.name) ×\($0.n)" : $0.name }.joined(separator: "；") + (c.count > limit ? " 等" : "")
    }

    private static func total<T: Numeric>(_ list: [String], in foods: [DietFood], _ amount: KeyPath<DietFood, T>) -> T {
        list.reduce(0) { sum, name in sum + (foods.first { $0.name == name }?[keyPath: amount] ?? 0) }
    }
    static func potassiumMg(_ list: [String]) -> Int { total(list, in: DietFoods.potassiumFoods, \.potassiumMg) }
    static func phosphorusMg(_ list: [String]) -> Int { total(list, in: DietFoods.phosphorusFoods, \.phosphorusMg) }

    /// The day's protein: from the foods counted, or from an older 「肉蛋奶豆 N 份」 record.
    static func proteinG(_ d: DayData) -> Double? {
        d.proteinFoods.isEmpty ? d.proteinServings.map { $0 * DietFoods.proteinPerServing } : total(d.proteinFoods, in: DietFoods.proteinFoods, \.proteinG)
    }

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
        if let g = proteinG(d) {
            if let t = p.proteinTargetG {
                let target = Double(t)
                if g > target * 1.15 { out.append(.init(tone: .attention, text: "蛋白质约 \(Int(g)) g，超过医生定的 \(t) g")) }
                else if g < target * 0.6 { out.append(.init(tone: .attention, text: "蛋白质约 \(Int(g)) g，明显少于医生定的 \(t) g")) }
                else { out.append(.init(tone: .good, text: "蛋白质约 \(Int(g)) g（医生定的 \(t) g）")) }
            } else {
                let from = d.proteinFoods.isEmpty ? "肉蛋奶豆 \((d.proteinServings ?? 0).oneDecimal) 份" : names(d.proteinFoods)
                out.append(.init(tone: .neutral, text: "蛋白质约 \(Int(g)) g（\(from)）"))
            }
        }
        out.append(foods(d.potassiumFoods, name: "高钾", mg: potassiumMg(d.potassiumFoods), nutrient: "钾", limited: p.limitsPotassium))
        out.append(foods(d.phosphorusFoods, name: "高磷", mg: phosphorusMg(d.phosphorusFoods), nutrient: "磷", limited: p.limitsPhosphorus))
        return out
    }

    /// Portions of high-potassium or high-phosphorus foods; two or more need attention when limited.
    private static func foods(_ list: [String], name: String, mg: Int, nutrient: String, limited: Bool) -> NutrientLine {
        guard !list.isEmpty else { return .init(tone: limited ? .good : .neutral, text: "没有\(name)食物") }
        let text = "\(name)食物 \(list.count) 份（约 \(mg) mg \(nutrient)）：\(names(list))"
        return .init(tone: limited && list.count >= 2 ? .attention : .neutral, text: text)
    }

    static func week(_ days: [DayData], profile p: ProfileSnapshot, now: Date = .app) -> NutrientWeek? {
        let end = now.startOfDay
        let recent = days.filter { $0.day > end.adding(days: -7) && $0.day <= end && $0.nutrientsLogged }
        guard !recent.isEmpty else { return nil }
        let protein = recent.compactMap(proteinG)
        let n = Double(recent.count)
        func perDay(_ f: (DayData) -> Int) -> Double { Double(recent.map(f).reduce(0, +)) / n }
        return NutrientWeek(days: recent.count,
                            saltyDays: recent.filter { salty($0, limit: p.saltLimitG) }.count,
                            proteinAvgG: protein.isEmpty ? nil : protein.reduce(0, +) / Double(protein.count),
                            potassiumPerDay: perDay { $0.potassiumFoods.count },
                            phosphorusPerDay: perDay { $0.phosphorusFoods.count },
                            potassiumMgPerDay: perDay { potassiumMg($0.potassiumFoods) },
                            phosphorusMgPerDay: perDay { phosphorusMg($0.phosphorusFoods) })
    }

    /// One line for the language models and the clinician summary.
    static func digest(_ days: [DayData], profile p: ProfileSnapshot, now: Date = .app) -> String? {
        guard p.tracksNutrients, let w = week(days, profile: p, now: now) else { return nil }
        var parts = ["偏咸 \(w.saltyDays) 天（盐上限 \(p.saltLimitG.oneDecimal) g）"]
        if let g = w.proteinAvgG { parts.append("蛋白质平均约 \(Int(g)) g/天" + (p.proteinTargetG.map { "（医生定的 \($0) g）" } ?? "")) }
        parts.append("高钾食物平均 \(w.potassiumPerDay.oneDecimal) 份/天，约 \(Int(w.potassiumMgPerDay)) mg 钾\(p.limitsPotassium ? "（需要限钾）" : "")")
        parts.append("高磷食物平均 \(w.phosphorusPerDay.oneDecimal) 份/天，约 \(Int(w.phosphorusMgPerDay)) mg 磷\(p.limitsPhosphorus ? "（需要限磷）" : "")")
        return "肾脏饮食（近 7 天记录了 \(w.days) 天）：" + parts.joined(separator: "；")
    }
}
