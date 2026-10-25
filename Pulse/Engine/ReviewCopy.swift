import Foundation

// The 复盘 cards are written by a language model. The rules engine still decides everything that
// matters — the headline verdict, what the summary talks about, numbers, proposals, plan changes —
// and hands them over as facts; the model tells the summary in a coach's voice and writes one
// sentence per item. Every field is checked before it is shown: a number that isn't in the facts,
// a change in the wrong direction, a list of numbers, a missing item or dose advice sends that
// field back to the rules text.

/// The text on a review card set.
struct ReviewCopy: Codable, Equatable {
    var headline: String
    var summary: String
    /// One sentence per item, in the order given in the facts.
    var items: [String]
}

/// What the model is given for one page, and the rules text to fall back on.
struct ReviewFacts: Equatable {
    var kind: String
    var text: String
    var fallback: ReviewCopy
    /// What each item is about (title and reason), used to put the model's sentences under the right item.
    var references: [String] = []
    /// Stable for the same facts, so a page isn't rewritten on every visit.
    var key: String { kind + "-" + String(Self.fnv1a(text), radix: 16) }

    static func fnv1a(_ s: String) -> UInt64 {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return h
    }
}

extension ReviewCopy {
    /// Keeps each field only if it is grounded in the facts; otherwise the rules text. The headline
    /// is the rules' verdict and is never rewritten.
    func checked(against facts: ReviewFacts) -> (copy: ReviewCopy, replaced: Int) {
        var replaced = 0
        func keep(_ text: String, _ fallback: String, max: Int, numbers: Int = .max, causes: Bool = true) -> String {
            let t = Self.spaced(text.trimmingCharacters(in: .whitespacesAndNewlines))
            guard !t.isEmpty, t.count <= max, AgentUI.isSafe(t), Self.numbersGrounded(t, in: facts.text),
                  Self.directionsMatch(t), Self.numbers(in: t).count <= numbers,
                  causes || !Self.causeWords.contains(where: t.contains),
                  !Self.exampleClaims.contains(where: { t.contains($0) && !facts.text.contains($0) }) else { replaced += 1; return fallback }
            return t
        }
        let f = facts.fallback
        // A summary that reads like a list of numbers, or links its points into causes the rules never
        // gave ("…，因为饮酒后…"), goes back to the rules' story.
        var out = ReviewCopy(headline: f.headline, summary: keep(summary, f.summary, max: 220, numbers: 4, causes: false), items: [])
        let refs = facts.references.count == f.items.count ? facts.references : f.items
        let placed = Self.align(items, to: refs)
        out.items = f.items.indices.map { j in
            placed[j].map { keep(Self.droppingTitle($0, of: refs[j]), f.items[j], max: 90) } ?? { replaced += 1; return f.items[j] }()
        }
        return (out, replaced)
    }

    static let causeWords = ["因为", "所以", "导致", "由于", "造成"]

    /// The app's spacing between Chinese and figures or Latin letters ("6周" → "6 周", "6.0bpm" → "6.0 bpm"),
    /// so a model's sentence matches the rules text next to it.
    static func spaced(_ text: String) -> String {
        [(#"(\p{Han})([0-9A-Za-z])"#, "$1 $2"), (#"([0-9A-Za-z%])(\p{Han})"#, "$1 $2"), (#"(\d)([A-Za-z])"#, "$1 $2")]
            .reduce(text) { $0.replacingOccurrences(of: $1.0, with: $1.1, options: .regularExpression) }
    }

    /// The tone example in the instructions, and the claims in it a small model sometimes copies as if
    /// they were about this person ("早点上床" for someone whose sleep is fine).
    static let toneExample = "这周你把计划的训练都练完了，节奏找得不错。睡眠是这周的短板，比上周少了一些。下周我们先试着早点上床，让身体跟上训练。"
    static let exampleClaims = ["节奏找得不错", "短板", "早点上床", "跟上训练"]

    /// "把周六从训练日中移出：近 6 周…" → "近 6 周…": the title is already on the card above the sentence.
    static func droppingTitle(_ item: String, of ref: String) -> String {
        // The reference reads "建议「title」：reason", "下周调整「title」：detail" or "title：detail".
        let title = pairs(String(ref.prefix { $0 != "：" }))
        let chars = Array(item)
        // The first "：" (or ":" outside a time such as 23:30) or "。"; a "，" only after the reference's own
        // label ("下周调整…，"), since a clause before a comma is usually content.
        let labelled = item.hasPrefix("下周调整") || item.hasPrefix("建议")
        guard !title.isEmpty, let i = chars.indices.prefix(31).first(where: { k in
            switch chars[k] {
            case "：", "。": true
            case "，": labelled
            case ":": !(k > 0 && chars[k - 1].isNumber && k + 1 < chars.count && chars[k + 1].isNumber)
            default: false
            }
        }) else { return item }
        let head = pairs(String(chars[..<i])), rest = String(chars[(i + 1)...]).trimmingCharacters(in: .whitespaces)
        guard !rest.isEmpty, !head.isEmpty, Double(head.intersection(title).count) / Double(head.count) >= 0.8 else { return item }
        return rest
    }

    /// "从 72 降到 73" is a wrong direction; every "from A … to B" in the text has to go the way its verb says.
    static func directionsMatch(_ text: String) -> Bool {
        guard let re = try? NSRegularExpression(pattern: #"从\s*±?(\d+(?:\.\d+)?)[^\d，。；,]{0,8}?(降|减|缩|少|低|下|升|增|涨|提|上|多|高|扩)[^\d，。；,]{0,6}?(\d+(?:\.\d+)?)"#) else { return true }
        return re.matches(in: text, range: NSRange(text.startIndex..., in: text)).allSatisfy { m in
            guard let ra = Range(m.range(at: 1), in: text), let rv = Range(m.range(at: 2), in: text), let rb = Range(m.range(at: 3), in: text),
                  let a = Double(text[ra]), let b = Double(text[rb]) else { return true }
            return "降减缩少低下".contains(text[rv]) ? b < a : b > a
        }
    }

    /// Small models sometimes write the items in a different order. Each sentence goes under the item
    /// it clearly talks about (shared wording); the rest keep their position if it is free.
    static func align(_ items: [String], to refs: [String]) -> [String?] {
        var out = [String?](repeating: nil, count: refs.count)
        var used = Set<Int>()
        let pairs = items.indices.flatMap { i in refs.indices.map { j in (i, j, similarity(items[i], refs[j])) } }
            .filter { $0.2 >= 0.15 }
            .sorted { $0.2 > $1.2 }
        for (i, j, _) in pairs where out[j] == nil && !used.contains(i) {
            out[j] = items[i]
            used.insert(i)
        }
        for i in items.indices where !used.contains(i) && i < refs.count && out[i] == nil {
            out[i] = items[i]
        }
        return out
    }

    /// Dice coefficient over character pairs, ignoring spaces and punctuation.
    static func similarity(_ a: String, _ b: String) -> Double {
        let x = pairs(a), y = pairs(b)
        guard !x.isEmpty, !y.isEmpty else { return 0 }
        return 2 * Double(x.intersection(y).count) / Double(x.count + y.count)
    }

    private static func pairs(_ s: String) -> Set<String> {
        let c = Array(s.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
        return c.count < 2 ? [] : Set((0..<(c.count - 1)).map { String(c[$0...$0 + 1]) })
    }

    /// Every number in the text appears in the facts (no made-up figures).
    static func numbersGrounded(_ text: String, in facts: String) -> Bool {
        let known = Set(numbers(in: facts))
        return numbers(in: text).allSatisfy(known.contains)
    }

    /// The figures in a text ("0/2" is two, "5.2" is one).
    static func numbers(in text: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: #"\d+(\.\d+)?"#) else { return [] }
        return re.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { Range($0.range, in: text).map { String(text[$0]) } }
    }
}

extension ReviewCoach {
    /// Facts for the weekly page: the brief, the adoptable proposals and next week's changes.
    static func weeklyFacts(brief b: WeeklyBrief, weekLabel: String, isCurrentWeek: Bool,
                            proposals: [CoachProposal], plan: NextWeekPlan?, priorities: [ReviewPriority] = []) -> ReviewFacts {
        var story = b.story
        story?.next = proposals.first.map(nextStep)
        var lines = ["【周期】\(weekLabel)\(isCurrentWeek ? "（这周还在进行中）" : "")",
                     priorities.isEmpty ? nil : "【优先事项】用户最在意：\(priorities.prefix(3).map(\.area.label).joined(separator: "、"))。先说和这些有关的变化。",
                     "【结论】\(b.headline)",
                     // Only what the summary talks about: given every metric, small models list them all.
                     story?.facts ?? (b.detail.isEmpty ? nil : "【说明】\(b.detail)"),
                     // With a plan, its first change already says how the target follows from this week.
                     plan == nil ? "【下周】\(b.nextWeek)" : nil].compactMap { $0 }
        var items: [String] = []
        var titles: [String] = []
        for p in proposals {
            titles.append("建议「\(p.title)」：\(p.rationale)")
            items.append(p.rationale)
        }
        for c in plan?.changes ?? [] {
            titles.append("下周调整「\(c.title)」：\(c.detail)")
            items.append(c.detail)
        }
        lines.append(titles.isEmpty ? "【条目】无（items 为空）" : "【条目】\n" + titles.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n"))
        return ReviewFacts(kind: "week", text: lines.joined(separator: "\n"),
                           fallback: ReviewCopy(headline: b.headline, summary: story?.text ?? b.detail, items: items), references: titles)
    }

    /// Facts for the long-term page: the verdict, the story to tell and the strategy.
    static func longTermFacts(context c: AgentContext, verdict v: LongTermVerdict, strategy: [AgentPoint]) -> ReviewFacts {
        let story = Self.story(context: c, verdict: v)
        var lines = ["【记录】已记录 \(c.progress.spanDays) 天",
                     "【结论】\(v.title)",
                     story.facts]
        lines.append("【条目】\n" + strategy.enumerated().map { "\($0.offset + 1). 「\($0.element.title)」：\($0.element.detail)" }.joined(separator: "\n"))
        return ReviewFacts(kind: "long", text: lines.joined(separator: "\n"),
                           fallback: ReviewCopy(headline: v.title, summary: story.text, items: strategy.map(\.detail)),
                           references: strategy.map { "\($0.title)：\($0.detail)" })
    }

    static let writerInstructions = """
    你是 Pulse 里的 Health Agent，像一位了解对方的私人教练，正在为「复盘」页写几句话。下面的【…】是 Pulse 根据记录算出的事实，【写作要点】是这次要讲的内容。
    要求：
    1. summary：2–3 句连贯的话，像面对面聊天一样把【写作要点】讲出来：先说主线，再说亮点和难点，最后落到下一步。不超过 110 字，最多引用 2 个数字，不要逐项罗列指标。
    2. 语气温和、具体：亮点真诚地肯定，难点不责备，说成可以一起解决的事。用「你」，可以说「我们一起」；不要用「您」「用户」「咱们」「数据显示」「综上」。
    3. 只说【写作要点】和【条目】里有的内容：不补充别的指标，不改动数字和升降方向，不把整周的变化说成某一天的事；没有依据的夸奖（例如「表现很好」「都有成果」）不要说；不要猜测原因（例如工作忙、压力大），也不要用「因为」「所以」把不同的事连起来；观察到的关联只能说成关联，不要说成已经确定的影响。
    4. items：按【条目】的顺序，把每条的说明改成一两句口语（不超过 50 字），像当面跟对方解释：用短句和日常说法（「次日早晨」说成「第二天早上」，「未完成」说成「没练成」，「摄入」说成「喝」），保留具体的日子、次数和分钟数，括号里的统计细节可以省掉。不要重复条目的标题，不要以「我们」开头，不要用「你将……」「因……」这样生硬的句式，不要在结尾加「这样能……」之类的空话；条数必须与【条目】相同。
    5. 用简体中文；不建议开始、停止或调整任何药物和剂量；不提急救。
    语气示例（内容与你要写的无关，不要照抄）：
    好：「\(ReviewCopy.toneExample)」
    不好：「你这周完成训练，平均睡眠下降，静息心率上升，饮酒减少，醒后精力一般。」
    """

    /// The same, for a cloud model that answers in JSON.
    static let writerJSONFormat = "只输出一个 JSON 对象，不要其他文字：{\"summary\": \"…\", \"items\": [\"…\"]}"

    /// Reads a model's JSON answer (tolerating code fences or text around it).
    static func copy(fromJSON raw: String) -> ReviewCopy? {
        struct Body: Decodable { var summary: String; var items: [String] }
        guard let a = raw.firstIndex(of: "{"), let b = raw.lastIndex(of: "}"), a < b,
              let body = try? JSONDecoder().decode(Body.self, from: Data(raw[a...b].utf8)) else { return nil }
        return ReviewCopy(headline: "", summary: body.summary, items: body.items)
    }
}
