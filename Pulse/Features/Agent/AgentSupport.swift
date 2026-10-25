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
        return AgentContext.make(
            profile: snap, name: p?.displayName ?? "你",
            days: DayBuilder.build(records: records, sessions: sessions),
            plan: items.map(\.snapshot), workouts: sessions.map(\.point),
            vitals: vitals.filter { $0.time > now.adding(days: -60) }.map(\.point),
            events: events.filter { $0.status.isActive }.map { AgentEvent(title: $0.title, severity: $0.severity, date: $0.relatedDate, guidance: $0.guidance) },
            stopBang: p?.stopBangAnswers ?? [], baselineSetAt: p?.baselineSetAt, raceName: p?.raceName ?? "",
            targetRHR: p?.targetRHR, weather: WeatherStore.shared.days, weatherSource: WeatherStore.shared.sourceName,
            labs: labs.map(\.point), now: now)
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
    let date = Date.app
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

    /// Every answer except the fixed emergency reply is written by a language model: the cloud model
    /// once the user has set it up, otherwise Apple Intelligence on the device. The rules engine runs
    /// first and supplies the facts — and, for safety-relevant questions, the conclusion to keep.
    var usesOnDeviceModel: Bool { OnDeviceModel.isAvailable }
    /// Why no language model can answer right now (nil when one can).
    var noModelReason: String? {
        CloudModelSettings.shared.isActive || usesOnDeviceModel ? nil : "\(OnDeviceModel.unavailableReason)，云端模型未启用"
    }

    /// Asks a question; the answer can be stopped by taking the question back.
    func ask(_ q: String, context: AgentContext, spoken: Bool = false) {
        guard !isResponding else { return }
        answering = Task { await send(q, context: context, spoken: spoken) }
    }

    func send(_ raw: String, context: AgentContext, spoken: Bool = false) async {
        let q = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !isResponding else { return }
        let history = modelHistory()
        messages.append(AgentMessage(role: .user, text: q))
        turn += 1
        let mine = turn
        isResponding = true
        defer { if turn == mine { isResponding = false; answering = nil } }

        let rule = HealthAgent.reply(to: q, context: context)
        let context = HealthAgent.context(context, answering: rule)

        // Emergencies: the fixed reply at once, never a generated one.
        if rule.urgent {
            messages.append(AgentMessage(role: .agent, text: rule.text, reply: rule, engine: .rules))
            if spoken || speakReplies, let last = messages.last { speak(last) }
            return
        }

        var fallbackNote: String? = nil
        if CloudModelSettings.shared.isActive, let client = CloudModelSettings.shared.client() {
            let id = append(AgentMessage(role: .agent, text: "", reply: rule, engine: .cloud, streaming: true))
            let (system, prompt) = cloudRequest(q, rule: rule, history: history, context: context)
            do {
                let raw = try await client.stream(system: system, prompt: prompt, maxTokens: 1600) { [weak self] partial in
                    self?.edit(id) { $0.text = HealthAgent.streamed(AgentUI.split(partial).text, of: rule, proposing: rule.proposesPlan || rule.intent == .planChange) }
                }
                guard turn == mine else { return }
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
                if blocks.isEmpty, [.planChange, .device, .trainingCheck].contains(rule.intent) { blocks = rule.blocks }
                // A condition the user mentioned is always offered by the rules, with its plan change.
                if rule.blocks.contains(where: { $0.condition != nil }) {
                    blocks = rule.blocks + blocks.filter { b in b.proposal == nil && !rule.blocks.contains { $0.id == b.id } }
                }
                edit(id) { m in
                    m.text = HealthAgent.finalize(parts.text.isEmpty ? rule.text : parts.text, of: rule,
                                                  proposals: blocks.prefix(AgentUI.maxBlocks).compactMap(\.proposal))
                    m.blocks = Array(blocks.prefix(AgentUI.maxBlocks))
                    m.note = note
                    m.streaming = false
                }
                if spoken || speakReplies, let m = messages.first(where: { $0.id == id }) { speak(m) }
                return
            } catch {
                guard turn == mine else { return }
                messages.removeAll { $0.id == id }
                fallbackNote = "云端模型暂不可用（\((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)），这次由 Apple 智能回答。"
            }
        }

        if usesOnDeviceModel {
            let id = append(AgentMessage(role: .agent, text: "", reply: rule, engine: .onDevice, streaming: true, note: fallbackNote, blocks: rule.blocks))
            // The on-device context window is small: the last exchange is enough history.
            let prompt = HealthAgent.modelPrompt(question: q, history: Array(history.suffix(2)), context: context, reply: rule, anonymous: false)
            do {
                let text = try await OnDeviceModel.respond(instructions: HealthAgent.groundedInstructions, prompt: prompt) { [weak self] partial in
                    self?.edit(id) { $0.text = HealthAgent.streamed(partial, of: rule) }
                }
                guard turn == mine else { return }
                guard !text.isEmpty else { throw CloudModelError.empty }
                edit(id) { $0.text = HealthAgent.finalize(text, of: rule) }
            } catch {
                guard turn == mine else { return }
                edit(id) { m in
                    m.text = rule.text
                    m.engine = .rules
                    m.note = "Apple 智能这次没能回答（\(error.localizedDescription)），以下为 Pulse 规则分析，没有经过大模型。"
                }
            }
            edit(id) { $0.streaming = false }
        } else {
            try? await Task.sleep(for: .milliseconds(350))
            guard turn == mine else { return }
            messages.append(AgentMessage(role: .agent, text: rule.text, reply: rule, engine: .rules,
                                         note: "当前没有可用的大模型（\(noModelReason ?? "")），以下为 Pulse 规则分析。", blocks: rule.blocks))
        }
        if spoken || speakReplies, let last = messages.last { speak(last) }
    }

    /// The recent exchange the model sees; questions taken back are left out.
    func modelHistory() -> [String] {
        messages.filter { !$0.withdrawn }.suffix(4).map { ($0.role == .user ? "用户：" : "助手：") + String($0.text.prefix(200)) }
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
    private func cloudRequest(_ q: String, rule: AgentReply, history: [String], context: AgentContext) -> (system: String, prompt: String) {
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
