import Foundation
import SwiftData
import Testing
@testable import Pulse

private let evening = Calendar.pulse.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 20))!

@Suite("端云结合: identifiers are masked before anything leaves the phone")
@MainActor
struct IdentityMaskTests {
    private func masked(_ s: String, names: [String] = ["晓林"], keep: [String] = ["小安", "氨氯地平"]) -> (String, IdentityMask) {
        var m = IdentityMask(knownNames: names, keep: keep)
        return (m.mask(s), m)
    }

    @Test func directIdentifiersAreReplaced() {
        let cases: [(String, String)] = [
            ("我是王建国，昨天在上海仁济医院找李明医生看了，血压156/98，电话 138 1234 5678",
             "我是[姓名1]，昨天在[医院1]找[医生1]看了，血压156/98，电话 [电话1]"),
            ("我妈刘桂芳血糖12，我老公张伟打呼噜很响", "我妈[姓名1]血糖12，我老公[姓名2]打呼噜很响"),
            ("我女儿小美最近老咳嗽，北京协和医院的张主任说没事", "我女儿[姓名1]最近老咳嗽，[医院1]的[医生1]说没事"),
            ("住在浦东新区张杨路1500号3栋201室，邮箱wang.jg@example.com", "住在[地址1]，邮箱[邮箱1]"),
            ("身份证号 310101198001011234，医保卡号是A12345678，固话021-62345678", "身份证号 [证件号1]，医保卡号是[编号1]，固话[电话1]"),
            ("透析在瑞金医院做，周一三五", "透析在[医院1]做，周一三五"),
            ("王医生让我每天走一万步", "[医生1]让我每天走一万步"),
            ("晓林今天能跑步吗", "[姓名1]今天能跑步吗"),
        ]
        for (raw, want) in cases {
            let (out, m) = masked(raw)
            #expect(out == want, "\(raw) → \(out)")
            #expect(m.restore(out) == raw, "\(raw) comes back whole")
        }
    }

    @Test func healthDataAgesDatesAndPlacesStay() {
        for s in ["我有高血压，在吃氨氯地平和二甲双胍，布洛芬能吃吗", "无锡马拉松还有多久，配速6:24能跑进4小时半吗",
                  "我 67 岁，10月21日空腹血糖 7.8，eGFR 45，血钾5.6", "我在上海，明天天气适合跑步吗", "去医院看看还是在家观察，社区医院行吗",
                  "我们小区门口的诊所能量血压吗", "高血压医生怎么看", "周三医生出诊吗", "以对方医生的意见为准", "向医生咨询", "把病史告诉医生",
                  "血压偏高医生怎么说", "小安，今天能跑间歇吗", "我是糖尿病人，能吃水果吗",
                  "我是高血压患者", "我爸老是失眠", "我妈血压高", "我女儿最近老咳嗽"] {
            let (out, m) = masked(s)
            #expect(out == s && m.isEmpty, "\(s) has nothing that names a person")
        }
    }

    @Test func theAnswerGetsTheOriginalsBack() {
        var m = IdentityMask(knownNames: [])
        let shown = m.mask("仁济医院的李明医生")
        #expect(shown == "[医院1]的[医生1]", "\(shown)")
        #expect(m.restore("可以问问【医生1】，或去［医院1］复查") == "可以问问李明医生，或去仁济医院复查", "other brackets count")
        #expect(m.restore("去[医院1]复查，[姓名3]也行") == "去仁济医院复查，也行", "a code never given out is dropped")
        #expect(m.restore("去[医院1]复查，再问[医", streaming: true) == "去仁济医院复查，再问", "a half-written code waits")
        #expect(m.summary == "医生、医院")
    }

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
        var c = AgentContext.make(profile: a.profile, name: p.displayName, days: a.days, plan: items.map(\.snapshot), workouts: [],
                                  vitals: vitals.map(\.point).filter { $0.time > evening.adding(days: -60) }, events: [],
                                  stopBang: [], baselineSetAt: nil, raceName: p.raceName, labs: labs, now: evening)
        c.answerMode = .hybrid
        c.healthDataConsented = true
        return (c, container)
    }

    /// Every question, said with a name, phone, hospital, doctor and address, goes out without them —
    /// in 端云结合 and in 全部云端 — while the health facts in it still go.
    @Test func nothingThatNamesThePersonLeaves() throws {
        let questions = ["今天早上血压155/95，要紧吗", "我能吃香蕉吗", "最近脚有点肿", "我的肾功能怎么样", "帮我把周三的散步改到周四",
                         "今天适合散步吗", "我最近整体怎么样", "昨晚没睡好，今天还能训练吗", "我的血压控制得怎么样", "糖尿病人能吃水果吗"]
        let identifiers = ["13812345678", "仁济医院", "李明", "文三路90号", "wang.jg@example.com"]
        let convo = AgentConversation()
        for persona in [DemoPersona.wangjianguo, .xiaolin, .chenjie] {
            let (c, container) = try load(persona)
            _ = container
            for q in questions {
                let said = "我是\(c.name)，电话13812345678，在仁济医院找李明医生看过，住在文三路90号，邮箱 wang.jg@example.com。\(q)"
                let rule = HealthAgent.reply(to: said, context: c)
                let context = HealthAgent.context(c, answering: rule)
                for request in [convo.hybridRequest(said, rule: rule, history: ["用户：我是\(c.name)", "助手：好的"], context: context),
                                convo.cloudRequest(said, rule: rule, history: [], context: context)] {
                    let out = convo.outgoing(request, context: context)
                    for x in identifiers + (c.name == "你" ? [] : [c.name]) {
                        #expect(!out.prompt.contains(x), "\(persona.name): 「\(x)」 left the phone in 「\(q)」")
                    }
                    #expect(out.prompt.contains(q), "\(persona.name): the question itself still goes: \(q)")
                    #expect(out.system.contains(IdentityMask.instruction))
                }
            }
        }
    }

    /// Pulse's own words — the digest, the rules' answer, the prompt's notes — never look like a
    /// person or a hospital: questions with nothing personal in them go out with nothing masked.
    @Test func pulsesOwnWordsAreNotTakenForPeople() throws {
        let questions = ["一天喝多少水？", "下午犯困可以喝咖啡吗", "为什么静息心率最近没怎么降？", "二甲双胍可以停吗", "今天早上血压155，要紧吗",
                         "今天能跑步吗", "今天蛋白质吃够了吗", "今天钾吃多了吗", "可以吃火锅吗", "头疼能吃布洛芬吗", "少吃盐有什么技巧？",
                         "尿酸高能吃海鲜吗", "我今天有点累，还要去跑步吗", "我妈有高血压该注意什么", "我感冒了还能运动吗", "我是不是有低血钾？",
                         "我的HRV最近怎么样？", "我的优先事项是什么", "我的体重有变化吗", "我的复查安排是什么", "我的肾功能怎么样？",
                         "我能把降压药减半吗", "我这周吃得咸吗", "接下来我该关注什么", "明天能跑间歇吗", "晚饭后血糖 12 正常吗？",
                         "最近体重涨了两斤要紧吗？", "熬夜后怎么恢复？", "睡不着怎么办？", "空腹血糖 6.8 高吗", "糖尿病人能吃水果吗？",
                         "肌酐 1.44 mg/dL 正常吗", "血压150/95能去散步吗", "血钾高不能吃什么", "这个月进步了吗", "这周的计划是什么",
                         "透析后很累正常吗", "间歇训练是什么", "降压药是早上吃还是晚上吃？", "饮酒对我的影响有多大？", "高压162低压98要去医院吗",
                         "我朋友最近老咳嗽怎么办", "我需要去看医生吗？", "这周训练量减一点", "帮我记一下血压 138/88", "下周三提醒我去医院复查",
                         "我最近整体怎么样", "脚有点肿", "我心情不好", "晚上睡不好怎么办"]
        let convo = AgentConversation()
        for persona in [DemoPersona.wangjianguo, .xiaolin, .chenjie, .linyue] {
            let (c, container) = try load(persona)
            _ = container
            for q in questions {
                let rule = HealthAgent.reply(to: q, context: c)
                let context = HealthAgent.context(c, answering: rule)
                for request in [convo.hybridRequest(q, rule: rule, history: [], context: context), convo.cloudRequest(q, rule: rule, history: [], context: context),
                                (HealthAgent.generalCloudInstructions, HealthAgent.generalPrompt(question: q, history: []))] {
                    let out = convo.outgoing(request, context: context)
                    let wrong = out.mask.entries.filter { $0.original != c.name }
                    #expect(wrong.isEmpty, "\(persona.name) 「\(q)」: \(wrong.map { "\($0.original)→\($0.code)" })")
                }
            }
        }
    }

    @Test func hybridSendsTheAnalysisButNotTheCardCatalog() throws {
        let (c, container) = try load(.wangjianguo)
        _ = container
        let q = "今天早上血压155/95，要紧吗"
        let rule = HealthAgent.reply(to: q, context: c)
        let (system, prompt) = AgentConversation().hybridRequest(q, rule: rule, history: [], context: HealthAgent.context(c, answering: rule))
        #expect(prompt.contains("【要点】") && prompt.contains("155/95"))
        #expect(!system.contains(AgentUI.catalogInstructions), "cards and plan changes are decided on the phone")
    }
}
