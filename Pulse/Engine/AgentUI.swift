import Foundation

// Generative UI for the Health Agent. In conversations that need more than a paragraph — choosing
// days, comparing a plan before and after, setting up a device — the agent (rules engine or cloud
// model) answers with components from a small fixed catalog. The app validates every block, fills
// charts from the user's own records (a model only names the metric) and renders it natively; what
// the user picks or submits goes back into the conversation.

enum AgentChartMetric: String, CaseIterable, Equatable {
    case rhr, sleep, activity, glucose, bp, wear
    var title: String {
        switch self {
        case .rhr: "静息心率"
        case .sleep: "睡眠时长"
        case .activity: "每日活动"
        case .glucose: "CGM 血糖"
        case .bp: "血压"
        case .wear: "佩戴与数据记录"
        }
    }
    /// Sensible window in days (the CGM curve shows hours, so it is capped at 3 days).
    func clampDays(_ d: Int) -> Int { self == .glucose ? min(max(d, 1), 3) : min(max(d, 7), 90) }
}

struct AgentFormField: Equatable, Identifiable {
    enum Kind: Equatable {
        case choice(options: [String], multiple: Bool)
        case weekdays
        case number(min: Int, max: Int, step: Int, unit: String, value: Int)
        case toggle
    }
    var id: String
    var label: String
    var kind: Kind
}

/// A short form the agent asks the user to fill in, e.g. which days are busy.
struct AgentForm: Equatable {
    var id: String
    var title: String
    var fields: [AgentFormField]
    var submitLabel: String
    /// The request the answers belong to; sent back together with them.
    var context: String
    /// A single single-choice question is answered with one tap.
    var submitsOnTap: Bool {
        guard fields.count == 1, case .choice(_, false) = fields[0].kind else { return false }
        return true
    }

    /// Turns the answers into the message that goes back to the agent.
    func message(_ answers: [String: String]) -> String {
        let parts = fields.compactMap { f -> String? in
            guard let a = answers[f.id], !a.isEmpty else { return nil }
            return "\(f.label.trimmingCharacters(in: CharacterSet(charactersIn: "？?：: ")))：\(a)"
        }
        let joined = parts.joined(separator: "；")
        return context.isEmpty ? joined : "\(context)。\(joined)"
    }
}

struct AgentChecklistItem: Equatable, Identifiable {
    var id: String
    var title: String
    var detail: String
}

struct AgentChecklist: Equatable {
    var id: String
    var title: String
    var items: [AgentChecklistItem]
}

struct AgentStep: Equatable, Identifiable {
    var id: String { title }
    var icon: String
    var title: String
    var detail: String
}

struct AgentSteps: Equatable {
    var title: String
    var steps: [AgentStep]
}

enum AgentUIBlock: Equatable, Identifiable {
    case form(AgentForm)
    case chart(AgentChartMetric, days: Int, caption: String?)
    case checklist(AgentChecklist)
    case steps(AgentSteps)
    case plan(PlanChangeProposal)
    /// A condition the user mentioned, to record (记下).
    case condition(ConditionProposal)
    /// A reading, water, a symptom or a reminder the user asked to record (记下).
    case record(RecordProposal)

    var id: String {
        switch self {
        case .form(let f): "form-\(f.id)"
        case .chart(let m, let d, _): "chart-\(m.rawValue)-\(d)"
        case .checklist(let c): "check-\(c.id)"
        case .steps(let s): "steps-\(s.title)"
        case .plan(let p): "plan-\(p.id)"
        case .condition(let c): "condition-\(c.id)"
        case .record(let r): "record-\(r.id)"
        }
    }

    var proposal: PlanChangeProposal? { if case .plan(let p) = self { p } else { nil } }
    var condition: ConditionProposal? { if case .condition(let c) = self { c } else { nil } }
    var record: RecordProposal? { if case .record(let r) = self { r } else { nil } }
}

enum AgentUI {
    static let maxBlocks = 3

    /// The cards shown with a cloud model's answer: its own, or the rules' when it offered none for a
    /// task that needs them. A condition card (with its plan change) and a 记下 card for a reading or
    /// a reminder always stay, first, whatever the model offered.
    static func cloudBlocks(_ model: [AgentUIBlock], rule: AgentReply) -> [AgentUIBlock] {
        var blocks = model
        if blocks.isEmpty, [.planChange, .device, .trainingCheck, .symptom, .reading].contains(rule.intent) { blocks = rule.blocks }
        if rule.blocks.contains(where: { $0.condition != nil }) {
            blocks = rule.blocks + blocks.filter { b in b.proposal == nil && !rule.blocks.contains { $0.id == b.id } }
        }
        let records = rule.blocks.filter { $0.record != nil }
        if !records.isEmpty { blocks = records + blocks.filter { b in !records.contains { $0.id == b.id } } }
        return Array(blocks.prefix(maxBlocks))
    }

    // MARK: Reading a model's answer

    /// Splits a model answer into the text shown in the bubble and the machine-readable parts.
    /// While streaming, everything from the first tag on is hidden (including a half-written tag).
    static func split(_ raw: String) -> (text: String, ui: String?, plan: String?) {
        let ui = section("ui", in: raw)
        let plan = section("plan", in: raw)
        var visible = raw
        if let first = ["<ui>", "<plan>"].compactMap({ raw.range(of: $0)?.lowerBound }).min() {
            visible = String(raw[..<first])
        }
        // A tag that is still arriving ("<", "<p", "<pla"…).
        if let lt = visible.lastIndex(of: "<"), !visible[lt...].contains(">"), visible.distance(from: lt, to: visible.endIndex) <= 6 {
            visible = String(visible[..<lt])
        }
        // Models sometimes wrap the JSON in a code fence before the tag.
        visible = visible.replacingOccurrences(of: "```json", with: "").replacingOccurrences(of: "```", with: "")
        return (visible.trimmingCharacters(in: .whitespacesAndNewlines), ui, plan)
    }

    private static func section(_ tag: String, in s: String) -> String? {
        guard let a = s.range(of: "<\(tag)>") else { return nil }
        let rest = s[a.upperBound...]
        guard let b = rest.range(of: "</\(tag)>") else { return nil }
        return String(rest[..<b.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Decodes and validates `<ui>` JSON. Unknown components, empty ones and text that gives
    /// medication or dose advice are dropped; numbers are clamped.
    static func blocks(fromJSON json: String, context: String) -> [AgentUIBlock] {
        let cleaned = json.replacingOccurrences(of: "```json", with: "").replacingOccurrences(of: "```", with: "")
        guard let data = cleaned.data(using: .utf8), let any = try? JSONSerialization.jsonObject(with: data) else { return [] }
        let list = (any as? [[String: Any]]) ?? ((any as? [String: Any]).map { [$0] } ?? [])
        return Array(list.compactMap { block(from: $0, context: context) }.prefix(maxBlocks))
    }

    static func block(from d: [String: Any], context: String) -> AgentUIBlock? {
        switch d["type"] as? String {
        case "form":
            let fields = ((d["fields"] as? [[String: Any]]) ?? []).prefix(4).enumerated().compactMap { field(from: $1, index: $0) }
            guard !fields.isEmpty else { return nil }
            let title = text(d["title"], max: 40) ?? "补充一下"
            guard isSafe(title) else { return nil }
            return .form(AgentForm(id: text(d["id"], max: 40) ?? "form-\(UUID().uuidString.prefix(6))", title: title, fields: Array(fields),
                                   submitLabel: text(d["submit"], max: 8) ?? "发送", context: context))
        case "chart":
            guard let m = (d["metric"] as? String).flatMap(AgentChartMetric.init(rawValue:)) else { return nil }
            let days = m.clampDays(int(d["days"]) ?? (m == .glucose ? 1 : 28))
            let caption = text(d["caption"], max: 80).flatMap { isSafe($0) ? $0 : nil }
            return .chart(m, days: days, caption: caption)
        case "checklist":
            let items = ((d["items"] as? [[String: Any]]) ?? []).prefix(8).enumerated().compactMap { i, it -> AgentChecklistItem? in
                guard let t = text(it["title"], max: 30), isSafe(t) else { return nil }
                let detail = text(it["detail"], max: 140) ?? ""
                guard isSafe(detail) else { return nil }
                return AgentChecklistItem(id: text(it["id"], max: 30) ?? "i\(i)-\(t)", title: t, detail: detail)
            }
            guard !items.isEmpty else { return nil }
            let title = text(d["title"], max: 30) ?? "清单"
            return .checklist(AgentChecklist(id: text(d["id"], max: 40) ?? "list-\(title)", title: title, items: Array(items)))
        case "steps":
            let steps = ((d["steps"] as? [[String: Any]]) ?? []).prefix(6).compactMap { s -> AgentStep? in
                guard let t = text(s["title"], max: 20), let detail = text(s["detail"], max: 160), isSafe(t + detail) else { return nil }
                return AgentStep(icon: symbol(s["icon"]), title: t, detail: detail)
            }
            guard !steps.isEmpty else { return nil }
            return .steps(AgentSteps(title: text(d["title"], max: 30) ?? "步骤", steps: Array(steps)))
        default:
            return nil
        }
    }

    private static func field(from f: [String: Any], index: Int) -> AgentFormField? {
        guard let label = text(f["label"], max: 30), isSafe(label) else { return nil }
        let id = text(f["id"], max: 30) ?? "f\(index)"
        switch f["kind"] as? String ?? f["type"] as? String {
        case "choice":
            let opts = ((f["options"] as? [Any]) ?? []).compactMap { text($0, max: 20) }.filter(isSafe).prefix(6)
            guard opts.count >= 2 else { return nil }
            return AgentFormField(id: id, label: label, kind: .choice(options: Array(opts), multiple: f["multiple"] as? Bool ?? false))
        case "weekdays":
            return AgentFormField(id: id, label: label, kind: .weekdays)
        case "number":
            let lo = max(0, int(f["min"]) ?? 0)
            let hi = min(600, max(lo + 1, int(f["max"]) ?? 120))
            let step = min(max(1, int(f["step"]) ?? 5), max(1, hi - lo))
            let v = min(max(int(f["value"]) ?? lo, lo), hi)
            return AgentFormField(id: id, label: label, kind: .number(min: lo, max: hi, step: step, unit: text(f["unit"], max: 6) ?? "", value: v))
        case "toggle":
            return AgentFormField(id: id, label: label, kind: .toggle)
        default:
            return nil
        }
    }

    private static func text(_ v: Any?, max: Int) -> String? {
        guard let s = (v as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        return String(s.prefix(max))
    }
    private static func int(_ v: Any?) -> Int? {
        if let i = v as? Int { return i }
        if let d = v as? Double { return Int(d) }
        if let s = v as? String { return Int(s) }
        return nil
    }
    private static let symbols: Set<String> = ["applewatch", "sensor.fill", "drop.fill", "heart.fill", "bolt.heart", "figure.run", "timer",
                                               "battery.75", "bell.badge", "checkmark.circle", "exclamationmark.triangle", "moon.stars.fill",
                                               "fork.knife", "bandage", "drop.triangle", "arrow.triangle.2.circlepath", "flag.checkered", "1.circle",
                                               "2.circle", "3.circle", "4.circle"]
    private static func symbol(_ v: Any?) -> String {
        let s = (v as? String) ?? ""
        return symbols.contains(s) ? s : "circle.fill"
    }

    /// Generated components never carry medication or dose advice.
    static func isSafe(_ s: String) -> Bool {
        let banned = ["剂量", "停药", "减药", "加药", "换药", "单位胰岛素", "胰岛素用量", "毫克", "mg"]
        if banned.contains(where: { s.contains($0) }) { return false }
        if s.contains("胰岛素"), s.range(of: #"\d+\s*(U|u|单位|IU)"#, options: .regularExpression) != nil { return false }
        // Any change to a medicine ("降压药减半", "少吃一片药") is the doctor's call.
        if s.contains("药"), ["减", "加", "停", "换", "半", "倍", "调整", "增", "少吃", "多吃", "不吃"].contains(where: { s.contains($0) }) { return false }
        return true
    }

    // MARK: Instructions for the cloud model

    /// The component catalog, appended to the cloud instructions.
    static let catalogInstructions = """
    可选的交互界面（Generative UI）：只有当交互界面比文字更清楚时才使用，例如需要用户补充信息、做选择、按步骤操作或查看趋势。
    在回答文字之后输出 <ui>JSON 数组</ui>，最多 3 个组件，只能用以下类型：
    - {"type":"form","id":"…","title":"…","fields":[字段],"submit":"发送"}；字段：
      {"id":"…","label":"…","kind":"choice","options":["…","…"],"multiple":false} ／ {"id":"…","label":"…","kind":"weekdays"} ／
      {"id":"…","label":"…","kind":"number","min":0,"max":90,"step":5,"value":30,"unit":"分钟"} ／ {"id":"…","label":"…","kind":"toggle"}
    - {"type":"chart","metric":"rhr|sleep|activity|glucose|bp|wear","days":28,"caption":"…"}（数据由 App 从用户记录中填充，你只选择指标）
    - {"type":"checklist","id":"…","title":"…","items":[{"title":"…","detail":"…"}]}
    - {"type":"steps","title":"…","steps":[{"icon":"applewatch|sensor.fill|drop.fill|figure.run|timer|bell.badge|moon.stars.fill|fork.knife","title":"…","detail":"…"}]}
    组件文字用简体中文、简短；不包含药物、剂量或胰岛素调整建议。不需要界面时不要输出 <ui>。
    """
}
