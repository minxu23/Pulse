import Foundation
import Testing
@testable import Pulse

private let today = Calendar.pulse.date(from: DateComponents(year: 2026, month: 10, day: 19, hour: 0))!   // a Monday
private let window = DateInterval(start: today.adding(days: -14), end: today)

/// 睡眠改善, the fifth pack (Docs 3.7): who it is for, what stops it, its two main targets, the week's times
/// and the weekly checks. Also the age left out, which is now nil rather than 0.
@Suite("Sleep pack")
@MainActor
struct SleepPackTests {
    private func profile() -> ProfileSnapshot {
        var p = ProfileSnapshot()
        p.age = 40; p.sex = .male; p.bmi = 23; p.heightCm = 175; p.level = .moderate
        p.availableWeekdays = [2, 4, 6]
        p.sessionMinutes = 45
        p.weeklyTargetMinutes = 150
        return p
    }

    /// Nights of `hours` falling asleep at `bed` (minutes after midnight, past 24 h after midnight), every
    /// other night `swing` minutes later.
    private func nights(hours: Double, bed: Int = 23 * 60 + 30, swing: Int = 0, count: Int = 30, from end: Date = today) -> [DayData] {
        (0..<count).map { i in
            var d = DayData(day: end.adding(days: -count + i))
            let start = d.day.adding(days: -1).adding(minutes: bed + (i % 2 == 0 ? 0 : swing))
            d.sleepStart = start
            d.sleepEnd = start.adding(minutes: Int(hours * 60) + 15)
            d.sleepMinutes = hours * 60
            d.rhr = 60; d.hrv = 45; d.steps = 9000
            if i % 7 == 3 { d.vo2Max = 42 }
            return d
        }
    }

    private func report(_ p: ProfileSnapshot, _ days: [DayData]) -> BaselineReport {
        BaselineAssessment.assess(BaselineInput(profile: p, days: days, workouts: [], vitals: [], meals: [], rhythmAlerts: [], window: window))
    }

    private func input(_ target: TargetMetric, bed: Double = 24 * 60 + 30, wake: Double = 6 * 60 + 40, hours: Double = 6.2) -> ProgramPlanInput {
        ProgramPlanInput(pack: .sleep, target: target, round: 1, roundStart: today, weeks: 4, baselineSteps: 9000, baselineMinutes: 120,
                         bedtime: bed, wakeTime: wake, sleepHours: hours)
    }

    // MARK: Who it is for

    @Test func shortNightsGetTheSleepPackAboutHours() {
        let r = report(profile(), nights(hours: 6.2))
        let rec = ProgramPacks.recommend(r, profile: profile())
        #expect(rec.recommended.pack == .sleep, "\(rec.recommended)")
        #expect(rec.recommended.reason.contains("6.2 小时"))
        #expect(ProgramPacks.target(for: .sleep, report: r, profile: profile()) == .sleepDuration)
        #expect(r.habits.wakeMean != nil, "the habit profile has the usual wake time for the pack's schedule")
    }

    @Test func enoughSleepAtScatteredTimesGetsTheRegularityTarget() {
        let r = report(profile(), nights(hours: 7.5, swing: 150))
        #expect(r.metric(.sleepRegularity)?.verdict == .attention)
        #expect(ProgramPacks.qualifies(.sleep, r, profile())?.contains("入睡时间每天相差") == true)
        #expect(ProgramPacks.target(for: .sleep, report: r, profile: profile()) == .sleepRegularity)
        let steady = report(profile(), nights(hours: 7.5))
        #expect(ProgramPacks.qualifies(.sleep, steady, profile()) == nil, "enough sleep at steady times: nothing for the pack to do")
        #expect(ProgramPacks.recommend(steady, profile: profile()).alternatives.contains { $0.pack == .sleep }, "but it can still be chosen")
    }

    @Test func shiftsAndUntreatedBreathingProblemsComeFirst() {
        let r = report(profile(), nights(hours: 6.2))
        var shifts = profile()
        shifts.shift = ShiftSchedule(pattern: [.day, .day, .night, .night, .off, .off], cycleStart: today)
        #expect(ProgramPacks.blocker(.sleep, r, shifts)?.contains("倒班") == true)
        let rec = ProgramPacks.recommend(r, profile: shifts)
        #expect(rec.recommended.pack != .sleep && !rec.alternatives.contains { $0.pack == .sleep })
        #expect(rec.blocked.contains { $0.pack == .sleep }, "shown with why it can't start")
        var apnea = profile()
        apnea.conditions = [.sleepApnea]
        #expect(ProgramPacks.blocker(.sleep, r, apnea)?.contains("先治疗") == true)
        apnea.apneaTreatment = .cpap
        #expect(ProgramPacks.blocker(.sleep, r, apnea) == nil, "treated: the pack can help with the schedule")
        var suspected = profile()
        suspected.apneaStatus = .suspected
        #expect(ProgramPacks.blocker(.sleep, r, suspected)?.contains("医生") == true)
        var stopBang = profile()
        stopBang.stopBangScore = 4
        #expect(ProgramPacks.blocker(.sleep, r, stopBang) == nil, "3–4 alone needs more signs")
        stopBang.stopBangScore = 5
        #expect(ProgramPacks.blocker(.sleep, r, stopBang)?.contains("医生") == true, "the self-check's 较高风险")
    }

    // MARK: Goals and readings

    @Test func goalsAreHalfAnHourMoreOrTwentyMinutesSteadier() {
        let p = profile()
        #expect(TargetTracker.goal(.sleepDuration, baseline: 6.2, profile: p) == 6.7)
        #expect(TargetTracker.goal(.sleepDuration, baseline: 6.8, profile: p) == 7.0, "never past 7 hours")
        #expect(TargetTracker.goal(.sleepDuration, baseline: 7.2, profile: p) == 7.2, "already there: stay there")
        #expect(TargetTracker.goal(.sleepRegularity, baseline: 75, profile: p) == 55)
        #expect(TargetTracker.goal(.sleepRegularity, baseline: 40, profile: p) == 30)
        #expect(TargetTracker.goal(.sleepRegularity, baseline: 25, profile: p) == 25)
        #expect(TargetTracker.reached(.sleepDuration, value: 6.8, goal: 6.7))
        #expect(TargetTracker.reached(.sleepRegularity, value: 50, goal: 55))
    }

    @Test func readingsUseTheLastSevenNights() {
        var days = nights(hours: 6, count: 14)
        for i in 7..<14 { days[i].sleepMinutes = 7 * 60 }
        let r = TargetTracker.reading(.sleepDuration, days: days, vitals: [], workouts: [], end: today)
        #expect(r.value == 7 && r.count == 7)
        #expect(r.valueText == "7" && r.unitShort == "小时")
        let steady = TargetTracker.reading(.sleepRegularity, days: nights(hours: 7, count: 14), vitals: [], workouts: [], end: today)
        #expect(steady.value == 0)
        let scattered = TargetTracker.reading(.sleepRegularity, days: nights(hours: 7, swing: 60, count: 14), vitals: [], workouts: [], end: today)
        #expect((scattered.value ?? 0) > 25)
        #expect(!scattered.series.isEmpty, "a point for each whole week")
        let few = TargetTracker.reading(.sleepDuration, days: Array(nights(hours: 6, count: 14).suffix(2)), vitals: [], workouts: [], end: today)
        #expect(few.value == nil, "two nights are too few to stand for the week")
    }

    // MARK: The week

    @Test func bedtimeComesEarlierEachWeekUntilSevenHours() {
        let x = input(.sleepDuration)
        let p = profile()
        // 6.2 hours: 0.8 short, so up to an hour earlier, 15 minutes a week; the wake time stays (to the quarter hour).
        #expect(PackPlanner.sleepSchedule(p, x, week: 1) == (24 * 60 + 15, 6 * 60 + 45))
        #expect(PackPlanner.sleepSchedule(p, x, week: 4).bed == 23 * 60 + 30)
        #expect(PackPlanner.sleepSchedule(p, x, week: 6).bed == 23 * 60 + 30, "no earlier than the hours need")
        #expect(PackPlanner.sleepSchedule(p, input(.sleepRegularity, hours: 7.4), week: 3).bed == 24 * 60 + 30, "regularity keeps the usual time")

        var q = p
        q.programPhase = .improve
        q.program = x
        let plan = PackPlanner.week(profile: q, input: x, weekStart: today)
        #expect(plan.notes.contains { $0.contains("06:45 起床") && $0.contains("00:15 前上床") }, "\(plan.notes)")
        #expect(plan.notes.contains { $0.contains("CBT-I") }, "insomnia goes to a clinic, not to this pack")
        #expect(plan.notes.contains { $0.contains("\(p.caffeineCutoffHour) 点后不喝咖啡") })
        #expect(!plan.sessions.isEmpty, "training stays: regular exercise helps sleep too")
    }

    @Test func weeklyChecksCountNightsOnTime() {
        let x = input(.sleepDuration)
        // Week 1: in bed by 00:15 (+30) and up at 06:45 ±30. Five nights on time, two late.
        var days = nights(hours: 6.5, bed: 24 * 60, count: 7, from: today.adding(days: 7))
        for i in [5, 6] {
            days[i].sleepStart = days[i].day.adding(days: -1).adding(minutes: 25 * 60 + 30)
            days[i].sleepEnd = days[i].day.adding(minutes: 8 * 60)
        }
        for i in 0..<5 { days[i].sleepEnd = days[i].day.adding(minutes: 6 * 60 + 50) }
        let e = ProgramEvaluator.Input(program: x, profile: profile(), days: days, workouts: [], vitals: [], plan: [],
                                       targetGoal: TargetGoal(target: .sleepDuration, baseline: 6.2, goal: 6.7))
        let w = ProgramEvaluator.week(e, weekStart: today, now: today.adding(days: 7).adding(minutes: 600))
        let wake = w.checks.first { $0.title == "按时起床" }
        let bed = w.checks.first { $0.title == "按时上床" }
        #expect(wake?.met == true && wake?.detail.contains("5 天") == true, "\(String(describing: wake))")
        #expect(bed?.met == true && bed?.detail.contains("00:45 前睡着") == true, "\(String(describing: bed))")
        #expect(w.targetLine.contains("睡眠时长 6.5"), "\(w.targetLine)")
        #expect(ProgramEvaluator.hardestLine(ProgramEvaluator.Input(program: x, profile: profile(), days: [], workouts: [], vitals: [], plan: [],
                                                                     hardest: ["按时上床", "按时上床、步数"])).contains("按时上床（2 周）"))
    }

    @Test func theRoundEndsOnTheNightsOfWeeksThreeAndFour() {
        // Weeks 1–2 at 6 h, weeks 3–4 at 6.8 h; the last week alone (7.2 h) would overstate it.
        var days = nights(hours: 6, count: 28, from: today.adding(days: 28))
        for i in 14..<28 { days[i].sleepMinutes = (i >= 21 ? 7.2 : 6.4) * 60 }
        let e = ProgramEvaluator.Input(program: input(.sleepDuration), profile: profile(), days: days, workouts: [], vitals: [], plan: [],
                                       targetGoal: TargetGoal(target: .sleepDuration, baseline: 6.2, goal: 6.7))
        let r = ProgramEvaluator.round(e, now: today.adding(days: 28).adding(minutes: 600))
        #expect(r?.value == 6.8, "\(String(describing: r))")
        #expect(r?.outcome == .achieved)
    }

    // MARK: Age left out

    @Test func anAgeLeftOutIsNilNotZero() {
        var p = ProfileSnapshot()
        p.age = nil
        #expect(!p.ageKnown && p.ageText == "年龄未填写")
        #expect(p.estimatedMaxHR == nil)
        #expect(!p.isAtLeast(age: 18))
        #expect(LabAnalyzer.ckdEPI(creatinine: 90, age: nil, sex: .male) == nil, "no eGFR without an age")
        #expect(PopulationNorms.stepPlateau(age: nil) == 8000...10_000)
        p.age = 66
        #expect(p.isAtLeast(age: 65) && p.estimatedMaxHR == 208 - 0.7 * 66)
    }
}
