import Foundation
import Testing
@testable import Pulse

private let monday = Calendar.pulse.date(from: DateComponents(year: 2026, month: 10, day: 19, hour: 0))!

/// The page check of 2026-11-09: a week with no full day yet judges nothing, the Health Agent looks back a
/// week on Mondays, a missing fitness estimate is still to do, and rank answers only promise causes they give.
@Suite("Program page check")
@MainActor
struct ProgramPageCheckTests {
    private func profile() -> ProfileSnapshot {
        var p = ProfileSnapshot()
        p.age = 45; p.sex = .male; p.level = .moderate
        p.availableWeekdays = [2, 4, 6]
        p.sessionMinutes = 45
        p.weeklyTargetMinutes = 150
        return p
    }

    private func input(_ target: TargetMetric) -> ProgramPlanInput {
        ProgramPlanInput(pack: .cardio, target: target, round: 1, roundStart: monday, weeks: 4, baselineSteps: 6000,
                         baselineMinutes: 60, vo2Band: RankBand.lowerMid.rawValue)
    }

    private func days(from start: Date, count: Int) -> [DayData] {
        (0..<count).map { i in
            var d = DayData(day: start.adding(days: i))
            d.rhr = 70; d.steps = 9000; d.sleepMinutes = 420
            return d
        }
    }

    private func sessions(weeks: Int) -> [SessionSnapshot] {
        (0..<(weeks * 7)).compactMap { i in
            guard i % 7 == 1 || i % 7 == 3 || i % 7 == 5 else { return nil }
            return SessionSnapshot(id: UUID(), day: monday.adding(days: i), kind: .aerobic, title: "快走", minutes: 30, minimumMinutes: 10,
                                   minimumDetail: "", intensity: .easy, isKey: false, status: .done, completedMinutes: 30)
        }
    }

    private func context(now: Date) -> AgentContext {
        var p = profile()
        p.program = input(.restingHR)
        p.programPhase = .improve
        var c = AgentContext.make(profile: p, name: "", days: days(from: monday.adding(days: -14), count: 24), plan: sessions(weeks: 2),
                                  workouts: [], vitals: [], events: [], stopBang: [], baselineSetAt: nil, raceName: "", now: now)
        c.program = AgentProgram(phase: .improve, pack: .cardio, goal: TargetGoal(target: .restingHR, baseline: 72, goal: 70),
                                 round: 1, roundStart: monday, weeks: 4, baselineStart: monday.adding(days: -7))
        return c
    }

    @Test func aWeekWithNoFullDayYetJudgesNothing() {
        let x = ProgramEvaluator.Input(program: input(.homeBP), profile: profile(), days: days(from: monday.adding(days: -14), count: 15),
                                       workouts: [], vitals: [], plan: sessions(weeks: 1), targetGoal: TargetGoal(target: .homeBP, baseline: 140, goal: 135))
        let w = ProgramEvaluator.week(x, weekStart: monday, now: monday.adding(minutes: 630))
        #expect(w.met, "no reading can be due on the week's first morning")
        #expect(w.next.contains("还没有到期的训练") && !w.next.contains("完成得好"), "\(w.next)")
    }

    @Test func midweekAsksOnlyForTheShareOfTheWeekSoFar() {
        #expect([0, 2, 3, 4, 5, 7].map { ProgramEvaluator.due(3, elapsed: $0) } == [0, 0, 1, 1, 2, 3])
        #expect([3, 4, 7].map { ProgramEvaluator.due(2, elapsed: $0) } == [0, 1, 2])
        #expect(ProgramEvaluator.due(5, elapsed: 7) == 5, "the whole week still asks for all of it")
        let x = ProgramEvaluator.Input(program: input(.homeBP), profile: profile(), days: days(from: monday.adding(days: -14), count: 17),
                                       workouts: [], vitals: [], plan: sessions(weeks: 1), targetGoal: TargetGoal(target: .homeBP, baseline: 140, goal: 135))
        let wednesday = ProgramEvaluator.week(x, weekStart: monday, now: monday.adding(days: 2).adding(minutes: 630))
        #expect(wednesday.checks.first { $0.title == "测血压" }?.met == true, "no reading is due before Thursday")
        let sunday = ProgramEvaluator.week(x, weekStart: monday, now: monday.adding(days: 7))
        #expect(sunday.checks.first { $0.title == "测血压" }?.met == false)
    }

    @Test func onMondayTheAgentTalksAboutLastWeek() {
        let first = HealthAgent.reply(to: "这周方案完成得怎么样？", context: context(now: monday.adding(minutes: 630)))
        #expect(first.text.hasPrefix("这一轮今天才开始"), "\(first.text)")
        let second = HealthAgent.reply(to: "这周方案完成得怎么样？", context: context(now: monday.adding(days: 7).adding(minutes: 630)))
        #expect(second.text.hasPrefix("上周的方案做到了。"), "\(second.text)")
        #expect(second.text.contains("第 1/4 周") && second.text.contains("上周完成得好：这周小幅加量"), "\(second.text)")
        let midweek = HealthAgent.reply(to: "这周方案完成得怎么样？", context: context(now: monday.adding(days: 9).adding(minutes: 630)))
        #expect(midweek.text.hasPrefix("这周的方案") && midweek.text.contains("第 2/4 周"), "\(midweek.text)")
    }

    @Test func aMissingFitnessEstimateIsStillToDo() {
        let x = BaselineInput(profile: profile(), days: days(from: monday, count: 2), workouts: [], vitals: [],
                              window: DateInterval(start: monday, end: monday.adding(days: 2)))
        let todo = BaselineAssessment.assess(x).completeness.stillToDo(daysLeft: 5).map(\.label)
        #expect(todo == ["心肺能力估算"], "readings the watch keeps adding aren't listed: \(todo)")
    }

    @Test func rankAnswersOnlyPromiseCausesTheyGive() {
        var c = context(now: monday.adding(days: 9).adding(minutes: 630))
        var p = c.profile
        p.age = 45
        let window = DateInterval(start: monday.adding(days: -14), end: monday)
        let worse = (0..<14).map { i in
            var d = DayData(day: monday.adding(days: -14 + i))
            d.rhr = 80; d.steps = 9000; d.sleepMinutes = 420; d.vo2Max = i % 5 == 0 ? 32 : nil
            return d
        }
        let report = BaselineAssessment.assess(BaselineInput(profile: p, days: worse, workouts: [], vitals: [], window: window))
        c.program?.report = report
        c.program?.concerns = []
        let text = HealthAgent.reply(to: "我的排名为什么靠后？", context: c).text
        #expect(!text.contains("可能和这些有关"))
        #expect(!text.contains("下面是可能的原因"), "\(text)")
    }
}
