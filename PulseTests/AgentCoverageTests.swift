import Foundation
import SwiftData
import Testing
@testable import Pulse

private let evening = Calendar.pulse.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 20))!

/// Everyday questions that once went unanswered or got the wrong topic: each must now be answered
/// about what it asks.
@Suite("Health Agent coverage")
@MainActor
struct AgentCoverageTests {
    private struct Fixture {
        let container: ModelContainer
        let base: ProfileSnapshot
        let make: (ProfileSnapshot) -> AgentContext
    }

    private func fixture(now evening: Date = evening) throws -> Fixture {
        let container = try ModelContainer(for: Schema(PulseSchema.models), configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        let ctx = container.mainContext
        DemoDataGenerator.populate(ctx, persona: .wangjianguo, now: evening)
        DataHub.ensureWeekPlan(in: ctx, now: evening)
        let a = DataHub.analytics(in: ctx, now: evening)
        let items = ((try? ctx.fetch(FetchDescriptor<PlanItem>())) ?? []).map(\.snapshot)
        let vitals = ((try? ctx.fetch(FetchDescriptor<VitalReading>())) ?? []).map(\.point).filter { $0.time > evening.adding(days: -60) }
        let labs = ((try? ctx.fetch(FetchDescriptor<LabResult>())) ?? []).map(\.point)
        return Fixture(container: container, base: a.profile) { p in
            AgentContext.make(profile: p, name: "王建国", days: a.days, plan: items, workouts: [], vitals: vitals, events: [], stopBang: [],
                              baselineSetAt: nil, raceName: "", labs: labs, now: evening)
        }
    }

    private func hemo(_ p: ProfileSnapshot) -> ProfileSnapshot {
        var x = p
        x.onDialysis = true; x.dialysisMode = .hemo; x.dialysisWeekdays = [2, 4, 6]; x.dryWeightKg = 70; x.fluidLimited = true
        return x
    }

    private func peritoneal(_ p: ProfileSnapshot) -> ProfileSnapshot {
        var x = p
        x.onDialysis = true; x.dialysisMode = .peritoneal; x.fluidLimited = true
        return x
    }

    @Test func safetyComesFirst() throws {
        let f = try fixture()
        let c = f.make(f.base)
        for q in ["胸口闷", "胸口有点闷", "心口疼得厉害"] {
            let r = HealthAgent.reply(to: q, context: c)
            #expect(r.intent == .emergency && r.text.contains("120"), "\(q)")
        }
        // Peritonitis and a blocked fistula: urgent, as written, before anything else.
        let pd = f.make(peritoneal(f.base))
        let cloudy = HealthAgent.reply(to: "腹透液浑浊怎么办", context: pd)
        #expect(cloudy.verbatim && cloudy.text.hasPrefix("透出液浑浊、肚子疼或发烧，可能是腹膜炎") && cloudy.text.contains("透出液带上"))
        #expect(HealthAgent.reply(to: "导管出口有点红", context: pd).text.hasPrefix("导管出口红肿"))
        let hd = f.make(hemo(f.base))
        #expect(HealthAgent.reply(to: "内瘘摸不到震颤了", context: hd).text.contains("立即联系透析中心"))
        // A dialysis day (Wednesday): no running, whatever the hour; a slow walk is fine.
        let run = HealthAgent.reply(to: "透析日能跑步吗", context: hd)
        #expect(run.text.contains("不建议") && run.text.contains("透析日") && !run.text.contains("可以去跑步"), "\(run.text)")
        #expect(HealthAgent.reply(to: "今天能运动吗", context: hd).text.contains("透析日"))
        #expect(!HealthAgent.reply(to: "透析后能散步吗", context: hd).text.contains("不建议"))
    }

    @Test func questionsGetTheirOwnTopic() throws {
        let f = try fixture()
        let c = f.make(f.base)
        func says(_ q: String, _ c: AgentContext, _ check: (AgentReply) -> Bool) {
            let r = HealthAgent.reply(to: q, context: c)
            #expect(check(r), "\(q) → \(r.text.prefix(80))")
        }
        // A weight is not a weight change.
        says("记一下体重 72.5 公斤", c) { $0.text.hasPrefix("体重 72.5 kg") && !$0.text.contains("涨了 72.5") && $0.blocks.contains { $0.record?.items == [.weight(kg: 72.5)] } }
        // Lab values as typed, in the report's unit.
        says("糖化血红蛋白 53 mmol/mol 是多少", c) { $0.text.hasPrefix("糖化血红蛋白 53 mmol/mol，约等于 7.0%") && !$0.text.contains("高于") }
        says("肌酐 1.44 mg/dL 正常吗", c) { $0.text.hasPrefix("血肌酐 1.44 mg/dL，约等于 127 μmol/L") }
        says("尿白蛋白肌酐比 5 mg/mmol 高吗", c) { $0.text.hasPrefix("尿白蛋白/肌酐比 5 mg/mmol，约等于 44 mg/g：A2") }
        says("糖化血红蛋白 53 是多少", c) { $0.text.contains("按数值看应该是 mmol/mol") }
        says("我的糖化血红蛋白怎么样", c) { $0.text.hasPrefix("糖化血红蛋白") }
        // Foods for a nutrient, not a meal plan.
        says("血钾高不能吃什么", c) { $0.text.hasPrefix("血钾高时") && $0.text.contains("香蕉") && $0.text.contains("焯") }
        says("血磷高要注意吃什么", c) { $0.text.hasPrefix("血磷高时") }
        // Dialysis.
        let hd = f.make(hemo(f.base))
        says("两次透析之间体重涨多少合适", hd) { $0.text.hasPrefix("你的干体重是 70.0 kg") && $0.text.contains("72.8 kg") }
        says("我的干体重是多少", hd) { $0.text.hasPrefix("你的干体重是 70.0 kg") }
        says("透析后很累正常吗", hd) { $0.text.hasPrefix("透析后觉得累很常见") }
        // Reminders on dialysis days, as set in 我的; every day for peritoneal dialysis.
        says("每次透析后提醒我称体重", hd) { $0.text.hasPrefix("可以帮你加一条重复提醒：「每次透析后称体重」，每周一、三、五上午 9 点") && $0.text.contains("透析一般几点结束") }
        says("每次透析后提醒我记录透出液", f.make(peritoneal(f.base))) { $0.blocks.first?.record?.repeats == .daily }
        var noDays = hemo(f.base)
        noDays.dialysisWeekdays = []
        says("每次透析后提醒我称体重", f.make(noDays)) { $0.text.contains("还不知道你哪几天透析") && $0.blocks.first?.record?.repeats == nil }
        says("我的干体重是多少", c) { $0.text.hasPrefix("你还没有记录在做透析") }
        // Weight, plan, settings.
        says("我的体重有变化吗", c) { $0.text.hasPrefix("最近一次体重") || $0.text.hasPrefix("还没有体重记录") }
        says("今天的训练是什么", c) { $0.text.hasPrefix("今天安排的是") || $0.text.hasPrefix("今天是") }
        says("这周的计划是什么", c) { $0.text.hasPrefix("这周的安排") }
        says("下周计划是什么", c) { $0.text.hasPrefix("下周") }
        says("间歇训练是什么", c) { $0.text.hasPrefix("间歇训练是快慢交替") }
        says("提醒我明天早上量血压", c) { $0.text.hasPrefix("可以帮你加一条提醒：「量血压」") && $0.blocks.contains { $0.record?.reminder != nil } }
        says("下周三提醒我去医院复查", c) { $0.text.hasPrefix("可以帮你加一条提醒：「去医院复查」") }
        says("怎么改血压目标", c) { $0.text.contains("血压目标") && $0.intent == .about }
        says("怎么打开提醒", c) { $0.text.hasPrefix("在「我的 › 提醒」里") }
        says("早上起来眼皮肿", c) { $0.text.hasPrefix("眼皮肿") }
        says("这周总结一下", c) { r in
            let first = r.text.components(separatedBy: "。").first ?? ""
            return r.intent == .overall && r.text.contains("本周复盘") && r.text.components(separatedBy: first).count == 2
        }
        says("今天蛋白质吃够了吗", c) { $0.text.contains("比医生定的少约") || $0.text.contains("差不多够了") || $0.text.contains("多了") }
        says("帮我记一下血压 138/88", c) { $0.text.hasPrefix("138/88") && $0.blocks.contains { $0.record?.items == [.bloodPressure(sys: 138, dia: 88, context: .random)] } }
        // Found in a round with the cloud model: each answers what was asked, first.
        says("晚上睡不好怎么办", c) { $0.intent == .sleep }
        says("这周训练量减一点", c) { $0.intent == .planChange && $0.blocks.contains { $0.proposal != nil } }
        says("晚上睡不好怎么办", c) { $0.text.contains("晚打鼾") }
        says("头疼能吃布洛芬吗", c) { $0.text.hasPrefix("先别自己吃布洛芬") && $0.text.contains("先量一下血压") && $0.safety?.contains("120") == true }
        says("膝盖疼能吃布洛芬吗", c) { $0.text.hasPrefix("先别自己吃布洛芬") && $0.text.contains("膝盖疼先别") }
        says("肾病为什么要少吃盐", c) { $0.text.hasPrefix("盐吃多了，身体会存水") && $0.text.contains("肾") }
        says("少吃盐有什么技巧", c) { $0.text.hasPrefix("控盐最有效") }
        says("肌酐 1.44 mg/dL 帮我记一下", c) { !$0.text.contains("某种病") }
        let water = HealthAgent.reply(to: "我刚喝了一杯水", context: c)
        #expect(AgentFollowUps.suggest(after: water, question: "我刚喝了一杯水", context: c, asked: []) == ["一天喝多少水？"])
        // Questions that are not about settings stay where they were.
        says("怎么改善睡眠", c) { $0.intent == .sleep }
        says("今天能运动吗", c) { $0.intent == .trainingCheck }
    }

    @Test func thisWeekOverMeansNextWeek() throws {
        // Saturday 2026-10-24: this week's sessions are behind; the change is for next week, and says so.
        let saturday = Calendar.pulse.date(from: DateComponents(year: 2026, month: 10, day: 24, hour: 9))!
        let f = try fixture(now: saturday)
        let r = HealthAgent.reply(to: "这周训练量减一点", context: f.make(f.base))
        #expect(r.text.hasPrefix("这周剩下的日子已经没有训练了，下周计划可以这样调整") && r.blocks.contains { $0.proposal?.scope == .nextWeek }, "\(r.text.prefix(80))")
        // The cloud model is told so, and which days hold no training to shorten.
        let c = f.make(f.base)
        let prompt = PlanChat.cloudPrompt(question: "这周训练量减一点", history: [], context: c, rulesHint: PlanChat.rulesHint("这周训练量减一点", context: c))
        #expect(prompt.contains("（本周可调整的日子里已经没有训练了）") && !prompt.contains("（下周可调整的日子里已经没有训练了）"))
        #expect(prompt.contains("（不是训练）"))
        // A change the model makes to this week leads with this week, whatever the rules chose.
        if var p = r.blocks.compactMap(\.proposal).first {
            p.scope = .thisWeek
            #expect(PlanChat.lead(for: p).hasPrefix("按你说的，本周计划"))
        }
    }

    @Test func everydayQuestionsAreAnswered() throws {
        let f = try fixture()
        let c = f.make(f.base)
        let hd = f.make(hemo(f.base))
        let unknown = "这个问题 Pulse 现在还答不好"
        let asked: [(String, AgentContext, String)] = [
            ("我刚喝了一杯水", c, "好的，这杯是 250 ml"),
            ("我的复查安排是什么", c, "按你现在的情况"),
            ("今天蛋白质吃够了吗", c, "今天"),
            ("我这周吃得咸吗", c, "这周"),
            ("今天钾吃多了吗", c, "今天"),
            ("我该吃多少蛋白质", c, "医生给你定的蛋白质是每天约 55 g"),
            ("一天喝多少水", c, "一般每天喝"),
            ("一天喝多少水", hd, "医生让你限水"),
            ("这个月哪天最好", c, "这个月最好的是"),
            ("和上个月比怎么样", c, ""),
            ("我的每日回顾怎么看", c, "每日回顾按你最在意的几件事"),
            ("为什么今天让我休息", c, "今天"),
            ("我的优先事项是什么", c, "你现在最在意的三件事"),
            ("帮我生成就诊摘要", c, "在「我的 › 隐私与数据导出」点「生成就诊摘要」"),
            ("怎么导出数据", c, "在「我的 › 隐私与数据导出」里可以导出"),
            ("怎么连接手表", c, "在「我的 › 数据来源」"),
            ("怎么设置透析日", hd, "在「我的 › 健康状况与用药 › 透析」"),
            ("每天走多少步合适", c, "每天 7000–10000 步"),
            ("我心情不好", c, "听起来你最近不太好受"),
            ("谢谢", c, "不客气"),
            ("皮肤痒", c, "皮肤痒在肾病里很常见"),
            ("没胃口", c, "吃得少的时候要先留意血糖"),
            ("晚上起夜好几次", c, "晚上起夜两次以上"),
        ]
        for (q, ctx, start) in asked {
            let r = HealthAgent.reply(to: q, context: ctx)
            #expect(!r.text.hasPrefix(unknown) && r.text.hasPrefix(start), "\(q) → \(r.text.prefix(80))")
        }
        // A safety line the model put in its own words is not added a second time; one it left out is.
        let swelling = "有气短、躺下喘不过气、3 天体重涨 2 公斤以上，或者只有一条腿肿、发红发热又疼，尽快就医。"
        #expect(HealthAgent.says("• 出现气短、躺下喘不过气、3 天体重涨 2 公斤以上，或只有一条腿肿、发红发热又疼，尽快就医", safety: swelling))
        #expect(!HealthAgent.says("• 坐着时把腿抬高，少吃盐\n• 体重涨得快要留意", safety: swelling))
        #expect(!HealthAgent.says("躺下喘不过气、3 天体重涨 2 公斤以上要留意", safety: swelling), "what to do is part of it")
        // Low mood keeps the helpline whatever a model writes.
        #expect(HealthAgent.reply(to: "我心情不好", context: c).safety?.contains("12356") == true)
    }

    /// Questions Apple Intelligence once answered with nothing from the rules to keep.
    @Test func kidneyFunctionAndMealIdeas() throws {
        let f = try fixture()
        let c = f.make(f.base)
        for q in ["我有点担心肾功能会变差", "我的肾功能怎么样"] {
            let r = HealthAgent.reply(to: q, context: c)
            #expect(r.conclusion?.hasPrefix("肾功能主要看 eGFR：最近一次是 57") == true && r.conclusion?.contains("平均每年下降约") == true, "\(q)")
            #expect(r.text.components(separatedBy: "平均每年下降约").count == 2, "\(q): the trend said once")
        }
        for q in ["今天吃啥好", "今天吃了什么比较好"] {
            #expect(HealthAgent.reply(to: q, context: c).intent == .diet, "\(q)")
        }
        // A model's list: apart from the sentence before it, no 「；」 left at the end.
        let run = HealthAgent.reply(to: "今天能跑步吗", context: c)
        let t = HealthAgent.finalize((run.conclusion ?? "") + "\n• 充分热身，跑的时候以能完整说话为准；", of: run, strict: false)
        #expect(t.contains("\n\n• 充分热身") && t.hasSuffix("为准"))
        // Bullets that only repeat the verdict go.
        let kidney = HealthAgent.reply(to: "我有点担心肾功能会变差", context: c)
        #expect(kidney.text.contains("能让它降得慢一点的：\n• 血压、血糖控制在目标内"))
        let repeated = HealthAgent.finalize((kidney.conclusion ?? "") + "\n\n• 近 17 个月平均每年下降约 4\n• 少吃盐，别自己吃布洛芬这类止痛药", of: kidney)
        #expect(!repeated.contains("• 近 17 个月") && repeated.contains("• 少吃盐"))
        // The model's 「要记下的话…」 in the middle moves down to sit above the card.
        let bp = HealthAgent.reply(to: "帮我记一下血压 138/88", context: c)
        let moved = HealthAgent.finalize((bp.conclusion ?? "") + "\n\n要记下的话，点下面的「记下」：血压 138/88 mmHg。\n\n• 静坐 5 分钟再测两次", of: bp, strict: false)
        #expect(moved.hasSuffix("要记下的话，点下面的「记下」：血压 138/88 mmHg。") && moved.components(separatedBy: "「记下」").count == 2)
    }
}
