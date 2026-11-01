import Foundation

// MARK: - How answers are produced

/// How Health Agent answers are produced, chosen by the user (我的 › 回答方式与云端模型).
enum AnswerMode: String, CaseIterable, Identifiable {
    case onDevice, hybrid, cloud
    var id: String { rawValue }

    var label: String {
        switch self {
        case .onDevice: "仅本机"
        case .hybrid: "端云结合"
        case .cloud: "全部云端"
        }
    }

    var icon: String {
        switch self {
        case .onDevice: "iphone"
        case .hybrid: "iphone.and.arrow.forward"
        case .cloud: "cloud"
        }
    }

    var detail: String {
        switch self {
        case .onDevice: "所有问题都由 Apple 智能和 Pulse 规则在本机回答，什么都不发送。"
        case .hybrid: "Pulse 先在本机分析你的记录，把问题和分析要点去掉姓名、电话、证件号、邮箱、地址、医院和医生后，发到云端写回答，再在本机换回原文、补上结论和安全提示。紧急情况和复盘只在本机。没同意发送健康数据时，只发通用问题。"
        case .cloud: "所有问题和复盘都由云端模型回答，提问时会附带数据摘要（同样先去掉姓名、电话等）。回答最好，隐私让步最多。"
        }
    }

    /// What actually happens: a mode whose requirements are not met answers on the device.
    static func effective(_ chosen: AnswerMode, cloudReady: Bool, digestConsented: Bool) -> AnswerMode {
        switch chosen {
        case .onDevice: .onDevice
        case .hybrid: cloudReady ? .hybrid : .onDevice
        case .cloud: cloudReady && digestConsented ? .cloud : .onDevice
        }
    }
}

/// Where one question is answered in 端云结合.
enum AgentRoute: Equatable {
    /// Needs the user's records, or says something about their health. With the user's consent it goes
    /// to the cloud with Pulse's analysis and identifiers masked (`IdentityMask`); without it, it is
    /// answered on this device and nothing is sent. The reason is shown with a local answer.
    case device(String)
    /// A general question: only its text (identifiers masked) goes to the cloud model.
    case general(String)
}

/// Decides, on the device, which questions in 端云结合 are about the user. Questions that need the
/// user's records or reveal their health go out only with consent, and never without Pulse's own
/// analysis; general questions go out as their text alone.
enum AgentRouting {
    /// Answers that are about the user's own records by nature (or need no model at all).
    static let localIntents: Set<AgentIntent> = [.emergency, .greeting, .daySummary, .meds, .device, .planChange, .trainingCheck, .labs,
                                                 .weather, .glucose, .bp, .readiness, .events, .doctor, .next, .overall, .condition,
                                                 .food, .reading, .symptom, .about]
    /// Words that make a question about the asker's own body, records or days.
    static let selfWords = ["我", "本人", "自己", "今天", "明天", "昨天", "昨晚", "今晚", "最近", "这周", "本周", "下周", "上周", "这个月",
                            "周末", "这几天", "刚才", "准备度"]
    /// Words that say the question is about general knowledge rather than the user's numbers.
    static let knowledgeWords = ["是什么", "什么是", "什么意思", "多少算", "正常范围", "正常值", "原理", "区别", "怎么选", "如何选", "推荐",
                                 "哪种", "哪个好", "补给", "装备", "跑鞋", "热身", "拉伸", "跑姿", "呼吸法", "为什么会", "科普"]
    /// Words about how someone feels or what they have.
    static let bodyWords = ["疼", "痛", "晕", "肿", "病", "药", "咳", "烧", "吐", "泻", "便秘", "失眠", "噩梦", "过敏", "痒", "出血", "麻",
                            "抖", "喘", "闷", "累", "乏力", "焦虑", "抑郁", "怀孕", "月经", "经期", "体重", "血"]
    /// Statements of a diagnosis, treatment or reading.
    static let healthStatements = ["我有", "我得了", "我患", "患有", "确诊", "诊断", "怀孕", "我在吃", "我吃的药", "我在用", "病史", "手术", "住院"]

    static func route(_ q: String, reply r: AgentReply, profile p: ProfileSnapshot, name: String) -> AgentRoute {
        if r.urgent || localIntents.contains(r.intent) { return .device("要用到你的健康记录") }
        if !r.blocks.isEmpty { return .device("要用到你的健康记录") }
        let a = AgentQuestion(q)
        if a.reading != nil || a.symptom != nil || a.food != nil { return .device("问题里有你的身体情况") }
        if healthStatements.contains(where: { q.contains($0) }) { return .device("问题里有你的健康信息") }
        if q.range(of: #"\d+(\.\d+)?\s*(mmHg|mmol|bpm|kg|公斤|斤|岁|次/分|%)"#, options: [.regularExpression, .caseInsensitive]) != nil {
            return .device("问题里有你的健康数据")
        }
        // The user's own conditions, medicines and name say something about them.
        let own = p.conditionNames + p.conditions.flatMap { c in ConditionLibrary.builtIn.first { $0.native == c }?.aliases ?? [] }
            + p.medications.map(\.name) + (name.isEmpty || name == "你" ? [] : [name])
        if own.contains(where: { $0.count >= 2 && q.contains($0) }) { return .device("提到了你记录的疾病或用药") }
        let aboutSelf = selfWords.contains { q.contains($0) }
        if r.intent == .unknown || r.intent == .knowledge {
            // Nothing in the records answers it: it may go out unless it describes the user's health.
            if aboutSelf && bodyWords.contains(where: { q.contains($0) }) { return .device("问题里有你的身体情况") }
            return .general(q)
        }
        // A topic Pulse answers from the records (心率, 睡眠, 运动…): only a plain knowledge question goes out.
        if knowledgeWords.contains(where: { q.contains($0) }) && !aboutSelf { return .general(q) }
        return .device("要用到你的健康记录")
    }

    /// The masker for one request: the user's own name always counts; Health Agent's name, the user's
    /// medicines and conditions are never taken for a person.
    static func mask(for c: AgentContext) -> IdentityMask {
        IdentityMask(knownNames: [c.name],
                     keep: [c.agentName, AgentName.standard, "Pulse"] + c.profile.medications.map(\.name) + c.profile.conditionNames)
    }
}

// MARK: - The cloud model, without the user's data

extension HealthAgent {
    /// Instructions for a general question sent without any of the user's records (端云结合).
    static let generalCloudInstructions = """
    你是 Pulse 应用里的健康助手，回答通用的健康、运动、饮食和睡眠问题。
    这个问题没有附带用户的任何健康记录：你看不到用户的数据，不要猜测或编造用户的身体情况、数字或计划。
    要求：
    1. 用口语化的简体中文，不夹英文单词（HRV、CGM 这类通用缩写除外），第一句直接回答问题，再给 2–4 条具体、马上能做的建议，每条单独一行、以「• 」开头。不超过 250 字，不用标题和表格。
    2. 不做诊断；不建议开始、停止或调整任何药物和剂量；需要结合个人情况时，建议咨询医生。
    3. 用户描述胸痛、呼吸困难、晕厥、一侧无力、说话不清等紧急症状时，第一句建议立即拨打 120；否则不要提急救。
    4. 如果要看个人数据才能说准，最后用一句话提醒：可以直接问「我的……怎么样」，Pulse 会在本机结合你的记录回答。
    5. 和健康、身体、运动、饮食、睡眠都无关的问题（比如写诗、编程、股票），只回复这一句：\(offTopicReply)
    """

    /// The prompt for a general question: earlier general exchanges and the question, nothing else.
    static func generalPrompt(question q: String, history: [String]) -> String {
        (history.isEmpty ? "" : "之前的对话：\n" + history.joined(separator: "\n") + "\n\n") + "问题：\(q)"
    }
}
