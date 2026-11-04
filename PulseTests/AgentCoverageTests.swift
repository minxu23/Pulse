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

    /// On the device, symptoms and plan changes keep the rules' wording; other answers are the model's.
    @Test func onDeviceKeepsSymptomWording() throws {
        let f = try fixture()
        let c = f.make(f.base)
        for q in ["最近总觉得累", "我最近老是头晕", "这周训练量减一点"] {
            #expect(HealthAgent.reply(to: q, context: c).readsAsWrittenOnDevice, "\(q)")
        }
        for q in ["我最近血压怎么样", "有点累，还要去跑步吗", "晚上睡不好怎么办"] {
            #expect(!HealthAgent.reply(to: q, context: c).readsAsWrittenOnDevice, "\(q)")
        }
        #expect(HealthAgent.reply(to: "最近总觉得累", context: c).text.contains("从你的记录看，可能有关的（不一定是原因）"))
    }

    /// Found in the cloud round of 2026-10-31 15:49.
    @Test func modelLeadInsAndRewordedSafety() throws {
        let f = try fixture()
        let c = f.make(f.base)
        // The safety line in the model's words (the examples in brackets left out) is not added again.
        let tired = HealthAgent.reply(to: "最近总觉得累", context: c)
        let s = try #require(tired.safety)
        #expect(HealthAgent.says("如果累了两周以上不见好，或者出现体重下降、发烧、气短、心慌，要尽快去看医生。", safety: s))
        #expect(!HealthAgent.says("累了两周以上不见好，或者出现体重下降、发烧、气短、心慌，要留意。", safety: s))
        // The question echoed before the verdict goes.
        let bp = HealthAgent.reply(to: "我最近血压怎么样", context: c)
        let k = try #require(bp.conclusion)
        let t = HealthAgent.finalize("我最近血压" + k + "\n\n• 每天固定时间吃药，别漏", of: bp)
        #expect(t.hasPrefix(k))
    }

    // MARK: What one thing does to another

    @Test func aQuestionAboutAnEffectIsAnsweredAboutTheTwoThingsItNames() throws {
        let f = try fixture()
        let c = f.make(f.base)
        let cases: [(String, String)] = [
            ("喝酒对血压有影响吗", "酒会让血压升高"), ("喝酒会影响血糖吗", "酒会让血糖"), ("喝酒影响睡眠吗", "后半夜"), ("喝酒伤肾吗", "肾的负担"),
            ("咖啡对血压有影响吗", "咖啡因会让血压"), ("喝咖啡会升血糖吗", "黑咖啡"), ("喝茶对血压好吗", "淡茶"),
            ("运动对血压有帮助吗", "有帮助"), ("运动能降血糖吗", "肌肉直接用糖"), ("跑步对肾有影响吗", "对肾有好处"), ("运动对睡眠有帮助吗", "更快入睡"),
            ("睡眠不好会影响血压吗", "血压容易偏高"), ("睡得少血糖会高吗", "胰岛素"), ("熬夜对血压有影响吗", "血压容易偏高"), ("熬夜影响血糖吗", "胰岛素"),
            ("压力大会影响血压吗", "压力大时血压"), ("压力大血糖会高吗", "压力激素"), ("吃盐多对血压有什么影响", "盐吃多了"), ("吃盐多对肾有影响吗", "排盐"),
            ("减肥对血压有帮助吗", "减几公斤"), ("抽烟对血压有影响吗", "每抽一支烟"), ("血压高会影响肾吗", "小血管"), ("血糖高会影响肾吗", "肾小球"),
            ("吃辣对血压有影响吗", "辣本身"), ("饭后散步对血糖有用吗", "10–15 分钟"), ("天气冷对血压有影响吗", "血管收缩"),
            ("我血压高，喝酒有影响吗", "酒会让血压升高"), ("睡眠和血压有关系吗", "血压容易偏高"),
        ]
        for (q, says) in cases {
            let r = HealthAgent.reply(to: q, context: c)
            #expect(r.conclusion?.contains(says) == true, "\(q): \(r.conclusion ?? r.text)")
            #expect(!r.text.contains("还没达标"), "\(q) got the topic report")
            #expect(r.text.hasPrefix(r.conclusion ?? "-"), "\(q)")
        }
    }

    @Test func anEffectAnswerFitsHowItWasAsked() throws {
        let f = try fixture()
        let c = f.make(f.base)
        #expect(HealthAgent.reply(to: "少吃盐对血压有好处吗", context: c).conclusion?.hasPrefix("有帮助。") == true)
        #expect(HealthAgent.reply(to: "戒烟对血压有帮助吗", context: c).conclusion?.hasPrefix("有帮助。") == true)
        #expect(HealthAgent.reply(to: "为什么喝酒后血压会高", context: c).conclusion?.hasPrefix("酒会让血压升高") == true)
        // Two outcomes: both are answered, and 「会。」 is said once.
        let both = HealthAgent.reply(to: "喝酒对血压和睡眠有影响吗", context: c)
        #expect(both.text.contains("酒会让血压升高") && both.text.contains("后半夜") && both.text.components(separatedBy: "会。").count == 2)
        // Medicines stay the doctor's call, and a drink on its own keeps its answer.
        #expect(HealthAgent.reply(to: "运动后吃降压药有影响吗", context: c).intent == .meds)
        #expect(!HealthAgent.reply(to: "能喝酒吗", context: c).text.contains("酒会让血压升高，喝得越多"))
    }

    @Test func drinkingMoreWaterIsNeverAdvisedOnAFluidLimit() throws {
        let f = try fixture()
        var limited = f.base
        limited.fluidLimited = true
        limited.waterTargetMl = 1200
        let r = HealthAgent.reply(to: "多喝水对肾好吗", context: f.make(limited))
        #expect(r.conclusion?.contains("你在限水") == true && r.text.contains("不超过 1200 ml"))
        #expect(!r.text.contains("1500–2000"))
        var free = f.base
        free.fluidLimited = false
        #expect(HealthAgent.reply(to: "多喝水对肾好吗", context: f.make(free)).text.contains("1500–2000"))
    }

    @Test func theirOwnDaysAreComparedOnlyWhenTheyShowIt() throws {
        let f = try fixture()
        let day0 = evening.startOfDay
        func context(_ gap: Double) -> AgentContext {
            var c = f.make(f.base)
            let days = (1...20).map { i -> DayData in
                var d = DayData(day: day0.adding(days: -i))
                d.alcoholUnits = i.isMultiple(of: 2) ? 2 : 0
                return d
            }
            c.days = days
            c.vitals = (0..<19).map { i in
                let drank = i.isMultiple(of: 2)   // the morning after an even day
                let morning = day0.adding(days: -(i + 1)).addingTimeInterval(8 * 3600)
                return VitalPoint(time: morning, kind: .bloodPressure, value: drank ? 130 + gap : 130, value2: 80, context: .morning)
            }
            return c
        }
        let shown = try #require(HealthAgent.ownDays(.alcohol, .bp, context: context(8)))
        #expect(shown.contains("观察到的关联") && shown.contains("喝过酒的第二天早上收缩压"))
        let none = try #require(HealthAgent.ownDays(.alcohol, .bp, context: context(0)))
        #expect(none.hasPrefix("从你的记录还看不出这个影响"))
        let opposite = try #require(HealthAgent.ownDays(.alcohol, .bp, context: context(-8)))
        #expect(opposite.hasPrefix("从你的记录还看不出这个影响"))
        // Too few mornings to compare: nothing is said.
        var few = context(8)
        few.vitals = Array(few.vitals.prefix(4))
        #expect(HealthAgent.ownDays(.alcohol, .bp, context: few) == nil)
    }

    @Test func aWeekSummaryOnTheDeviceKeepsTheWeeksOwnNumbers() throws {
        let f = try fixture()
        let c = f.make(f.base)
        #expect(HealthAgent.reply(to: "这周总结一下", context: c).readsAsWrittenOnDevice)
        #expect(!HealthAgent.reply(to: "我最近整体怎么样？", context: c).readsAsWrittenOnDevice)
    }

    // MARK: A race other than the one set

    @Test func aRaceTheQuestionNamesIsNotTakenForTheOneSet() throws {
        let f = try fixture()
        var c = f.make(f.base)
        c.workouts = (0..<16).map { i in
            let start = evening.adding(days: -(i * 3 + 1))
            return WorkoutPoint(start: start, type: .run, minutes: 60, distanceKm: i == 0 ? 10 : 8)
        }
        c.race = MarathonWeek(phase: .base, weeksToRace: 19, weeklyKm: 24, longRunKm: 13, easyPace: 7.5, marathonPace: 6.4, thresholdPace: 6,
                              sessions: [], notes: [], warnings: [])
        c.raceName = ""
        let half = HealthAgent.reply(to: "下个月想跑半马，怎么准备", context: c)
        #expect(half.intent == .marathon && half.conclusion?.hasPrefix("下个月跑半马") == true)
        #expect(half.text.contains("19 周后的全程马拉松") && !half.text.contains("当前处于"))
        #expect(HealthAgent.reply(to: "下周有个半马能跑吗", context: c).conclusion?.contains("来不及") == true)
        #expect(HealthAgent.reply(to: "我想跑10公里比赛", context: c).conclusion?.hasPrefix("10 公里") == true)
        #expect(HealthAgent.reply(to: "下个月想跑全马，来得及吗", context: c).conclusion?.contains("来不及") == true)
        #expect(HealthAgent.reply(to: "半马怎么练", context: c).text.contains("16–18 km"))
        // The race that is set keeps its own answer.
        #expect(HealthAgent.reply(to: "我适合跑马拉松吗", context: c).text.contains("当前处于"))
        // A run of 10 km is not a race, and fuelling keeps its answer.
        #expect(AskedRace.find(in: "今天跑10公里行吗") == nil)
        #expect(HealthAgent.reply(to: "半马怎么补给", context: c).text.contains("能量胶"))
    }

    @Test func whenARaceIsReadsFromTheQuestion() {
        #expect(AskedRace.find(in: "下周有个半马")?.weeks == 1)
        #expect(AskedRace.find(in: "下下周的半马")?.weeks == 2)
        #expect(AskedRace.find(in: "下个月想跑全马")?.weeks == 6)
        #expect(AskedRace.find(in: "三个月后想跑全马")?.weeks == 12)
        #expect(AskedRace.find(in: "10周后跑半马")?.weeks == 10)
        #expect(AskedRace.find(in: "明年想跑马拉松")?.weeks == nil)
        #expect(AskedRace.find(in: "半程马拉松")?.distance == .half)
        #expect(AskedRace.find(in: "马拉松")?.distance == .full)
    }

    // MARK: Weekly running

    private func runner(_ c: AgentContext, thisWeek: Double, weeksBefore: Double) -> AgentContext {
        var c = c
        c.workouts = [WorkoutPoint(start: c.weekStart.addingTimeInterval(3600), type: .run, minutes: 60, distanceKm: thisWeek)]
            + (1...4).map { WorkoutPoint(start: c.weekStart.adding(days: -7 * $0).addingTimeInterval(3600), type: .run, minutes: 60, distanceKm: weeksBefore) }
        return c
    }

    @Test func weeklyRunningIsAnsweredWithAVerdict() throws {
        let f = try fixture()
        var base = f.base
        base.extraConditions = []
        base.conditions = []
        base.clinicianCleared = true
        var c = runner(f.make(base), thisWeek: 20, weeksBefore: 20)
        c.race = MarathonWeek(phase: .base, weeksToRace: 19, weeklyKm: 24, longRunKm: 13, easyPace: 7.5, marathonPace: 6.4, thresholdPace: 6,
                              sessions: [], notes: [], warnings: [])
        c.plan = []
        let short = HealthAgent.reply(to: "这周跑量够吗", context: c)
        #expect(short.readsAsWrittenOnDevice, "the week, the week before and the target must not be mixed up")
        // The target is called that: 「本周跑量 24 km」 read as distance already run.
        #expect(HealthAgent.digest(c).contains("本周目标跑量 24 km") && !HealthAgent.digest(c).contains("，本周跑量"))
        #expect(short.conclusion?.hasPrefix("差一些：这周跑了 20.0 km，目标约 24.0 km") == true && short.text.contains("不用硬补"), "\(short.text)")
        #expect(HealthAgent.reply(to: "这周跑量够吗", context: runner(c, thisWeek: 24, weeksBefore: 20)).conclusion?.hasPrefix("够了") == true)
        // Its own average when no race is set, and no invented target.
        var free = runner(c, thisWeek: 20, weeksBefore: 20)
        free.race = nil
        #expect(HealthAgent.reply(to: "我的跑量太少吗", context: free).conclusion?.hasPrefix("和平时差不多") == true)
        #expect(HealthAgent.reply(to: "这周跑量够吗", context: runner(free, thisWeek: 10, weeksBefore: 20)).conclusion?.hasPrefix("比平时少一些") == true)
        #expect(HealthAgent.reply(to: "这周跑了多少", context: free).conclusion == "这周跑了 20.0 km，前一周 20.0 km。")
        #expect(HealthAgent.reply(to: "这周跑量够吗", context: runner(free, thisWeek: 26, weeksBefore: 20)).conclusion?.hasPrefix("比平时还多一些") == true)
        #expect(HealthAgent.reply(to: "这周跑量够吗", context: runner(c, thisWeek: 0, weeksBefore: 20)).conclusion?.contains("这周还没跑") == true)
        // With a race the plan's target stands, not a cap of its own.
        #expect(HealthAgent.reply(to: "跑量要不要加", context: c).conclusion?.hasPrefix("按计划加就好") == true)
        // A question is not a plan change, and an order still is.
        let many = HealthAgent.reply(to: "这周跑量是不是太多了", context: runner(free, thisWeek: 30, weeksBefore: 20))
        #expect(many.conclusion?.hasPrefix("有点多") == true && many.proposals.isEmpty && many.intent != .planChange, "\(many.text)")
        #expect(HealthAgent.reply(to: "这周跑量减一点", context: c).intent == .planChange)
        let add = HealthAgent.reply(to: "跑量要不要加", context: free)
        #expect(add.conclusion?.contains("下周别超过 22.0 km") == true, "\(add.intent) \(add.text.prefix(90))")
        // Someone who doesn't run hears that, not a request to set a race.
        var none = free
        none.workouts = []
        let idle = HealthAgent.reply(to: "这周跑量够吗", context: none)
        #expect(idle.conclusion?.contains("谈不上跑量") == true && !idle.text.contains("赛事目标"))
        // Held back by a condition: no more distance before the doctor agrees.
        #expect(HealthAgent.reply(to: "跑量要不要加", context: runner(f.make(f.base), thisWeek: 20, weeksBefore: 20)).conclusion?.hasPrefix("先别加") == true)
        #expect(HealthAgent.reply(to: "这周练得够吗", context: free).intent != .unknown)
    }

    // MARK: Exercise around shifts

    @Test func exerciseAroundShiftsIsAnsweredAboutTheShift() throws {
        let f = try fixture()
        let free = f.make(f.base)
        for q in ["夜班后什么时候运动最好", "下夜班能跑步吗", "上完夜班能运动吗", "夜班后几点运动好"] {
            let r = HealthAgent.reply(to: q, context: free)
            #expect(r.conclusion?.hasPrefix("夜班后先补觉") == true, "\(q): \(r.text.prefix(60))")
            #expect(r.text.contains("作息与倒班"), "no roster yet: \(q)")
        }
        #expect(HealthAgent.reply(to: "夜班前能运动吗", context: free).conclusion?.contains("出门前 3–4 小时") == true)
        #expect(HealthAgent.reply(to: "夜班当天要不要练", context: free).conclusion?.contains("出门前 3–4 小时") == true)
        #expect(HealthAgent.reply(to: "倒班怎么安排运动", context: free).conclusion?.hasPrefix("按班次来排") == true)
        #expect(!HealthAgent.reply(to: "白班什么时候运动", context: free).text.contains("恢复日"))
        #expect(HealthAgent.reply(to: "白班什么时候运动", context: free).conclusion?.contains("下班后") == true)
        #expect(HealthAgent.reply(to: "倒班的人适合什么运动", context: free).conclusion?.contains("快走") == true)
        // On a roster: the day's own shift, and the rest days to come. A yes or no about today stays with the training check.
        var worker = f.base
        worker.shift = ShiftSchedule(pattern: [.night, .off, .off], cycleStart: evening.startOfDay)
        let c = f.make(worker)
        let r = HealthAgent.reply(to: "倒班怎么安排运动", context: c)
        #expect(r.text.contains("接下来的休息日是") && !r.text.contains("作息与倒班"), "\(r.text)")
        #expect(HealthAgent.reply(to: "下夜班能跑步吗", context: c).intent == .trainingCheck)
    }

    // MARK: Why glucose runs high

    private func withGlucose(_ c: AgentContext, hour: Int, value: Double) -> AgentContext {
        var c = c
        let others = c.vitals.filter { $0.kind != .glucose }
        c.vitals = others + (0..<14).flatMap { d -> [VitalPoint] in
            (0..<24).map { h in
                VitalPoint(time: evening.startOfDay.adding(days: -d - 1).addingTimeInterval(Double(h) * 3600),
                           kind: .glucose, value: h == hour ? value : 6.0, value2: nil, context: .random)
            }
        }
        return c
    }

    @Test func whyGlucoseRunsHighChecksThatItDoes() throws {
        let f = try fixture()
        let c = f.make(f.base)
        // It does: this person's own morning numbers, then reasons kept as possibilities.
        let high = HealthAgent.reply(to: "为什么我的血糖早上高", context: withGlucose(c, hour: 6, value: 12))
        #expect(high.conclusion?.hasPrefix("你早上的血糖确实偏高") == true, "\(high.text.prefix(80))")
        #expect(high.text.contains("黎明现象") && high.text.contains("不一定都是你的情况") && high.status == .attention("确实偏高"))
        #expect(high.readsAsWrittenOnDevice, "on the device 「常见的原因」 would turn into causes")
        #expect(high.safety?.contains("连续两周") == true)
        // It doesn't: said so, with no advice about something that isn't there.
        let fine = HealthAgent.reply(to: "早上血糖为什么高", context: withGlucose(c, hour: 12, value: 12))
        #expect(fine.conclusion?.hasPrefix("从记录看，你早上的血糖并不高") == true, "\(fine.text.prefix(80))")
        #expect(fine.text.contains("偶尔偏高的话，常见的原因") && !fine.text.contains("连续两周") && fine.safety == nil && fine.status == .good("并不高"))
        // The meal and the part of the day it names.
        let meal = HealthAgent.reply(to: "为什么早饭后血糖高", context: withGlucose(c, hour: 9, value: 13))
        #expect(meal.conclusion?.hasPrefix("你早饭后的血糖确实偏高") == true && meal.text.contains("早饭后升得更高"), "\(meal.text.prefix(80))")
        #expect(HealthAgent.reply(to: "晚饭后血糖怎么这么高", context: withGlucose(c, hour: 20, value: 13)).conclusion?.contains("晚饭后的血糖") == true)
        // Swings, in the percent the metric is kept in.
        var swinging = withGlucose(c, hour: 6, value: 12)
        swinging.glucose.cv = 42
        #expect(HealthAgent.reply(to: "为什么血糖忽高忽低", context: swinging).conclusion == "你的血糖确实波动偏大：近 14 天波动系数 42%，一般希望在 36% 以内。")
        swinging.glucose.cv = 22
        #expect(HealthAgent.reply(to: "血糖波动大是什么原因", context: swinging).conclusion?.hasPrefix("从记录看，你的血糖波动不算大") == true)
        let night = HealthAgent.reply(to: "半夜血糖低怎么回事", context: withGlucose(c, hour: 2, value: 3.2))
        #expect(night.conclusion?.contains("低于") == true && night.text.contains("运动量比平时大") && !night.text.contains("黎明现象"), "\(night.text.prefix(80))")
        #expect(night.text.contains("告诉医生"))
        // Other forms keep their own answers, and a medicine stays the doctor's call.
        #expect(HealthAgent.reply(to: "血糖12为什么这么高", context: c).conclusion?.hasPrefix("12.0") == true)
        #expect(HealthAgent.reply(to: "打了胰岛素为什么血糖还高", context: c).intent == .meds)
        #expect(HealthAgent.reply(to: "血糖控制得怎么样", context: c).status != nil)
    }

    @Test func whyGlucoseRunsHighWithoutRecords() throws {
        let f = try fixture()
        var c = f.make(f.base)
        c.vitals = c.vitals.filter { $0.kind != .glucose }
        c.glucose = GlucoseMetrics(readings: 0, coverage: 0, isContinuous: false)
        let r = HealthAgent.reply(to: "空腹血糖为什么高", context: c)
        #expect(r.conclusion?.contains("看不出你是不是这样") == true && r.text.contains("黎明现象") && r.figure == nil, "\(r.text.prefix(80))")
    }

    // MARK: What a cloud model is told, and what it may not say

    @Test func theScheduleIsSpelledOutDayByDay() throws {
        let f = try fixture()
        var worker = f.base
        worker.shift = ShiftSchedule(pattern: [.off, .off, .day, .day], cycleStart: evening.startOfDay)
        let c = f.make(worker)
        #expect(HealthAgent.digest(c).contains("明天休息、后天白班、大后天白班"), "\(HealthAgent.digest(c))")
        // Wednesday, on Monday, Wednesday and Friday: Friday is next, not tomorrow.
        let hd = f.make(hemo(f.base))
        let line = try #require(Dialysis.digest([], profile: hemo(f.base), now: evening))
        #expect(line.contains("今天是透析日") && line.contains("下一次透析是后天（周五）"), "\(line)")
        #expect(HealthAgent.digest(hd).contains("下一次透析是后天（周五）"))
    }

    @Test func thePlanFormatStaysOutOfTheAnswer() {
        #expect(HealthAgent.inOurWords("今天缩到 25 分钟，强度降为 easy（有慢性肾病）") == "今天缩到 25 分钟，强度降为低强度（有慢性肾病）")
        #expect(HealthAgent.inOurWords("改成 moderate，再加一次 strength") == "改成中等强度，再加一次力量")
        #expect(HealthAgent.inOurWords("HRV 和 CGM 不变，easy-going 也不变") == "HRV 和 CGM 不变，easy-going 也不变")
        let plan = AgentReply(text: "可以", intent: .exercise)
        #expect(HealthAgent.finalize("强度降为 easy。", of: plan, strict: false) == "强度降为低强度。")
        #expect(HealthAgent.streamed("强度降为 easy", of: plan) == "强度降为低强度")
    }

    @Test func aCloudModelIsToldNotToWorkFactsOutItself() {
        #expect(HealthAgent.cloudInstructions.contains("不要自己推算事实"))
        #expect(PlanChat.cloudInstructions.contains("说明文字用中文"))
        #expect(PlanChat.cloudInstructions.contains("不要自己算本周合计时长"), "plan answers have instructions of their own")
    }

    // MARK: How much sleep

    private func sleeping(_ c: AgentContext, lastNight: Double, others: Double) -> AgentContext {
        var c = c
        let today = c.logicalToday
        c.days = (0..<14).map { i in
            var d = DayData(day: today.adding(days: -i))
            d.sleepMinutes = (i == 0 ? lastNight : others) * 60
            return d
        }
        return c
    }

    @Test func howMuchSleepIsAnsweredWithAVerdict() throws {
        let f = try fixture()
        var base = f.base
        base.sleepNeedMinutes = 420
        let c = f.make(base)
        // 「最近」 is the 14-night figure the sleep summary gives.
        var short = c
        short.sleep.avgMinutes = 330
        var plenty = c
        plenty.sleep.avgMinutes = 420
        for q in ["最近睡够了吗", "我睡够了吗", "最近睡饱了吗", "睡得够不够", "我是不是睡太少了"] {
            let r = HealthAgent.reply(to: q, context: short)
            #expect(r.intent == .sleep && r.conclusion == "还差一些：近 14 晚平均每晚 5.5 小时，目标 7.0 小时，每晚少了约 1.5 小时。", "\(q): \(r.text.prefix(70))")
            #expect(r.status == .attention("睡得不够") && r.readsAsWrittenOnDevice)
        }
        #expect(HealthAgent.reply(to: "最近睡够了吗", context: plenty).conclusion?.hasPrefix("睡够了：") == true)
        // Half an hour short is fine, but it isn't called enough: 6.6 of 7.
        var close = c
        close.sleep.avgMinutes = 395
        let nearly = HealthAgent.reply(to: "最近睡够了吗", context: close)
        #expect(nearly.status == .good("差一点") && nearly.conclusion?.hasPrefix("差一点：") == true, "\(nearly.text.prefix(60))")
        #expect(HealthAgent.reply(to: "昨晚睡够了吗", context: sleeping(c, lastNight: 6.7, others: 8)).conclusion?.hasPrefix("昨晚差一点") == true)
        #expect(HealthAgent.reply(to: "昨晚睡得怎么样", context: sleeping(c, lastNight: 7.5, others: 5)).conclusion == "昨晚睡了 7.5 小时，目标 7.0 小时。")
        // Last night, and the week.
        #expect(HealthAgent.reply(to: "昨晚睡够了吗", context: sleeping(c, lastNight: 5.5, others: 8)).conclusion == "昨晚没睡够：睡了 5.5 小时，目标 7.0 小时。")
        #expect(HealthAgent.reply(to: "昨晚睡了多久", context: sleeping(c, lastNight: 7.5, others: 5)).conclusion == "昨晚睡了 7.5 小时，目标 7.0 小时。")
        #expect(HealthAgent.reply(to: "这周睡够了吗", context: sleeping(c, lastNight: 8, others: 8)).conclusion?.hasPrefix("睡够了：这周") == true)
        #expect(HealthAgent.reply(to: "我该睡多久", context: c).conclusion?.hasPrefix("你的目标是每晚 7.0 小时") == true)
        #expect(HealthAgent.reply(to: "我每天睡几个小时才够", context: c).conclusion?.contains("7–9 小时") == true)
        // No record of it: said, not guessed.
        var none = c
        none.days = []
        none.sleep.avgMinutes = nil
        #expect(HealthAgent.reply(to: "昨晚睡够了吗", context: none).conclusion == "昨晚还没有睡眠记录，看不出来。")
        #expect(HealthAgent.reply(to: "最近睡够了吗", context: none).conclusion?.contains("看不出来") == true)
        // A number in the question and a request for advice keep their own answers.
        #expect(HealthAgent.reply(to: "昨晚只睡了5个小时", context: c).conclusion?.contains("昨晚还没有") != true)
        #expect(HealthAgent.sleepAmountAsk(AgentQuestion("睡得太少怎么办")) == nil)
    }

    // MARK: What is left of a target

    @Test func whatIsLeftOfTheWeeksTargetIsAnsweredInMinutes() throws {
        let f = try fixture()
        var base = f.base
        base.weeklyTargetMinutes = 45
        base.sessionMinutes = 30
        base.extraConditions = []
        base.conditions = []
        base.clinicianCleared = true
        var c = f.make(base)
        c.weekActiveMinutes = 27
        c.plan = []
        c.readiness.level = .high
        let today = HealthAgent.reply(to: "今天动多久能达标", context: c)
        #expect(today.conclusion == "今天动 18 分钟，这周就达标了：这周已活动 27 分钟，每周目标 45 分钟。", "\(today.text.prefix(80))")
        #expect(today.intent == .exercise && today.readsAsWrittenOnDevice && today.status == .attention("还差 18 分钟"))
        for q in ["这周还差多少分钟达标", "运动目标还差多少", "这周还差多少运动", "这周还要练多久"] {
            let r = HealthAgent.reply(to: q, context: c)
            #expect(r.conclusion?.hasPrefix("还差 18 分钟") == true && r.proposals.isEmpty, "\(q): \(r.text.prefix(70))")
        }
        // There is no target for a day; the plan, where it covers the gap, is the answer.
        #expect(HealthAgent.reply(to: "今天运动够了吗", context: c).conclusion?.hasPrefix("目标是按周算的") == true)
        let ahead = try #require(f.make(f.base).plan.first)
        var today2 = ahead
        today2.day = c.logicalToday; today2.minutes = 30; today2.status = .planned; today2.kind = .aerobic
        var later = today2
        later.day = c.logicalToday.adding(days: 1)
        var onPlan = c
        onPlan.plan = [today2]
        #expect(HealthAgent.reply(to: "今天动多久能达标", context: onPlan).conclusion?.hasPrefix("今天按计划练完，这周就达标了") == true)
        if c.logicalToday.adding(days: 1) < c.weekStart.adding(days: 7) {
            var rest = c
            rest.plan = [later]
            #expect(HealthAgent.reply(to: "今天动多久能达标", context: rest).conclusion?.hasPrefix("今天不用加练") == true)
        }
        // Too much for one day: not all of it today.
        var far = c
        far.weekActiveMinutes = 0
        far.profile.weeklyTargetMinutes = 150
        #expect(HealthAgent.reply(to: "今天还要运动多久", context: far).conclusion?.hasPrefix("今天不用一次补完") == true)
        // Done already.
        var done = c
        done.weekActiveMinutes = 50
        #expect(HealthAgent.reply(to: "这周运动目标完成了吗", context: done).conclusion?.hasPrefix("这周已经达标了") == true)
        // Never a reason to push on a day that says not to.
        var tired = c
        tired.readiness.level = .rest
        #expect(HealthAgent.reply(to: "今天动多久能达标", context: tired).conclusion?.hasPrefix("今天别为了达标硬练") == true)
        var hd = f.make(hemo(f.base))
        hd.weekActiveMinutes = 0
        #expect(HealthAgent.reply(to: "今天动多久能达标", context: hd).conclusion?.hasPrefix("今天是透析日") == true)
        // A yes or no about today stays with the training check; other topics keep theirs.
        #expect(HealthAgent.reply(to: "今天还要运动吗", context: c).intent == .trainingCheck)
        #expect(HealthAgent.reply(to: "血糖目标还差多少", context: c).intent != .exercise)
    }

    @Test func stepsLeftAreAnsweredFromToday() throws {
        let f = try fixture()
        var c = f.make(f.base)
        c.profile.stepsTarget = 7000
        var day = DayData(day: c.logicalToday)
        day.steps = 3600
        c.days = [day]
        let r = HealthAgent.reply(to: "步数还差多少", context: c)
        #expect(r.conclusion == "还差 3400 步：今天走了 3600 步，目标 7000 步。", "\(r.text.prefix(80))")
        #expect(r.text.contains("大约再走 34 分钟"))
        #expect(HealthAgent.reply(to: "今天走多少步达标", context: c).conclusion?.hasPrefix("还差 3400 步") == true)
        c.days = []
        #expect(HealthAgent.reply(to: "今天走了多少步", context: c).conclusion?.contains("没有步数记录") == true)
        // What is enough in general stays know-how.
        #expect(HealthAgent.reply(to: "每天走多少步合适", context: c).verbatim)
    }
}
