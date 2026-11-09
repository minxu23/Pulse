import Foundation
import SwiftData
import Testing
@testable import Pulse

/// The fixes from the code review of 2026-11-09: erasing both stores, plans outside a pack, unknown age,
/// round goals and noise, the round's first-week steps, a past week's chat, typed numbers and proposal reasons.
@Suite("Code review fixes")
@MainActor
struct ReviewFindingsTests {
    private let wednesday = Calendar.pulse.date(from: DateComponents(year: 2026, month: 11, day: 4, hour: 10))!

    /// The container itself is kept by the test: its models can't be read once it is gone.
    private func memory() throws -> ModelContainer {
        try ModelContainer(for: Schema(PulseSchema.models), configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    @Test func erasingEverythingFindsBothStoresAfterThePreferencesAreCleared() throws {
        let id = UUID().uuidString
        let suite = "test.erase.\(id)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let own = "test-own-\(id).store", sample = "test-sample-\(id).store"
        defaults.set(own, forKey: DataStores.ownKey)
        defaults.set(sample, forKey: DataStores.sampleKey)
        defaults.set(DataStores.Mode.own.rawValue, forKey: DataStores.modeKey)
        defer {
            for name in [own, sample] {
                for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(at: URL(fileURLWithPath: DataStores.url(name).path + suffix)) }
            }
            UserDefaults().removePersistentDomain(forName: suite)
        }
        let stores = DataStores(defaults: defaults, arguments: [])
        let mine = UserProfile()
        mine.nickname = "我自己"; mine.onboardingDone = true
        stores.container.mainContext.insert(mine)
        try stores.container.mainContext.save()
        stores.enterTesting()
        let demo = UserProfile()
        demo.nickname = "示例"; demo.usesDemoData = true
        stores.container.mainContext.insert(demo)
        try stores.container.mainContext.save()

        // 删除所有数据 from testing mode: every preference goes first (DataHub.eraseEverything), then the other store.
        DataHub.clearPreferences(defaults, domain: suite)
        stores.eraseOtherStore()

        #expect(stores.mode == .own && !stores.testingEnabled)
        #expect(DataHub.profile(in: stores.container.mainContext) == nil, "your own store is the one deleted")
        #expect(FileManager.default.fileExists(atPath: DataStores.url(sample).path), "the open sample file is not deleted in its place")
        #expect(defaults.string(forKey: DataStores.ownKey) == own && defaults.string(forKey: DataStores.sampleKey) == sample,
                "which file is which is written again, so the next launch doesn't guess")
        #expect(defaults.string(forKey: DataStores.modeKey) == "own")
    }

    @Test func settingsChangesKeepTheWeekWhenOnlyRecording() throws {
        let container = try memory()
        let ctx = container.mainContext
        let p = UserProfile()
        p.onboardingDone = true
        ctx.insert(p)
        let ws = wednesday.weekStart
        let tomorrow = PlanItem(day: wednesday.adding(days: 1), weekStart: ws, kind: .aerobic, title: "快走", minutes: 30, intensity: .easy)
        ctx.insert(tomorrow)
        try ctx.save()
        DataHub.regenerateWeekPlan(in: ctx, now: wednesday)
        #expect(DataHub.planItems(weekStart: ws, in: ctx).count == 1, "no plan is made for someone who only records, and none is deleted")
    }

    @Test func unknownAgeGivesNoHeartRateNumbers() {
        var p = ProfileSnapshot()
        p.age = 0
        #expect(!PlanGenerator.guidance(.hard, p).contains("bpm"))
        #expect(PlanGenerator.guidance(.hard, p).contains("出生年份"))
        #expect(HRZones.zones(profile: p).zones.isEmpty)
        p.age = 40
        #expect(PlanGenerator.guidance(.hard, p).contains("bpm"))
        #expect(HRZones.zones(profile: p).zones.count == 5)
    }

    @Test func glucoseGoalsAreNeverAboveTheBaseline() {
        var p = ProfileSnapshot()
        p.age = 45
        #expect(TargetTracker.goal(.postMealGlucose, baseline: 2.0, profile: p) == 2.0, "already healthy: stay there")
        #expect(TargetTracker.goal(.postMealGlucose, baseline: 9.0, profile: p) == 6.0, "a third less")
        #expect(TargetTracker.goal(.postMealGlucose, baseline: 4.06, profile: p) <= 4.06)
        #expect(TargetTracker.goal(.fastingGlucose, baseline: 5.0, profile: p) == 5.0)
        #expect(TargetTracker.goal(.fastingGlucose, baseline: 7.0, profile: p) == 6.5)
    }

    @Test func weeklyDistanceIsTheShareOfThePlan() {
        let monday = wednesday.weekStart
        var p = ProfileSnapshot()
        p.age = 40
        p.race = RaceInfo(name: "城市马拉松", date: monday.adding(days: 7 * 16), targetMinutes: nil, startDate: monday.adding(days: -7 * 4),
                          currentWeeklyKm: 30, longestRunKm: 16, fuelCarbsPerHour: 60)
        let planned = MarathonPlanner.week(profile: p, race: p.race!, weekStart: monday).weeklyKm
        let runs = [WorkoutPoint(start: monday.adding(days: 1).adding(minutes: 7 * 60), type: .run, minutes: 60, distanceKm: planned / 2),
                    WorkoutPoint(start: monday.adding(days: 5).adding(minutes: 7 * 60), type: .run, minutes: 60, distanceKm: planned / 2)]
        let r = TargetTracker.reading(.weeklyRunKm, days: [], vitals: [], workouts: runs, end: monday.adding(days: 7), profile: p)
        #expect(r.value.map { abs($0 - 100) < 0.01 } == true, "the plan's distance, all of it")
        #expect(r.plannedKm == planned && r.runKm.map { abs($0 - planned) < 0.01 } == true)
        #expect(TargetTracker.goal(.weeklyRunKm, baseline: 25, profile: p) == 90, "90% of the plan, whatever was run before")
        #expect(TargetTracker.reached(.weeklyRunKm, value: r.value, goal: 90))
        let input = ProgramPlanInput(pack: .event, target: .weeklyRunKm, round: 1, roundStart: monday)
        let x = ProgramEvaluator.Input(program: input, profile: p, days: [], workouts: runs, vitals: [], plan: [], targetGoal: TargetGoal(target: .weeklyRunKm, goal: 90))
        let week = ProgramEvaluator.week(x, weekStart: monday, now: monday.adding(days: 7))
        #expect(week.change == nil && !week.beyondNoise, "no baseline to compare a share of the plan with")
        #expect(week.targetLine.contains("完成计划的 100%"), "\(week.targetLine)")
        #expect(TargetTracker.reading(.weeklyRunKm, days: [], vitals: [], workouts: runs, end: monday.adding(days: 7)).value == nil,
                "without a race there is no plan to measure against")
    }

    @Test func theRoundsFirstWeekGetsItsStepTarget() throws {
        let container = try memory()
        let ctx = container.mainContext
        let monday = wednesday.adding(days: 5).weekStart
        let p = UserProfile()
        p.onboardingDone = true
        p.birthYear = 1985
        p.stepsTarget = 8000
        p.programPhase = .improve
        p.programRoundStart = monday
        let input = ProgramPlanInput(pack: .cardio, target: .restingHR, round: 1, roundStart: monday, baselineSteps: 6000)
        p.programPlanData = try JSONEncoder().encode(input)
        ctx.insert(p)
        // The round's first week was made in advance, so the week's plan is already there on Monday.
        ctx.insert(PlanItem(day: monday.adding(days: 2), weekStart: monday, kind: .aerobic, title: "快走", minutes: 30, intensity: .easy))
        try ctx.save()
        DataHub.ensureWeekPlan(in: ctx, now: monday.adding(minutes: 10 * 60))
        #expect(p.stepsTarget == 7000, "6000 at baseline, 1000 more in week 1")
        #expect(DataHub.programStepsTarget(p, weekStart: monday.adding(days: -7)) == nil, "not before the round begins")
    }

    @Test func aPastWeeksChatRecordsAtTheRealTime() {
        let past = wednesday.adding(days: -10)
        var c = AgentContext.make(profile: ProfileSnapshot(), name: "", days: [], plan: [], workouts: [], vitals: [], events: [], stopBang: [],
                                  baselineSetAt: nil, raceName: "", now: past)
        c.liveNow = wednesday
        let walked = HealthAgent.reply(to: "刚快走了40分钟", context: c)
        let record = walked.blocks.compactMap(\.record).first
        #expect(record.map { Calendar.pulse.isDate($0.time, inSameDayAs: wednesday) } == true, "recorded today, not on the past week's day")
        let plan = HealthAgent.reply(to: "帮我调整这周的训练计划", context: c)
        #expect(plan.text.contains("过去一周") && plan.blocks.isEmpty, "no plan change from a past week")
    }

    @Test func typedNumbersKeepTheirDecimalPoint() {
        #expect(NumberField.parse("65.") == 65)
        #expect(NumberField.parse("65.5") == 65.5)
        #expect(NumberField.parse("65,5") == 65.5)
        #expect(NumberField.parse("") == nil)
    }

    @Test func onlyTheFirstFiveProposalsTakeTheWrittenReasons() {
        let items = ["a", "b", "c", "d", "e", "下周调整的说明"]
        let p = CoachProposal(id: "drop-5", icon: "calendar", title: "周四改为日常活动日", rationale: "近 6 周周四 4 次没完成。",
                              action: .dropWeekday(5), adoptLabel: "采纳")
        #expect(WeeklyAgentReview.rationale(items, proposal: p, index: 1) == "b")
        #expect(WeeklyAgentReview.rationale(items, proposal: p, index: 5) == p.rationale, "the sixth item is a next-week change")
    }
}
