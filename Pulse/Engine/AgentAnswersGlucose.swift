import Foundation

// MARK: - Why glucose runs high or low

extension HealthAgent {
    /// The part of the day a question about glucose names.
    private enum Moment: Equatable {
        case morning, meal(String, Range<Int>), afterMeals, evening, night, swings, any

        var name: String {
            switch self {
            case .morning: "早上"
            case .meal(let n, _): n + "后"
            case .afterMeals: "饭后"
            case .evening: "晚上"
            case .night: "半夜"
            case .swings, .any: ""
            }
        }
        var hours: [Int] {
            switch self {
            case .morning: Array(5..<8)
            case .meal(_, let h): Array(h)
            case .afterMeals: Array(8..<11) + Array(12..<16) + Array(19..<23)
            case .evening: Array(18..<23)
            case .night: Array(0..<5)
            case .swings, .any: Array(0..<24)
            }
        }
    }

    private static func moment(_ a: AgentQuestion) -> Moment {
        if a.has(["波动", "忽高忽低", "不稳"]) { return .swings }
        if a.has(["饭后", "餐后"]) { return AgentQuestion.meal(a.text).map { .meal($0.name, $0.hours) } ?? .afterMeals }
        if a.has(["半夜", "夜里", "凌晨"]) { return .night }
        if a.has(["早上", "早晨", "清晨", "空腹", "起床", "晨起"]) { return .morning }
        if a.has(["晚上", "睡前", "晚间"]) { return .evening }
        return .any
    }

    /// 「为什么我的血糖早上高」: first whether it does, in this person's own numbers for that part of
    /// the day; then the usual reasons, kept as possibilities, and only what the records can back
    /// as theirs. A number in the question (「血糖12为什么这么高」) is `glucoseReading`'s.
    static func glucoseWhy(_ a: AgentQuestion, context c: AgentContext) -> AgentReply? {
        guard a.has(["血糖"]), !a.has(["药", "胰岛素"]),
              a.form == .why || a.has(["什么原因", "怎么这么高", "这么高", "老是高", "总是高", "一直高", "怎么这么低", "老是低", "忽高忽低"]),
              a.has(["高", "低", "波动", "不稳"]) else { return nil }
        let p = c.profile
        let m = c.glucose
        let when = moment(a)
        let low = a.has(["血糖低", "血糖偏低", "低血糖", "血糖老是低", "血糖这么低", "血糖怎么这么低", "血糖会低"]) || (a.has(["低"]) && !a.has(["高"]))
        let values = c.vitals.filter { $0.kind == .glucose && $0.time > c.now.adding(days: -14) && when.hours.contains($0.time.hour) }.map(\.value)
        let upper = when == .morning ? (p.hasDiabetes ? 7.0 : 6.1) : p.glucoseHigh
        let average = Stats.mean(values)
        let above = values.isEmpty ? 0 : Double(values.filter { $0 > upper }.count) / Double(values.count)
        let below = values.filter { $0 < p.glucoseLow }.count
        let enough = values.count >= 3
        let place = when.name + "的"
        let during = when.name.isEmpty ? "" : (when == .morning ? "早饭前" : when.name)

        var first: String
        var status: AgentStatus? = nil
        if !enough {
            first = "你的记录里还没有足够的\(when.name)血糖，看不出你是不是这样；下面是常见的原因。"
        } else if when == .swings {
            let cv = m.cv.map { Int($0.rounded()) }
            if let cv, cv > 36 {
                first = "你的血糖确实波动偏大：近 14 天波动系数 \(cv)%，一般希望在 36% 以内。"
                status = .attention("波动偏大")
            } else if let cv {
                first = "从记录看，你的血糖波动不算大：近 14 天波动系数 \(cv)%，一般希望在 36% 以内。"
                status = .good("波动不算大")
            } else {
                first = "你的记录里还没有足够的血糖，算不出波动有多大；下面是常见的原因。"
            }
        } else if low {
            first = below > 0 ? "近 14 天\(during)有 \(below) 个读数低于 \(p.glucoseLow.oneDecimal)，平均 \(average?.oneDecimal ?? "—") mmol/L。"
                : "从记录看，你\(place)血糖并不低：近 14 天\(during)平均 \(average?.oneDecimal ?? "—") mmol/L，没有低于 \(p.glucoseLow.oneDecimal) 的读数。"
            status = below > 0 ? .attention("有过偏低") : .good("并不低")
        } else if (average ?? 0) > upper || above >= 0.3 {
            let share = Int((above * 100).rounded())
            first = "你\(place)血糖确实偏高：近 14 天\(during)平均 \(average?.oneDecimal ?? "—") mmol/L，\(share)% 的读数高于 \(upper.oneDecimal)。"
            status = .attention("确实偏高")
        } else {
            first = "从记录看，你\(place)血糖并不高：近 14 天\(during)平均 \(average?.oneDecimal ?? "—") mmol/L，\(Int((above * 100).rounded()))% 的读数高于 \(upper.oneDecimal)。"
            status = .good("并不高")
        }
        // 「为什么血糖老是高」 names no time: where it runs high is the first thing to know.
        var parts: [String?] = [first]
        if when == .any, !low, enough {
            let windows: [(String, Range<Int>)] = [("早饭后", 8..<11), ("午饭后", 12..<16), ("晚饭后", 19..<23), ("夜里", 0..<6)]
            let top = windows.compactMap { w -> (String, Double)? in
                let v = c.vitals.filter { $0.kind == .glucose && $0.time > c.now.adding(days: -14) && w.1.contains($0.time.hour) }.map(\.value)
                return v.count >= 10 ? (w.0, Double(v.filter { $0 > p.glucoseHigh }.count) / Double(v.count)) : nil
            }.max { $0.1 < $1.1 }
            if let top, top.1 >= 0.3 { parts.append("偏高的时候多在\(top.0)：这段时间有 \(Int((top.1 * 100).rounded()))% 高于 \(p.glucoseHigh.oneDecimal)。") }
        }

        var reasons: [String]
        var steps: [String]
        var doctor = p.hasDiabetes ? "连续两周都这样，带着记录问医生要不要调整方案（药怎么调由医生定）。" : "还偏高的话，去医院查空腹血糖和糖化血红蛋白。"
        if low {
            reasons = ["这顿吃得少、主食少了，或者吃饭比平时晚", "运动量比平时大，运动后几小时都可能偏低", "空腹喝了酒"]
            if p.hasDiabetes { reasons.append("降糖药或胰岛素的作用比需要的强") }
            steps = ["手边备点升糖快的，比如方糖或果汁", "记下偏低的时间、前面吃了什么、动了多少"]
            doctor = "反复偏低要尽快告诉医生；手抖、出汗、心慌时先吃糖，15 分钟后再测。"
        } else {
            switch when {
            case .morning:
                reasons = ["清晨身体会分泌升糖的激素，这叫黎明现象，很常见", "晚饭太晚、吃得太多，或者吃了夜宵", "前一晚没睡好"]
                steps = ["晚饭别太晚、别太多，睡前不吃夜宵", "连着几天测空腹血糖，看是不是一直高"]
            case .meal, .afterMeals:
                reasons = ["这顿主食多，或者白米白面这类升得快的吃得多", "吃得快，先吃了主食", "饭后坐着不动"]
                if case .meal(let n, _) = when, n == "早饭" { reasons.insert("早上身体对胰岛素没那么敏感，同样的饭，早饭后升得更高", at: 0) }
                steps = ["饭后散步 10–15 分钟，对餐后血糖最直接", "先吃菜和肉，主食放最后，一餐一拳头，换一半成粗粮"]
            case .evening, .night:
                reasons = ["晚饭主食多、吃得晚，或者吃了夜宵", "白天活动少", "压力大、没睡好"]
                steps = ["晚饭主食定量，饭后散步 10–15 分钟", "连着几天测睡前血糖，看是不是一直高"]
            case .swings:
                reasons = ["主食量和吃饭时间不固定", "有时运动、有时不动", "睡眠不规律，压力大"]
                steps = ["主食定量、吃饭定时", "记几天饮食和血糖，在「血糖管理」里看是哪顿升得多"]
            case .any:
                reasons = ["主食吃得多，或者白米白面这类升得快的吃得多", "活动少，饭后坐着不动", "没睡好、压力大"]
                steps = ["饭后散步 10–15 分钟，对餐后血糖最直接", "先吃菜和肉，主食放最后，一餐一拳头，换一半成粗粮"]
            }
        }
        // Told it doesn't happen, what to do about it would only confuse.
        let fine = status?.tone == .good
        parts.append((fine ? "偶尔\(low ? "偏低" : "偏高")的话，" : "") + "常见的原因（不一定都是你的情况）：\n" + (bullets(reasons) ?? ""))
        // Only what the records back; 「还看不出」 adds nothing to an answer about causes.
        if !low {
            let morning = when == .morning
            for line in [ownDays(.lateMeal, .glucose, context: c, morning: morning), ownDays(.shortSleep, .glucose, context: c, morning: morning)] {
                if let line, !line.hasPrefix("从你的记录还看不出") { parts.append(line) }
            }
        }
        if when == .morning || when == .night, !low, c.lows.contains(where: \.nocturnal) {
            parts.append("你近 14 天夜里有 \(c.lows.filter(\.nocturnal).count) 次低血糖：夜里偏低后，早上血糖可能反弹升高，这一点要告诉医生。")
        }
        if !fine {
            parts.append(bullets(steps))
            parts.append(doctor)
        }
        var r = AgentReply(text: lines(parts), sources: [m.readings > 0 ? "血糖 近 14 天" : "血糖常识"], followUps: ["今天吃什么好？"], destination: .glucose,
                           intent: .glucose, conclusion: first, safety: fine ? nil : doctor)
        r.status = status
        r.figure = m.readings > 0 ? .glucose(c) : nil
        r.asWrittenOnDevice = true
        return r
    }
}
