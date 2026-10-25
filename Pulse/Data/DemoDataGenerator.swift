import Foundation
import SwiftData

/// Deterministic random numbers so the demo looks the same on every install.
struct SeededRandom {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> Double {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        z ^= z >> 31
        return Double(z >> 11) / Double(1 << 53)
    }
    mutating func chance(_ p: Double) -> Bool { next() < p }
    mutating func normal(_ mean: Double, _ sd: Double) -> Double {
        let u1 = max(next(), 1e-9), u2 = next()
        return mean + sd * (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
    }
    mutating func int(_ range: ClosedRange<Int>) -> Int {
        range.lowerBound + Int(next() * Double(range.count)) % range.count
    }
}

/// Builds a 120-day example history for a 39-year-old office worker who wants a lower resting
/// heart rate, more energy and a first marathon next spring.
extension DailyRecord {
    /// Sample data opened before this night has ended: there is no sleep, overnight data or
    /// morning check-in yet (real data can't come from the future either).
    func clearUnfinishedNight() {
        restingHR = nil; rhrSourceRaw = nil; hrv = nil; respiratoryRate = nil
        spo2Avg = nil; spo2Min = nil; breathingDisturbances = nil; vo2Max = nil
        sleepStart = nil; sleepEnd = nil; sleepMinutes = nil; deepMinutes = nil; remMinutes = nil; awakeMinutes = nil
        checkInAt = nil; energy = nil; sleepFeel = nil; soreness = nil; sorenessAreaRaw = nil; stress = nil; illnessSymptoms = false
        snoring = false; gasping = false; witnessedApnea = false; morningHeadache = false; daytimeSleepy = false; cpapHours = nil
        medsTaken = nil
    }
}

@MainActor
enum DemoDataGenerator {
    static let days = 120

    static func populate(_ ctx: ModelContext, now: Date = .app) {
        DataHub.deleteAll(in: ctx)
        var rng = SeededRandom(seed: 20261021)
        // Meal portions draw from their own sequence, so the rest of the history stays as it was.
        var mealRng = SeededRandom(seed: 7_202_611)
        let today = now.startOfDay
        let start = today.adding(days: -days)

        // Profile
        let p = UserProfile()
        p.createdAt = start
        p.onboardingDone = true
        p.usesDemoData = true
        p.nickname = "晓林"
        p.birthYear = Calendar.pulse.component(.year, from: now) - 39
        p.sex = .male
        p.heightCm = 175
        p.weightKg = 77
        p.neckCm = 39.5
        p.activityLevel = .light
        p.weeklyExerciseMinutes = 60
        p.availableWeekdays = [3, 5, 7, 1]
        p.sessionMinutes = 45
        p.preferredTime = .evening
        p.goals = [.lowerRHR, .energy, .fitness]
        p.goalNote = "静息心率回到 65 左右，白天不犯困；明年春天完成第一个全程马拉松。"
        p.weeklyTimeBudget = 240
        p.weeklyTargetMinutes = 80
        p.rhrMethod = .device
        p.targetRHR = 65
        p.bedtimeMinutes = 23 * 60 + 15
        p.wakeMinutes = 7 * 60
        p.waterTargetMl = 2000
        p.apneaStatus = .suspected
        p.stopBangAnswers = [true, false, false, false, false, false, false, true]
        p.stopBangDate = today.adding(days: -20)
        p.raceName = "无锡马拉松"
        p.raceDate = Calendar.pulse.date(from: DateComponents(year: Calendar.pulse.component(.year, from: now) + 1, month: 3, day: 21))
        p.raceTargetMinutes = 270
        p.currentWeeklyKm = 18
        p.longestRecentRunKm = 12
        ctx.insert(p)

        let med = MedicationEntry(name: "氯雷他定", category: .other, dose: "10 mg 每日一次（季节性过敏）", startDate: today.adding(days: -30))
        med.endDate = today.adding(days: 10)
        ctx.insert(med)

        // Plans first, so workouts can follow them.
        var completedByDay: [Date: [(PlanItem, Double)]] = [:]
        var ws = start.weekStart
        while ws <= today {
            // The persona progressed steadily from ~80 to ~170 minutes per week.
            let weekProgress = Double(ws.daysSince(start)) / Double(days)
            let weeklyTarget = min(170, Int(80 + 95 * weekProgress).roundedTo5())
            var snap = p.snapshot(medications: [])
            snap.weeklyTargetMinutes = weeklyTarget
            let plan = PlanGenerator.generate(profile: snap, weekStart: ws)
            for s in plan.sessions {
                let day = ws.adding(days: PlanGenerator.order(s.weekday))
                guard day >= start else { continue }
                let item = PlanItem(day: day, weekStart: ws, kind: s.kind, title: s.title, minutes: s.minutes, intensity: s.intensity)
                item.detail = s.detail; item.guidance = s.guidance
                item.minimumMinutes = s.minimumMinutes; item.minimumDetail = s.minimumDetail; item.isKey = s.isKey
                if day < today && s.kind.isTraining {
                    // Thursdays are hard for this persona (late meetings): a plan-fit signal for review.
                    let skipP = s.weekday == 5 ? 0.5 : 0.07
                    let r = rng.next()
                    if r < skipP { item.status = .skipped }
                    else if r < skipP + 0.08 { item.status = .partial; item.completedMinutes = Int(Double(s.minutes) * 0.6) }
                    else { item.status = .done; item.completedMinutes = s.minutes }
                    if item.status != .skipped {
                        completedByDay[day, default: []].append((item, Double(item.completedMinutes ?? s.minutes)))
                    }
                } else if day < today {
                    item.status = .done
                }
                ctx.insert(item)
            }
            if ws.adding(days: 7) > today { p.weeklyTargetMinutes = weeklyTarget }
            ws = ws.adding(days: 7)
        }
        p.weeklyTargetReason = "上周完成良好，本周有氧目标小幅增加约 10%。"

        // Daily physiology & behaviour
        var prevAlcohol = 0.0, prevStress = 0, prevHard = false
        for i in 0...days {
            let day = start.adding(days: i)
            let progress = Double(i) / Double(days)            // 0 → 1
            let improve = min(1, max(0, (progress - 0.12) / 0.75))
            let r = DailyRecord(day: day)
            let isToday = day == today

            // Illness and travel episodes
            let illIdx = i - (days - 52)
            let ill = (0...4).contains(illIdx)
            let travel = (days - 75...days - 73).contains(i)
            let experiment = i >= days - 10   // two-week alcohol-free self experiment

            // Sleep (night ending this morning)
            let weekend = [1, 7].contains(day.weekday)
            let bedMean = 23.0 * 60 + 40 - 30 * improve + (weekend ? 25 : 0)
            let bed = Int(rng.normal(bedMean, 40 - 15 * improve))
            var sleepMin = rng.normal(385 + 45 * improve, 32)
            if prevAlcohol > 0 { sleepMin -= 20 }
            if prevStress >= 4 { sleepMin -= 15 }
            if ill { sleepMin += 30 }
            sleepMin = max(270, min(520, sleepMin))
            let sleepStart = day.adding(days: -1).adding(minutes: bed)
            r.sleepStart = sleepStart
            r.sleepEnd = sleepStart.adding(minutes: Int(sleepMin + 20))
            r.sleepMinutes = sleepMin.rounded()
            r.deepMinutes = (sleepMin * rng.normal(0.15, 0.02)).rounded()
            r.remMinutes = (sleepMin * rng.normal(0.22, 0.03)).rounded()
            r.awakeMinutes = rng.normal(22, 6).rounded()

            // Resting HR & HRV
            var rhr = 72.5 - 6.5 * improve + rng.normal(0, 1.7)
            if prevAlcohol > 0 { rhr += 1.4 * prevAlcohol }
            if sleepMin < 360 { rhr += 2 }
            if prevStress >= 4 { rhr += 1.5 }
            if prevHard { rhr += 1.8 }
            if ill { rhr += [6.5, 9, 8, 5, 2.5][illIdx] }
            if travel { rhr += 3 }
            if isToday { rhr += 0.5 }
            r.restingHR = rhr.rounded()
            r.rhrSource = .device
            var lnHRV = log(37 + 9 * improve) + rng.normal(0, 0.11)
            if prevAlcohol > 0 { lnHRV -= 0.08 * prevAlcohol }
            if ill { lnHRV -= 0.3 }
            if sleepMin < 360 { lnHRV -= 0.08 }
            r.hrv = exp(lnHRV).rounded()
            r.respiratoryRate = rng.normal(14.8, 0.6).rounded(to: 0.1)
            r.spo2Avg = rng.normal(95.5, 0.8).rounded()
            r.spo2Min = (prevAlcohol > 0 ? rng.normal(88.5, 1.5) : rng.normal(91, 1.4)).rounded()
            r.breathingDisturbances = max(1, rng.normal(prevAlcohol > 0 ? 9 : 6, 1.8)).rounded(to: 0.1)
            if i % 7 == 0 { r.vo2Max = (38 + 3.2 * improve + rng.normal(0, 0.3)).rounded(to: 0.1) }

            // Sleep breathing cues
            r.snoring = rng.chance(prevAlcohol > 0 ? 0.7 : 0.22)
            r.gasping = rng.chance(0.04)
            r.daytimeSleepy = rng.chance(0.25 - 0.12 * improve)
            r.morningHeadache = rng.chance(0.05)

            // Morning check-in
            if rng.chance(0.82) || isToday {
                r.checkInAt = day.adding(minutes: 7 * 60 + 20)
                var energy = 2.9 + 1.0 * improve + rng.normal(0, 0.6)
                if sleepMin < 360 { energy -= 0.7 }
                if ill { energy -= 1.5 }
                r.energy = max(1, min(5, Int(energy.rounded())))
                r.sleepFeel = max(1, min(5, Int((sleepMin / 95 + rng.normal(0, 0.5)).rounded())))
                r.soreness = prevHard ? rng.int(1...2) : (rng.chance(0.2) ? 1 : 0)
                r.stress = max(1, min(5, Int(rng.normal(day.weekday == 2 ? 3.4 : 2.7, 0.8).rounded())))
                r.illnessSymptoms = ill && illIdx <= 3
            }
            if isToday, let end = r.sleepEnd, now < end { r.clearUnfinishedNight() }
            var tags: Set<ContextTag> = []
            if ill { tags.insert(.illness) }
            if travel { tags.insert(.travel) }
            if (r.stress ?? 0) >= 4 { tags.insert(.highStress) }
            if sleepMin < 340 { tags.insert(.poorSleep) }

            // Behaviours during the day (not yet complete for today)
            if !isToday {
                let alcoholP = experiment ? 0 : (weekend ? 0.42 : 0.12) - 0.12 * improve
                r.alcoholUnits = rng.chance(max(0.03, alcoholP)) ? Double(rng.int(1...4)) : 0
                if r.alcoholUnits > 0 { tags.insert(.alcohol) }
                r.caffeineCups = rng.int(1...3)
                r.lastCaffeineHour = rng.chance(0.35 - 0.2 * improve) ? rng.int(14...17) : rng.int(9...13)
                if (r.lastCaffeineHour ?? 0) >= p.caffeineCutoffHour { tags.insert(.lateCaffeine) }
                r.waterMl = Int(rng.normal(1500 + 400 * improve, 300)).roundedTo5()
                r.lateMeal = rng.chance(0.18 - 0.08 * improve)
                if r.lateMeal { tags.insert(.lateMeal) }
                r.dietQuality = rng.chance(0.5 + 0.3 * improve) ? 3 : (rng.chance(0.7) ? 2 : 1)
                r.steps = max(1500, Int(rng.normal(5600 + 2900 * improve, 1800)))
            } else {
                r.caffeineCups = 1
                r.lastCaffeineHour = 9
                r.waterMl = 500
                r.steps = Int(Double(max(1500, Int(rng.normal(8000, 1500)))) * min(1, Double(now.hour) / 21))
            }
            r.tags = tags
            r.manualFields = []

            // Workouts from completed plan items
            var dayMinutes = 0.0, dayHard = false
            for (item, minutes) in completedByDay[day] ?? [] {
                let type: WorkoutType
                switch item.kind {
                case .strength: type = .strength
                case .quality: type = .run
                case .long: type = improve > 0.4 ? .run : .walk
                default: type = improve > 0.3 && rng.chance(0.6) ? .run : (rng.chance(0.3) ? .cycle : .walk)
                }
                let startTime = day.adding(minutes: 19 * 60 + rng.int(0...40))
                let s = ActivitySession(start: startTime, type: type, minutes: minutes, source: .demo)
                s.planItemID = item.id
                switch type {
                case .run:
                    s.rpe = item.kind == .quality ? 8 : 4
                    s.avgHR = (item.kind == .quality ? 158 : 141 - 10 * improve + rng.normal(0, 3)).rounded()
                    s.distanceKm = (minutes / (7.2 - 0.6 * improve)).rounded(to: 0.1)
                case .walk:
                    s.rpe = 3
                    s.avgHR = (112 - 5 * improve + rng.normal(0, 3)).rounded()
                    s.distanceKm = (minutes / 11).rounded(to: 0.1)
                case .cycle:
                    s.rpe = 4
                    s.avgHR = (128 - 7 * improve + rng.normal(0, 3)).rounded()
                    s.distanceKm = (minutes / 3).rounded(to: 0.1)
                default:
                    s.rpe = 6
                    s.avgHR = (118 + rng.normal(0, 4)).rounded()
                }
                s.feeling = item.kind == .quality ? .hard : (rng.chance(0.65) ? .good : .great)
                if s.isHard { dayHard = true }
                dayMinutes += minutes
                ctx.insert(s)
                item.adjustmentNote = nil
            }
            if !isToday {
                r.exerciseMinutes = (dayMinutes + max(0, rng.normal(12, 6))).rounded()
                r.activeKcal = (Double(r.steps ?? 0) * 0.04 + dayMinutes * 6).rounded()
            } else {
                r.exerciseMinutes = (max(0, rng.normal(14, 4)) * min(1, Double(now.hour) / 20)).rounded()
            }
            if dayHard { r.tags = r.tags.union([.hardTraining]) }

            // Bedtime record on most past evenings
            if !isToday && rng.chance(0.7) {
                r.eveningCheckInAt = day.adding(minutes: 22 * 60 + 40)
                r.eveningFatigue = dayHard ? 4 : rng.int(2...3)
                r.eveningSoreness = dayHard ? 2 : (rng.chance(0.3) ? 1 : 0)
                r.eveningStress = max(1, min(5, (r.stress ?? 3) + rng.int(-1...1) - 1))
                r.plannedBedtime = day.adding(minutes: p.bedtimeMinutes + rng.int(-15...30))
                r.plannedWake = day.adding(days: 1).adding(minutes: p.wakeMinutes)
                r.reviewedAt = rng.chance(0.6) ? day.adding(minutes: 22 * 60 + 45) : nil
            }

            // Meals over the two weeks of CGM, at the times the sensor shows them
            if i >= days - 14 {
                for (minute, kind, carbs, note) in [(7 * 60 + 30, MealKind.breakfast, 55.0, "燕麦、鸡蛋、牛奶"),
                                                    (12 * 60 + 30, .lunch, 75.0, "米饭、清蒸鱼、青菜"),
                                                    (19 * 60, .dinner, 65.0, "杂粮饭、鸡胸肉、豆腐汤")] {
                    let t = day.adding(minutes: minute)
                    guard t <= now else { continue }
                    let m = MealLog(time: t, kind: kind)
                    // Saturday dinner is the bigger one the CGM shows.
                    let big = kind == .dinner && day.weekday == 7
                    m.carbsG = big ? 100 : carbs + Double(mealRng.int(-8...8)); m.note = big ? "聚餐：烧烤、炒饭、啤酒" : note; m.balanced = !big
                    ctx.insert(m)
                }
            }
            ctx.insert(r)

            prevAlcohol = r.alcoholUnits
            prevStress = r.stress ?? 2
            prevHard = dayHard
        }

        // Home blood pressure: mornings every 3 days for 60 days, then morning + bedtime daily
        // for the last 2 weeks so the overnight trend is visible.
        for i in stride(from: 60, through: 0, by: -1) {
            let d = today.adding(days: -i)
            let improve = Double(60 - i) / 60
            let daily = i <= 14
            guard daily || i % 3 == 0 else { continue }
            let morningT = d.adding(minutes: 7 * 60 + 25)
            if morningT <= now {
                let sys = rng.normal(137 - 7 * improve, 4), dia = rng.normal(87 - 4 * improve, 3)
                let v = VitalReading(time: morningT, kind: .bloodPressure, value: sys.rounded(), value2: dia.rounded(), context: .morning)
                v.pulse = rng.normal(70 - 4 * improve, 3).rounded()
                v.medsTaken = false
                ctx.insert(v)
            }
            if daily && i >= 1 {
                let sys = rng.normal(126 - 5 * improve, 4), dia = rng.normal(80 - 3 * improve, 3)
                let v = VitalReading(time: d.adding(minutes: 22 * 60 + 30), kind: .bloodPressure, value: sys.rounded(), value2: dia.rounded(), context: .bedtime)
                v.medsTaken = false
                ctx.insert(v)
            }
        }
        let high = VitalReading(time: today.adding(days: -41).adding(minutes: 21 * 60), kind: .bloodPressure, value: 146, value2: 93, context: .random)
        high.note = "加班后测量"
        ctx.insert(high)

        // Two weeks of CGM data (metabolic insight sensor)
        let meals: [(Double, Double)] = [(7.5, 2.6), (12.5, 3.0), (19.0, 3.3)]
        for i in 0..<15 * 96 {
            let t = today.adding(days: -14).addingTimeInterval(Double(i) * 900)
            guard t <= now else { break }
            let h = Double(t.minutesOfDay) / 60
            var g = 5.0 + 0.25 * sin(h / 24 * 2 * .pi) + rng.normal(0, 0.18)
            for (mealH, peak) in meals {
                let dt = h - mealH
                if dt > 0 && dt < 3.5 { g += peak * (dt / 0.75) * exp(1 - dt / 0.75) * (t.weekday == 7 && mealH == 19 ? 1.5 : 1) }
            }
            if [3, 5, 7].contains(t.weekday) && h > 19.7 && h < 21 { g -= 0.6 }
            ctx.insert(VitalReading(time: t, kind: .glucose, value: max(3.6, g).rounded(to: 0.1), context: .random, source: .demo))
        }

        // A past lactate test under professional supervision
        for (stage, lac) in [1.2, 1.6, 2.3, 3.8].enumerated() {
            let v = VitalReading(time: today.adding(days: -35).adding(minutes: 9 * 60 + stage * 5), kind: .lactate, value: lac, context: .duringExercise)
            v.note = "递增测试第 \(stage + 1) 级 · 配速 \(["7:30", "7:00", "6:30", "6:00"][stage])/km · 心率 \([138, 148, 157, 168][stage])"
            v.pulse = Double([138, 148, 157, 168][stage])
            ctx.insert(v)
        }

        // A resolved event with its follow-up trail
        let e = HealthEvent(kind: .bpHigh, severity: .consult, title: "血压高于 140/90",
                            detail: "加班后测得 146/93 mmHg。", guidance: "安静休息 5 分钟后复测；持续偏高请咨询医生。",
                            relatedDate: high.time, valueText: "146/93", dedupeKey: "demo-bp")
        e.createdAt = high.time
        e.followUpLog = ["复测 134/86，休息后下降", "社区医院咨询：家庭血压继续监测，3 个月后复查"]
        e.status = .resolved
        e.resolvedAt = high.time.adding(days: 6)
        ctx.insert(e)

        ctx.insert(CareTask(title: "社区医院复查血压", area: .cardio, due: today.adding(days: 45), note: "带上家庭血压记录"))
        ctx.insert(CareTask(title: "咨询睡眠门诊：打鼾与白天困倦", area: .sleep, due: today.adding(days: 21), note: "可导出「就诊摘要」带给医生"))
        let doneTask = CareTask(title: "年度体检", area: .general, due: today.adding(days: -50))
        doneTask.done = true; doneTask.doneAt = today.adding(days: -50)
        ctx.insert(doneTask)

        // Saved reviews and an ongoing self-experiment
        let r1 = ReviewEntry(periodStart: today.adding(days: -21).weekStart, periodEnd: today.adding(days: -15).weekStart)
        r1.summary = "完成 3/4 次训练，周四又没练成。"
        r1.keep = "周六长时间快走，和家人一起很容易坚持"
        r1.change = "周四改成 20 分钟精简版"
        r1.nextFocus = "工作日 23:15 前上床"
        ctx.insert(r1)
        let r2 = ReviewEntry(periodStart: today.adding(days: -14).weekStart, periodEnd: today.adding(days: -8).weekStart)
        r2.summary = "睡眠明显规律了，精力更好。"
        r2.keep = "下午 2 点后不喝咖啡"
        r2.change = "试试两周不喝酒，看次日心率"
        r2.nextFocus = "完成个人验证：饮酒与次日静息心率"
        ctx.insert(r2)
        let ins = InsightRecord(key: "alcohol-rhr", status: .testing)
        ins.experimentStart = today.adding(days: -10)
        ins.experimentEnd = today.adding(days: 4)
        ins.note = "两周不饮酒，观察次日静息心率与睡眠"
        ctx.insert(ins)

        try? ctx.save()
        DataHub.updateBaselineIfNeeded(in: ctx)
        p.baselineSetAt = start.adding(days: 14)
        // 专项运动 for next spring's marathon, turned on four weeks ago: the history keeps the plans she
        // followed, this week on follows the marathon plan — as turning it on in 「我的」 does.
        p.setModule(.marathon, enabled: true)
        p.marathonStart = today.adding(days: -28)
        p.goals.insert(.event)
        DataHub.regenerateWeekPlan(in: ctx, now: now)
        DataHub.refreshAlerts(in: ctx, now: now)
        try? ctx.save()
    }
}
