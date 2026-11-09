import Foundation
import SwiftData
import Testing
@testable import Pulse

private let monday = Calendar.pulse.date(from: DateComponents(year: 2026, month: 10, day: 19, hour: 0))!

/// The spec review of 2026-11-09 (Docs/三阶段健康计划设计.md): safety questions and the doctor's go-ahead,
/// goals, rounds that stretch or end with the race, the plan's personal rules, 摸底周, 总结期, the program's
/// own questions to the Health Agent, and the review's 最难坚持 question.
@Suite("Spec review fixes")
@MainActor
struct SpecFindingsTests {
    private func memory() throws -> ModelContainer {
        try ModelContainer(for: Schema(PulseSchema.models), configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    private func profile(age: Int = 45) -> ProfileSnapshot {
        var p = ProfileSnapshot()
        p.age = age; p.sex = .male; p.level = .moderate
        p.availableWeekdays = [2, 4, 6, 7]
        p.sessionMinutes = 45
        p.weeklyTargetMinutes = 150
        p.weeklyTimeBudget = 240
        return p
    }

    private func input(_ pack: ProgramPack, _ target: TargetMetric) -> ProgramPlanInput {
        ProgramPlanInput(pack: pack, target: target, round: 1, roundStart: monday, weeks: 4, baselineSteps: 6000,
                         baselineMinutes: 60, vo2Band: RankBand.lowerMid.rawValue)
    }

    private func days(from start: Date, count: Int, ill: (Int) -> Bool = { _ in false }) -> [DayData] {
        (0..<count).map { i in
            var d = DayData(day: start.adding(days: i))
            d.rhr = 70; d.steps = 9000
            if ill(i) { d.tags = [.illness] }
            return d
        }
    }

    private func sessions(weeks: Int, done: Bool) -> [SessionSnapshot] {
        (0..<(weeks * 7)).compactMap { i in
            guard i % 7 == 1 || i % 7 == 3 || i % 7 == 5 else { return nil }
            return SessionSnapshot(id: UUID(), day: monday.adding(days: i), kind: .aerobic, title: "快走", minutes: 30, minimumMinutes: 10,
                                   minimumDetail: "", intensity: .easy, isKey: false, status: done ? .done : .skipped, completedMinutes: done ? 30 : nil)
        }
    }

    // MARK: Safety

    @Test func anyYesInTheSafetyQuestionsAsksForADoctorFirst() {
        var p = profile()
        p.parqAnswers = [false, false, false, false, true, false, false]
        let x = BaselineInput(profile: p, days: [], workouts: [], vitals: [], window: DateInterval(start: monday, end: monday.adding(days: 7)))
        let r = BaselineAssessment.assess(x)
        #expect(r.dangerKinds == [.parq], "a prescription for a chronic condition counts too")
        #expect(r.redFlags.first?.contains("服用慢性病处方药") == true)
        #expect(ProgramPacks.recommend(r, profile: p).doctorFirst)
        // A heart condition said in the questions caps the intensity, and joints get low-impact sessions.
        p.parqAnswers = [true, false, false, false, false, true, false]
        #expect(p.cardiacLimited && p.jointIssues)
        p.clinicianCleared = true
        #expect(!p.cardiacLimited, "only the doctor-confirmed intensity setting lifts the cap")
        let w = PackPlanner.week(profile: { var q = profile(); q.parqAnswers = [true, false, false, false, false, true, false]; return q }(),
                                 input: input(.fitness, .vo2max), weekStart: monday.adding(days: 14))
        #expect(w.sessions.allSatisfy { $0.intensity != .hard }, "no intervals without the doctor's word")
        #expect(w.notes.contains { $0.contains("低冲击") })
    }

    @Test func aDoctorsGoAheadCoversTheSignsItWasGivenFor() throws {
        let container = try memory()
        let p = UserProfile()
        container.mainContext.insert(p)
        var r = BaselineAssessment.assess(BaselineInput(profile: ProfileSnapshot(), days: [], workouts: [], vitals: [],
                                                        window: DateInterval(start: monday, end: monday.adding(days: 7))))
        r.redFlags = ["运动前安全问题"]
        r.redFlagKinds = [RedFlag.Kind.parq.rawValue]
        #expect(ProgramFlow.doctorStillNeeded(p, r))
        ProgramFlow.confirmDoctor(p, r)
        #expect(!ProgramFlow.doctorStillNeeded(p, r))
        #expect(!p.clinicianCleared, "starting the program does not lift the care limits on intensity")
        r.redFlags.append("心律提示")
        r.redFlagKinds?.append(RedFlag.Kind.rhythm.rawValue)
        #expect(ProgramFlow.doctorStillNeeded(p, r), "a new danger sign asks again")
    }

    // MARK: Rounds

    @Test func weeksOfIllnessStretchTheRoundByTwoAtMost() {
        let x = ProgramEvaluator.Input(program: input(.cardio, .restingHR), profile: profile(),
                                       days: days(from: monday.adding(days: -14), count: 14 + 49) { i in
                                           // Weeks 2, 3 and 4 of the round each have 3 days of illness.
                                           let d = i - 14
                                           return d >= 7 && d < 28 && d % 7 < 3
                                       },
                                       workouts: [], vitals: [], plan: sessions(weeks: 7, done: true), baseline: 70, goal: 68)
        #expect(ProgramEvaluator.roundWeeks(x, now: monday.adding(days: 7)) == 4, "nothing excused yet")
        #expect(ProgramEvaluator.roundWeeks(x, now: monday.adding(days: 14)) == 5)
        #expect(ProgramEvaluator.roundWeeks(x, now: monday.adding(days: 49)) == 6, "at most 2 more weeks")
        #expect(ProgramEvaluator.round(x, now: monday.adding(days: 28)) == nil, "the stretched round isn't over at 4 weeks")
        #expect(ProgramEvaluator.round(x, now: monday.adding(days: 42)) != nil)
        #expect(ProgramEvaluator.week(x, weekStart: monday.adding(days: 7), now: monday.adding(days: 14)).next.contains("顺延一周"))
    }

    @Test func theThirdRoundInARowWithoutTheGoalSuggestsANewBaseline() {
        var x = ProgramEvaluator.Input(program: input(.cardio, .restingHR), profile: profile(),
                                       days: days(from: monday.adding(days: -14), count: 42), workouts: [], vitals: [],
                                       plan: sessions(weeks: 4, done: false), baseline: 70, goal: 68,
                                       hardest: ["步数", "步数", "周二的训练"])
        let first = ProgramEvaluator.round(x, now: monday.adding(days: 28))
        #expect(first?.suggestsReassessment == nil)
        #expect(first?.detail.contains("最难坚持的是步数（2 周）") == true, "\(first?.detail ?? "")")
        x.missedBefore = 2
        let third = ProgramEvaluator.round(x, now: monday.adding(days: 28))
        #expect(third?.suggestsReassessment == true && third?.next.contains("连续 3 轮") == true)
    }

    @Test func clinicReadingsNeedEveryWeekAndUseTheLastTwoWeeks() {
        func bp(_ day: Int, _ v: Double) -> VitalPoint {
            VitalPoint(time: monday.adding(days: day).adding(minutes: 9 * 60), kind: .bloodPressure, value: v, value2: 85, context: .random)
        }
        // Two readings a week, as the pack asks, except week 3.
        let base = ProgramEvaluator.Input(program: input(.cardio, .clinicBP), profile: profile(),
                                          days: days(from: monday.adding(days: -14), count: 42), workouts: [],
                                          vitals: [bp(1, 150), bp(3, 148), bp(8, 147), bp(10, 146), bp(22, 139), bp(25, 135)],
                                          plan: sessions(weeks: 4, done: true), baseline: 150, goal: 140)
        #expect(ProgramEvaluator.round(base, now: monday.adding(days: 28))?.outcome == .notEnoughReadings, "week 3 has no reading")
        var full = base
        full.vitals += [bp(15, 144), bp(17, 142)]
        let r = ProgramEvaluator.round(full, now: monday.adding(days: 28))
        #expect(r?.value == 140, "the mean of weeks 3–4, not the last single reading (135)")
        #expect(r?.outcome == .achieved)
    }

    @Test func theEventPackFollowsTheRace() {
        var p = profile()
        p.race = RaceInfo(name: "城市马拉松", date: monday.adding(days: 7 * 10), targetMinutes: nil, startDate: monday.adding(days: -14),
                          currentWeeklyKm: 30, longestRunKm: 16, fuelCarbsPerHour: 60)
        let x = ProgramEvaluator.Input(program: input(.event, .weeklyRunKm), profile: p, days: days(from: monday.adding(days: -14), count: 120),
                                       workouts: [], vitals: [], plan: sessions(weeks: 4, done: true), baseline: nil, goal: 90)
        let check = ProgramEvaluator.round(x, now: monday.adding(days: 28))
        #expect(check?.outcome == .phaseCheck, "every 4 weeks a look at the training phase, never 总结期 before the race")
        #expect(check?.next.contains("接下来是") == true)
        let done = ProgramEvaluator.round(x, now: monday.adding(days: 7 * 10 + 1))
        #expect(done?.outcome == .raceDone && done?.outcome.endsProgram == true)
    }

    // MARK: The plan

    @Test func theWeekFollowsTheUsersHabitsAndAge() {
        var x = input(.fitness, .vo2max)
        x.usualWeekdays = [3, 5, 1]
        x.mainSlot = .evening
        let w = PackPlanner.week(profile: profile(), input: x, weekStart: monday.adding(days: 14))
        let training = Set(w.sessions.filter { $0.kind.isTraining }.map(\.weekday))
        #expect([3, 5, 1].allSatisfy(training.contains), "the days they already exercise on")
        #expect(w.sessions.filter { $0.kind.isTraining }.allSatisfy { $0.detail.hasPrefix("建议傍晚练") })
        let older = PackPlanner.week(profile: profile(age: 68), input: input(.fitness, .vo2max), weekStart: monday.adding(days: 14))
        #expect(older.sessions.contains { $0.title == "快慢走交替" } && !older.sessions.contains { $0.title == "4×4 间歇" })
        var slow = input(.fitness, .vo2max)
        slow.slowRecovery = true
        #expect(PackPlanner.week(profile: profile(), input: slow, weekStart: monday.adding(days: 7)).sessions.allSatisfy { $0.kind != .quality },
                "slow heart-rate recovery: aerobic only in weeks 1–2")
        #expect(PackPlanner.week(profile: profile(), input: slow, weekStart: monday.adding(days: 14)).sessions.contains { $0.kind == .quality })
    }

    @Test func theSummaryKeepsTheEffortWithoutAddingMore() {
        var p = profile()
        p.programPhase = .summary
        p.availableWeekdays = [1, 2, 3, 4, 5, 6]
        let w = PackPlanner.week(profile: p, input: input(.fitness, .vo2max), weekStart: monday.adding(days: 56))
        #expect(w.sessions.filter { $0.kind.isTraining }.count <= 3, "2–3 core sessions a week")
        #expect(!w.sessions.contains { $0.title == "心肺复测" })
        #expect(w.stepsTarget == PackPlanner.stepsTarget(input(.fitness, .vo2max), age: 45, week: 4), "steps hold at the round's last week")
        #expect(w.notes.first?.hasPrefix("总结期") == true && w.notes.contains { $0.contains("不再加量") })
    }

    @Test func theBaselineWeekFindsOutInsteadOfTraining() throws {
        var p = profile()
        p.programPhase = .baseline
        let w = PlanGenerator.generate(profile: p, weekStart: monday)
        #expect(w.sessions.filter { $0.title == "户外快走或慢跑" }.count == 2)
        #expect(w.sessions.contains { $0.title == "力量自测（可选）" })
        #expect(w.sessions.allSatisfy { $0.intensity != .hard })
        #expect(w.notes.contains { $0.contains("体脂秤") })
        // Plans are made for everyone but those who only record.
        let container = try memory()
        let u = UserProfile()
        container.mainContext.insert(u)
        u.usageIntent = .recording
        #expect(!u.makesPlans)
        u.usageIntent = .cardio
        #expect(u.makesPlans, "outside the program the general plan still runs (Docs 8)")
    }

    // MARK: Switching and the monitor

    @Test func switchingPacksKeepsTheBaselineReport() throws {
        let container = try memory()
        let ctx = container.mainContext
        let evening = Calendar.pulse.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 20))!
        DemoDataGenerator.populate(ctx, persona: .chenjie, now: evening)
        let p = DataHub.profile(in: ctx)!
        ProgramFlow.startBaseline(p, in: ctx, now: evening)
        let result = DataHub.baseline(in: ctx, window: ProgramFlow.baselineWindow(p, now: evening), now: evening)
        p.programQuestionsDone = true
        p.parqAnswers = Array(repeating: false, count: ParQ.allCases.count)
        ProgramFlow.confirmDoctor(p, result.report)
        ProgramFlow.choose(.cardio, result: result, profile: p, in: ctx, now: evening)
        let frozen = ProgramFlow.baselineSnapshot(in: ctx)
        let later = evening.adding(days: 10)
        ProgramFlow.choose(.fitness, result: result, profile: p, in: ctx, now: later)
        #expect(p.programPack == .fitness && p.programRound == 2)
        #expect(ProgramFlow.baselineSnapshot(in: ctx) == frozen, "the baseline report stays as it was")
        let snapshots = try ctx.fetch(FetchDescriptor<ProgramSnapshot>()).filter { $0.reportKind == .baseline }
        #expect(snapshots.count == 1)
        #expect(ProgramFlow.startWindow(p, result: result, now: later) == DataHub.historyWindow(now: later), "the new start is the last 14 days")
    }

    @Test func aMonitorBoughtMidRoundSwitchesToHomeReadingsAtOnce() throws {
        let container = try memory()
        let ctx = container.mainContext
        let p = UserProfile()
        ctx.insert(p)
        p.programPhase = .improve
        p.programTargetRaw = TargetMetric.clinicBP.rawValue
        p.programTargetBaseline = 150
        p.programTargetGoal = 140
        p.programPlan = input(.cardio, .clinicBP)
        ProgramFlow.switchToHomeBP(p, in: ctx)
        #expect(p.programTarget == .homeBP && p.programPlan?.target == .homeBP && p.hasBPMonitor == true)
        #expect(p.programTargetBaseline == 150 && p.programTargetGoal == 145, "same baseline, the home goal")
    }

    // MARK: Strength

    @Test func theStrengthSelfTestRanksAgainstPeers() {
        var p = profile()
        let today = monday
        p.strengthTest = StrengthTest(pushups: 13, chairStands: nil, date: today)
        let m = BaselineAssessment.strength(p)
        #expect(m?.rank.map { abs($0.goodness - 40) < 0.5 } == true, "13 push-ups at 45 is the lower bound of 「good」 (P40)")
        p.age = 66; p.sex = .female
        p.strengthTest = StrengthTest(pushups: nil, chairStands: 11, date: today)
        #expect(BaselineAssessment.strength(p)?.rank.map { abs($0.goodness - 25) < 0.5 } == true, "11 chair stands at 66 is the 25th percentile")
        #expect(BaselineAssessment.strength(p)?.valueText == "30 秒坐站 11 次")
        // The generalised table keeps the five-knot tables as they were.
        #expect(PopulationNorms.vo2max.percentile(38.6, age: 35, sex: .male) == 50)
    }

    // MARK: Health Agent and review

    @Test func theAgentAnswersProgramQuestionsFromTheRules() {
        var p = profile()
        p.program = input(.cardio, .restingHR)
        p.programPhase = .improve
        var c = AgentContext.make(profile: p, name: "", days: days(from: monday.adding(days: -14), count: 24), plan: sessions(weeks: 2, done: true),
                                  workouts: [], vitals: [], events: [], stopBang: [], baselineSetAt: nil, raceName: "", now: monday.adding(days: 9).adding(minutes: 600))
        c.program = AgentProgram(phase: .improve, pack: .cardio, goal: TargetGoal(target: .restingHR, baseline: 72, goal: 70),
                                 round: 1, roundStart: monday, weeks: 4, baselineStart: monday.adding(days: -7))
        let week = HealthAgent.reply(to: "我现在第几周？", context: c)
        #expect(week.intent == .program && week.text.contains("第 1 轮第 2/4 周"), "\(week.text)")
        #expect(week.text.contains("主靶点静息心率") && week.text.contains("目标 ≤ 70"))
        let done = HealthAgent.reply(to: "这周方案完成得怎么样？", context: c)
        #expect(done.text.contains("训练：") && done.text.contains("下周："), "\(done.text)")
        let rank = HealthAgent.reply(to: "我的排名为什么靠后？", context: c)
        #expect(rank.intent == .program)
        c.program = nil
        #expect(HealthAgent.reply(to: "我现在第几周？", context: c).text.contains("还没有开始三阶段健康计划"))
    }

    @Test func theWeeklyReviewAsksWhatWasHardestToKeepUp() {
        let c = AgentContext.make(profile: profile(), name: "", days: [], plan: [], workouts: [], vitals: [], events: [], stopBang: [],
                                  baselineSetAt: nil, raceName: "", now: monday.adding(days: 6))
        let w = ReviewCoach.week(days: [], plan: [], weekStart: monday, span: 7, source: nil, now: monday.adding(days: 6))
        let report = ProgramWeekReport(week: 2, weeks: 4, checks: [BehaviorCheck(title: "训练", detail: "", met: true),
                                                                    BehaviorCheck(title: "步数", detail: "", met: false)],
                                       excused: false, target: TargetReading(target: .restingHR), change: nil, beyondNoise: false, targetLine: "", next: "")
        let step = ReviewCoach.reflection(context: c, week: w, program: report).first { $0.id == "change" }
        #expect(step?.question == "这周最难坚持的是哪一项？")
        #expect(step?.options.prefix(2) == ["步数", "训练"], "the goal missed this week comes first")
        #expect(ReviewCoach.reflection(context: c, week: w).first { $0.id == "change" }?.question == "哪些安排比较难坚持？")
    }
}
