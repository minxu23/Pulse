import Foundation

// MARK: - The agent's name

/// What the user calls the Health Agent: 「Health Agent」 until they give it a name — in 我的 › Health Agent,
/// or in the chat (「以后叫你小安」). Answers and model instructions use it; the settings path keeps
/// the feature's own name.
enum AgentName {
    static let standard = "Health Agent"
    static let key = "agent.name"
    static let maxLength = 10

    enum Request: Equatable {
        case rename(String)
        /// Back to 「Health Agent」.
        case reset
        /// 「我想给你取个名字」 without one yet.
        case ask
    }

    /// The name as typed, without quotes, spaces or punctuation around it; nil when nothing is left
    /// or it is the standard name.
    static func cleaned(_ s: String) -> String? {
        let edges = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "「」『』“”\"'‘’《》()（）[]【】,，.。、!！?？~～:："))
        let t = s.trimmingCharacters(in: edges)
        guard !t.isEmpty, !t.contains(where: \.isNewline), t.caseInsensitiveCompare(standard) != .orderedSame else { return nil }
        return t
    }

    /// 「问问 Health Agent」 but 「问问小安」: a space only where Chinese meets Latin letters or digits.
    static func phrase(_ before: String, _ name: String, _ after: String = "") -> String {
        func latin(_ c: Character?) -> Bool { c.map { $0.isASCII && ($0.isLetter || $0.isNumber) } ?? false }
        func han(_ c: Character?) -> Bool { c?.unicodeScalars.first.map { (0x4E00...0x9FFF).contains($0.value) } ?? false }
        func gap(_ a: Character?, _ b: Character?) -> String { (latin(a) && han(b)) || (han(a) && latin(b)) ? " " : "" }
        return before + gap(before.last, name.first) + name + gap(name.last, after.first) + after
    }

    // MARK: In the chat

    /// 「以后叫你小安」「你就叫小安吧」「给你取个名字叫小安」「改回原来的名字」. Only a message that is
    /// just the request counts: 「我叫你帮我看看血压」 is a question. Right after 「你想叫我什么？」
    /// (`afterAsking`) the message may be the name alone.
    static func requested(in q: String, afterAsking: Bool = false) -> Request? {
        let t = q.trimmingCharacters(in: .whitespacesAndNewlines)
        if ["改回原来的名字", "恢复原来的名字", "恢复默认名字", "改回默认名字", "用回原来的名字", "叫回原来的名字", "改回原名", "不用给你取名字"].contains(where: t.contains) {
            return .reset
        }
        let name = #"[「“"']?([^，,。！!？?\n「」“”"']{1,16}?)[」”"']?"#
        let end = #"\s*(?:吧|好了|好吗|好不好|行吗|行不行|怎么样|呗)?\s*[。！!～~]*$"#
        let patterns = [
            #"^(?:那|好)?我?(?:以后|今后|从现在起|从今天起|从今以后|还是)?就?(?:想|要)?(?:叫|称呼)你\s*"# + name + end,
            #"^我?(?:可以|能)(?:叫|称呼)你\s*"# + name + #"\s*(?:吗|么|吧|好吗)?\s*[？?。！!]*$"#,
            #"^你(?:以后|今后|从现在起|从今天起)?就?(?:改)?叫\s*"# + name + end,
            #"^我?(?:给|帮)你(?:取|起)(?:个|一个)?(?:新)?名字?[，,]?\s*(?:就)?(?:叫|是)?\s*"# + name + end,
            #"^(?:把)?你的?名字(?:改成|改为|换成|就叫|叫)\s*"# + name + end,
            #"^(?:把你|你)?改名(?:叫|为|成)?\s*"# + name + end,
        ]
        for p in patterns {
            guard let g = AgentQuestion.groups(p, t), let raw = g.first else { continue }
            if ["吧", "呗", "好", "好吗", "好了"].contains(raw) { break }
            return spokenName(raw)
        }
        if afterAsking, t.count <= maxLength + 2 { return spokenName(t) }
        if t.contains("你"), ["取个名字", "取名字", "起个名字", "起名字", "改个名字", "改名字", "换个名字", "取个名", "起个名"].contains(where: t.contains),
           !t.contains("什么"), t.count <= 16 {
            return .ask
        }
        return nil
    }

    /// A name said in the chat; nil when it reads as a request to do something or a question.
    private static func spokenName(_ raw: String) -> Request? {
        if ["帮", "看", "查", "提醒", "告诉", "给我", "什么", "啥", "怎么", "吗", "我", "你", "去", "做", "算", "分析", "？", "?", "不用", "不要", "没事", "随便", "不了", "取消"].contains(where: raw.contains) { return nil }
        guard let n = cleaned(raw) else { return .reset }
        return n.count <= maxLength ? .rename(n) : nil
    }

    /// 「你叫什么名字」「怎么称呼你」.
    static func asksName(_ q: String) -> Bool {
        ["你叫什么", "你叫啥", "你的名字是什么", "你的名字叫什么", "你叫做什么", "怎么称呼你", "该怎么叫你", "你有名字吗", "你有没有名字", "你的名字"]
            .contains(where: q.contains) && requested(in: q) == nil
    }

    /// 「小安，今天能跑步吗」: the question without the name it starts with.
    static func unaddressed(_ q: String, name: String) -> String {
        let t = q.trimmingCharacters(in: .whitespacesAndNewlines)
        for n in Set([name, standard]) where t.count > n.count && t.lowercased().hasPrefix(n.lowercased()) {
            let rest = t.dropFirst(n.count)
            guard let c = rest.first, "，,：: 、!！~～".contains(c) else { continue }
            let q = rest.drop { "，,：: 、!！~～".contains($0) }
            if !q.isEmpty { return String(q) }
        }
        return t
    }

    /// For the language models: the name the user gave, so 「小安」 in a question means them. nil for the standard name.
    static func introduction(_ name: String) -> String? {
        guard name != standard else { return nil }
        return "用户给你取了名字「\(name)」：你就是\(name)，用户叫\(name)就是在叫你；需要称呼自己时用这个名字，不要自称 Health Agent。"
    }

    /// The reply to a rename in the chat (shown as written).
    static func reply(to r: Request) -> AgentReply {
        let text: String
        switch r {
        case .rename(let n): text = "好，以后我就叫\(n)。想换回来，说「改回原来的名字」就行，也可以在「我的 › Health Agent › 名字」里改。"
        case .reset: text = "好，改回「\(standard)」了。想再取名字，直接说「以后叫你…」就行。"
        case .ask: text = "好啊，你想叫我什么？直接说「以后叫你…」就行，最多 \(maxLength) 个字。"
        }
        return AgentReply(text: text, followUps: ["我最近整体怎么样？", "今天适合运动吗？"], intent: .greeting, conclusion: text, verbatim: true)
    }
}
