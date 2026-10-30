import Foundation
import SwiftData
import Testing
@testable import Pulse

private let today = Calendar.pulse.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 9))!

/// Builds `count` consecutive days ending today with resting HR from `rhr(i)` (i = 0 oldest).
private func series(_ count: Int, source: RHRSource = .device, rhr: (Int) -> Double?) -> [DayData] {
    (0..<count).map { i in
        var d = DayData(day: today.adding(days: i - count + 1))
        d.rhr = rhr(i)
        d.rhrSource = source
        return d
    }
}

private func wiggle(_ i: Int) -> Double { [0, 1, -1, 0.5, -0.5, 1.5, -1.5][i % 7] }

@Suite("Resting heart rate trend")
struct RHRTrendTests {
    @Test func stableSeriesIsTypical() {
        let days = series(60) { 65 + wiggle($0) }
        let t = RHRTrendAnalyzer.analyze(days: days, profile: ProfileSnapshot(), today: today)
        #expect(t.sustained == .none)
        if case .typical = t.shortTerm {} else { Issue.record("expected typical, got \(t.shortTerm)") }
        if case .stable = t.longTerm {} else { Issue.record("expected stable, got \(t.longTerm)") }
        #expect(t.baseline != nil)
    }

    @Test func singleSpikeIsNotSustained() {
        let days = series(60) { $0 == 59 ? 74 : 65 + wiggle($0) }
        let t = RHRTrendAnalyzer.analyze(days: days, profile: ProfileSnapshot(), today: today)
        if case .spikeUp(let d) = t.shortTerm { #expect(d > 7) } else { Issue.record("expected spike, got \(t.shortTerm)") }
        #expect(t.sustained == .none)
        #expect(t.headline.contains("单次波动"))
    }

    @Test func sustainedRiseDetected() {
        let days = series(60) { $0 >= 53 ? 71 + wiggle($0) : 65 + wiggle($0) }
        let t = RHRTrendAnalyzer.analyze(days: days, profile: ProfileSnapshot(), today: today)
        if case .rise(let d) = t.sustained { #expect(d > 4) } else { Issue.record("expected rise, got \(t.sustained)") }
    }

    @Test func longTermDecreaseDetected() {
        let days = series(84) { 72 - Double($0) * 0.08 + wiggle($0) }
        let t = RHRTrendAnalyzer.analyze(days: days, profile: ProfileSnapshot(), today: today)
        if case .decreasing(let s) = t.longTerm { #expect(s < -1) } else { Issue.record("expected decreasing, got \(t.longTerm)") }
    }

    @Test func mixedSourcesUseDominantAndFlagLimitation() {
        var days = series(40) { 64 + wiggle($0) }
        for i in stride(from: 30, to: 40, by: 2) { days[i].rhr = 70; days[i].rhrSource = .manual }
        let t = RHRTrendAnalyzer.analyze(days: days, profile: ProfileSnapshot(), today: today)
        #expect(t.dominantSource == .device)
        #expect(t.points.allSatisfy { $0.source == .device })
        #expect(t.limitations.contains { $0.contains("同时有设备与手动") })
    }

    @Test func medicationChangeLimitsComparability() {
        let days = series(40) { 64 + wiggle($0) }
        var p = ProfileSnapshot()
        p.medications = [MedicationInfo(name: "美托洛尔", category: .betaBlocker, start: today.adding(days: -10), end: nil)]
        let t = RHRTrendAnalyzer.analyze(days: days, profile: p, today: today)
        #expect(t.limitations.contains { $0.contains("美托洛尔") })
    }

    @Test func insufficientDataExplainsLimits() {
        let days = series(4) { _ in 66 }
        let t = RHRTrendAnalyzer.analyze(days: days, profile: ProfileSnapshot(), today: today)
        #expect(t.baseline == nil)
        #expect(t.headline.contains("正在建立个人参照"))
        #expect(!t.limitations.isEmpty)
    }

    @Test func elevatedDaysCarryContext() {
        var days = series(40) { $0 == 39 ? 72 : 64 + wiggle($0) }
        days[38].alcoholUnits = 3
        let t = RHRTrendAnalyzer.analyze(days: days, profile: ProfileSnapshot(), today: today)
        #expect(t.elevatedDays.first?.tags.contains(.alcohol) == true)
    }
}

@Suite("Body readiness")
struct ReadinessTests {
    private func history() -> [DayData] {
        (1...28).map { i in
            var d = DayData(day: today.adding(days: -i))
            d.rhr = 62 + wiggle(i); d.rhrSource = .device
            d.hrv = 50 + wiggle(i) * 3
            d.sleepMinutes = 450
            d.load = i % 2 == 0 ? 200 : 0
            return d
        }
    }

    @Test func wellRecoveredMorningScoresHigh() {
        var d = DayData(day: today)
        d.rhr = 61; d.rhrSource = .device; d.hrv = 52; d.sleepMinutes = 470; d.energy = 4; d.soreness = 0; d.stress = 2
        let r = ReadinessEngine.evaluate(today: d, history: history(), profile: ProfileSnapshot())
        #expect(r.level == .high)
        #expect(r.confidence == .high)
    }

    @Test func shortSleepAndElevatedHRLowerReadiness() {
        var d = DayData(day: today)
        d.rhr = 70; d.rhrSource = .device; d.hrv = 34; d.sleepMinutes = 300; d.energy = 2
        let r = ReadinessEngine.evaluate(today: d, history: history(), profile: ProfileSnapshot())
        #expect(r.level == .low || r.level == .rest)
        #expect(r.factors.first { $0.id == "rhr" }?.impact == .negative)
    }

    @Test func illnessForcesRest() {
        var d = DayData(day: today)
        d.rhr = 62; d.rhrSource = .device; d.sleepMinutes = 480; d.energy = 4; d.illness = true
        let r = ReadinessEngine.evaluate(today: d, history: history(), profile: ProfileSnapshot())
        #expect(r.level == .rest)
        #expect(!r.overrides.isEmpty)
    }

    @Test func noDataGivesNoScore() {
        let r = ReadinessEngine.evaluate(today: DayData(day: today), history: [], profile: ProfileSnapshot())
        #expect(r.score == nil)
        #expect(r.confidence == .low)
    }
}

@Suite("Plans and adjustments")
struct PlanTests {
    @Test func beginnerPlanHasStrengthLongAndNoIntervals() {
        var p = ProfileSnapshot()
        p.level = .sedentary; p.availableWeekdays = [3, 5, 7]; p.weeklyTargetMinutes = 75
        let plan = PlanGenerator.generate(profile: p, weekStart: today.weekStart)
        #expect(plan.sessions.count == 7)
        #expect(plan.sessions.contains { $0.kind == .strength })
        #expect(plan.sessions.contains { $0.kind == .long })
        #expect(!plan.sessions.contains { $0.kind == .quality })
        #expect(plan.sessions.contains { $0.kind == .rest })
        #expect(plan.sessions.allSatisfy { $0.minimumMinutes <= $0.minutes })
    }

    @Test func cardiacWithoutClearanceAvoidsHardSessions() {
        var p = ProfileSnapshot()
        p.level = .active; p.goals = [.fitness]; p.conditions = [.coronaryDisease]
        p.availableWeekdays = [2, 3, 4, 5, 6, 7]
        let plan = PlanGenerator.generate(profile: p, weekStart: today.weekStart)
        #expect(!plan.sessions.contains { $0.intensity == .hard })
        #expect(plan.notes.first?.contains("医生") == true)
    }

    @Test func rateLoweringMedsUseRPEGuidance() {
        var p = ProfileSnapshot()
        p.medications = [MedicationInfo(name: "比索洛尔", category: .betaBlocker, start: today.adding(days: -100), end: nil)]
        #expect(PlanGenerator.guidance(.easy, p).contains("主观感受"))
    }

    @Test func weeklyTargetProgressesGradually() {
        let p = ProfileSnapshot()
        #expect(PlanGenerator.nextWeeklyTarget(current: 100, lastWeekCompletion: 0.95, profile: p).minutes == 110)
        #expect(PlanGenerator.nextWeeklyTarget(current: 100, lastWeekCompletion: 0.7, profile: p).minutes == 100)
        #expect(PlanGenerator.nextWeeklyTarget(current: 100, lastWeekCompletion: 0.3, profile: p).minutes == 85)
    }

    @Test func marathonPhasesAndTaper() {
        var p = ProfileSnapshot()
        p.modules = [.marathon]
        p.availableWeekdays = [3, 5, 7, 1]
        let race = RaceInfo(name: "测试马拉松", date: today.adding(days: 7 * 20), targetMinutes: 270,
                            startDate: today, currentWeeklyKm: 20, longestRunKm: 12, fuelCarbsPerHour: 45)
        p.race = race
        let early = MarathonPlanner.week(profile: p, race: race, weekStart: today.weekStart)
        #expect(early.phase == .base)
        let taper = MarathonPlanner.week(profile: p, race: race, weekStart: race.date.weekStart.adding(days: -7))
        #expect(taper.phase == .taper)
        let peak = MarathonPlanner.week(profile: p, race: race, weekStart: race.date.weekStart.adding(days: -35))
        #expect(peak.weeklyKm > early.weeklyKm)
        #expect(taper.weeklyKm < peak.weeklyKm)
        #expect(peak.longRunKm > early.longRunKm)
    }

    private func session(_ kind: PlanKind, _ minutes: Int, _ intensity: Intensity, key: Bool = false) -> SessionSnapshot {
        SessionSnapshot(id: UUID(), day: today, kind: kind, title: kind.label, minutes: minutes, minimumMinutes: 15,
                        minimumDetail: "精简", intensity: intensity, isKey: key, status: .planned)
    }

    private func readiness(_ level: ReadinessLevel, _ score: Int) -> ReadinessResult {
        ReadinessResult(score: score, level: level, factors: [], confidence: .high, headline: "", recommendation: "",
                        overrides: [], notes: [], missing: [])
    }

    @Test func lowReadinessDowngradesIntervals() {
        var c = AdjustmentContext(); c.readiness = readiness(.low, 50)
        let r = PlanAdjuster.adjust(sessions: [session(.quality, 40, .hard, key: true)], context: c)
        #expect(r.proposals.first?.intensity == .easy)
        #expect(r.proposals.first?.reasons.isEmpty == false)
    }

    @Test func busyDayUsesMinimumVersion() {
        var c = AdjustmentContext(); c.readiness = readiness(.high, 85); c.availableMinutes = 15
        let r = PlanAdjuster.adjust(sessions: [session(.aerobic, 45, .easy)], context: c)
        #expect(r.proposals.first?.minutes == 15)
    }

    @Test func illnessConvertsToRest() {
        var c = AdjustmentContext(); c.illness = true
        let r = PlanAdjuster.adjust(sessions: [session(.aerobic, 45, .moderate)], context: c)
        #expect(r.proposals.first?.kind == .rest)
    }

    @Test func priorActivityCountsTowardAerobic() {
        var c = AdjustmentContext(); c.readiness = readiness(.high, 80); c.activeMinutesSoFar = 40
        let r = PlanAdjuster.adjust(sessions: [session(.aerobic, 40, .easy)], context: c)
        #expect(r.proposals.first?.countsAsDone == true)
    }
}

@Suite("Alerts and care analyzers")
struct AlertTests {
    @Test func bloodPressureCrisisIsUrgent() {
        let v = VitalPoint(time: today, kind: .bloodPressure, value: 185, value2: 110, context: .morning)
        #expect(AlertEngine.evaluateVital(v, profile: ProfileSnapshot())?.severity == .urgent)
    }

    @Test func lowGlucoseNeedsVerification() {
        let v = VitalPoint(time: today, kind: .glucose, value: 3.5, value2: nil, context: .preExercise)
        #expect(AlertEngine.evaluateVital(v, profile: ProfileSnapshot())?.kind == .glucoseLow)
        let severe = VitalPoint(time: today, kind: .glucose, value: 2.8, value2: nil, context: .random)
        #expect(AlertEngine.evaluateVital(severe, profile: ProfileSnapshot())?.severity == .urgent)
    }

    @Test func threeElevatedMorningsRaiseEvent() {
        let days = series(40) { $0 >= 37 ? 76 : 64 + wiggle($0) }
        let p = ProfileSnapshot()
        let t = RHRTrendAnalyzer.analyze(days: days, profile: p, today: today)
        let alerts = AlertEngine.rhrAlerts(days: days, trend: t, profile: p, now: today)
        #expect(alerts.contains { $0.kind == .rhrSustainedRise && $0.severity == .verify })
    }

    @Test func glucoseMetricsFollowConsensusRanges() {
        let pts = (0..<(14 * 96)).map { i -> (time: Date, value: Double) in
            (today.adding(days: -14).addingTimeInterval(Double(i) * 900), i % 10 == 0 ? 11.0 : 6.0)
        }
        let m = GlucoseAnalyzer.metrics(pts, now: today)
        #expect(m.isContinuous)
        #expect(m.sufficient)
        #expect(abs((m.tir ?? 0) - 0.9) < 0.02)
        #expect(abs((m.tar ?? 0) - 0.1) < 0.02)
    }

    @Test func stopBangScoring() {
        #expect(SleepAnalyzer.stopBang([true, true, false, true, false, false, false, true]).risk == "中等风险")
        #expect(SleepAnalyzer.stopBang([true, true, true, true, false, true, false, true]).risk == "较高风险")
    }
}

@Suite("Review")
struct ReviewTests {
    @Test func alcoholAssociationObserved() {
        var days = series(90) { 64 + wiggle($0) }
        for i in stride(from: 3, to: 88, by: 7) {
            days[i].alcoholUnits = 3
            days[i + 1].rhr = 69 + wiggle(i)
        }
        let assoc = InsightEngine.associations(days: days, profile: ProfileSnapshot(), now: today)
        let a = assoc.first { $0.id == "alcohol-rhr" }
        #expect(a?.sufficient == true)
        #expect((a?.diff ?? 0) > 3)
        #expect(a?.strength == .strong)
    }

    @Test func progressReportsNonHeartGains() {
        var days = series(84) { 66 + wiggle($0) }
        for i in days.indices {
            days[i].energy = i < 28 ? 3 : 4
            days[i].exerciseMinutes = i < 28 ? 10 : 35
        }
        let t = RHRTrendAnalyzer.analyze(days: days, profile: ProfileSnapshot(), today: today)
        let r = ProgressEvaluator.evaluate(days: days, workouts: [], trend: t, profile: ProfileSnapshot(), now: today)
        #expect(r.dimensions.first { $0.id == "energy" }?.status == .improved)
        #expect(r.dimensions.first { $0.id == "activity" }?.status == .improved)
        #expect(r.overall.contains("真实的进展"))
    }
}

@Suite("Demo data integration")
@MainActor
struct DemoTests {
    @Test func demoPopulatesConsistentHistory() throws {
        let container = try ModelContainer(for: Schema(PulseSchema.models),
                                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        let ctx = container.mainContext
        DemoDataGenerator.populate(ctx, now: today)
        let a = DataHub.analytics(in: ctx, now: today)
        #expect(a.days.count >= 120)
        #expect(a.trend.baseline != nil)
        if case .decreasing = a.trend.longTerm {} else { Issue.record("demo should show a decreasing long-term trend, got \(a.trend.longTerm)") }
        #expect(a.readiness().score != nil)
        DataHub.ensureWeekPlan(in: ctx, now: today)
        #expect(!DataHub.planItems(weekStart: today.weekStart, in: ctx).isEmpty)
        let assoc = InsightEngine.associations(days: a.days, profile: a.profile, now: today)
        #expect(assoc.contains { $0.id == "alcohol-rhr" && $0.sufficient && $0.diff > 0 })
    }
}

@Suite("Daily flow")
@MainActor
struct DailyFlowTests {
    @Test func phasesFollowPersonalSchedule() {
        let wake = 7 * 60, bed = 23 * 60
        func at(_ h: Int, _ m: Int = 0) -> Date { today.startOfDay.adding(minutes: h * 60 + m) }
        #expect(DayPhase.current(at: at(7, 30), wakeMinutes: wake, bedtimeMinutes: bed) == .morning)
        #expect(DayPhase.current(at: at(14), wakeMinutes: wake, bedtimeMinutes: bed) == .exercise)
        #expect(DayPhase.current(at: at(21, 30), wakeMinutes: wake, bedtimeMinutes: bed) == .evening)
        #expect(DayPhase.current(at: at(23, 30), wakeMinutes: wake, bedtimeMinutes: bed) == .review)
        #expect(DayPhase.current(at: at(1), wakeMinutes: wake, bedtimeMinutes: bed) == .review)
    }

    @Test func overnightBloodPressureComparesBedtimeAndMorning() {
        let d = today.startOfDay
        let vitals = [
            VitalPoint(time: d.adding(minutes: -90), kind: .bloodPressure, value: 118, value2: 75, context: .bedtime),
            VitalPoint(time: d.adding(minutes: 7 * 60), kind: .bloodPressure, value: 140, value2: 88, context: .morning),
        ]
        let r = OvernightAnalyzer.bloodPressure(vitals, morningOf: today, profile: ProfileSnapshot())
        #expect(r.riseSys == 22)
        #expect(r.needsAttention)
    }

    @Test func overnightGlucoseDetectsLows() {
        let d = today.startOfDay
        let w = DateInterval(start: d.adding(minutes: -60), end: d.adding(minutes: 7 * 60))
        let pts = (0..<32).map { i in
            VitalPoint(time: w.start.addingTimeInterval(Double(i) * 900), kind: .glucose, value: (8...11).contains(i) ? 3.4 : 5.6, value2: nil, context: .night)
        }
        let r = OvernightAnalyzer.glucose(pts, window: w, profile: ProfileSnapshot())
        #expect(r.isContinuous)
        #expect(r.lowAlert)
    }

    @Test func demoHasOvernightCGM() throws {
        let container = try ModelContainer(for: Schema(PulseSchema.models),
                                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        let ctx = container.mainContext
        DemoDataGenerator.populate(ctx, now: today)
        let a = DataHub.analytics(in: ctx, now: today)
        let vitals = try ctx.fetch(FetchDescriptor<VitalReading>()).map(\.point)
        let w = OvernightAnalyzer.nightWindow(for: today, today: a.today)
        let g = OvernightAnalyzer.glucose(vitals, window: w, profile: a.profile)
        #expect(g.isContinuous, "window \(w), glucose count \(vitals.filter { $0.kind == .glucose }.count), in window \(g.points.count)")
    }
}

// MARK: - Professional modules

@Suite("Professional modules")
struct ProModuleTests {
    private func run(_ daysAgo: Int, km: Double, minutes: Double, rpe: Int = 4, hr: Double? = 145) -> WorkoutPoint {
        WorkoutPoint(start: today.adding(days: -daysAgo), type: .run, minutes: minutes, avgHR: hr, rpe: rpe, distanceKm: km)
    }

    @Test func trainingLoadFlagsRapidIncrease() {
        // Three steady weeks, then a week with double the load.
        var w: [WorkoutPoint] = []
        for d in stride(from: 27, through: 7, by: -2) { w.append(run(d, km: 6, minutes: 40)) }
        for d in 0...6 { w.append(run(d, km: 8, minutes: 60)) }
        let s = TrainingLoad.status(w, now: today)
        #expect(s.ratio != nil)
        #expect(s.zone == .high)
        let steady = TrainingLoad.status(w.filter { $0.start < today.adding(days: -6) } + [run(1, km: 6, minutes: 40), run(3, km: 6, minutes: 40), run(5, km: 6, minutes: 40)], now: today)
        #expect(steady.zone == .optimal || steady.zone == .low)
    }

    @Test func trainingLoadNeedsHistory() {
        let s = TrainingLoad.status([run(1, km: 5, minutes: 30)], now: today)
        #expect(s.zone == .insufficient)
        #expect(s.ratio == nil)
    }

    @Test func riegelPredictionAndSplits() {
        // 10 km in 50 min → about 3:49 for the marathon.
        let m = RacePredictor.riegel(distanceKm: 10, minutes: 50)
        #expect(abs(m - 229) < 3)
        let p = RacePredictor.predict([run(3, km: 10, minutes: 50, rpe: 7), run(5, km: 6, minutes: 42)], now: today)
        #expect(p?.basisKm == 10)
        let splits = RacePredictor.splits(targetMinutes: 240)
        #expect(splits.last?.km == 42.195)
        #expect(abs((splits.last?.minutes ?? 0) - 240) < 0.01)
        #expect(RacePredictor.clockText(125.5) == "2:05:30")
    }

    @Test func hrZonesRespectThresholdAndCap() {
        var p = ProfileSnapshot()
        p.thresholdHR = 160
        let (zones, basis) = HRZones.zones(profile: p)
        #expect(zones.count == 5)
        #expect(basis.contains("阈值心率"))
        #expect(zones[3].low == 152 && zones[4].low == 160)
        p.thresholdHR = nil
        p.hrCap = 130
        let capped = HRZones.zones(profile: p).zones
        #expect(capped.contains { $0.aboveCap })
        #expect(!capped[0].aboveCap)
    }

    @Test func lactateThresholdsInterpolate() {
        let t0 = today
        let stages = [(1.2, 138.0), (1.6, 148.0), (2.3, 157.0), (3.8, 168.0), (5.0, 175.0)].enumerated().map { i, v in
            LactateStage(time: t0.addingTimeInterval(Double(i) * 300), lactate: v.0, hr: v.1, pace: nil)
        }
        let r = LactateAnalyzer.analyze(stages)
        #expect(r?.baseline == 1.2)
        #expect(r?.lt1HR != nil)
        // 4.0 sits between 3.8 @168 and 5.0 @175.
        #expect(abs((r?.lt2HR ?? 0) - 169.2) < 0.5)
        #expect(LactateAnalyzer.pace(in: "递增测试第 2 级 · 配速 7:00/km") == "7:00")
    }

    @Test func homeBloodPressureProtocol() {
        var p = ProfileSnapshot()
        p.bpTargetSys = 130; p.bpTargetDia = 80
        var v: [VitalPoint] = []
        for i in 0..<7 {
            let d = today.startOfDay.adding(days: -i)
            v.append(VitalPoint(time: d.adding(minutes: 7 * 60), kind: .bloodPressure, value: 138, value2: 86, context: .morning))
            v.append(VitalPoint(time: d.adding(minutes: 21 * 60), kind: .bloodPressure, value: 132, value2: 82, context: .bedtime))
        }
        let s = BPAnalyzer.homeMonitoring(v.filter { $0.time <= today.addingTimeInterval(14 * 3600) }, profile: p, now: today.addingTimeInterval(14 * 3600))
        #expect(s.progress >= 0.9)
        #expect(s.aboveHomeThreshold)
        #expect(Int(s.morningAvg?.sys ?? 0) == 138)
    }

    @Test func glucoseMealExerciseAndLows() {
        let start = today.startOfDay
        var g: [VitalPoint] = []
        for i in 0..<96 {
            let t = start.addingTimeInterval(Double(i) * 900)
            var value = 5.5
            if (30...37).contains(i) { value = 5.5 + Double(min(i - 30, 37 - i)) * 1.0 }   // breakfast peak ~ +3.5
            if (8...10).contains(i) { value = 3.4 }                                         // 02:00–02:30 low
            if (70...73).contains(i) { value = 5.5 - Double(i - 69) * 0.4 }                // during exercise
            g.append(VitalPoint(time: t, kind: .glucose, value: value, context: .random))
        }
        let meals = [MealInfo(time: start.addingTimeInterval(30 * 900), kind: .breakfast, carbs: 60, note: "")]
        let mr = GlucoseAnalyzer.mealResponses(g, meals: meals)
        #expect(mr.count == 1)
        #expect((mr.first?.rise ?? 0) >= 3)
        let ex = GlucoseAnalyzer.exerciseResponses(g, sessions: [WorkoutPoint(start: start.addingTimeInterval(69 * 900), type: .run, minutes: 60)])
        #expect(ex.first.map { $0.change < 0 } == true)
        let lows = GlucoseAnalyzer.lowEpisodes(g, low: 3.9)
        #expect(lows.count == 1)
        #expect(lows.first?.nocturnal == true)
        #expect((lows.first?.minutes ?? 0) >= 30)
    }

    @Test func marathonStrengthNeverSharesQualityDay() {
        var p = ProfileSnapshot()
        p.availableWeekdays = [3, 5, 7, 1]
        let race = RaceInfo(name: "测试", date: today.adding(days: 140), targetMinutes: 270, startDate: today.adding(days: -14),
                            currentWeeklyKm: 20, longestRunKm: 12, fuelCarbsPerHour: 45)
        let w = MarathonPlanner.week(profile: p, race: race, weekStart: today.weekStart)
        let quality = Set(w.sessions.filter { $0.kind == .quality || $0.kind == .long }.map(\.weekday))
        let strength = w.sessions.filter { $0.kind == .strength }.map(\.weekday)
        #expect(!strength.isEmpty)
        #expect(strength.allSatisfy { !quality.contains($0) })
    }

    @Test func cardioAdherenceAndWeightGain() {
        var days = series(10) { _ in 65 }
        for i in 0..<10 { days[i].medsTaken = i != 3 }
        let r = CardioAnalyzer.medicationAdherence(days, now: today)
        #expect(r.recorded == 10 && r.missed == 1)
        let w = [VitalPoint(time: today.adding(days: -3), kind: .weight, value: 70, context: .morning),
                 VitalPoint(time: today, kind: .weight, value: 72.4, context: .morning)]
        #expect(CardioAnalyzer.rapidWeightGain(w, now: today) != nil)
        var p = ProfileSnapshot()
        p.conditions = [.coronaryDisease]
        #expect(CardioAnalyzer.exerciseGuidance(profile: p).contains { $0.contains("立即停止") })
    }
}

// MARK: - 复盘 coach

@Suite("Review coach")
@MainActor
struct ReviewCoachTests {
    @Test func weekSnapshotComparesSameSpan() {
        var days = series(14) { 66 + wiggle($0) }
        for i in 0..<14 { days[i].sleepMinutes = i >= 7 ? 450 : 400; days[i].exerciseMinutes = 30 }
        let ws = today.weekStart
        let span = today.daysSince(ws) + 1
        let cur = ReviewCoach.week(days: days, plan: [], weekStart: ws, span: span, source: .device, now: today)
        let prev = ReviewCoach.week(days: days, plan: [], weekStart: ws.adding(days: -7), span: span, source: .device, now: today)
        #expect(cur.daysLogged == span)
        #expect(prev.daysLogged == span)
        #expect(cur.activeMinutes == prev.activeMinutes)
    }

    @Test func briefLeadsWithMissedTraining() throws {
        var cur = WeekSnapshot(weekStart: today.weekStart, span: 3, rhr: 70, sleepHours: 7, activeMinutes: 10, energy: 3, alcohol: 0,
                               stress: 3, done: 0, total: 2, completion: 0, missedWeekdays: [2], daysLogged: 3)
        var prev = cur
        prev.rhr = 73; prev.sleepHours = 6.5; prev.alcohol = 3; prev.completion = 0.5; prev.done = 1
        let c = AgentContext.make(profile: ProfileSnapshot(), name: "测试", days: series(30) { 70 + wiggle($0) }, plan: [], workouts: [],
                                  vitals: [], events: [], stopBang: [], baselineSetAt: nil, raceName: "", now: today)
        let b = ReviewCoach.brief(current: cur, previous: prev, context: c, isCurrentWeek: true, nextTarget: (90, ""))
        #expect(b.headline.hasPrefix("训练还没跟上"))
        #expect(b.story?.main.contains("周一的训练没练成") == true)
        cur.completion = 1; cur.done = 2
        #expect(!ReviewCoach.brief(current: cur, previous: prev, context: c, isCurrentWeek: true, nextTarget: (90, "")).headline.contains("没跟上"))
    }

    @Test func nextWeekLineFollowsCompletion() {
        #expect(ReviewCoach.nextWeekLine(current: 150, next: 165, completion: 0.9, isCurrentWeek: true).contains("增加到 165"))
        #expect(ReviewCoach.nextWeekLine(current: 150, next: 120, completion: 0.4, isCurrentWeek: false).contains("降到 120"))
        #expect(ReviewCoach.nextWeekLine(current: 150, next: 150, completion: nil, isCurrentWeek: true).contains("保持"))
    }

    @Test func demoProducesProposalsAndReflection() throws {
        let container = try ModelContainer(for: Schema(PulseSchema.models),
                                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        let ctx = container.mainContext
        DemoDataGenerator.populate(ctx, now: today)
        DataHub.ensureWeekPlan(in: ctx, now: today)
        let p = DataHub.profile(in: ctx)!
        let a = DataHub.analytics(in: ctx, now: today)
        let items = (try? ctx.fetch(FetchDescriptor<PlanItem>())) ?? []
        let sessions = (try? ctx.fetch(FetchDescriptor<ActivitySession>())) ?? []
        let c = AgentContext.make(profile: a.profile, name: p.displayName, days: a.days, plan: items.map(\.snapshot),
                                  workouts: sessions.map(\.point), vitals: [], events: [], stopBang: p.stopBangAnswers,
                                  baselineSetAt: p.baselineSetAt, raceName: p.raceName, now: today)
        let proposals = ReviewCoach.proposals(context: c, handledInsights: ["alcohol-rhr"], taskTitles: [])
        // Thursdays are often skipped in the demo: the agent proposes taking them out.
        #expect(proposals.contains { if case .dropWeekday(5) = $0.action { return true } else { return false } })
        #expect(proposals.count <= 3)
        #expect(!proposals.contains { $0.id == "exp-alcohol-rhr" })
        let steps = ReviewCoach.reflection(context: c, week: ReviewCoach.week(days: a.days, plan: c.plan, weekStart: today.weekStart.adding(days: -7), span: 7, source: .device, now: today))
        #expect(steps.map(\.id) == ["keep", "change", "focus"])
        #expect(steps.allSatisfy { !$0.options.isEmpty })
        let v = ReviewCoach.verdict(context: c)
        #expect(v.kind == .fits || v.kind == .partly)
    }
}

// MARK: - Next week & cloud model

@Suite("Next week plan and cloud model")
@MainActor
struct NextWeekAndCloudTests {
    private func demo() throws -> (AgentContext, ModelContext, ModelContainer) {
        let container = try ModelContainer(for: Schema(PulseSchema.models),
                                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        let ctx = container.mainContext
        DemoDataGenerator.populate(ctx, now: today)
        DataHub.ensureWeekPlan(in: ctx, now: today)
        let p = DataHub.profile(in: ctx)!
        let a = DataHub.analytics(in: ctx, now: today)
        let items = (try? ctx.fetch(FetchDescriptor<PlanItem>())) ?? []
        let sessions = (try? ctx.fetch(FetchDescriptor<ActivitySession>())) ?? []
        let c = AgentContext.make(profile: a.profile, name: p.displayName, days: a.days, plan: items.map(\.snapshot),
                                  workouts: sessions.map(\.point), vitals: [], events: [], stopBang: p.stopBangAnswers,
                                  baselineSetAt: p.baselineSetAt, raceName: p.raceName, now: today)
        return (c, ctx, container)
    }

    @Test func reviewMentionedDayIsDroppedNextWeekOnly() throws {
        let (c, ctx, container) = try demo()
        _ = container
        let ws = today.weekStart.adding(days: -7)
        var w = ReviewCoach.week(days: c.days, plan: c.plan, weekStart: ws, span: 7, source: .device, now: today)
        w.missedWeekdays = [5]
        let plan = ReviewCoach.nextWeekPlan(context: c, week: w, notes: ReviewNotes(change: "周四的训练、工作太忙", focus: "按时上床"))
        #expect(plan.weekStart == today.weekStart.adding(days: 7))
        #expect(!plan.sessions.contains { $0.weekday == 5 && $0.kind.isTraining })
        #expect(plan.changes.contains { $0.title.contains("周四") })
        #expect(plan.changes.contains { $0.title.contains("缩短") })
        #expect(plan.changes.contains { $0.title.contains("睡眠") })
        // Applying writes next week's items without touching the profile's training days.
        DataHub.applyNextWeekPlan(plan, in: ctx)
        let next = DataHub.planItems(weekStart: plan.weekStart, in: ctx)
        #expect(next.count == plan.sessions.count)
        let p = DataHub.profile(in: ctx)!
        #expect(p.availableWeekdays.contains(5))
        #expect(p.nextWeekTargetMinutes == plan.targetMinutes)
        // When next week begins, its target is adopted and the plan is kept.
        DataHub.ensureWeekPlan(in: ctx, now: plan.weekStart.adding(days: 1))
        #expect(p.weeklyTargetMinutes == plan.targetMinutes)
        #expect(p.nextWeekTargetMinutes == nil)
        // The adopted marker lasts through that week and clears the week after.
        #expect(p.nextWeekPlannedFor == plan.weekStart)
        DataHub.ensureWeekPlan(in: ctx, now: plan.weekStart.adding(days: 8))
        #expect(p.nextWeekPlannedFor == nil)
        #expect(DataHub.planItems(weekStart: plan.weekStart, in: ctx).count == plan.sessions.count)
    }

    @Test func anthropicStreamParsing() {
        #expect(CloudModelClient.parse(line: #"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"你好"}}"#, provider: .anthropic) == .text("你好"))
        #expect(CloudModelClient.parse(line: #"data: {"type":"message_stop"}"#, provider: .anthropic) == .done)
        #expect(CloudModelClient.parse(line: "event: ping", provider: .anthropic) == .ignore)
        #expect(CloudModelClient.parse(line: #"data: {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#, provider: .anthropic) == .error("Overloaded"))
    }

    @Test func openAIStreamParsing() {
        #expect(CloudModelClient.parse(line: #"data: {"choices":[{"delta":{"content":"建议"}}]}"#, provider: .openAICompatible) == .text("建议"))
        #expect(CloudModelClient.parse(line: "data: [DONE]", provider: .openAICompatible) == .done)
        #expect(CloudModelClient.parse(line: #"data: {"choices":[{"delta":{}}]}"#, provider: .openAICompatible) == .ignore)
    }

    @Test func requestsAreBuiltPerProvider() throws {
        let a = try CloudModelClient(provider: .anthropic, baseURL: "https://api.anthropic.com/v1/", model: "claude-sonnet-5-5", apiKey: "k")
            .request(system: "s", prompt: "p", maxTokens: 10)
        #expect(a.url?.absoluteString == "https://api.anthropic.com/v1/messages")
        #expect(a.value(forHTTPHeaderField: "x-api-key") == "k")
        #expect(a.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        let o = try CloudModelClient(provider: .openAICompatible, baseURL: "https://example.com/v1", model: "m", apiKey: "k")
            .request(system: "s", prompt: "p", maxTokens: 10)
        #expect(o.url?.absoluteString == "https://example.com/v1/chat/completions")
        #expect(o.value(forHTTPHeaderField: "Authorization") == "Bearer k")
        #expect(throws: CloudModelError.badURL) {
            try CloudModelClient(provider: .openAICompatible, baseURL: "http://insecure.example.com", model: "m", apiKey: "k")
                .request(system: "s", prompt: "p", maxTokens: 10)
        }
    }

    @Test func openRouterRequestsAndPresets() throws {
        let r = try CloudModelClient(provider: .openRouter, baseURL: CloudProvider.openRouter.defaultBaseURL,
                                     model: CloudProvider.openRouter.defaultModel, apiKey: "k")
            .request(system: "s", prompt: "p", maxTokens: 10)
        #expect(r.url?.absoluteString == "https://openrouter.ai/api/v1/chat/completions")
        #expect(r.value(forHTTPHeaderField: "Authorization") == "Bearer k")
        #expect(r.value(forHTTPHeaderField: "X-Title") == "Pulse")
        let body = try JSONSerialization.jsonObject(with: r.httpBody ?? Data()) as? [String: Any]
        #expect(body?["model"] as? String == "anthropic/claude-sonnet-5.5")
        #expect(CloudModelClient.parse(line: ": OPENROUTER PROCESSING", provider: .openRouter) == .ignore)
        #expect(CloudModelClient.parse(line: #"data: {"choices":[{"delta":{"content":"好"}}]}"#, provider: .openRouter) == .text("好"))
        #expect(CloudModelClient.errorMessage(in: #"{"error":{"message":"No auth credentials found","code":401}}"#) == "No auth credentials found")
        #expect(OpenRouterModels.groups.first == "Anthropic")
        #expect(OpenRouterModels.presets.allSatisfy { $0.model.contains("/") })
        #expect(CloudProvider.openRouter.launchKeyVariable == "PULSE_OPENROUTER_KEY")
    }

    @Test func cloudDigestIsAnonymous() throws {
        let (c, _, container) = try demo()
        _ = container
        #expect(!HealthAgent.digest(c, anonymous: true).contains(c.name))
        #expect(HealthAgent.digest(c).contains(c.name))
    }
}

// MARK: - Sample users with poor adherence

@Suite("Demo personas")
@MainActor
struct DemoPersonaTests {
    private func load(_ persona: DemoPersona) throws -> (AgentContext, ModelContext, ModelContainer) {
        let container = try ModelContainer(for: Schema(PulseSchema.models),
                                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        let ctx = container.mainContext
        DemoDataGenerator.populate(ctx, persona: persona, now: today)
        DataHub.ensureWeekPlan(in: ctx, now: today)
        let p = DataHub.profile(in: ctx)!
        let a = DataHub.analytics(in: ctx, now: today)
        let items = (try? ctx.fetch(FetchDescriptor<PlanItem>())) ?? []
        let sessions = (try? ctx.fetch(FetchDescriptor<ActivitySession>())) ?? []
        let vitals = (try? ctx.fetch(FetchDescriptor<VitalReading>())) ?? []
        let events = ((try? ctx.fetch(FetchDescriptor<HealthEvent>())) ?? []).filter { $0.status.isActive }
        let c = AgentContext.make(profile: a.profile, name: p.displayName, days: a.days, plan: items.map(\.snapshot),
                                  workouts: sessions.map(\.point), vitals: vitals.map(\.point),
                                  events: events.map { AgentEvent(title: $0.title, severity: $0.severity, date: $0.relatedDate, guidance: $0.guidance) },
                                  stopBang: p.stopBangAnswers, baselineSetAt: p.baselineSetAt, raceName: p.raceName,
                                  targetRHR: p.targetRHR, now: today)
        return (c, ctx, container)
    }

    /// The 复盘 cards are cached and generated per facts key, so the same records must always give the
    /// same facts (no dictionary or set order leaking into the text).
    @Test(arguments: [DemoPersona.xiaolin, .chenjie, .linyue, .wangjianguo])
    func reviewFactsAreStable(_ persona: DemoPersona) throws {
        let (c, ctx, container) = try load(persona)
        _ = container
        let p = DataHub.profile(in: ctx)!
        func keys(_ c: AgentContext) -> [String] {
            let cur = ReviewCoach.week(days: c.days, plan: c.plan, weekStart: c.weekStart, span: 4, source: c.trend.dominantSource, now: c.logicalToday)
            let prev = ReviewCoach.week(days: c.days, plan: c.plan, weekStart: c.weekStart.adding(days: -7), span: 4, source: c.trend.dominantSource, now: c.logicalToday)
            let brief = ReviewCoach.brief(current: cur, previous: prev, context: c, isCurrentWeek: true, nextTarget: (90, ""))
            let proposals = ReviewCoach.proposals(context: c, handledInsights: [], taskTitles: [])
            let plan = ReviewCoach.nextWeekPlan(context: c, week: cur, notes: nil)
            let week = ReviewCoach.weeklyFacts(brief: brief, weekLabel: "w", isCurrentWeek: true, proposals: proposals, plan: plan)
            let long = ReviewCoach.longTermFacts(context: c, verdict: ReviewCoach.verdict(context: c), strategy: ReviewCoach.strategy(context: c))
            return [week.text, long.text]
        }
        let first = keys(c)
        for _ in 0..<8 {
            let again = AgentContext.make(profile: c.profile, name: c.name, days: c.days, plan: c.plan, workouts: c.workouts, vitals: c.vitals,
                                          events: c.openEvents, stopBang: p.stopBangAnswers, baselineSetAt: p.baselineSetAt, raceName: c.raceName,
                                          targetRHR: c.targetRHR, now: c.now)
            #expect(keys(again) == first)
        }
    }

    /// 所处阶段 follows each person's goals, and the records — not the calendar — decide the stage.
    @Test func journeysFollowGoalsAndRecords() throws {
        let (chen, _, k1) = try load(.chenjie)
        _ = k1
        let paths = GoalJourneys.paths(chen)
        #expect(paths.map(\.id) == ["rhr", "energy"])
        // 120 days in, but most planned training is not done: still building the routine.
        let rhr = try #require(paths.first)
        #expect(rhr.stages[rhr.current].id == "habits")
        #expect(rhr.standing.toPass?.contains("60%") == true)

        // A stage once reached is kept, even though the routine has slipped since.
        var kept = chen.profile
        kept.journeyReached = ["rhr": 3]
        let again = AgentContext.make(profile: kept, name: chen.name, days: chen.days, plan: chen.plan, workouts: chen.workouts, vitals: chen.vitals,
                                      events: [], stopBang: [], baselineSetAt: nil, raceName: chen.raceName, now: chen.now)
        let keptRHR = try #require(GoalJourneys.paths(again).first)
        #expect(keptRHR.current >= 3)

        let (wang, _, k2) = try load(.wangjianguo)
        _ = k2
        #expect(GoalJourneys.paths(wang).map(\.id) == ["rhr", "bp", "glucose"])
        // The page's one next step: a care step that needs the doctor comes first …
        #expect(GoalJourneys.nextStep(wang)?.contains("医生") == true)
        // … otherwise the first goal's, and the 长期总结 ends on it.
        let step = try #require(GoalJourneys.nextStep(chen))
        #expect(step == rhr.standing.next)
        let long = ReviewCoach.longTermFacts(context: chen, verdict: ReviewCoach.verdict(context: chen), strategy: ReviewCoach.strategy(context: chen))
        #expect(long.fallback.summary.contains("接下来，" + step.trimmingCharacters(in: CharacterSet(charactersIn: "。"))))

        var p = ProfileSnapshot()
        p.goals = [.event]
        let fresh = AgentContext.make(profile: p, name: "测试", days: [], plan: [], workouts: [], vitals: [], events: [], stopBang: [],
                                      baselineSetAt: nil, raceName: "", now: today)
        let race = GoalJourneys.paths(fresh)
        #expect(race.map(\.id) == ["race"])
        #expect(race[0].stages[race[0].current].id == "set")
        p.goals = []
        let none = GoalJourneys.paths(AgentContext.make(profile: p, name: "测试", days: [], plan: [], workouts: [], vitals: [], events: [],
                                                        stopBang: [], baselineSetAt: nil, raceName: "", now: today))
        #expect(none.map(\.id) == ["rhr"] && none[0].current == 0)
    }

    /// A demo opened again days later is regenerated, so today has a night and a readiness score.
    @Test func staleDemoIsDetected() throws {
        let container = try ModelContainer(for: Schema(PulseSchema.models), configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        let ctx = container.mainContext
        DemoDataGenerator.populate(ctx, persona: .chenjie, now: today.adding(days: -3))
        #expect(DemoDataGenerator.isStale(in: ctx, now: today))
        DemoDataGenerator.populate(ctx, persona: .chenjie, now: today)
        #expect(!DemoDataGenerator.isStale(in: ctx, now: today))
    }

    /// The weekly proposal, next week's plan and the long-term strategy name the same hard day.
    @Test func hardDayIsNamedOnce() throws {
        let (c, _, container) = try load(.chenjie)
        _ = container
        let hardest = try #require(InsightEngine.missedWeekdays(plan: c.plan, now: c.now).first)
        let drop = ReviewCoach.proposals(context: c, handledInsights: [], taskTitles: []).first { $0.id.hasPrefix("drop-") }
        #expect(drop?.id == "drop-\(hardest.weekday)")
        let cur = ReviewCoach.week(days: c.days, plan: c.plan, weekStart: c.weekStart, span: 4, source: c.trend.dominantSource, now: c.logicalToday)
        let plan = ReviewCoach.nextWeekPlan(context: c, week: cur, notes: nil)
        let day = Weekday.name(hardest.weekday)
        #expect(plan.changes.contains { $0.title == "\(day)改为日常活动日" })
        #expect(c.planFit.first?.title.hasPrefix(day) == true)
    }

    @Test(arguments: [DemoPersona.chenjie, .linyue, .wangjianguo])
    func lowAdherencePersonas(_ persona: DemoPersona) throws {
        let (c, ctx, container) = try load(persona)
        _ = container
        let p = DataHub.profile(in: ctx)!
        #expect(p.nickname == persona.name)
        #expect(p.demoPersona == persona.rawValue)
        let plan = c.adherence("plan")
        let checkins = c.adherence("checkin")
        let assessment = HealthAgent.assess(c)
        let proposals = ReviewCoach.proposals(context: c, handledInsights: [], taskTitles: [])
        print("[\(persona.name)] 计划完成 \(Int((plan?.rate ?? 0) * 100))% · 晨起记录 \(Int((checkins?.rate ?? 0) * 100))% · 静息心率 \(c.trend.avg28?.noDecimal ?? "-")（基线 \(c.trend.baseline?.noDecimal ?? "-")）· 睡眠 \(((c.sleep.avgMinutes ?? 0) / 60).oneDecimal)h \(c.sleep.regularityText) · 目标 \(c.profile.weeklyTargetMinutes) 分钟 · 结论：\(assessment.headline) · 建议：\(proposals.map(\.title).joined(separator: "；"))")
        print("[\(persona.name)] 维度：\(c.progress.dimensions.map { "\($0.name)\($0.status.label) \($0.from ?? "")→\($0.to ?? "")" }.joined(separator: "；"))")
        #expect((plan?.rate ?? 1) < 0.6, "plan adherence should be poor")
        #expect((checkins?.rate ?? 1) < 0.6, "check-ins should be sparse")
        #expect(c.dimension("rhr")?.status != .improved)
        #expect(c.profile.weeklyTargetMinutes <= p.weeklyTimeBudget)
        #expect(!assessment.watch.isEmpty || !proposals.isEmpty)
        #expect(ReviewCoach.verdict(context: c).kind != .fits)
    }

    @Test func chenjieHasHighBloodPressureAndBreathingCues() throws {
        let (c, _, container) = try load(.chenjie)
        _ = container
        #expect((c.bp.avgSys ?? 0) >= 133)
        #expect(c.breathing.level != .none)
        #expect((c.sleep.avgMinutes ?? 999) < c.profile.sleepNeedMinutes - 30)
    }

    @Test func linyueHasIrregularSleepAndGaps() throws {
        let (c, _, container) = try load(.linyue)
        _ = container
        #expect((c.sleep.bedtimeSD ?? 0) > 60)
        #expect(c.days.count < 115)
    }

    @Test func wangjianguoHasPoorGlucoseControlAndMissedMeds() throws {
        let (c, ctx, container) = try load(.wangjianguo)
        _ = container
        print("[王建国] TIR \(Int((c.glucose.tir ?? 0) * 100))% TBR \(String(format: "%.1f", (c.glucose.tbr ?? 0) * 100))% 低血糖 \(c.lows.count) 次 · 服药 \(Int((CardioAnalyzer.medicationAdherence(c.days, now: today).rate ?? 0) * 100))% · 血压 \(Int(c.bp.avgSys ?? 0))/\(Int(c.bp.avgDia ?? 0))")
        #expect(c.glucose.isContinuous)
        #expect((c.glucose.tir ?? 1) < 0.7)
        #expect(c.lows.count >= 2)
        let adherence = CardioAnalyzer.medicationAdherence(c.days, now: today)
        #expect((adherence.rate ?? 1) < 0.85)
        #expect((c.bp.avgSys ?? 0) >= 135)
        let tasks = (try? ctx.fetch(FetchDescriptor<CareTask>())) ?? []
        #expect(tasks.contains { !$0.done && ($0.due ?? .distantFuture) < today })
        #expect(HealthAgent.reply(to: "我的血糖控制得怎么样？", context: c).text.contains("低于"))
    }
}

// MARK: - Health Agent

@Suite("Health Agent")
@MainActor
struct HealthAgentTests {
    private func demoContext() throws -> AgentContext {
        let container = try ModelContainer(for: Schema(PulseSchema.models),
                                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        let ctx = container.mainContext
        DemoDataGenerator.populate(ctx, now: today)
        DataHub.ensureWeekPlan(in: ctx, now: today)
        let p = DataHub.profile(in: ctx)!
        let a = DataHub.analytics(in: ctx, now: today)
        let items = (try? ctx.fetch(FetchDescriptor<PlanItem>())) ?? []
        let sessions = (try? ctx.fetch(FetchDescriptor<ActivitySession>())) ?? []
        let vitals = (try? ctx.fetch(FetchDescriptor<VitalReading>())) ?? []
        return AgentContext.make(profile: a.profile, name: p.displayName, days: a.days, plan: items.map(\.snapshot),
                                 workouts: sessions.map(\.point), vitals: vitals.map(\.point), events: [],
                                 stopBang: p.stopBangAnswers, baselineSetAt: p.baselineSetAt, raceName: p.raceName,
                                 targetRHR: p.targetRHR, now: today)
    }

    @Test func intentsRouteByPriority() {
        #expect(HealthAgent.intent(for: "我现在胸痛，喘不上气") == .emergency)
        #expect(HealthAgent.intent(for: "胰岛素要加量吗") == .meds)
        #expect(HealthAgent.intent(for: "为什么静息心率最近没怎么降？") == .rhr)
        #expect(HealthAgent.intent(for: "我的 HRV 怎么样") == .hrv)
        #expect(HealthAgent.intent(for: "我需要去看睡眠门诊吗？") == .breathing)
        #expect(HealthAgent.intent(for: "今天适合运动吗？") == .trainingCheck)
        #expect(HealthAgent.intent(for: "饮酒对我的影响有多大？") == .alcohol)
        #expect(HealthAgent.intent(for: "早上的血压偏高怎么办") == .bp)
        #expect(HealthAgent.intent(for: "总结一下今天，明天要注意什么？") == .daySummary)
        #expect(HealthAgent.intent(for: "接下来我该关注什么？") == .next)
        #expect(HealthAgent.intent(for: "天气怎么样") == .weather)
        #expect(HealthAgent.intent(for: "这几天的天气适合户外训练吗？") == .weather)
        #expect(HealthAgent.intent(for: "明天下雨还能跑步吗？") == .trainingCheck)
    }

    @Test func emergencyAnswerIsFixedAndUrgent() throws {
        let c = try demoContext()
        let r = HealthAgent.reply(to: "突然胸口痛，还出冷汗", context: c)
        #expect(r.urgent)
        #expect(r.text.contains("120"))
    }

    @Test func neverGivesMedicationAdvice() throws {
        let c = try demoContext()
        let r = HealthAgent.reply(to: "我可以停药吗", context: c)
        #expect(r.intent == .meds)
        #expect(r.text.contains("医生") && r.text.contains("别自己停"))
    }

    @Test func assessmentIsGroundedInDemoData() throws {
        let c = try demoContext()
        let a = HealthAgent.assess(c)
        #expect(!a.headline.isEmpty)
        #expect(a.summary.contains("bpm"))
        #expect(a.nextSteps.count == 3)
        #expect(!a.questions.isEmpty)
        // The demo persona drinks at weekends: the observed association should surface somewhere.
        #expect(a.watch.contains { $0.title.contains("饮酒") } || a.nextSteps.contains { $0.title.contains("饮酒") })
        #expect(a.basis.hasPrefix("依据"))
    }

    @Test func answersCorrectFalsePremise() throws {
        let c = try demoContext()
        let r = HealthAgent.reply(to: "为什么静息心率最近没怎么降？", context: c)
        #expect(r.intent == .rhr)
        #expect(r.text.contains("其实在下降"))
        #expect(r.destination == .heart)
    }

    @Test func answersCoverEachTopic() throws {
        let c = try demoContext()
        for q in ["我的睡眠怎么样", "我的血压怎么样", "我的血糖控制得怎么样", "马拉松目标现实吗", "这周训练完成得怎么样",
                  "咖啡对我睡眠有影响吗", "最近压力大", "饮食要注意什么", "我需要去看医生吗", "我最近整体怎么样", "你好"] {
            let r = HealthAgent.reply(to: q, context: c)
            #expect(r.intent != .unknown, "\(q) was not understood")
            #expect(r.text.count > 20, "\(q) answer too short")
            #expect(!r.text.contains("nan"))
        }
    }

    @Test func digestFitsOnDeviceContext() throws {
        let c = try demoContext()
        let d = HealthAgent.digest(c)
        #expect(d.contains("静息心率"))
        #expect(d.count < 1200)
    }
}

// MARK: - Plan changes in conversation, device guidance, Generative UI

@Suite("Agent plan changes, devices and generative UI")
@MainActor
struct AgentPlanDeviceTests {
    private func load(_ persona: DemoPersona, now: Date = today) throws -> (AgentContext, ModelContext, ModelContainer) {
        let container = try ModelContainer(for: Schema(PulseSchema.models),
                                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        let ctx = container.mainContext
        DemoDataGenerator.populate(ctx, persona: persona, now: today)
        DataHub.ensureWeekPlan(in: ctx, now: today)
        let p = DataHub.profile(in: ctx)!
        let a = DataHub.analytics(in: ctx, now: today)
        let items = (try? ctx.fetch(FetchDescriptor<PlanItem>())) ?? []
        let sessions = (try? ctx.fetch(FetchDescriptor<ActivitySession>())) ?? []
        let vitals = (try? ctx.fetch(FetchDescriptor<VitalReading>())) ?? []
        let c = AgentContext.make(profile: a.profile, name: p.displayName, days: a.days, plan: items.map(\.snapshot),
                                  workouts: sessions.map(\.point), vitals: vitals.map(\.point), events: [],
                                  stopBang: p.stopBangAnswers, baselineSetAt: p.baselineSetAt, raceName: p.raceName,
                                  targetRHR: p.targetRHR, now: now)
        return (c, ctx, container)
    }

    private func isTraining(_ items: [SessionSnapshot], _ wd: Int, _ ws: Date) -> Bool {
        items.contains { $0.day == PlanChat.day(wd, ws) && $0.kind.isTraining }
    }

    @Test func recognisesPlanAndDeviceRequests() {
        #expect(HealthAgent.intent(for: "周四加班没空，帮我调整一下") == .planChange)
        #expect(HealthAgent.intent(for: "把周三的训练改到周五") == .planChange)
        #expect(HealthAgent.intent(for: "膝盖有点疼，这周怎么练") == .planChange)
        #expect(HealthAgent.intent(for: "这周太累了，轻松一点") == .planChange)
        #expect(HealthAgent.intent(for: "跑步时手表测的心率准吗？") == .device)
        #expect(HealthAgent.intent(for: "CGM 贴在哪里比较好") == .device)
        #expect(HealthAgent.intent(for: "我的血糖控制得怎么样") == .glucose)
        #expect(HealthAgent.intent(for: "最近加班没时间睡觉") == .sleep)
        #expect(HealthAgent.intent(for: "跑步时胸痛") == .emergency)
        #expect(HealthAgent.intent(for: "下周计划怎么安排？") == .exercise)
    }

    @Test func lateNightQuestionIsAboutTheComingDay() throws {
        let night = Calendar.pulse.date(bySettingHour: 2, minute: 30, second: 0, of: today)!
        let (c, _, container) = try load(.xiaolin, now: night)
        _ = container
        let r = HealthAgent.reply(to: "明天是否适合做大力量训练", context: c)
        #expect(r.intent == .trainingCheck)
        #expect(r.text.hasPrefix("不建议"), "\(r.text)")
        #expect(r.text.contains("02:30"))
        #expect(TrainingCheck.targetDay("明天", now: night) == today.startOfDay)
        #expect(PlanChat.weekdays(in: "明天没空", now: night) == [today.weekday])
        #expect(HealthAgent.digest(c).contains("02:30"))
        // A score from a night that has not finished is never used.
        #expect(!r.text.contains("今天准备度"))
    }

    @Test func eveningAndNightAnswersFollowTheClock() throws {
        func at(_ h: Int, _ m: Int, dayOffset: Int = 0) -> Date {
            Calendar.pulse.date(bySettingHour: h, minute: m, second: 0, of: today.adding(days: dayOffset))!
        }
        // 21:00, a couple of hours before bed: an easy run is fine if it ends an hour before sleep; intervals are not.
        let (e, _, c1) = try load(.xiaolin, now: at(21, 0))
        _ = c1
        #expect(HealthAgent.reply(to: "现在适合跑步吗？", context: e).text.hasPrefix("可以"))
        #expect(HealthAgent.reply(to: "现在适合做间歇吗？", context: e).text.hasPrefix("现在不建议"))
        #expect(HealthAgent.reply(to: "今天准备度怎么样？", context: e).text.contains("今天早上的准备度"))
        // Past bedtime: no training now, no coffee, no drink; the overall view leaves out the morning score.
        let (n, _, c2) = try load(.xiaolin, now: at(23, 40))
        _ = c2
        #expect(HealthAgent.reply(to: "今天适合运动吗？", context: n).text.hasPrefix("现在不建议"))
        #expect(HealthAgent.reply(to: "现在喝杯咖啡可以吗？", context: n).text.contains("不建议再喝"))
        #expect(HealthAgent.reply(to: "今晚还能喝一杯酒吗？", context: n).text.contains("不建议再喝"))
        #expect(!HealthAgent.assess(n).summary.contains("今天准备度"))
        // 02:30: the summary is about the day that is ending, and readiness waits for the morning.
        let (d, _, c3) = try load(.xiaolin, now: at(2, 30))
        _ = c3
        #expect(d.logicalToday == today.startOfDay.adding(days: -1))
        let summary = HealthAgent.reply(to: "总结一下今天，明天要注意什么？", context: d).text
        #expect(summary.contains("现在先睡"))
        #expect(!summary.contains("比平时早 30 分钟上床"))
        #expect(HealthAgent.reply(to: "今天准备度怎么样？", context: d).text.contains("睡醒后才能评估"))
        #expect(HealthAgent.reply(to: "今天适合运动吗？", context: d).text.contains("「今天」按睡醒后的白天理解"))
        #expect(HealthAgent.reply(to: "熬夜后怎么恢复？", context: d).text.contains("起床时间尽量不变"))
    }

    @Test func reviewWeekFollowsTheSameDayRule() throws {
        // Monday 01:00: 复盘's "本周" is still the week that is ending, and "下周" is the one just begun.
        let monday = today.weekStart
        let night = Calendar.pulse.date(bySettingHour: 1, minute: 0, second: 0, of: monday)!
        let (c, _, container) = try load(.xiaolin, now: night)
        _ = container
        #expect(c.weekStart == monday.adding(days: -7))
        let span = c.logicalToday.daysSince(c.weekStart) + 1
        #expect(span == 7)
        let w = ReviewCoach.week(days: c.days, plan: c.plan, weekStart: c.weekStart, span: span, source: c.trend.dominantSource, now: c.logicalToday)
        #expect(w.total > 0)
        #expect(w.daysLogged >= 6)
        #expect(ReviewCoach.nextWeekPlan(context: c, week: w, notes: nil).weekStart == monday)
        // From 5 am it is the new week.
        let (d, _, container2) = try load(.xiaolin, now: Calendar.pulse.date(bySettingHour: 6, minute: 0, second: 0, of: monday)!)
        _ = container2
        #expect(d.weekStart == monday)
    }

    @Test func dayPhasesFollowTheFiveAmRule() {
        func at(_ h: Int, _ m: Int) -> Date { Calendar.pulse.date(bySettingHour: h, minute: m, second: 0, of: today)! }
        // Wake 07:00, bed 23:00: until 5 am it is still the previous night, so no morning assessment yet.
        #expect(DayPhase.current(at: at(2, 30), wakeMinutes: 420, bedtimeMinutes: 1380) == .review)
        #expect(DayPhase.current(at: at(4, 30), wakeMinutes: 420, bedtimeMinutes: 1380) == .review)
        #expect(DayPhase.current(at: at(5, 30), wakeMinutes: 420, bedtimeMinutes: 1380) == .morning)
        #expect(DayClock.logicalToday(at(4, 59)) == today.startOfDay.adding(days: -1))
        #expect(DayClock.logicalToday(at(5, 0)) == today.startOfDay)
    }

    @Test func startingTheDayEarlyEndsTheNight() {
        // A date far from the other tests, so the shared setting cannot affect them.
        let day = today.adding(days: 40)
        func at(_ h: Int, _ m: Int) -> Date { Calendar.pulse.date(bySettingHour: h, minute: m, second: 0, of: day)! }
        defer { DayClock.undoEarlyStart() }
        #expect(!DayClock.canStartEarly(at(2, 30)))
        #expect(DayClock.canStartEarly(at(4, 15)))
        DayClock.startEarly(at: at(4, 20))
        #expect(!DayClock.isBeforeWake(at(4, 25)))
        #expect(DayClock.logicalToday(at(4, 25)) == day.startOfDay)
        #expect(DayPhase.current(at: at(4, 25), wakeMinutes: 420, bedtimeMinutes: 1380) == .morning)
        #expect(DayClock.canUndoEarlyStart(at(4, 24)))
        #expect(!DayClock.canUndoEarlyStart(at(4, 30)))
        #expect(!DayClock.canStartEarly(at(4, 25)))
        // It only applies to that early morning; the next night follows the usual rule again.
        #expect(DayClock.isBeforeWake(Calendar.pulse.date(bySettingHour: 2, minute: 0, second: 0, of: day.adding(days: 1))!))
        DayClock.undoEarlyStart()
        #expect(DayClock.isBeforeWake(at(4, 25)))
    }

    @Test func modelPromptCarriesDataAndKeepsTheConclusion() throws {
        let night = Calendar.pulse.date(bySettingHour: 2, minute: 30, second: 0, of: today)!
        let (c, _, container) = try load(.xiaolin, now: night)
        _ = container
        let r = HealthAgent.reply(to: "明天是否适合做大力量训练", context: c)
        let prompt = HealthAgent.modelPrompt(question: "明天是否适合做大力量训练", history: [], context: c, reply: r, anonymous: false)
        #expect(prompt.contains("【数据】"))
        #expect(prompt.contains("静息心率"))
        #expect(prompt.contains("02:30"))
        let k = try #require(r.conclusion)
        #expect(prompt.contains(k))
        // A model answer that drops or flips the verdict gets it put back in front; labels are stripped.
        #expect(HealthAgent.finalize("结论：明天适合练，注意热身。", of: r).hasPrefix(k))
        #expect(HealthAgent.finalize(k + "现在先睡。", of: r) == k + "现在先睡。")
        #expect(!HealthAgent.finalize("用户数据摘要：\n" + k, of: r).contains("用户数据摘要"))
        #expect(!HealthAgent.finalize("【现在】" + k, of: r).contains("【"))
        for echoed in ["第一句：", "第一句:", "第一句话：", "**第一句**：", "**第一句：**"] {
            #expect(HealthAgent.finalize(echoed + k, of: r) == k, "\(echoed)")
        }
        // While streaming: a label is stripped as soon as it is complete and held back while half-written.
        #expect(HealthAgent.stripLabels("第一句：根据当前", streaming: true) == "根据当前")
        #expect(HealthAgent.stripLabels("第一", streaming: true).isEmpty)
        #expect(HealthAgent.stripLabels("好的。\n【数", streaming: true) == "好的。")
        #expect(HealthAgent.stripLabels("第一次跑步", streaming: true) == "第一次跑步")
        // Anonymous prompts for the cloud leave the name out.
        #expect(!HealthAgent.modelPrompt(question: "我最近整体怎么样？", history: [], context: c,
                                         reply: HealthAgent.reply(to: "我最近整体怎么样？", context: c), anonymous: true).contains(c.name))
    }

    @Test func daytimeEasySessionIsNotBlocked() throws {
        let (c, _, container) = try load(.xiaolin)
        _ = container
        let r = HealthAgent.reply(to: "今天适合轻松跑吗", context: c)
        #expect(r.intent == .trainingCheck)
        #expect(!r.text.hasPrefix("不建议"), "\(r.text)")
        #expect(TrainingCheck.session(in: "明天能不能撸铁") == .heavyStrength)
        #expect(TrainingCheck.session(in: "后天适合跑长距离吗") == .long)
    }

    @Test func readsDaysAndMinutes() {
        #expect(PlanChat.weekdays(in: "周三到周五出差", now: today) == [4, 5, 6])
        #expect(PlanChat.weekdays(in: "把周三改到星期五", now: today) == [4, 6])
        #expect(PlanChat.weekdays(in: "明天没空", now: today) == [today.adding(days: 1).weekday])
        #expect(PlanChat.minutes(in: "周五只有 20 分钟") == 20)
        #expect(PlanChat.minutes(in: "大概半小时") == 30)
    }

    @Test func asksWithAFormThenProposes() throws {
        let (c, _, container) = try load(.xiaolin)
        _ = container
        let r = HealthAgent.reply(to: "这周有几天没空，帮我调整计划", context: c)
        #expect(r.intent == .planChange)
        guard case .form(let f) = r.blocks.first else { Issue.record("expected a form, got \(r.text)"); return }
        #expect(f.fields.contains { $0.kind == .weekdays })
        // The answers go back as a message the agent understands.
        let (ws, items, _) = PlanChat.slots(.thisWeek, context: c)
        let open = PlanChat.editable(items, weekStart: ws, now: c.now)
        let busy = Weekday.mondayFirst.filter { open.contains($0) && isTraining(items, $0, ws) }.prefix(1)
        try #require(!busy.isEmpty)
        let r2 = HealthAgent.reply(to: f.message(["days": busy.map(Weekday.name).joined(separator: "、"), "minutes": "0 分钟"]), context: c)
        guard case .plan(let p) = r2.blocks.first else { Issue.record("expected a proposal, got \(r2.text)"); return }
        #expect(p.scope == .thisWeek)
        for wd in busy { #expect(!isTraining(p.after, wd, p.weekStart)) }
        #expect(p.minutesAfter <= p.minutesBefore)
        #expect(p.checks.first?.contains("总训练时长") == true)
    }

    @Test func pastDaysStayAsTheyWere() throws {
        let (c, _, container) = try load(.xiaolin)
        _ = container
        // Monday has passed by Wednesday.
        let p = PlanChat.propose([.replace(day: 2, kind: .rest, title: "休息", minutes: 0, intensity: .rest, detail: nil)],
                                 scope: .thisWeek, request: "周一休息", context: c, source: "test")
        #expect(!p.hasChanges)
    }

    @Test func checksCapVolumeHardSessionsAndKeepARestDay() throws {
        let (c, _, container) = try load(.xiaolin)
        _ = container
        let ops: [PlanEditOp] = Weekday.mondayFirst.map { .replace(day: $0, kind: .quality, title: "间歇", minutes: 90, intensity: .hard, detail: nil) }
        let p = PlanChat.propose(ops, scope: .nextWeek, request: "每天都练间歇", context: c, source: "test")
        #expect(p.minutesAfter <= max(Int(Double(p.minutesBefore) * 1.1), p.minutesBefore + 15))
        #expect(p.after.filter { $0.intensity == .hard }.count <= 2)
        #expect(Weekday.mondayFirst.contains { !isTraining(p.after, $0, p.weekStart) })
        let hard = p.after.filter { $0.intensity == .hard }.map(\.day).sorted()
        #expect(!zip(hard, hard.dropFirst()).contains { $1.daysSince($0) == 1 })
        #expect(p.checks.contains { $0.contains("10%") })
    }

    @Test func cardiacLimitKeepsNewSessionsModerate() throws {
        var (c, _, container) = try load(.xiaolin)
        _ = container
        c.profile.modules.insert(.cardioCare)
        c.profile.clinicianCleared = false
        let (ws, items, _) = PlanChat.slots(.nextWeek, context: c)
        let wd = try #require(Weekday.mondayFirst.first { wd in items.contains { $0.day == PlanChat.day(wd, ws) && $0.kind.isTraining && $0.intensity != .hard } })
        let p = PlanChat.propose([.intensity(day: wd, .hard)], scope: .nextWeek, request: "加强度", context: c, source: "test")
        #expect(!p.after.contains { $0.day == PlanChat.day(wd, ws) && $0.intensity == .hard })
        #expect(p.checks.contains { $0.contains("医生确认") })
    }

    @Test func painSwitchesToLowImpact() throws {
        let (c, _, container) = try load(.xiaolin)
        _ = container
        let r = HealthAgent.reply(to: "膝盖有点疼，下周怎么练", context: c)
        guard case .plan(let p) = r.blocks.first else { Issue.record("expected a proposal, got \(r.text)"); return }
        #expect(p.scope == .nextWeek)
        #expect(p.after.filter { $0.kind.isTraining }.allSatisfy { $0.intensity <= .moderate })
        #expect(p.after.contains { $0.title.contains("低冲击") })
        #expect(p.checks.contains { $0.contains("就医") })
    }

    @Test func adoptAndUndoThisWeek() throws {
        let (c, ctx, container) = try load(.xiaolin)
        _ = container
        let (ws, items, _) = PlanChat.slots(.thisWeek, context: c)
        let open = PlanChat.editable(items, weekStart: ws, now: c.now)
        let a = try #require(Weekday.mondayFirst.first { open.contains($0) && isTraining(items, $0, ws) })
        let b = try #require(Weekday.mondayFirst.first { open.contains($0) && !isTraining(items, $0, ws) })
        let moved = try #require(items.first { $0.day == PlanChat.day(a, ws) && $0.kind.isTraining })
        let wasAdjusted = DataHub.planItems(weekStart: ws, in: ctx).first { $0.id == moved.id }!.wasAdjusted
        let p = PlanChat.propose([.move(from: a, to: b)], scope: .thisWeek, request: "挪一下", context: c, source: "test")
        #expect(p.lines.count == 2)
        let undo = DataHub.applyPlanChange(p, in: ctx)
        let after = DataHub.planItems(weekStart: ws, in: ctx).first { $0.id == moved.id }!
        #expect(after.day == PlanChat.day(b, ws))
        #expect(after.adjustmentNote?.contains("Health Agent") == true)
        DataHub.revertPlanChange(p, undo: undo, in: ctx)
        let back = DataHub.planItems(weekStart: ws, in: ctx).first { $0.id == moved.id }!
        #expect(back.day == PlanChat.day(a, ws))
        #expect(back.wasAdjusted == wasAdjusted)
    }

    @Test func adoptAndUndoGeneratedNextWeek() throws {
        let (c, ctx, container) = try load(.xiaolin)
        _ = container
        let (ws, items, generated) = PlanChat.slots(.nextWeek, context: c)
        #expect(generated)
        let wd = try #require(Weekday.mondayFirst.first { isTraining(items, $0, ws) })
        let p = PlanChat.propose([.minutes(day: wd, minutes: 20)], scope: .nextWeek, request: "下周少一点", context: c, source: "test")
        let undo = DataHub.applyPlanChange(p, in: ctx)
        #expect(DataHub.planItems(weekStart: ws, in: ctx).count == p.after.count)
        #expect(DataHub.planItems(weekStart: ws, in: ctx).allSatisfy { !$0.guidance.isEmpty || !$0.kind.isTraining })
        DataHub.revertPlanChange(p, undo: undo, in: ctx)
        #expect(DataHub.planItems(weekStart: ws, in: ctx).isEmpty)
    }

    @Test func withdrawingRemovesTheQuestionAndItsAnswer() {
        let convo = AgentConversation()
        let q1 = AgentMessage(role: .user, text: "最近睡得怎么样")
        let a1 = AgentMessage(role: .agent, text: "睡得不错")
        let q2 = AgentMessage(role: .user, text: "明天能跑步吗")
        let a2 = AgentMessage(role: .agent, text: "可以")
        convo.messages = [q1, a1, q2, a2]
        convo.answeredForms["\(a1.id.uuidString)|days"] = "周四"
        convo.withdraw(q1.id)
        #expect(convo.messages.map(\.id) == [q1.id, q2.id, a2.id])
        #expect(convo.messages[0].withdrawn)
        #expect(convo.answeredForms.isEmpty)
        // The model no longer sees it.
        #expect(convo.modelHistory() == ["用户：明天能跑步吗", "助手：可以"])
        // Taken back once; the agent's own messages can't be.
        convo.withdraw(q1.id)
        convo.withdraw(a2.id)
        #expect(convo.messages.count == 3)
    }

    @Test func withdrawingStopsAnAnswerInProgress() {
        let convo = AgentConversation()
        let q = AgentMessage(role: .user, text: "这周怎么练")
        convo.messages = [q, AgentMessage(role: .agent, text: "我先看看", streaming: true)]
        convo.isResponding = true
        convo.withdraw(q.id)
        #expect(!convo.isResponding)
        #expect(convo.messages.count == 1 && convo.messages[0].withdrawn)
    }

    @Test func withdrawingCanUndoAnAdoptedPlanChange() throws {
        let (c, ctx, container) = try load(.xiaolin)
        _ = container
        let (ws, items, _) = PlanChat.slots(.thisWeek, context: c)
        let open = PlanChat.editable(items, weekStart: ws, now: c.now)
        let a = try #require(Weekday.mondayFirst.first { open.contains($0) && isTraining(items, $0, ws) })
        let b = try #require(Weekday.mondayFirst.first { open.contains($0) && !isTraining(items, $0, ws) })
        let moved = try #require(items.first { $0.day == PlanChat.day(a, ws) && $0.kind.isTraining })
        let p = PlanChat.propose([.move(from: a, to: b)], scope: .thisWeek, request: "挪一下", context: c, source: "test")
        let convo = AgentConversation()
        let q = AgentMessage(role: .user, text: "挪一下")
        convo.messages = [q, AgentMessage(role: .agent, text: "好的", blocks: [.plan(p)])]
        convo.planOutcomes[p.id] = .applied(DataHub.applyPlanChange(p, in: ctx))
        #expect(convo.adoptedPlans(answering: q.id).count == 1)
        convo.withdraw(q.id, undoingChangesIn: ctx)
        #expect(convo.planOutcomes[p.id] == .undone)
        #expect(DataHub.planItems(weekStart: ws, in: ctx).first { $0.id == moved.id }?.day == PlanChat.day(a, ws))
    }

    @Test func proposedChangesAreNotPresentedAsDone() throws {
        let (c, _, container) = try load(.xiaolin)
        _ = container
        let r = HealthAgent.reply(to: "这周六的训练挪到周日", context: c)
        try #require(r.proposesPlan, "\(r.text)")
        let k = try #require(r.conclusion)
        #expect(k.contains("采纳") && r.text.hasPrefix(k))
        // Each day says what it was and what it becomes.
        for l in r.proposals[0].lines {
            #expect(r.text.contains("\(Weekday.name(l.weekday))：原来是「\(l.before)」，改为「\(l.after)」"))
        }
        let out = HealthAgent.finalize(k + "\n\n本周六的训练已从长距离跑改为轻松跑 4 km 30 分钟，计划已更新。\n• 已经帮你把周日挪到周六。\n下周强度已改为轻松。\n静息心率已从 72 降到 66，已结合准备度做了安全检查。", of: r)
        #expect(out.contains("本周六的训练建议从长距离跑改为轻松跑"))
        #expect(out.contains("计划需要你采纳后才会更新"))
        #expect(out.contains("建议把周日挪到周六"))
        #expect(out.contains("下周强度建议改为轻松"))
        // Facts from the data stay as they are.
        #expect(out.contains("静息心率已从 72 降到 66，已结合准备度做了安全检查"))
        // The changed days are still ahead: a clause saying their session is done goes.
        let days = HealthAgent.changedDays(r.proposals)
        #expect(days.contains("周六") && days.contains("星期日"))
        #expect(HealthAgent.notApplied("• 周日：轻松跑 4 km，周六长距离跑已完成，保持训练连续性。", changedDays: days)
                == "• 周日：轻松跑 4 km，保持训练连续性。")
        #expect(HealthAgent.notApplied("周日轻松跑，周六的长距离跑已经完成。", changedDays: days) == "周日轻松跑。")
        #expect(HealthAgent.notApplied("• 周六已练完。", changedDays: days).isEmpty)
        #expect(HealthAgent.notApplied("上周六已完成长距离跑，本周已完成 1 次训练。", changedDays: days) == "上周六已完成长距离跑，本周已完成 1 次训练。")
        // Only the changed days: a generic bullet goes, and the rules' own lines step in when none is left.
        let generic = "• 保持今天准备度 99（恢复充分），结合训练负荷比 1.03，优先考虑室内有氧。"
        let l = r.proposals[0].lines[0]
        let name = Weekday.name(l.weekday)
        let right = "• \(name)：改为「\(l.after)」。"
        let focused = HealthAgent.finalize(k + "\n\n" + right + "\n" + generic, of: r)
        #expect(focused.contains(right) && !focused.contains("保持今天准备度"))
        let refilled = HealthAgent.finalize(k + "\n\n" + generic, of: r)
        #expect(!refilled.contains("保持今天准备度") && refilled.contains("原来是「"))
        #expect(HealthAgent.streamed(k + "\n\n" + right + "\n• 保持今天准备", of: r) == k + "\n\n" + right)
        // A day line that has the change backwards is replaced by the rules' line for that day.
        let backwards = "• \(name)：将「\(l.after)」改为「\(l.before)」，因为天气。"
        let fixed = HealthAgent.finalize(k + "\n\n" + backwards, of: r)
        #expect(!fixed.contains(backwards) && fixed.contains("\(name)：原来是「\(l.before)」，改为「\(l.after)」"))
        // While streaming, a day line waits until it is complete.
        #expect(HealthAgent.streamed(k + "\n\n" + backwards, of: r) == k)
        // Answers about something else that carry a change card keep their own bullets.
        var weather = r
        weather.intent = .weather
        #expect(HealthAgent.finalize(k + "\n\n" + generic, of: weather).contains("保持今天准备度"))
        // While streaming, a clause with 「已」 waits until it is complete.
        #expect(HealthAgent.streamed("好的。周六的训练已从长距离跑改", of: r) == "好的。周六的训练")
        #expect(HealthAgent.streamed("好的。周六的训练已从长距离跑改为轻松跑，", of: r) == "好的。周六的训练建议从长距离跑改为轻松跑，")
        // Answers without a plan change are left alone.
        let plain = HealthAgent.reply(to: "最近睡得怎么样？", context: c)
        #expect(!plain.proposesPlan)
        #expect(HealthAgent.finalize("计划已更新。", of: plain).contains("计划已更新"))
        #expect(HealthAgent.streamed("计划已更", of: plain) == "计划已更")
    }

    @Test func generatedUIIsValidated() {
        let raw = #"好的，先确认一下。<ui>[{"type":"form","title":"哪几天没空？","fields":[{"id":"d","label":"没空的日子","kind":"weekdays"},{"id":"m","label":"可用时间","kind":"number","min":0,"max":9999,"value":30,"unit":"分钟"}]},{"type":"chart","metric":"rhr","days":400},{"type":"video"},{"type":"checklist","items":[{"title":"胰岛素剂量减半","detail":""},{"title":"戴紧手表","detail":"训练时紧一格"}]}]</ui>"#
        let parts = AgentUI.split(raw)
        #expect(parts.text == "好的，先确认一下。")
        let blocks = AgentUI.blocks(fromJSON: parts.ui ?? "", context: "调整计划")
        #expect(blocks.count == 3)
        if case .form(let f) = blocks[0], case .number(_, let hi, _, _, _) = f.fields[1].kind { #expect(hi == 600) } else { Issue.record("form") }
        if case .chart(.rhr, let d, _) = blocks[1] { #expect(d == 90) } else { Issue.record("chart") }
        if case .checklist(let l) = blocks[2] { #expect(l.items.map(\.title) == ["戴紧手表"]) } else { Issue.record("checklist") }
        // While streaming, a tag that is still arriving stays hidden.
        #expect(AgentUI.split("马上给你选项<u").text == "马上给你选项")
        #expect(AgentUI.split(#"马上<plan>{"scope""#).text == "马上")
        let f = AgentForm(id: "x", title: "t", fields: [AgentFormField(id: "d", label: "没空的日子", kind: .weekdays)], submitLabel: "发送", context: "调整本周计划")
        #expect(f.message(["d": "周四、周五"]) == "调整本周计划。没空的日子：周四、周五")
    }

    @Test func cloudPlanEditsAreParsed() throws {
        let r = PlanChat.ops(fromJSON: #"{"scope":"next_week","edits":[{"op":"move","from":"周三","to":"星期四"},{"op":"minutes","day":5,"minutes":"25"},{"op":"replace","day":"sat","kind":"aerobic","title":"骑行","minutes":40,"intensity":"easy"},{"op":"delete_everything"}]}"#)
        #expect(r.scope == .nextWeek)
        #expect(r.ops.count == 3)
        #expect(r.ops.first == .move(from: 4, to: 5))
        #expect(r.ops.dropFirst().first == .minutes(day: 6, minutes: 25))
        let (c, _, container) = try load(.xiaolin)
        _ = container
        let prompt = PlanChat.cloudPrompt(question: "周四加班", history: [], context: c, rulesHint: PlanChat.rulesHint("周四加班", context: c))
        #expect(prompt.contains("·可调整"))
        #expect(!prompt.contains(c.name))
    }

    @Test func cloudReplyRunsThroughTheSameChecks() throws {
        let (c, _, container) = try load(.xiaolin)
        _ = container
        let (ws, items, _) = PlanChat.slots(.nextWeek, context: c)
        let wd = try #require(Weekday.mondayFirst.first { isTraining(items, $0, ws) })
        let raw = """
        你下周\(Weekday.name(wd))加班，我把那天的训练缩短到 20 分钟，并多加一次 120 分钟的长跑。
        <plan>{"scope":"next_week","edits":[{"op":"minutes","day":"\(Weekday.name(wd))","minutes":20},{"op":"replace","day":"\(Weekday.name(Weekday.mondayFirst.first { !isTraining(items, $0, ws) } ?? 1))","kind":"long","title":"长跑","minutes":120,"intensity":"easy"}]}</plan>
        """
        let parts = AgentUI.split(raw)
        #expect(!parts.text.contains("<plan>"))
        let parsed = PlanChat.ops(fromJSON: try #require(parts.plan))
        let p = PlanChat.propose(parsed.ops, scope: parsed.scope ?? .thisWeek, request: "下周加班", context: c, source: "云端 · test")
        #expect(p.hasChanges)
        #expect(p.minutesAfter <= max(Int(Double(p.minutesBefore) * 1.1), p.minutesBefore + 15))
    }

    @Test func deviceGuideReadsDataQuality() throws {
        let (c, _, container) = try load(.linyue)
        _ = container
        #expect(DeviceGuide.findings(c, focus: .watch).contains { !$0.ok })
        let r = HealthAgent.reply(to: "手表数据总是断，怎么戴比较好", context: c)
        #expect(r.intent == .device)
        #expect(r.blocks.contains { if case .checklist = $0 { true } else { false } })
        #expect(r.blocks.contains { if case .chart(.wear, _, _) = $0 { true } else { false } })
    }

    @Test func cgmGuideUsesCarePlanNumbersAndNoDoses() throws {
        let (c, _, container) = try load(.wangjianguo)
        _ = container
        let r = HealthAgent.reply(to: "运动时 CGM 怎么用", context: c)
        #expect(r.intent == .device)
        let steps = try #require(r.blocks.compactMap { if case .steps(let s) = $0 { s } else { nil } }.first)
        #expect(steps.steps[0].detail.contains(c.profile.glucosePreExerciseMin.oneDecimal))
        #expect(AgentUI.isSafe(r.text))
        #expect(steps.steps.allSatisfy { AgentUI.isSafe($0.detail) })
        #expect(DeviceGuide.findings(c, focus: .cgm).contains { $0.id == "coverage" })
    }
}

// MARK: - Shift work

@Suite("Shift work")
struct ShiftWorkTests {
    /// Monday 2026-10-19 is day 1 of 白 白 夜 夜 休 休.
    private let monday = today.weekStart
    private var profile: ProfileSnapshot {
        var p = ProfileSnapshot()
        p.wakeMinutes = 7 * 60
        p.bedtimeMinutes = 23 * 60
        p.sleepNeedMinutes = 450
        p.availableWeekdays = Weekday.mondayFirst
        p.shift = ShiftSchedule(pattern: [.day, .day, .night, .night, .off, .off], cycleStart: monday,
                                dayStart: 8 * 60, dayEnd: 17 * 60, nightStart: 20 * 60, nightEnd: 8 * 60)
        return p
    }
    private func at(_ dayOffset: Int, _ h: Int, _ m: Int = 0) -> Date {
        Calendar.pulse.date(bySettingHour: h, minute: m, second: 0, of: monday.adding(days: dayOffset))!
    }

    @Test func rosterRepeats() {
        let s = profile.shift!
        #expect(s.kind(on: monday) == .day)
        #expect(s.kind(on: monday.adding(days: 2)) == .night)
        #expect(s.kind(on: monday.adding(days: 6)) == .day)
        #expect(s.kind(on: monday.adding(days: -1)) == .off)
    }

    @Test func wakingWindowsFollowTheShift() {
        let p = profile
        // Day shift: up 90 minutes before work, in bed early enough to sleep 7.5 h.
        let d0 = DayClock.window(for: monday, profile: p)
        #expect(d0.wake == at(0, 6, 30))
        #expect(d0.bed == at(0, 23))
        // First night: normal morning, a nap before work, main sleep after the shift.
        let n1 = DayClock.window(for: monday.adding(days: 2), profile: p)
        #expect(n1.wake == at(2, 7))
        #expect(n1.nap != nil)
        #expect(n1.bed == at(3, 9))
        // Second night: a full daytime sleep after the first.
        let n2 = DayClock.window(for: monday.adding(days: 3), profile: p)
        #expect(n2.wake == at(3, 16, 30))
        #expect(n2.afterNightShift)
        #expect(n2.nextWake == at(4, 13))
        // Recovery day: a short sleep, then back to nights.
        let r = DayClock.window(for: monday.adding(days: 4), profile: p)
        #expect(r.wake == at(4, 13))
        #expect(r.bed == at(4, 23))
    }

    @Test func theDayEndsAtTheMainSleep() {
        let p = profile
        // Thursday 10:00, after the second night: still Thursday's shift day (Wednesday's date is not involved).
        #expect(DayClock.logicalToday(at(4, 10), p) == monday.adding(days: 3))
        // Awake after the recovery sleep: Friday has begun.
        #expect(DayClock.logicalToday(at(4, 12), p) == monday.adding(days: 4))
        // Mid-shift at 03:00 is still the night-shift day, not the next one.
        #expect(DayClock.logicalToday(at(4, 3), p) == monday.adding(days: 3))
        // Phases through a night shift.
        let w = DayClock.window(for: monday.adding(days: 3), profile: p)
        #expect(DayPhase.current(at: at(3, 17), window: w) == .morning)
        #expect(DayPhase.current(at: at(4, 3), window: w) == .exercise)
        #expect(DayPhase.current(at: at(4, 7), window: w) == .evening)
        #expect(DayPhase.current(at: at(4, 9, 30), window: w) == .review)
        // Without a roster the 5 am rule still holds.
        var regular = p
        regular.shift = nil
        #expect(DayClock.logicalToday(at(4, 4), regular) == monday.adding(days: 3))
        #expect(DayClock.logicalToday(at(4, 6), regular) == monday.adding(days: 4))
    }

    @Test func clockTimesSurviveTheClockChange() {
        // 25 October 2026: British Summer Time ends (a 25-hour day where the tests run in London).
        let change = Calendar.pulse.date(from: DateComponents(year: 2026, month: 10, day: 25))!
        var p = profile
        p.shift = ShiftSchedule(pattern: [.day], cycleStart: change, dayStart: 7 * 60, dayEnd: 15 * 60, nightStart: 20 * 60, nightEnd: 8 * 60)
        let w = DayClock.window(for: change, profile: p)
        #expect(w.wake.hour == 5 && w.wake.minutesOfDay == 5 * 60 + 30)
        #expect(DayClock.window(for: change, profile: nil).rollover.hour == 5)
    }

    @Test func agentKnowsTheShift() {
        let c = AgentContext.make(profile: profile, name: "测试", days: [], plan: [], workouts: [], vitals: [], events: [],
                                  stopBang: [], baselineSetAt: nil, raceName: "", now: at(4, 3))
        #expect(c.window.kind == .night)
        #expect(!c.pastBedtime)
        #expect(HealthAgent.digest(c).contains("倒班：今天夜班"))
        let after = AgentContext.make(profile: profile, name: "测试", days: [], plan: [], workouts: [], vitals: [], events: [],
                                      stopBang: [], baselineSetAt: nil, raceName: "", now: at(4, 10))
        #expect(after.pastBedtime)
        #expect(after.nightLine?.contains("13:00") == true)
    }

    @Test func nightShiftSleepAdviceUsesTheRoster() {
        let c = AgentContext.make(profile: profile, name: "测试", days: [], plan: [], workouts: [], vitals: [], events: [],
                                  stopBang: [], baselineSetAt: nil, raceName: "", now: at(4, 3))
        let r = HealthAgent.reply(to: "下班后怎么睡比较好？", context: c)
        #expect(r.intent == .sleep)
        // Thursday is the last night of the run: sleep 09:00–13:00, then bed at the usual time.
        let k = try? #require(r.conclusion)
        #expect(k?.contains("09:00") == true && k?.contains("13:00") == true)
        #expect(r.text.contains("最后一个夜班"))
        let coffee = HealthAgent.reply(to: "现在可以喝咖啡吗？", context: c)
        #expect(coffee.conclusion?.contains("不到 6 小时") == true)
    }

    @Test func noTrainingOnNightsOrTheDayAfter() {
        let plan = PlanGenerator.generate(profile: profile, weekStart: monday)
        // Wed, Thu are nights; Fri is the recovery day.
        for wd in [4, 5, 6] {
            #expect(!plan.sessions.contains { $0.weekday == wd && $0.kind.isTraining })
        }
        #expect(plan.sessions.contains { $0.weekday == 4 && $0.title == "夜班日" })
        #expect(plan.sessions.contains { $0.weekday == 6 && $0.title == "夜班后恢复" })
        #expect(plan.sessions.filter { $0.kind.isTraining }.count >= 2)
    }
}

@Suite("Shift work sample user")
@MainActor
struct ShiftPersonaTests {
    @Test func linyueHasHerRoster() throws {
        let container = try ModelContainer(for: Schema(PulseSchema.models), configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        let ctx = container.mainContext
        DemoDataGenerator.populate(ctx, persona: .linyue, now: today)
        let p = try #require(DataHub.profile(in: ctx))
        let s = try #require(p.shiftSchedule)
        #expect(s.pattern.count == 5)
        // The generated sleep matches the roster: the day after a night shift starts after a daytime sleep.
        let snap = p.snapshot(medications: [])
        let recovery = (0..<5).map { today.adding(days: -$0) }.first { s.kind(on: $0.adding(days: -1)) == .night }!
        let rec = DataHub.analytics(in: ctx, now: today).day(recovery)
        if let start = rec?.sleepStart { #expect(start.hour >= 7 && start.hour <= 10) }
        #expect(DayClock.window(for: recovery, profile: snap).afterNightShift)
    }
}

// MARK: - Review cards written by a model

@Suite("Review copy")
struct ReviewCopyTests {
    private var facts: ReviewFacts {
        let brief = WeeklyBrief(headline: "这周训练还没跟上", detail: "完成 1/4 次训练，静息心率 66 bpm。",
                                metrics: [BriefMetric(name: "静息心率", icon: "heart", value: "66", unit: "bpm", delta: "-2", trend: .better)],
                                watch: [], nextWeek: "下周有氧目标 90 分钟。")
        let p = CoachProposal(id: "drop-5", icon: "calendar", title: "周四改为日常活动日", rationale: "近 6 周周四 4 次没完成。",
                              action: .dropWeekday(5), adoptLabel: "采纳")
        let q = CoachProposal(id: "short", icon: "timer", title: "单次训练缩短到 35 分钟", rationale: "忙碌时更容易坚持。",
                              action: .dropWeekday(5), adoptLabel: "采纳")
        return ReviewCoach.weeklyFacts(brief: brief, weekLabel: "10月19日–25日", isCurrentWeek: true, proposals: [p, q], plan: nil)
    }

    @Test func groundedCopyIsKept() {
        let f = facts
        #expect(f.fallback.items.count == 2)
        #expect(f.text.contains("【下周】下周有氧目标 90 分钟。"))
        let model = ReviewCopy(headline: "训练要先跟上节奏", summary: "这周只完成了 1 次训练，不过静息心率 66 bpm，比上周低了一些。",
                               items: ["周四近 6 周有 4 次没练成，换成散步更容易坚持。", "每次练 35 分钟，忙的时候也能完成。"])
        let (out, replaced) = model.checked(against: f)
        #expect(replaced == 0)
        #expect(out == ReviewCopy(headline: f.fallback.headline, summary: model.summary, items: model.items))   // the verdict stays the rules'
    }

    @Test func inventedNumbersMissingItemsAndDosesFallBack() {
        let f = facts
        let model = ReviewCopy(headline: "", summary: "静息心率下降了 8 bpm，可以把降压药减半。", items: ["换成散步。"])
        let (out, replaced) = model.checked(against: f)
        #expect(out.summary == f.fallback.summary)     // 8 is not in the facts, and dose advice
        #expect(out.items[0] == "换成散步。")
        #expect(out.items[1] == f.fallback.items[1])   // missing item
        #expect(replaced == 2)
    }

    @Test func listsWrongDirectionsAndRepeatedTitlesAreCaught() {
        let f = facts
        let listy = ReviewCopy(headline: "", summary: "你完成 1/4 次训练，静息心率 66 bpm，近 6 周周四 4 次没完成。", items: [])
        #expect(listy.checked(against: f).copy.summary == f.fallback.summary)
        #expect(!ReviewCopy.directionsMatch("静息心率从72降到73"))
        let causal = ReviewCopy(headline: "", summary: "这周只完成了 1 次训练，因为静息心率 66 bpm。", items: [])
        #expect(causal.checked(against: f).copy.summary == f.fallback.summary)
        let copied = ReviewCopy(headline: "", summary: "这周只完成了 1 次训练。下周我们先试着早点上床。", items: [])
        #expect(copied.checked(against: f).copy.summary == f.fallback.summary)
        #expect(ReviewCopy.directionsMatch("每周的活动从 75 分钟降到了 44 分钟，睡眠从 5.9 增加到 6.4 小时"))
        let titled = ReviewCopy(headline: "", summary: "", items: ["周四改为日常活动日：周四常常没练成，先换成散步。", "建议“单次训练缩短到 35 分钟”。忙的时候也能完成。"])
        #expect(titled.checked(against: f).copy.items == ["周四常常没练成，先换成散步。", "忙的时候也能完成。"])
        #expect(ReviewCopy.droppingTitle("下周调整有氧目标保持 45 分钟。这周完成了一半，下周先不变。", of: "下周调整「有氧目标保持 45 分钟」：这周完成了一半。")
                == "这周完成了一半，下周先不变。")
        #expect(ReviewCopy.droppingTitle("下周调整周六改为日常活动日，最近 6 周周六常常练不成。", of: "下周调整「周六改为日常活动日」：最近 6 周周六常常练不成。")
                == "最近 6 周周六常常练不成。")
        #expect(ReviewCopy.droppingTitle("周六改为日常活动，其他日子照旧。", of: "下周调整「周六改为日常活动日」：最近 6 周周六常常练不成。")
                == "周六改为日常活动，其他日子照旧。")
        // A first sentence that is content, not the title, stays.
        #expect(ReviewCopy.droppingTitle("最近 6 周周六常常练不成。下周先换成日常活动。", of: "下周调整「周六改为日常活动日」：最近 6 周周六常常练不成，下周先换成日常活动。")
                == "最近 6 周周六常常练不成。下周先换成日常活动。")
        #expect(ReviewCopy.spaced("最近6周周六，平均高6.0bpm，23:30前睡下，完成了0%的有氧") == "最近 6 周周六，平均高 6.0 bpm，23:30 前睡下，完成了 0% 的有氧")
        // A time is not a title.
        #expect(ReviewCopy.droppingTitle("9/20 晚在 23:30 ±45 分钟内入睡。", of: "把目标上床时间调整为 00:15：9/20 晚在 23:30 ±45 分钟内入睡。") == "9/20 晚在 23:30 ±45 分钟内入睡。")
    }

    @Test func reorderedItemsLandUnderTheRightTitle() {
        let points = [AgentPoint(icon: "calendar", title: "先让计划更容易坚持", detail: "减少每次时长或训练日，优先保证每周的次数。"),
                      AgentPoint(icon: "moon", title: "把作息作为下一阶段的重点", detail: "固定起床时间，逐步提前上床。"),
                      AgentPoint(icon: "wineglass", title: "确认饮酒对你的影响", detail: "饮酒后的早晨静息心率平均高 6.0 bpm，可通过 2 周个人验证确认。")]
        let f = ReviewFacts(kind: "long", text: "【条目】饮酒后 6.0 bpm 2 周", fallback: ReviewCopy(headline: "h", summary: "s", items: points.map(\.detail)),
                            references: points.map { "\($0.title)：\($0.detail)" })
        let model = ReviewCopy(headline: "h", summary: "s",
                               items: ["饮酒后的早晨静息心率平均高 6.0 bpm，用 2 周验证一下。", "每次练短一点，先保证每周的次数。", "固定起床时间，再慢慢提前上床。"])
        let (out, replaced) = model.checked(against: f)
        #expect(replaced == 0)
        #expect(out.items == [model.items[1], model.items[2], model.items[0]])
    }

    @Test func factsAreStableAndJSONIsRead() {
        #expect(facts.key == facts.key)
        let json = "好的：\n```json\n{\"summary\":\"b\",\"items\":[\"c\"]}\n```"
        #expect(ReviewCoach.copy(fromJSON: json) == ReviewCopy(headline: "", summary: "b", items: ["c"]))
    }
}

// MARK: - Blood pressure and glucose forecasts

@Suite("Vital forecasts")
struct VitalForecastTests {
    /// Three readings a week for `weeks` weeks before this week, with weekly means from `mean(k)` (k = 0 oldest).
    private func readings(_ kind: VitalKind, weeks: Int, mean: (Int) -> Double, second: ((Int) -> Double)? = nil) -> [VitalPoint] {
        let thisWeek = today.startOfDay.weekStart
        return (0..<weeks).flatMap { k -> [VitalPoint] in
            let start = thisWeek.adding(days: -7 * (weeks - k))
            return [-1.0, 0, 1].enumerated().map { i, wobble in
                VitalPoint(time: start.adding(days: i * 2).addingTimeInterval(8 * 3600), kind: kind, value: mean(k) + wobble,
                           value2: second.map { $0(k) + wobble }, context: .morning)
            }
        }
    }

    @Test func risingPressureWidensAndPointsToTheDoctor() throws {
        let bp = readings(.bloodPressure, weeks: 8, mean: { 124 + 2 * Double($0) }, second: { 80 + Double($0) })
        let f = try #require(VitalForecaster.bloodPressure(bp, profile: ProfileSnapshot(), now: today))
        #expect(f.systolic.direction == .rising)
        #expect(f.systolic.weeks.filter(\.projected).count == VitalForecaster.horizon)
        let spans = f.systolic.weeks.filter(\.projected).map { $0.high - $0.low }
        #expect(spans == spans.sorted())
        // Damped: four more weeks add less than four times the weekly rise.
        #expect(f.systolic.end.mid - f.systolic.latest.mid < 8)
        #expect(f.needsDoctor && f.message.contains("医生"))
    }

    @Test func tooFewWeeksGiveNoForecastAndSteadyStaysSteady() {
        let short = readings(.bloodPressure, weeks: 3, mean: { _ in 128 }, second: { _ in 80 })
        #expect(VitalForecaster.bloodPressure(short, profile: ProfileSnapshot(), now: today) == nil)
        let flat = readings(.bloodPressure, weeks: 8, mean: { 126 + ($0 % 2 == 0 ? 1 : -1) }, second: { _ in 78 })
        let f = VitalForecaster.bloodPressure(flat, profile: ProfileSnapshot(), now: today)
        #expect(f?.systolic.direction == .steady)
        #expect(f?.needsDoctor == false)
    }

    @Test func fallingGlucoseNearTheLowRangeWarns() throws {
        let g = readings(.glucose, weeks: 8, mean: { 7.5 - 0.4 * Double($0) }).map { var v = $0; v.context = .fasting; return v }
        let f = try #require(VitalForecaster.glucose(g, profile: ProfileSnapshot(), now: today))
        #expect(f.mean.direction == .falling)
        #expect(f.measure == "空腹血糖")
        #expect(f.message.contains("低血糖"))
        #expect(!f.message.contains("胰岛素") || VitalForecaster.caveat.contains("胰岛素"))
    }
}

@Suite("Next-hour forecasts")
struct NextHourForecastTests {
    private let now = Calendar.pulse.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 15))!

    /// A week of CGM every 15 minutes: gentle daily waves, then the last half hour at `slope` per minute.
    private func cgm(endingAt end: Double, slope: Double) -> [VitalPoint] {
        let start = now.adding(days: -7)
        return stride(from: 0, through: 7 * 24 * 60, by: 15).map { m -> VitalPoint in
            let t = start.addingTimeInterval(Double(m) * 60)
            let toEnd = now.timeIntervalSince(t) / 60
            let v = toEnd <= 30 ? end - slope * toEnd : 7 + 1.2 * sin(Double(m) / 240)
            return VitalPoint(time: t, kind: .glucose, value: v, value2: nil, context: .random)
        }
    }

    @Test func fallingGlucoseWarnsOfALowBeforeItHappens() throws {
        let f = try #require(NextHourForecaster.glucose(cgm(endingAt: 5.6, slope: -0.07), profile: ProfileSnapshot(), now: now))
        guard case .lowSoon(let m)? = f.alert else { Issue.record("expected a low warning, got \(String(describing: f.alert))"); return }
        #expect(m <= 60)
        #expect(f.points.map(\.minutes) == [15, 30, 45, 60])
        // Damped: an hour does not carry the whole 0.07/min fall.
        #expect(5.6 - f.end.mid < 0.07 * 60)
        #expect(f.message.contains("低于") && !f.message.contains("胰岛素"))
        #expect(NextHourForecaster.caveat.contains("不能用来计算胰岛素"))
    }

    @Test func steadyOrStaleGlucoseIsQuiet() {
        let steady = NextHourForecaster.glucose(cgm(endingAt: 7, slope: 0), profile: ProfileSnapshot(), now: now)
        #expect(steady?.alert == nil)
        #expect(steady?.message.contains("平稳") == true)
        // The last reading is an hour old: no forecast.
        #expect(NextHourForecaster.glucose(cgm(endingAt: 7, slope: 0), profile: ProfileSnapshot(), now: now.addingTimeInterval(3600)) == nil)
    }

    @Test func aQuietHourAfterMealsIsNotALow() throws {
        // A week at 5.0 with three meals a day; now is three hours after lunch, drifting down slowly.
        let start = now.adding(days: -7)
        let g = stride(from: 0, through: 7 * 24 * 60, by: 15).map { m -> VitalPoint in
            let t = start.addingTimeInterval(Double(m) * 60), h = Double(t.minutesOfDay) / 60
            let v = [(7.5, 2.6), (12.0, 3.0), (19.0, 3.3)].reduce(5.0) { g, meal in
                let dt = h - meal.0
                return dt > 0 && dt < 3.5 ? g + meal.1 * (dt / 0.75) * exp(1 - dt / 0.75) : g
            }
            return VitalPoint(time: t, kind: .glucose, value: v, value2: nil, context: .random)
        }
        let f = try #require(NextHourForecaster.glucose(g, profile: ProfileSnapshot(), now: now))
        #expect(f.alert == nil)
        #expect(f.message.contains("平稳"))
        // The swings after meals widen the band above, not below.
        #expect(f.end.low > 4.5)
    }

    @Test func aSteadyReadingOnANewSensorIsNotALow() throws {
        let g = stride(from: 0, through: 120, by: 5).map { m in
            VitalPoint(time: now.addingTimeInterval(Double(m - 120) * 60), kind: .glucose, value: 5.6, value2: nil, context: .random)
        }
        let f = try #require(NextHourForecaster.glucose(g, profile: ProfileSnapshot(), now: now))
        #expect(f.alert == nil)
        #expect(f.message.contains("平稳"))
    }

    @Test func bloodPressureFollowsTheTimeOfDay() throws {
        // Mornings around 145/90, evenings around 128/80, for three weeks.
        let bp = (1...21).flatMap { d -> [VitalPoint] in
            let day = now.startOfDay.adding(days: -d)
            return [VitalPoint(time: day.addingTimeInterval(7.5 * 3600), kind: .bloodPressure, value: 145 + Double(d % 3), value2: 90, context: .morning),
                    VitalPoint(time: day.addingTimeInterval(21 * 3600), kind: .bloodPressure, value: 128 + Double(d % 3), value2: 80, context: .bedtime)]
        }
        let morning = try #require(NextHourForecaster.bloodPressure(bp, now: now.startOfDay.addingTimeInterval(6.5 * 3600)))
        let evening = try #require(NextHourForecaster.bloodPressure(bp, now: now.startOfDay.addingTimeInterval(20 * 3600)))
        #expect(morning.systolic.end.mid > evening.systolic.end.mid + 10)
        #expect(morning.message.contains("安静坐 5 分钟"))
        // No readings at this time of day: no forecast.
        #expect(NextHourForecaster.bloodPressure(bp, now: now.startOfDay.addingTimeInterval(13 * 3600)) == nil)
    }
}

@Suite("Abnormal readings")
struct AbnormalReadingTests {
    private func point(_ kind: VitalKind, _ v: Double, _ v2: Double? = nil) -> VitalPoint {
        VitalPoint(time: today, kind: kind, value: v, value2: v2, context: .random)
    }

    @Test func outOfRangeReadingsAskForCausesAndLowsComeFirst() throws {
        let p = ProfileSnapshot()
        #expect(AbnormalReadings.check(point(.glucose, 6.5), profile: p) == nil)
        #expect(AbnormalReadings.check(point(.bloodPressure, 128, 82), profile: p) == nil)
        let low = try #require(AbnormalReadings.check(point(.glucose, 3.4), profile: p))
        #expect(low.direction == .low && low.severe)
        #expect(low.firstLine?.contains("确认回升后再回想原因") == true)
        let high = try #require(AbnormalReadings.check(point(.bloodPressure, 142, 88), profile: p))
        #expect(high.direction == .high && !high.severe && high.firstLine == nil)
        #expect(high.causes.contains("漏服了降压药"))
        let crisis = try #require(AbnormalReadings.check(point(.bloodPressure, 186, 112), profile: p))
        #expect(crisis.severe && crisis.firstLine?.contains("120") == true)
    }

    @Test func noteAndQuestionCarryWhatTheUserRecalled() throws {
        let a = try #require(AbnormalReadings.check(point(.glucose, 13.2), profile: ProfileSnapshot()))
        #expect(AbnormalReading.note(causes: ["刚吃过饭", "漏服了药"], text: " 午饭吃了两碗面 ") == "可能原因：刚吃过饭、漏服了药；午饭吃了两碗面")
        #expect(AbnormalReading.note(causes: [], text: "") == "")
        let q = a.question(at: today, causes: ["漏服了药"], text: "")
        #expect(q.contains("血糖是 13.2 mmol/L，偏高") && q.contains("漏服了药") && q.contains("分析"))
    }
}


@Suite("Home layout")
struct HomeLayoutTests {
    @Test func defaultsRemovalsAndNewModules() {
        let base: [HomeCard] = [.state, .now, .phases, .week]
        #expect(HomeLayout.visible(order: "", seen: "", available: base) == [.state, .now, .phases])
        // Reordered, 现在 removed: it stays removed.
        let seen = "now,phases,state,week"
        #expect(HomeLayout.visible(order: "phases,state", seen: seen, available: base) == [.phases, .state])
        // A module turned on later joins after the nearest card that comes before it by default.
        #expect(HomeLayout.visible(order: "phases,state,now", seen: seen, available: base + [.glucose]) == [.phases, .state, .now, .glucose])
        // A module turned off drops out of the order.
        #expect(HomeLayout.visible(order: "glucose,state", seen: seen + ",glucose", available: base) == [.state])
        // 血糖 and 血压 next to each other share a row; other cards stay on their own.
        #expect(HomeLayout.rows([.state, .glucose, .bloodPressure, .race, .glucose]) == [[.state], [.glucose, .bloodPressure], [.race], [.glucose]])
    }
}

@Suite("Glucose profile")
struct GlucoseProfileTests {
    /// 7 days of CGM every 15 minutes: `base` overnight + three meals a day rising by `peak`, fading with `fade` hours.
    private func week(base: Double, peak: Double, fade: Double, carbs: Double = 60) -> GlucoseModelInput {
        let start = today.startOfDay.adding(days: -7)
        let mealHours = [7.5, 12.5, 19.0]
        let g: [(time: Date, value: Double)] = (0..<(7 * 96)).map { k in
            let t = start.addingTimeInterval(Double(k) * 900)
            let h = Double(t.minutesOfDay) / 60
            var v = base
            for mh in mealHours { let dt = h - mh; if dt > 0 && dt < 5 { v += peak * (dt / fade) * exp(1 - dt / fade) } }
            return (t, v)
        }
        let meals = (0..<7).flatMap { d in
            zip(mealHours, [MealKind.breakfast, .lunch, .dinner]).map { h, k in
                MealInfo(time: start.adding(days: d).addingTimeInterval(h * 3600), kind: k, carbs: carbs, note: "")
            }
        }
        return GlucoseModelInput(glucose: g, meals: meals, profile: ProfileSnapshot(), now: start.adding(days: 7))
    }

    @Test func steadyGlucoseShowsNoSigns() throws {
        let p = try #require(RuleGlucoseModel().profile(week(base: 5.0, peak: 1.8, fade: 0.6)))
        #expect(p.level == .normal)
        #expect(p.signs.allSatisfy { !$0.present })
        #expect(p.meals.count == 3 && p.meals.allSatisfy { $0.backMinutes != nil })
        #expect(p.tests.isEmpty)
    }

    @Test func slowHighMealsAndHighNightsAreSigns() throws {
        let p = try #require(RuleGlucoseModel().profile(week(base: 6.0, peak: 3.4, fade: 1.2)))
        #expect(p.level == .watch)
        let present = Set(p.signs.filter(\.present).map(\.id))
        #expect(present.isSuperset(of: ["peak", "slow", "fasting"]))
        #expect(p.summary.contains("需要化验才能确认") && p.tests.contains("HOMA-IR"))
    }

    @Test func predictionFollowsPastMealsAndCarbs() throws {
        let input = week(base: 5.0, peak: 2.5, fade: 0.75)
        let model = RuleGlucoseModel()
        let at = input.now.addingTimeInterval(-3600)
        let usual = try #require(model.predict(input, kind: .lunch, carbs: 60, at: at))
        #expect(abs(usual.peak.mid - usual.start - 2.5) < 0.4)
        #expect((30...60).contains(usual.peakMinutes))
        #expect(usual.peak.low < usual.peak.mid && usual.peak.mid < usual.peak.high)
        let bigger = try #require(model.predict(input, kind: .lunch, carbs: 90, at: at))
        #expect(bigger.peak.mid > usual.peak.mid)
        #expect(MealPrediction.caveat.contains("不能用来计算胰岛素"))
        // Too few meals: no prediction.
        var few = input
        few.meals = Array(input.meals.prefix(2))
        #expect(model.predict(few, kind: .lunch, carbs: nil, at: at) == nil)
    }

    @Test func gridMatchesGlucoFMInput() {
        let input = week(base: 5.5, peak: 2, fade: 0.75)
        let grid = input.fiveMinuteGrid()
        #expect(grid.mgdl.count == 288 && grid.observed.count == 288)
        // A 15-minute sensor fills one slot in three, in mg/dL.
        #expect(grid.observed.filter { $0 }.count == 95)   // the last reading is 15 minutes before now
        #expect(grid.mgdl.enumerated().filter { grid.observed[$0.offset] }.allSatisfy { $0.element > 80 })
    }
}

@Suite("Next hour after a meal")
struct NextHourAfterMealTests {
    @Test func theMealCurveLeadsTheSlope() {
        let eaten = today
        let now = eaten.addingTimeInterval(50 * 60)
        // Still rising fast now, but this meal usually peaks at 60 minutes and falls after.
        let slope = NextHourForecast(from: now, now: 10.0, points: NextHourForecaster.horizons.map {
            .init(minutes: $0, mid: 10 + 0.08 * Double($0), low: 9 + 0.08 * Double($0), high: 11 + 0.08 * Double($0)) }, rate: 0.08, alert: nil, message: "")
        let curve = RuleGlucoseModel.offsets.map { m -> MealPrediction.Point in
            let rise = 4.0 * (Double(m) / 60) * exp(1 - Double(m) / 60)
            return .init(minutes: m, mid: 6 + rise, low: 5.6 + rise, high: 6.4 + rise)
        }
        let meal = MealPrediction(kind: .lunch, start: 6, points: curve, basis: 10, peakMinutes: 60, backMinutes: nil, message: "")
        let f = NextHourForecaster.following(slope, meal: meal, eatenAt: eaten, label: "午餐", profile: ProfileSnapshot())
        #expect(f.end.mid < slope.end.mid)
        #expect(f.end.mid < 10)   // past the peak, an hour on it is lower than now
        #expect(f.message.contains("午餐后还在上升") && f.message.contains("前后到达高点"))
    }
}

@Suite("Weather and the plan")
@MainActor
struct WeatherPlanTests {
    private let monday = Calendar.pulse.date(from: DateComponents(year: 2026, month: 10, day: 19, hour: 8))!
    private func session(_ dayOffset: Int, _ kind: PlanKind, _ title: String, _ intensity: Intensity = .easy, key: Bool = false) -> SessionSnapshot {
        SessionSnapshot(id: UUID(), day: monday.startOfDay.adding(days: dayOffset), kind: kind, title: title, minutes: 45, minimumMinutes: 20,
                        minimumDetail: "", intensity: intensity, isKey: key, status: .planned, completedMinutes: nil)
    }
    private func day(_ offset: Int, _ sky: DayWeather.Sky, high: Double = 24, rain: Double = 0, aqi: Int? = nil) -> DayWeather {
        DayWeather(day: monday.startOfDay.adding(days: offset), sky: sky, high: high, low: high - 8, rainChance: rain, aqi: aqi)
    }

    @Test func stormMovesTheKeySessionAndRainTakesTheRestIndoors() {
        let plan = [session(1, .long, "长距离慢跑", key: true), session(3, .aerobic, "轻松跑"), session(4, .strength, "力量训练")]
        let forecast = [day(0, .cloudy), day(1, .thunder, rain: 0.9), day(2, .clear), day(3, .heavyRain, rain: 0.9), day(4, .heavyRain, rain: 0.9),
                        day(5, .clear), day(6, .clear)]
        let a = WeatherPlanner.advice(plan: plan, forecast: forecast, now: monday)
        // Tuesday's long run moves to Wednesday (clear, free); Thursday's easy run goes indoors; strength is indoors anyway.
        #expect(a.ops.contains(.move(from: 3, to: 4)))
        #expect(a.ops.contains { if case .replace(5, _, let t, 45, _, _, _) = $0 { t.contains("室内") } else { false } })
        #expect(a.affected == [3, 5])
        #expect(a.notes.count == 2 && a.notes[0].contains("雷阵雨"))
    }

    @Test func heatEasesHardSessionsAndGoodWeatherChangesNothing() {
        let plan = [session(2, .quality, "间歇跑", .hard)]
        let hot = WeatherPlanner.advice(plan: plan, forecast: [day(2, .clear, high: 33)], now: monday)
        #expect(hot.ops == [.intensity(day: 4, .moderate)])
        #expect(hot.notes.first?.contains("早上 7 点前") == true)
        let fine = WeatherPlanner.advice(plan: plan, forecast: [day(2, .cloudy, high: 22)], now: monday)
        #expect(fine.ops.isEmpty && fine.notes.isEmpty)
        // Polluted air takes it indoors.
        let smog = WeatherPlanner.advice(plan: plan, forecast: [day(2, .clear, aqi: 180)], now: monday)
        #expect(smog.ops.count == 1 && smog.notes.first?.contains("AQI 180") == true)
    }

    @Test func demoProposalGoesThroughTheSafetyChecks() throws {
        let container = try ModelContainer(for: Schema(PulseSchema.models), configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        let ctx = container.mainContext
        DemoDataGenerator.populate(ctx, persona: .xiaolin, now: monday)
        let p = DataHub.profile(in: ctx)!
        let a = DataHub.analytics(in: ctx, now: monday)
        let items = (try? ctx.fetch(FetchDescriptor<PlanItem>())) ?? []
        let c = AgentContext.make(profile: a.profile, name: p.displayName, days: a.days, plan: items.map(\.snapshot), workouts: [], vitals: [],
                                  events: [], stopBang: [], baselineSetAt: nil, raceName: p.raceName, now: monday)
        let r = WeatherPlanner.proposal(context: c, forecast: DemoWeather.days(from: monday), source: "示例天气")
        let (proposal, advice) = try #require(r)
        #expect(proposal.hasChanges && !proposal.checks.isEmpty)
        #expect(proposal.notes.prefix(advice.notes.count) == advice.notes[...])
    }

    @Test func planChangesCheckTheWeatherWhereSessionsLand() throws {
        let container = try ModelContainer(for: Schema(PulseSchema.models), configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        let ctx = container.mainContext
        DemoDataGenerator.populate(ctx, persona: .xiaolin, now: monday)
        let p = DataHub.profile(in: ctx)!
        let a = DataHub.analytics(in: ctx, now: monday)
        let items = (try? ctx.fetch(FetchDescriptor<PlanItem>())) ?? []
        let c = AgentContext.make(profile: a.profile, name: p.displayName, days: a.days, plan: items.map(\.snapshot), workouts: [], vitals: [],
                                  events: [], stopBang: [], baselineSetAt: nil, raceName: p.raceName,
                                  weather: DemoWeather.days(from: monday), weatherSource: "示例天气", now: monday)
        // An outdoor session on a fine day, moved to Wednesday (heavy rain in the demo forecast).
        let s = try #require(c.plan.first { $0.day >= monday.startOfDay && $0.day < monday.weekStart.adding(days: 7) && $0.kind.isTraining
            && WeatherPlanner.isOutdoor($0) && c.weather(on: $0.day)?.isGoodForOutdoors == true })
        let wednesday = 4
        let change = PlanChat.propose([.move(from: s.day.weekday, to: wednesday)], scope: .thisWeek, request: "挪到周三", context: c, source: "test")
        try #require(change.hasChanges)
        #expect(change.notes.contains { $0.hasPrefix("周三有大雨") && $0.contains("改后的「\(s.title)」建议在室内完成") })
        // The rules answer carries it, so the model hears about it too.
        #expect(PlanChat.reply(for: change, context: c).text.contains("周三有大雨"))
        // Changes made for the weather don't repeat it.
        let forWeather = PlanChat.propose([.move(from: s.day.weekday, to: wednesday)], scope: .thisWeek, request: "根据天气预报调整", context: c,
                                          source: "test", checksWeather: false)
        #expect(forWeather.notes.isEmpty)
    }
}

@Suite("Weather reminder")
struct WeatherReminderTests {
    private let today = Calendar.pulse.date(from: DateComponents(year: 2026, month: 10, day: 22))!
    private func run(_ status: PlanStatus = .planned, kind: PlanKind = .aerobic, title: String = "轻松跑") -> SessionSnapshot {
        SessionSnapshot(id: UUID(), day: today, kind: kind, title: title, minutes: 40, minimumMinutes: 20, minimumDetail: "",
                        intensity: .easy, isKey: false, status: status, completedMinutes: nil)
    }
    private func weather(_ sky: DayWeather.Sky, high: Double, rain: Double = 0, aqi: Int? = nil) -> DayWeather {
        DayWeather(day: today, sky: sky, high: high, low: high - 8, rainChance: rain, aqi: aqi)
    }

    @Test func remindsForTheOutdoorSessionStillToDo() throws {
        let hot = try #require(WeatherPlanner.reminder(today: weather(.clear, high: 33), sessions: [run()]))
        #expect(hot.badge == "高温" && hot.short.contains("早晚练") && !hot.changePlan)
        let storm = try #require(WeatherPlanner.reminder(today: weather(.thunder, high: 22, rain: 0.9), sessions: [run()]))
        #expect(storm.changePlan && storm.line.contains("「轻松跑」"))
        // Fine weather, a finished session, or an indoor one: nothing to say.
        #expect(WeatherPlanner.reminder(today: weather(.cloudy, high: 24), sessions: [run()]) == nil)
        #expect(WeatherPlanner.reminder(today: weather(.clear, high: 33), sessions: [run(.done)]) == nil)
        #expect(WeatherPlanner.reminder(today: weather(.clear, high: 33), sessions: [run(kind: .strength, title: "力量训练")]) == nil)
        #expect(WeatherPlanner.reminder(today: nil, sessions: [run()]) == nil)
    }
}

@Suite("Health Agent and the weather")
struct AgentWeatherTests {
    private let morning = Calendar.pulse.date(from: DateComponents(year: 2026, month: 10, day: 22, hour: 9))!
    private func context(_ weather: [DayWeather], kind: PlanKind = .aerobic, title: String = "轻松跑") -> AgentContext {
        let s = SessionSnapshot(id: UUID(), day: morning.startOfDay.adding(days: 1), kind: kind, title: title, minutes: 40, minimumMinutes: 20,
                                minimumDetail: "", intensity: .easy, isKey: false, status: .planned, completedMinutes: nil)
        return AgentContext.make(profile: ProfileSnapshot(), name: "测试", days: [], plan: [s], workouts: [], vitals: [], events: [], stopBang: [],
                                 baselineSetAt: nil, raceName: "", weather: weather, weatherSource: "示例天气", now: morning)
    }
    private func day(_ offset: Int, _ sky: DayWeather.Sky, high: Double, rain: Double = 0) -> DayWeather {
        DayWeather(day: morning.startOfDay.adding(days: offset), sky: sky, high: high, low: high - 8, rainChance: rain)
    }

    @Test func trainingQuestionsWeighTheForecast() {
        let storm = context([day(0, .cloudy, high: 24), day(1, .thunder, high: 22, rain: 0.9)])
        let r = HealthAgent.reply(to: "明天适合跑步吗？", context: storm)
        #expect(r.intent == .trainingCheck)
        #expect(r.text.contains("雷阵雨") && r.text.contains("室内"))
        #expect(r.sources.contains("天气预报"))
        // A strength session is not affected; a fine day says so.
        let gym = HealthAgent.reply(to: "明天适合做力量训练吗？", context: context([day(1, .thunder, high: 22, rain: 0.9)], kind: .strength, title: "力量训练"))
        #expect(!gym.text.contains("雷阵雨"))
        let fine = HealthAgent.reply(to: "明天适合跑步吗？", context: context([day(1, .clear, high: 22)]))
        #expect(fine.text.contains("适合户外"))
    }

    @Test func weatherQuestionsGetTheForecastAndAPlanChange() {
        let c = context([day(0, .cloudy, high: 24), day(1, .heavyRain, high: 20, rain: 0.9), day(2, .clear, high: 25)])
        let r = HealthAgent.reply(to: "这几天的天气适合户外训练吗？", context: c)
        #expect(r.intent == .weather)
        #expect(r.text.contains("天气预报：今天 多云") && r.text.contains("明天 大雨"))
        #expect(r.blocks.contains { if case .plan = $0 { true } else { false } })
        #expect(HealthAgent.digest(c).contains("天气预报（示例天气）"))
        // No forecast: says so instead of guessing.
        #expect(HealthAgent.reply(to: "明天天气怎么样？", context: context([])).text.contains("拿不到天气预报"))
    }
}
