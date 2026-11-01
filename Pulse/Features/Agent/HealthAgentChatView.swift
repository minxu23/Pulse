import SwiftUI

/// Conversation with the Health Agent: text or voice in, answers grounded in the user's own
/// records, with links to the page where the details live.
struct HealthAgentChatView: View {
    var initialQuestion: String? = nil
    var startListening = false
    @Environment(\.dismiss) private var dismiss
    @State private var convo = AgentConversation.shared
    @State private var cloud = CloudModelSettings.shared
    @State private var confirmClear = false
    @State private var showModelSettings = false
    @State private var renaming = false
    private var names: AgentNameSettings { .shared }

    var body: some View {
        CalmNavigationStack {
            AgentContextReader { ctx in
                AgentChatContent(context: ctx, initialQuestion: initialQuestion, startListening: startListening)
            }
            .navigationTitle(names.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Menu {
                        // 回答方式: switch here; setting up the cloud model is on its own page.
                        Section("回答方式") {
                            ForEach(AnswerMode.allCases) { m in
                                Button { cloud.mode = m } label: {
                                    Label(m.label + (cloud.canChoose(m) ? "" : "（需先设置）"), systemImage: cloud.mode == m ? "checkmark" : m.icon)
                                }
                                .disabled(!cloud.canChoose(m))
                            }
                            Button { showModelSettings = true } label: { Label("设置云端模型…", systemImage: "gearshape") }
                        }
                        Button { renaming = true } label: { Label(names.custom == nil ? "取个名字…" : "改名字…", systemImage: "pencil") }
                        Toggle(isOn: $convo.speakReplies) { Label("朗读回复", systemImage: "speaker.wave.2") }
                        Button(role: .destructive) { confirmClear = true } label: { Label("清空对话", systemImage: "trash") }
                            .disabled(convo.messages.isEmpty)
                    } label: { Image(systemName: "ellipsis.circle") }
                    .accessibilityLabel("更多")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { convo.stopSpeaking(); dismiss() }.fontWeight(.semibold)
                }
            }
            .navigationDestination(isPresented: $showModelSettings) { CloudModelSettingsView() }
            .agentRenameAlert(isPresented: $renaming)
            .confirmationDialog("清空当前对话？", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("清空对话", role: .destructive) { convo.clear() }
            } message: {
                Text("对话只保存在这台手机上，清空后无法恢复；已经记下的数据和采纳的计划不受影响。")
            }
        }
    }
}

private struct AgentChatContent: View {
    let context: AgentContext
    let initialQuestion: String?
    let startListening: Bool
    @State private var convo = AgentConversation.shared
    @State private var speech = SpeechInput()
    @State private var input = ""
    @State private var usedVoice = false
    @State private var started = false
    /// A question whose answer had a plan change adopted: taking it back asks about the plan first.
    @State private var withdrawing: AgentMessage?
    @Environment(\.modelContext) private var modelContext
    @FocusState private var focused: Bool

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // Not lazy: adopting a plan re-renders the context, and a lazy stack would lose its place.
                VStack(alignment: .leading, spacing: Theme.Space.cardGap) {
                    AgentIntro(context: context, compact: convo.messages.contains { !$0.withdrawn }, onAsk: { ask($0) })
                    ForEach(convo.messages) { m in
                        AgentMessageView(message: m, context: context, isLast: m.id == convo.messages.last?.id,
                                         speaking: convo.speakingID == m.id,
                                         onFollowUp: { ask($0) }, onSpeak: { convo.speak(m) },
                                         onWithdraw: { withdraw(m) }, onEdit: { edit(m.text) })
                            .id(m.id)
                    }
                    if convo.isResponding, convo.messages.last?.role == .user {
                        TypingBubble().id("typing")
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                // Side margins come from the app's page margins; only the vertical inset is set here.
                .padding(.vertical, Theme.Space.block)
                .labelStyle(.inline)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Theme.page)
            .onChange(of: convo.messages.last?.text) { _, _ in
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: convo.messages.count) { old, new in
                // Only for new messages: taking an earlier question back keeps the reader's place.
                guard new > old else { return }
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { inputBar }
        .onChange(of: speech.transcript) { _, t in if speech.isRecording || !t.isEmpty { input = t } }
        .task {
            guard !started else { return }
            started = true
            if let q = initialQuestion { ask(q) }
            else if startListening { usedVoice = true; await speech.start() }
        }
        .onDisappear { speech.stop() }
        .confirmationDialog(withdrawTitle, isPresented: Binding(get: { withdrawing != nil }, set: { if !$0 { withdrawing = nil } }),
                            titleVisibility: .visible, presenting: withdrawing) { m in
            Button("撤回，并撤销这些调整") { withAnimation { convo.withdraw(m.id, undoingChangesIn: modelContext) } }
            Button("撤回，保留调整") { withAnimation { convo.withdraw(m.id) } }
            Button("取消", role: .cancel) {}
        } message: { _ in
            Text(AgentNameSettings.shared.phrase("撤回后，问题和回答都从对话中移除，", "也不再参考它们。"))
        }
    }

    private func ask(_ q: String, spoken: Bool = false) {
        convo.ask(q, context: context, spoken: spoken)
    }

    /// 撤回: at once, unless the answer changed the plan.
    private func withdraw(_ m: AgentMessage) {
        if convo.hasAdoptedChanges(answering: m.id) { withdrawing = m }
        else { withAnimation { convo.withdraw(m.id) } }
    }

    /// Names what taking the question back could also undo.
    private var withdrawTitle: String {
        guard let m = withdrawing else { return "" }
        let plans = !convo.adoptedPlans(answering: m.id).isEmpty
        let names = (convo.recordedConditions(answering: m.id).map { "「\($0.info.name)」" }
            + convo.recordedItems(answering: m.id).flatMap { $0.0.items.map { "「\(RecordProposal.label($0))」" } }).joined(separator: "、")
        switch (plans, names.isEmpty) {
        case (true, true): return "这个问题的回答里有已采纳的计划调整"
        case (false, false): return "从这个回答里记下了\(names)"
        default: return "这个回答里有已采纳的计划调整，还记下了\(names)"
        }
    }

    /// 重新编辑: the question back in the input field.
    private func edit(_ text: String) {
        if speech.isRecording { speech.stop() }
        input = text
        focused = true
    }

    private func submit() {
        if speech.isRecording { speech.stop() }
        let q = input
        let voice = usedVoice
        input = ""
        usedVoice = false
        speech.transcript = ""
        ask(q, spoken: voice)
    }

    private var inputBar: some View {
        VStack(spacing: Theme.Space.tight) {
            if speech.isRecording {
                HStack(spacing: Theme.Space.iconGap) {
                    Image(systemName: "waveform").symbolEffect(.variableColor.iterative, options: .repeating)
                        .font(.footnote).imageScale(.small)
                        .foregroundStyle(.red)
                    Text("正在听…说完后轻点发送").font(.footnote).foregroundStyle(.secondary)
                    Spacer()
                    if speech.onDevice { Text("设备端识别").font(.caption).foregroundStyle(.secondary) }
                }
                .accessibilityElement(children: .combine)
            }
            if let err = speech.errorMessage {
                Text(err).font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(alignment: .bottom, spacing: Theme.Space.item) {
                Button {
                    focused = false
                    usedVoice = true
                    Task { await speech.toggle() }
                } label: {
                    Image(systemName: speech.isRecording ? "stop.fill" : "mic.fill")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(speech.isRecording ? Color.white : Theme.accent)
                        .frame(width: Theme.Size.tap, height: Theme.Size.tap)
                        .background(speech.isRecording ? Color.red : Theme.accent.opacity(0.12), in: Circle())
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(speech.isRecording ? "停止听写" : "语音提问")

                TextField("想问什么、想调整什么，都可以说…", text: $input, axis: .vertical)
                    .lineLimit(1...5)
                    .focused($focused)
                    .submitLabel(.send)
                    .onSubmit(submit)
                    .padding(.horizontal, Theme.Space.block).padding(.vertical, Theme.Space.item)
                    .frame(minHeight: Theme.Size.tap)
                    // Half the tap height: a pill on one line, level with the round buttons beside it.
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.Size.tap / 2, style: .continuous))

                Button(action: submit) {
                    Image(systemName: "arrow.up.circle.fill").font(.largeTitle)
                        .foregroundStyle(canSend ? Theme.accent : Color.gray.opacity(0.4))
                        .frame(width: Theme.Size.tap, height: Theme.Size.tap)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .accessibilityLabel("发送")
            }
        }
        .padding(.horizontal, Theme.Space.gutter)
        .padding(.vertical, Theme.Space.item)
        .background(.bar)
    }

    private var canSend: Bool {
        !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !convo.isResponding
    }
}

// MARK: - Intro

private struct AgentIntro: View {
    let context: AgentContext
    let compact: Bool
    var onAsk: (String) -> Void

    /// Who answers, by the 回答方式 in effect.
    private var modeLine: String {
        let s = CloudModelSettings.shared
        let model = OpenRouterModels.name(for: s.model) ?? s.model
        let line: String
        switch s.effectiveMode {
        case .cloud: line = "全部云端 · 由云端模型 \(model) 根据你的数据回答，提问时发送数据摘要"
        case .hybrid: line = s.consented ? "端云结合 · 本机分析后，去掉姓名、电话等再由 \(model) 写回答；紧急情况在本机"
            : "端云结合 · 涉及你记录的问题在本机回答；通用问题由 \(model) 回答，不发送你的数据"
        case .onDevice:
            line = AgentConversation.shared.usesOnDeviceModel ? "仅本机 · 由设备端 Apple 智能根据你的数据回答，数据不离开本机"
                : "大模型不可用（\(AgentConversation.shared.noModelReason ?? "")）· 目前为规则分析"
        }
        return s.mode == s.effectiveMode ? line : line + "（「\(s.mode.label)」需要先在设置里完成连接测试）"
    }

    var body: some View {
        let a = HealthAgent.assess(context)
        VStack(alignment: .leading, spacing: Theme.Space.block) {
            HStack(spacing: Theme.Space.block) {
                AgentAvatar(size: compact ? Theme.Size.iconTile : Theme.Size.tileIcon)
                VStack(alignment: .leading, spacing: Theme.Space.hairline) {
                    Text("你好\(context.name == "你" ? "" : "，\(context.name)")").font(compact ? .headline : .title3.weight(.semibold))
                    Text(modeLine).font(.footnote).foregroundStyle(.secondary)
                }
            }
            if !compact {
                Text("\(a.headline)。我可以解释你的数据变化、回答疑问、按你的情况调整训练计划，也可以指导手表和 CGM 的使用。可以打字，也可以按麦克风说话。")
                    .font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                FlowLayout(spacing: Theme.Space.item) {
                    ForEach(a.questions, id: \.self) { q in
                        Button { onAsk(q) } label: { Text(q).frame(minHeight: Theme.Size.borderedLabel) }
                            .buttonStyle(.bordered)
                    }
                }
                Text(AgentNameSettings.shared.phrase("", "不做诊断，也不提供用药建议；紧急情况请拨打 120。"))
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .cardSurface()
    }
}

// MARK: - Messages

private struct AgentMessageView: View {
    let message: AgentMessage
    let context: AgentContext
    let isLast: Bool
    let speaking: Bool
    var onFollowUp: (String) -> Void
    var onSpeak: () -> Void
    var onWithdraw: () -> Void
    var onEdit: () -> Void
    @State private var showSent = false

    var body: some View {
        if message.role == .user && message.withdrawn {
            WithdrawnNotice(onEdit: onEdit)
        } else if message.role == .user {
            HStack {
                Spacer(minLength: 48)
                Text(message.text)
                    .font(.body).foregroundStyle(.white)
                    .padding(.horizontal, Theme.Space.block).padding(.vertical, Theme.Space.item)
                    .background(Theme.accent, in: RoundedRectangle(cornerRadius: Theme.Radius.bubble, style: .continuous))
                    .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: Theme.Radius.bubble, style: .continuous))
                    .contextMenu {
                        Button { UIPasteboard.general.string = message.text } label: { Label("复制", systemImage: "doc.on.doc") }
                        Button(action: onWithdraw) {
                            Label("撤回", systemImage: "arrow.uturn.backward")
                            Text("问题和回答一起移除")
                        }
                    }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("我：\(message.text)")
            .accessibilityAction(named: "撤回", onWithdraw)
        } else {
            let hasBlocks = !message.blocks.isEmpty && !message.streaming
            VStack(alignment: .leading, spacing: Theme.Space.block) {
                HStack(alignment: .top, spacing: Theme.Space.block) {
                    AgentAvatar(size: Theme.Size.iconTile)
                    VStack(alignment: .leading, spacing: Theme.Space.block) {
                        if message.text.isEmpty && message.streaming {
                            TypingDots()
                        } else {
                            Text(Self.attributed(message.text)).font(.body).fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        }
                        if let note = message.note {
                            StatusLabel(.neutral(note)).font(.footnote)
                        }
                        if !hasBlocks { footer }
                    }
                    .padding(Theme.Space.block)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.Radius.bubble, style: .continuous))
                }
                // Generated components get the full width; the actions follow them.
                if hasBlocks {
                    AgentBlocksView(blocks: message.blocks, messageID: message.id, context: context, onSubmit: onFollowUp)
                    // Under the bubble: the avatar's width plus its gap.
                    VStack(alignment: .leading, spacing: Theme.Space.block) { footer }
                        .padding(.leading, Theme.Size.iconTile + Theme.Space.block)
                }
            }
        }
    }

    @ViewBuilder private var footer: some View {
        if let r = message.reply, !message.streaming {
            if r.urgent {
                Link(destination: URL(string: "tel://120")!) {
                    Label("拨打 120", systemImage: "phone.fill").frame(maxWidth: .infinity).fontWeight(.semibold)
                }
                .buttonStyle(.borderedProminent).tint(.red).controlSize(.large)
            }
            if let d = r.destination {
                NavigationLink { d.view } label: {
                    Label("查看\(d.title)", systemImage: d.icon)
                }
                .buttonStyle(.bordered)
            }
            if message.engine == .rules && !r.urgent && AgentConversation.shared.noModelReason != nil {
                NavigationLink { CloudModelSettingsView() } label: {
                    Label("设置云端模型", systemImage: "cloud")
                }
                .buttonStyle(.bordered)
            }
            HStack(spacing: Theme.Space.item) {
                Text(([message.engine == .onDevice ? "Apple 智能" : (message.engine == .cloud ? "云端 · \(CloudModelSettings.shared.model)"
                        : (r.urgent ? "固定急救提示（不经过模型）" : "Pulse 规则分析（未经大模型）"))] + [message.privacy].compactMap { $0 }
                       + [message.masked.map { "发送前去掉了\($0)" }].compactMap { $0 } + r.sources).joined(separator: " · "))
                    .font(.footnote).foregroundStyle(.secondary).lineLimit(3)
                Spacer(minLength: Theme.Space.tight)
                Button(action: onSpeak) {
                    Image(systemName: speaking ? "speaker.wave.2.fill" : "speaker.wave.2")
                        .font(.subheadline).frame(width: Theme.Size.tap, height: Theme.Size.tap)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain).foregroundStyle(Theme.accent)
                .accessibilityLabel(speaking ? "停止朗读" : "朗读这条回复")
            }
            // Exactly what went to the cloud, so the masking can be checked.
            if let sent = message.sent {
                Button { showSent = true } label: {
                    Text("查看发送的内容").font(.footnote).frame(minHeight: Theme.Size.tap).contentShape(Rectangle())
                }
                .buttonStyle(.plain).foregroundStyle(Theme.accent)
                .sheet(isPresented: $showSent) { SentContentSheet(text: sent, masked: message.masked) }
            }
            if isLast && !r.followUps.isEmpty {
                FlowLayout(spacing: Theme.Space.item) {
                    ForEach(r.followUps, id: \.self) { q in
                        Button { onFollowUp(q) } label: { Text(q).frame(minHeight: Theme.Size.borderedLabel) }
                            .buttonStyle(.bordered)
                    }
                }
            }
        }
    }

    /// Renders inline Markdown (bold from the language model) and keeps line breaks.
    static func attributed(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }
}

/// What one answer sent to the cloud model, word for word.
private struct SentContentSheet: View {
    let text: String
    let masked: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.block) {
                    Text(masked.map { "发送前在本机把\($0)换成了 [姓名1] 这样的代号，回答回来后再换回原文。年龄、日期和健康数据照原样发送。" }
                         ?? "这次的内容里没有姓名、电话、证件号、邮箱、地址、医院或医生，照原样发送。")
                        .font(.subheadline).foregroundStyle(.secondary)
                    Text(text).font(.subheadline).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(Theme.Space.block)
                        .background(Theme.subtle.opacity(0.6), in: RoundedRectangle(cornerRadius: Theme.Radius.inner, style: .continuous))
                }
                .padding(.vertical, Theme.Space.block)
            }
            .pageMargins()
            .navigationTitle("发送的内容").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
    }
}

/// What is left of a question the user took back.
private struct WithdrawnNotice: View {
    var onEdit: () -> Void

    var body: some View {
        HStack(spacing: Theme.Space.tight) {
            Text("你撤回了一个问题").foregroundStyle(.secondary)
            Button(action: onEdit) {
                Text("重新编辑").frame(minHeight: Theme.Size.tap).contentShape(Rectangle())
            }
            .foregroundStyle(Theme.accent)
        }
        .font(.footnote)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("你撤回了一个问题")
        .accessibilityAction(named: "重新编辑", onEdit)
    }
}

private struct TypingBubble: View {
    var body: some View {
        HStack(alignment: .top, spacing: Theme.Space.block) {
            AgentAvatar(size: Theme.Size.iconTile)
            TypingDots()
                .padding(Theme.Space.block)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.Radius.bubble, style: .continuous))
            Spacer()
        }
        .accessibilityLabel("正在分析")
    }
}

private struct TypingDots: View {
    var body: some View {
        Image(systemName: "ellipsis")
            .font(.title3.weight(.bold)).foregroundStyle(.secondary)
            .symbolEffect(.variableColor.iterative, options: .repeating)
            .frame(height: 20)
    }
}

/// The agent's identity mark (decorative; not a status or interaction colour).
struct AgentAvatar: View {
    var size: CGFloat = Theme.Size.iconTile
    var body: some View {
        Image(systemName: "sparkles")
            .font(.system(size: size * 0.46, weight: .semibold)).foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(AngularGradient(colors: [.orange, .pink, .purple, .indigo, .cyan, .orange], center: .center), in: Circle())
            .accessibilityHidden(true)
    }
}
