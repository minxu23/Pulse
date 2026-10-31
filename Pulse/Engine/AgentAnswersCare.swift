import Foundation

// MARK: - Answers for the records Pulse keeps

/// Questions about what Pulse already records or schedules — lab values as typed, body weight,
/// dialysis, the kidney-diet record, water, the plan, the reviews — and about the app itself.
/// Each answers the question asked from the person's own records, and says where to look or
/// record when the chat cannot do it.
extension HealthAgent {
    /// The answers below, in the order they are tried; nil when none fits.
    static func careAnswer(_ a: AgentQuestion, context c: AgentContext) -> AgentReply? {
        if let r = AppGuide.reply(a) { return r }
        if asksDialysis(a) { return dialysis(a, context: c) }
        if a.has(["体重"]), a.has(["变化", "怎么样", "趋势", "最近", "重了", "轻了", "涨了吗", "降了吗", "有没有涨"]) { return weightTrend(c) }
        if a.has(["蛋白质", "钾", "磷", "盐", "咸"]),
           a.has(["今天", "这周", "本周", "最近", "吃够", "吃多", "超了", "超标", "够不够", "够吗", "咸吗", "该吃多少", "吃多少", "能吃多少"]),
           !a.has(["不能吃", "吃什么", "哪些"]) {
            return kidneyDietRecord(a, context: c)
        }
        if a.has(["钾", "磷"]), a.has(["吃什么", "能吃", "不能吃", "少吃", "哪些", "食物", "忌口", "注意什么", "别吃"]) {
            return nutrientFoods(a.has(["磷"]) && !a.has(["钾"]) ? .phosphorus : .potassium, context: c)
        }
        if a.has(["喝多少水", "喝水多少", "饮水量", "喝几杯水", "水喝多少", "喝多少", "水要喝"]), a.has(["水", "喝"]) { return water(c) }
        if a.has(["为什么"]), a.has(["休息", "没有训练", "没有安排", "不用练", "不练"]) { return whyRest(c) }
        if a.has(["下周"]), a.has(["计划", "安排", "练什么", "训练"]), !PlanChat.isRequest(a.text) { return nextWeek(c) }
        if a.has(["今天", "明天", "这周", "本周"]), a.has(["训练", "计划", "练什么", "安排", "运动"]),
           a.has(["什么", "哪些", "内容", "几点", "多久"]), a.form != .canI { return planContent(a, context: c) }
        if a.has(["这周", "本周", "上周"]), a.has(["总结", "复盘", "回顾"]) || a.text.range(of: "^(这周|本周|上周)(过得)?怎么样[？?]?$", options: .regularExpression) != nil {
            return weekSummary(a, context: c)
        }
        if a.has(["这个月", "本月", "这周", "本周"]), a.has(["哪天最好", "哪天最差", "哪天", "最好的一天", "最差的一天"]) { return bestDays(a, context: c) }
        if a.has(["每日回顾", "顺利", "有起伏", "需留意"]), a.form == .explain || a.has(["怎么看", "什么意思", "怎么算", "怎么评"]) { return dailyReviewExplained(c) }
        if a.has(["优先事项", "优先级", "最该关注什么", "最在意"]) { return priorities(c) }
        if let k = moreKnowledge(a, context: c) { return k }
        return nil
    }

    // MARK: Lab values and weight as typed

    static func labReading(_ k: LabKind, value v: Double, unit: String, guessed: Bool, _ a: AgentQuestion, context c: AgentContext) -> AgentReply {
        // Judged at the precision shown: 53 mmol/mol is 7.0%, not "above 7%".
        let std = Double(k.format(k.standard(v, unit: unit))) ?? k.standard(v, unit: unit)
        let status = LabAnalyzer.status(k, std, profile: c.profile)
        func sp(_ u: String) -> String { u == "%" ? u : " " + u }
        let shown = "\(k.label) \(v.cleanText)\(sp(unit))"
        let converted = unit == k.unit ? "" : "，约等于 \(k.format(std))\(sp(k.unit))"
        var first = "\(shown)\(converted)：\(status.text)。"
        if status.level == .urgent { first = "\(shown)\(converted)，已经到了需要尽快处理的程度，今天就联系医生或去医院。" }
        var parts: [String?] = []
        if guessed, unit != k.unit { parts.append("你没写单位，按数值看应该是 \(unit)；以化验单上的单位为准。") }
        if guessed, unit == k.unit, let other = k.units.dropFirst().first(where: { k.plausible.contains(k.standard(v, unit: $0)) }), k == .uacr {
            parts.append("如果化验单上的单位是 \(other)，约等于 \(k.format(k.standard(v, unit: other))) \(k.unit)，就是\(LabAnalyzer.status(k, k.standard(v, unit: other), profile: c.profile).text)。")
        }
        if let last = c.lab(k), abs(last.value - std) > 0.001 {
            parts.append("你 \(last.date.formatted(.dateTime.month().day())) 记录的是 \(last.valueText)\(sp(k.unit))。")
        }
        parts.append("一次结果只能作参考，医生会结合前后几次化验一起看。")
        return AgentReply(text: lines([first] + parts), sources: ["化验参考范围"], followUps: ["我的化验结果怎么样？", "我什么时候该复查？"],
                          destination: .labs, intent: .reading, conclusion: first,
                          safety: status.level == .urgent ? "数值异常明显时不要等，今天就联系医生；有心慌、无力、气短立即拨打 120。" : nil)
    }

    static func weightReading(_ kg: Double, _ a: AgentQuestion, context c: AgentContext) -> AgentReply {
        let p = c.profile
        let weights = c.vitals.filter { $0.kind == .weight && $0.time > c.now.adding(days: -8) }.sorted { $0.time < $1.time }
        var first = "体重 \(kg.oneDecimal) kg。"
        var parts: [String?] = []
        if p.onHemodialysis, let dry = p.dryWeightKg {
            let gain = kg - dry, pct = gain / dry * 100
            first = "体重 \(kg.oneDecimal) kg，比干体重 \(dry.oneDecimal) kg \(gain >= 0 ? "多" : "少") \(abs(gain).oneDecimal) kg"
                + (gain > 0 ? "（\(Int(pct.rounded()))%）" : "") + (pct >= Dialysis.gainPercent ? "，涨得偏多。" : "。")
            if pct >= Dialysis.gainPercent { parts.append("两次透析之间涨得多，透析时要脱的水也多，容易抽筋、血压往下掉：按透析中心定的量喝水，少吃咸的，下次透析时告诉医护人员。") }
        } else if let last = weights.last {
            let d = kg - last.value
            first = "体重 \(kg.oneDecimal) kg，比 \(last.time.formatted(.dateTime.month().day())) 记录的 \(last.value.oneDecimal) kg " + (abs(d) < 0.3 ? "差不多。" : "\(d > 0 ? "多" : "少")了 \(abs(d).oneDecimal) kg。")
            if p.watchesWeight, d >= 2, last.time > c.now.adding(days: -4) {
                parts.append("几天里涨了 2 kg 以上，可能是身体存了水：看看脚踝有没有肿、尿有没有变少，明早再称一次，复称仍偏高就联系医生。")
            }
        }
        return AgentReply(text: lines([first] + parts), sources: ["体重记录", "健康状况"], followUps: ["我的体重有变化吗？"],
                          destination: .vitals, intent: .reading, conclusion: first)
    }

    static func weightTrend(_ c: AgentContext) -> AgentReply {
        let p = c.profile
        let w = c.vitals.filter { $0.kind == .weight }.sorted { $0.time < $1.time }
        guard let last = w.last else {
            let first = "还没有体重记录。"
            return AgentReply(text: lines([first, "在「今日」右上角「+ › 其他指标」里记体重；\(p.watchesWeight ? "你需要留意体重，最好每天早上起床排尿后、早饭前称一次。" : "每周固定一天早上称一次就够。")"]),
                              sources: ["体重记录"], destination: .vitals, intent: .reading, conclusion: first)
        }
        let day = Date.FormatStyle().month().day()
        func change(_ days: Int) -> (Double, VitalPoint)? {
            w.last { $0.time <= last.time.adding(days: -days) && $0.time > last.time.adding(days: -days * 2) }.map { (last.value - $0.value, $0) }
        }
        var first = "最近一次体重 \(last.value.oneDecimal) kg（\(last.time.formatted(day))）"
        if let (d, from) = change(28) ?? change(7) {
            first += abs(d) < 0.5 ? "，和 \(from.time.formatted(day)) 差不多。" : "，比 \(from.time.formatted(day)) \(d > 0 ? "多" : "少")了 \(abs(d).oneDecimal) kg。"
        } else { first += "。" }
        var parts: [String?] = []
        if p.onHemodialysis, let dry = p.dryWeightKg { parts.append("你的干体重是 \(dry.oneDecimal) kg：两次透析之间涨到 \((dry * (1 + Dialysis.gainPercent / 100)).oneDecimal) kg 以上，Pulse 会提醒你。") }
        if p.watchesWeight, !p.onHemodialysis, let g = CardioAnalyzer.weightGain(c.vitals, now: c.now) {
            parts.append("要留意：3 天内涨了 \(g.kg.oneDecimal) kg，可能是身体存了水，看看有没有脚肿、尿少，联系医生。")
        }
        if w.count < 4 { parts.append("记录还少，\(p.watchesWeight ? "每天早上" : "每周固定一天早上")称一次，变化才看得清。") }
        return AgentReply(text: lines([first] + parts), sources: ["体重记录"], followUps: p.watchesWeight ? ["最近脚有点肿怎么办？"] : [],
                          destination: .vitals, intent: .reading, conclusion: first)
    }

    // MARK: Dialysis

    static func asksDialysis(_ a: AgentQuestion) -> Bool {
        if a.has(["干体重"]) { return true }
        return a.has(["透析"]) && a.has(["体重", "涨", "哪天", "透析日", "几天", "注意", "喝水", "饮水", "喝多少"]) && !TrainingCheck.isRequest(a.text)
    }

    static func dialysis(_ a: AgentQuestion, context c: AgentContext) -> AgentReply {
        let p = c.profile
        guard p.onDialysis else {
            let first = "你还没有记录在做透析。"
            return AgentReply(text: lines([first, "在做透析的话，在「我的 › 健康状况与用药 › 透析」打开，选血液透析或腹膜透析，填上透析日和干体重。Pulse 会避开透析日安排运动，并留意两次透析之间的体重。"]),
                              sources: ["健康状况"], intent: .condition, conclusion: first, verbatim: true)
        }
        if p.onPeritoneal {
            let first = "腹膜透析每天在家做，最要紧的是每天称体重、记尿量，并留意感染的迹象。"
            return AgentReply(text: lines([first, bullets(["每天早上起床排尿后称体重，几天里涨得快、脚肿或气短，联系腹透中心",
                                                         "喝水按腹透中心定的量；保住剩下的尿量很重要",
                                                         "透出液浑浊、肚子疼或发烧，立即联系腹透中心"])]),
                              sources: ["健康状况"], followUps: ["今天能运动吗？"], intent: .condition, conclusion: first, verbatim: true)
        }
        var first: String
        var parts: [String?] = []
        if let dry = p.dryWeightKg {
            let limit = dry * (1 + Dialysis.gainPercent / 100)
            first = "你的干体重是 \(dry.oneDecimal) kg。两次透析之间，体重一般最好不要涨到干体重的 \(Int(Dialysis.gainPercent))% 以上，也就是 \(limit.oneDecimal) kg 以内；具体以透析中心的要求为准。"
            if let g = Dialysis.gain(c.vitals, profile: p, now: c.now) {
                parts.append("最近一次体重 \(g.latest.value.oneDecimal) kg，比干体重多 \(g.kg.oneDecimal) kg" + (g.percent.map { "（\(Int($0.rounded()))%）" } ?? "") + (Dialysis.tooMuch(g) ? "，涨得偏多。" : "，在范围内。"))
            }
        } else {
            first = "两次透析之间，体重一般最好不要涨到干体重的 \(Int(Dialysis.gainPercent))% 以上，具体以透析中心的要求为准。你还没填干体重，在「我的 › 健康状况与用药 › 透析」填上，Pulse 就能帮你算。"
        }
        parts.append(bullets(["透析日：\(Dialysis.schedule(p))，这几天不安排训练",
                              "体重涨得多，多半是喝水多、吃得咸：喝水按透析中心定的量，少吃咸菜、汤和加工食品",
                              "内瘘那只手臂不压、不提重物、不量血压，每天摸一摸震颤"]))
        return AgentReply(text: lines([first] + parts), sources: ["健康状况", "体重记录"], followUps: ["透析日能散步吗？"],
                          intent: .condition, conclusion: first)
    }

    // MARK: Kidney diet record, foods and water

    static func kidneyDietRecord(_ a: AgentQuestion, context c: AgentContext) -> AgentReply {
        let p = c.profile
        let today = c.days.first { $0.day == c.logicalToday }
        let week = a.has(["这周", "本周", "最近"])
        guard p.tracksNutrients else {
            let first = "你还没有打开盐、蛋白质、钾和磷的记录。"
            return AgentReply(text: lines([first, "需要管住这些时，在「我的 › 健康状况与用药 › 饮食限制」打开，再在「今日 › 饮食与指标」里记每天吃了什么。"]),
                              sources: ["饮食记录"], intent: .diet, conclusion: first, verbatim: true)
        }
        if a.has(["该吃多少", "能吃多少", "吃多少"]), a.has(["蛋白质"]) {
            let first = p.proteinTargetG.map { "医生给你定的蛋白质是每天约 \($0) g。" } ?? "蛋白质吃多少要按肾内科医生或营养师定的量来，Pulse 不替你定。"
            let g = today.flatMap(KidneyDiet.proteinG)
            return AgentReply(text: lines([first, g.map { "今天记录的约 \(Int($0)) g。" } ?? "今天还没记。",
                                           "1 个鸡蛋约 6 g，1 两瘦肉约 10 g，1 碗米饭约 4 g，1 杯牛奶约 7 g；主食和蔬菜也算在内。"]),
                              sources: ["饮食记录"], destination: nil, intent: .diet, conclusion: first, verbatim: true)
        }
        if week {
            guard let w = KidneyDiet.week(c.days, profile: p, now: c.now) else {
                return AgentReply(text: "这周还没有饮食记录。在「今日 › 饮食与指标」里记一下吃了什么，我就能帮你看盐、蛋白质、钾和磷。",
                                  sources: ["饮食记录"], intent: .diet, verbatim: true)
            }
            let first = "这周记录了 \(w.days) 天：偏咸 \(w.saltyDays) 天" + (w.proteinAvgG.map { "，蛋白质平均约 \(Int($0)) g" + (p.proteinTargetG.map { "（医生定的 \($0) g）" } ?? "") } ?? "")
                + "，高钾食物平均每天 \(w.potassiumPerDay.oneDecimal) 份（约 \(Int(w.potassiumMgPerDay)) mg 钾）。"
            var tips: [String] = []
            if w.saltyDays >= 2 { tips.append("偏咸的天里多是咸菜、酱料或在外吃：这些先少一点") }
            if p.limitsPotassium, w.potassiumPerDay >= 1.5 { tips.append("限钾的话，高钾的菜先焯水再炒，水果一天一份") }
            return AgentReply(text: lines([first, bullets(tips), "钾和磷只算记下的高钾、高磷食物，不是全天总量。"]),
                              sources: ["饮食记录"], followUps: ["少吃盐有什么技巧？"], intent: .diet, conclusion: first)
        }
        guard let d = today, d.nutrientsLogged else {
            return AgentReply(text: "今天还没记饮食。在「今日 › 饮食与指标」点「记录今天的饮食」，记下吃了几个鸡蛋、几两肉、几碗饭和吃过的高盐、高钾食物，我就能帮你对照医生定的量。",
                              sources: ["饮食记录"], intent: .diet, verbatim: true)
        }
        let all = KidneyDiet.lines(d, profile: p)
        let asked = all.filter { l in
            (a.has(["蛋白质"]) && l.text.contains("蛋白质")) || (a.has(["钾"]) && l.text.contains("钾"))
                || (a.has(["磷"]) && l.text.contains("磷")) || (a.has(["盐", "咸"]) && (l.text.contains("盐") || l.text.contains("咸")))
        }
        let shown = asked.isEmpty ? all : asked
        let first = "今天记录的：" + shown.map(\.text).joined(separator: "；") + "。"
        let off = shown.filter { $0.tone == .attention }
        // 「吃够了吗」 is about the amount, not only the limit.
        var protein: String? = nil
        if a.has(["蛋白质"]), let g = KidneyDiet.proteinG(d), let t = p.proteinTargetG.map(Double.init) {
            protein = g < t * 0.9 ? "比医生定的少约 \(Int((t - g).rounded())) g，今天还可以补一点，比如 1 个鸡蛋加 1 杯牛奶约 13 g。"
                : (g > t * 1.15 ? "比医生定的多了，明天肉蛋奶豆少一份就好。" : "差不多够了。")
        }
        return AgentReply(text: lines([first, protein ?? (off.isEmpty ? "今天这几项都在范围内。" : "超出或明显不够的，明天调整一下就好，不用一次补回来。"),
                                       a.has(["钾", "磷"]) ? "钾和磷只算记下的高钾、高磷食物，不是全天总量。" : nil]),
                          sources: ["饮食记录"], intent: .diet, conclusion: first)
    }

    enum Nutrient { case potassium, phosphorus }

    static func nutrientFoods(_ n: Nutrient, context c: AgentContext) -> AgentReply {
        let p = c.profile
        let foods = n == .potassium ? DietFoods.potassiumFoods : DietFoods.phosphorusFoods
        let lab = c.lab(n == .potassium ? .potassium : .phosphorus, within: 180)
        let name = n == .potassium ? "钾" : "磷"
        let first = n == .potassium ? "血钾高时，少吃含钾多的蔬果、菌菇和豆类，蔬菜先焯水再炒，别用低钠盐。"
            : "血磷高时，最要少吃的是加工食品和深色汽水：里面加的磷最容易被吸收。"
        let list = foods.sorted { (n == .potassium ? $0.potassiumMg : $0.phosphorusMg) > (n == .potassium ? $1.potassiumMg : $1.phosphorusMg) }
            .map { "\($0.name)：\($0.portion)约 \(n == .potassium ? $0.potassiumMg : $0.phosphorusMg) mg" }
        var parts: [String?] = [lab.map { "你 \($0.date.formatted(.dateTime.month().day())) 的血\(name)是 \($0.valueText) mmol/L（\(LabAnalyzer.status($0.kind, $0.value, profile: p).text)）。" },
                                "含\(name)多的常见食物（大约的量）：", bullets(Array(list.prefix(8)))]
        if n == .potassium {
            parts.append(bullets(["绿叶菜、土豆切小块，先在开水里焯 2–3 分钟再炒，能去掉一部分钾", "肉汤、菜汤里溶进了很多钾，少喝汤", "水果一天一份，选苹果、梨这类含钾少的"]))
        } else {
            parts.append(bullets(["看配料表，含「磷酸」字样的加工食品少吃", "蛋白质按医生定的量吃，别为了降磷吃得太少", "降磷药要和饭一起吃，按医生的安排"]))
        }
        parts.append("具体吃多少，按肾内科医生或营养师的要求；不要自己加减补钾药或利尿剂。")
        return AgentReply(text: lines([first] + parts), sources: ["饮食常识", lab == nil ? nil : "化验结果"].compactMap { $0 },
                          followUps: ["今天钾吃多了吗？"], intent: .diet, conclusion: first, verbatim: true)
    }

    static func water(_ c: AgentContext) -> AgentReply {
        let p = c.profile
        let drunk = c.days.first { $0.day == c.logicalToday }?.waterMl ?? 0
        let first = p.fluidLimited ? "医生让你限水，每天喝水不超过 \(p.waterTargetMl) ml（汤、粥、水果里的水也算）。"
            : "一般每天喝 1500–2000 ml 左右，你设的目标是 \(p.waterTargetMl) ml；天热、运动出汗多时多喝一些。"
        var parts: [String?] = ["今天记录的是 \(drunk) ml。"]
        if p.fluidLimited { parts.append(bullets(["用固定的杯子，一天的量提前倒好", "口渴时含一小块冰或小口慢喝", "少吃咸的，盐吃多了会更渴"])) }
        else if p.hasDiabetes { parts.append("血糖高时会口渴、尿多，喝白开水，不用含糖饮料解渴。") }
        return AgentReply(text: lines([first] + parts), sources: ["饮水记录", "健康状况"], intent: .diet, conclusion: first, verbatim: true)
    }

    // MARK: The plan

    static func planContent(_ a: AgentQuestion, context c: AgentContext) -> AgentReply {
        let df = Date.FormatStyle().month().day().weekday(.abbreviated).locale(Locale(identifier: "zh_CN"))
        func line(_ s: SessionSnapshot) -> String {
            "\(s.day.formatted(df))：\(s.title) \(s.minutes) 分钟 · \(s.intensity.label)" + (s.status == .planned ? "" : "（\(s.status.label)）")
        }
        if a.has(["这周", "本周"]) {
            let week = c.plan.filter { $0.day >= c.weekStart && $0.day < c.weekStart.adding(days: 7) }.sorted { $0.day < $1.day }
            let first = week.isEmpty ? "这周还没有排计划。" : "这周的安排："
            return AgentReply(text: lines([first, bullets(week.map(line))]), sources: ["本周计划"], followUps: ["今天适合运动吗？"],
                              destination: .plan, intent: .exercise, conclusion: first, verbatim: true)
        }
        let day = a.has(["明天"]) ? c.logicalToday.adding(days: 1) : c.logicalToday
        let word = a.has(["明天"]) ? "明天" : "今天"
        let items = c.plan.filter { $0.day == day }
        guard let s = items.first(where: { $0.kind.isTraining }) ?? items.first else {
            return whyRest(c, day: day, word: word)
        }
        let first = "\(word)安排的是「\(s.title)」\(s.minutes) 分钟，\(s.intensity.label)" + (s.status == .planned ? "。" : "，\(s.status.label)。")
        var parts: [String?] = []
        if let d = s.newDetail { parts.append(d) }
        if s.minimumMinutes > 0, s.minimumMinutes < s.minutes { parts.append("时间紧的话，做 \(s.minimumMinutes) 分钟也算：\(s.minimumDetail)") }
        if day == c.logicalToday, let score = c.readiness.score { parts.append("今天准备度 \(score)：\(c.readiness.recommendation)") }
        return AgentReply(text: lines([first] + parts), sources: ["本周计划", "准备度"], followUps: ["\(word)适合运动吗？"],
                          destination: .plan, intent: .exercise, conclusion: first)
    }

    /// 「为什么今天让我休息」: what the day is in the plan, and why.
    static func whyRest(_ c: AgentContext, day: Date? = nil, word: String = "今天") -> AgentReply {
        let p = c.profile
        let d = day ?? c.logicalToday
        let items = c.plan.filter { $0.day == d }
        var why: [String] = []
        if Dialysis.isDay(d, p) { why.append("\(word)是透析日，透析前后不安排训练") }
        if !p.availableWeekdays.contains(d.weekday) { why.append("\(Weekday.name(d.weekday))不是你设的训练日（在「我的 › 运动基础与生活节奏」里改）") }
        if d == c.logicalToday, c.readiness.level == .rest || c.readiness.level == .low, let s = c.readiness.score { why.append("今天准备度 \(s)，身体还在恢复") }
        if items.contains(where: { $0.kind.isTraining }) {
            let s = items.first { $0.kind.isTraining }!
            let first = "\(word)其实有安排：「\(s.title)」\(s.minutes) 分钟，\(s.intensity.label)。"
            return AgentReply(text: lines([first, why.isEmpty ? nil : "不过：" + why.joined(separator: "；") + "，量力而行。"]), sources: ["本周计划"],
                              followUps: ["\(word)适合运动吗？"], destination: .plan, intent: .exercise, conclusion: first)
        }
        let walk = items.first { $0.kind == .walk }
        let first = "\(word)是\(walk == nil ? "休息日" : "日常活动日")" + (why.isEmpty ? "：一周里留出不练的日子，身体才能把训练的效果长出来。" : "：" + why.joined(separator: "；") + "。")
        return AgentReply(text: lines([first, walk.map { "可以做的：\($0.title) \($0.minutes) 分钟，轻松就好。" }]),
                          sources: ["本周计划", "准备度"], followUps: ["这周的训练完成得怎么样？"], destination: .plan, intent: .exercise, conclusion: first)
    }

    static func nextWeek(_ c: AgentContext) -> AgentReply {
        let next = c.weekStart.adding(days: 7)
        let items = c.plan.filter { $0.day >= next && $0.day < next.adding(days: 7) && $0.kind.isTraining }.sorted { $0.day < $1.day }
        let df = Date.FormatStyle().month().day().weekday(.abbreviated).locale(Locale(identifier: "zh_CN"))
        guard !items.isEmpty else {
            let first = "下周的计划要到周一才定：会按这周完成得怎么样自动调整目标。"
            return AgentReply(text: lines([first, "想先看看，可以去「复盘 › 本周复盘」，最下面有下周计划的草案，可以直接采用。"]),
                              sources: ["本周计划"], followUps: ["这周的训练完成得怎么样？"], destination: .plan, intent: .exercise, conclusion: first, verbatim: true)
        }
        let first = "下周已经排好 \(items.count) 次训练："
        return AgentReply(text: lines([first, bullets(items.map { "\($0.day.formatted(df))：\($0.title) \($0.minutes) 分钟 · \($0.intensity.label)" })]),
                          sources: ["下周计划"], destination: .plan, intent: .exercise, conclusion: first, verbatim: true)
    }

    // MARK: Reviews

    static func weekSummary(_ a: AgentQuestion, context c: AgentContext) -> AgentReply {
        let last = a.has(["上周"])
        let ws = last ? c.weekStart.adding(days: -7) : c.weekStart
        let span = last ? 7 : c.logicalToday.daysSince(c.weekStart) + 1
        let cur = ReviewCoach.week(days: c.days, plan: c.plan, weekStart: ws, span: span, source: c.trend.dominantSource, now: c.logicalToday)
        let prev = ReviewCoach.week(days: c.days, plan: c.plan, weekStart: ws.adding(days: -7), span: span, source: c.trend.dominantSource, now: c.logicalToday)
        let pr = ReviewPriorities.ranked(c, mine: c.profile.reviewPriorities)
        let b = ReviewCoach.brief(current: cur, previous: prev, context: c, isCurrentWeek: !last,
                                  nextTarget: (c.profile.weeklyTargetMinutes, ""), priorities: pr)
        let first = b.headline + "。"
        let numbers = b.metrics.filter { $0.value != "—" }.prefix(4).map { "\($0.name) \($0.value) \($0.unit)" + ($0.delta.map { "（\($0)）" } ?? "") }
        // The headline already says the story's main thread; the bright spot and the difficulty follow.
        let story = [b.story?.bright.map { "好的一面是，\($0)。" }, b.story?.hard.map { "需要留意的是，\($0)。" }].compactMap { $0 }.joined()
        return AgentReply(text: lines([first, story.isEmpty ? nil : story, bullets(numbers), "完整的复盘在「复盘 › \(last ? "本周复盘（切到上周）" : "本周复盘")」。"]),
                          sources: ["本周记录"], followUps: ["接下来我该关注什么？"], intent: .overall, conclusion: first)
    }

    static func bestDays(_ a: AgentQuestion, context c: AgentContext) -> AgentReply {
        let week = a.has(["这周", "本周"])
        let today = c.logicalToday
        let start = week ? c.weekStart : today.monthStart
        let pr = ReviewPriorities.ranked(c, mine: c.profile.reviewPriorities)
        let span = stride(from: 0, through: today.daysSince(start), by: 1).map { start.adding(days: $0) }
        let rated: [(day: Date, level: DayLevel)] = span.compactMap { d in ReviewPriorities.verdict(on: d, context: c, priorities: pr).level.map { (d, $0) } }
        let period = week ? "这周" : "这个月"
        guard let top = rated.map(\.level).min(), let low = rated.map(\.level).max() else {
            let first = "\(period)的记录还不够，评不出来。"
            return AgentReply(text: first, sources: ["每日回顾"], intent: .overall, conclusion: first, verbatim: true)
        }
        let df = Date.FormatStyle().month().day()
        func days(_ l: DayLevel) -> String { rated.filter { $0.level == l }.prefix(3).map { $0.day.formatted(df) }.joined(separator: "、") }
        let first = "\(period)最好的是 \(days(top))（\(top.label)）" + (low > top ? "，需要多留意的是 \(days(low))（\(low.label)）。" : "。")
        let summary = ReviewPriorities.monthSummary(rated.map { Optional($0.level) }).replacingOccurrences(of: "这个月", with: period)
        return AgentReply(text: lines([first, summary + "。", "在「复盘 › 每日回顾」点日历上的某一天，能看到那天具体怎么样。"]),
                          sources: ["每日回顾"], followUps: ["我的优先事项是什么？"], intent: .overall, conclusion: first, verbatim: true)
    }

    static func dailyReviewExplained(_ c: AgentContext) -> AgentReply {
        let first = "每日回顾按你最在意的几件事（优先事项）给每天评一个等级，也会和你自己平时的水平比。"
        return AgentReply(text: lines([first, bullets(DayLevel.allCases.map { "\($0.label)：\($0.meaning)" }),
                                       "离目标很远（比如家庭血压 145/90 以上）就算是平时也这样，也不算没问题；连续多天没达标会单独提醒一次，建议带着记录去看医生。",
                                       "在「复盘 › 每日回顾」点某一天能看到具体每一项；优先事项可以在那里点「调整」改顺序。"]),
                          sources: ["每日回顾"], followUps: ["我的优先事项是什么？"], intent: .about, conclusion: first, verbatim: true)
    }

    static func priorities(_ c: AgentContext) -> AgentReply {
        let pr = Array(ReviewPriorities.ranked(c, mine: c.profile.reviewPriorities).prefix(3))
        let first = "你现在最在意的三件事：\(pr.map(\.area.label).joined(separator: "、"))。"
        return AgentReply(text: lines([first, bullets(pr.map { "\($0.area.label)：\($0.mine ? "你自己排的" : $0.reason)" }),
                                       "复盘和每日回顾都按这个顺序来；在「复盘 › 每日回顾」点「调整」可以改。"]),
                          sources: ["健康状况", "最近的记录"], followUps: ["这周总结一下"], intent: .overall, conclusion: first, verbatim: true)
    }

    // MARK: Know-how

    static func moreKnowledge(_ a: AgentQuestion, context c: AgentContext) -> AgentReply? {
        let p = c.profile
        let first: String, tips: [String]
        if a.has(["间歇"]), a.form == .explain || a.has(["怎么练", "怎么做", "是什么"]) {
            first = "间歇训练是快慢交替：比如快跑 1–3 分钟、慢跑或走 1–3 分钟，重复几组，用比较短的时间练心肺。"
            tips = ["一周最多 1–2 次，中间隔开至少一天", "先有几周规律的轻松有氧打底再加", p.intensityCapped ? "你现在\(p.intensityCaps.joined(separator: "、"))，医生确认前先不做间歇" : "快的那段做到说话断断续续就够了"]
        } else if a.has(["步"]), a.has(["多少", "几步", "合适", "够不够", "走多少"]) {
            let avg = c.recent7.compactMap(\.steps)
            first = "每天 7000–10000 步对多数人就够了，比单看步数更要紧的是每周 150 分钟快走这类中等强度活动。"
            tips = ["你设的目标是每天 \(p.stepsTarget) 步" + (avg.isEmpty ? "" : "，近 7 天平均 \(avg.reduce(0, +) / avg.count) 步"),
                    "平时走得少，每周比上周多走 1000 步左右慢慢加", "久坐时每小时起来走几分钟"]
        } else {
            return nil
        }
        return AgentReply(text: lines([first, bullets(tips)]), sources: ["运动常识"], followUps: ["今天适合运动吗？"],
                          destination: .plan, intent: .knowledge, conclusion: first, verbatim: true)
    }

    // MARK: Feelings and courtesy

    static func mood(_ a: AgentQuestion, context c: AgentContext) -> AgentReply? {
        guard a.has(["心情不好", "心情差", "心情很差", "不开心", "难过", "郁闷", "情绪低落", "想哭", "沮丧", "心里难受", "心里不舒服", "烦死", "好烦", "很烦"]) else { return nil }
        let first = "听起来你最近不太好受，愿意的话可以和我说说发生了什么。"
        var parts: [String?] = [bullets(["今天先给自己留一点时间：出去走 10–15 分钟、晒晒太阳", "和信任的人聊一聊，不用一个人扛着", "今晚早点睡，别逼自己做完所有事"])]
        let stress = c.recent7.compactMap(\.stress)
        if stress.count >= 3, Double(stress.reduce(0, +)) / Double(stress.count) >= 3.5 { parts.append("你这周记的压力也偏高，这段时间对自己好一点。") }
        parts.append("如果心情低落两周以上、对什么都提不起兴趣，或者影响到吃饭睡觉，去看看心理科或精神科医生。")
        let safety = "如果有伤害自己的想法，请马上联系身边的人，或拨打心理援助热线 12356。"
        parts.append(safety)
        return AgentReply(text: lines([first] + parts), sources: ["压力记录"], followUps: ["怎么才能睡好？"], intent: .stress,
                          conclusion: first, safety: safety)
    }

    static func courtesy(_ q: String) -> AgentReply? {
        let t = q.trimmingCharacters(in: CharacterSet(charactersIn: " ！!。.~～😊👍"))
        guard ["谢谢", "谢了", "多谢", "谢谢你", "感谢", "好的", "好", "知道了", "明白了", "收到", "OK", "ok", "嗯", "嗯嗯", "行"].contains(t) else { return nil }
        let text = t.hasPrefix("谢") || t == "感谢" ? "不客气。有什么想问的随时找我。" : "好的。有什么想问的随时找我。"
        return AgentReply(text: text, followUps: ["接下来我该关注什么？"], intent: .greeting, conclusion: text, verbatim: true)
    }

    // MARK: Recording and reminders from the chat

    /// 「提醒我明天早上量血压」: a 照护与随访 task with a card to confirm; the date can be changed on it.
    static func reminderRequest(_ a: AgentQuestion, context c: AgentContext) -> AgentReply? {
        guard ChatRecord.asksReminder(a) else { return nil }
        let p = ChatRecord.reminder(a, now: c.now)
        guard let r = p.reminder else { return nil }
        let df = Date.FormatStyle().month().day().weekday(.abbreviated).locale(Locale(identifier: "zh_CN"))
        let first: String
        if let rep = p.repeats {
            let at = r.timed ? " " + Clock.text(r.due.minutesOfDay) : "上午 9 点"
            first = "可以帮你加一条重复提醒：「\(r.title)」，\(rep.label)\(at)，第一次在 \(r.due.formatted(df))。点「记下」后生效\(r.timed ? "，时间可以在卡片上改" : "")。"
        } else {
            let when = r.due.formatted(df) + (r.timed ? " " + Clock.text(r.due.minutesOfDay) : "，当天上午 9 点提醒")
            first = "可以帮你加一条提醒：「\(r.title)」，\(when)。点「记下」后生效，日期可以在卡片上改。"
        }
        return AgentReply(text: lines([first, p.repeatAsked ? "这种重复方式还不支持（可以按每天、每周几或每月几号重复），这里先加一次。" : nil,
                                       p.repeats == nil ? "它会出现在「趋势 › 异常跟进 › 照护与随访事项」里，完成后在那里打个勾。"
                                           : "它会出现在「趋势 › 异常跟进 › 照护与随访事项」里，每次完成后打个勾，会自动排到下一次。"]),
                          sources: ["照护与随访事项"], intent: .about, blocks: [.record(p)], conclusion: first, verbatim: true)
    }

    /// A meal or a workout told in the chat: what it is, and what it adds up to today or this week.
    private static func eatenOrDone(_ p: RecordProposal, context c: AgentContext) -> (lines: [String], sources: [String], intent: AgentIntent)? {
        let prof = c.profile
        var out: [String] = []
        var sources: [String] = []
        for item in p.items {
            switch item {
            case .meal(let m):
                let kidney = prof.proteinTargetG != nil || prof.conditions.contains(.ckd) || prof.onDialysis
                if m.foods.isEmpty {
                    out.append("好的，记一顿\(m.kind.label)。")
                    if kidney { out.append("说出吃了什么、吃了多少（比如「两碗米饭、一个鸡蛋」），Pulse 能按份数帮你算蛋白质和钾。") }
                } else {
                    out.append("好的，\(m.kind.label)：\(ChatRecord.portions(m.foods))。")
                }
                let protein = m.foods.reduce(0.0) { sum, f in sum + (DietFoods.proteinFoods.first { $0.name == f }?.proteinG ?? 0) }
                if kidney, protein > 0 {
                    let today = c.days.first { $0.day == m.at.startOfDay }.flatMap(KidneyDiet.proteinG) ?? 0
                    out.append("按份数估算，这顿蛋白质约 \(Int(protein.rounded())) g，加上今天已记的约 \(Int((protein + today).rounded())) g"
                               + (prof.proteinTargetG.map { "（医生定的每天约 \($0) g）" } ?? "") + "。")
                }
                let potassium = m.foods.filter(DietFoods.potassium.contains)
                if prof.limitsPotassium, !potassium.isEmpty { out.append("\(KidneyDiet.names(potassium))含钾较多，你在限钾，今天其他高钾的少吃些。") }
                let salty = m.foods.filter(DietFoods.salt.contains)
                if !salty.isEmpty, kidney || prof.conditions.contains(.hypertension) { out.append("\(salty.joined(separator: "、"))偏咸，今天其他菜清淡些。") }
                sources.append("饮食记录")
            case .workout(let w):
                let names: [WorkoutType: String] = [.run: "跑步", .walk: "步行", .cycle: "骑行", .swim: "游泳", .strength: "力量训练", .hiit: "间歇训练",
                                                    .yoga: "瑜伽 / 拉伸", .ball: "球类运动"]
                out.append("好的，\(names[w.type] ?? "运动")\(w.km.map { " \($0.cleanText) 公里" } ?? "")\(w.estimated ? "，按距离估算约" : " ")\(w.minutes) 分钟。")
                if let s = ChatRecord.planned(for: w, in: c.plan) {
                    out.append("记下后算作\(Calendar.pulse.isDate(s.day, inSameDayAs: c.now) ? "今天" : "那天")计划的「\(s.title)」。")
                }
                if w.start.weekStart == c.now.weekStart {
                    out.append("加上这次，这周约活动 \(Int(c.weekActiveMinutes) + w.minutes) 分钟，每周目标 \(prof.weeklyTargetMinutes) 分钟。")
                }
                sources.append("本周计划")
            case .water(let ml):
                out.append("饮水 \(ml) ml 也一起记。")
            default: return nil
            }
        }
        guard !out.isEmpty else { return nil }
        let intent: AgentIntent = p.items.contains { if case .workout = $0 { true } else { false } } ? .exercise : .diet
        return (out, sources, intent)
    }

    /// 「帮我记一下…」「我刚喝了一杯水」: the answer, with a card to record what the statement holds.
    static func recordingNote(_ r: AgentReply, question q: String, context c: AgentContext) -> AgentReply {
        let a = AgentQuestion(q)
        guard ChatRecord.wanted(a), r.intent != .emergency, !r.urgent, r.blocks.allSatisfy({ $0.record == nil }) else { return r }
        guard let p = ChatRecord.proposal(a, now: c.now) else {
            // Nothing Pulse could take from the sentence: how to say it, or where to record it.
            let note = a.has(["吃", "饭", "餐"]) ? "没认出吃了什么。可以说「午饭吃了两碗米饭、一个鸡蛋」，或者在「今日 › 饮食与指标」的「记录饮食」里记。"
                : a.has(["跑", "练", "运动", "走", "骑", "游"]) ? "没认出运动了多久。可以说「刚快走了 40 分钟」「跑了 5 公里」，或者在「今日」右上角「+ › 运动」里记。"
                : "这个还不能在对话里直接记，在「今日」右上角的「+」记一下就好。"
            var out = r.intent == .unknown ? AgentReply(text: note, intent: .about, conclusion: note, verbatim: true) : r
            if r.intent != .unknown { out.text = lines([r.text, note]) }
            return out
        }
        let summary = p.items.map(RecordProposal.label).joined(separator: "、")
        // The card records it; a pointer to the form would say the opposite.
        var out = r
        let ask = "要记下来的话，点下面的「记下」：\(summary)。"
        if p.items.count == 1, case .water(let ml) = p.items[0] {
            let drunk = c.days.first { $0.day == c.logicalToday }?.waterMl ?? 0
            let first = "好的，这杯是 \(ml) ml。今天已记录 \(drunk) ml，\(c.profile.fluidLimited ? "上限" : "目标") \(c.profile.waterTargetMl) ml。"
            out = AgentReply(text: lines([first, ask]), sources: ["饮水记录"], intent: .diet, conclusion: first, verbatim: true)
        } else if p.items.allSatisfy({ switch $0 { case .meal, .workout, .water: true; default: false } }),
                  [.unknown, .diet, .food, .exercise, .about].contains(r.intent), a.symptom == nil,
                  !a.has(["血压", "血糖", "心率", "心跳", "头晕", "不舒服", "难受", "疼", "痛"]), let said = eatenOrDone(p, context: c) {
            // 「午饭吃了两碗米饭」「刚走了 40 分钟」: what it adds up to today, then the card. A sentence that
            // says more (「吃了咸菜，血压有点高」) keeps its own answer, with the card.
            out = AgentReply(text: lines(said.lines + [ask]), sources: said.sources, intent: said.intent, conclusion: said.lines.first, verbatim: true)
        } else if r.intent == .unknown {
            out = AgentReply(text: ask, intent: .about, conclusion: ask, verbatim: true)
        } else {
            out.text = lines([r.text, ask])
        }
        out.blocks.append(.record(p))
        return out
    }
}

// MARK: - Where things are in the app

/// 「怎么导出数据」「怎么改血压目标」: where to find it, in the app's own words.
enum AppGuide {
    static let entries: [(words: [String], answer: String)] = [
        (["导出", "备份"], "在「我的 › 隐私与数据导出」里可以导出全部记录。"),
        (["就诊摘要", "给医生看的", "带给医生"], "在「我的 › 隐私与数据导出」点「生成就诊摘要」，会整理好血压、血糖、化验、用药和最近的情况，复诊时给医生看。"),
        (["连接手表", "连手表", "连接健康", "健康App", "健康 App", "Apple Watch", "同步数据", "数据来源"], "在「我的 › 数据来源」里连接 Apple 健康，手表、体重秤、血压计同步到健康 App 的数据，Pulse 都能读到。"),
        (["透析日", "干体重", "透析设置", "设置透析"], "在「我的 › 健康状况与用药 › 透析」里打开，选血液透析或腹膜透析，再选透析日、填干体重（勾了慢性肾病才会显示这一栏）。"),
        (["血压目标"], "在「心血管健康」页右上角点「照护计划」，在「血压目标」里按医生给的改。"),
        (["到期提醒", "打开提醒", "关闭提醒", "通知", "异常提醒"], "在「我的 › 提醒」里：「到期提醒」会在复查、复诊前一周和当天通知你，「异常提醒」会在后台发现需要联系医生的情况时通知你。"),
        (["限水", "饮水目标", "喝水目标"], "在「我的 › 恢复目标」里设饮水目标；医生要求限水时打开「限水」，目标就变成每天的上限。"),
        (["饮食限制", "蛋白质目标", "限钾", "限磷", "盐的上限"], "在「我的 › 健康状况与用药 › 饮食限制」里填医生定的盐、蛋白质，打开限钾、限磷。"),
        (["优先事项"], "在「复盘 › 每日回顾」点「调整」，可以改优先事项的顺序。"),
        (["回答方式", "云端模型", "端云结合"], "在「我的 › Health Agent › 回答方式与云端模型」里选仅本机、端云结合或全部云端。"),
        (["训练日", "哪几天练", "运动时间"], "在「我的 › 运动基础与生活节奏」里选每周能练的日子和每次的时间。"),
        (["改名字", "你的名字", "叫你"], "在「我的 › Health Agent › 名字」里改，也可以直接跟我说「以后叫你小安」。"),
    ]

    static func reply(_ a: AgentQuestion) -> AgentReply? {
        let how = a.has(["怎么", "在哪", "哪里", "如何", "怎样"])
        let act = a.has(["设置", "打开", "关闭", "关掉", "改", "修改", "导出", "连接", "生成", "添加", "调整", "开启", "备份"])
        guard how || act, !a.has(["提醒我"]) else { return nil }
        guard let e = entries.first(where: { e in e.words.contains { a.text.contains($0) } }) else { return nil }
        // 「怎么改善血压」 is about health, not a setting; only settings words count.
        if e.answer.contains("血压目标"), !a.has(["目标"]) { return nil }
        return AgentReply(text: e.answer, sources: ["Pulse 使用说明"], intent: .about, conclusion: e.answer, verbatim: true)
    }
}

extension Double {
    /// 「1.44」「53」: as typed, without trailing zeros.
    var cleanText: String { truncatingRemainder(dividingBy: 1) == 0 ? String(Int(self)) : String(self) }
}
