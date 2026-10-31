import Foundation

// MARK: - What a question asks

/// What a question asks, read before an answer is chosen: its form (能不能 / 要不要紧 / 为什么 /
/// 怎么办) and the things it names — a reading, a food, a symptom. Answers start from these, so
/// 「今天早上血压155，要紧吗」 is answered about 155, not with the 30-day summary.
struct AgentQuestion {
    enum Form: Equatable { case canI, isItOK, why, how, howIsIt, explain, plain }

    enum Reading: Equatable {
        case bp(sys: Int, dia: Int?)
        case glucose(Double, MeasureContext?)
        case sleepHours(Double)
        case weightChange(kg: Double)
        /// 「体重 72.5 公斤」: a weight, not a change.
        case weight(kg: Double)
        /// 「糖化血红蛋白 53 mmol/mol」: a lab value as on the report; `unit` as typed or guessed.
        case lab(LabKind, value: Double, unit: String, guessed: Bool)
    }

    let text: String
    let form: Form
    let reading: Reading?
    let food: Food?
    let symptom: AskedSymptom?

    init(_ question: String) {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        text = q
        form = Self.form(of: q)
        reading = Self.reading(in: q)
        symptom = AskedSymptom.find(in: q)
        // A food only counts when the question is about eating it.
        let eating = ["吃", "喝", "能", "可以", "好吗", "行吗", "要紧", "正常"].contains { q.contains($0) }
        food = eating ? FoodGuide.find(in: q) : nil
    }

    func has(_ words: [String]) -> Bool { words.contains { text.contains($0) } }

    // MARK: Form

    static func form(of q: String) -> Form {
        func any(_ w: [String]) -> Bool { w.contains { q.contains($0) } }
        if any(["怎么算", "怎么计算", "怎么来的", "什么意思", "是什么", "什么是", "讲讲", "解释一下", "介绍一下"]) { return .explain }
        if any(["为什么", "为啥", "怎么回事", "什么原因", "怎么会"]) { return .why }
        if any(["正常吗", "正常不", "要紧吗", "要不要紧", "严重吗", "危险吗", "有问题吗", "有事吗", "没事吧", "高吗", "低吗", "算高", "算低"]) { return .isItOK }
        if any(["怎么办", "怎么才能", "怎么降", "怎么改善", "怎么做", "怎样", "如何", "技巧", "办法", "方法", "有什么建议", "怎么安排", "怎么调"]) { return .how }
        if any(["能不能", "可不可以", "可以吃", "能吃", "能喝", "可以喝", "要不要", "还要", "还能", "适合", "行吗", "好吗", "可以吗", "行不行"])
            || q.range(of: "(能|可以).{0,8}吗", options: .regularExpression) != nil { return .canI }
        if any(["怎么样", "好不好", "进步", "控制得", "有没有改善", "改善了吗", "变好"]) { return .howIsIt }
        return .plain
    }

    // MARK: Numbers in the question

    /// 「155」「155/95」「高压155低压95」, 「血糖12」「餐后血糖 11.5」, 「只睡了5个小时」「睡了五个半小时」,
    /// 「体重涨了两斤」「重了1公斤」.
    static func reading(in q: String) -> Reading? {
        if ["血压", "高压", "低压", "收缩压", "舒张压"].contains(where: { q.contains($0) }) {
            if let g = groups(#"(\d{2,3})\s*[/／]\s*(\d{2,3})"#, q), let s = Int(g[0]), let d = Int(g[1]), (70...280).contains(s) {
                return .bp(sys: s, dia: d)
            }
            let hi = groups(#"(?:高压|收缩压)\D{0,3}(\d{2,3})"#, q).flatMap { Int($0[0]) }
            let lo = groups(#"(?:低压|舒张压)\D{0,3}(\d{2,3})"#, q).flatMap { Int($0[0]) }
            if let s = hi, (70...280).contains(s) { return .bp(sys: s, dia: lo) }
            if let g = groups(#"血压\D{0,6}(\d{2,3})"#, q), let s = Int(g[0]), (70...280).contains(s) { return .bp(sys: s, dia: nil) }
        }
        if let g = groups(#"血糖[^0-9]{0,8}(\d{1,2}(?:\.\d)?)"#, q), let v = Double(g[0]), (1.0...35).contains(v) {
            return .glucose(v, glucoseContext(q))
        }
        if let g = groups(#"睡了?\s*(?:不到|不足|才|只有|大概|约)?\s*([0-9一二两三四五六七八九十]+(?:\.\d)?)\s*个?(半)?\s*(?:多)?\s*(?:小时|钟头|h)"#, q), let h = number(g[0]) {
            return .sleepHours(h + (g.count > 1 && g[1] == "半" ? 0.5 : 0))
        }
        if let g = groups(#"(?:涨|胖|长|(?<!体)重|增加|多)了?\s*([0-9一二两三四五六七八九十]+(?:\.\d)?)\s*(斤|公斤|千克|kg)"#, q), let n = number(g[0]) {
            return .weightChange(kg: g[1] == "斤" ? n / 2 : n)
        }
        if let g = groups(#"(?:体重|称了|称出来)\D{0,4}(\d{2,3}(?:\.\d+)?)\s*(斤|公斤|千克|kg|KG)?"#, q), let n = Double(g[0]) {
            let kg = g.count > 1 && g[1] == "斤" ? n / 2 : n
            if (25...250).contains(kg) { return .weight(kg: kg) }
        }
        if let l = lab(in: q) { return l }
        return nil
    }

    /// The names a lab report uses, longest first so 「糖化血红蛋白」 is not read as 血红蛋白.
    static let labNames: [(LabKind, [String])] = [
        (.hba1c, ["糖化血红蛋白", "HbA1c", "hba1c", "糖化"]), (.uacr, ["尿白蛋白肌酐比", "尿白蛋白/肌酐比", "尿微量白蛋白", "UACR", "ACR", "尿白蛋白"]),
        (.egfr, ["eGFR", "egfr", "肾小球滤过率"]), (.creatinine, ["肌酐"]), (.potassium, ["血钾", "钾离子"]), (.phosphorus, ["血磷"]),
        (.hemoglobin, ["血红蛋白"]), (.uricAcid, ["尿酸"]),
    ]

    /// 「肌酐 1.44 mg/dL」「糖化血红蛋白 53」: the test, the value, and its unit — as typed, or the
    /// unit the value fits (1.44 is no creatinine in μmol/L; 53 is no HbA1c in %).
    static func lab(in q: String) -> Reading? {
        for (kind, names) in labNames {
            guard let name = names.first(where: { q.contains($0) }) else { continue }
            let units = #"(mg/dL|mg/dl|μmol/L|umol/L|µmol/L|mmol/mol|mmol/L|mg/mmol|mg/g|g/dL|g/dl|g/L|%)?"#
            guard let g = groups(NSRegularExpression.escapedPattern(for: name) + #"[^0-9]{0,6}(\d+(?:\.\d+)?)\s*"# + units, q), let v = Double(g[0]) else { return nil }
            let typed = g.count > 1 ? g[1].replacingOccurrences(of: "u", with: "μ").replacingOccurrences(of: "µ", with: "μ") : ""
            if let u = kind.units.first(where: { $0.lowercased() == typed.lowercased() }) {
                return .lab(kind, value: v, unit: u, guessed: false)
            }
            let fits = kind.units.first { kind.plausible.contains(kind.standard(v, unit: $0)) }
            return fits.map { .lab(kind, value: v, unit: $0, guessed: true) }
        }
        return nil
    }

    static func glucoseContext(_ q: String) -> MeasureContext? {
        if ["餐后", "饭后", "吃完", "吃过饭", "吃饭后"].contains(where: { q.contains($0) }) { return .postMeal }
        if ["空腹", "早上起来", "起床后", "晨起", "早上没吃"].contains(where: { q.contains($0) }) { return .fasting }
        if ["饭前", "餐前"].contains(where: { q.contains($0) }) { return .preMeal }
        if q.contains("睡前") { return .bedtime }
        if ["半夜", "夜里", "凌晨"].contains(where: { q.contains($0) }) { return .night }
        if ["运动前", "跑步前", "练之前"].contains(where: { q.contains($0) }) { return .preExercise }
        return nil
    }

    /// Which meal a question names, as the hours its readings fall in.
    static func meal(_ q: String) -> (name: String, hours: Range<Int>)? {
        if ["晚饭", "晚餐"].contains(where: { q.contains($0) }) { return ("晚饭", 19..<23) }
        if ["午饭", "午餐", "中饭"].contains(where: { q.contains($0) }) { return ("午饭", 12..<16) }
        if ["早饭", "早餐"].contains(where: { q.contains($0) }) { return ("早饭", 8..<11) }
        return nil
    }

    static func groups(_ pattern: String, _ s: String) -> [String]? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return nil }
        return (1..<m.numberOfRanges).map { i in Range(m.range(at: i), in: s).map { String(s[$0]) } ?? "" }
    }

    /// Digits or a small Chinese number (「五」「两」「十一」).
    static func number(_ s: String) -> Double? {
        if let d = Double(s) { return d }
        let digit: [Character: Double] = ["一": 1, "二": 2, "两": 2, "三": 3, "四": 4, "五": 5, "六": 6, "七": 7, "八": 8, "九": 9]
        if s == "十" { return 10 }
        if s.hasPrefix("十"), let last = s.last, let d = digit[last] { return 10 + d }
        if s.count == 1, let c = s.first, let d = digit[c] { return d }
        return nil
    }
}

// MARK: - Symptoms

enum AskedSymptom: String, CaseIterable {
    case fatigue, dizzy, swelling, cold, pain, soreness, palpitations, cramps, thirst, urine, headache
    /// Common with kidney disease: itchy skin, no appetite, getting up at night to pass urine.
    case itch, appetite, nocturia

    var label: String {
        switch self {
        case .fatigue: "累"
        case .dizzy: "头晕"
        case .swelling: "水肿"
        case .cold: "感冒"
        case .pain: "疼痛"
        case .soreness: "肌肉酸"
        case .palpitations: "心慌"
        case .cramps: "抽筋"
        case .thirst: "口渴"
        case .urine: "尿的变化"
        case .headache: "头疼"
        case .itch: "皮肤痒"
        case .appetite: "没胃口"
        case .nocturia: "起夜"
        }
    }

    /// The first symptom a question names; emergencies (胸痛, 晕倒…) are caught before this.
    static func find(in q: String) -> AskedSymptom? {
        func any(_ w: [String]) -> Bool { w.contains { q.contains($0) } }
        if any(["头晕", "头昏", "眩晕", "发晕", "晕乎", "眼前发黑", "站起来晕"]) || q.range(of: "头[^，。？]{0,3}晕", options: .regularExpression) != nil { return .dizzy }
        if any(["水肿", "浮肿"]) || q.range(of: "(脚|腿|踝|脸|眼皮|手).{0,4}肿", options: .regularExpression) != nil { return .swelling }
        if any(["感冒", "发烧", "发热", "咳嗽", "嗓子疼", "喉咙痛", "嗓子痛", "流鼻涕", "鼻塞", "着凉"]) { return .cold }
        if any(["心慌", "心悸", "心跳很快", "心跳好快", "心跳快", "心跳不齐", "漏跳", "早搏"]) { return .palpitations }
        if any(["头疼", "头痛"]) { return .headache }
        if q.contains("抽筋") { return .cramps }
        if any(["泡沫尿", "尿里有泡沫", "尿少", "尿量少", "尿量变少", "尿血"]) { return .urine }
        if any(["起夜", "夜尿", "晚上尿", "夜里尿", "半夜上厕所", "夜里上厕所", "晚上上厕所"]) { return .nocturia }
        if any(["皮肤痒", "身上痒", "全身痒", "瘙痒", "痒得", "很痒", "发痒"]), !any(["嗓子", "喉咙", "眼睛", "鼻子"]) { return .itch }
        if any(["没胃口", "胃口不好", "不想吃", "吃不下", "食欲不好", "食欲差", "恶心"]) { return .appetite }
        if any(["口渴", "口干", "老想喝水", "尿多", "尿频"]) { return .thirst }
        let body = PlanChat.lowerBody + PlanChat.upperBody + PlanChat.backWords
        if PlanChat.painWords.filter({ $0 != "不舒服" }).contains(where: { q.contains($0) }), body.contains(where: { q.contains($0) }) { return .pain }
        if q.contains("酸"), !any(["酸奶", "尿酸", "乳酸", "胃酸"]) { return .soreness }
        if q.contains("累"), !any(["累计", "累积"]) { return .fatigue }
        if any(["疲劳", "疲惫", "乏力", "没劲", "没力气", "没精神", "提不起劲"]) { return .fatigue }
        return nil
    }
}
