import Foundation
import Security

// Optional cloud language model for the Health Agent — a test entry under 我的. Off by default.
// When enabled (key saved, connection tested, sending explicitly agreed to), each question sends
// the data digest, the rules-engine analysis and the question to the configured service.
// Emergency questions are always answered on the device.

enum CloudProvider: String, CaseIterable, Identifiable {
    case openRouter, anthropic, openAICompatible
    var id: String { rawValue }
    var label: String {
        switch self {
        case .openRouter: "OpenRouter"
        case .anthropic: "Anthropic Claude"
        case .openAICompatible: "OpenAI 兼容接口"
        }
    }
    var defaultBaseURL: String {
        switch self {
        case .openRouter: "https://openrouter.ai/api/v1"
        case .anthropic: "https://api.anthropic.com/v1"
        case .openAICompatible: ""
        }
    }
    var defaultModel: String {
        switch self {
        case .openRouter: "anthropic/claude-sonnet-5.5"
        case .anthropic: "claude-sonnet-5-5"
        case .openAICompatible: ""
        }
    }
    /// Speaks the OpenAI chat-completions dialect.
    var isOpenAIStyle: Bool { self != .anthropic }
    /// Launch-environment variable that can supply this provider's key (see Demo/ scripts).
    var launchKeyVariable: String? {
        switch self {
        case .openRouter: "PULSE_OPENROUTER_KEY"
        case .anthropic: "PULSE_ANTHROPIC_KEY"
        case .openAICompatible: nil
        }
    }
}

/// OpenRouter model presets (IDs as listed by openrouter.ai/api/v1/models), Anthropic first.
enum OpenRouterModels {
    struct Preset: Identifiable, Hashable {
        var id: String { model }
        let group: String
        let name: String
        let model: String
    }
    static let presets: [Preset] = [
        .init(group: "Anthropic", name: "Claude Sonnet 5.5", model: "anthropic/claude-sonnet-5.5"),
        .init(group: "Anthropic", name: "Claude Opus 5.5", model: "anthropic/claude-opus-5.5"),
        .init(group: "Anthropic", name: "Claude Haiku 5.5", model: "anthropic/claude-haiku-5.5"),
        .init(group: "OpenAI", name: "GPT-6.1 Sol", model: "openai/gpt-6.1-sol"),
        .init(group: "Google", name: "Gemini 3.8 Flash", model: "google/gemini-3.8-flash"),
        .init(group: "DeepSeek", name: "DeepSeek V4 Pro", model: "deepseek/deepseek-v4-pro"),
        .init(group: "通义千问", name: "Qwen 3.7 Plus", model: "qwen/qwen3.7-plus"),
        .init(group: "Kimi", name: "Kimi K3", model: "moonshotai/kimi-k3"),
        .init(group: "智谱", name: "GLM-5.3", model: "z-ai/glm-5.3"),
    ]
    static var groups: [String] { presets.reduce(into: [String]()) { if !$0.contains($1.group) { $0.append($1.group) } } }
    static func name(for model: String) -> String? { presets.first { $0.model == model }?.name }

    /// The full public model list (no key needed); batch variants are left out.
    static func fetchAll() async throws -> [String] {
        guard let url = URL(string: "https://openrouter.ai/api/v1/models") else { return [] }
        let (data, response) = try await URLSession.shared.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = json["data"] as? [[String: Any]] else { throw CloudModelError.empty }
        return list.compactMap { $0["id"] as? String }.filter { !$0.hasSuffix(":batch") }.sorted()
    }
}

/// Keys handed to the app at launch (e.g. `SIMCTL_CHILD_PULSE_OPENROUTER_KEY` from the demo script,
/// which reads the key the user already uses for summit2md). They are kept in memory only.
enum LaunchKeys {
    static func key(for provider: CloudProvider) -> String? {
        guard let name = provider.launchKeyVariable,
              let v = ProcessInfo.processInfo.environment[name]?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty else { return nil }
        return v
    }
    static var source: String { ProcessInfo.processInfo.environment["PULSE_KEY_SOURCE"].flatMap { $0.isEmpty ? nil : $0 } ?? "启动环境" }
}

enum KeySource: Equatable {
    case none, keychain, launch(String)
}

/// Settings for the cloud model test entry (the API key itself lives in the Keychain).
@MainActor
@Observable
final class CloudModelSettings {
    static let shared = CloudModelSettings()
    private let d = UserDefaults.standard

    var provider: CloudProvider {
        didSet { d.set(provider.rawValue, forKey: "cloud.provider") }
    }
    var baseURL: String {
        didSet { d.set(baseURL, forKey: "cloud.baseURL") }
    }
    var model: String {
        didSet { d.set(model, forKey: "cloud.model") }
    }
    /// The user agreed that questions send the data digest to the service.
    var consented: Bool {
        didSet { d.set(consented, forKey: "cloud.consented"); if !consented { enabled = false } }
    }
    /// Use the cloud model for Health Agent answers.
    var enabled: Bool {
        didSet { d.set(enabled, forKey: "cloud.enabled") }
    }
    var lastTestOK: Bool {
        didSet { d.set(lastTestOK, forKey: "cloud.lastTestOK") }
    }
    /// Bumped when a key is saved or deleted so views re-read the Keychain.
    private var keyRevision = 0

    init() {
        provider = CloudProvider(rawValue: d.string(forKey: "cloud.provider") ?? "") ?? .openRouter
        baseURL = d.string(forKey: "cloud.baseURL") ?? CloudProvider.openRouter.defaultBaseURL
        model = d.string(forKey: "cloud.model") ?? CloudProvider.openRouter.defaultModel
        consented = d.bool(forKey: "cloud.consented")
        enabled = d.bool(forKey: "cloud.enabled")
        lastTestOK = d.bool(forKey: "cloud.lastTestOK")
        // Earlier versions kept one key for all providers; it belonged to the provider saved then.
        if let old = KeychainStore.read(account: "cloud.apiKey") {
            KeychainStore.save(old, account: Self.account(provider))
            KeychainStore.delete(account: "cloud.apiKey")
        }
    }

    private static func account(_ p: CloudProvider) -> String { "cloud.apiKey.\(p.rawValue)" }

    /// Where the current provider's key comes from: the Keychain first, then the launch environment.
    var keySource: KeySource {
        _ = keyRevision
        if KeychainStore.read(account: Self.account(provider)) != nil { return .keychain }
        if LaunchKeys.key(for: provider) != nil { return .launch(LaunchKeys.source) }
        return .none
    }
    var hasKey: Bool { keySource != .none }
    private var apiKey: String? { KeychainStore.read(account: Self.account(provider)) ?? LaunchKeys.key(for: provider) }

    var isConfigured: Bool { hasKey && !model.trimmingCharacters(in: .whitespaces).isEmpty && URL(string: baseURL)?.scheme == "https" }
    /// Cloud answers are used only when everything is set and the user opted in.
    var isActive: Bool { enabled && consented && lastTestOK && isConfigured }

    @discardableResult
    func saveKey(_ key: String) -> Bool {
        let ok = KeychainStore.save(key.trimmingCharacters(in: .whitespacesAndNewlines), account: Self.account(provider))
        keyRevision += 1
        lastTestOK = false
        return ok
    }

    /// Keeps a launch-provided key for later runs (only when the user asks).
    func saveLaunchKeyToKeychain() {
        if let k = LaunchKeys.key(for: provider) { saveKey(k) }
    }

    func deleteKey() {
        KeychainStore.delete(account: Self.account(provider))
        keyRevision += 1
        lastTestOK = false
        enabled = false
    }

    func client() -> CloudModelClient? {
        guard isConfigured, let key = apiKey else { return nil }
        return CloudModelClient(provider: provider, baseURL: baseURL, model: model.trimmingCharacters(in: .whitespaces), apiKey: key)
    }
}

// MARK: - Keychain

enum KeychainStore {
    private static let service = "com.pulse.restingheart.cloudmodel"

    @discardableResult
    static func save(_ value: String, account: String) -> Bool {
        delete(account: account)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecValueData as String: Data(value.utf8),
        ]
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    static func read(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - Client

enum CloudModelError: LocalizedError, Equatable {
    case badURL
    case http(Int, String)
    case service(String)
    case empty
    case network(String)

    var errorDescription: String? {
        switch self {
        case .badURL: "接口地址无效，需要以 https:// 开头。"
        case .http(let code, let msg):
            switch code {
            case 401, 403: "身份验证失败（\(code)）：请检查 API 密钥。\(msg)"
            case 404: "找不到接口或模型（404）：请检查接口地址和模型名称。\(msg)"
            case 429: "请求过于频繁或额度不足（429）。\(msg)"
            default: "服务返回错误 \(code)。\(msg)"
            }
        case .service(let msg): "服务返回错误：\(msg)"
        case .empty: "服务没有返回内容。"
        case .network(let msg): "网络错误：\(msg)"
        }
    }
}

/// One server-sent-events line, decoded for either provider.
enum CloudStreamEvent: Equatable {
    case text(String)
    case done
    case error(String)
    case ignore
}

struct CloudModelClient {
    let provider: CloudProvider
    let baseURL: String
    let model: String
    let apiKey: String

    func request(system: String, prompt: String, maxTokens: Int) throws -> URLRequest {
        let base = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        let path = provider == .anthropic ? "/messages" : "/chat/completions"
        guard let url = URL(string: base + path), url.scheme == "https" else { throw CloudModelError.badURL }
        var r = URLRequest(url: url, timeoutInterval: 60)
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "content-type")
        let body: [String: Any]
        switch provider {
        case .anthropic:
            r.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            r.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            body = ["model": model, "max_tokens": maxTokens, "stream": true, "system": system,
                    "messages": [["role": "user", "content": prompt]]]
        case .openAICompatible, .openRouter:
            r.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            if provider == .openRouter { r.setValue("Pulse", forHTTPHeaderField: "X-Title") }
            body = ["model": model, "max_tokens": maxTokens, "stream": true, "temperature": 0.3,
                    "messages": [["role": "system", "content": system], ["role": "user", "content": prompt]]]
        }
        r.httpBody = try JSONSerialization.data(withJSONObject: body)
        return r
    }

    /// Streams the answer, reporting the accumulated text as it arrives.
    @MainActor
    func stream(system: String, prompt: String, maxTokens: Int = 900, onPartial: @escaping @MainActor (String) -> Void) async throws -> String {
        let req = try request(system: system, prompt: prompt, maxTokens: maxTokens)
        let (bytes, response): (URLSession.AsyncBytes, URLResponse)
        do {
            (bytes, response) = try await URLSession.shared.bytes(for: req)
        } catch {
            throw CloudModelError.network(error.localizedDescription)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            var body = ""
            for try await line in bytes.lines { body += line; if body.count > 2000 { break } }
            throw CloudModelError.http(status, Self.errorMessage(in: body) ?? "")
        }
        var text = ""
        for try await line in bytes.lines {
            switch Self.parse(line: line, provider: provider) {
            case .text(let t):
                text += t
                onPartial(text)
            case .done: return text
            case .error(let m): throw CloudModelError.service(m)
            case .ignore: continue
            }
        }
        guard !text.isEmpty else { throw CloudModelError.empty }
        return text
    }

    /// Decodes one SSE line from the Anthropic Messages API or an OpenAI-compatible chat API.
    static func parse(line: String, provider: CloudProvider) -> CloudStreamEvent {
        guard line.hasPrefix("data:") else { return .ignore }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        if payload == "[DONE]" { return .done }
        guard let data = payload.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return .ignore }
        if let err = json["error"] as? [String: Any] { return .error(err["message"] as? String ?? "未知错误") }
        switch provider {
        case .anthropic:
            switch json["type"] as? String {
            case "content_block_delta":
                if let delta = json["delta"] as? [String: Any], let t = delta["text"] as? String { return .text(t) }
            case "message_stop": return .done
            default: break
            }
        case .openAICompatible, .openRouter:
            if let choices = json["choices"] as? [[String: Any]], let delta = choices.first?["delta"] as? [String: Any],
               let t = delta["content"] as? String {
                return .text(t)
            }
        }
        return .ignore
    }

    static func errorMessage(in body: String) -> String? {
        guard let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return body.isEmpty ? nil : String(body.prefix(200)) }
        if let err = json["error"] as? [String: Any], let m = err["message"] as? String { return m }
        if let m = json["message"] as? String { return m }
        return nil
    }
}

extension HealthAgent {
    /// Cloud models have more room: answer from the digest, using the rules analysis as the facts.
    static let cloudInstructions = """
    你是 Pulse 应用中的 Health Agent，帮助用户理解自己的健康数据，长期目标是降低静息心率，串联运动、睡眠、饮食、身体指标和恢复。
    要求：
    1. 只依据【数据】和【要点】回答，引用其中的数字；没有的数据直接说明没有记录，不要编造。不要输出【】标题，也不要整段复述【数据】；问题和健康数据无关时直接说明。
    2. 区分「观察到的关联」和「已确认的原因」；不做诊断；不建议开始、停止或调整任何药物和剂量。
    3. 用户描述紧急症状时，第一句建议立即拨打 120；否则不要提及急救。
    4. 用简体中文，先给结论，再给 2–4 条具体、可执行的建议（每条以「• 」开头）。不超过 300 字，不用标题和表格。
    5. 需要专业判断时建议咨询医生，并提醒可以带上 Pulse 生成的就诊摘要。
    6. 注意摘要中的「现在」时间。给出【第一句】时，回答必须以它原样开头，后面的内容不能与它矛盾，不要输出「结论：」之类的标签；某天是否适合训练，分析要点没有结论时，说明要看当天早上的准备度，不要自行判断「适合」。
    """
}
