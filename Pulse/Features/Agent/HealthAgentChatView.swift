import SwiftUI

/// Conversation with the Health Agent: text or voice in, answers grounded in the user's own
/// records, with links to the page where the details live.
struct HealthAgentChatView: View {
    var initialQuestion: String? = nil
    var startListening = false
    @Environment(\.dismiss) private var dismiss
    @State private var convo = AgentConversation.shared
    @State private var confirmClear = false

    var body: some View {
        CalmNavigationStack {
            AgentContextReader { ctx in
                AgentChatContent(context: ctx, initialQuestion: initialQuestion, startListening: startListening)
            }
            .navigationTitle("Health Agent")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Menu {
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
            .confirmationDialog("清空当前对话？", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("清空对话", role: .destructive) { convo.clear() }
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
                VStack(alignment: .leading, spacing: 16) {
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
                .padding(16)
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
            Text("撤回后，问题和回答都从对话中移除，Health Agent 也不再参考它们。")
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
        let names = convo.recordedConditions(answering: m.id).map { "「\($0.info.name)」" }.joined(separator: "、")
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
        VStack(spacing: 6) {
            if speech.isRecording {
                HStack(spacing: 8) {
                    Image(systemName: "waveform").symbolEffect(.variableColor.iterative, options: .repeating)
                        .foregroundStyle(.red)
                    Text("正在听…说完后轻点发送").font(.footnote).foregroundStyle(.secondary)
                    Spacer()
                    if speech.onDevice { Text("设备端识别").font(.caption).foregroundStyle(.secondary) }
                }
                .padding(.horizontal, 6)
                .accessibilityElement(children: .combine)
            }
            if let err = speech.errorMessage {
                Text(err).font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 6)
            }
            HStack(alignment: .bottom, spacing: 8) {
                Button {
                    focused = false
                    usedVoice = true
                    Task { await speech.toggle() }
                } label: {
                    Image(systemName: speech.isRecording ? "stop.fill" : "mic.fill")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(speech.isRecording ? Color.white : Theme.accent)
                        .frame(width: 44, height: 44)
                        .background(speech.isRecording ? Color.red : Theme.accent.opacity(0.12), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(speech.isRecording ? "停止听写" : "语音提问")

                TextField("想问什么、想调整什么，都可以说…", text: $input, axis: .vertical)
                    .lineLimit(1...5)
                    .focused($focused)
                    .submitLabel(.send)
                    .onSubmit(submit)
                    .padding(.horizontal, 14).padding(.vertical, 11)
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: 22, style: .continuous))

                Button(action: submit) {
                    Image(systemName: "arrow.up.circle.fill").font(.largeTitle)
                        .foregroundStyle(canSend ? Theme.accent : Color.gray.opacity(0.4))
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .accessibilityLabel("发送")
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 8)
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

    var body: some View {
        let a = HealthAgent.assess(context)
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                AgentAvatar(size: compact ? 32 : 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text("你好\(context.name == "你" ? "" : "，\(context.name)")").font(compact ? .headline : .title3.weight(.semibold))
                    Text(CloudModelSettings.shared.isActive ? "由云端模型 \(CloudModelSettings.shared.model) 根据你的数据回答 · 提问时发送数据摘要"
                         : (AgentConversation.shared.usesOnDeviceModel ? "由设备端 Apple 智能根据你的数据回答 · 数据不离开本机"
                            : "大模型不可用（\(AgentConversation.shared.noModelReason ?? "")）· 目前为规则分析"))
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            if !compact {
                Text("\(a.headline)。我可以解释你的数据变化、回答疑问、按你的情况调整训练计划，也可以指导手表和 CGM 的使用。可以打字，也可以按麦克风说话。")
                    .font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                FlowLayout(spacing: 8) {
                    ForEach(a.questions, id: \.self) { q in
                        Button(q) { onAsk(q) }.buttonStyle(.bordered)
                    }
                }
                Text("Health Agent 不做诊断，也不提供用药建议；紧急情况请拨打 120。")
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

    var body: some View {
        if message.role == .user && message.withdrawn {
            WithdrawnNotice(onEdit: onEdit)
        } else if message.role == .user {
            HStack {
                Spacer(minLength: 48)
                Text(message.text)
                    .font(.body).foregroundStyle(.white)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(Theme.accent, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: 18, style: .continuous))
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
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 10) {
                    AgentAvatar(size: 28)
                    VStack(alignment: .leading, spacing: 12) {
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
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
                // Generated components get the full width; the actions follow them.
                if hasBlocks {
                    AgentBlocksView(blocks: message.blocks, messageID: message.id, context: context, onSubmit: onFollowUp)
                    VStack(alignment: .leading, spacing: 12) { footer }
                        .padding(.leading, 38)
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
            HStack(spacing: 8) {
                Text(([message.engine == .onDevice ? "Apple 智能" : (message.engine == .cloud ? "云端 · \(CloudModelSettings.shared.model)"
                        : (r.urgent ? "固定急救提示（不经过模型）" : "Pulse 规则分析（未经大模型）"))] + r.sources).joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                Spacer(minLength: 4)
                Button(action: onSpeak) {
                    Image(systemName: speaking ? "speaker.wave.2.fill" : "speaker.wave.2")
                        .font(.subheadline).frame(width: 44, height: 44)
                }
                .buttonStyle(.plain).foregroundStyle(Theme.accent)
                .accessibilityLabel(speaking ? "停止朗读" : "朗读这条回复")
            }
            if isLast && !r.followUps.isEmpty {
                FlowLayout(spacing: 8) {
                    ForEach(r.followUps, id: \.self) { q in
                        Button(q) { onFollowUp(q) }.buttonStyle(.bordered)
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

/// What is left of a question the user took back.
private struct WithdrawnNotice: View {
    var onEdit: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Text("你撤回了一个问题").foregroundStyle(.secondary)
            Button("重新编辑", action: onEdit).foregroundStyle(Theme.accent)
        }
        .font(.footnote)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("你撤回了一个问题")
        .accessibilityAction(named: "重新编辑", onEdit)
    }
}

private struct TypingBubble: View {
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            AgentAvatar(size: 28)
            TypingDots()
                .padding(14)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
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
    var size: CGFloat = 32
    var body: some View {
        Image(systemName: "sparkles")
            .font(.system(size: size * 0.46, weight: .semibold)).foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(AngularGradient(colors: [.orange, .pink, .purple, .indigo, .cyan, .orange], center: .center), in: Circle())
            .accessibilityHidden(true)
    }
}
