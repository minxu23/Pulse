import Foundation
import SwiftData
import Testing
@testable import Pulse

private let evening = Calendar.pulse.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 20))!

@Suite("回答方式: what may leave the device")
@MainActor
struct AgentRoutingTests {
    private func load(_ persona: DemoPersona) throws -> (AgentContext, ModelContainer) {
        let container = try ModelContainer(for: Schema(PulseSchema.models), configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        let ctx = container.mainContext
        DemoDataGenerator.populate(ctx, persona: persona, now: evening)
        DataHub.ensureWeekPlan(in: ctx, now: evening)
        let p = DataHub.profile(in: ctx)!
        let a = DataHub.analytics(in: ctx, now: evening)
        let items = (try? ctx.fetch(FetchDescriptor<PlanItem>())) ?? []
        let vitals = (try? ctx.fetch(FetchDescriptor<VitalReading>())) ?? []
        let labs = ((try? ctx.fetch(FetchDescriptor<LabResult>())) ?? []).map(\.point)
        let c = AgentContext.make(profile: a.profile, name: p.displayName, days: a.days, plan: items.map(\.snapshot), workouts: [],
                                  vitals: vitals.map(\.point).filter { $0.time > evening.adding(days: -60) }, events: [],
                                  stopBang: [], baselineSetAt: nil, raceName: p.raceName, labs: labs, now: evening)
        return (c, container)
    }

    private func route(_ q: String, _ c: AgentContext) -> AgentRoute {
        AgentRouting.route(q, reply: HealthAgent.reply(to: q, context: c), profile: c.profile, name: c.name)
    }

    private func isGeneral(_ r: AgentRoute) -> Bool { if case .general = r { true } else { false } }

    @Test func modesNeedTheirSetup() {
        #expect(AnswerMode.effective(.hybrid, cloudReady: false, digestConsented: true) == .onDevice)
        #expect(AnswerMode.effective(.hybrid, cloudReady: true, digestConsented: false) == .hybrid, "端云结合 sends no digest")
        #expect(AnswerMode.effective(.cloud, cloudReady: true, digestConsented: false) == .onDevice)
        #expect(AnswerMode.effective(.cloud, cloudReady: true, digestConsented: true) == .cloud)
        #expect(AnswerMode.effective(.onDevice, cloudReady: true, digestConsented: true) == .onDevice)
    }

    @Test func questionsAboutTheUserStayOnTheDevice() throws {
        let (c, container) = try load(.wangjianguo)
        _ = container
        for q in ["我能吃香蕉吗", "今天早上血压155，要紧吗", "我的血压控制得怎么样", "今天适合散步吗", "最近脚有点肿", "我最近老是做噩梦",
                  "氨氯地平能和柚子一起吃吗", "糖尿病人能吃水果吗", "我是低血钾症患者", "帮我把周三的散步改到周四", "你好",
                  "我确诊了痛风该注意什么", "体重 82kg 合适吗", "我的肾功能怎么样", "胸口痛"] {
            #expect(!isGeneral(route(q, c)), "\(q) must not leave the device")
        }
    }

    @Test func generalQuestionsMayGoToTheCloud() throws {
        let (c, container) = try load(.xiaolin)
        _ = container
        for q in ["拉伸怎么做", "我应该买什么跑鞋", "马拉松怎么补给", "HRV是什么意思", "静息心率多少算正常", "帮我写首诗"] {
            #expect(isGeneral(route(q, c)), "\(q) is a general question")
        }
        // The same topics asked about the user's own numbers stay local.
        for q in ["为什么我的HRV这么低", "怎么才能把静息心率降下来", "我这周的训练量是不是太大了", "我适合跑马拉松吗"] {
            #expect(!isGeneral(route(q, c)), "\(q) needs the records")
        }
    }

    @Test func onlyTheQuestionGoesOut() throws {
        let (c, container) = try load(.xiaolin)
        _ = container
        #expect(route("我的手机号是13812345678，拉伸怎么做", c) == .general("我的手机号是[手机号]，拉伸怎么做"))
        #expect(AgentRouting.redacted("发到 a.b@example.com") == "发到 [邮箱]")
        let prompt = HealthAgent.generalPrompt(question: "拉伸怎么做", history: ["用户：跑鞋怎么选", "助手：看脚型"])
        #expect(prompt.hasSuffix("问题：拉伸怎么做") && !prompt.contains("静息心率") && !prompt.contains("【数据】"))
        #expect(HealthAgent.generalCloudInstructions.contains("没有附带用户的任何健康记录"))
    }

    @Test func theCloudModelIsNotHeldToTheSmallModelsLimits() throws {
        let (c, container) = try load(.xiaolin)
        _ = container
        let r = HealthAgent.reply(to: "我这周的训练量是不是太大了", context: c)
        #expect(HealthAgent.modelPrompt(question: "我这周的训练量是不是太大了", history: [], context: c, reply: r, anonymous: false).contains("不要列建议"))
        #expect(!HealthAgent.modelPrompt(question: "我这周的训练量是不是太大了", history: [], context: c, reply: r, anonymous: true).contains("不要列建议"))
        let lead = AgentReply(text: "不大：负荷比 1.07。", intent: .exercise, conclusion: "不大：负荷比 1.07。")
        #expect(HealthAgent.finalize("不大：负荷比 1.07。\n• 这周别再加量", of: lead, strict: false).contains("别再加量"))
        #expect(!HealthAgent.cloudInstructions.contains("降低静息心率"))
    }

    @Test func pastedKeysAreCleanedAndChecked() {
        let k = "sk-or-v1-0123456789abcdef0123456789abcdef"
        #expect(APIKeyText.cleaned("  \(k)\n") == k)
        #expect(APIKeyText.cleaned("OPENROUTER_API_KEY=\"\(k)\"") == k)
        #expect(APIKeyText.cleaned("export OPENROUTER_API_KEY='\(k)'") == k)
        #expect(APIKeyText.cleaned("# my key\nBearer \(k)") == k)
        #expect(APIKeyText.provider(of: k) == .openRouter)
        #expect(APIKeyText.provider(of: "sk-ant-api03-abcdefghijklmnopqrstuvwxyz") == .anthropic)
        #expect(APIKeyText.problem(k, for: .openRouter) == nil)
        #expect(APIKeyText.problem("", for: .openRouter)?.contains("剪贴板里没有文字") == true)
        #expect(APIKeyText.problem("拉伸怎么做", for: .openRouter) != nil, "copied the wrong text")
        #expect(APIKeyText.problem("sk-ant-api03-abcdefghijklmnopqrstuvwxyz", for: .openRouter)?.contains("sk-or-") == true)
        #expect(APIKeyText.problem("anything-long-enough-1234567890", for: .openAICompatible) == nil)
        #expect(APIKeyText.hint(k) == "sk-or-…cdef")
    }
}
