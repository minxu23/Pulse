import Foundation
import SwiftData

/// The baseline report from the stored records (三阶段计划).
struct BaselineResult: Equatable, Codable {
    var report: BaselineReport
    var concerns: [Concern]
    var recommendation: PackRecommendation
}

extension DataHub {
    /// The baseline days for someone with history: the 14 full days before today.
    static func historyWindow(now: Date = .app) -> DateInterval {
        let end = DayClock.logicalToday(now)
        return DateInterval(start: end.adding(days: -14), end: end)
    }

    static func baselineInput(in ctx: ModelContext, window: DateInterval, now: Date = .app) -> BaselineInput {
        let a = analytics(in: ctx, now: now)
        let sessions = (try? ctx.fetch(FetchDescriptor<ActivitySession>())) ?? []
        let vitals = (try? ctx.fetch(FetchDescriptor<VitalReading>())) ?? []
        let meals = (try? ctx.fetch(FetchDescriptor<MealLog>())) ?? []
        let labs = (try? ctx.fetch(FetchDescriptor<LabResult>())) ?? []
        let events = (try? ctx.fetch(FetchDescriptor<HealthEvent>())) ?? []
        let back = window.start.adding(days: -100)
        return BaselineInput(profile: a.profile,
                             days: a.days.filter { $0.day >= back && $0.day < window.end },
                             workouts: sessions.filter { $0.start >= back && $0.start < window.end }.map(\.point),
                             vitals: vitals.filter { $0.time >= back && $0.time < window.end }.map(\.point),
                             meals: meals.map(\.time).filter { $0 >= back && $0 < window.end },
                             labs: labs.map(\.point),
                             rhythmAlerts: events.filter { $0.kind == .irregularRhythm }.map(\.relatedDate),
                             window: window)
    }

    static func baseline(in ctx: ModelContext, window: DateInterval, now: Date = .app) -> BaselineResult {
        let x = baselineInput(in: ctx, window: window, now: now)
        let r = BaselineAssessment.assess(x)
        return BaselineResult(report: r, concerns: CauseInference.concerns(r, x),
                              recommendation: ProgramPacks.recommend(r, profile: x.profile))
    }
}

extension BaselineResult {
    /// The report's opening line: the strongest ability, the one that needs work most (the recommended pack's,
    /// when it has one), and the pack.
    var summaryLine: String {
        let cards = report.cards.filter { $0.verdict != nil }
        func key(_ c: AbilityCard) -> (Verdict, Int) { (c.verdict!, -(c.band?.rawValue ?? 2)) }
        let pack = recommendation.recommended.pack
        let worst = pack.ability.flatMap { a in cards.first { $0.ability == a } } ?? cards.max { key($0) < key($1) }
        let best = cards.filter { $0.verdict == .good && $0.ability != worst?.ability }.min { key($0) < key($1) }
        var parts: [String] = []
        if let best {
            let top = best.metrics.compactMap(\.rank).max { $0.goodness < $1.goodness }
            parts.append("\(best.ability.title)是你的强项" + (top.map { "（同龄\($0.approx)）" } ?? ""))
        }
        // The weakness named is a health outcome behind the pack (not a habit like steps).
        let outcomes = ProgramPacks.outcomes[pack] ?? Set(worst?.metrics.map(\.kind) ?? [])
        let weak = worst?.metrics.filter { outcomes.contains($0.kind) && ($0.verdict ?? .good) >= .fair }
            .min { ($0.verdict ?? .good, -($0.rank?.goodness ?? 50)) > ($1.verdict ?? .good, -($1.rank?.goodness ?? 50)) }
        if let worst, let m = weak {
            parts.append("最需要改善的是\(worst.ability.title)：\(m.title) \(m.valueText)")
        }
        let flagged = cards.filter { ($0.verdict ?? .good) >= .attention }.count
        if flagged >= 2 { parts.append("4 项能力里有 \(flagged) 项需要关注") }
        parts.append("建议先做「\(pack.title)」" + (weak == nil ? "（\(recommendation.recommended.reason)）" : ""))
        return parts.joined(separator: "；") + "。"
    }
}

// MARK: - 三阶段计划: phases

extension UserProfile {
    var programPhase: ProgramPhase {
        get { ProgramPhase(rawValue: programPhaseRaw) ?? .none }
        set { programPhaseRaw = newValue.rawValue }
    }
    var programPack: ProgramPack? { ProgramPack(rawValue: programPackRaw) }
    /// Weekly plans are made unless the user only records (sample users always get them): 基线期 gets a 摸底周,
    /// a running pack its own weeks, and someone outside the program the general plan (Docs 8).
    var makesPlans: Bool { usesDemoData || usageIntent != .recording || programPhase.runsPack }
    var programTarget: TargetMetric? { TargetMetric(rawValue: programTargetRaw) }
    /// What the running pack's plan needs from the baseline, kept as JSON.
    var programPlan: ProgramPlanInput? {
        get { programPlanData.flatMap { try? JSONDecoder().decode(ProgramPlanInput.self, from: $0) } }
        set { programPlanData = newValue.flatMap { try? JSONEncoder().encode($0) } }
    }
    /// The round's main target, its baseline and goal.
    var targetGoal: TargetGoal? {
        programTarget.map { TargetGoal(target: $0, baseline: programTargetBaseline, goal: programTargetGoal) }
    }
}

/// Where the user is in the plan, for the cards and pages that show it.
struct ProgramStatus: Equatable {
    var phase: ProgramPhase
    /// 基线期: full days recorded so far (the window), and whether the report can be made.
    var baselineDays = 0
    var reportReady = false
    var missing: [BaselineCompleteness.Item] = []
    var pack: ProgramPack?
    var target: TargetMetric?
    var round = 0
    /// 1-based week of the round; 0 before it starts (the days until the Monday it begins).
    var week = 0
    var weeks = 4

    /// What still needs doing: not what the remaining days fill up on their own.
    var stillToDo: [BaselineCompleteness.Item] {
        BaselineCompleteness(items: missing).stillToDo(daysLeft: max(0, ProgramFlow.baselineDays - baselineDays))
    }

    /// 「基线期第 3/7 天 · 还差：心肺能力估算」 (the 「现在」 card on 今日).
    var baselineLine: String {
        let day = "基线期第 \(min(baselineDays + 1, ProgramFlow.baselineDays))/\(ProgramFlow.baselineDays) 天"
        return stillToDo.isEmpty ? day + " · 照常生活就好" : day + " · 还差：" + stillToDo.map(\.label).joined(separator: "、")
    }
}

enum ProgramFlow {
    static let baselineDays = 7
    static let longestBaseline = 14

    /// The baseline days so far: from the start up to (not including) today.
    static func baselineWindow(_ p: UserProfile, now: Date = .app) -> DateInterval {
        let today = DayClock.logicalToday(now)
        let start = min(p.programBaselineStart ?? today, today)
        return DateInterval(start: start, end: max(start, today))
    }

    @MainActor
    static func status(_ p: UserProfile, in ctx: ModelContext, now: Date = .app) -> ProgramStatus {
        syncRoundLength(p, in: ctx, now: now)
        var s = ProgramStatus(phase: p.programPhase, pack: p.programPack, target: p.programTarget,
                              round: p.programRound, weeks: p.programRoundWeeks)
        switch p.programPhase {
        case .baseline:
            let w = baselineWindow(p, now: now)
            s.baselineDays = w.end.daysSince(w.start)
            let r = DataHub.baseline(in: ctx, window: w, now: now).report
            s.missing = r.completeness.missing
            s.reportReady = isReady(days: s.baselineDays, r)
        case .improve, .summary:
            s.week = week(p, now: now)
        case .none:
            break
        }
        return s
    }

    /// A week with everything needed, or two weeks whatever is still missing.
    static func isReady(days: Int, _ r: BaselineReport) -> Bool {
        (days >= baselineDays && r.completeness.isReady) || days >= longestBaseline
    }

    /// Starts the baseline. Someone whose last 14 days already hold enough gets the report straight away.
    /// The days still to come get the 摸底周 in place of what was planned.
    @MainActor
    static func startBaseline(_ p: UserProfile, in ctx: ModelContext, now: Date = .app) {
        let history = DataHub.historyWindow(now: now)
        let r = DataHub.baseline(in: ctx, window: history, now: now).report
        let today = DayClock.logicalToday(now)
        p.programPhase = .baseline
        p.programBaselineStart = r.completeness.isReady ? history.start : today
        p.programPackRaw = ""
        p.programTargetRaw = ""
        p.programRound = 0
        p.programRoundStart = nil
        p.programRoundWeeks = 4
        p.programPlan = nil
        p.programTargetBaseline = nil
        p.programTargetGoal = nil
        // A new assessment: its danger signs are asked about again.
        p.programClearedFlags = []
        // The week's minutes are no goal while the baseline records what is usual.
        p.weeklyTargetReason = "基线期照常生活，这周的分钟数只作参考，不用刻意多练。"
        try? ctx.save()
        DataHub.clearPlannedDays(from: now.startOfDay, in: ctx)
        DataHub.insertPlan(for: p, weekStart: now.weekStart, fromDay: now.startOfDay, in: ctx)
        try? ctx.save()
    }

    /// The direction the user picked (记录 or one of the packs): recording stops new training; any other
    /// direction starts with a baseline, which replaces the days still planned.
    @MainActor
    static func setUsageIntent(_ intent: UsageIntent, note: String, profile p: UserProfile, in ctx: ModelContext, now: Date = .app) {
        let changed = intent != p.usageIntent
        p.usageIntent = intent
        p.goalNote = note
        if intent == .recording {
            p.programPhase = .none
            p.programPlan = nil
            if changed { DataHub.clearPlannedDays(from: now.startOfDay, in: ctx) }
        } else if changed || p.programPhase == .none {
            startBaseline(p, in: ctx, now: now)
        }
        try? ctx.save()
    }

    /// Rounds start on a Monday, in step with the week plan and the weekly review: today if it is Monday,
    /// otherwise the next one. Existing arrangements are kept until that date.
    static func roundStart(now: Date = .app) -> Date {
        let today = DayClock.logicalToday(now)
        let weekday = Calendar.pulse.component(.weekday, from: today)
        return weekday == 2 ? today : today.adding(days: (9 - weekday) % 7)
    }

    static func week(_ p: UserProfile, now: Date = .app) -> Int {
        guard let start = p.programRoundStart else { return 0 }
        let d = DayClock.logicalToday(now).daysSince(start)
        return d < 0 ? 0 : d / 7 + 1
    }

    static func initialWeeklyMinutes(profile: ProfileSnapshot, report: BaselineReport) -> Int {
        let cap = Int(Double(profile.weeklyTimeBudget) * 0.8)
        return min(max(60, cap), max(60, Int(report.habits.guidelineMinutes * 1.1).roundedTo5()))
    }

    /// What the pack's weeks need from the baseline: the user's sports, steps, minutes, usual days and time,
    /// and whether heart rate recovered slowly.
    static func planInput(_ pack: ProgramPack, target: TargetMetric, round: Int, start: Date, report r: BaselineReport) -> ProgramPlanInput {
        ProgramPlanInput(pack: pack, target: target, round: round, roundStart: start, weeks: 4, sports: r.habits.sports,
                         baselineSteps: r.habits.stepsMean, baselineMinutes: r.habits.guidelineMinutes,
                         vo2Band: r.metric(.vo2max)?.rank?.band.rawValue, usualWeekdays: r.habits.usualWeekdays,
                         mainSlot: r.habits.mainSlot, slowRecovery: r.metric(.hrRecovery)?.verdict == .attention)
    }

    static func preview(_ pack: ProgramPack, result: BaselineResult, profile: ProfileSnapshot, now: Date = .app) -> WeekPlan {
        var p = profile
        p.weeklyTargetMinutes = initialWeeklyMinutes(profile: profile, report: result.report)
        p.programPhase = .improve
        let r = result.report
        let start = roundStart(now: now)
        let input = planInput(pack, target: ProgramPacks.target(for: pack, report: r, profile: p), round: 1, start: start, report: r)
        return PackPlanner.week(profile: p, input: input, weekStart: start)
    }

    /// The days the new pack starts from: the baseline week, or when switching packs mid-way the last 14 days,
    /// with the frozen baseline report left as it is (Docs 6).
    @MainActor
    static func startWindow(_ p: UserProfile, result: BaselineResult, now: Date = .app) -> DateInterval {
        p.programPhase.runsPack ? DataHub.historyWindow(now: now) : result.report.window
    }

    /// Danger signs in the report that no doctor has allowed yet: the program waits for them (Docs 2.9).
    static func doctorStillNeeded(_ p: UserProfile, _ r: BaselineReport) -> Bool {
        guard !r.redFlags.isEmpty else { return false }
        let cleared = Set(p.programClearedFlags)
        guard let kinds = r.redFlagKinds, !kinds.isEmpty else { return cleared.isEmpty }
        return !Set(kinds).isSubset(of: cleared)
    }

    /// The user says a doctor has seen these danger signs and allowed exercise: starting the program, nothing
    /// more (the intensity limits for heart and kidney conditions stay as they are).
    static func confirmDoctor(_ p: UserProfile, _ r: BaselineReport) {
        p.programClearedFlags = Array(Set(p.programClearedFlags).union(r.redFlagKinds ?? ["legacy"])).sorted()
    }

    /// Freezes the baseline report and starts round 1 of the chosen pack: the main target's baseline and goal,
    /// a weekly volume that starts just above what the baseline showed, and this week's plan from the pack.
    /// Switching packs starts a new round from the current data and keeps the baseline report.
    @MainActor
    static func choose(_ pack: ProgramPack, result: BaselineResult, profile p: UserProfile, in ctx: ModelContext, now: Date = .app) {
        guard p.canStartImprovement else { return }
        let switching = p.programPhase.runsPack
        let fresh = DataHub.baseline(in: ctx, window: startWindow(p, result: result, now: now), now: now)
        guard !doctorStillNeeded(p, fresh.report) else { return }
        let snap = DataHub.analytics(in: ctx, now: now).profile
        let r = fresh.report
        guard ProgramPacks.blocker(pack, r, snap) == nil else { return }
        let target = ProgramPacks.target(for: pack, report: r, profile: snap)
        if !switching, let data = try? JSONEncoder().encode(fresh) {
            ctx.insert(ProgramSnapshot(.baseline, round: 0, pack: pack.rawValue, payload: data, createdAt: now))
        }
        let start = roundStart(now: now)
        let newRound = p.programRound > 0 ? p.programRound + 1 : 1
        p.usageIntentRaw = pack.rawValue
        p.programPackRaw = pack.rawValue
        p.programTargetRaw = target.rawValue
        p.programPhase = .improve
        p.programRound = newRound
        p.programRoundStart = start
        p.programRoundWeeks = 4
        // Weekly distance is measured against the plan, so it has a goal (90%) but no baseline to compare with.
        let base = target == .weeklyRunKm ? nil : baselineValue(target, result: fresh, in: ctx, now: now)
        p.programTargetBaseline = base
        p.programTargetGoal = base.map { TargetTracker.goal(target, baseline: $0, profile: snap, report: r) }
            ?? TargetTracker.defaultGoal(target, profile: snap)
        p.programPlan = planInput(pack, target: target, round: newRound, start: start, report: r)
        // Start a little above what the baseline showed, never below an hour.
        p.weeklyTargetMinutes = initialWeeklyMinutes(profile: snap, report: r)
        p.weeklyTargetReason = "按基线期每周约 \(Int(r.habits.guidelineMinutes)) 分钟中高强度运动，从略多一点开始。"
        try? ctx.save()
        // Generate only the new round's days. Starting next Monday must not rewrite this week.
        DataHub.clearPlannedDays(from: start, in: ctx)
        DataHub.insertPlan(for: p, weekStart: start, fromDay: start, in: ctx)
        try? ctx.save()
    }

    /// A blood-pressure monitor bought during a round on clinic readings: home blood pressure from today, in
    /// the same round with the same baseline, and the home goal (Docs 3.1).
    @MainActor
    static func switchToHomeBP(_ p: UserProfile, in ctx: ModelContext) {
        p.hasBPMonitor = true
        if p.programTarget == .clinicBP {
            let snap = p.snapshot(medications: DataHub.medications(in: ctx))
            p.programTargetRaw = TargetMetric.homeBP.rawValue
            if var input = p.programPlan { input.target = .homeBP; p.programPlan = input }
            p.programTargetGoal = p.programTargetBaseline.map { TargetTracker.goal(.homeBP, baseline: $0, profile: snap) }
                ?? TargetTracker.defaultGoal(.homeBP, profile: snap)
        }
        try? ctx.save()
    }

    /// The main target's value over the baseline days (weekly distance: kilometres a week over the last 4 weeks).
    @MainActor
    static func baselineValue(_ t: TargetMetric, result: BaselineResult, in ctx: ModelContext, now: Date = .app) -> Double? {
        let r = result.report
        switch t {
        case .vo2max: if let v = r.metric(.vo2max)?.value { return v.rounded(to: 0.1) }
        case .restingHR: if let v = r.metric(.rhr)?.value { return v.rounded() }
        case .homeBP: if let v = r.metric(.bloodPressure)?.value { return v.rounded() }
        default: break
        }
        let x = DataHub.baselineInput(in: ctx, window: r.window, now: now)
        if t == .clinicBP {
            let bp = x.vitals.filter { $0.kind == .bloodPressure && $0.time >= r.window.end.adding(days: -28) }
            return Stats.mean(bp.map(\.value))?.rounded()
        }
        if t == .weeklyRunKm {
            let runs = x.workouts.filter { $0.type == .run && $0.start >= r.window.end.adding(days: -28) }
            return (runs.compactMap(\.distanceKm).reduce(0, +) / 4).rounded(to: 0.1)
        }
        return TargetTracker.reading(t, days: x.days, vitals: x.vitals, workouts: x.workouts, end: r.window.end).value.map { $0.rounded(to: 0.1) }
    }

    /// The latest frozen report of a kind.
    @MainActor
    static func snapshot<T: Decodable>(_ kind: ProgramSnapshot.Kind, as type: T.Type, in ctx: ModelContext) -> T? {
        let k = kind.rawValue
        var d = FetchDescriptor<ProgramSnapshot>(predicate: #Predicate { $0.kind == k }, sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        d.fetchLimit = 1
        guard let s = (try? ctx.fetch(d))?.first else { return nil }
        return try? JSONDecoder().decode(T.self, from: s.payload)
    }

    /// The baseline report the current plan started from.
    @MainActor
    static func baselineSnapshot(in ctx: ModelContext) -> BaselineResult? { snapshot(.baseline, as: BaselineResult.self, in: ctx) }

    /// The report frozen when 总结期 began.
    @MainActor
    static func summarySnapshot(in ctx: ModelContext) -> BaselineResult? { snapshot(.summary, as: BaselineResult.self, in: ctx) }
}

// MARK: - 三阶段计划: weeks, round end, summary

extension ProgramFlow {
    @MainActor
    static func evaluatorInput(_ p: UserProfile, in ctx: ModelContext, now: Date = .app) -> ProgramEvaluator.Input? {
        let a = DataHub.analytics(in: ctx, now: now)
        guard let program = a.profile.program else { return nil }
        let back = program.roundStart.adding(days: -70)
        let sessions = (try? ctx.fetch(FetchDescriptor<ActivitySession>())) ?? []
        let vitals = (try? ctx.fetch(FetchDescriptor<VitalReading>())) ?? []
        let items = (try? ctx.fetch(FetchDescriptor<PlanItem>())) ?? []
        let reviews = (try? ctx.fetch(FetchDescriptor<ReviewEntry>())) ?? []
        return ProgramEvaluator.Input(program: program, profile: a.profile,
                                      days: a.days.filter { $0.day >= back },
                                      workouts: sessions.filter { $0.start >= back }.map(\.point),
                                      vitals: vitals.filter { $0.time >= back }.map(\.point),
                                      plan: items.filter { $0.day >= back }.map(\.snapshot),
                                      baseline: p.programTargetBaseline, goal: p.programTargetGoal,
                                      hardest: reviews.filter { $0.periodStart >= program.roundStart && !$0.change.isEmpty }.map(\.change),
                                      missedBefore: missedInARow(in: ctx))
    }

    /// Rounds of the current program, last first, that ended without their goal, counted until one that reached it.
    @MainActor
    static func missedInARow(in ctx: ModelContext) -> Int {
        let baselineKind = ProgramSnapshot.Kind.baseline.rawValue, roundKind = ProgramSnapshot.Kind.round.rawValue
        let all = (try? ctx.fetch(FetchDescriptor<ProgramSnapshot>(sortBy: [SortDescriptor(\.createdAt)]))) ?? []
        let since = all.last { $0.kind == baselineKind }?.createdAt ?? .distantPast
        let rounds = all.filter { $0.kind == roundKind && $0.createdAt >= since }
            .compactMap { try? JSONDecoder().decode(ProgramRoundResult.self, from: $0.payload) }
        return rounds.reversed().prefix { !$0.outcome.endsProgram && $0.outcome != .phaseCheck }.count
    }

    /// Keeps the round's length in step with its weeks of illness or travel (Docs 5), for the plan and the cards.
    @MainActor
    static func syncRoundLength(_ p: UserProfile, in ctx: ModelContext, now: Date = .app) {
        guard p.programPhase == .improve, let x = evaluatorInput(p, in: ctx, now: now) else { return }
        let weeks = ProgramEvaluator.roundWeeks(x, now: now)
        guard weeks != p.programRoundWeeks else { return }
        p.programRoundWeeks = weeks
        if var input = p.programPlan { input.weeks = weeks; p.programPlan = input }
    }

    @MainActor
    static func weekReport(_ p: UserProfile, weekStart: Date, in ctx: ModelContext, now: Date = .app) -> ProgramWeekReport? {
        guard p.programPhase == .improve, let start = p.programRoundStart, weekStart >= start,
              weekStart < start.adding(days: 7 * p.programRoundWeeks), let x = evaluatorInput(p, in: ctx, now: now) else { return nil }
        return ProgramEvaluator.week(x, weekStart: weekStart, now: now)
    }

    /// The same from the records a screen already holds (复盘), without fetching them all again.
    @MainActor
    static func weekReport(_ p: UserProfile, weekStart: Date, context c: AgentContext) -> ProgramWeekReport? {
        guard p.programPhase == .improve, let start = p.programRoundStart, weekStart >= start,
              weekStart < start.adding(days: 7 * p.programRoundWeeks), let program = c.profile.program else { return nil }
        let x = ProgramEvaluator.Input(program: program, profile: c.profile, days: c.days, workouts: c.workouts, vitals: c.vitals,
                                       plan: c.plan, baseline: p.programTargetBaseline, goal: p.programTargetGoal)
        return ProgramEvaluator.week(x, weekStart: weekStart, now: c.now)
    }

    @MainActor
    static func roundResult(_ p: UserProfile, in ctx: ModelContext, now: Date = .app) -> ProgramRoundResult? {
        guard p.programPhase == .improve, let x = evaluatorInput(p, in: ctx, now: now) else { return nil }
        return ProgramEvaluator.round(x, now: now)
    }

    /// Closes the round: an achieved one (or a race that is over) leads to 总结期 with the summary report frozen;
    /// otherwise the next round starts with its adjustment.
    @MainActor
    static func finishRound(_ result: ProgramRoundResult, profile p: UserProfile, in ctx: ModelContext, now: Date = .app) {
        if let data = try? JSONEncoder().encode(result) {
            ctx.insert(ProgramSnapshot(.round, round: result.round, pack: p.programPackRaw, payload: data, createdAt: now))
        }
        if result.outcome.endsProgram {
            p.programPhase = .summary
            // 总结报告: frozen like the baseline report, so later data doesn't change the comparison (Docs 2.5, 9).
            let summary = DataHub.baseline(in: ctx, window: DataHub.historyWindow(now: now), now: now)
            if let data = try? JSONEncoder().encode(summary) {
                ctx.insert(ProgramSnapshot(.summary, round: result.round, pack: p.programPackRaw, payload: data, createdAt: now))
            }
        } else {
            p.programRound += 1
            p.programRoundStart = roundStart(now: now)
            p.programRoundWeeks = 4
            if result.outcome == .lowAdherence {
                p.weeklyTargetMinutes = max(45, Int(Double(p.weeklyTargetMinutes) * 0.85).roundedTo5())
                p.weeklyTargetReason = "上一轮完成得少，这一轮先把量降一些。"
            }
            if var input = p.programPlan {
                input.round = p.programRound
                input.roundStart = p.programRoundStart!
                input.weeks = 4
                p.programPlan = input
            }
        }
        try? ctx.save()
        DataHub.regenerateWeekPlan(in: ctx, now: now)
        try? ctx.save()
    }

    /// After three rounds without the goal: the round's result is kept with the others and a new baseline starts.
    @MainActor
    static func reassess(after result: ProgramRoundResult, profile p: UserProfile, in ctx: ModelContext, now: Date = .app) {
        if let data = try? JSONEncoder().encode(result) {
            ctx.insert(ProgramSnapshot(.round, round: result.round, pack: p.programPackRaw, payload: data, createdAt: now))
        }
        startBaseline(p, in: ctx, now: now)
    }

    /// The round summaries so far, oldest first.
    @MainActor
    static func roundResults(in ctx: ModelContext) -> [ProgramRoundResult] {
        let k = ProgramSnapshot.Kind.round.rawValue
        let d = FetchDescriptor<ProgramSnapshot>(predicate: #Predicate { $0.kind == k }, sortBy: [SortDescriptor(\.createdAt)])
        return ((try? ctx.fetch(d)) ?? []).compactMap { try? JSONDecoder().decode(ProgramRoundResult.self, from: $0.payload) }
    }

    /// From 总结期: a reminder to look again in 3 months (a care task with a due date).
    @MainActor
    static func scheduleReassessment(in ctx: ModelContext, now: Date = .app) {
        let t = CareTask(title: "三阶段计划复评：重新记录一周，生成新的基线报告", area: .general, due: now.startOfDay.adding(days: 90))
        ctx.insert(t)
        try? ctx.save()
    }
}
