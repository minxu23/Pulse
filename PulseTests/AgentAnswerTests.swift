import Foundation
import SwiftData
import Testing
@testable import Pulse

private let evening = Calendar.pulse.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 20))!

@Suite("Health Agent answers the question asked")
@MainActor
struct AgentAnswerTests {
    private func load(_ persona: DemoPersona, at evening: Date = evening) throws -> (AgentContext, ModelContainer) {
        let container = try ModelContainer(for: Schema(PulseSchema.models), configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        let ctx = container.mainContext
        DemoDataGenerator.populate(ctx, persona: persona, now: evening)
        DataHub.ensureWeekPlan(in: ctx, now: evening)
        let p = DataHub.profile(in: ctx)!
        let a = DataHub.analytics(in: ctx, now: evening)
        let items = (try? ctx.fetch(FetchDescriptor<PlanItem>())) ?? []
        let sessions = (try? ctx.fetch(FetchDescriptor<ActivitySession>())) ?? []
        let vitals = (try? ctx.fetch(FetchDescriptor<VitalReading>())) ?? []
        let labs = ((try? ctx.fetch(FetchDescriptor<LabResult>())) ?? []).map(\.point)
        let c = AgentContext.make(profile: a.profile, name: p.displayName, days: a.days, plan: items.map(\.snapshot),
                                  workouts: sessions.map(\.point), vitals: vitals.map(\.point).filter { $0.time > evening.adding(days: -60) },
                                  events: [], stopBang: p.stopBangAnswers, baselineSetAt: p.baselineSetAt, raceName: p.raceName,
                                  targetRHR: p.targetRHR, weather: DemoWeather.days(from: evening), weatherSource: "示例天气",
                                  labs: labs, now: evening)
        return (c, container)
    }

    @Test func questionsAreRead() {
        #expect(AgentQuestion("今天早上血压155，要紧吗").reading == .bp(sys: 155, dia: nil))
        #expect(AgentQuestion("今天早上血压155，要紧吗").form == .isItOK)
        #expect(AgentQuestion("血压150/95能去散步吗").reading == .bp(sys: 150, dia: 95))
        #expect(AgentQuestion("高压162低压98要去医院吗").reading == .bp(sys: 162, dia: 98))
        #expect(AgentQuestion("晚饭后血糖12正常吗").reading == .glucose(12, .postMeal))
        #expect(AgentQuestion("空腹血糖 6.8 高吗").reading == .glucose(6.8, .fasting))
        #expect(AgentQuestion("我是2型糖尿病，血糖老是高").reading == nil)
        #expect(AgentQuestion("昨晚只睡了5个小时，今天怎么安排").reading == .sleepHours(5))
        #expect(AgentQuestion("昨晚睡了五个半小时").reading == .sleepHours(5.5))
        #expect(AgentQuestion("最近体重涨了两斤").reading == .weightChange(kg: 1))
        #expect(AgentQuestion("我能吃香蕉吗").food?.name == "香蕉")
        #expect(AgentQuestion("能吃葡萄干吗").food?.name == "红枣和果干")
        #expect(AgentQuestion("香蕉").food == nil, "a food is only read when the question is about eating it")
        #expect(AgentQuestion("最近脚有点肿").symptom == .swelling)
        #expect(AgentQuestion("跑步膝盖疼怎么办").symptom == .pain)
        #expect(AgentQuestion("跑完步腿很酸正常吗").symptom == .soreness)
        #expect(AgentQuestion("能喝酸奶吗").symptom == nil)
        #expect(AgentQuestion("尿酸高能吃海鲜吗").symptom == nil)
        #expect(AgentQuestion("给我讲讲准备度是怎么算的").form == .explain)
    }

    @Test func aKidneyPatientGetsAnswersAboutWhatHeAsked() throws {
        let (c, container) = try load(.wangjianguo)
        _ = container
        let banana = HealthAgent.reply(to: "我能吃香蕉吗", context: c)
        #expect(banana.intent == .food)
        #expect(banana.conclusion?.hasPrefix("香蕉最好先不吃") == true && banana.text.contains("5.4"), "\(banana.text)")
        let hotpot = HealthAgent.reply(to: "我可以吃火锅吗", context: c)
        #expect(hotpot.conclusion?.hasPrefix("火锅可以偶尔吃，但要换个吃法") == true)
        #expect(hotpot.text.contains("清汤") && hotpot.text.contains("盐"))
        #expect(!HealthAgent.reply(to: "今天想吃烧烤", context: c).text.contains("锅底"), "barbecue is not hotpot")

        let bp = HealthAgent.reply(to: "今天早上血压155，要紧吗", context: c)
        #expect(bp.intent == .reading && bp.text.contains("155") && bp.text.contains("晨起"), "\(bp.text)")
        let crisis = HealthAgent.reply(to: "血压185/115怎么办", context: c)
        #expect(crisis.text.contains("120") && crisis.conclusion?.contains("马上") == true)
        let glucose = HealthAgent.reply(to: "晚饭后血糖12正常吗", context: c)
        #expect(glucose.conclusion?.hasPrefix("12.0 偏高") == true && glucose.text.contains("晚饭后"))
        #expect(HealthAgent.reply(to: "血糖3.5怎么办", context: c).text.contains("15 g"))

        let swelling = HealthAgent.reply(to: "最近脚有点肿", context: c)
        #expect(swelling.intent == .symptom && swelling.text.contains("氨氯地平") && swelling.text.contains("气短"))
        let dizzy = HealthAgent.reply(to: "我最近老是头晕", context: c)
        #expect(dizzy.text.contains("120") && dizzy.text.contains("格列美脲"))
        #expect(HealthAgent.reply(to: "我该多久去复查一次", context: c).text.contains("6 个月"))
        #expect(HealthAgent.reply(to: "少吃盐有什么技巧", context: c).text.contains("低钠盐"), "salt substitute is potassium")
        let meds = HealthAgent.reply(to: "降压药是早上吃还是晚上吃", context: c)
        #expect(meds.conclusion?.hasPrefix("氨氯地平") == true && !meds.text.contains("二甲双胍"))
        #expect(HealthAgent.reply(to: "我的血压控制得怎么样", context: c).conclusion?.hasPrefix("还没达标") == true)
        #expect(HealthAgent.reply(to: "能喝啤酒吗", context: c).text.contains("尿酸"))
    }

    @Test func aRunnerGetsDirectAnswers() throws {
        let (c, container) = try load(.xiaolin)
        _ = container
        #expect(HealthAgent.reply(to: "跑步前吃香蕉好吗", context: c).conclusion == "香蕉可以吃。")
        // A premise the records do not bear out is answered first.
        #expect(HealthAgent.reply(to: "最近心率为什么变高了", context: c).conclusion?.contains("没有变高") == true)
        #expect(HealthAgent.reply(to: "为什么我的HRV这么低", context: c).conclusion?.contains("不算低") == true)
        #expect(HealthAgent.reply(to: "我这周的训练量是不是太大了", context: c).conclusion?.hasPrefix("不大") == true)
        let how = HealthAgent.reply(to: "怎么才能把静息心率降下来", context: c)
        #expect(how.text.contains("少喝酒") && how.text.contains("4.6"), "levers from the person's own records, by size")

        let tired = HealthAgent.reply(to: "我今天有点累，还要去跑步吗", context: c)
        #expect(tired.intent == .trainingCheck && tired.text.contains("累"))
        let knee = HealthAgent.reply(to: "跑步膝盖疼怎么办", context: c)
        #expect(knee.intent == .symptom && knee.text.contains("骨科") && knee.proposesPlan)
        #expect(knee.safety?.contains("骨科") == true, "when to see a doctor survives a model rewrite")
        let cold = HealthAgent.reply(to: "我感冒了还能运动吗", context: c)
        #expect(cold.intent == .symptom && cold.conclusion?.contains("脖子以上") == true)
        #expect(HealthAgent.reply(to: "跑完步腿很酸正常吗", context: c).conclusion?.hasPrefix("正常") == true)
        #expect(HealthAgent.reply(to: "下午犯困可以喝咖啡吗", context: c).conclusion?.hasPrefix("可以喝") == true, "asks about the afternoon, not now")
        #expect(HealthAgent.reply(to: "周末朋友聚会要喝酒，有什么影响", context: c).text.contains("配一杯水"))
        #expect(HealthAgent.reply(to: "晚上睡不着怎么办", context: c).conclusion?.contains("20 分钟") == true)
        #expect(HealthAgent.reply(to: "给我讲讲准备度是怎么算的", context: c).text.contains("25%"))
        #expect(HealthAgent.reply(to: "这个月进步了吗", context: c).conclusion?.hasPrefix("有进步") == true)
        #expect(HealthAgent.reply(to: "拉伸怎么做", context: c).intent == .knowledge, "「怎么做」 is not 「接下来」")
    }

    @Test func theModelSeesOnlyWhatBearsOnTheQuestion() throws {
        let (c, container) = try load(.wangjianguo)
        _ = container
        let food = HealthAgent.reply(to: "我能吃香蕉吗", context: c)
        let prompt = HealthAgent.modelPrompt(question: "我能吃香蕉吗", history: [], context: c, reply: food, anonymous: false)
        #expect(!prompt.contains("打鼾") && !prompt.contains("天气预报") && prompt.contains("化验"))
        #expect(prompt.contains("不要另外加"))
        #expect(!HealthAgent.groundedInstructions.contains("降低静息心率"), "not every answer is about resting heart rate")

        let load = HealthAgent.reply(to: "我这周的训练量是不是太大了", context: c)
        let p2 = HealthAgent.modelPrompt(question: "我这周的训练量是不是太大了", history: [], context: c, reply: load, anonymous: false)
        #expect(!p2.contains("天气预报") && p2.contains("不要列建议"))
    }

    @Test func modelAnswersAreKeptToTheRules() {
        let r = AgentReply(text: "不大：负荷比 1.07。\n\n本周完成 1/4 次。", intent: .exercise, conclusion: "不大：负荷比 1.07。")
        // Suggestions the rules did not make are dropped.
        #expect(!HealthAgent.finalize("不大：负荷比 1.07。\n• 关注睡眠呼吸变化", of: r).contains("睡眠呼吸"))
        // A model that loses the verdict is not used.
        #expect(!HealthAgent.keepsConclusion("还没达标，低于 1.3% 的时间也超过 4%。", of: AgentReply(text: "", conclusion: "还没达标：近 14 天 66% 在范围内。")))
        #expect(HealthAgent.keepsConclusion("可以喝，但最好在14:00前喝完。", of: AgentReply(text: "", conclusion: "可以喝，但最好在 14:00 前喝完。")))
        // Facts dropped after the verdict are put back.
        let food = AgentReply(text: "", intent: .food, conclusion: "香蕉最好先不吃。你的血钾 5.4 偏高。")
        #expect(HealthAgent.finalize("香蕉最好先不吃。\n• 换成苹果", of: food).contains("5.4"))
        // A second list of suggestions is dropped.
        let two = AgentReply(text: "要点\n• 少喝酒\n• 睡够", intent: .rhr)
        #expect(!HealthAgent.finalize("对你最有用的：\n• 少喝酒\n• 睡够\n\n• 马上戒酒", of: two).contains("马上戒酒"))
        // When to see a doctor stays, however short the model's answer.
        let pain = AgentReply(text: "", intent: .symptom, conclusion: "膝盖疼先别跑了。", safety: "肿得厉害或 1–2 周还没好转，去看骨科。")
        #expect(HealthAgent.finalize("膝盖疼先别跑了。\n• 换成骑车", of: pain).hasSuffix("去看骨科。"))
        #expect(HealthAgent.finalize("膝盖疼先别跑了。肿得厉害或 1–2 周还没好转，去看骨科。", of: pain).components(separatedBy: "骨科").count == 2)
        // The time line echoed from the data is dropped.
        #expect(!HealthAgent.finalize("现在：10月21日 周三 20:00。\n可以。", of: AgentReply(text: "可以。", intent: .diet)).contains("10月21日"))
    }

    // MARK: Found in the full verification (2026-10-29)

    private func at(_ h: Int, _ m: Int) -> Date { Calendar.pulse.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: h, minute: m))! }

    @Test func safetyAnswersAreSpecific() throws {
        let (c, container) = try load(.wangjianguo)
        _ = container
        let harm = HealthAgent.reply(to: "我不想活了", context: c)
        #expect(harm.urgent && harm.text.hasPrefix("听到你这样说") && harm.text.contains("12356"))
        #expect(HealthAgent.reply(to: "I have chest pain", context: c).urgent)
        let stop = HealthAgent.reply(to: "二甲双胍可以停吗", context: c)
        #expect(stop.intent == .meds && stop.text.contains("别自己停") && stop.text.contains("低血糖"))
        let half = HealthAgent.reply(to: "我能把降压药减半吗", context: c)
        #expect(half.conclusion?.contains("不能替你调整") == true && half.text.contains("141/86"))
        // A lab result that contradicts what the user says is pointed out, and kept through a model rewrite.
        let told = HealthAgent.reply(to: "我是低血钾症患者", context: c)
        #expect(told.safety?.contains("5.4") == true)
        #expect(HealthAgent.reply(to: "我是不是有低血钾？", context: c).conclusion?.hasPrefix("从化验看不是偏低，而是偏高") == true)
        var withHypo = c
        withHypo.profile.include(ConditionLibrary.resolve("hypokalemia"))
        #expect(HealthAgent.reply(to: "我能吃香蕉吗", context: withHypo).conclusion?.hasPrefix("香蕉最好先不吃") == true, "the lab result wins")
    }

    @Test func questionsAboutOthersAndPulseItself() throws {
        var (c, container) = try load(.wangjianguo)
        _ = container
        let mom = HealthAgent.reply(to: "我妈有高血压", context: c)
        #expect(mom.intent == .unknown && mom.text.contains("家人"))
        #expect(HealthAgent.modelPrompt(question: "我妈有高血压", history: [], context: c, reply: mom, anonymous: false).contains("家人或朋友"))
        #expect(HealthAgent.reply(to: "今天股票怎么样", context: c).intent == .unknown)
        #expect(HealthAgent.reply(to: "我的数据会上传吗", context: c).text.contains("仅本机"))
        c.answerMode = .hybrid
        let privacy = HealthAgent.reply(to: "我的数据会上传吗", context: c)
        #expect(privacy.text.contains("端云结合") && privacy.verbatim && privacy.intent == .about)
        #expect(HealthAgent.reply(to: "你的建议依据是什么", context: c).intent == .about)
        #expect(HealthAgent.reply(to: "Can I run today?", context: c).text.contains("中文"))
        #expect(HealthAgent.reply(to: "？？？", context: c).text.contains("没太看懂"))
    }

    @Test func topicAnswersMatchTheQuestion() throws {
        let (c, container) = try load(.wangjianguo)
        _ = container
        #expect(HealthAgent.reply(to: "为什么静息心率最近没怎么降？", context: c).conclusion?.hasPrefix("最近确实变化不大") == true)
        #expect(HealthAgent.reply(to: "我这周的训练量是不是太大了", context: c).conclusion?.hasPrefix("不大，反而偏少") == true)
        #expect(HealthAgent.reply(to: "今晚能做力量训练吗", context: c).intent == .trainingCheck)
        let drink = HealthAgent.reply(to: "喝酒后第二天能跑步吗？", context: c)
        #expect(drink.intent == .alcohol && drink.conclusion?.hasPrefix("可以动，但做轻松的") == true)
        let effect = HealthAgent.reply(to: "饮酒对我的影响有多大？", context: c)
        #expect(effect.conclusion?.hasPrefix("从你的记录看，影响不小") == true && !effect.text.contains("聚会"))
        #expect(effect.safety?.contains("低血糖") == true, "glimepiride with alcohol is kept through a rewrite")
        #expect(HealthAgent.reply(to: "能喝奶茶吗", context: c).conclusion?.hasPrefix("奶茶可以喝一点") == true)
        #expect(HealthAgent.reply(to: "HRV是什么意思", context: c).conclusion?.hasPrefix("HRV（心率变异性）") == true)
        #expect(HealthAgent.reply(to: "马拉松怎么补给", context: c).text.contains("能量胶"))
        #expect(HealthAgent.reply(to: "帮我把周六的训练挪到周日", context: c).text.contains("周六本来没有安排训练"))
        #expect(HealthAgent.reply(to: "拉伸怎么做", context: c).text.contains("20–30 秒"))
        #expect(HealthAgent.reply(to: "我应该买什么跑鞋", context: c).text.contains("合脚"))
        let cgm = HealthAgent.reply(to: "CGM 贴在哪里比较好", context: c)
        #expect(cgm.intent == .knowledge && cgm.text.contains("上臂后侧"))
    }

    @Test func timeAndScheduleAreRespected() throws {
        let (chen, c1) = try load(.chenjie, at: at(7, 30))
        _ = c1
        #expect(HealthAgent.reply(to: "现在可以去跑步吗", context: chen).conclusion?.contains("可以去跑步") == true, "judges the run, not the planned strength")
        let (lin, c2) = try load(.linyue, at: at(1, 30))
        _ = c2
        #expect(HealthAgent.reply(to: "现在可以去跑步吗", context: lin).conclusion?.contains("夜班") == true)
        let shift = HealthAgent.reply(to: "明天能跑间歇吗？", context: lin)
        #expect(shift.conclusion?.hasPrefix("不建议") == true && shift.conclusion?.contains("夜班") == true, "the reason goes with the verdict")
        let (xiao, c3) = try load(.xiaolin, at: at(7, 30))
        _ = c3
        let rest = HealthAgent.reply(to: "今天适合运动吗？", context: xiao)
        #expect(rest.conclusion?.contains("计划里是休息") == true, "heat does not make a rest day 「量要少一点」")
        let (late, c4) = try load(.wangjianguo, at: at(23, 40))
        _ = c4
        #expect(HealthAgent.reply(to: "昨晚只睡了4个小时", context: late).text.contains("已经过了你平时"))
    }

    @Test func followUpsAreReadWithTheQuestionBefore() {
        #expect(HealthAgent.resolveFollowUp("那明天呢？", previous: "今天适合运动吗？") == "明天适合运动吗？")
        #expect(HealthAgent.resolveFollowUp("那苹果呢？", previous: "我能吃香蕉吗") == "我能吃苹果吗")
        #expect(HealthAgent.resolveFollowUp("那周六呢", previous: "明天能跑间歇吗？") == "周六能跑间歇吗？")
        #expect(HealthAgent.resolveFollowUp("我能吃香蕉吗", previous: "今天适合运动吗？") == nil)
        #expect(HealthAgent.resolveFollowUp("那苹果呢？", previous: nil) == nil)
        // A follow-up that names no topic keeps the one before; follow-ups asked on it don't pile up.
        #expect(HealthAgent.resolveFollowUp("那该注意什么？", previous: "我最近血压怎么样") == "我最近血压怎么样，那该注意什么？")
        #expect(HealthAgent.resolveFollowUp("为什么", previous: "我最近血压怎么样，那该注意什么？") == "我最近血压怎么样，为什么")
        #expect(HealthAgent.resolveFollowUp("怎么办？", previous: "最近脚有点肿。") == "最近脚有点肿，怎么办？")
        #expect(HealthAgent.resolveFollowUp("今天能跑步吗", previous: "我最近血压怎么样") == nil)
        #expect(HealthAgent.resolveFollowUp("该注意什么", previous: nil) == nil)
        #expect(!HealthAgent.isContinuation("血压该注意什么") && !HealthAgent.isContinuation("接下来我该关注什么"))
    }

    /// 「那该注意什么？」 after a topic is answered on that topic, not with the general next steps.
    @Test func topicFollowUpsStayOnTopic() throws {
        let (c, container) = try load(.wangjianguo)
        _ = container
        for (first, then, intent) in [("我最近血压怎么样", "那该注意什么？", AgentIntent.bp), ("血糖控制得怎么样", "该怎么办", .glucose),
                                      ("我的肾功能怎么样？", "那要注意什么", .labs), ("最近脚有点肿", "要紧吗", .symptom),
                                      ("我能吃香蕉吗", "为什么", .food), ("晚上睡不好怎么办", "那要去看医生吗", .sleep)] {
            let asked = try #require(HealthAgent.resolveFollowUp(then, previous: first))
            #expect(HealthAgent.reply(to: asked, context: c).intent == intent, "\(first) → \(then)")
        }
        // The model is asked for what is asked now; the verdict isn't pinned again.
        let full = HealthAgent.reply(to: "我最近血压怎么样，那该注意什么？", context: c)
        let r = HealthAgent.continuing(full, question: "那该注意什么？")
        let verdict = try #require(full.conclusion)
        #expect(r.conclusion == nil && !r.text.contains(verdict) && r.text.contains("• "), "\(r.text)")
        // 「要紧吗」 asks for the verdict itself.
        let judged = HealthAgent.continuing(HealthAgent.reply(to: "今天早上血压155，要紧吗", context: c), question: "要紧吗")
        #expect(judged.conclusion != nil && judged.continuation)
        // A model that says the verdict again anyway: the opening goes, the list stays and gets a lead-in.
        let echoed = "我刚刚看你的血压记录，还没达标：近 30 天 15 次测量平均 142/89，目标是 130/80 以下。\n\n• 每天固定时间吃药，别漏\n• 盐每天不超过 5 g"
        let shown = HealthAgent.finalize(echoed, of: HealthAgent.continuing(AgentReply(text: "还没达标：近 30 天 15 次测量平均 142/89，目标是 130/80 以下。\n• 每天固定时间吃药，别漏", intent: .bp,
                                                                                    conclusion: "还没达标：近 30 天 15 次测量平均 142/89，目标是 130/80 以下。"),
                                                                         question: "那该注意什么？"), strict: false)
        #expect(shown.hasPrefix("可以从这几件事做起：") && shown.contains("• 每天固定时间吃药") && !shown.contains("142/89"), "\(shown)")
        let fresh = "盐是最容易忽略的一项。\n\n• 每天固定时间吃药"
        #expect(HealthAgent.withoutRepeat(fresh, of: "还没达标：近 30 天 15 次测量平均 142/89，目标是 130/80 以下。") == fresh)
        let prompt = HealthAgent.modelPrompt(question: "我最近血压怎么样，那该注意什么？", history: ["用户：我最近血压怎么样", "助手：还没达标"],
                                             context: c, reply: r, anonymous: true)
        #expect(prompt.contains("接着上一个问题追问") && !prompt.contains("【第一句】"))
    }

    private func chips(_ q: String, _ c: AgentContext, asked: [String] = []) -> [String] {
        AgentFollowUps.suggest(after: HealthAgent.reply(to: q, context: c), question: q, context: c, asked: asked)
    }

    @Test func suggestionsFollowTheAnswerAndThePerson() throws {
        let (wang, c1) = try load(.wangjianguo)
        _ = c1
        #expect(chips("我能吃香蕉吗", wang).first == "那苹果呢？", "high potassium: the next fruit to ask about")
        #expect(chips("可以吃火锅吗", wang).contains("少吃盐有什么技巧？"))
        #expect(chips("今天早上血压155，要紧吗", wang).prefix(2) == ["我的血压控制得怎么样？", "降压药是早上吃还是晚上吃？"])
        #expect(chips("最近脚有点肿", wang).contains("我的肾功能怎么样？"))
        #expect(chips("今天适合运动吗", wang).first == "那明天呢？")
        let (xiao, c2) = try load(.xiaolin)
        _ = c2
        #expect(chips("我应该买什么跑鞋", xiao).allSatisfy { HealthAgent.reply(to: $0, context: xiao).intent == .knowledge }, "know-how leads to more know-how")
        #expect(chips("昨晚只睡了5个小时", xiao).contains("熬夜后怎么恢复？"))
        #expect(chips("HRV是什么意思", xiao).first == "我的HRV最近怎么样？")
        #expect(!chips("血糖控制得怎么样", xiao).contains("糖尿病人能吃水果吗？"), "not for someone without diabetes")
        #expect(chips("我妈有高血压该注意什么", xiao) == ["少吃盐有什么技巧？"], "someone else's health: nothing about the user's own records")
        for old in ["晚饭后血糖 12 正常吗？", "今天早上血压 155 要紧吗？", "最近体重涨了两斤要紧吗？"] {
            #expect(!["血糖控制得怎么样", "我的血压控制得怎么样", "最近脚有点肿"].contains { chips($0, wang).contains(old) })
        }
    }

    @Test func suggestionsAreNewAndAnswerable() throws {
        let (wang, c1) = try load(.wangjianguo)
        _ = c1
        #expect(!chips("今天适合运动吗", wang, asked: ["明天适合运动吗"]).contains("那明天呢？"), "「那明天呢」 was asked already")
        #expect(!chips("我的睡眠怎么样", wang, asked: ["睡不着怎么办"]).contains("睡不着怎么办？"))
        #expect(chips("胸口痛，喘不上气", wang).isEmpty, "nothing under an emergency reply")
        for persona in DemoPersona.allCases {
            let (c, container) = try load(persona)
            _ = container
            for q in ["我能吃香蕉吗", "晚饭后血糖12正常吗", "最近老是很累", "明天能跑间歇吗", "为什么静息心率最近没怎么降", "我的睡眠怎么样",
                      "昨晚喝了酒今天能跑步吗", "我的血压控制得怎么样", "我的肾功能怎么样", "接下来我该关注什么", "马拉松怎么补给", "拉伸怎么做"] {
                let s = chips(q, c)
                #expect(!s.isEmpty && s.count <= 3, "\(persona.name)：\(q)")
                for x in s {
                    let a = HealthAgent.reply(to: HealthAgent.resolveFollowUp(x, previous: q) ?? x, context: c)
                    #expect(a.intent != .unknown && !a.text.hasPrefix("还没有"), "\(persona.name)：\(q) → \(x) has no answer of its own")
                }
            }
        }
    }

    @Test func everyAnswerInTheConversationCarriesItsSuggestions() async throws {
        let (c, container) = try load(.wangjianguo)
        _ = container
        // Verbatim answers: no language model or network involved.
        let chat = AgentConversation()
        await chat.send("准备度是怎么算的", context: c)
        await chat.send("我该多久去复查一次", context: c)
        let answers = chat.messages.compactMap(\.reply)
        #expect(answers.count == 2 && answers.allSatisfy { !$0.followUps.isEmpty })
        #expect(!answers[1].followUps.contains("准备度是怎么算的？"), "what was asked is not offered again")
    }

    @Test func theAgentCanBeNamed() throws {
        #expect(AgentName.requested(in: "以后叫你小安") == .rename("小安"))
        #expect(AgentName.requested(in: "以后就叫你小安吧") == .rename("小安"))
        #expect(AgentName.requested(in: "我可以叫你小安吗？") == .rename("小安"))
        #expect(AgentName.requested(in: "你就叫「阿康」吧！") == .rename("阿康"))
        #expect(AgentName.requested(in: "给你取个名字，叫小安") == .rename("小安"))
        #expect(AgentName.requested(in: "把你的名字改成 Ava") == .rename("Ava"))
        #expect(AgentName.requested(in: "改回原来的名字") == .reset)
        #expect(AgentName.requested(in: "还是叫你 Health Agent 吧") == .reset)
        #expect(AgentName.requested(in: "我想给你起个名字") == .ask)
        #expect(AgentName.requested(in: "小安", afterAsking: true) == .rename("小安"))
        #expect(AgentName.requested(in: "算了", afterAsking: true) == nil)
        for q in ["我叫你帮我看看血压", "叫你提醒我吃药", "你叫什么名字", "我女儿叫小安", "今天适合运动吗", "小安", "以后叫你一个超级长超级长的名字"] {
            #expect(AgentName.requested(in: q) == nil, "\(q) is not a new name")
        }
        #expect(AgentName.asksName("你叫什么名字？") && !AgentName.asksName("以后叫你小安"))
        #expect(AgentName.unaddressed("小安，今天适合跑步吗", name: "小安") == "今天适合跑步吗")
        #expect(AgentName.unaddressed("小安排一下明天的训练", name: "小安") == "小安排一下明天的训练", "a word that starts with the name")
        #expect(AgentName.phrase("问问", "Health Agent") == "问问 Health Agent")
        #expect(AgentName.phrase("和", "小安", "一起分析") == "和小安一起分析")
        #expect(AgentName.phrase("和", "Ava", "一起分析") == "和 Ava 一起分析")
        #expect(AgentName.cleaned(" 「小安」 ") == "小安" && AgentName.cleaned("health agent") == nil)
        #expect(AgentName.introduction("小安")?.contains("你就是小安") == true && AgentName.introduction(AgentName.standard) == nil)
        // A model speaks of itself as 「我」, whatever it was named.
        #expect(AgentName.firstPerson("康康建议把今天的活动减到 10 分钟。", name: "康康") == "我建议把今天的活动减到 10 分钟。")
        #expect(AgentName.firstPerson("Health Agent 会在本机回答。", name: "Health Agent") == "Health Agent 会在本机回答。", "only when it is the subject, right before the verb")
        #expect(AgentName.firstPerson("Health Agent建议早点睡。", name: "Health Agent") == "我建议早点睡。")
        #expect(AgentName.firstPerson("小安排一下明天的训练", name: "小安") == "小安排一下明天的训练")
        // Only the user can make the visit summary, in the app.
        let r = AgentReply(text: "肌酐偏高。", intent: .labs)
        #expect(HealthAgent.finalize("复诊时给医生看，我可以帮你生成就诊摘要。", of: r, strict: false) == "复诊时给医生看，可以在「我的 › 隐私与数据导出」生成就诊摘要。")

        let (base, container) = try load(.xiaolin)
        _ = container
        #expect(HealthAgent.reply(to: "你叫什么名字", context: base).text.contains("以后叫你小安"))
        var c = base
        c.agentName = "小安"
        #expect(HealthAgent.reply(to: "你叫什么名字", context: c).text.hasPrefix("我叫小安。"))
        #expect(HealthAgent.reply(to: "你好", context: c).text.contains("我是小安"))
    }

    @Test func namingInTheChat() async throws {
        let (c, container) = try load(.wangjianguo)
        _ = container
        // Its own store: the app's name and other tests stay as they are.
        let suite = "PulseTests.agentName"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let names = AgentNameSettings(defaults: defaults)
        let chat = AgentConversation()
        chat.names = names
        await chat.send("以后叫你小安吧", context: c)
        #expect(names.name == "小安" && chat.messages.last?.text.hasPrefix("好，以后我就叫小安") == true)
        await chat.send("我想给你改个名字", context: c)
        await chat.send("阿康", context: c)
        #expect(names.name == "阿康", "the answer to 「你想叫我什么」 is the name")
        await chat.send("改回原来的名字", context: c)
        #expect(names.custom == nil && names.name == AgentName.standard)
    }

    @Test func modelAnswersStayWithinTheRules() {
        let off = AgentReply(text: "", intent: .unknown)
        #expect(HealthAgent.finalize("这个我帮不上忙。\n• 保持规律作息", of: off) == HealthAgent.offTopicReply)
        let two = AgentReply(text: "可以。\n• 强度保持能说话\n• 洗个温水澡", intent: .trainingCheck, conclusion: "可以。")
        #expect(!HealthAgent.finalize("可以。\n• 强度保持能说话\n• 洗个温水澡\n• 早上 7 点前练", of: two).contains("7 点前"), "no more suggestions than the rules made")
        #expect(OnDeviceModel.describe(NSError(domain: "x", code: 1, userInfo: [NSLocalizedDescriptionKey: "guardrailViolation"])).contains("内容限制"))
        #expect(HealthAgent.stripLabels("【接下来最值得做的三件事】\n- 先复测血压") == "接下来最值得做的三件事\n• 先复测血压")
        let dash = AgentReply(text: "不建议。\n• 改成轻松活动", intent: .trainingCheck, conclusion: "不建议明天练。那天是夜班后的恢复日。")
        let kept = HealthAgent.finalize("不建议明天练。\n- 改成轻松活动\n- 多喝水", of: dash)
        #expect(kept.contains("夜班后的恢复日") && !kept.contains("多喝水"), "a dropped reason comes back; 「- 」 lists are capped too")
    }
}
