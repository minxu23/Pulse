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
    private static let cloudQuestions: [[String]] = [
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
    private static let hybridQuestions: [[String]] = [
        ["间歇训练是什么"],
        ["肾病为什么要少吃盐"],
        ["我最近血压怎么样"],
        ["帮我记一下血压 138/88"],
    ]

    private func context() throws -> (AgentContext, ModelContainer) {
        let container = try ModelContainer(for: Schema(PulseSchema.models), configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        let ctx = container.mainContext
        let now = Date()
        DemoDataGenerator.populate(ctx, persona: .wangjianguo, now: now)
        DataHub.ensureWeekPlan(in: ctx, now: now)
        let a = DataHub.analytics(in: ctx, now: now)
        let items = ((try? ctx.fetch(FetchDescriptor<PlanItem>())) ?? []).map(\.snapshot)
        let workouts = ((try? ctx.fetch(FetchDescriptor<ActivitySession>())) ?? []).map(\.point)
        let vitals = ((try? ctx.fetch(FetchDescriptor<VitalReading>())) ?? []).map(\.point).filter { $0.time > now.adding(days: -60) }
        let labs = ((try? ctx.fetch(FetchDescriptor<LabResult>())) ?? []).map(\.point)
        var c = AgentContext.make(profile: a.profile, name: "王建国", days: a.days, plan: items, workouts: workouts, vitals: vitals,
                                  events: [], stopBang: [], baselineSetAt: nil, raceName: "", labs: labs, now: now)
        c.agentName = AgentNameSettings.shared.name
        return (c, container)
    }

    private static func describe(_ b: AgentUIBlock) -> String {
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

    private func ask(_ round: [String], mode: AnswerMode, context c: AgentContext) async -> String {
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
                if !m.blocks.isEmpty { out += "- 卡片：" + m.blocks.map(Self.describe).joined(separator: "；") + "\n" }
                if let f = m.reply?.followUps, !f.isEmpty { out += "- 追问：" + f.joined(separator: " / ") + "\n" }
                // What the app promises whatever the model writes.
                if m.engine == .cloud, !m.general, let k = rule.conclusion {
                    let verdict = k.split(separator: "。").first.map(String.init) ?? k
                    #expect(m.text.filter { !$0.isWhitespace }.contains(verdict.filter { !$0.isWhitespace }), "\(q): first sentence kept")
                }
                if let s = rule.safety { #expect(HealthAgent.says(m.text, safety: s), "\(q): safety kept") }
                if rule.blocks.contains(where: { $0.record != nil }) { #expect(HealthAgent.withoutRecordClaims(m.text) == m.text, "\(q): no claim of recording") }
                if rule.blocks.contains(where: { $0.record != nil }) { #expect(m.blocks.contains { $0.record != nil }, "\(q): 记下 card kept") }
            }
            out += "\n"
        }
        return out
    }

    @Test func aRoundOfQuestions() async throws {
        let settings = CloudModelSettings.shared
        try #require(settings.cloudReady && settings.consented, "this simulator's Pulse has no tested cloud key with consent")
        let mode = settings.mode
        defer { settings.mode = mode }
        let (c, container) = try context()
        _ = container
        var report = "# 云端模型实测 \(Date().formatted(date: .numeric, time: .shortened))\n服务：\(settings.provider.label) · \(settings.model)\n\n"
        let only = ProcessInfo.processInfo.environment["PULSE_LIVE_ONLY"].map { Set($0.components(separatedBy: "|")) }
        func asked(_ rounds: [[String]]) -> [[String]] { rounds.filter { only?.contains($0[0]) ?? true } }
        settings.mode = .cloud
        for round in asked(Self.cloudQuestions) {
            let r = await ask(round, mode: .cloud, context: c)
            report += r
            print(r)
        }
        settings.mode = .hybrid
        for round in asked(Self.hybridQuestions) {
            let r = await ask(round, mode: .hybrid, context: c)
            report += r
            print(r)
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pulse-cloud-live.md")
        try report.write(to: url, atomically: true, encoding: .utf8)
    }
}
