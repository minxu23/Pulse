import Foundation
import SwiftData

// MARK: - Model → engine snapshots

extension UserProfile {
    func snapshot(medications: [MedicationEntry]) -> ProfileSnapshot {
        var s = ProfileSnapshot()
        s.age = age
        s.sex = sex
        s.bmi = bmi
        s.neckCm = neckCm
        s.level = activityLevel
        s.conditions = conditions
        s.medications = medications.map { MedicationInfo(name: $0.name, category: $0.category, start: $0.startDate, end: $0.endDate) }
        s.goals = goals
        s.modules = modules
        s.journeyReached = journeyReached
        s.availableWeekdays = availableWeekdays
        s.sessionMinutes = sessionMinutes
        s.weeklyTimeBudget = weeklyTimeBudget
        s.weeklyTargetMinutes = weeklyTargetMinutes
        s.baselineRHR = baselineRHR
        s.sleepNeedMinutes = sleepNeedHours * 60
        s.bedtimeMinutes = bedtimeMinutes
        s.wakeMinutes = wakeMinutes
        s.shift = shiftSchedule
        s.caffeineCutoffHour = caffeineCutoffHour
        s.weeklyAlcoholLimit = weeklyAlcoholLimit
        s.waterTargetMl = waterTargetMl
        s.fluidLimited = fluidLimit
        s.tracksNutrients = nutrientTracking
        s.saltLimitG = saltLimitG
        s.proteinTargetG = proteinTargetG
        s.potassiumLimit = potassiumLimit
        s.phosphorusLimit = phosphorusLimit
        s.extraConditions = extraConditionsRaw.map(ConditionLibrary.resolve)
        s.stepsTarget = stepsTarget
        s.hrCap = exerciseHRCap
        s.clinicianCleared = clinicianCleared
        s.thresholdHR = thresholdHR
        s.apneaStatus = apneaStatus
        s.apneaTreatment = apneaTreatment
        s.cpapTargetHours = cpapTargetHours
        s.glucoseLow = glucoseLow
        s.glucoseHigh = glucoseHigh
        s.glucosePreExerciseMin = glucosePreExerciseMin
        s.glucoseExerciseMax = glucoseExerciseMax
        s.bpTargetSys = bpTargetSys
        s.bpTargetDia = bpTargetDia
        s.limitations = limitations
        if let date = raceDate {
            s.race = RaceInfo(name: raceName, date: date, targetMinutes: raceTargetMinutes,
                              startDate: marathonStart ?? createdAt, currentWeeklyKm: currentWeeklyKm,
                              longestRunKm: longestRecentRunKm, fuelCarbsPerHour: fuelCarbsPerHour)
        }
        return s
    }
}

extension PlanItem {
    var snapshot: SessionSnapshot {
        SessionSnapshot(id: id, day: day, kind: kind, title: title, minutes: minutes, minimumMinutes: minimumMinutes,
                        minimumDetail: minimumDetail, intensity: intensity, isKey: isKey, status: status,
                        completedMinutes: completedMinutes)
    }
}

extension ActivitySession {
    var point: WorkoutPoint {
        WorkoutPoint(start: start, type: type, minutes: minutes, avgHR: avgHR, rpe: rpe, distanceKm: distanceKm)
    }
}

extension VitalReading {
    var point: VitalPoint { VitalPoint(time: time, kind: kind, value: value, value2: value2, context: context) }
}

enum DayBuilder {
    static func build(records: [DailyRecord], sessions: [ActivitySession]) -> [DayData] {
        let byDay = Dictionary(grouping: sessions, by: \.day)
        var out: [Date: DayData] = [:]
        for r in records {
            var d = DayData(day: r.day)
            d.rhr = r.restingHR
            d.rhrSource = r.rhrSource
            d.hrv = r.hrv
            d.sleepMinutes = r.sleepMinutes
            d.sleepStart = r.sleepStart
            d.sleepEnd = r.sleepEnd
            d.deepMinutes = r.deepMinutes
            d.spo2Min = r.spo2Min
            d.breathingDisturbances = r.breathingDisturbances
            d.respiratoryRate = r.respiratoryRate
            d.vo2Max = r.vo2Max
            d.steps = r.steps
            d.exerciseMinutes = r.exerciseMinutes
            d.energy = r.energy
            d.sleepFeel = r.sleepFeel
            d.soreness = r.soreness
            d.stress = r.stress
            d.illness = r.illnessSymptoms
            d.tags = r.tags
            d.alcoholUnits = r.alcoholUnits
            d.caffeineCups = r.caffeineCups
            d.lastCaffeineHour = r.lastCaffeineHour
            d.waterMl = r.waterMl
            d.lateMeal = r.lateMeal
            d.dietQuality = r.dietQuality
            d.nutrientsLogged = r.nutrientsLogged
            d.saltG = r.saltG
            d.saltSources = r.saltSources
            d.proteinServings = r.proteinServings
            d.potassiumFoods = r.potassiumFoods
            d.phosphorusFoods = r.phosphorusFoods
            d.snoring = r.snoring
            d.gasping = r.gasping
            d.witnessedApnea = r.witnessedApnea
            d.morningHeadache = r.morningHeadache
            d.daytimeSleepy = r.daytimeSleepy
            d.cpapHours = r.cpapHours
            d.eveningFatigue = r.eveningFatigue
            d.eveningSoreness = r.eveningSoreness
            d.eveningStress = r.eveningStress
            d.plannedBedtime = r.plannedBedtime
            d.checkedIn = r.hasCheckIn
            d.medsTaken = r.medsTaken
            out[d.day] = d
        }
        for (day, list) in byDay {
            var d = out[day] ?? DayData(day: day)
            d.load = list.map(\.load).reduce(0, +)
            d.sessionMinutes = list.map(\.minutes).reduce(0, +)
            d.hardSession = list.contains(where: \.isHard) || d.tags.contains(.hardTraining)
            out[day] = d
        }
        return out.values.sorted { $0.day < $1.day }
    }
}

/// Everything the screens need, computed once from the current query results.
struct Analytics {
    let profile: ProfileSnapshot
    let days: [DayData]
    let trend: RHRTrend
    let now: Date

    init(profile: UserProfile?, medications: [MedicationEntry], records: [DailyRecord],
         sessions: [ActivitySession], now: Date = .app) {
        self.now = now
        self.profile = profile?.snapshot(medications: medications) ?? ProfileSnapshot()
        self.days = DayBuilder.build(records: records, sessions: sessions)
        self.trend = RHRTrendAnalyzer.analyze(days: days, profile: self.profile, today: now)
    }

    func day(_ date: Date) -> DayData? { days.first { $0.day == date.startOfDay } }
    var today: DayData? { day(now) }
    var history: [DayData] { days.filter { $0.day < now.startOfDay } }

    func readiness(on date: Date? = nil) -> ReadinessResult {
        let d = (date ?? now).startOfDay
        return ReadinessEngine.evaluate(today: day(d) ?? DayData(day: d),
                                        history: days.filter { $0.day < d }, profile: profile)
    }
}

// MARK: - Persistence helpers

@MainActor
enum DataHub {
    static func record(for date: Date, in ctx: ModelContext) -> DailyRecord {
        let d = date.startOfDay
        let desc = FetchDescriptor<DailyRecord>(predicate: #Predicate { $0.day == d })
        if let r = try? ctx.fetch(desc).first { return r }
        let r = DailyRecord(day: d)
        ctx.insert(r)
        return r
    }

    static func profile(in ctx: ModelContext) -> UserProfile? {
        try? ctx.fetch(FetchDescriptor<UserProfile>()).first
    }

    static func medications(in ctx: ModelContext) -> [MedicationEntry] {
        (try? ctx.fetch(FetchDescriptor<MedicationEntry>())) ?? []
    }

    static func analytics(in ctx: ModelContext, now: Date = .app) -> Analytics {
        Analytics(profile: profile(in: ctx), medications: medications(in: ctx),
                  records: (try? ctx.fetch(FetchDescriptor<DailyRecord>())) ?? [],
                  sessions: (try? ctx.fetch(FetchDescriptor<ActivitySession>())) ?? [], now: now)
    }

    static func planItems(weekStart: Date, in ctx: ModelContext) -> [PlanItem] {
        let ws = weekStart
        let desc = FetchDescriptor<PlanItem>(predicate: #Predicate { $0.weekStart == ws }, sortBy: [SortDescriptor(\.day)])
        return (try? ctx.fetch(desc)) ?? []
    }

    /// Creates this week's plan if it does not exist yet, progressing the weekly target from
    /// last week's completion (需求 4).
    static func ensureWeekPlan(in ctx: ModelContext, now: Date = .app) {
        guard let profile = profile(in: ctx), profile.onboardingDone else { return }
        let ws = now.weekStart
        // A plan generated last week from the weekly review: adopt its target now that the week has begun.
        // The marker stays for that week, so a plan adopted just after midnight on Monday (still the
        // previous week in 复盘) keeps showing as adopted.
        if let planned = profile.nextWeekPlannedFor, planned <= ws {
            if planned == ws, let t = profile.nextWeekTargetMinutes {
                profile.weeklyTargetMinutes = t
                profile.weeklyTargetReason = profile.nextWeekTargetReason
            }
            if planned < ws { profile.nextWeekPlannedFor = nil }
            profile.nextWeekTargetMinutes = nil
            profile.nextWeekTargetReason = ""
        }
        guard planItems(weekStart: ws, in: ctx).isEmpty else { return }

        let last = planItems(weekStart: ws.adding(days: -7), in: ctx).filter { $0.kind.isTraining }
        let completion: Double? = last.isEmpty ? nil :
            last.reduce(0.0) { $0 + ($1.status == .done ? 1 : ($1.status == .partial ? 0.5 : 0)) } / Double(last.count)
        let snap = profile.snapshot(medications: medications(in: ctx))
        let (target, reason) = PlanGenerator.nextWeeklyTarget(current: profile.weeklyTargetMinutes,
                                                               lastWeekCompletion: completion, profile: snap)
        profile.weeklyTargetMinutes = target
        profile.weeklyTargetReason = reason
        insertPlan(for: profile, weekStart: ws, fromDay: now.startOfDay, in: ctx)
    }

    /// Rebuilds the remaining days of this week after settings change; completed items are kept.
    static func regenerateWeekPlan(in ctx: ModelContext, now: Date = .app) {
        guard let profile = profile(in: ctx) else { return }
        let ws = now.weekStart
        for item in planItems(weekStart: ws, in: ctx) where item.day >= now.startOfDay && item.status == .planned {
            ctx.delete(item)
        }
        insertPlan(for: profile, weekStart: ws, fromDay: now.startOfDay, in: ctx)
    }

    static func insertPlan(for profile: UserProfile, weekStart ws: Date, fromDay: Date, in ctx: ModelContext) {
        let snap = profile.snapshot(medications: medications(in: ctx))
        let plan = PlanGenerator.generate(profile: snap, weekStart: ws)
        let existingDays = Set(planItems(weekStart: ws, in: ctx).map(\.day))
        for s in plan.sessions {
            let day = ws.adding(days: PlanGenerator.order(s.weekday))
            guard day >= fromDay, !existingDays.contains(day) else { continue }
            let item = PlanItem(day: day, weekStart: ws, kind: s.kind, title: s.title, minutes: s.minutes, intensity: s.intensity)
            item.detail = s.detail
            item.guidance = s.guidance
            item.minimumMinutes = s.minimumMinutes
            item.minimumDetail = s.minimumDetail
            item.isKey = s.isKey
            ctx.insert(item)
        }
    }

    /// Keeps the furthest stage reached on each goal's path; a stage once reached is not taken back.
    static func recordJourneys(_ paths: [GoalJourney], in ctx: ModelContext) {
        guard let profile = profile(in: ctx) else { return }
        var reached = profile.journeyReached
        for p in paths where p.keepsReached && p.current > (reached[p.id] ?? 0) { reached[p.id] = p.current }
        guard reached != profile.journeyReached else { return }
        profile.journeyReached = reached
        try? ctx.save()
    }

    /// Writes next week's plan generated from this week's review. Earlier generated items for that
    /// week are replaced; the new aerobic target takes effect when the week starts.
    static func applyNextWeekPlan(_ plan: NextWeekPlan, in ctx: ModelContext) {
        guard let profile = profile(in: ctx) else { return }
        for item in planItems(weekStart: plan.weekStart, in: ctx) where item.status == .planned { ctx.delete(item) }
        for s in plan.sessions {
            let day = plan.weekStart.adding(days: PlanGenerator.order(s.weekday))
            let item = PlanItem(day: day, weekStart: plan.weekStart, kind: s.kind, title: s.title, minutes: s.minutes, intensity: s.intensity)
            item.detail = s.detail
            item.guidance = s.guidance
            item.minimumMinutes = s.minimumMinutes
            item.minimumDetail = s.minimumDetail
            item.isKey = s.isKey
            ctx.insert(item)
        }
        profile.nextWeekPlannedFor = plan.weekStart
        profile.nextWeekTargetMinutes = plan.targetMinutes
        profile.nextWeekTargetReason = plan.targetReason
        try? ctx.save()
    }

    /// What adopting a conversational plan change replaced, so it can be undone.
    struct PlanUndo: Equatable {
        var details: [UUID: String] = [:]
        var guidance: [UUID: String] = [:]
        var trails: [UUID: Bool] = [:]
    }

    /// Writes a plan change agreed with the Health Agent. Only sessions that are still planned
    /// change; each keeps an adjustment trail so the plan shows what was changed and why.
    @discardableResult
    static func applyPlanChange(_ p: PlanChangeProposal, in ctx: ModelContext, now: Date = .app) -> PlanUndo {
        var undo = PlanUndo()
        guard let profile = profile(in: ctx) else { return undo }
        let snap = profile.snapshot(medications: medications(in: ctx))
        let items = planItems(weekStart: p.weekStart, in: ctx)
        let request = p.request.count > 40 ? String(p.request.prefix(40)) + "…" : p.request
        for s in p.after {
            let old = p.before.first { $0.id == s.id }
            if let item = items.first(where: { $0.id == s.id }) {
                guard let old, old != s, item.status == .planned else { continue }
                undo.details[item.id] = item.detail
                undo.guidance[item.id] = item.guidance
                undo.trails[item.id] = item.wasAdjusted
                if item.originalTitle == nil {
                    item.originalTitle = item.title
                    item.originalMinutes = item.minutes
                    item.originalIntensityRaw = item.intensityRaw
                    item.originalKindRaw = item.kindRaw
                }
                item.day = s.day
                item.kind = s.kind
                item.title = s.title
                item.minutes = s.minutes
                item.intensity = s.intensity
                item.isKey = s.isKey
                item.minimumMinutes = s.minimumMinutes
                item.minimumDetail = s.minimumDetail
                if let d = s.newDetail { item.detail = d }
                if old.kind != s.kind || old.intensity != s.intensity { item.guidance = PlanGenerator.guidance(s.intensity, snap) }
                let moved = old.day != s.day ? "从\(Weekday.name(old.day.weekday))移到\(Weekday.name(s.day.weekday))。" : ""
                item.adjustmentNote = AgentNameSettings.shared.phrase("\(moved)与", "对话后调整：「\(request)」")
                item.adjustedAt = now
            } else if old == nil || p.generated {
                let item = PlanItem(day: s.day, weekStart: p.weekStart, kind: s.kind, title: s.title, minutes: s.minutes, intensity: s.intensity)
                item.id = s.id
                item.detail = s.newDetail ?? ""
                item.guidance = PlanGenerator.guidance(s.intensity, snap)
                item.minimumMinutes = s.minimumMinutes
                item.minimumDetail = s.minimumDetail
                item.isKey = s.isKey
                if !p.generated {
                    item.adjustmentNote = AgentNameSettings.shared.phrase("与", "对话后添加：「\(request)」")
                    item.adjustedAt = now
                }
                ctx.insert(item)
            }
        }
        try? ctx.save()
        return undo
    }

    /// Records a condition from the conversation (记下): ticks a built-in one, otherwise keeps it with
    /// the other conditions. Returns false when it was already there, so undoing leaves it alone.
    @discardableResult
    static func recordCondition(_ x: ConditionInfo, in ctx: ModelContext) -> Bool {
        guard let p = profile(in: ctx) else { return false }
        if let n = x.native {
            guard !p.conditions.contains(n) else { return false }
            p.conditions.insert(n)
            if n == .sleepApnea { p.apneaStatus = .diagnosed }
            if n == .ckd { p.nutrientTracking = true }
        } else {
            guard !p.extraConditionsRaw.contains(x.id) else { return false }
            p.extraConditionsRaw.append(x.id)
        }
        try? ctx.save()
        return true
    }

    static func forgetCondition(_ x: ConditionInfo, in ctx: ModelContext) {
        guard let p = profile(in: ctx) else { return }
        if let n = x.native { p.conditions.remove(n) } else { p.extraConditionsRaw.removeAll { $0 == x.id } }
        try? ctx.save()
    }

    /// Puts the plan back as it was before `applyPlanChange`.
    static func revertPlanChange(_ p: PlanChangeProposal, undo: PlanUndo, in ctx: ModelContext) {
        let items = planItems(weekStart: p.weekStart, in: ctx)
        for item in items where item.status == .planned {
            guard let old = p.before.first(where: { $0.id == item.id }), !p.generated else {
                if p.after.contains(where: { $0.id == item.id }) { ctx.delete(item) }
                continue
            }
            guard undo.details[item.id] != nil else { continue }
            item.day = old.day
            item.kind = old.kind
            item.title = old.title
            item.minutes = old.minutes
            item.intensity = old.intensity
            item.isKey = old.isKey
            item.minimumMinutes = old.minimumMinutes
            item.minimumDetail = old.minimumDetail
            item.detail = undo.details[item.id] ?? item.detail
            item.guidance = undo.guidance[item.id] ?? item.guidance
            if undo.trails[item.id] != true {
                item.originalTitle = nil
                item.originalMinutes = nil
                item.originalIntensityRaw = nil
                item.originalKindRaw = nil
                item.adjustmentNote = nil
                item.adjustedAt = nil
            }
        }
        try? ctx.save()
    }

    /// Evaluates abnormal-event rules and stores new events once (需求 8).
    @discardableResult
    static func refreshAlerts(in ctx: ModelContext, now: Date = .app) -> Int {
        let a = analytics(in: ctx, now: now)
        let vitals = ((try? ctx.fetch(FetchDescriptor<VitalReading>())) ?? [])
            .filter { $0.time > now.adding(days: -14) }.map(\.point)
        let candidates = AlertEngine.evaluate(days: a.days, vitals: vitals, trend: a.trend, profile: a.profile, now: now)
        var added = 0
        for c in candidates where addEvent(c, in: ctx) != nil { added += 1 }
        return added
    }

    @discardableResult
    static func addEvent(_ c: AlertCandidate, in ctx: ModelContext) -> HealthEvent? {
        let key = c.dedupeKey
        let existing = (try? ctx.fetch(FetchDescriptor<HealthEvent>(predicate: #Predicate { $0.dedupeKey == key }))) ?? []
        guard existing.isEmpty else { return nil }
        let e = HealthEvent(kind: c.kind, severity: c.severity, title: c.title, detail: c.detail, guidance: c.guidance,
                            relatedDate: c.relatedDate, valueText: c.valueText, dedupeKey: c.dedupeKey)
        e.followUpDue = c.severity >= .consult ? c.relatedDate.adding(days: c.severity == .urgent ? 0 : 3) : nil
        ctx.insert(e)
        return e
    }

    /// Sets the baseline automatically once enough comparable mornings exist.
    static func updateBaselineIfNeeded(in ctx: ModelContext) {
        guard let profile = profile(in: ctx), profile.baselineRHR == nil else { return }
        let a = analytics(in: ctx)
        if let b = RHRTrendAnalyzer.computeBaseline(points: a.trend.points) {
            profile.baselineRHR = b.rounded(to: 0.5)
            profile.baselineSetAt = .app
            profile.baselineIsManual = false
        }
    }

    static func deleteAll(in ctx: ModelContext) {
        for type in PulseSchema.models {
            try? ctx.delete(model: type)
        }
        try? ctx.save()
    }
}
