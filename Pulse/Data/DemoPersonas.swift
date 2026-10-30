import Foundation
import SwiftData

/// Sample users for demos and testing. 晓林 is the original, well-adhering persona; the others have
/// average health and poor adherence, so the plan, review and Health Agent can be seen handling
/// skipped sessions, irregular sleep, missing data and care plans that are not followed.
enum DemoPersona: String, CaseIterable, Identifiable {
    case xiaolin, chenjie, linyue, wangjianguo
    var id: String { rawValue }
    var name: String {
        switch self {
        case .xiaolin: "晓林"
        case .chenjie: "陈杰"
        case .linyue: "林悦"
        case .wangjianguo: "王建国"
        }
    }
    var summary: String {
        switch self {
        case .xiaolin: "39 岁 · 坚持得不错，静息心率明显下降"
        case .chenjie: "45 岁 · 久坐、血压偏高、熬夜饮酒，计划常落空"
        case .linyue: "34 岁 · 倒班护士，作息混乱，记录断断续续"
        case .wangjianguo: "57 岁 · 2 型糖尿病与高血压，漏服药、运动少"
        }
    }
}

extension DemoDataGenerator {
    /// A sample user's data that stops before today's night (the demo was opened again on a later day).
    static func isStale(in ctx: ModelContext, now: Date = .app) -> Bool {
        guard let p = DataHub.profile(in: ctx), !p.demoPersona.isEmpty else { return false }
        var d = FetchDescriptor<DailyRecord>(predicate: #Predicate { $0.restingHR != nil }, sortBy: [SortDescriptor(\.day, order: .reverse)])
        d.fetchLimit = 1
        guard let last = (try? ctx.fetch(d))?.first?.day else { return true }
        // Older than today, or ahead of it (the demo clock was moved back).
        return last != DayClock.logicalToday(now)
    }

    static func populate(_ ctx: ModelContext, persona: DemoPersona, now: Date = .app) {
        switch persona {
        case .xiaolin: populate(ctx, now: now)
        case .chenjie: PersonaGenerator.populate(ctx, spec: .chenjie, now: now)
        case .linyue: PersonaGenerator.populate(ctx, spec: .linyue, now: now)
        case .wangjianguo: PersonaGenerator.populate(ctx, spec: .wangjianguo, now: now)
        }
        DataHub.profile(in: ctx)?.demoPersona = persona.rawValue
        try? ctx.save()
    }
}

// MARK: - Persona description

struct SleepNight {
    /// Minutes from the record day's midnight; negative means the previous evening.
    var start: Int
    var minutes: Double
    var nightShift = false
}

struct BPSpec {
    var sys: Double
    var dia: Double
    var sd: Double
    var everyDays: Int
    var missedMedBump: Double
    var eveningP: Double
}

struct GlucoseSpec {
    var cgmDays: Int
    var baseline: Double
    var meals: [(hour: Double, peak: Double)]
    var dawnRise: Double
    var nightLowsDaysAgo: [Int]
    var fingerstickEvery: Int
    var fastingMean: Double
}

/// Kidney disease: lab reports and a kidney-diet record for the last weeks.
struct KidneySpec {
    var labs: [(daysAgo: Int, kind: LabKind, value: Double)]
    var proteinTargetG: Int?
    var potassiumLimit: Bool
    /// Chance a day's kidney diet is recorded, and what such a day looks like.
    var loggedP: Double
    var recordDays: Int
    var saltSources: ClosedRange<Int>
    /// Portions of meat, eggs, milk and soy a day; staples and vegetables come on top.
    var proteinPortions: ClosedRange<Int>
    var potassiumFoods: ClosedRange<Int>
    var phosphorusFoods: ClosedRange<Int>
}

struct PersonaSpec {
    var nickname: String
    var age: Int
    var sex: Sex
    var heightCm: Double
    var weightKg: Double
    var neckCm: Double?
    var level: ActivityLevel
    var conditions: Set<HealthCondition> = []
    var meds: [(name: String, category: MedicationCategory, dose: String)] = []
    var modules: Set<ProModule> = []
    var goals: Set<GoalDirection>
    var goalNote: String
    var weekdays: [Int]
    var sessionMinutes: Int
    var preferredTime: PreferredTime
    var shiftWork = false
    var weeklyBudget: Int
    var startTarget: Int
    var targetRHR: Double?
    var bedtimeTarget: Int
    var wakeTarget: Int
    var sleepNeedHours: Double
    var waterTarget: Int
    var stepsTarget: Int
    var caffeineCutoff: Int
    var alcoholLimit: Double
    var stopBang: [Bool] = []
    var apnea: ApneaStatus = .unknown

    // Physiology
    var rhrStart: Double
    var rhrEnd: Double
    var rhrNoise: Double
    var hrvBase: Double
    var spo2Mean: Double
    var sleep: (_ i: Int, _ day: Date, _ weekend: Bool, _ rng: inout SeededRandom) -> SleepNight
    var rhrShift: (_ i: Int, _ day: Date) -> Double = { _, _ in 0 }

    // Behaviour
    var doneP: Double
    var partialP: Double
    /// How much motivation fades over the 120 days (0 = steady, 1 = gone by the end):
    /// completion, check-ins and steps drift down, as they often do after a keen start.
    var fade: Double = 0
    var extraSkip: (_ i: Int, _ weekday: Int) -> Double = { _, _ in 0 }
    var slumpWeeks: Set<Int> = []
    var wearP: Double
    var gaps: [ClosedRange<Int>] = []
    var checkInP: Double
    var eveningP: Double
    var alcoholWeekdayP: Double
    var alcoholWeekendP: Double
    var alcoholUnits: ClosedRange<Int>
    var cups: ClosedRange<Int>
    var lateCaffeineP: Double
    var waterMean: Double
    var lateMealP: Double
    var balancedP: Double
    var stepsMean: Double
    var stressMean: Double
    var energyMean: Double
    var snoringP: Double
    var gaspP: Double
    var sleepyP: Double
    var headacheP: Double
    var medsTakenP: Double? = nil
    var menstrual = false
    var meals: [(minute: Int, kind: MealKind, carbs: Double, note: String)]

    // Vitals and care
    var bp: BPSpec?
    var glucose: GlucoseSpec?
    var kidney: KidneySpec? = nil
    var tasks: [(title: String, area: CareArea, dueInDays: Int, done: Bool, note: String)] = []
    var reviews: [(weeksAgo: Int, summary: String, keep: String, change: String, focus: String)] = []
    var symptoms: [(daysAgo: Int, title: String, detail: String)] = []
}

// MARK: - The three low-adherence personas

extension PersonaSpec {
    /// 久坐的中年上班族：血压偏高未就诊，熬夜、周末饮酒多，打鼾明显，计划经常完不成。
    static let chenjie = PersonaSpec(
        nickname: "陈杰", age: 45, sex: .male, heightCm: 176, weightKg: 88, neckCm: 42, level: .sedentary,
        goals: [.lowerRHR, .energy], goalNote: "体检说心率偏快、血压偏高，想先把作息和运动捡起来。",
        weekdays: [2, 4, 6, 7], sessionMinutes: 40, preferredTime: .evening, weeklyBudget: 150, startTarget: 90,
        targetRHR: 68, bedtimeTarget: 23 * 60 + 30, wakeTarget: 7 * 60 + 15, sleepNeedHours: 7.5,
        waterTarget: 1800, stepsTarget: 8000, caffeineCutoff: 14, alcoholLimit: 6,
        rhrStart: 76, rhrEnd: 75, rhrNoise: 2.2, hrvBase: 28, spo2Mean: 89.8,
        sleep: { _, _, weekend, rng in
            SleepNight(start: Int(rng.normal(weekend ? 75 : 25, 50)), minutes: max(270, min(480, rng.normal(weekend ? 400 : 362, 38))))
        },
        doneP: 0.42, partialP: 0.14, fade: 0.55,
        extraSkip: { _, wd in wd == 6 || wd == 7 ? 0.2 : 0 },
        slumpWeeks: [5, 6, 12],
        wearP: 0.82, gaps: [61...66],
        checkInP: 0.35, eveningP: 0.12,
        alcoholWeekdayP: 0.25, alcoholWeekendP: 0.62, alcoholUnits: 2...6,
        cups: 2...4, lateCaffeineP: 0.6, waterMean: 1100, lateMealP: 0.4, balancedP: 0.25,
        stepsMean: 4300, stressMean: 3.5, energyMean: 2.5,
        snoringP: 0.55, gaspP: 0.07, sleepyP: 0.45, headacheP: 0.12,
        meals: [(8 * 60 + 40, .breakfast, 70, "包子、豆浆"), (12 * 60 + 40, .lunch, 105, "盖浇饭、可乐"), (20 * 60 + 50, .dinner, 95, "外卖烧烤、啤酒")],
        bp: BPSpec(sys: 139, dia: 89, sd: 5, everyDays: 5, missedMedBump: 0, eveningP: 0.2),
        tasks: [("体检复查：血压、血脂", .cardio, -26, false, "体检报告建议 1 个月内复查"),
                ("咨询睡眠门诊：打鼾", .sleep, -5, false, "")],
        reviews: [(7, "这周基本没练，加班太多。", "周一的快走", "周五、周六的训练", "先保证每周 2 次")])

    /// 倒班护士：白班、夜班、休息轮换，作息和记录都不规律，咖啡因多。
    static let linyue = PersonaSpec(
        nickname: "林悦", age: 34, sex: .female, heightCm: 163, weightKg: 57, neckCm: nil, level: .light,
        goals: [.energy, .lowerRHR], goalNote: "倒班后总觉得累，想睡得好一点、精力好一点。",
        weekdays: [3, 5, 1], sessionMinutes: 30, preferredTime: .flexible, shiftWork: true, weeklyBudget: 120, startTarget: 80,
        targetRHR: nil, bedtimeTarget: 23 * 60 + 30, wakeTarget: 7 * 60, sleepNeedHours: 7.5,
        waterTarget: 1800, stepsTarget: 8000, caffeineCutoff: 15, alcoholLimit: 3,
        rhrStart: 68, rhrEnd: 68, rhrNoise: 2.0, hrvBase: 34, spo2Mean: 93.5,
        sleep: { i, _, _, rng in
            switch i % 5 {
            case 0: return SleepNight(start: 8 * 60 + 40 + Int(rng.normal(0, 25)), minutes: rng.normal(290, 35), nightShift: true)   // after a night shift
            case 1: return SleepNight(start: 2 * 60 + Int(rng.normal(0, 50)), minutes: rng.normal(430, 45))                          // first day off
            default: return SleepNight(start: -30 + Int(rng.normal(0, 30)), minutes: rng.normal(370, 30))                             // day shifts
            }
        },
        rhrShift: { i, _ in i % 5 == 0 ? 5 : 0 },
        doneP: 0.48, partialP: 0.1, fade: 0.6,
        extraSkip: { i, _ in i % 5 == 0 || i % 5 == 4 ? 0.4 : 0 },
        slumpWeeks: [9],
        wearP: 0.85, gaps: [40...48, 88...96],
        checkInP: 0.45, eveningP: 0.1,
        alcoholWeekdayP: 0.03, alcoholWeekendP: 0.08, alcoholUnits: 1...2,
        cups: 2...5, lateCaffeineP: 0.55, waterMean: 1150, lateMealP: 0.5, balancedP: 0.3,
        stepsMean: 8200, stressMean: 3.7, energyMean: 2.6,
        snoringP: 0.05, gaspP: 0.01, sleepyP: 0.55, headacheP: 0.15, menstrual: true,
        meals: [(7 * 60 + 10, .breakfast, 45, "面包、咖啡"), (13 * 60 + 30, .lunch, 70, "医院食堂"), (21 * 60 + 40, .dinner, 60, "泡面")],
        bp: BPSpec(sys: 112, dia: 72, sd: 5, everyDays: 15, missedMedBump: 0, eveningP: 0))

    /// 2 型糖尿病合并高血压和早期糖尿病肾病：用药依从性差、很少运动，血糖波动大并偶有夜间低血糖，
    /// eGFR 缓慢下降、尿白蛋白增加，血钾偏高，口味偏咸。
    static let wangjianguo = PersonaSpec(
        nickname: "王建国", age: 57, sex: .male, heightCm: 170, weightKg: 80, neckCm: 41, level: .sedentary,
        conditions: [.diabetesT2, .hypertension, .ckd],
        meds: [("二甲双胍", .otherGlucose, "0.5 g 每日两次"), ("格列美脲", .sulfonylurea, "2 mg 每日早餐前"), ("氨氯地平", .otherAntihypertensive, "5 mg 每日一次")],
        modules: [.diabetesCare, .cardioCare],
        goals: [.careAligned, .lowerRHR], goalNote: "医生让我控制血糖血压、多走路，但总是坚持不下来。",
        weekdays: [2, 4, 6], sessionMinutes: 30, preferredTime: .morning, weeklyBudget: 120, startTarget: 75,
        targetRHR: nil, bedtimeTarget: 22 * 60 + 45, wakeTarget: 6 * 60 + 30, sleepNeedHours: 7,
        waterTarget: 1800, stepsTarget: 7000, caffeineCutoff: 15, alcoholLimit: 3,
        rhrStart: 73, rhrEnd: 72, rhrNoise: 1.8, hrvBase: 24, spo2Mean: 91,
        sleep: { _, _, _, rng in SleepNight(start: -50 + Int(rng.normal(0, 40)), minutes: max(300, rng.normal(395, 40))) },
        doneP: 0.42, partialP: 0.15, fade: 0.5,
        slumpWeeks: [3, 4, 10, 11],
        wearP: 0.75, gaps: [70...75],
        checkInP: 0.4, eveningP: 0.08,
        alcoholWeekdayP: 0.08, alcoholWeekendP: 0.3, alcoholUnits: 1...3,
        cups: 0...1, lateCaffeineP: 0.05, waterMean: 1300, lateMealP: 0.3, balancedP: 0.2,
        stepsMean: 4800, stressMean: 2.8, energyMean: 2.7,
        snoringP: 0.35, gaspP: 0.04, sleepyP: 0.35, headacheP: 0.05, medsTakenP: 0.7,
        meals: [(7 * 60 + 20, .breakfast, 80, "白粥、馒头、咸菜"), (12 * 60, .lunch, 110, "米饭、红烧肉、青菜"), (18 * 60 + 40, .dinner, 100, "面条、炒菜")],
        bp: BPSpec(sys: 142, dia: 88, sd: 6, everyDays: 3, missedMedBump: 8, eveningP: 0.15),
        glucose: GlucoseSpec(cgmDays: 14, baseline: 7.6, meals: [(7.5, 4.8), (12.2, 5.6), (18.9, 5.2)], dawnRise: 1.4,
                             nightLowsDaysAgo: [3, 8, 12], fingerstickEvery: 4, fastingMean: 8.4),
        kidney: KidneySpec(
            labs: [(520, .egfr, 63), (520, .creatinine, 116), (380, .egfr, 62), (380, .uacr, 42), (200, .egfr, 60), (200, .potassium, 4.6),
                   (200, .hba1c, 7.8), (125, .hba1c, 8.1), (100, .egfr, 58), (100, .uacr, 68), (100, .potassium, 4.9), (100, .hemoglobin, 131),
                   (12, .egfr, 57), (12, .creatinine, 127), (12, .uacr, 86), (12, .potassium, 5.4), (12, .phosphorus, 1.32),
                   (12, .hemoglobin, 127), (12, .uricAcid, 452), (12, .hba1c, 7.6)],
            proteinTargetG: 55, potassiumLimit: true, loggedP: 1.0, recordDays: 21,
            saltSources: 0...3, proteinPortions: 3...7, potassiumFoods: 0...3, phosphorusFoods: 0...2),
        // The slipped follow-up is one no lab result answers: rechecks are ticked off by the result (化验复查提醒).
        tasks: [("眼底检查", .diabetes, -18, false, "糖尿病每年一次，上次是去年秋天"),
                ("心内科复诊", .cardio, 10, false, "带上家庭血压记录"),
                ("足部检查", .diabetes, -120, true, "")],
        symptoms: [(9, "疑似低血糖（出汗、手抖）", "凌晨醒来出汗、手抖，测指尖血糖 3.6 mmol/L，吃了饼干后好转。")])
}

// MARK: - Generator

@MainActor
enum PersonaGenerator {
    static let days = 120

    /// `n` different items from `list`, in list order.
    static func pick(_ list: [String], _ n: Int, _ rng: inout SeededRandom) -> [String] {
        var chosen = Set<Int>()
        while chosen.count < min(n, list.count) { chosen.insert(rng.int(0...(list.count - 1))) }
        return chosen.sorted().map { list[$0] }
    }

    /// A keen start that fades: above 1 in the first weeks, falling to about 1 − fade by the end.
    static func motivation(_ fade: Double, _ progress: Double) -> Double {
        max(0.1, 1 + 0.35 * fade - 1.35 * fade * progress)
    }

    static func populate(_ ctx: ModelContext, spec s: PersonaSpec, now: Date = .app) {
        DataHub.deleteAll(in: ctx)
        // Deterministic per persona (Swift's String hashing is randomised per run, so derive the seed by hand).
        var rng = SeededRandom(seed: UInt64(s.nickname.unicodeScalars.reduce(0) { $0 &* 31 &+ UInt64($1.value) }))
        // Meals logged before the last four days draw from their own sequence, so the rest of the history stays as it was.
        var mealRng = SeededRandom(seed: 7_202_610)
        var dietRng = SeededRandom(seed: 5_202_410)
        let today = now.startOfDay
        let start = today.adding(days: -days)
        let inGap: (Int) -> Bool = { i in s.gaps.contains { $0.contains(i) } }

        // Profile
        let p = UserProfile()
        p.createdAt = start
        p.onboardingDone = true
        p.usesDemoData = true
        p.nickname = s.nickname
        p.birthYear = Calendar.pulse.component(.year, from: now) - s.age
        p.sex = s.sex
        p.heightCm = s.heightCm
        p.weightKg = s.weightKg
        p.neckCm = s.neckCm
        p.activityLevel = s.level
        p.weeklyExerciseMinutes = s.startTarget / 2
        p.conditions = s.conditions
        p.availableWeekdays = s.weekdays
        p.sessionMinutes = s.sessionMinutes
        p.preferredTime = s.preferredTime
        p.shiftWork = s.shiftWork
        p.goals = s.goals
        p.goalNote = s.goalNote
        p.weeklyTimeBudget = s.weeklyBudget
        p.weeklyTargetMinutes = s.startTarget
        p.rhrMethod = .device
        p.targetRHR = s.targetRHR
        p.bedtimeMinutes = s.bedtimeTarget
        p.wakeMinutes = s.wakeTarget
        p.sleepNeedHours = s.sleepNeedHours
        p.waterTargetMl = s.waterTarget
        p.stepsTarget = s.stepsTarget
        p.caffeineCutoffHour = s.caffeineCutoff
        p.weeklyAlcoholLimit = s.alcoholLimit
        p.modules = s.modules
        p.stopBangAnswers = s.stopBang
        p.apneaStatus = s.apnea
        if s.modules.contains(.cardioCare) { p.bpTargetSys = 130; p.bpTargetDia = 80 }
        ctx.insert(p)
        for m in s.meds { ctx.insert(MedicationEntry(name: m.name, category: m.category, dose: m.dose, startDate: start.adding(days: -400))) }

        // Weekly plans with poor completion; the target follows the app's own progression rule.
        var completedByDay: [Date: [(PlanItem, Double)]] = [:]
        var ws = start.weekStart
        var target = s.startTarget
        var weekIndex = 0
        while ws <= today {
            var snap = p.snapshot(medications: [])
            snap.weeklyTargetMinutes = target
            let plan = PlanGenerator.generate(profile: snap, weekStart: ws)
            var score = 0.0, count = 0
            for ps in plan.sessions {
                let day = ws.adding(days: PlanGenerator.order(ps.weekday))
                guard day >= start else { continue }
                let item = PlanItem(day: day, weekStart: ws, kind: ps.kind, title: ps.title, minutes: ps.minutes, intensity: ps.intensity)
                item.detail = ps.detail; item.guidance = ps.guidance
                item.minimumMinutes = ps.minimumMinutes; item.minimumDetail = ps.minimumDetail; item.isKey = ps.isKey
                let i = day.daysSince(start)
                if day < today && ps.kind.isTraining {
                    let slump = s.slumpWeeks.contains(weekIndex)
                    let motivation = Self.motivation(s.fade, Double(i) / Double(days))
                    let done = slump ? 0.08 : max(0, s.doneP * motivation - s.extraSkip(i, ps.weekday))
                    let partial = slump ? 0.05 : s.partialP
                    let r = rng.next()
                    if inGap(i) || r >= done + partial { item.status = .skipped }
                    else if r < done { item.status = .done; item.completedMinutes = ps.minutes }
                    else { item.status = .partial; item.completedMinutes = max(10, Int(Double(ps.minutes) * 0.5)) }
                    if item.status != .skipped { completedByDay[day, default: []].append((item, Double(item.completedMinutes ?? ps.minutes))) }
                    score += item.status == .done ? 1 : (item.status == .partial ? 0.5 : 0)
                    count += 1
                } else if day < today {
                    item.status = .done
                }
                ctx.insert(item)
            }
            if ws.adding(days: 7) > today {
                p.weeklyTargetMinutes = target
            } else {
                let next = PlanGenerator.nextWeeklyTarget(current: target, lastWeekCompletion: count > 0 ? score / Double(count) : nil, profile: snap)
                target = next.minutes
                p.weeklyTargetReason = next.reason
            }
            ws = ws.adding(days: 7)
            weekIndex += 1
        }

        // Daily physiology and behaviour
        var prevAlcohol = 0.0, prevStress = 0, prevHard = false
        var takenByDay: [Date: Bool] = [:]
        for i in 0...days {
            let day = start.adding(days: i)
            let isToday = day == today
            let progress = Double(i) / Double(days)
            let motivation = Self.motivation(s.fade, progress)
            let weekend = [1, 7].contains(day.weekday)
            if inGap(i) && !isToday {
                prevAlcohol = 0; prevHard = false
                continue
            }
            let r = DailyRecord(day: day)
            let wear = isToday || rng.chance(s.wearP)
            var tags: Set<ContextTag> = []
            let menstrualDay = s.menstrual && (i % 28) < 5
            if menstrualDay { tags.insert(.menstrual) }

            // Sleep (night ending this morning)
            let night = s.sleep(i, day, weekend, &rng)
            var sleepMin = night.minutes
            if prevAlcohol > 0 { sleepMin -= 18 }
            if prevStress >= 4 { sleepMin -= 12 }
            sleepMin -= 20 * s.fade * progress
            sleepMin = max(240, min(520, sleepMin))
            if wear {
                let sleepStart = day.adding(minutes: night.start)
                r.sleepStart = sleepStart
                r.sleepEnd = sleepStart.adding(minutes: Int(sleepMin + 22))
                r.sleepMinutes = sleepMin.rounded()
                r.deepMinutes = (sleepMin * rng.normal(0.12, 0.02)).rounded()
                r.remMinutes = (sleepMin * rng.normal(0.19, 0.03)).rounded()
                r.awakeMinutes = rng.normal(34, 9).rounded()
            }
            if sleepMin < 330 { tags.insert(.poorSleep) }

            // Resting HR & HRV
            var rhr = s.rhrStart + (s.rhrEnd - s.rhrStart) * progress + rng.normal(0, s.rhrNoise)
            rhr += 1.5 * prevAlcohol + (sleepMin < 330 ? 2.5 : 0) + (prevStress >= 4 ? 1.5 : 0) + (prevHard ? 1.5 : 0)
            rhr += s.rhrShift(i, day) + (menstrualDay ? 1.5 : 0)
            var lnHRV = log(s.hrvBase) + rng.normal(0, 0.13) - 0.07 * prevAlcohol - (sleepMin < 330 ? 0.1 : 0) - (night.nightShift ? 0.15 : 0)
            if isToday { lnHRV -= 0.02 }
            if wear {
                r.restingHR = rhr.rounded()
                r.rhrSource = .device
                r.hrv = exp(lnHRV).rounded()
                r.respiratoryRate = rng.normal(15.6, 0.7).rounded(to: 0.1)
                r.spo2Avg = rng.normal(94.6, 0.9).rounded()
                r.spo2Min = (s.spo2Mean - (prevAlcohol > 0 ? 2.2 : 0) + rng.normal(0, 1.6)).rounded()
                r.breathingDisturbances = max(1, rng.normal(prevAlcohol > 0 ? 12 : 8, 2.4)).rounded(to: 0.1)
                if i % 10 == 0 { r.vo2Max = (33 + rng.normal(0, 0.4)).rounded(to: 0.1) }
            }

            // Self-reported cues
            r.snoring = rng.chance(min(0.95, s.snoringP + (prevAlcohol > 0 ? 0.25 : 0)))
            r.gasping = rng.chance(s.gaspP)
            r.daytimeSleepy = rng.chance(s.sleepyP)
            r.morningHeadache = rng.chance(s.headacheP)

            // Morning check-in (often skipped)
            var stress = Int(rng.normal(s.stressMean + (day.weekday == 2 ? 0.4 : 0), 0.9).rounded())
            stress = max(1, min(5, stress))
            if rng.chance(s.checkInP * (0.5 + 0.5 * motivation) * 1.2) || isToday {
                r.checkInAt = day.adding(minutes: s.wakeTarget + rng.int(10...70))
                var energy = s.energyMean - 0.5 * s.fade * progress + rng.normal(0, 0.7) - (sleepMin < 330 ? 0.7 : 0) - (prevAlcohol > 2 ? 0.5 : 0)
                if night.nightShift { energy -= 0.6 }
                r.energy = max(1, min(5, Int(energy.rounded())))
                r.sleepFeel = max(1, min(5, Int((sleepMin / 100 + rng.normal(0, 0.6)).rounded())))
                r.soreness = prevHard ? rng.int(1...2) : (rng.chance(0.15) ? 1 : 0)
                r.stress = stress
            }
            let nightOver = !(isToday && (r.sleepEnd.map { now < $0 } ?? false))
            if !nightOver { r.clearUnfinishedNight() }
            if stress >= 4 && nightOver { tags.insert(.highStress) }

            // Behaviour during the day
            if !isToday {
                let alcoholP = weekend ? s.alcoholWeekendP : s.alcoholWeekdayP
                r.alcoholUnits = rng.chance(alcoholP) ? Double(rng.int(s.alcoholUnits)) : 0
                if r.alcoholUnits > 0 { tags.insert(.alcohol) }
                r.caffeineCups = rng.int(s.cups)
                if r.caffeineCups > 0 {
                    r.lastCaffeineHour = rng.chance(s.lateCaffeineP) ? rng.int(s.caffeineCutoff...(s.shiftWork ? 22 : 18)) : rng.int(8...(s.caffeineCutoff - 1))
                    if (r.lastCaffeineHour ?? 0) >= s.caffeineCutoff { tags.insert(.lateCaffeine) }
                }
                r.waterMl = max(400, Int(rng.normal(s.waterMean, 300))).roundedTo5()
                r.lateMeal = rng.chance(s.lateMealP)
                if r.lateMeal { tags.insert(.lateMeal) }
                r.dietQuality = rng.chance(s.balancedP) ? 3 : (rng.chance(0.55) ? 2 : 1)
                r.steps = max(1200, Int(rng.normal(s.stepsMean * (0.9 + 0.15 * motivation), 1700)))
            } else {
                r.caffeineCups = s.cups.lowerBound > 0 ? 1 : 0
                r.lastCaffeineHour = r.caffeineCups > 0 ? 9 : nil
                r.waterMl = 400
                r.steps = Int(Double(max(1200, Int(rng.normal(s.stepsMean, 1200)))) * min(1, Double(now.hour) / 21))
            }
            if let p = s.medsTakenP, !isToday {
                let taken = rng.chance(p)
                takenByDay[day] = taken
                if rng.chance(0.75) { r.medsTaken = taken }
            }
            r.tags = tags
            r.manualFields = []

            // Workouts from completed plan items, plus the occasional unplanned walk
            var dayMinutes = 0.0, dayHard = false
            for (item, minutes) in completedByDay[day] ?? [] {
                let type: WorkoutType = item.kind == .strength ? .strength : (item.kind == .quality ? .run : (rng.chance(0.75) ? .walk : .cycle))
                let s0 = ActivitySession(start: day.adding(minutes: 19 * 60 + rng.int(0...90)), type: type, minutes: minutes, source: .demo)
                s0.planItemID = item.id
                s0.rpe = type == .strength ? 6 : (type == .run ? 7 : 4)
                s0.avgHR = (type == .walk ? 116 : (type == .cycle ? 132 : 128) + rng.normal(0, 4)).rounded()
                if type == .walk { s0.distanceKm = (minutes / 12).rounded(to: 0.1) }
                if type == .cycle { s0.distanceKm = (minutes / 3.2).rounded(to: 0.1) }
                s0.feeling = rng.chance(0.4) ? .hard : (rng.chance(0.6) ? .ok : .good)
                if s0.isHard { dayHard = true }
                dayMinutes += minutes
                ctx.insert(s0)
            }
            if !isToday && completedByDay[day] == nil && rng.chance(0.1 * motivation) {
                let walk = ActivitySession(start: day.adding(minutes: 12 * 60 + 30), type: .walk, minutes: Double(rng.int(15...30)), source: .demo)
                walk.rpe = 3
                walk.avgHR = rng.normal(112, 4).rounded()
                dayMinutes += walk.minutes
                ctx.insert(walk)
            }
            if wear {
                r.exerciseMinutes = isToday ? (max(0, rng.normal(8, 3)) * min(1, Double(now.hour) / 20)).rounded()
                    : (dayMinutes + max(0, rng.normal(6 * motivation, 4))).rounded()
                r.activeKcal = (Double(r.steps ?? 0) * 0.04 + dayMinutes * 6).rounded()
            }
            if dayHard { r.tags = r.tags.union([.hardTraining]) }

            // Bedtime record, rarely
            if !isToday && rng.chance(s.eveningP) {
                r.eveningCheckInAt = day.adding(minutes: 23 * 60 + 10)
                r.eveningFatigue = rng.int(3...5)
                r.eveningSoreness = rng.chance(0.2) ? 1 : 0
                r.eveningStress = max(1, min(5, stress + rng.int(-1...0)))
                r.plannedBedtime = day.adding(minutes: s.bedtimeTarget + rng.int(15...75))
                r.plannedWake = day.adding(days: 1).adding(minutes: s.wakeTarget)
            }

            // Meals for the last few days (two weeks for someone wearing a CGM)
            if i >= days - (s.glucose != nil ? 14 : 4) {
                let recent = i >= days - 4
                for meal in s.meals {
                    let t = day.adding(minutes: meal.minute + (recent ? rng.int(-20...20) : mealRng.int(-20...20)))
                    guard t <= now else { continue }
                    let m = MealLog(time: t, kind: meal.kind)
                    m.carbsG = meal.carbs + Double(recent ? rng.int(-10...10) : mealRng.int(-10...10)); m.note = meal.note; m.balanced = false
                    ctx.insert(m)
                }
            }
            if let k = s.kidney, i > days - k.recordDays, isToday || dietRng.chance(k.loggedP * motivation) {
                r.nutrientsLogged = true
                r.saltSources = Self.pick(DietFoods.salt, dietRng.int(k.saltSources), &dietRng)
                // The day's protein as portions: rice and vegetables, then meat, eggs, milk and soy.
                var protein = Array(repeating: "米饭", count: dietRng.int(2...3)) + ["蔬菜", "蔬菜"]
                let sources = ["鸡蛋", "牛奶、酸奶", "瘦肉", "鱼虾", "豆腐、豆制品"]
                for _ in 0..<dietRng.int(k.proteinPortions) { protein.append(sources[dietRng.int(0...(sources.count - 1))]) }
                r.proteinFoods = DietFoods.proteinFoods.map(\.name).flatMap { name in protein.filter { $0 == name } }
                r.potassiumFoods = Self.pick(Array(DietFoods.potassium.dropLast()), dietRng.int(k.potassiumFoods), &dietRng)
                r.phosphorusFoods = Self.pick(DietFoods.phosphorus, dietRng.int(k.phosphorusFoods), &dietRng)
                // Swelling and urine over the last two weeks: mild ankle swelling now and then, some foam.
                if i > days - 14 {
                    let swollen = dietRng.chance(0.3)
                    r.edema = (swollen ? Edema.mild : Edema.none).rawValue
                    r.edemaPlaces = swollen ? ["脚踝"] : []
                    r.urineOutput = UrineAmount.usual.rawValue
                    r.foamyUrine = dietRng.chance(0.25)
                }
            }
            ctx.insert(r)
            prevAlcohol = r.alcoholUnits
            prevStress = r.stress ?? stress
            prevHard = dayHard
        }

        // Home blood pressure, measured irregularly
        if let bp = s.bp {
            for i in stride(from: days, through: 0, by: -1) where i % bp.everyDays == 0 || (i <= 10 && rng.chance(0.35)) {
                let d = today.adding(days: -i)
                guard !inGap(days - i) else { continue }
                let missed = takenByDay[d] == false
                let t = d.adding(minutes: 7 * 60 + rng.int(0...60))
                if t <= now {
                    let sys = rng.normal(bp.sys + (missed ? bp.missedMedBump : 0), bp.sd), dia = rng.normal(bp.dia + (missed ? bp.missedMedBump / 2 : 0), bp.sd * 0.7)
                    let v = VitalReading(time: t, kind: .bloodPressure, value: sys.rounded(), value2: dia.rounded(), context: .morning)
                    v.pulse = rng.normal(s.rhrStart + 4, 3).rounded()
                    if s.medsTakenP != nil { v.medsTaken = !missed }
                    ctx.insert(v)
                }
                if i >= 1 && rng.chance(bp.eveningP) {
                    let v = VitalReading(time: d.adding(minutes: 22 * 60 + rng.int(0...50)), kind: .bloodPressure,
                                         value: rng.normal(bp.sys - 6, bp.sd).rounded(), value2: rng.normal(bp.dia - 4, bp.sd * 0.7).rounded(), context: .bedtime)
                    ctx.insert(v)
                }
            }
        }

        // Glucose: fingersticks first, CGM for the last two weeks
        if let g = s.glucose {
            for i in stride(from: days, to: g.cgmDays, by: -g.fingerstickEvery) {
                let d = today.adding(days: -i)
                guard !inGap(days - i) else { continue }
                ctx.insert(VitalReading(time: d.adding(minutes: 7 * 60 + 5), kind: .glucose, value: max(4, rng.normal(g.fastingMean, 0.9)).rounded(to: 0.1), context: .fasting))
                if rng.chance(0.4) {
                    ctx.insert(VitalReading(time: d.adding(minutes: 14 * 60), kind: .glucose, value: rng.normal(g.fastingMean + 3.5, 1.4).rounded(to: 0.1), context: .postMeal))
                }
            }
            let cgmStart = today.adding(days: -g.cgmDays)
            let lowDays = Set(g.nightLowsDaysAgo.map { today.adding(days: -$0) })
            var dayOffset = 0.0, lastDay = cgmStart
            for k in 0..<((g.cgmDays + 1) * 96) {
                let t = cgmStart.addingTimeInterval(Double(k) * 900)
                guard t <= now else { break }
                if !t.isSameDay(lastDay) { dayOffset = rng.normal(0, 0.6); lastDay = t }
                let h = Double(t.minutesOfDay) / 60
                var v = g.baseline + dayOffset + rng.normal(0, 0.25)
                if h >= 4 && h < 8 { v += g.dawnRise * min(1, (h - 4) / 3) }
                for meal in g.meals {
                    let dt = h - meal.hour
                    if dt > 0 && dt < 4 { v += meal.peak * (dt / 1.0) * exp(1 - dt / 1.0) }
                }
                if lowDays.contains(t.startOfDay), h >= 1.5 && h < 4 {
                    v = min(v, 3.3 + abs(h - 2.6) * 0.9 + rng.normal(0, 0.1))
                }
                ctx.insert(VitalReading(time: t, kind: .glucose, value: max(2.9, v).rounded(to: 0.1), context: .random, source: .demo))
            }
        }

        // Follow-up that slipped, reported symptoms and a sparse review history
        for task in s.tasks {
            let t = CareTask(title: task.title, area: task.area, due: today.adding(days: task.dueInDays), note: task.note)
            if task.done { t.done = true; t.doneAt = today.adding(days: task.dueInDays) }
            ctx.insert(t)
        }
        for sym in s.symptoms {
            let date = today.adding(days: -sym.daysAgo).adding(minutes: 3 * 60 + 20)
            let e = HealthEvent(kind: .symptom, severity: .consult, title: sym.title, detail: sym.detail,
                                guidance: "按低血糖处理并复测；近期多次出现时，请尽快联系医生，评估降糖药物与运动安排。",
                                relatedDate: date, dedupeKey: "demo-symptom-\(sym.daysAgo)")
            e.createdAt = date
            ctx.insert(e)
        }
        for rv in s.reviews {
            let w0 = today.weekStart.adding(days: -7 * rv.weeksAgo)
            let e = ReviewEntry(periodStart: w0, periodEnd: w0.adding(days: 6))
            e.summary = rv.summary; e.keep = rv.keep; e.change = rv.change; e.nextFocus = rv.focus
            e.createdAt = w0.adding(days: 6)
            ctx.insert(e)
        }

        // The roster is set up only now: the history above was planned before she entered it.
        if s.shiftWork {
            // The roster behind the generated sleep (see `linyue.sleep`): day index % 5 →
            // recovery after a night, day off, two day shifts, a night shift.
            p.shiftPattern = [.off, .off, .day, .day, .night]
            p.shiftCycleStart = start
            p.dayShiftStart = 7 * 60
            p.dayShiftEnd = 15 * 60 + 30
            p.nightShiftStart = 20 * 60
            p.nightShiftEnd = 8 * 60
            try? ctx.save()
            // The rest of this week is planned around the roster.
            DataHub.regenerateWeekPlan(in: ctx, now: now)
        }
        if let k = s.kidney {
            p.nutrientTracking = true
            p.proteinTargetG = k.proteinTargetG
            p.potassiumLimit = k.potassiumLimit
            for l in k.labs where l.daysAgo >= 0 {
                ctx.insert(LabResult(date: today.adding(days: -l.daysAgo).adding(minutes: 8 * 60), kind: l.kind, value: l.value))
            }
        }
        try? ctx.save()
        DataHub.updateBaselineIfNeeded(in: ctx)
        p.baselineSetAt = start.adding(days: 14)
        DataHub.refreshAlerts(in: ctx, now: now)
        try? ctx.save()
    }
}
