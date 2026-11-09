import Foundation
import SwiftData
import Testing
@testable import Pulse

private let evening = Calendar.pulse.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 20))!
private let monday = evening.startOfDay.weekStart

/// Steps 4–5 of the 三阶段健康计划: pack weeks, main-target goals, weekly checks, the round's decision and
/// the flow from choosing a pack to the next round or the summary.
@Suite("三阶段计划: packs and rounds")
@MainActor
struct ProgramPlanTests {
    private func profile(age: Int = 45) -> ProfileSnapshot {
        var p = ProfileSnapshot()
        p.age = age; p.sex = .male; p.level = .moderate
        p.availableWeekdays = [2, 4, 6, 7]
        p.sessionMinutes = 45
        p.weeklyTargetMinutes = 150
        p.weeklyTimeBudget = 240
        return p
    }

    private func input(_ pack: ProgramPack, _ target: TargetMetric, sports: [SportHabit] = [], steps: Double? = 4426, start: Date = monday) -> ProgramPlanInput {
        ProgramPlanInput(pack: pack, target: target, round: 1, roundStart: start, weeks: 4, sports: sports,
                         baselineSteps: steps, baselineMinutes: 40, vo2Band: RankBand.lowerMid.rawValue)
    }

    @Test func stepsClimbFromTheBaselineToThePlateau() {
        let x = input(.cardio, .restingHR)
        #expect(PackPlanner.stepsTarget(x, age: 45, week: 1) == 5500, "4426 → 4500, plus 1000")
        #expect(PackPlanner.stepsTarget(x, age: 45, week: 4) == 8000, "capped where the benefit levels off")
        #expect(PackPlanner.stepsTarget(x, age: 65, week: 3) == 6000, "from 60 the plateau is 6000")
        #expect(PackPlanner.stepsTarget(input(.cardio, .restingHR, steps: 9300), age: 45, week: 2) == 9500, "already there: keep it")
        #expect(PackPlanner.stepsTarget(input(.cardio, .restingHR, steps: nil), age: 45, week: 2) == nil)
    }

    @Test func fitnessAddsIntervalsFromWeekTwo() {
        let p = profile()
        let w1 = PackPlanner.week(profile: p, input: input(.fitness, .vo2max), weekStart: monday)
        let w2 = PackPlanner.week(profile: p, input: input(.fitness, .vo2max), weekStart: monday.adding(days: 7))
        let w4 = PackPlanner.week(profile: p, input: input(.fitness, .vo2max), weekStart: monday.adding(days: 21))
        #expect(w1.sessions.filter { $0.kind == .quality }.isEmpty)
        #expect(w2.sessions.filter { $0.kind == .quality }.count == 1)
        #expect(w4.sessions.contains { $0.kind == .test && $0.title == "心肺复测" })
        #expect(w2.notes.first?.contains("第 1 轮 · 第 2 / 4 周") == true)
        #expect(w2.stepsTarget == 6500)
        // Intervals never on two days in a row.
        let q = w4.sessions.filter { $0.kind == .quality }.map { PlanGenerator.order($0.weekday) }.sorted()
        #expect(zip(q, q.dropFirst()).allSatisfy { $1 - $0 >= 2 })
        // A heart condition without the doctor's word: no intervals, and the plan says why.
        var heart = p
        heart.conditions = [.coronaryDisease]
        let capped = PackPlanner.week(profile: heart, input: input(.fitness, .vo2max), weekStart: monday.adding(days: 14))
        #expect(capped.sessions.allSatisfy { $0.intensity != .hard })
        #expect(capped.notes.contains { $0.contains("暂不安排高强度间歇") })
    }

    @Test func aBallGamePlayedHardCountsAsTheVigorousSession() {
        let tennis = SportHabit(type: .tennis, sessions: 8, perWeek: 2, minutes: 90, weekdays: [7], slot: .evening,
                                reserveShare: 0.68, vigorousShare: 0.55, intensity: .hard, recovery: 30)
        let w2 = PackPlanner.week(profile: profile(), input: input(.fitness, .vo2max, sports: [tennis]), weekStart: monday.adding(days: 7))
        let sat = w2.sessions.first { $0.weekday == 7 }
        #expect(sat?.title == "网球" && sat?.kind == .quality && sat?.minutes == 90)
        #expect(sat?.detail.contains("68%") == true)
        #expect(w2.sessions.filter { $0.kind == .quality }.count == 1, "tennis is week 2's one hard session")
        // Played easily, it is an aerobic session.
        var easy = tennis
        easy.intensity = .moderate
        let w = PackPlanner.week(profile: profile(), input: input(.cardio, .restingHR, sports: [easy]), weekStart: monday)
        #expect(w.sessions.first { $0.weekday == 7 }?.kind == .aerobic)
    }

    @Test func bloodPressureGetsWallSquatsOnSeparateDays() {
        let w = PackPlanner.week(profile: profile(), input: input(.cardio, .homeBP), weekStart: monday)
        let squats = w.sessions.filter { $0.detail.contains("靠墙静蹲") }
        #expect((1...3).contains(squats.count))
        #expect(w.notes.contains { $0.contains("每周 3 次靠墙静蹲") })
        #expect(w.sessions.contains { $0.title == "快走日" }, "aerobic on most days")
        var knee = profile()
        knee.conditions = [.jointPain]
        let k = PackPlanner.week(profile: knee, input: input(.cardio, .homeBP), weekStart: monday)
        #expect(k.sessions.contains { $0.detail.contains("静力握拳") } && !k.sessions.contains { $0.detail.contains("靠墙静蹲") })
    }

    @Test func metabolismWalksAfterDinner() {
        let w = PackPlanner.week(profile: profile(), input: input(.metabolic, .weight), weekStart: monday)
        #expect(w.sessions.contains { $0.title == "饭后散步" })
        #expect(w.notes.contains { $0.contains("晚饭后走 10–15 分钟") })
    }

    @Test func raceWeeksComeFromTheMarathonPlan() {
        var p = profile()
        p.race = RaceInfo(name: "无锡马拉松", date: monday.adding(days: 120), targetMinutes: 240, startDate: monday,
                          currentWeeklyKm: 30, longestRunKm: 16, fuelCarbsPerHour: 45)
        let w = PackPlanner.week(profile: p, input: input(.event, .weeklyRunKm), weekStart: monday)
        #expect(w.marathon != nil)
        #expect(w.notes.first?.contains("关键事件准备") == true)
    }

    @Test func goalsAreWhatFourWeeksCanMove() {
        let p = profile()
        #expect(TargetTracker.goal(.vo2max, baseline: 40, profile: p) == 42, "+5%")
        #expect(TargetTracker.goal(.vo2max, baseline: 20, profile: p) == 21.5, "at least +1.5, beyond the watch's scatter")
        #expect(TargetTracker.goal(.restingHR, baseline: 75, profile: p) == 72)
        #expect(TargetTracker.goal(.restingHR, baseline: 64, profile: p) == 62)
        // 「降 5 mmHg，或降到医生的目标、135 以下」: whichever is reached first, the nearer one.
        #expect(TargetTracker.goal(.homeBP, baseline: 141, profile: p) == 136, "5 lower comes before the home line")
        #expect(TargetTracker.goal(.homeBP, baseline: 150, profile: p) == 145, "not 16 lower")
        #expect(TargetTracker.goal(.homeBP, baseline: 137, profile: p) == 134, "under 135 comes first")
        var treated = p
        treated.conditions = [.hypertension]
        treated.bpTargetSys = 130
        #expect(TargetTracker.goal(.homeBP, baseline: 150, profile: treated) == 145)
        #expect(TargetTracker.goal(.homeBP, baseline: 133, profile: treated) == 130, "the doctor's target is nearer")
        #expect(TargetTracker.goal(.homeBP, baseline: 128, profile: treated) == 128, "already under the target: stay there")
        #expect(TargetTracker.goal(.clinicBP, baseline: 150, profile: p) == 140, "sparse readings: 10 mmHg")
        #expect(TargetTracker.goal(.clinicBP, baseline: 138, profile: p) == 134, "or under the line")
        #expect(TargetTracker.goal(.weight, baseline: 88, profile: p) == 86.2)
        // 「提高 5 个百分点，最多到 70%」.
        #expect(TargetTracker.goal(.cgmTIR, baseline: 60, profile: p) == 65)
        #expect(TargetTracker.goal(.cgmTIR, baseline: 67, profile: p) == 70)
        #expect(TargetTracker.goal(.cgmTIR, baseline: 78, profile: p) == 78, "already above 70%: stay there")
        #expect(TargetTracker.reached(.homeBP, value: 133, goal: 134) && !TargetTracker.reached(.vo2max, value: 41, goal: 42))
    }

    // MARK: Weeks and rounds

    private func days(_ n: Int, rhr: (Int) -> Double, steps: Int = 9000) -> [DayData] {
        (0..<n).map { i in
            var d = DayData(day: monday.adding(days: i - 14))
            d.rhr = rhr(i); d.steps = steps
            return d
        }
    }

    private func plan(weeks: Int, done: Bool) -> [SessionSnapshot] {
        (0..<(weeks * 7)).compactMap { i in
            guard i % 7 == 1 || i % 7 == 3 || i % 7 == 5 else { return nil }
            return SessionSnapshot(id: UUID(), day: monday.adding(days: i), kind: .aerobic, title: "快走", minutes: 30, minimumMinutes: 10,
                                   minimumDetail: "", intensity: .easy, isKey: false, status: done ? .done : .skipped, completedMinutes: done ? 30 : nil)
        }
    }

    private func evaluator(rhrDrop: Double, done: Bool, target: TargetMetric = .restingHR, vitals: [VitalPoint] = []) -> ProgramEvaluator.Input {
        var x = input(.cardio, target, steps: 6000)
        x.roundStart = monday
        return ProgramEvaluator.Input(program: x, profile: profile(),
                                      days: days(14 + 28, rhr: { i in i < 14 ? 76 : 76 - rhrDrop * Double(i - 14) / 28 }),
                                      workouts: [], vitals: vitals, plan: plan(weeks: 4, done: done), targetGoal: TargetGoal(target: target, baseline: 76, goal: 73))
    }

    @Test func weekChecksAndTheTargetAgainstItsNoise() {
        let x = evaluator(rhrDrop: 6, done: true)
        let w3 = ProgramEvaluator.week(x, weekStart: monday.adding(days: 14), now: monday.adding(days: 21))
        #expect(w3.week == 3)
        #expect(w3.checks.first { $0.title == "训练" }?.met == true)
        #expect(w3.checks.first { $0.title == "步数" }?.met == true)
        #expect(w3.met)
        #expect(w3.change != nil && w3.change! < -3)
        #expect(w3.beyondNoise && w3.targetLine.contains("是真的在变好"))
        let small = ProgramEvaluator.week(evaluator(rhrDrop: 2, done: true), weekStart: monday, now: monday.adding(days: 7))
        #expect(!small.beyondNoise && small.targetLine.contains("还在平时的波动范围内"))
        let missed = ProgramEvaluator.week(evaluator(rhrDrop: 6, done: false), weekStart: monday, now: monday.adding(days: 7))
        #expect(!missed.met && missed.next.contains("减量约 15%"))
    }

    @Test func theRoundEndsInOneOfFourWays() {
        let end = monday.adding(days: 28)
        #expect(ProgramEvaluator.round(evaluator(rhrDrop: 6, done: true), now: end.adding(days: -1)) == nil, "not over yet")
        #expect(ProgramEvaluator.round(evaluator(rhrDrop: 6, done: true), now: end)?.outcome == .achieved)
        #expect(ProgramEvaluator.round(evaluator(rhrDrop: 1, done: true), now: end)?.outcome == .slowResponse)
        #expect(ProgramEvaluator.round(evaluator(rhrDrop: 6, done: false), now: end)?.outcome == .lowAdherence)
        let none = ProgramEvaluator.round(evaluator(rhrDrop: 6, done: true, target: .clinicBP), now: end)
        #expect(none?.outcome == .notEnoughReadings && none?.next.contains("社区卫生服务中心") == true)
    }

    // MARK: The flow on a sample user

    @Test func choosingAPackStartsRoundOneAndItsPlan() throws {
        let container = try ModelContainer(for: Schema(PulseSchema.models), configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        let ctx = container.mainContext
        DemoDataGenerator.populate(ctx, persona: .chenjie, now: evening)
        let p = DataHub.profile(in: ctx)!
        ProgramFlow.startBaseline(p, in: ctx, now: evening)
        #expect(p.programPhase == .baseline)
        #expect(ProgramFlow.status(p, in: ctx, now: evening).reportReady, "120 days of history: the report is ready at once")
        let result = DataHub.baseline(in: ctx, window: ProgramFlow.baselineWindow(p, now: evening), now: evening)
        p.programQuestionsDone = true
        p.parqAnswers = Array(repeating: false, count: 7)
        let preview = ProgramFlow.preview(.cardio, result: result, profile: p.snapshot(medications: []), now: evening)
        ProgramFlow.choose(.cardio, result: result, profile: p, in: ctx, now: evening)
        #expect(p.programPhase == .improve && p.programRound == 1)
        #expect(p.programTarget == .homeBP)
        #expect(p.programTargetBaseline != nil && p.programTargetGoal != nil && p.programTargetGoal! < p.programTargetBaseline!)
        #expect(Calendar.pulse.component(.weekday, from: p.programRoundStart!) == 2, "rounds start on a Monday")
        #expect(ProgramFlow.baselineSnapshot(in: ctx)?.report.window == result.report.window, "the report is frozen")
        let items = DataHub.planItems(weekStart: p.programRoundStart!, in: ctx)
        let actualMinutes = items.filter { $0.kind.isTraining }.map(\.minutes).reduce(0, +)
        let previewMinutes = preview.sessions.filter { $0.kind.isTraining }.map(\.minutes).reduce(0, +)
        #expect(actualMinutes == previewMinutes, "the confirmation shows the plan that will actually start")
        #expect(items.contains { $0.detail.contains("靠墙静蹲") || $0.title == "快走日" }, "the effective week follows the pack")
        #expect(DataHub.analytics(in: ctx, now: evening).profile.program?.pack == .cardio)

        // The round ends short of the goal: round 2 starts on the next Monday with the same target.
        let r = ProgramRoundResult(outcome: .slowResponse, round: 1, weeksMet: 3, weeksCounted: 4, baseline: 140, value: 137, goal: 134,
                                   headline: "", detail: "", next: "")
        ProgramFlow.finishRound(r, profile: p, in: ctx, now: evening.adding(days: 28))
        #expect(p.programPhase == .improve && p.programRound == 2)
        #expect(DataHub.analytics(in: ctx, now: evening).profile.program?.round == 2)
        #expect(ProgramFlow.roundResults(in: ctx).count == 1)
        // An achieved round leads to the summary.
        var won = r
        won.outcome = .achieved
        won.round = 2
        ProgramFlow.finishRound(won, profile: p, in: ctx, now: evening.adding(days: 56))
        #expect(p.programPhase == .summary)
    }
}
