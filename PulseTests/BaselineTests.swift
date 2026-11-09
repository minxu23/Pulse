import Foundation
import SwiftData
import Testing
@testable import Pulse

private let evening = Calendar.pulse.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 20))!
private let today = evening.startOfDay
private let window = DateInterval(start: today.adding(days: -7), end: today)

/// Step 2 of the 三阶段健康计划: peer ranks, the health portrait and habit profile, possible causes,
/// the main target per pack and the recommended pack.
@Suite("三阶段计划: baseline report")
@MainActor
struct BaselineTests {
    // MARK: Peer ranks

    @Test func ranksInterpolateBetweenPublishedPercentiles() {
        let vo2 = PopulationNorms.vo2max.rank(34.8, age: 45, sex: .male)
        #expect(abs(vo2.goodness - 50) < 0.5, "the FRIEND median for men in their 40s")
        #expect(PopulationNorms.restingHR.rank(55, age: 30, sex: .male).band == .top10, "lower resting heart rate ranks higher")
        #expect(PopulationNorms.restingHR.rank(89, age: 30, sex: .female).band == .bottom25)
        #expect(PopulationNorms.bodyFat.rank(31.0, age: 37, sex: .male).band == .lowerMid, "P75 body fat is the bottom of 中下")
        #expect(PopulationNorms.vo2max.rank(80, age: 30, sex: .male).goodness == 99, "capped")
        #expect(PopulationNorms.vo2max.rank(5, age: 30, sex: .male).goodness == 1, "capped")
        #expect(PeerRank(goodness: 70, reference: .friend2022).approx == "约前 30%")
        #expect(PeerRank(goodness: 10, reference: .friend2022).approx == "约后 10%")
    }

    @Test func fitnessAgeComesFromTheMedians() {
        #expect(PopulationNorms.fitnessAge(vo2: 38.6, sex: .male) == 35)
        #expect(PopulationNorms.fitnessAge(vo2: 25.9, sex: .female) == 45)
        #expect(PopulationNorms.fitnessAge(vo2: 60, sex: .male) == 20)
        #expect(PopulationNorms.fitnessAge(vo2: 10, sex: .female) == 89)
    }

    @Test func stepsUseTheDoseResponseBands() {
        #expect(PopulationNorms.stepBand(4000, age: 40) == .sedentary)
        #expect(PopulationNorms.stepBand(7500, age: 40) == .fair)
        #expect(PopulationNorms.stepBand(8500, age: 40) == .good)
        #expect(PopulationNorms.stepBand(6500, age: 65) == .good, "the curve levels off earlier from 60")
        #expect(PopulationNorms.bmiClass(24) == .over && PopulationNorms.bmiClass(28) == .obese)
        #expect(PopulationNorms.waistClass(86, sex: .female) == .central && PopulationNorms.waistClass(86, sex: .male) == .pre)
    }

    // MARK: Synthetic users

    private func profile(age: Int = 40, sex: Sex = .male, bmi: Double = 23) -> ProfileSnapshot {
        var p = ProfileSnapshot()
        p.age = age; p.sex = sex; p.bmi = bmi; p.heightCm = 175
        return p
    }

    private func days(rhr: Double = 60, sleepH: Double = 7.5, steps: Int = 8000, vo2: Double? = 40) -> [DayData] {
        (0..<30).map { i in
            var d = DayData(day: today.adding(days: -30 + i))
            d.rhr = rhr; d.hrv = 45; d.sleepMinutes = sleepH * 60; d.steps = steps
            d.sleepStart = d.day.adding(minutes: -60)
            if i % 7 == 3 { d.vo2Max = vo2 }
            return d
        }
    }

    private func session(_ daysAgo: Int, hour: Int, _ type: WorkoutType, minutes: Double, avg: Double, recovery: Double? = nil) -> WorkoutPoint {
        WorkoutPoint(start: today.adding(days: -daysAgo).adding(minutes: hour * 60), type: type, minutes: minutes, avgHR: avg,
                     rpe: nil, distanceKm: nil, hrSeries: Array(repeating: Int(avg), count: Int(minutes)), hrRecovery: recovery)
    }

    private func report(_ p: ProfileSnapshot, days: [DayData], workouts: [WorkoutPoint] = [], vitals: [VitalPoint] = [],
                        meals: [Date] = [], rhythm: [Date] = []) -> (BaselineReport, BaselineInput) {
        let x = BaselineInput(profile: p, days: days, workouts: workouts, vitals: vitals, meals: meals, rhythmAlerts: rhythm, window: window)
        return (BaselineAssessment.assess(x), x)
    }

    @Test func completenessWaitsForACardioFitnessEstimate() {
        let (none, _) = report(profile(), days: days(vo2: nil))
        #expect(!none.completeness.isReady)
        #expect(none.completeness.missing.map(\.label) == ["心肺能力估算"])
        #expect(none.metric(.vo2max)?.quality == .missing)
        let (some, _) = report(profile(), days: days())
        #expect(some.completeness.isReady)
        #expect(some.metric(.vo2max)?.quality == .estimated)
    }

    @Test func habitsShowWhenAndHowHardEachSportIs() {
        // Tennis at 19:00 hard enough to be vigorous (HRmax 180, resting 60 → vigorous from 132); walks at noon.
        let w = [session(2, hour: 19, .tennis, minutes: 90, avg: 150, recovery: 30), session(9, hour: 19, .tennis, minutes: 90, avg: 148, recovery: 28),
                 session(16, hour: 19, .tennis, minutes: 80, avg: 152), session(4, hour: 12, .walk, minutes: 30, avg: 100),
                 session(11, hour: 12, .walk, minutes: 30, avg: 102)]
        let (r, _) = report(profile(), days: days(), workouts: w)
        let h = r.habits
        #expect(h.mainSlot == .evening)
        #expect(h.sports.first?.type == .tennis && h.sports.first?.intensity == .hard)
        #expect(h.sports.first?.weekdays.count == 1, "always the same weekday")
        #expect(h.sports.first { $0.type == .walk }?.intensity == .easy)
        #expect(h.vigorousMinutes == 65, "260 vigorous minutes over 4 weeks")
        #expect(h.guidelineMinutes == 130, "vigorous minutes count twice; the walks stay below moderate")
        #expect(r.metric(.hrRecovery)?.verdict == .good, "two hard sessions with recovery")
        #expect(h.afterMeal == nil, "no meals known")
        let meals = (0..<10).map { today.adding(days: -$0).adding(minutes: 18 * 60 + 20) }
        #expect(report(profile(), days: days(), workouts: w, meals: meals).0.habits.afterMeal == 2, "the two tennis evenings that had dinner at 18:20")
    }

    @Test func heartRateLoweringMedicinesSwitchToHowHardItFelt() {
        var p = profile()
        p.medications = [MedicationInfo(name: "美托洛尔", category: .betaBlocker, start: today.adding(days: -300), end: nil)]
        let w = [session(2, hour: 19, .run, minutes: 40, avg: 120)]
        let (r, _) = report(p, days: days(), workouts: w)
        #expect(!r.habits.zonesReliable)
        #expect(r.habits.moderateMinutes > 0, "a run counts as moderate by its usual effort")
        #expect(r.metric(.activeMinutes)?.note?.contains("控制心率的药物") == true)
    }

    private func bp(_ sys: Double, _ dia: Double, n: Int = 12) -> [VitalPoint] {
        (0..<n).map { VitalPoint(time: today.adding(days: -1 - $0 / 2).adding(minutes: $0 % 2 == 0 ? 7 * 60 : 21 * 60), kind: .bloodPressure,
                                 value: sys, value2: dia, context: .morning) }
    }

    @Test func cardioTargetFollowsTheBloodPressureRules() {
        // Home readings at 145/92 without a diagnosis: a blood-pressure problem, and a monitor.
        let (high, _) = report(profile(), days: days(), vitals: bp(145, 92))
        #expect(high.metric(.bloodPressure)?.verdict == .attention)
        #expect(ProgramPacks.target(for: .cardio, report: high, profile: profile()) == .homeBP)
        // Diagnosed, no readings, monitor not known: readings from a pharmacy or clinic.
        var treated = profile()
        treated.conditions = [.hypertension]
        let (none, _) = report(treated, days: days())
        #expect(ProgramPacks.target(for: .cardio, report: none, profile: treated) == .clinicBP)
        treated.hasBPMonitor = false
        #expect(ProgramPacks.target(for: .cardio, report: high, profile: treated) == .clinicBP, "explicitly no monitor must not be overridden by a few clinic readings")
        treated.hasBPMonitor = true
        #expect(ProgramPacks.target(for: .cardio, report: none, profile: treated) == .homeBP)
        // No blood-pressure problem: resting heart rate.
        let (normal, _) = report(profile(), days: days(rhr: 82), vitals: bp(118, 76))
        #expect(ProgramPacks.target(for: .cardio, report: normal, profile: profile()) == .restingHR)
    }

    private func cgm(mean: Double, swing: Double) -> [VitalPoint] {
        (0..<(7 * 96)).map { i in
            VitalPoint(time: window.start.adding(minutes: i * 15), kind: .glucose,
                       value: mean + swing * sin(Double(i) / 6), value2: nil, context: .random)
        }
    }

    @Test func metabolicTargetFollowsDiabetesAndDevices() {
        var diabetic = profile()
        diabetic.conditions = [.diabetesT2]
        let (withCGM, _) = report(diabetic, days: days(), vitals: cgm(mean: 8.5, swing: 3))
        #expect(withCGM.metric(.glucose)?.title == "血糖达标时间")
        #expect(ProgramPacks.target(for: .metabolic, report: withCGM, profile: diabetic) == .cgmTIR)
        let (healthyCGM, _) = report(profile(), days: days(), vitals: cgm(mean: 6.2, swing: 2.2))
        #expect(healthyCGM.metric(.glucose)?.title == "餐后血糖")
        #expect((healthyCGM.metric(.glucose)?.verdict ?? .good) >= .fair)
        #expect(ProgramPacks.target(for: .metabolic, report: healthyCGM, profile: profile()) == .postMealGlucose)
        let heavy = profile(bmi: 27)
        let (noCGM, _) = report(heavy, days: days())
        #expect(ProgramPacks.target(for: .metabolic, report: noCGM, profile: heavy) == .weight)
        #expect(ProgramPacks.target(for: .fitness, report: noCGM, profile: heavy) == .vo2max)
        #expect(ProgramPacks.target(for: .event, report: noCGM, profile: heavy) == .weeklyRunKm)
    }

    @Test func dangerSignsComeBeforeAnyPlan() {
        let (r, _) = report(profile(), days: days(), rhythm: [today.adding(days: -20)])
        #expect(r.metric(.rhythm)?.verdict == .urgent)
        #expect(!r.redFlags.isEmpty)
        #expect(ProgramPacks.recommend(r, profile: profile()).doctorFirst)
        let (fine, _) = report(profile(), days: days())
        #expect(fine.metric(.rhythm)?.valueText == "未见提示")
        #expect(!ProgramPacks.recommend(fine, profile: profile()).doctorFirst)
        let (veryHigh, _) = report(profile(), days: days(), vitals: bp(165, 102))
        #expect(veryHigh.metric(.bloodPressure)?.verdict == .urgent && !veryHigh.redFlags.isEmpty)
    }

    @Test func causesLeadWithWhatTheRecordsShow() {
        // High resting heart rate, little exercise, short sleep.
        let (r, x) = report(profile(), days: days(rhr: 84, sleepH: 6.1))
        let c = CauseInference.concerns(r, x).first { $0.metric == .rhr }
        #expect(c != nil)
        #expect(c!.causes.count <= CauseInference.maxCauses)
        #expect(c!.causes.first?.evidence == .data)
        #expect(c!.causes.contains { $0.text.contains("6.1 小时") })
        #expect(c!.causes.map(\.evidence) == c!.causes.map(\.evidence).sorted(), "data first, then common, then doctor")
        #expect(c!.causes.allSatisfy { !$0.text.contains("因为") })
    }

    @Test func weakestAbilityDecidesThePack() {
        // Low fitness only → 运动能力提升.
        let (unfit, _) = report(profile(), days: days(vo2: 26))
        #expect(ProgramPacks.recommend(unfit, profile: profile()).recommended.pack == .fitness)
        // Obese and unfit → metabolism is the weaker (attention beats a low band alone).
        let (heavy, _) = report(profile(bmi: 29), days: days(vo2: 33))
        let rec = ProgramPacks.recommend(heavy, profile: profile(bmi: 29))
        #expect(rec.recommended.pack == .metabolic)
        #expect(rec.alternatives.contains { $0.pack == .fitness })
        // A race eight weeks out leads.
        var racer = profile()
        racer.race = RaceInfo(name: "无锡马拉松", date: today.adding(days: 56), targetMinutes: nil, startDate: today,
                              currentWeeklyKm: 30, longestRunKm: 18, fuelCarbsPerHour: 45)
        #expect(ProgramPacks.recommend(heavy, profile: racer).recommended.pack == .event)
        // No race set: 关键事件准备 is blocked with what to do.
        #expect(ProgramPacks.recommend(unfit, profile: profile()).blocked.contains { $0.pack == .event })
    }

    // MARK: Sample users

    private func load(_ persona: DemoPersona) throws -> (BaselineResult, ProfileSnapshot, ModelContainer) {
        let container = try ModelContainer(for: Schema(PulseSchema.models), configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        let ctx = container.mainContext
        DemoDataGenerator.populate(ctx, persona: persona, now: evening)
        let r = DataHub.baseline(in: ctx, window: DataHub.historyWindow(now: evening), now: evening)
        return (r, DataHub.analytics(in: ctx, now: evening).profile, container)
    }

    @Test func xiaolinIsReadyAndRuns() throws {
        let (b, p, c) = try load(.xiaolin)
        _ = c
        #expect(b.report.completeness.isReady)
        #expect(b.report.habits.sports.contains { $0.type == .run })
        #expect(b.report.habits.mainSlot == .evening)
        #expect(b.report.metric(.vo2max)?.rank != nil)
        #expect(b.report.cards.count == 4)
        #expect(b.recommendation.recommended.pack == (p.race != nil ? .event : .fitness))
    }

    @Test func wangjianguoGetsBloodPressureFromHisMonitor() throws {
        let (b, p, c) = try load(.wangjianguo)
        _ = c
        #expect(b.report.metric(.bloodPressure)?.value != nil)
        #expect(ProgramPacks.target(for: .cardio, report: b.report, profile: p) == .homeBP)
        #expect([.cardio, .metabolic].contains(b.recommendation.recommended.pack))
    }

    @Test func hejingsCGMSetsTimeInRange() throws {
        let (b, p, c) = try load(.hejing)
        _ = c
        #expect(b.report.metric(.glucose)?.title == "血糖达标时间")
        #expect(ProgramPacks.target(for: .metabolic, report: b.report, profile: p) == .cgmTIR)
    }

    @Test func chenjieIsHeavyAndUnfit() throws {
        let (b, p, c) = try load(.chenjie)
        _ = c
        #expect(ProgramPacks.qualifies(.metabolic, b.report, p) != nil, "BMI 28.4")
        // Every sample user wears a CGM: without diabetes the metabolic target is the post-meal rise, not weight.
        #expect(ProgramPacks.target(for: .metabolic, report: b.report, profile: p) == .postMealGlucose)
        #expect(b.report.metric(.glucose)?.title == "餐后血糖")
        #expect(!b.concerns.isEmpty)
    }
}
