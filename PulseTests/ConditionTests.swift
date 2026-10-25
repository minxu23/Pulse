import Foundation
import SwiftData
import Testing
@testable import Pulse

private let monday = Calendar.pulse.date(from: DateComponents(year: 2026, month: 10, day: 19, hour: 8))!

@Suite("Chronic conditions, fluid limits and weight")
@MainActor
struct ConditionTests {
    /// The sample user's week, with one training made hard when `hardSession` is set.
    private func load(now: Date = monday, hardSession: Bool = false) throws -> (AgentContext, ModelContext, ModelContainer) {
        let container = try ModelContainer(for: Schema(PulseSchema.models), configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        let ctx = container.mainContext
        DemoDataGenerator.populate(ctx, persona: .xiaolin, now: now)
        DataHub.ensureWeekPlan(in: ctx, now: now)
        if hardSession {
            let week = DataHub.planItems(weekStart: now.weekStart, in: ctx)
            week.first { $0.day > now.startOfDay && $0.kind.isTraining && $0.status == .planned }?.intensity = .hard
        }
        let p = DataHub.profile(in: ctx)!
        let a = DataHub.analytics(in: ctx, now: now)
        let items = (try? ctx.fetch(FetchDescriptor<PlanItem>())) ?? []
        let c = AgentContext.make(profile: a.profile, name: p.displayName, days: a.days, plan: items.map(\.snapshot), workouts: [], vitals: [],
                                  events: [], stopBang: [], baselineSetAt: nil, raceName: p.raceName, now: now)
        return (c, ctx, container)
    }

    private func outdoorRun(on offset: Int, _ intensity: Intensity = .easy) -> SessionSnapshot {
        SessionSnapshot(id: UUID(), day: monday.startOfDay.adding(days: offset), kind: .aerobic, title: "轻松跑", minutes: 40, minimumMinutes: 20,
                        minimumDetail: "", intensity: intensity, isKey: false, status: .planned, completedMinutes: nil)
    }

    @Test func hearsOnlyConditionsTheUserSaysTheyHave() {
        let p = ProfileSnapshot()
        #expect(ConditionLibrary.mention(in: "我是低血钾症患者", profile: p)?.info.id == "hypokalemia")
        #expect(ConditionLibrary.mention(in: "我有低血钾，明天能跑间歇吗？", profile: p)?.info.id == "hypokalemia")
        #expect(ConditionLibrary.mention(in: "作为一名痛风患者，饮食要注意什么", profile: p)?.info.id == "gout")
        #expect(ConditionLibrary.mention(in: "我有慢性肾病", profile: p)?.info.native == .ckd)
        #expect(ConditionLibrary.mention(in: "医生说我是2型糖尿病", profile: p)?.info.native == .diabetesT2)
        // Someone else, a doubt, a question or the past.
        for q in ["我妈有高血压", "我是不是有低血钾？", "我有低血钾吗", "我没有肾病", "我以前得过痛风", "我担心自己有骨质疏松",
                  "我是糖尿病患者", "我有点累", "血钾低会怎样"] {
            #expect(ConditionLibrary.mention(in: q, profile: p) == nil, "\(q)")
        }
        // Already recorded.
        var hk = ProfileSnapshot()
        hk.extraConditions = [ConditionLibrary.entry(id: "hypokalemia")!]
        #expect(ConditionLibrary.mention(in: "我是低血钾症患者", profile: hk) == nil)
        var ckd = ProfileSnapshot()
        ckd.conditions = [.ckd]
        #expect(ConditionLibrary.mention(in: "我有肾病", profile: ckd) == nil)
        // Not in the library: recorded by name only, and the card says so.
        let x = ConditionLibrary.mention(in: "我是肝硬化患者", profile: p)
        #expect(x?.info.name == "肝硬化" && x?.info.known == false)
        #expect(x?.info.changes.contains { $0.contains("身体限制") } == true)
    }

    @Test func aStatementGetsTheCardAndThePlanChangeItCallsFor() throws {
        let (c, _, container) = try load(hardSession: true)
        _ = container
        let hard = c.plan.filter { $0.day >= monday.startOfDay && $0.day < monday.weekStart.adding(days: 7) && $0.intensity == .hard && $0.status == .planned }
        try #require(!hard.isEmpty, "the sample week needs a hard session")
        let r = HealthAgent.reply(to: "我是低血钾症患者", context: c)
        #expect(r.intent == .condition)
        let card = try #require(r.blocks.first?.condition)
        #expect(card.info.id == "hypokalemia")
        let k = try #require(r.conclusion)
        #expect(r.text.hasPrefix(k) && k.contains("记下"))
        #expect(r.text.contains("不再安排间歇") && r.text.contains("心跳不齐"))
        // This week's hard sessions become moderate, as a change to adopt.
        let plan = try #require(r.blocks.compactMap(\.proposal).first)
        #expect(hard.allSatisfy { h in plan.after.first { $0.id == h.id }?.intensity == .moderate })
        #expect(plan.checks.contains { $0.contains("低血钾症") })
        // The models hear about it, and are told nothing is recorded yet.
        let prompt = HealthAgent.modelPrompt(question: "我是低血钾症患者", history: [], context: HealthAgent.context(c, answering: r), reply: r, anonymous: true)
        #expect(prompt.contains("点「记下」前还没有记录") && prompt.contains("低血钾症：") && prompt.contains("医生确认前只做中低强度"))
    }

    @Test func aQuestionThatMentionsAConditionIsAnsweredWithIt() throws {
        let (c, _, container) = try load()
        _ = container
        let r = HealthAgent.reply(to: "我有低血钾，明天能跑间歇吗？", context: c)
        #expect(r.intent == .trainingCheck)
        #expect(r.text.hasPrefix("不建议"), "\(r.text)")
        #expect(r.text.contains("你记录了低血钾症") && r.text.contains("点「记下」"))
        // A hot day's outdoor session goes indoors, and the plan card says why.
        let hot = c.plan.first { $0.day > monday.startOfDay && $0.day < monday.weekStart.adding(days: 7) && WeatherPlanner.isOutdoor($0) && $0.status == .planned }
        if let s = hot {
            var warm = c
            warm.weather = [DayWeather(day: s.day, sky: .clear, high: 33, low: 25, rainChance: 0, aqi: nil)]
            let plan = try #require(HealthAgent.reply(to: "我是低血钾症患者", context: warm).blocks.compactMap(\.proposal).first)
            #expect(plan.lines.contains { $0.weekday == s.day.weekday && $0.after.contains("室内") })
            #expect(plan.notes.contains { $0.contains("低血钾症不宜在高温下大量出汗") })
        }
        #expect(r.blocks.first?.condition?.info.id == "hypokalemia")
        // Without the condition the same question is not refused for that reason.
        #expect(!HealthAgent.reply(to: "明天能跑间歇吗？", context: c).text.contains("低血钾症"))
    }

    @Test func recordingAConditionChangesThePlanAndCanBeTakenBack() throws {
        let (c, ctx, container) = try load()
        _ = container
        let r = HealthAgent.reply(to: "我是低血钾症患者", context: c)
        let card = try #require(r.blocks.first?.condition)
        let convo = AgentConversation()
        let q = AgentMessage(role: .user, text: "我是低血钾症患者")
        convo.messages = [q, AgentMessage(role: .agent, text: r.text, blocks: r.blocks)]
        convo.conditionOutcomes[card.id] = .recorded(added: DataHub.recordCondition(card.info, in: ctx))
        #expect(DataHub.profile(in: ctx)?.extraConditionsRaw == ["hypokalemia"])
        let p = DataHub.analytics(in: ctx, now: monday).profile
        #expect(p.intensityCapped && p.heatSensitive)
        #expect(HealthAgent.digest(HealthAgentTestsSupport.with(c, profile: p)).contains("低血钾症："))
        // New weeks leave out hard sessions and carry the condition's exercise points.
        let week = PlanGenerator.generalWeek(profile: p, weekStart: monday.weekStart)
        #expect(!week.sessions.contains { $0.kind == .quality })
        #expect(week.notes.contains { $0.hasPrefix("低血钾症：") })
        // Recording it again changes nothing; taking the question back forgets it.
        #expect(!DataHub.recordCondition(card.info, in: ctx))
        #expect(convo.hasAdoptedChanges(answering: q.id))
        convo.withdraw(q.id, undoingChangesIn: ctx)
        #expect(convo.conditionOutcomes[card.id] == .undone)
        #expect(DataHub.profile(in: ctx)?.extraConditionsRaw.isEmpty == true)
    }

    @Test func kidneyDiseaseIsBuiltIn() throws {
        let (c, ctx, container) = try load()
        _ = container
        let r = HealthAgent.reply(to: "我有慢性肾病", context: c)
        let card = try #require(r.blocks.first?.condition)
        #expect(card.info.native == .ckd && card.info.changes.contains { $0.contains("体重增加 2 kg") })
        DataHub.recordCondition(card.info, in: ctx)
        let p = DataHub.analytics(in: ctx, now: monday).profile
        #expect(p.conditions.contains(.ckd) && p.kidneyLimited && p.watchesWeight)
        #expect(PlanGenerator.generalWeek(profile: p, weekStart: monday.weekStart).notes.contains { $0.hasPrefix("慢性肾病") })
        // A plan change asked for later never brings a hard session back.
        var cleared = p
        cleared.clinicianCleared = true
        #expect(!cleared.kidneyLimited)
    }

    @Test func modelClaimsOfRecordingAreReworded() throws {
        let (c, _, container) = try load()
        _ = container
        let r = HealthAgent.reply(to: "我是低血钾症患者", context: c)
        let t = HealthAgent.finalize("已为你记下低血钾症，之后会考虑它。\n你已记录 5 天血压。", of: r)
        #expect(!t.contains("已为你记下") && t.contains("可以记下低血钾症"))
        #expect(t.contains("你已记录 5 天血压"))
    }

    @Test func aFluidLimitNeverSaysDrinkMore() {
        var p = ProfileSnapshot()
        p.fluidLimited = true
        p.waterTargetMl = 1200
        let run = outdoorRun(on: 2)
        let hot = DayWeather(day: run.day, sky: .clear, high: 33, low: 25, rainChance: 0, aqi: nil)
        // A hot day takes the session indoors instead of 「带水」.
        let a = WeatherPlanner.advice(plan: [run], forecast: [hot], now: monday, profile: p)
        #expect(a.ops.contains { if case .replace = $0 { true } else { false } })
        #expect(a.notes.count == 1 && a.notes[0].contains("限水期间") && !a.notes[0].contains("带水"))
        let usual = WeatherPlanner.advice(plan: [run], forecast: [hot], now: monday)
        #expect(usual.ops.isEmpty && usual.notes.first?.contains("带水") == true)
        let today = DayWeather(day: monday.startOfDay, sky: .clear, high: 33, low: 25, rainChance: 0, aqi: nil)
        let reminder = WeatherPlanner.reminder(today: today, sessions: [outdoorRun(on: 0)], profile: p)
        #expect(reminder?.changePlan == true && reminder?.line.contains("带水") == false)
        // Recovery items: nothing about drinking under the limit; going over it is worth saying.
        var d = DayData(day: monday.startOfDay)
        d.waterMl = 500
        let under = RecoveryAdvisor.bedtimeFocus(today: d, history: [], profile: p, readiness: nil, tomorrow: [], now: monday)
        #expect(!under.contains { $0.id == "water" })
        d.waterMl = 1600
        let over = RecoveryAdvisor.bedtimeFocus(today: d, history: [], profile: p, readiness: nil, tomorrow: [], now: monday)
        #expect(over.first { $0.id == "water" }?.title == "饮水超过上限")
        var free = p
        free.fluidLimited = false
        d.waterMl = 500
        #expect(RecoveryAdvisor.bedtimeFocus(today: d, history: [], profile: free, readiness: nil, tomorrow: [], now: monday).contains { $0.title == "适量补水" })
    }

    @Test func quickWeightGainAlertsWhenFluidMatters() {
        let w = [VitalPoint(time: monday.adding(days: -3), kind: .weight, value: 70.4, context: .morning),
                 VitalPoint(time: monday.adding(days: -2), kind: .weight, value: 70.0, context: .morning),
                 VitalPoint(time: monday, kind: .weight, value: 72.3, context: .morning)]
        var p = ProfileSnapshot()
        // Nothing for someone without a reason to watch it.
        #expect(AlertEngine.weightAlert(w, profile: p, now: monday) == nil)
        p.conditions = [.ckd]
        let a = AlertEngine.weightAlert(w, profile: p, now: monday)
        // Measured from the lowest earlier reading, not the first.
        #expect(a?.kind == .weightGain && a?.title == "3 天内体重增加 2.3 kg")
        #expect(a?.guidance.contains("不要自己加用或停用利尿剂") == true)
        var limited = ProfileSnapshot()
        limited.fluidLimited = true
        #expect(AlertEngine.weightAlert(w, profile: limited, now: monday) != nil)
        // A slow gain is not.
        let slow = [VitalPoint(time: monday.adding(days: -3), kind: .weight, value: 71, context: .morning),
                    VitalPoint(time: monday, kind: .weight, value: 72.5, context: .morning)]
        #expect(AlertEngine.weightAlert(slow, profile: p, now: monday) == nil)
    }
}

/// Swaps the profile of a context, as the agent does for a condition mentioned in the question.
enum HealthAgentTestsSupport {
    static func with(_ c: AgentContext, profile p: ProfileSnapshot) -> AgentContext {
        var c = c
        c.profile = p
        return c
    }
}
