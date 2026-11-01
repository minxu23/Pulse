import SwiftUI

/// 回答方式与云端模型: how Health Agent answers (仅本机 / 端云结合 / 全部云端), and the user's own
/// cloud model account. 仅本机 by default; nothing is sent until a key is saved and the connection
/// tested, and the data digest only with 全部云端, after it is explicitly agreed to.
struct CloudModelSettingsView: View {
    @State private var settings = CloudModelSettings.shared
    @State private var keyInput = ""
    @State private var test: TestState = .idle
    @State private var sample: TestState = .idle
    @State private var sampleText = ""
    @State private var showDigest = false
    @State private var browseModels = false
    @State private var keyError: String?
    @State private var keyNote: String?
    @State private var showKey = false

    enum TestState: Equatable {
        case idle, running
        case ok(String)
        case failed(String)
    }

    var body: some View {
        AgentContextReader { ctx in
            Form {
                Section {
                    ForEach(AnswerMode.allCases) { m in modeRow(m) }
                } header: { Text("回答方式") } footer: {
                    Text(settings.mode == settings.effectiveMode
                         ? "每条回答下面会标出它在哪里回答。紧急情况的提示始终由本机给出。发到云端的内容受所选服务的隐私条款约束。"
                         : "「\(settings.mode.label)」还不能用，目前在本机回答。先完成下面的设置。")
                }

                Section {
                    Picker("服务", selection: Binding(get: { settings.provider }, set: { p in
                        settings.provider = p
                        settings.baseURL = p.defaultBaseURL
                        settings.model = p.defaultModel
                        settings.lastTestOK = false
                    })) {
                        ForEach(CloudProvider.allCases) { Text($0.label).tag($0) }
                    }
                    LabeledContent("接口地址") {
                        TextField("https://…/v1", text: $settings.baseURL)
                            .multilineTextAlignment(.trailing)
                            .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                    if settings.provider == .openRouter {
                        Menu {
                            ForEach(OpenRouterModels.groups, id: \.self) { g in
                                Section(g) {
                                    ForEach(OpenRouterModels.presets.filter { $0.group == g }) { m in
                                        Button { settings.model = m.model } label: {
                                            if settings.model == m.model { Label(m.name, systemImage: "checkmark") } else { Text(m.name) }
                                        }
                                    }
                                }
                            }
                            Divider()
                            Button { browseModels = true } label: { Label("浏览全部模型…", systemImage: "list.bullet") }
                        } label: {
                            LabeledContent("模型") {
                                HStack(spacing: Theme.Space.iconGap) {
                                    Text(OpenRouterModels.name(for: settings.model) ?? settings.model).lineLimit(1)
                                    Image(systemName: "chevron.up.chevron.down").font(.footnote)
                                }
                                .foregroundStyle(Theme.accent)
                            }
                        }
                        .foregroundStyle(.primary)
                        LabeledContent("模型 ID") {
                            TextField("anthropic/claude-sonnet-5.5", text: $settings.model)
                                .multilineTextAlignment(.trailing).font(.footnote)
                                .textInputAutocapitalization(.never).autocorrectionDisabled()
                        }
                    } else {
                        LabeledContent("模型") {
                            TextField(settings.provider == .anthropic ? "claude-sonnet-5-5" : "服务提供的模型名称", text: $settings.model)
                                .multilineTextAlignment(.trailing)
                                .textInputAutocapitalization(.never).autocorrectionDisabled()
                        }
                    }
                } header: { Text("服务") } footer: {
                    switch settings.provider {
                    case .openRouter:
                        Text("OpenRouter 用一个密钥调用多家模型，包括 Anthropic Claude、OpenAI、Google、DeepSeek、通义千问、Kimi、智谱等。可用模型和价格以 openrouter.ai 为准。")
                    case .anthropic:
                        Text("使用 Anthropic Messages API。模型可填写 claude-opus-5-5、claude-sonnet-5-5 或 claude-haiku-5-5。")
                    case .openAICompatible:
                        Text("适用于提供 /chat/completions 接口的服务。接口地址填写到 /v1 一级。")
                    }
                }
                .onChange(of: settings.baseURL) { _, _ in settings.lastTestOK = false }
                .onChange(of: settings.model) { _, _ in settings.lastTestOK = false }

                Section {
                    switch settings.keySource {
                    case .keychain:
                        LabeledContent("API 密钥", value: "已保存在钥匙串 · \(settings.keyHint ?? "")")
                        if let keyNote { StatusLabel(.good(keyNote)).font(.subheadline) }
                        Button("删除密钥", role: .destructive) { settings.deleteKey(); test = .idle; sample = .idle; keyNote = nil }
                    case .launch(let source):
                        LabeledContent("API 密钥", value: "来自\(source)")
                        Text("由启动脚本传入，只在本次运行中使用，没有写入钥匙串或文件。").font(.footnote).foregroundStyle(.secondary)
                        Button("保存到钥匙串，下次也使用") { settings.saveLaunchKeyToKeychain() }
                    case .none:
                        HStack(spacing: Theme.Space.item) {
                            Group {
                                if showKey {
                                    TextField(keyPlaceholder, text: $keyInput)
                                } else {
                                    SecureField(keyPlaceholder, text: $keyInput)
                                }
                            }
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .onSubmit { savePendingKey() }
                            Button { showKey.toggle() } label: {
                                Image(systemName: showKey ? "eye.slash" : "eye")
                                    .frame(width: Theme.Size.tap, height: Theme.Size.tap).contentShape(Rectangle())
                            }
                                .buttonStyle(.borderless).foregroundStyle(.secondary)
                                .accessibilityLabel(showKey ? "隐藏密钥" : "显示密钥")
                        }
                        // A paste into the field (many characters at once) is saved straight away.
                        .onChange(of: keyInput) { old, new in if new.count - old.count >= 16 { savePendingKey() } }
                        HStack {
                            // The system paste button: no 「允许粘贴」 prompt, and greyed out while the clipboard is empty.
                            PasteButton(payloadType: String.self) { strings in
                                let text = strings.first ?? ""
                                Task { @MainActor in
                                    keyInput = text
                                    savePendingKey()
                                }
                            }
                            .labelStyle(.titleAndIcon)
                            Spacer()
                            Button("保存到钥匙串") { savePendingKey() }
                                .buttonStyle(.borderless)
                                .disabled(pendingKey.isEmpty)
                        }
                        if let keyError { StatusLabel(.attention(keyError)).font(.subheadline) }
                    }
                } header: { Text("API 密钥") } footer: {
                    VStack(alignment: .leading, spacing: Theme.Space.item) {
                        #if targetEnvironment(simulator)
                        if settings.keySource == .none {
                            Text("在模拟器里粘贴：Mac 上复制的内容要先同步到模拟器，先点一下模拟器窗口再点「粘贴」；「粘贴」是灰色的就说明还没同步过来。还是不行的话，在 Mac 终端运行 pbpaste | xcrun simctl pbcopy booted，或者用 Demo 文件夹里的脚本启动，会自动带上 ~/.spark/keys 中的密钥。")
                        }
                        #endif
                        Text("每个服务的密钥分开保存在本机钥匙串，不会出现在导出的数据中。")
                    }
                }

                Section {
                    Button {
                        // A key typed or pasted into the field but not saved yet is saved first.
                        guard savePendingKey() else { return }
                        Task { await runTest() }
                    } label: {
                        HStack {
                            Label("测试连接", systemImage: "antenna.radiowaves.left.and.right")
                                .foregroundStyle(canTest ? Theme.accent : Color.secondary)
                            Spacer()
                            if test == .running { ProgressView() }
                        }
                    }
                    .disabled(!canTest || test == .running)
                    result(test)
                } header: { Text("连接测试") } footer: {
                    if !settings.endpointReady {
                        Text("接口地址要以 https:// 开头，模型名称不能为空，填好后才能测试。")
                    } else if !settings.hasKey && pendingKey.isEmpty {
                        Text("先在上面粘贴 API 密钥，再测试连接。测试只发送一句固定的文字，不包含任何健康数据。")
                    } else {
                        Text("测试只发送一句固定的文字，不包含任何健康数据。")
                    }
                }

                Section {
                    Toggle("同意把健康数据发到云端", isOn: $settings.consented)
                    DisclosureGroup("查看会发送的数据摘要", isExpanded: $showDigest) {
                        Text(HealthAgent.digest(ctx, anonymous: true))
                            .font(.footnote).foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .padding(.vertical, Theme.Space.tight)
                    }
                } header: { Text("会发送的健康数据") } footer: {
                    Text("「端云结合」每次只发送问题、Pulse 在本机的分析要点和与这个问题有关的数据；「全部云端」还会附上数据摘要（年龄、健康状况、用药名称、最近一次化验结果和各项统计）。发送前都会在本机把姓名、电话、证件号、邮箱、地址、医院和医生换成代号，回答回来后再换回；年龄、日期和健康数据照原样发送。不同意时，「端云结合」只发送通用问题。")
                }

                Section {
                    Button {
                        Task { await runSample(ctx) }
                    } label: {
                        HStack {
                            Label("用我的数据试问：我最近整体怎么样？", systemImage: "bubble.left.and.text.bubble.right")
                                .foregroundStyle(settings.consented && settings.lastTestOK && settings.isConfigured ? Theme.accent : Color.secondary)
                            Spacer()
                            if sample == .running { ProgressView() }
                        }
                    }
                    .disabled(!(settings.consented && settings.lastTestOK && settings.isConfigured) || sample == .running)
                    if !sampleText.isEmpty {
                        Text(sampleText).font(.subheadline).textSelection(.enabled).padding(.vertical, Theme.Space.tight)
                    }
                    if case .failed = sample { result(sample) }
                } header: { Text("试一试") } footer: {
                    Text("用你的数据摘要问一次，看看「全部云端」的回答效果。需要先测试连接并同意发送健康数据。")
                }
            }
        }
        .sheet(isPresented: $browseModels) { OpenRouterModelBrowser(selection: $settings.model) }
        .navigationTitle("回答方式与云端模型").calmStyle()
        .navigationBarTitleDisplayMode(.inline)
    }

    private var pendingKey: String { keyInput.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var keyPlaceholder: String {
        switch settings.provider {
        case .openRouter: "粘贴 OpenRouter 密钥（sk-or-…）"
        case .anthropic: "粘贴 Anthropic 密钥（sk-ant-…）"
        case .openAICompatible: "粘贴 API 密钥"
        }
    }
    private var canTest: Bool { settings.endpointReady && (settings.hasKey || !pendingKey.isEmpty) }

    /// Saves a key waiting in the field; false when the Keychain refused it.
    /// Cleans what was pasted (「KEY=…」, quotes, line breaks), switches to the service the key belongs
    /// to, checks it looks like a key, then saves it. False when it wasn't saved; the reason is shown.
    @discardableResult
    private func savePendingKey() -> Bool {
        guard !pendingKey.isEmpty else { return true }
        let key = APIKeyText.cleaned(keyInput)
        var switched: String? = nil
        if let p = APIKeyText.provider(of: key), p != settings.provider, settings.provider != .openAICompatible {
            settings.provider = p
            settings.baseURL = p.defaultBaseURL
            settings.model = p.defaultModel
            settings.lastTestOK = false
            switched = "这是 \(p.label) 的密钥，服务已切换到「\(p.label)」。"
        }
        if let problem = APIKeyText.problem(key, for: settings.provider) {
            keyError = problem
            return false
        }
        guard settings.saveKey(key) else {
            keyError = "没能保存到钥匙串，请再试一次。"
            return false
        }
        keyInput = ""
        keyError = nil
        keyNote = switched
        showKey = false
        test = .idle
        return true
    }

    private func modeRow(_ m: AnswerMode) -> some View {
        let ok = settings.canChoose(m)
        // Not .disabled: that would grey out the hint saying what the mode still needs.
        return Button { if ok { settings.mode = m } } label: {
            HStack(alignment: .top, spacing: Theme.Space.block) {
                Image(systemName: m.icon).font(.body).frame(width: 24).foregroundStyle(ok ? Theme.accent : Color.secondary)
                VStack(alignment: .leading, spacing: Theme.Space.hairline) {
                    Text(m.label).font(.body.weight(.medium)).foregroundStyle(ok ? Color.primary : Color.secondary)
                    Text(m.detail).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if let need = requirement(m) { StatusLabel(.attention(need)).font(.subheadline) }
                }
                Spacer(minLength: Theme.Space.item)
                if settings.mode == m { Image(systemName: "checkmark").font(.body.weight(.semibold)).foregroundStyle(Theme.accent) }
            }
            .padding(.vertical, Theme.Space.tight)
            .frame(minHeight: Theme.Size.tap)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(settings.mode == m ? .isSelected : [])
        .accessibilityHint(requirement(m) ?? "")
    }

    /// What a mode still needs before it can be used.
    private func requirement(_ m: AnswerMode) -> String? {
        switch m {
        case .onDevice: nil
        case .hybrid: !settings.cloudReady ? "先在下方保存密钥并测试连接" : (settings.consented ? nil : "同意发送健康数据后，涉及你记录的问题也由云端回答；现在只发通用问题")
        case .cloud: !settings.cloudReady ? "先保存密钥、测试连接，并同意发送健康数据" : (settings.consented ? nil : "先在下方同意发送健康数据")
        }
    }

    @ViewBuilder
    private func result(_ state: TestState) -> some View {
        switch state {
        case .ok(let t): StatusLabel(.good(t)).font(.subheadline)
        case .failed(let t): StatusLabel(.urgent(t)).font(.subheadline)
        default: EmptyView()
        }
    }

    private func runTest() async {
        guard let client = settings.client() else { return }
        test = .running
        let start = Date.app
        do {
            let reply = try await client.stream(system: "你是连接测试。", prompt: "请只回复四个字：连接成功", maxTokens: 20) { _ in }
            let secs = Date.app.timeIntervalSince(start)
            settings.lastTestOK = true
            test = .ok("连接成功 · \(String(format: "%.1f", secs)) 秒 · 回复：\(reply.trimmingCharacters(in: .whitespacesAndNewlines).prefix(20))")
        } catch {
            settings.lastTestOK = false
            test = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    private func runSample(_ ctx: AgentContext) async {
        guard let client = settings.client() else { return }
        sample = .running
        sampleText = ""
        let rule = HealthAgent.reply(to: "我最近整体怎么样？", context: ctx)
        let prompt = "用户数据摘要：\n\(HealthAgent.digest(ctx, anonymous: true))\n\n用户的问题：我最近整体怎么样？\n\n分析要点（来自用户记录）：\n\(rule.text)"
        do {
            _ = try await client.stream(system: HealthAgent.cloudInstructions, prompt: prompt) { partial in sampleText = partial }
            sample = .ok("")
        } catch {
            sample = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }
}

/// Searchable list of every model OpenRouter offers (public list, no key needed).
struct OpenRouterModelBrowser: View {
    @Binding var selection: String
    @Environment(\.dismiss) private var dismiss
    @State private var models: [String] = []
    @State private var query = ""
    @State private var error: String?

    var body: some View {
        CalmNavigationStack {
            List {
                if let error { StatusLabel(.urgent(error)).font(.subheadline) }
                if models.isEmpty && error == nil {
                    HStack { ProgressView(); Text("正在获取模型列表…").foregroundStyle(.secondary) }
                }
                ForEach(filtered, id: \.self) { id in
                    Button {
                        selection = id
                        dismiss()
                    } label: {
                        HStack {
                            Text(id).font(.subheadline).foregroundStyle(.primary)
                            Spacer()
                            if id == selection { Image(systemName: "checkmark").foregroundStyle(Theme.accent) }
                        }
                        .frame(minHeight: Theme.Size.tap)
                    }
                }
            }
            .searchable(text: $query, prompt: "搜索，如 anthropic、claude、qwen")
            .navigationTitle("OpenRouter 模型")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
            .task {
                do { models = try await OpenRouterModels.fetchAll() }
                catch { self.error = "无法获取模型列表：\(error.localizedDescription)" }
            }
        }
    }

    private var filtered: [String] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let list = q.isEmpty ? models : models.filter { $0.lowercased().contains(q) }
        // Anthropic models first, as they are the recommended default.
        return list.filter { $0.hasPrefix("anthropic/") } + list.filter { !$0.hasPrefix("anthropic/") }
    }
}
