import Foundation

// How a Health Agent answer is laid out. Every answer — the rules' own text or a language model's —
// is read into the same parts, in the same order: a status tag and the verdict, the numbers it
// stands on (tiles and a small chart drawn from the user's records), explanations, lists under a
// title of their own, and the line about when to see a doctor, set apart. The rules engine says
// what the status is and which numbers to show; the text only decides the order of the rest.

/// How the verdict reads at a glance: a coloured glyph and a few words (「还没达标」).
struct AgentStatus: Equatable {
    enum Tone: String, Equatable { case good, attention, urgent }
    var tone: Tone
    var label: String

    static func good(_ label: String) -> AgentStatus { .init(tone: .good, label: label) }
    static func attention(_ label: String) -> AgentStatus { .init(tone: .attention, label: label) }
}

/// The numbers an answer stands on: two or three tiles, and a chart or a split bar drawn from the
/// user's own records. Built by the rules from the same values the verdict uses.
struct AgentFigure: Equatable {
    struct Tile: Equatable {
        var label: String
        var value: String
        var unit = ""
        /// A short line under the value (「目标 130/80」).
        var note: String? = nil
        var tone: AgentStatus.Tone? = nil
    }

    /// One part of a bar that adds up to 100% (time below, in and above the glucose range).
    struct Part: Equatable {
        var label: String
        var share: Double
        var tone: AgentStatus.Tone
    }

    var tiles: [Tile]
    /// A trend chart filled from the records when it is drawn.
    var chart: AgentChartMetric? = nil
    var days = 28
    var parts: [Part] = []
}

enum AgentAnswerLayout {
    enum ListStyle: Equatable {
        /// Things to do.
        case steps
        /// What the records show (「从你的记录看，可能有关的」).
        case findings
    }

    struct Item: Equatable {
        /// 「周三」 in 「周三：原来是…」, shown in bold.
        var label: String?
        var text: String
        /// SF Symbol for what the line is about.
        var icon: String
    }

    enum Section: Equatable {
        /// The first sentence: the answer itself.
        case verdict(String)
        case paragraph(String)
        /// Fine print: where to look in the app, reference ranges.
        case note(String)
        case list(title: String?, style: ListStyle, items: [Item])
        /// When to see a doctor or call 120.
        case safety(String)
    }

    /// The title a list of things to do gets when the answer gives none, in answers that give advice
    /// (not explanations, plan changes or summaries, whose lists are something else).
    static func stepsTitle(for r: AgentReply?) -> String? {
        guard let r, !r.verbatim, !r.urgent else { return nil }
        let advice: Set<AgentIntent> = [.bp, .glucose, .sleep, .rhr, .hrv, .readiness, .trainingCheck, .reading, .symptom, .food, .diet,
                                        .alcohol, .caffeine, .stress, .breathing, .weather, .labs, .marathon, .exercise, .meds, .unknown]
        return advice.contains(r.intent) ? "可以这样做" : nil
    }

    /// The parts of an answer, in the order written. Works on a half-written answer too, so a
    /// streamed answer takes its final shape as it arrives.
    static func sections(of text: String, reply r: AgentReply?, cards: [AgentUIBlock] = []) -> [Section] {
        leavingOut(cards.compactMap(\.proposal),
                   from: sections(of: text, conclusion: r?.conclusion, safety: r?.safety, status: r?.status, stepsTitle: stepsTitle(for: r)))
    }

    static func sections(of text: String, conclusion: String? = nil, safety: String? = nil, status: AgentStatus? = nil,
                         stepsTitle: String? = nil) -> [Section] {
        // Lines, each a paragraph or a list item; a blank line only separates lists.
        enum Token { case text(String), item(String), gap }
        var tokens: [Token] = []
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { if case .gap? = tokens.last {} else if !tokens.isEmpty { tokens.append(.gap) }; continue }
            if let item = listItem(line) { tokens.append(.item(item)) } else { tokens.append(.text(line)) }
        }

        var out: [Section] = []
        var title: String? = nil
        var items: [String] = []
        var safetyShown = false
        /// The verdict ends in a colon and leads the list below it.
        var verdictLeads = false
        func closeList() {
            guard !items.isEmpty else { title = nil; return }
            let style = style(title: title)
            let made = items.map { item($0, style: style) }
            // Lines a model spaced out one by one belong together.
            if title == nil, case .list(let t, let s, let before)? = out.last, s == style {
                out[out.count - 1] = .list(title: t, style: s, items: before + made)
            } else {
                // A list straight under the verdict (「接下来最值得做的三件事：」) needs no title of its own.
                let underVerdict = verdictLeads && out.count == 1
                out.append(.list(title: title ?? (style == .steps && !underVerdict ? stepsTitle : nil), style: style, items: made))
            }
            items = []
            title = nil
        }

        for (i, token) in tokens.enumerated() {
            switch token {
            case .gap:
                // A gap after a title keeps it for the list below (「其他化验结果：」, blank line, list).
                if !items.isEmpty { closeList() }
            case .item(let line):
                items.append(line)
            case .text(let line):
                closeList()
                let next = tokens.dropFirst(i + 1).first { if case .gap = $0 { false } else { true } }
                var leadsList = false
                if case .item? = next { leadsList = true }
                let isTitle = leadsList && (line.hasSuffix("：") || line.hasSuffix(":")) && line.count <= 40
                if out.isEmpty {
                    // The verdict: the pinned conclusion, or the first sentence.
                    let (head, rest) = verdict(of: line, conclusion: conclusion, status: status)
                    verdictLeads = isTitle && rest == nil
                    out.append(.verdict(isTitle ? trimmedColon(head) : head))
                    if let rest { out.append(contentsOf: paragraphs(rest, safety: safety, shown: &safetyShown)) }
                } else if isTitle {
                    title = trimmedColon(line)
                } else {
                    out.append(contentsOf: paragraphs(line, safety: safety, shown: &safetyShown))
                }
            }
        }
        closeList()
        return out
    }

    /// What a plan card below the answer already shows — the day-by-day changes and their notes —
    /// is not said again above it.
    static func leavingOut(_ proposals: [PlanChangeProposal], from sections: [Section]) -> [Section] {
        guard !proposals.isEmpty else { return sections }
        let days = Set(proposals.flatMap(\.lines).map { Weekday.name($0.weekday) })
        let notes = proposals.flatMap(\.notes)
        return sections.compactMap { s in
            switch s {
            case .list(let title, let style, let items):
                let kept = items.filter { !($0.label.map(days.contains) ?? false) }
                return kept.isEmpty ? nil : .list(title: title, style: style, items: kept)
            case .paragraph(let t), .note(let t):
                return notes.contains(t) ? nil : s
            default:
                return s
            }
        }
    }

    // MARK: Parts

    /// The verdict and what follows it in the same paragraph. A status label already shown as the
    /// tag (「还没达标：」) is left out of the sentence.
    static func verdict(of line: String, conclusion: String?, status: AgentStatus?) -> (String, String?) {
        var head: String
        if let c = conclusion?.trimmingCharacters(in: .whitespacesAndNewlines), !c.isEmpty, line.hasPrefix(c), c.count <= 90 {
            head = c
        } else {
            head = firstSentence(line)
        }
        let rest = String(line.dropFirst(head.count)).trimmingCharacters(in: .whitespaces)
        if let label = status?.label {
            for sep in ["：", ":", "，"] where head.hasPrefix(label + sep) && head.count > label.count + 4 {
                head = String(head.dropFirst(label.count + 1))
            }
        }
        return (head, rest.isEmpty ? nil : rest)
    }

    /// Up to the first full stop; a short line stays whole.
    static func firstSentence(_ s: String) -> String {
        guard s.count > 24, let end = s.firstIndex(where: { "。！？!?".contains($0) }) else { return s }
        let head = String(s[...end])
        // A sentence of a few characters (「好的。」) reads better with the next one.
        if head.count < 8, let more = s[s.index(after: end)...].firstIndex(where: { "。！？!?".contains($0) }) { return String(s[...more]) }
        return head
    }

    private static func paragraphs(_ line: String, safety: String?, shown: inout Bool) -> [Section] {
        if !shown, let s = safety, isSafety(line, safety: s) {
            shown = true
            return [.safety(line)]
        }
        return [isNote(line) ? .note(line) : .paragraph(line)]
    }

    /// The safety line as written, or a model's wording of it.
    static func isSafety(_ line: String, safety s: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        return t == s || t.contains(s) || HealthAgent.says(t, safety: s)
    }

    /// Fine print: pointers to a page, reference ranges, how often to recheck.
    static func isNote(_ line: String) -> Bool {
        guard line.count <= 70 else { return false }
        let patterns = [#"^在「[^」]+」(里|中)"#, #"以[^。，]{1,8}为准。?$"#, #"^各医院"#, #"（「我的 ›[^」]+」[^）]*）。?$"#]
        return patterns.contains { line.range(of: $0, options: .regularExpression) != nil }
    }

    /// A paragraph that only repeats the figure's numbers (「近 14 天 CGM：目标范围内 66%…」): left
    /// out when the figure is shown. It needs two measured values at least, all of them in the figure.
    static func restates(_ line: String, figure: AgentFigure) -> Bool {
        let values = highlights(in: line).map { numbers(in: String(line[$0])) }.flatMap { $0 }
        guard values.count >= 2 else { return false }
        let shown = Set(figure.tiles.flatMap { numbers(in: [$0.value, $0.note ?? ""].joined(separator: " ")) }
                        + figure.parts.flatMap { numbers(in: String(format: "%.1f %.0f", $0.share * 100, $0.share * 100)) })
        return values.allSatisfy(shown.contains)
    }

    /// The numbers in a piece of text, as written (「1.0」 stays 「1.0」).
    static func numbers(in s: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: #"\d+(?:\.\d+)?"#) else { return [] }
        return re.matches(in: s, range: NSRange(s.startIndex..., in: s)).compactMap { Range($0.range, in: s).map { String(s[$0]) } }
    }

    /// The text of a list line, without its marker; nil for a plain line.
    static func listItem(_ line: String) -> String? {
        for marker in ["• ", "•", "· ", "- ", "* ", "– "] where line.hasPrefix(marker) {
            let t = String(line.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
            return t.isEmpty ? nil : t
        }
        // 「1. 」「2、」「(3) 」, but not 「1.5 小时」.
        if let r = line.range(of: #"^(\d{1,2}(?:\.(?!\d)|[、)）])|[（(]\d{1,2}[)）])\s*"#, options: .regularExpression) {
            let t = String(line[r.upperBound...]).trimmingCharacters(in: .whitespaces)
            return t.isEmpty ? nil : t
        }
        return nil
    }

    private static func trimmedColon(_ s: String) -> String {
        var t = s.replacingOccurrences(of: "**", with: "")
        while t.hasSuffix("：") || t.hasSuffix(":") { t.removeLast() }
        return t.trimmingCharacters(in: .whitespaces)
    }

    /// Findings are what the records show; everything else is a list of things to do.
    static func style(title: String?) -> ListStyle {
        guard let t = title else { return .steps }
        return ["记录看", "可能有关", "关联", "化验结果", "影响", "原因", "拖住"].contains { t.contains($0) } ? .findings : .steps
    }

    static func item(_ line: String, style: ListStyle) -> Item {
        var text = line.trimmingCharacters(in: CharacterSet(charactersIn: "；; "))
        var label: String? = nil
        // 「周三：…」「还要加把劲：…」「早饭：…」: a short label before the colon.
        if let r = text.range(of: "：") ?? text.range(of: ": ") {
            let head = String(text[..<r.lowerBound]).replacingOccurrences(of: "**", with: "")
            let rest = String(text[r.upperBound...]).trimmingCharacters(in: .whitespaces)
            if (1...8).contains(head.count), !head.contains("，"), !rest.isEmpty {
                label = head
                text = rest
            }
        }
        return Item(label: label, text: text, icon: icon(for: (label ?? "") + text) ?? (style == .steps ? "checkmark.circle" : "doc.text.magnifyingglass"))
    }

    /// A glyph for what a line is about, by the first topic word it names. Decorative: the words say it all.
    static func icon(for s: String) -> String? {
        let topics: [(String, [String])] = [
            ("phone.fill", ["120", "急诊"]),
            ("stethoscope", ["医生", "就医", "复诊", "门诊", "看病", "医院", "营养师", "透析中心"]),
            ("pills.fill", ["药", "胰岛素"]),
            ("testtube.2", ["化验", "eGFR", "肌酐", "血钾", "血磷", "血红蛋白", "尿酸", "尿白蛋白", "糖化", "复查"]),
            ("drop.fill", ["血糖", "低血糖", "碳水", "CGM"]),
            ("heart.fill", ["血压", "袖带", "收缩压", "舒张压"]),
            ("waveform.path.ecg", ["静息心率", "心率", "HRV", "心率变异性"]),
            ("lungs.fill", ["打鼾", "憋醒", "呼吸暂停", "呼吸机", "睡眠监测", "血氧"]),
            ("bed.double.fill", ["睡", "作息", "起床", "上床", "午睡", "熬夜", "夜班", "补觉"]),
            ("wineglass", ["酒"]),
            ("cup.and.saucer.fill", ["咖啡", "浓茶", "奶茶"]),
            ("waterbottle.fill", ["喝水", "饮水", "喝了汤", "限水", "水分"]),
            ("fork.knife", ["盐", "吃", "饭", "菜", "水果", "主食", "粗粮", "蛋白质", "饮食", "零食", "果汁"]),
            ("scalemass.fill", ["体重", "称"]),
            ("figure.walk", ["散步", "快走", "走路", "步行", "徒步"]),
            ("figure.run", ["跑", "训练", "运动", "有氧", "力量", "骑", "游泳", "热身", "强度", "组数", "重量", "活动", "练"]),
            ("figure.cooldown", ["拉伸", "放松", "慢呼吸", "冥想", "压力"]),
            ("calendar", ["周一", "周二", "周三", "周四", "周五", "周六", "周日", "明天", "下周"]),
            ("square.and.pencil", ["记下", "记录", "记在"]),
        ]
        return topics.first { $0.1.contains { s.contains($0) } }?.0
    }

    /// Ranges of measured values to set in bold: 「142/86」「6.5 小时」「68%」「5.4 mmol/L」.
    static func highlights(in s: String) -> [Range<String.Index>] {
        let units = "mmHg|mmol/L|μmol/L|umol/L|mg/g|g/L|mL/min(?:/1\\.73m²)?|bpm|ms|kg|公斤|斤|小时|分钟|毫升|ml|mL|g|次/分|分"
        let n = #"\d+(?:\.\d+)?"#
        // A range counts as one value: 「10–15 分钟」「60–70%」.
        let pattern = n + "/" + n + "|" + n + "(?:[–~-]" + n + ")?" + #"\s?(?:%|(?:"# + units + #")(?![A-Za-z]))"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = NSRange(s.startIndex..., in: s)
        return re.matches(in: s, range: ns).compactMap { Range($0.range, in: s) }
    }
}

// MARK: - Figures from the records

extension AgentFigure {
    /// Blood pressure over 30 days against the target.
    static func bloodPressure(_ c: AgentContext) -> AgentFigure? {
        let s = c.bp
        guard s.count > 0, let sys = s.avgSys, let dia = s.avgDia else { return nil }
        let p = c.profile
        let ok = Int(sys) <= p.bpTargetSys && Int(dia) <= p.bpTargetDia
        // mmHg goes without saying; the value keeps its full size.
        var tiles = [Tile(label: "30 天平均", value: "\(Int(sys))/\(Int(dia))", note: "目标 \(p.bpTargetSys)/\(p.bpTargetDia)",
                          tone: ok ? .good : .attention)]
        if let r = s.inTargetRate {
            tiles.append(Tile(label: "在目标内", value: "\(Int((r * 100).rounded()))", unit: "%", note: "\(s.count) 次测量", tone: r >= 0.7 ? .good : .attention))
        }
        if let m = s.morningSys, let e = s.eveningSys {
            tiles.append(Tile(label: "晨起 / 晚上", value: "\(Int(m))/\(Int(e))", note: "收缩压", tone: m - e >= 10 ? .attention : nil))
        }
        return AgentFigure(tiles: tiles, chart: .bp, days: 30)
    }

    /// Time in range over 14 days, as tiles and the classic below / in / above bar.
    static func glucose(_ c: AgentContext) -> AgentFigure? {
        let m = c.glucose
        guard m.readings > 0, let tir = m.tir else { return nil }
        var tiles = [Tile(label: "目标范围内", value: "\(Int((tir * 100).rounded()))", unit: "%", note: "一般希望 >70%", tone: tir >= 0.7 ? .good : .attention)]
        if let tbr = m.tbr { tiles.append(Tile(label: "低于范围", value: String(format: "%.1f", tbr * 100), unit: "%", note: "参考 <4%", tone: tbr < 0.04 ? .good : .attention)) }
        if let mean = m.mean { tiles.append(Tile(label: "平均", value: mean.oneDecimal, unit: "mmol/L", note: m.cv.map { "波动 CV \(Int($0))%" })) }
        var parts: [Part] = []
        if let tbr = m.tbr, let tar = m.tar {
            parts = [Part(label: "低于", share: tbr, tone: .urgent), Part(label: "范围内", share: tir, tone: .good), Part(label: "高于", share: tar, tone: .attention)]
        }
        return AgentFigure(tiles: tiles, chart: nil, days: 14, parts: parts)
    }

    /// Resting heart rate: this week, the month and the personal baseline.
    static func rhr(_ c: AgentContext) -> AgentFigure? {
        let t = c.trend
        guard let a7 = t.avg7, t.points.count >= 3 else { return nil }
        var tiles = [Tile(label: "近 7 天平均", value: a7.noDecimal, unit: "bpm")]
        if let b = t.baseline {
            tiles.append(Tile(label: "个人基线", value: b.noDecimal, unit: "bpm"))
            let d = a7 - b
            tiles.append(Tile(label: "和基线比", value: d.signedText, unit: "bpm", tone: d <= 1 ? .good : (d >= 3 ? .attention : nil)))
        } else if let a28 = t.avg28 {
            tiles.append(Tile(label: "近 4 周", value: a28.noDecimal, unit: "bpm"))
        }
        return AgentFigure(tiles: tiles, chart: .rhr, days: 28)
    }

    static func hrv(_ c: AgentContext) -> AgentFigure? {
        guard let a = Stats.mean(c.recent7.compactMap(\.hrv)) else { return nil }
        var tiles = [Tile(label: "近 7 天平均", value: a.noDecimal, unit: "ms")]
        if let m = Stats.mean(c.days.filter { $0.day > c.now.adding(days: -28) }.compactMap(\.hrv)) {
            tiles.append(Tile(label: "近 4 周", value: m.noDecimal, unit: "ms"))
        }
        return AgentFigure(tiles: tiles, chart: .hrv, days: 28)
    }

    /// Sleep over 14 nights against the need.
    static func sleep(_ c: AgentContext) -> AgentFigure? {
        let s = c.sleep
        guard let avg = s.avgMinutes, s.nights > 0 else { return nil }
        let need = c.profile.sleepNeedMinutes
        var tiles = [Tile(label: "平均每晚", value: (avg / 60).oneDecimal, unit: "小时", note: "目标 \((need / 60).oneDecimal)",
                          tone: avg >= need - 30 ? .good : .attention)]
        tiles.append(Tile(label: "睡够的晚上", value: "\(s.nightsMeetingNeed)/\(s.nights)", tone: s.nightsMeetingNeed * 2 >= s.nights ? .good : .attention))
        if let b = s.avgBedtime { tiles.append(Tile(label: "平均入睡", value: Clock.text(b))) }
        return AgentFigure(tiles: tiles, chart: .sleep, days: 14)
    }

    /// Today's readiness score with the training load beside it.
    static func readiness(_ c: AgentContext) -> AgentFigure? {
        guard let score = c.readiness.score else { return nil }
        let level = c.readiness.level
        var tiles = [Tile(label: "今天准备度", value: "\(score)", note: level.label, tone: [.high, .moderate].contains(level) ? .good : .attention)]
        // Two of what the score was made from, as the score saw them.
        for f in c.readiness.factors where ["sleep", "rhr"].contains(f.id) && f.available {
            let v = f.value.split(separator: " ", maxSplits: 1).map(String.init)
            tiles.append(Tile(label: f.name, value: v.first ?? f.value, unit: v.count > 1 ? v[1] : "",
                              tone: f.impact == .negative ? .attention : (f.impact == .positive ? .good : nil)))
        }
        return AgentFigure(tiles: tiles)
    }

    /// Kidney function: the latest eGFR, its stage and how fast it moves.
    static func kidney(_ c: AgentContext) -> AgentFigure? {
        guard let e = LabAnalyzer.latest(c.labs).first(where: { $0.kind == .egfr }) else { return nil }
        let st = LabAnalyzer.status(.egfr, e.value, profile: c.profile)
        // Its unit (mL/min/1.73m²) is too long for a tile and goes without saying.
        var tiles = [Tile(label: "最近 eGFR", value: e.valueText, note: e.date.formatted(.dateTime.month().day()),
                          tone: st.level >= .abnormal ? .attention : .good)]
        let series = LabAnalyzer.egfrSeries(c.labs)
        if let t = LabAnalyzer.egfrTrend(c.labs), let slope = egfrPerYear(c.labs), let first = series.first, let last = series.last {
            let months = Int((last.date.timeIntervalSince(first.date) / 86400 / 30).rounded())
            tiles.append(Tile(label: "每年变化", value: abs(slope) < 0.5 ? "0" : String(format: "%+.0f", slope),
                              note: t.fast ? "下降较快" : "近 \(months) 个月", tone: t.fast ? .attention : nil))
        }
        if let k = LabAnalyzer.latest(c.labs).first(where: { $0.kind == .potassium }) {
            let ks = LabAnalyzer.status(.potassium, k.value, profile: c.profile)
            tiles.append(Tile(label: "血钾", value: k.valueText, unit: "mmol/L", tone: ks.level >= .abnormal ? .attention : .good))
        }
        let span = series.first.map { max(90, c.now.daysSince($0.date) + 1) } ?? 365
        return AgentFigure(tiles: tiles, chart: .egfr, days: span)
    }

    /// The yearly change in eGFR, by the same rule as `LabAnalyzer.egfrTrend` (≥ 3 results over ≥ 6 months).
    static func egfrPerYear(_ labs: [LabPoint]) -> Double? {
        let s = LabAnalyzer.egfrSeries(labs)
        guard s.count >= 3, let first = s.first, let last = s.last, last.date.timeIntervalSince(first.date) / 86400 >= 180 else { return nil }
        let xs = s.map { $0.date.timeIntervalSince(first.date) / 86400 / 365 }
        let ys = s.map(\.value)
        let mx = xs.reduce(0, +) / Double(xs.count), my = ys.reduce(0, +) / Double(ys.count)
        let den = xs.map { ($0 - mx) * ($0 - mx) }.reduce(0, +)
        guard den > 0 else { return nil }
        return zip(xs, ys).map { ($0 - mx) * ($1 - my) }.reduce(0, +) / den
    }
}
