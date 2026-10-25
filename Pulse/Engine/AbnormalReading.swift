import Foundation

// An out-of-range blood pressure or glucose reading is a chance to learn what moves it. Pulse asks
// the user to recall what happened around it — picked from likely causes or written in their own
// words — and keeps it as the reading's note, or hands the question to the Health Agent. When the
// reading needs action first (a low, a very high pressure), that comes before any reflection.

struct AbnormalReading: Equatable {
    enum Direction { case high, low }
    var direction: Direction
    /// Needs action now (a low, or a pressure at a crisis level).
    var severe: Bool
    var title: String
    var valueText: String
    /// Likely causes to pick from, most common first.
    var causes: [String]
    /// What to do before thinking about causes, when the reading needs it.
    var firstLine: String?

    /// The note kept on the reading.
    static func note(causes: [String], text: String) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return [causes.isEmpty ? nil : "可能原因：" + causes.joined(separator: "、"), t.isEmpty ? nil : t].compactMap { $0 }.joined(separator: "；")
    }

    /// What the Health Agent is asked.
    func question(at time: Date, causes picked: [String], text: String) -> String {
        let when = time.isSameDay(.app) ? "今天 \(Clock.text(time.minutesOfDay))" : time.formatted(.dateTime.month().day().hour().minute())
        var q = "我\(when)的\(title.prefix(2))是 \(valueText)，\(title.dropFirst(2))。"
        if !picked.isEmpty { q += "我想到的可能原因：\(picked.joined(separator: "、"))。" }
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { q += "补充：\(t)。" }
        return q + "结合我最近的记录，帮我分析一下可能的原因，下次可以注意什么？"
    }
}

enum AbnormalReadings {
    /// Home blood pressure from 135/85 counts as high (clinic 140/90).
    static func check(_ v: VitalPoint, profile p: ProfileSnapshot) -> AbnormalReading? {
        switch v.kind {
        case .glucose:
            let text = "\(v.value.oneDecimal) mmol/L"
            if v.value < p.glucoseLow {
                return AbnormalReading(direction: .low, severe: true, title: "血糖偏低", valueText: text,
                                       causes: ["运动后或活动比平时多", "没按时吃饭或吃得少", "喝了酒", "用药或注射后没及时进食", "夜里睡着时"],
                                       firstLine: "先按照护计划处理低血糖（通常为 15 g 快速碳水，15 分钟后复测），确认回升后再回想原因。"
                                           + (v.value < 3.0 ? "如出现意识不清或无法进食，请身边的人立即拨打 120。" : ""))
            }
            if v.value > p.glucoseHigh {
                return AbnormalReading(direction: .high, severe: false, title: "血糖偏高", valueText: text,
                                       causes: ["刚吃过饭", "这餐主食偏多", "吃了甜食或含糖饮料", "漏服了药", "压力大或没睡好", "身体不舒服", "今天活动少"],
                                       firstLine: v.value > 13.9 ? "多喝水，按照护计划复测；伴随恶心、呕吐或明显不适请及时就医。" : nil)
            }
        case .bloodPressure:
            let dia = v.value2 ?? 0
            let text = "\(Int(v.value))/\(Int(dia)) mmHg"
            if v.value >= 135 || dia >= 85 {
                let crisis = v.value >= 180 || dia >= 120
                return AbnormalReading(direction: .high, severe: crisis, title: "血压偏高", valueText: text,
                                       causes: ["刚活动或走动后就测", "喝了咖啡或浓茶", "情绪紧张或着急", "漏服了降压药", "没睡好", "饮食偏咸", "测量时没坐好或说话"],
                                       firstLine: crisis ? "先安静坐 5 分钟后复测；仍 ≥180/120 或伴随胸痛、气短、头痛、肢体无力，请立即拨打 120。" : nil)
            }
            if v.value < 90 {
                return AbnormalReading(direction: .low, severe: false, title: "血压偏低", valueText: text,
                                       causes: ["刚起身", "天热或出汗多", "喝水少", "刚服过降压药", "身体不舒服"],
                                       firstLine: "坐下或躺下，缓慢起身；反复头晕或晕厥请咨询医生。")
            }
        default:
            break
        }
        return nil
    }
}
