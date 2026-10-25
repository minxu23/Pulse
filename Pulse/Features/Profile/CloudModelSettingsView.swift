import SwiftUI

/// 云端模型（测试）：connect your own cloud model account to try Health Agent answers.
/// Off by default; nothing is sent until a key is saved, the connection is tested and sending
/// the data digest is explicitly agreed to.
struct CloudModelSettingsView: View {
    @State private var settings = CloudModelSettings.shared
    @State private var keyInput = ""
    @State private var test: TestState = .idle
    @State private var sample: TestState = .idle
    @State private var sampleText = ""
    @State private var showDigest = false
    @State private var browseModels = false

    enum TestState: Equatable {
        case idle, running
        case ok(String)
        case failed(String)
    }

    var body: some View {
        AgentContextReader { ctx in
            Form {
                Section {
                    Label {
                        Text("接入你自己的云端大模型账号，测试 Health Agent 的回答效果。默认关闭，Pulse 的其他功能不受影响。")
                    } icon: { Image(systemName: "flask").foregroundStyle(.secondary) }
                    StatusLabel(.attention("开启后，向 Health Agent 提问时，会把下方的「数据摘要」、本机分析要点和你的问题发送到所选服务，并受该服务的隐私条款约束。"))
                }
                .font(.subheadline)

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
                                HStack(spacing: 4) {
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
                        LabeledContent("API 密钥", value: "已保存在钥匙串")
                        Button("删除密钥", role: .destructive) { settings.deleteKey(); test = .idle; sample = .idle }
                    case .launch(let source):
                        LabeledContent("API 密钥", value: "来自\(source)")
                        Text("由启动脚本传入，只在本次运行中使用，没有写入钥匙串或文件。").font(.footnote).foregroundStyle(.secondary)
                        Button("保存到钥匙串，下次也使用") { settings.saveLaunchKeyToKeychain() }
                    case .none:
                        SecureField(settings.provider == .openRouter ? "sk-or-…" : "粘贴 API 密钥", text: $keyInput)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                        HStack {
                            Button("从剪贴板粘贴") { keyInput = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
                                .buttonStyle(.borderless)
                            Spacer()
                            Button("保存到钥匙串") {
                                settings.saveKey(keyInput)
                                keyInput = ""
                            }
                            .buttonStyle(.borderless)
                            .disabled(keyInput.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }
                } header: { Text("API 密钥") } footer: {
                    Text(settings.provider == .openRouter
                         ? "每个服务的密钥分开保存在本机钥匙串，不会出现在导出的数据中。用 Demo 文件夹中的脚本启动时，会自动带上 ~/.spark/keys 中的 OpenRouter / Anthropic 密钥（与 Spark、summit2md 共用）。"
                         : "每个服务的密钥分开保存在本机钥匙串，不会出现在导出的数据中。")
                }

                Section {
                    Button {
                        Task { await runTest() }
                    } label: {
                        HStack {
                            Label("测试连接", systemImage: "antenna.radiowaves.left.and.right")
                                .foregroundStyle(settings.isConfigured ? Theme.accent : Color.secondary)
                            Spacer()
                            if test == .running { ProgressView() }
                        }
                    }
                    .disabled(!settings.isConfigured || test == .running)
                    result(test)
                } header: { Text("连接测试") } footer: {
                    Text("测试只发送一句固定的文字，不包含任何健康数据。")
                }

                Section {
                    Toggle("我了解提问时会发送数据摘要", isOn: $settings.consented)
                    DisclosureGroup("查看会发送的数据摘要", isExpanded: $showDigest) {
                        Text(HealthAgent.digest(ctx, anonymous: true))
                            .font(.footnote).foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .padding(.vertical, 4)
                    }
                } header: { Text("发送内容") } footer: {
                    Text("摘要只包含统计结果（如近 7 天静息心率平均值、睡眠时长、达标情况），不包含姓名、逐条记录或设备标识。")
                }

                Section {
                    Toggle("使用云端模型回答", isOn: $settings.enabled)
                        .disabled(!(settings.consented && settings.lastTestOK && settings.isConfigured))
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
                        Text(sampleText).font(.subheadline).textSelection(.enabled).padding(.vertical, 4)
                    }
                    if case .failed = sample { result(sample) }
                } header: { Text("在 Health Agent 中使用") } footer: {
                    Text("需要先保存密钥、测试连接成功并同意发送摘要。关闭后恢复为本机分析（Apple 智能或规则分析）；紧急情况的提示始终由本机给出。")
                }
            }
        }
        .sheet(isPresented: $browseModels) { OpenRouterModelBrowser(selection: $settings.model) }
        .navigationTitle("云端模型（测试）").calmStyle()
        .navigationBarTitleDisplayMode(.inline)
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
                        .frame(minHeight: 44)
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
