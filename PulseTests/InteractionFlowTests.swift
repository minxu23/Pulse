import Foundation
import SwiftData
import Testing
@testable import Pulse

@Suite("交互流程与资料完整性")
@MainActor
struct InteractionFlowTests {
    @Test func aNewProfileHasNoFabricatedMeasurementsOrTrainingGoal() {
        let p = UserProfile()
        #expect(p.birthYear == 0 && p.heightCm == 0 && p.weightKg == 0)
        #expect(!p.hasAge && !p.hasBodySize && p.bmi == 0)
        #expect(p.usageIntent == .recording && p.goals.isEmpty)
        #expect(!p.canStartImprovement && !p.healthBackgroundReviewed)
        #expect(!p.basicsSummary.contains("BMI 0"))
    }

    @Test func testingMustBeEnteredExplicitlyAndExitingPreservesAnInMemoryProfile() throws {
        let suite = "interaction.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set("own-\(suite).store", forKey: DataStores.ownKey)
        defaults.set("sample-\(suite).store", forKey: DataStores.sampleKey)
        defaults.set("own", forKey: DataStores.modeKey)
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let stores = DataStores(defaults: defaults, arguments: ["-PulseInMemory"])
        let mine = UserProfile()
        mine.nickname = "原档案"; mine.birthYear = 1980; mine.weightKg = 70
        stores.container.mainContext.insert(mine)
        stores.use(.sample)
        #expect(stores.mode == .own && !stores.testingEnabled)
        stores.enterTesting()
        let sample = UserProfile(); sample.nickname = "示例"; sample.usesDemoData = true
        stores.container.mainContext.insert(sample)
        stores.exitTesting()
        let returned = try #require(DataHub.profile(in: stores.container.mainContext))
        #expect(stores.mode == .own && !stores.testingEnabled)
        #expect(returned.nickname == "原档案" && returned.birthYear == 1980 && returned.weightKg == 70)
        stores.use(.sample)
        #expect(stores.mode == .own)
    }

    @Test func unknownBasicsDoNotGeneratePeerRanksOrBMI() {
        let end = Date().startOfDay
        var p = ProfileSnapshot(); p.age = 0; p.sex = .unspecified; p.heightCm = 0; p.bmi = 0
        let days = (1...7).map { i in
            var d = DayData(day: end.adding(days: -i)); d.rhr = 65; d.vo2Max = 38; d.bodyFatPct = 25; d.steps = i == 1 ? 0 : 7000
            return d
        }.sorted { $0.day < $1.day }
        let r = BaselineAssessment.assess(BaselineInput(profile: p, days: days, workouts: [], vitals: [], meals: [], rhythmAlerts: [], window: DateInterval(start: end.adding(days: -7), end: end)))
        #expect(r.cards.flatMap(\.metrics).allSatisfy { $0.rank == nil })
        #expect(r.metric(.bmi)?.quality == .missing)
        #expect(!r.habits.zonesReliable)
        #expect(r.habits.stepsMean == 6000, "a measured zero must remain in the daily mean")
    }

    @Test func incompleteSafetyCannotStartAndChangingPacksKeepsHistory() throws {
        let c = try ModelContainer(for: Schema(PulseSchema.models), configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        let ctx = c.mainContext
        let now = Calendar.pulse.date(from: DateComponents(year: 2026, month: 11, day: 4, hour: 20))!
        DemoDataGenerator.populate(ctx, persona: .xiaolin, now: now)
        let p = try #require(DataHub.profile(in: ctx))
        let result = DataHub.baseline(in: ctx, window: DataHub.historyWindow(now: now), now: now)
        p.programQuestionsDone = false; p.parqAnswers = []
        ProgramFlow.choose(.fitness, result: result, profile: p, in: ctx, now: now)
        #expect(p.programPhase != .improve)
        #expect(try ctx.fetchCount(FetchDescriptor<ProgramSnapshot>()) == 0)
        p.programQuestionsDone = true; p.parqAnswers = Array(repeating: false, count: 7)
        let thisWeek = DataHub.planItems(weekStart: now.weekStart, in: ctx).map { ($0.id, $0.title) }
        ProgramFlow.choose(.fitness, result: result, profile: p, in: ctx, now: now)
        #expect(p.programPhase == .improve && p.programRound == 1)
        #expect(p.programRoundStart == now.weekStart.adding(days: 7))
        #expect(DataHub.planItems(weekStart: now.weekStart, in: ctx).map(\.id) == thisWeek.map(\.0))
        ProgramFlow.choose(.cardio, result: result, profile: p, in: ctx, now: now)
        #expect(p.programRound == 2 && p.programPack == .cardio)
        #expect(try ctx.fetchCount(FetchDescriptor<ProgramSnapshot>()) == 1, "switching packs keeps the one baseline report (Docs 6)")
    }

    @Test func reviewLeadsWithThePackTargetAndRecordingHasNoTrainingCompletion() {
        let metrics = [BriefMetric(name: "训练完成", icon: "", value: "0/3", unit: "次", delta: nil, trend: .none),
                       BriefMetric(name: "静息心率", icon: "", value: "65", unit: "bpm", delta: nil, trend: .none)]
        let target = TargetReading(target: .restingHR, value: 64)
        let improvement = ReviewPresentation.metrics(metrics, target: target, recording: false, steps: 6200, previousSteps: 6000)
        #expect(improvement.first?.value == "64")
        #expect(improvement.prefix(3).map(\.name) == [target.label, "训练完成", "日均步数"])
        #expect(improvement[2].value == "6200")
        #expect(improvement.filter { $0.name.contains("静息心率") }.count == 1)
        let recording = ReviewPresentation.metrics(metrics, target: target, recording: true)
        #expect(recording.count == 1 && recording.first?.name == "静息心率")
        let empty = ReviewPresentation.metrics([], target: TargetReading(target: .homeBP), recording: false)
        #expect(empty.first?.value == "未记录")
    }

    @Test func noActivityRecordIsDifferentFromARecordedZero() {
        let zero = BriefMetric(name: "活动", icon: "", value: "0", unit: "分钟", delta: "持平", trend: .flat)
        let unknown = ReviewPresentation.metrics([zero], target: nil, recording: true, activityKnown: false)
        #expect(unknown.first?.value == "未记录" && unknown.first?.delta == nil)
        #expect(ReviewPresentation.metrics([zero], target: nil, recording: true, activityKnown: true).first?.value == "0")
    }

    @Test func sampleConversationsDoNotReplacePersonalConversations() {
        let c = AgentConversation()
        c.messages = [AgentMessage(role: .user, text: "个人记录")]
        c.switchStore(from: "own", to: "sample")
        #expect(c.messages.isEmpty)
        c.messages = [AgentMessage(role: .user, text: "示例记录")]
        c.switchStore(from: "sample", to: "own")
        #expect(c.messages.map(\.text) == ["个人记录"])
        c.switchStore(from: "own", to: "sample")
        #expect(c.messages.map(\.text) == ["示例记录"])
    }

    @Test func aPastReviewPassesItsWeekEndToTheAgent() {
        let week = Date().startOfDay.weekStart.adding(days: -14)
        let scope = ReviewChatScope(weekStart: week)
        #expect(scope.referenceDate == week.adding(days: 7).addingTimeInterval(-1))
        #expect(scope.label.contains("复盘"))
    }

    @Test func clinicPressureFootnotesNameTheSystolicTargetAndMeasurementDate() {
        let r = TargetReading(target: .clinicBP, value: 140, value2: 85, count: 2, latest: Date().adding(days: -2))
        let text = TargetTracker.footnote(r, goal: TargetGoal(target: r.target, baseline: 145, goal: 135), now: Date())
        #expect(text.contains("基线收缩压 145") && text.contains("目标 ≤ 135") && text.contains("最近"))
    }
}
