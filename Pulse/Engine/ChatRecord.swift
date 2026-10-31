import Foundation

// MARK: - Recording from the conversation

/// What the user asked the chat to record — 「帮我记一下血压 138/88」「我刚喝了一杯水」「脚有点肿，记下来」
/// 「下周三提醒我去医院复查」. Nothing is written until the user taps 记下 on the card (like a plan
/// change or a condition), and it can be undone.
struct RecordProposal: Identifiable, Equatable {
    enum Item: Equatable {
        case bloodPressure(sys: Int, dia: Int, context: MeasureContext)
        case glucose(Double, context: MeasureContext)
        case weight(kg: Double)
        case water(ml: Int)
        case swelling(Edema, places: [String])
        case urine(UrineAmount)
        case foamyUrine
        /// In Pulse's own unit.
        case lab(LabKind, value: Double)
        /// A 照护与随访 task; `timed` when the user gave a time of day.
        case reminder(title: String, area: CareArea, due: Date, timed: Bool)
    }

    let id: UUID
    var items: [Item]
    /// When it was measured, or the day it belongs to.
    var time: Date
    /// 「每天」: only one reminder is added; repeating ones are not supported yet.
    var repeatAsked = false

    var reminder: (title: String, area: CareArea, due: Date, timed: Bool)? {
        for i in items { if case .reminder(let t, let a, let d, let timed) = i { return (t, a, d, timed) } }
        return nil
    }

    /// 「血压 138/88 mmHg · 晨起」.
    static func label(_ i: Item) -> String {
        switch i {
        case .bloodPressure(let s, let d, let c): "血压 \(s)/\(d) mmHg" + (c == .random ? "" : " · \(c.label)")
        case .glucose(let v, let c): "血糖 \(v.oneDecimal) mmol/L" + (c == .random ? "" : " · \(c.label)")
        case .weight(let kg): "体重 \(kg.oneDecimal) kg"
        case .water(let ml): "饮水 \(ml) ml"
        case .swelling(let e, let places): "水肿：\(e.label)" + (places.isEmpty ? "" : "（\(places.joined(separator: "、"))）")
        case .urine(let u): "尿量：\(u.label)"
        case .foamyUrine: "泡沫尿"
        case .lab(let k, let v): "\(k.label) \(k.format(v)) \(k.unit)"
        case .reminder(let t, _, _, _): "提醒：\(t)"
        }
    }

    static func icon(_ i: Item) -> String {
        switch i {
        case .bloodPressure: "heart.text.square"
        case .glucose: "drop.fill"
        case .weight: "scalemass"
        case .water: "drop"
        case .swelling, .urine, .foamyUrine: "drop.triangle"
        case .lab: "testtube.2"
        case .reminder: "bell"
        }
    }
}

enum ChatRecord {
    /// 「帮我记一下」「记下来」, or a plain statement of what was just measured or drunk.
    static func wanted(_ a: AgentQuestion) -> Bool {
        if a.has(["帮我记", "记一下", "记下来", "帮我记录", "记录一下", "记上", "帮我登记", "记个"]) { return true }
        let question = a.has(["吗", "？", "?", "怎么", "要不要", "多少", "什么", "呢"])
        // 「今天早上血压 138/88」 states a reading; 「血压 155 要紧吗」 asks about one.
        return !question && (a.has(["刚量", "量了", "测了", "刚测", "称了", "刚称", "喝了", "刚喝"]) || a.reading != nil)
    }

    /// What a statement holds that Pulse can record; nil when nothing it can.
    static func proposal(_ a: AgentQuestion, now: Date) -> RecordProposal? {
        let q = a.text
        let day = a.has(["昨天", "昨晚"]) ? now.adding(days: -1) : now
        var items: [RecordProposal.Item] = []
        switch a.reading {
        case .bp(let s, let d?)?:
            let ctx: MeasureContext = a.has(["早上", "晨起", "起床", "早晨"]) ? .morning : (a.has(["睡前", "晚上", "睡觉前"]) ? .bedtime : .random)
            items.append(.bloodPressure(sys: s, dia: d, context: ctx))
        case .glucose(let v, let c)?:
            items.append(.glucose(v, context: c ?? .random))
        case .weight(let kg)?:
            items.append(.weight(kg: kg))
        case .lab(let k, let v, let unit, _)?:
            items.append(.lab(k, value: k.standard(v, unit: unit)))
        default: break
        }
        if let ml = water(in: q) { items.append(.water(ml: ml)) }
        if let s = a.symptom {
            switch s {
            case .swelling:
                let marked = a.has(["很肿", "明显", "厉害", "肿得", "按下去坑很深"])
                items.append(.swelling(marked ? .marked : .mild, places: KidneySigns.places.filter { q.contains($0) || (($0 == "脚踝") && q.contains("脚")) || ($0 == "眼睑" && q.contains("眼皮")) }))
            case .urine:
                if a.has(["泡沫"]) { items.append(.foamyUrine) }
                if a.has(["尿少", "尿量少", "尿量变少"]) { items.append(.urine(.less)) }
            default: break
            }
        }
        guard !items.isEmpty else { return nil }
        let time = Calendar.pulse.isDate(day, inSameDayAs: now) ? now : day.startOfDay.adding(minutes: 12 * 60)
        return RecordProposal(id: UUID(), items: items, time: time)
    }

    /// 「一杯水」「两杯」「一瓶水」「500ml」: millilitres drunk; a cup is 250 ml, a bottle 500 ml.
    static func water(in q: String) -> Int? {
        guard q.contains("水") || q.contains("ml") || q.contains("毫升"), q.contains("喝") || q.contains("饮水") else { return nil }
        if let g = AgentQuestion.groups(#"(\d{2,4})\s*(?:ml|毫升|mL)"#, q), let n = Int(g[0]), (50...3000).contains(n) { return n }
        if let g = AgentQuestion.groups(#"([0-9一二两三四五六七八九十半]+)\s*(杯|瓶)"#, q) {
            let n = g[0] == "半" ? 0.5 : AgentQuestion.number(g[0]) ?? 1
            return Int(n * (g[1] == "瓶" ? 500 : 250))
        }
        return nil
    }

    // MARK: Reminders

    static func asksReminder(_ a: AgentQuestion) -> Bool {
        a.has(["提醒我", "到时候提醒", "记得提醒", "帮我设个提醒", "设个提醒", "帮我提醒", "叫我"]) && !a.has(["怎么", "在哪"])
    }

    /// 「下周三提醒我去医院复查」「提醒我明天早上 8 点量血压」: what, when (a day, and a time if said).
    static func reminder(_ a: AgentQuestion, now: Date) -> RecordProposal {
        let q = a.text
        let (day, dayWord) = reminderDay(q, now: now)
        let clock = reminderTime(q)
        var due = (day ?? now.startOfDay.adding(days: clock.map { now.startOfDay.adding(minutes: $0) > now } == true ? 0 : 1))
        if let m = clock { due = due.startOfDay.adding(minutes: m) }
        // What to do: the sentence without the reminder words, the day and the time.
        var title = q
        for w in ["帮我设个提醒", "设个提醒", "到时候提醒我", "记得提醒我", "帮我提醒", "提醒我一下", "提醒我", "叫我", "到时候", "一下", "请", "帮我"] {
            title = title.replacingOccurrences(of: w, with: "")
        }
        if let dayWord { title = title.replacingOccurrences(of: dayWord, with: "") }
        for pattern in [clockDigits, clockWords] {
            title = title.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        title = title.replacingOccurrences(of: #"^(早上|上午|中午|下午|傍晚|晚上|每天|每晚|每早)"#, with: "", options: .regularExpression)
        title = title.trimmingCharacters(in: CharacterSet(charactersIn: " ，,。.！!？?、的要"))
        if title.isEmpty { title = "提醒" }
        let area: CareArea
        if ["血压", "心内", "降压"].contains(where: q.contains) { area = .cardio }
        else if ["血糖", "糖化", "胰岛素", "眼底", "足部"].contains(where: q.contains) { area = .diabetes }
        else if ["肾", "透析", "肌酐", "血钾", "化验", "复查"].contains(where: q.contains) { area = .kidney }
        else if ["睡", "呼吸机"].contains(where: q.contains) { area = .sleep }
        else { area = .general }
        return RecordProposal(id: UUID(), items: [.reminder(title: title, area: area, due: due, timed: clock != nil)], time: now,
                              repeatAsked: a.has(["每天", "每晚", "每早", "每周", "每个月", "每次"]))
    }

    /// The day named: 今天/明天/后天, 周X (this week's, or next if past), 下周X, X月X日, X号, N天后.
    static func reminderDay(_ q: String, now: Date) -> (Date?, String?) {
        let today = now.startOfDay
        let names: [Character: Int] = ["一": 2, "二": 3, "三": 4, "四": 5, "五": 6, "六": 7, "日": 1, "天": 1]
        if let g = AgentQuestion.groups(#"(下个?(?:周|星期|礼拜))([一二三四五六日天])"#, q), let wd = names[Character(g[1])] {
            let nextMonday = today.weekStart.adding(days: 7)
            return (nextMonday.adding(days: Weekday.mondayFirst.firstIndex(of: wd) ?? 0), g[0] + g[1])
        }
        if let g = AgentQuestion.groups(#"((?:这|本)?(?:周|星期|礼拜))([一二三四五六日天])"#, q), let wd = names[Character(g[1])] {
            var d = today.weekStart.adding(days: Weekday.mondayFirst.firstIndex(of: wd) ?? 0)
            if d < today { d = d.adding(days: 7) }
            return (d, g[0] + g[1])
        }
        if let g = AgentQuestion.groups(#"(\d{1,2})\s*月\s*(\d{1,2})\s*[日号]"#, q), let m = Int(g[0]), let dd = Int(g[1]) {
            var c = Calendar.pulse.dateComponents([.year], from: today)
            c.month = m; c.day = dd
            if var d = Calendar.pulse.date(from: c) {
                if d < today { d = Calendar.pulse.date(byAdding: .year, value: 1, to: d) ?? d }
                return (d, "\(g[0])月\(g[1])" + (q.contains("\(g[1])号") ? "号" : "日"))
            }
        }
        if let g = AgentQuestion.groups(#"(?<![月\d])(\d{1,2})\s*号"#, q), let dd = Int(g[0]) {
            var c = Calendar.pulse.dateComponents([.year, .month], from: today)
            c.day = dd
            if var d = Calendar.pulse.date(from: c) {
                if d < today { d = Calendar.pulse.date(byAdding: .month, value: 1, to: d) ?? d }
                return (d, "\(g[0])号")
            }
        }
        if let g = AgentQuestion.groups(#"([0-9一二两三四五六七八九十]+)\s*(天|周|个星期|个月)(?:以?后|之后)"#, q), let n = AgentQuestion.number(g[0]) {
            let k = Int(n)
            let d = g[1] == "天" ? today.adding(days: k) : (g[1] == "个月" ? Calendar.pulse.date(byAdding: .month, value: k, to: today) ?? today : today.adding(days: 7 * k))
            return (d, AgentQuestion.groups(#"([0-9一二两三四五六七八九十]+\s*(?:天|周|个星期|个月)(?:以?后|之后))"#, q)?.first)
        }
        for (w, n) in [("大后天", 3), ("后天", 2), ("明天", 1), ("明早", 1), ("明晚", 1), ("今天", 0), ("今晚", 0)] where q.contains(w) {
            return (today.adding(days: n), w == "明早" || w == "明晚" || w == "今晚" ? nil : w)
        }
        if q.contains("下周") { return (today.weekStart.adding(days: 7), "下周") }
        if q.contains("下个月") { return (Calendar.pulse.date(byAdding: .month, value: 1, to: today), "下个月") }
        return (nil, nil)
    }

    /// 「8 点半」「21:30」, and 「晚上九点」 — a Chinese numeral only right after a part of the day, so
    /// 「多喝一点水」 is no time.
    static let clockDigits = #"(?:早上|上午|中午|下午|傍晚|晚上|今晚|明早|明晚)?\s*(\d{1,2})\s*[点:：]\s*(半|\d{1,2})?\s*分?"#
    static let clockWords = #"(?:早上|上午|中午|下午|傍晚|晚上|今晚|明早|明晚)\s*([一二两三四五六七八九十]{1,3})\s*点\s*(半)?"#

    /// Minutes past midnight: 「8 点」「晚上 9 点半」「下午 3:30」, or a part of the day alone (早上 8:00…).
    static func reminderTime(_ q: String) -> Int? {
        let part = AgentQuestion.groups(#"(早上|上午|中午|下午|傍晚|晚上|今晚|明早|明晚)"#, q)?.first
        if let g = AgentQuestion.groups(clockDigits, q) ?? AgentQuestion.groups(clockWords, q), let h0 = AgentQuestion.number(g[0]) {
            var h = Int(h0)
            let m = g.count > 1 ? (g[1] == "半" ? 30 : Int(g[1]) ?? 0) : 0
            if ["下午", "傍晚", "晚上", "今晚", "明晚"].contains(part ?? ""), h < 12 { h += 12 }
            if part == "中午", h < 6 { h += 12 }
            return (0...23).contains(h) && (0...59).contains(m) ? h * 60 + m : nil
        }
        switch part {
        case "早上", "明早": return 8 * 60
        case "上午": return 9 * 60
        case "中午": return 12 * 60
        case "下午": return 15 * 60
        case "傍晚": return 18 * 60
        case "晚上", "今晚", "明晚": return 20 * 60
        default: return nil
        }
    }
}
