import SwiftUI
import SwiftData
import AVFoundation
#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - Context from the store

/// Reads everything the agent needs and hands an `AgentContext` to its content.
struct AgentContextReader<Content: View>: View {
    @Query private var profiles: [UserProfile]
    @Query private var meds: [MedicationEntry]
    @Query(sort: \DailyRecord.day) private var records: [DailyRecord]
    @Query(sort: \ActivitySession.start) private var sessions: [ActivitySession]
    @Query(sort: \PlanItem.day) private var items: [PlanItem]
    @Query(sort: \VitalReading.time) private var vitals: [VitalReading]
    @Query(sort: \HealthEvent.createdAt, order: .reverse) private var events: [HealthEvent]
    @Query(sort: \LabResult.date) private var labs: [LabResult]
    @AppStorage(DayClock.earlyStartKey) private var earlyStart: Double = 0
    @ViewBuilder var content: (AgentContext) -> Content

    var body: some View {
        let _ = earlyStart
        content(make())
            .task(id: Date.app.startOfDay) { await WeatherStore.shared.load(demo: profiles.first?.usesDemoData == true) }
    }

    private func make() -> AgentContext {
        let p = profiles.first
        let snap = p?.snapshot(medications: meds) ?? ProfileSnapshot()
        DayClock.current = snap
        let now = Date.app
        var c = AgentContext.make(
            profile: snap, name: p?.displayName ?? "你",
            days: DayBuilder.build(records: records, sessions: sessions),
            plan: items.map(\.snapshot), workouts: sessions.map(\.point),
            vitals: vitals.filter { $0.time > now.adding(days: -60) }.map(\.point),
            events: events.filter { $0.status.isActive }.map { AgentEvent(title: $0.title, severity: $0.severity, date: $0.relatedDate, guidance: $0.guidance) },
            stopBang: p?.stopBangAnswers ?? [], baselineSetAt: p?.baselineSetAt, raceName: p?.raceName ?? "",
            targetRHR: p?.targetRHR, weather: WeatherStore.shared.days, weatherSource: WeatherStore.shared.sourceName,
            labs: labs.map(\.point), now: now)
        c.answerMode = CloudModelSettings.shared.effectiveMode
        c.agentName = AgentNameSettings.shared.name
        return c
    }
}

extension AgentDestination {
    @MainActor @ViewBuilder var view: some View {
        switch self {
        case .sleep: SleepCareView().navigationTitle("睡眠与呼吸").navigationBarTitleDisplayMode(.inline).calmStyle()
        case .recovery: HabitsView().navigationTitle("恢复").navigationBarTitleDisplayMode(.inline).calmStyle()
        case .plan: WeeklyPlanView().navigationTitle("运动计划").navigationBarTitleDisplayMode(.inline).calmStyle()
        case .heart: RHRTrendView().navigationTitle("静息心率").navigationBarTitleDisplayMode(.inline).calmStyle()
        case .vitals: VitalsView().navigationTitle("关键指标").navigationBarTitleDisplayMode(.inline).calmStyle()
        case .glucose: DiabetesCareView()
        case .cardio: CardioCareView()
        case .marathon: MarathonView()
        case .events: HealthEventsView()
        case .labs: LabResultsView()
        }
    }
}

// MARK: - Conversation

struct AgentMessage: Identifiable, Equatable {
    enum Role { case user, agent }
    enum Engine: Equatable { case onDevice, rules, cloud }
    let id = UUID()
    let role: Role
    var text: String
    var reply: AgentReply? = nil
    var engine: Engine = .rules
    var streaming = false
    /// Shown under the answer, e.g. why the cloud model was not used.
    var note: String? = nil
    /// Interactive components (Generative UI) rendered with the answer.
    var blocks: [AgentUIBlock] = []
    /// A question the user took back (撤回): shown as a one-line notice and left out of what the
    /// model sees; its answer is removed.
    var withdrawn = false
    /// 端云结合: answered by the cloud model as a general question, without any of the user's data.
    var general = false
    /// 端云结合: why this answer stayed on the device (shown with the answer).
    var privacy: String? = nil
    let date = Date.app
}

/// How a cloud answer attempt ended.
private enum CloudOutcome {
    case answered, superseded
    case failed(String)
}

/// What happened to a plan proposal shown in the conversation.
enum PlanOutcome: Equatable {
    case applied(DataHub.PlanUndo)
    case dismissed
    case undone
}

/// What happened to a condition card shown in the conversation.
enum ConditionOutcome: Equatable {
    /// `added` is false when it was already recorded; undoing then leaves it.
    case recorded(added: Bool)
    case dismissed
    case undone
}

/// The conversation lives for the app session, so closing and reopening the sheet keeps it.
@MainActor
@Observable
final class AgentConversation {
    static let shared = AgentConversation()

    var messages: [AgentMessage] = []
    var isResponding = false
    var speakReplies = false
    var speakingID: UUID?
    /// Answers to forms, keyed by message id + form id, so a sent form shows what was chosen.
    var answeredForms: [String: String] = [:]
    var planOutcomes: [UUID: PlanOutcome] = [:]
    var conditionOutcomes: [UUID: ConditionOutcome] = [:]
    /// Where a name given in the chat is saved.
    @ObservationIgnored var names = AgentNameSettings.shared
    /// The answer being written, so that taking its question back can stop it.
    private var answering: Task<Void, Never>?
    /// Moves on whenever an answer is abandoned; an abandoned answer never writes into the conversation.
    private var turn = 0
    private let synth = AVSpeechSynthesizer()
    private let speechDelegate = SpeechDelegate()

    init() {
        // The old "don't use the language model" switch is gone; answers always go through a model.
        UserDefaults.standard.removeObject(forKey: "agent.useModel")
        synth.delegate = speechDelegate
        speechDelegate.onFinish = { [weak self] in Task { @MainActor in self?.speakingID = nil } }
    }

    /// Every answer except the fixed emergency reply is written by a language model, as the user's
    /// `AnswerMode` says: Apple Intelligence on the device, the cloud model for general questions only
    /// (端云结合), or the cloud model for everything (全部云端). The rules engine runs first and
    /// supplies the facts — and, for safety-relevant questions, the conclusion to keep.
    var usesOnDeviceModel: Bool { OnDeviceModel.isAvailable }
    /// Why no language model can answer right now (nil when one can).
    var noModelReason: String? {
        CloudModelSettings.shared.effectiveMode != .onDevice || usesOnDeviceModel ? nil : "\(OnDeviceModel.unavailableReason)，云端模型未启用"
    }

    /// Asks a question; the answer can be stopped by taking the question back.
    func ask(_ q: String, context: AgentContext, spoken: Bool = false) {
        guard !isResponding else { return }
        answering = Task { await send(q, context: context, spoken: spoken) }
    }

    func send(_ raw: String, context: AgentContext, spoken: Bool = false) async {
        let typed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty, !isResponding else { return }
        // 「小安，今天能跑步吗」: the name it is addressed to is not part of the question.
        let q = AgentName.unaddressed(typed, name: context.agentName)
        let history = modelHistory()
        let generalHistory = generalModelHistory()
        // 「那明天呢？」 is read with the question before it.
        let previous = messages.last { $0.role == .user && !$0.withdrawn }.map { AgentName.unaddressed($0.text, name: context.agentName) }
        let asked = HealthAgent.resolveFollowUp(q, previous: previous) ?? q
        let earlier = messages.filter { $0.role == .user && !$0.withdrawn }.map(\.text)
        let askedForName = messages.last { $0.role == .agent }?.reply?.text == AgentName.reply(to: .ask).text
        messages.append(AgentMessage(role: .user, text: typed))
        turn += 1
        let mine = turn
        isResponding = true
        defer { if turn == mine { isResponding = false; answering = nil } }

        // 「以后叫你小安」: the new name applies at once, and the answer says how to change it back.
        if let request = AgentName.requested(in: q, afterAsking: askedForName) {
            switch request {
            case .rename(let n): names.set(n)
            case .reset: names.set(nil)
            case .ask: break
            }
            var r = AgentName.reply(to: request)
            r.followUps = AgentFollowUps.suggest(after: r, question: q, context: context, asked: earlier)
            try? await Task.sleep(for: .milliseconds(350))
            guard turn == mine else { return }
            messages.append(AgentMessage(role: .agent, text: r.text, reply: r, engine: .rules))
            if spoken || speakReplies, let last = messages.last { speak(last) }
            return
        }

        var rule = HealthAgent.reply(to: asked, context: context)
        let context = HealthAgent.context(context, answering: rule)
        // The questions offered under the answer follow from it and from this person.
        rule.followUps = AgentFollowUps.suggest(after: rule, question: asked, context: context, asked: earlier)
        // A model's answer to an open question is not the rules' 「可以试试下面这些」 reply: only questions on its topic.
        let modelFollowUps = rule.intent == .unknown
            ? AgentFollowUps.suggest(after: rule, question: asked, context: context, asked: earlier, fallback: false) : rule.followUps

        // Emergencies: the fixed reply at once, never a generated one.
        if rule.urgent {
            messages.append(AgentMessage(role: .agent, text: rule.text, reply: rule, engine: .rules))
            if spoken || speakReplies, let last = messages.last { speak(last) }
            return
        }

        // Explanations and schedules read best as written. General know-how goes to the cloud model
        // when the user chose one (端云结合 / 全部云端).
        if rule.verbatim, !(rule.intent == .knowledge && CloudModelSettings.shared.effectiveMode != .onDevice) {
            try? await Task.sleep(for: .milliseconds(350))
            guard turn == mine else { return }
            messages.append(AgentMessage(role: .agent, text: rule.text, reply: rule, engine: .rules, blocks: rule.blocks))
            if spoken || speakReplies, let last = messages.last { speak(last) }
            return
        }

        let settings = CloudModelSettings.shared
        var fallbackNote: String? = nil
        // 端云结合: why this question stays on the device.
        var privacy: String? = nil
        switch settings.effectiveMode {
        case .cloud:
            if let client = settings.client() {
                switch await answerWithRecords(asked, rule: rule, history: history, context: context, client: client, followUps: modelFollowUps,
                                               mine: mine, spoken: spoken) {
                case .answered, .superseded: return
                case .failed(let note): fallbackNote = note
                }
            }
        case .hybrid:
            switch AgentRouting.route(asked, reply: rule, profile: context.profile, name: context.name) {
            case .general(let text):
                if let client = settings.client() {
                    switch await answerGeneral(text, history: generalHistory, client: client, followUps: modelFollowUps, mine: mine, spoken: spoken) {
                    case .answered, .superseded: return
                    case .failed(let note): fallbackNote = note
                    }
                }
            case .device(let why):
                privacy = "在本机回答：\(why)"
            }
        case .onDevice:
            break
        }

        if usesOnDeviceModel {
            let id = append(AgentMessage(role: .agent, text: "", reply: rule, engine: .onDevice, streaming: true, note: fallbackNote,
                                         blocks: rule.blocks, privacy: privacy))
            // The on-device context window is small: the last exchange is enough history.
            let prompt = HealthAgent.modelPrompt(question: asked, history: Array(history.suffix(2)), context: context, reply: rule, anonymous: false)
            do {
                let text = try await OnDeviceModel.respond(instructions: Self.named(HealthAgent.groundedInstructions, context), prompt: prompt) { [weak self] partial in
                    self?.edit(id) { $0.text = HealthAgent.streamed(partial, of: rule) }
                }
                guard turn == mine else { return }
                guard !text.isEmpty else { throw CloudModelError.empty }
                if HealthAgent.keepsConclusion(text, of: rule) {
                    edit(id) { m in
                        m.text = HealthAgent.finalize(text, of: rule)
                        m.reply?.followUps = modelFollowUps
                    }
                } else {
                    // The model lost the answer the rules worked out: show that answer as it is.
                    edit(id) { m in
                        m.text = rule.text
                        m.engine = .rules
                    }
                }
            } catch {
                guard turn == mine else { return }
                edit(id) { m in
                    m.text = rule.text
                    m.engine = .rules
                    m.note = "Apple 智能这次没能回答（\(OnDeviceModel.describe(error))），以下为 Pulse 规则分析，没有经过大模型。"
                }
            }
            edit(id) { $0.streaming = false }
        } else {
            try? await Task.sleep(for: .milliseconds(350))
            guard turn == mine else { return }
            let note = privacy != nil
                ? "本机没有可用的 Apple 智能（\(OnDeviceModel.unavailableReason)），这个问题要用到你的记录，所以没有发到云端，以下为 Pulse 规则分析。"
                : (fallbackNote ?? "当前没有可用的大模型（\(noModelReason ?? OnDeviceModel.unavailableReason)），以下为 Pulse 规则分析。")
            messages.append(AgentMessage(role: .agent, text: rule.text, reply: rule, engine: .rules, note: note, blocks: rule.blocks, privacy: privacy))
        }
        if spoken || speakReplies, let last = messages.last { speak(last) }
    }

    /// 全部云端: the question with the anonymous data digest and the rules analysis.
    private func answerWithRecords(_ q: String, rule: AgentReply, history: [String], context: AgentContext,
                                   client: CloudModelClient, followUps: [String], mine: Int, spoken: Bool) async -> CloudOutcome {
        let id = append(AgentMessage(role: .agent, text: "", reply: rule, engine: .cloud, streaming: true))
        let (system, prompt) = cloudRequest(q, rule: rule, history: history, context: context)
        do {
            let raw = try await client.stream(system: system, prompt: prompt, maxTokens: 1600) { [weak self] partial in
                self?.edit(id) { $0.text = HealthAgent.streamed(AgentUI.split(partial).text, of: rule, proposing: rule.proposesPlan || rule.intent == .planChange) }
            }
            guard turn == mine else { return .superseded }
            let parts = AgentUI.split(raw)
            var blocks = parts.ui.map { AgentUI.blocks(fromJSON: $0, context: q) } ?? []
            var note: String? = nil
            if let json = parts.plan {
                let parsed = PlanChat.ops(fromJSON: json)
                let scope = parsed.scope ?? (q.contains("下周") ? .nextWeek : .thisWeek)
                let proposal = PlanChat.propose(parsed.ops, scope: scope, request: q, context: context,
                                                source: "云端 · \(CloudModelSettings.shared.model)")
                if proposal.hasChanges { blocks.insert(.plan(proposal), at: 0) }
                else { note = "云端模型给出的修改没有通过本机安全检查，下面是 Pulse 规则给出的方案。" }
            }
            // Keep the rules engine's components when the model offered none for a task that needs them.
            if blocks.isEmpty, [.planChange, .device, .trainingCheck, .symptom, .reading].contains(rule.intent) { blocks = rule.blocks }
            // A condition the user mentioned is always offered by the rules, with its plan change.
            if rule.blocks.contains(where: { $0.condition != nil }) {
                blocks = rule.blocks + blocks.filter { b in b.proposal == nil && !rule.blocks.contains { $0.id == b.id } }
            }
            edit(id) { m in
                m.text = HealthAgent.finalize(parts.text.isEmpty ? rule.text : parts.text, of: rule,
                                              proposals: blocks.prefix(AgentUI.maxBlocks).compactMap(\.proposal), strict: false)
                m.blocks = Array(blocks.prefix(AgentUI.maxBlocks))
                m.reply?.followUps = followUps
                m.note = note
                m.streaming = false
            }
            if spoken || speakReplies, let m = messages.first(where: { $0.id == id }) { speak(m) }
            return .answered
        } catch {
            guard turn == mine else { return .superseded }
            messages.removeAll { $0.id == id }
            return .failed("云端模型暂不可用（\(Self.describe(error))），这次\(usesOnDeviceModel ? "由 Apple 智能" : "以 Pulse 规则")在本机回答。")
        }
    }

    /// 端云结合: a general question goes out as its text alone — no digest, no records, no rules analysis.
    private func answerGeneral(_ q: String, history: [String], client: CloudModelClient, followUps: [String], mine: Int, spoken: Bool) async -> CloudOutcome {
        let shown = AgentReply(text: "", sources: ["通用问题 · 没有发送你的数据"], followUps: followUps, intent: .unknown)
        let id = append(AgentMessage(role: .agent, text: "", reply: shown, engine: .cloud, streaming: true, general: true))
        do {
            let raw = try await client.stream(system: HealthAgent.generalCloudInstructions,
                                              prompt: HealthAgent.generalPrompt(question: q, history: history), maxTokens: 900) { [weak self] partial in
                self?.edit(id) { $0.text = HealthAgent.stripLabels(partial, streaming: true) }
            }
            guard turn == mine else { return .superseded }
            edit(id) { m in
                m.text = HealthAgent.finalize(raw, of: shown, strict: false)
                m.reply = AgentReply(text: m.text, sources: shown.sources, followUps: shown.followUps, intent: .unknown)
                m.streaming = false
            }
            if spoken || speakReplies, let m = messages.first(where: { $0.id == id }) { speak(m) }
            return .answered
        } catch {
            guard turn == mine else { return .superseded }
            messages.removeAll { $0.id == id }
            return .failed("云端模型暂不可用（\(Self.describe(error))），这次在本机回答。")
        }
    }

    private static func describe(_ error: Error) -> String { (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }

    /// The recent exchange the model sees; questions taken back are left out.
    func modelHistory() -> [String] {
        messages.filter { !$0.withdrawn }.suffix(4).map { ($0.role == .user ? "用户：" : "助手：") + String($0.text.prefix(200)) }
    }

    /// 端云结合: only earlier general exchanges go with a general question — never an answer made from
    /// the user's records, or the question that led to it.
    func generalModelHistory() -> [String] {
        var out: [String] = []
        for (i, m) in messages.enumerated() where m.role == .agent && m.general && !m.streaming {
            guard let qi = messages[..<i].lastIndex(where: { $0.role == .user }), !messages[qi].withdrawn else { continue }
            out += ["用户：" + AgentRouting.redacted(String(messages[qi].text.prefix(200))), "助手：" + String(m.text.prefix(200))]
        }
        return Array(out.suffix(4))
    }

    private func append(_ m: AgentMessage) -> UUID {
        messages.append(m)
        return m.id
    }

    /// Changes a message found by id: earlier messages may be taken back while an answer is written.
    private func edit(_ id: UUID, _ change: (inout AgentMessage) -> Void) {
        guard let i = messages.firstIndex(where: { $0.id == id }) else { return }
        change(&messages[i])
    }

    // MARK: Taking a question back (撤回)

    /// Where the answers to a question are: the agent messages up to the next question.
    private func answers(to id: UUID) -> Range<Int> {
        guard let i = messages.firstIndex(where: { $0.id == id }) else { return messages.endIndex..<messages.endIndex }
        return (i + 1)..<(messages[(i + 1)...].firstIndex { $0.role == .user } ?? messages.endIndex)
    }

    /// Plan changes adopted from the answers to a question, which taking it back can also undo.
    func adoptedPlans(answering id: UUID) -> [(PlanChangeProposal, DataHub.PlanUndo)] {
        messages[answers(to: id)].flatMap(\.blocks).compactMap { b in
            guard case .plan(let p) = b, case .applied(let undo) = planOutcomes[p.id] else { return nil }
            return (p, undo)
        }
    }

    /// Conditions recorded from the answers to a question (only those the card added).
    func recordedConditions(answering id: UUID) -> [ConditionProposal] {
        messages[answers(to: id)].flatMap(\.blocks).compactMap { b in
            guard let c = b.condition, conditionOutcomes[c.id] == .recorded(added: true) else { return nil }
            return c
        }
    }

    /// Whether taking the question back could also undo something the user adopted from its answer.
    func hasAdoptedChanges(answering id: UUID) -> Bool {
        !adoptedPlans(answering: id).isEmpty || !recordedConditions(answering: id).isEmpty
    }

    /// 撤回: takes a question back with its answer, stopping the answer if it is still being written.
    /// The question stays as a one-line notice (to edit and send again); the model no longer sees it.
    /// With a context, plan changes adopted and conditions recorded from the answer are undone too;
    /// otherwise they stay.
    func withdraw(_ id: UUID, undoingChangesIn ctx: ModelContext? = nil) {
        guard let i = messages.firstIndex(where: { $0.id == id }), messages[i].role == .user, !messages[i].withdrawn else { return }
        if isResponding, i == messages.lastIndex(where: { $0.role == .user }) {
            answering?.cancel()
            answering = nil
            turn += 1
            isResponding = false
        }
        if let ctx {
            for (p, undo) in adoptedPlans(answering: id) {
                DataHub.revertPlanChange(p, undo: undo, in: ctx)
                planOutcomes[p.id] = .undone
            }
            for c in recordedConditions(answering: id) {
                DataHub.forgetCondition(c.info, in: ctx)
                conditionOutcomes[c.id] = .undone
            }
        }
        let range = answers(to: id)
        let removed = Set(messages[range].map(\.id))
        if let s = speakingID, removed.contains(s) { stopSpeaking() }
        answeredForms = answeredForms.filter { key, _ in !removed.contains { key.hasPrefix($0.uuidString) } }
        messages.removeSubrange(range)
        messages[i].withdrawn = true
    }

    /// Instructions and prompt for the cloud model, by what the question is about.
    /// The model's instructions with the name the user gave it, so 「小安」 in a question means the model.
    private static func named(_ instructions: String, _ c: AgentContext) -> String {
        AgentName.introduction(c.agentName).map { instructions + "\n\n" + $0 } ?? instructions
    }

    private func cloudRequest(_ q: String, rule: AgentReply, history: [String], context: AgentContext) -> (system: String, prompt: String) {
        let (system, prompt) = recordsRequest(q, rule: rule, history: history, context: context)
        return (Self.named(system, context), prompt)
    }

    private func recordsRequest(_ q: String, rule: AgentReply, history: [String], context: AgentContext) -> (system: String, prompt: String) {
        let past = history.isEmpty ? "" : "之前的对话：\n" + history.joined(separator: "\n") + "\n\n"
        switch rule.intent {
        case .planChange:
            return (PlanChat.cloudInstructions + "\n\n" + AgentUI.catalogInstructions,
                    PlanChat.cloudPrompt(question: q, history: history, context: context, rulesHint: PlanChat.rulesHint(q, context: context)))
        case .device:
            return (DeviceGuide.cloudInstructions + "\n\n" + AgentUI.catalogInstructions, """
            用户数据摘要：
            \(HealthAgent.digest(context, anonymous: true))

            设备与训练：
            \(DeviceGuide.grounding(q, context: context))

            \(past)用户的问题：\(q)
            """)
        default:
            return (HealthAgent.cloudInstructions + "\n\n" + AgentUI.catalogInstructions,
                    HealthAgent.modelPrompt(question: q, history: history, context: context, reply: rule, anonymous: true))
        }
    }

    func speak(_ m: AgentMessage) {
        synth.stopSpeaking(at: .immediate)
        if speakingID == m.id { speakingID = nil; return }
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        let u = AVSpeechUtterance(string: m.text.replacingOccurrences(of: "•", with: ""))
        u.voice = AVSpeechSynthesisVoice(language: "zh-CN")
        u.rate = AVSpeechUtteranceDefaultSpeechRate
        speakingID = m.id
        synth.speak(u)
    }

    func stopSpeaking() {
        synth.stopSpeaking(at: .immediate)
        speakingID = nil
    }

    func clear() {
        stopSpeaking()
        answering?.cancel()
        answering = nil
        turn += 1
        isResponding = false
        messages = []
        answeredForms = [:]
        planOutcomes = [:]
        conditionOutcomes = [:]
    }
}

private final class SpeechDelegate: NSObject, AVSpeechSynthesizerDelegate {
    var onFinish: (() -> Void)?
    func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) { onFinish?() }
    func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) { onFinish?() }
}

// MARK: - On-device language model (Apple Intelligence)

/// Wraps the Foundation Models framework. Everything runs on the device; when the model is not
/// available (older iOS, unsupported device, Apple Intelligence off) the rules engine answers.
enum OnDeviceModel {
    static var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            let model = SystemLanguageModel.default
            return model.isAvailable && model.supportsLocale(Locale(identifier: "zh_CN"))
        }
        #endif
        return false
    }

    /// Why Apple Intelligence can't answer on this device right now.
    /// A model error in words a user can read.
    static func describe(_ error: Error) -> String {
        let raw = "\(error)".lowercased()
        if raw.contains("guardrail") || raw.contains("unsafe") || raw.contains("sensitive") { return "这个问题触发了 Apple 智能的内容限制" }
        if raw.contains("context") { return "这次的内容太长" }
        if raw.contains("rate") || raw.contains("concurrent") { return "Apple 智能正忙" }
        return "暂时出错了"
    }

    static var unavailableReason: String {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            let model = SystemLanguageModel.default
            switch model.availability {
            case .available:
                return model.supportsLocale(Locale(identifier: "zh_CN")) ? "Apple 智能可用" : "Apple 智能暂不支持中文"
            case .unavailable(.appleIntelligenceNotEnabled): return "Apple 智能未开启"
            case .unavailable(.deviceNotEligible): return "这台设备不支持 Apple 智能"
            case .unavailable(.modelNotReady): return "Apple 智能模型还在准备中"
            default: return "Apple 智能不可用"
            }
        }
        #endif
        return "需要 iOS 26 才能使用 Apple 智能"
    }

    @MainActor
    static func respond(instructions: String, prompt: String, onPartial: @escaping @MainActor (String) -> Void) async throws -> String {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            let session = LanguageModelSession(instructions: instructions)
            let stream = session.streamResponse(to: prompt, options: GenerationOptions(temperature: 0.2))
            var last = ""
            for try await snapshot in stream {
                last = snapshot.content
                onPartial(last)
            }
            return last
        }
        #endif
        return ""
    }
}
