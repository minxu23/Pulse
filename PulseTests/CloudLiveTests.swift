import Foundation
import SwiftData
import Testing
@testable import Pulse

/// A round of real questions to the cloud model set up in this simulator's Pulse (key in its Keychain):
/// 全部云端 first, then 端云结合, with the 王建国 sample data. It spends the user's key, so it runs only
/// when asked — `TEST_RUNNER_PULSE_LIVE_CLOUD=1 xcodebuild test -only-testing:PulseTests/CloudLiveTests …`
/// — and puts the answer mode back as it found it. `TEST_RUNNER_PULSE_LIVE_ONLY=问题|问题` asks only
/// the rounds that start with those questions. The answers go to `tmp/pulse-cloud-live.md` in the
/// app's container.
@Suite("Cloud model, live", .enabled(if: ProcessInfo.processInfo.environment["PULSE_LIVE_CLOUD"] == "1"))
@MainActor
struct CloudLiveTests {
    static let cloudQuestions: [[String]] = [
        ["今天能跑步吗", "那明天呢？"],
        ["我最近血压怎么样"],
        ["帮我记一下血压 138/88"],
        ["脚有点肿，记下来"],
        ["肌酐 1.44 mg/dL 帮我记一下"],
        ["我刚喝了一杯水"],
        ["下周三提醒我去医院复查"],
        ["头疼能吃布洛芬吗"],
        ["血钾高不能吃什么"],
        ["我心情不好"],
        ["胸口闷"],
        ["这周总结一下"],
        ["这周训练量减一点"],
        ["晚上睡不好怎么办"],
    ]
    /// The other sample users, 全部云端: `-only-testing:PulseTests/CloudLiveTests/otherPeople()`.
    private static let peopleQuestions: [(DemoPersona, [[String]])] = [
        (.xiaolin, [["今天能跑间歇吗"], ["我的静息心率怎么样"], ["下个月想跑半马，怎么准备"]]),
        (.chenjie, [["昨晚喝了酒，今天能运动吗"], ["我血压偏高该怎么办"], ["老是熬夜怎么办"], ["计划总是完成不了"]]),
        (.linyue, [["上完夜班能运动吗"], ["我睡眠很乱怎么办"], ["这周总结一下"]]),
    ]
    private static let hybridQuestions: [[String]] = [
        ["间歇训练是什么"],
        ["肾病为什么要少吃盐"],
        ["我最近血压怎么样"],
        ["帮我记一下血压 138/88"],
    ]

    @Test func aRoundOfQuestions() async throws {
        let settings = CloudModelSettings.shared
        try #require(settings.cloudReady && settings.consented, "this simulator's Pulse has no tested cloud key with consent")
        let mode = settings.mode
        defer { settings.mode = mode }
        let (c, container) = try LiveRound.context()
        _ = container
        var report = "# 云端模型实测 \(Date().formatted(date: .numeric, time: .shortened))\n服务：\(settings.provider.label) · \(settings.model)\n\n"
        settings.mode = .cloud
        for round in LiveRound.only(Self.cloudQuestions) {
            let r = await LiveRound.ask(round, mode: .cloud, context: c)
            report += r
            print(r)
        }
        settings.mode = .hybrid
        for round in LiveRound.only(Self.hybridQuestions) {
            let r = await LiveRound.ask(round, mode: .hybrid, context: c)
            report += r
            print(r)
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pulse-cloud-live.md")
        try report.write(to: url, atomically: true, encoding: .utf8)
    }
}

extension CloudLiveTests {
    @Test func otherPeople() async throws {
        let settings = CloudModelSettings.shared
        try #require(settings.cloudReady && settings.consented, "this simulator's Pulse has no tested cloud key with consent")
        let mode = settings.mode
        defer { settings.mode = mode }
        settings.mode = .cloud
        var report = "# 云端模型实测（其他示例用户） \(Date().formatted(date: .numeric, time: .shortened))\n服务：\(settings.provider.label) · \(settings.model)\n\n"
        for (persona, rounds) in Self.peopleQuestions {
            let (c, container) = try LiveRound.context(persona)
            _ = container
            report += "## \(persona.name)\n\n"
            for round in LiveRound.only(rounds) {
                let r = await LiveRound.ask(round, mode: .cloud, context: c)
                report += r
                print(r)
            }
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pulse-cloud-people.md")
        try report.write(to: url, atomically: true, encoding: .utf8)
    }
}

extension CloudLiveTests {
    /// Where the wait goes in one answer: `-only-testing:PulseTests/CloudLiveTests/timing()`. Reports
    /// when the first bytes, the first reasoning and the first answer text arrive (nothing of the key).
    @Test func timing() async throws {
        let settings = CloudModelSettings.shared
        try #require(settings.cloudReady && settings.consented, "this simulator's Pulse has no tested cloud key with consent")
        let client = try #require(settings.client())
        let (c, container) = try LiveRound.context(.chenjie)
        _ = container
        let q = "老是熬夜怎么办"
        let rule = HealthAgent.reply(to: q, context: c)
        let (system, prompt) = AgentConversation().cloudRequest(q, rule: rule, history: [], context: HealthAgent.context(c, answering: rule))
        var report = "# 云端用时 \(Date().formatted(date: .numeric, time: .shortened))\n服务：\(settings.provider.label) · \(settings.model)\n"
        var start = Date()
        var (bytes, response) = try await URLSession.shared.bytes(for: client.request(system: system, prompt: prompt, maxTokens: 1600))
        if (response as? HTTPURLResponse)?.statusCode == 400 {
            // As the app does: a model that must reason is asked again with "minimal".
            var body = ""
            for try await line in bytes.lines { body += line; if body.count > 600 { break } }
            report += "- 不推理被拒：\(CloudModelClient.errorMessage(in: body) ?? "")\n"
            start = Date()
            (bytes, response) = try await URLSession.shared.bytes(for: client.request(system: system, prompt: prompt, maxTokens: 1600, reasoning: "minimal"))
        }
        report += "- 状态 \((response as? HTTPURLResponse)?.statusCode ?? 0)，响应头 \(String(format: "%.1f", Date().timeIntervalSince(start))) 秒\n"
        var firstLine: Double?, firstReasoning: Double?, firstText: Double?, lastText: Double?
        var reasoningChunks = 0, textChunks = 0, chars = 0
        for try await line in bytes.lines {
            let t = Date().timeIntervalSince(start)
            if firstLine == nil { firstLine = t }
            guard line.hasPrefix("data:"), let data = line.dropFirst(5).trimmingCharacters(in: .whitespaces).data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let delta = (json["choices"] as? [[String: Any]])?.first?["delta"] as? [String: Any] else { continue }
            if let r = delta["reasoning"] as? String, !r.isEmpty { reasoningChunks += 1; if firstReasoning == nil { firstReasoning = t } }
            if let x = delta["content"] as? String, !x.isEmpty { textChunks += 1; chars += x.count; if firstText == nil { firstText = t }; lastText = t }
        }
        func s(_ x: Double?) -> String { x.map { String(format: "%.1f 秒", $0) } ?? "无" }
        report += "- 第一行数据 \(s(firstLine))；第一段推理 \(s(firstReasoning))（\(reasoningChunks) 段）\n"
        report += "- 第一段正文 \(s(firstText))，最后一段 \(s(lastText))；正文 \(textChunks) 段、\(chars) 字\n"
        report += "- 提示长度：系统 \(system.count) 字，问题与摘要 \(prompt.count) 字\n"
        print(report)
        try report.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("pulse-cloud-timing.md"), atomically: true, encoding: .utf8)
    }
}

/// The same questions to Apple Intelligence on this device or simulator (free, nothing leaves it):
/// `TEST_RUNNER_PULSE_LIVE_LOCAL=1 xcodebuild test -only-testing:PulseTests/OnDeviceLiveTests …`.
/// The answers go to `tmp/pulse-on-device-live.md` in the app's container.
@Suite("Apple Intelligence, live", .enabled(if: ProcessInfo.processInfo.environment["PULSE_LIVE_LOCAL"] == "1"))
@MainActor
struct OnDeviceLiveTests {
    static let questions: [[String]] = CloudLiveTests.cloudQuestions + [
        ["最近总觉得累"],
        ["我有点担心肾功能会变差"],
        ["今天吃了什么比较好"],
    ]

    @Test func aRoundOfQuestions() async throws {
        try #require(OnDeviceModel.isAvailable, "\(OnDeviceModel.unavailableReason)")
        let settings = CloudModelSettings.shared
        let mode = settings.mode
        defer { settings.mode = mode }
        settings.mode = .onDevice
        let (c, container) = try LiveRound.context()
        _ = container
        var report = "# Apple 智能实测 \(Date().formatted(date: .numeric, time: .shortened))\n\n"
        for round in LiveRound.only(Self.questions) {
            let r = await LiveRound.ask(round, mode: .onDevice, context: c)
            report += r
            print(r)
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pulse-on-device-live.md")
        try report.write(to: url, atomically: true, encoding: .utf8)
    }
}

@MainActor
enum LiveRound {
    /// `TEST_RUNNER_PULSE_LIVE_ONLY=问题|问题`: only the rounds that start with those questions.
    static func only(_ rounds: [[String]]) -> [[String]] {
        let only = ProcessInfo.processInfo.environment["PULSE_LIVE_ONLY"].map { Set($0.components(separatedBy: "|")) }
        return rounds.filter { only?.contains($0[0]) ?? true }
    }

    static func context(_ persona: DemoPersona = .wangjianguo) throws -> (AgentContext, ModelContainer) {
        let container = try ModelContainer(for: Schema(PulseSchema.models), configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        let ctx = container.mainContext
        let now = Date()
        DemoDataGenerator.populate(ctx, persona: persona, now: now)
        DataHub.ensureWeekPlan(in: ctx, now: now)
        let a = DataHub.analytics(in: ctx, now: now)
        let items = ((try? ctx.fetch(FetchDescriptor<PlanItem>())) ?? []).map(\.snapshot)
        let workouts = ((try? ctx.fetch(FetchDescriptor<ActivitySession>())) ?? []).map(\.point)
        let vitals = ((try? ctx.fetch(FetchDescriptor<VitalReading>())) ?? []).map(\.point).filter { $0.time > now.adding(days: -60) }
        let labs = ((try? ctx.fetch(FetchDescriptor<LabResult>())) ?? []).map(\.point)
        var c = AgentContext.make(profile: a.profile, name: persona.name, days: a.days, plan: items, workouts: workouts, vitals: vitals,
                                  events: [], stopBang: [], baselineSetAt: nil, raceName: "", labs: labs, now: now)
        c.agentName = AgentNameSettings.shared.name
        return (c, container)
    }

    static func describe(_ b: AgentUIBlock) -> String {
        switch b {
        case .form(let f): "表单「\(f.id)」"
        case .chart(let m, let d, _): "图表 \(m.title) \(d) 天"
        case .checklist(let c): "清单「\(c.id)」"
        case .steps(let s): "步骤「\(s.title)」"
        case .plan(let p): "计划修改 \(p.id)"
        case .condition(let c): "记下健康状况「\(c.info.name)」"
        case .record(let r): "记下：" + r.items.map(RecordProposal.label).joined(separator: "、")
        }
    }

    static func ask(_ round: [String], mode: AnswerMode, context c: AgentContext) async -> String {
        var c = c
        c.answerMode = mode
        let chat = AgentConversation()
        var out = ""
        for q in round {
            let before = chat.messages.count
            let start = Date()
            await chat.send(q, context: c)
            let secs = Date().timeIntervalSince(start)
            let rule = HealthAgent.reply(to: HealthAgent.resolveFollowUp(q, previous: round.first == q ? nil : round.first) ?? q, context: c)
            out += "### [\(mode.label)] \(q)\n"
            for m in chat.messages[before...] where m.role == .agent {
                out += "- 引擎：\(m.engine.rawValue)，用时 \(String(format: "%.1f", secs)) 秒\(m.general ? "，通用问题" : "")\n"
                if let n = m.note { out += "- 说明：\(n)\n" }
                if let p = m.privacy { out += "- \(p)\n" }
                if let k = rule.conclusion { out += "- 规则的第一句：\(k.split(separator: "。").first.map { $0 + "。" } ?? k)\n" }
                if let s = rule.safety { out += "- 规则的安全提示：\(s)\n" }
                out += "\n" + m.text + "\n\n"
                if !m.blocks.isEmpty { out += "- 卡片：" + m.blocks.map(describe).joined(separator: "；") + "\n" }
                if let f = m.reply?.followUps, !f.isEmpty { out += "- 追问：" + f.joined(separator: " / ") + "\n" }
                // What the app promises whatever the model writes.
                if m.engine != .rules, !m.general, let k = rule.conclusion {
                    let verdict = k.split(separator: "。").first.map(String.init) ?? k
                    #expect(m.text.filter { !$0.isWhitespace }.contains(verdict.filter { !$0.isWhitespace }), "\(q): first sentence kept")
                }
                if let s = rule.safety { #expect(HealthAgent.says(m.text, safety: s), "\(q): safety kept") }
                if rule.blocks.contains(where: { $0.record != nil }) { #expect(HealthAgent.withoutRecordClaims(m.text) == m.text, "\(q): no claim of recording") }
                #expect(AgentName.firstPerson(m.text, name: c.agentName) == m.text && !m.text.contains("帮你生成"), "\(q): speaks as 「我」, makes nothing itself")
                if rule.blocks.contains(where: { $0.record != nil }) { #expect(m.blocks.contains { $0.record != nil }, "\(q): 记下 card kept") }
            }
            out += "\n"
        }
        return out
    }
}
