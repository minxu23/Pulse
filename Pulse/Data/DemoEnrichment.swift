import Foundation
import SwiftData

/// Adds what the baseline report reads to a sample user's history once it is generated: steps by the
/// hour and stand hours for the last 4 weeks, walking heart rate, minute-by-minute heart rate and
/// recovery for recent sessions, body fat on weigh-in days, and the sports they like.
///
/// It runs after the generators and draws from its own sequence, so every value the generators made
/// (and the tests that pin each sample user's character) stays exactly as it was.
@MainActor
enum DemoEnrichment {
    static func enrich(_ ctx: ModelContext, persona: String, now: Date = .app) {
        guard let p = DataHub.profile(in: ctx) else { return }
        var rng = SeededRandom(seed: seed(persona))
        let records = (try? ctx.fetch(FetchDescriptor<DailyRecord>(sortBy: [SortDescriptor(\.day)]))) ?? []
        let sessions = (try? ctx.fetch(FetchDescriptor<ActivitySession>(sortBy: [SortDescriptor(\.start)]))) ?? []
        let weights = ((try? ctx.fetch(FetchDescriptor<VitalReading>())) ?? []).filter { $0.kind == .weight }
        let today = now.startOfDay
        let age = Double(p.age ?? 40)   // sample users always have a birth year
        let hrMax = 208 - 0.7 * age
        let sessionsByDay = Dictionary(grouping: sessions, by: \.day)

        for r in records where r.day >= today.adding(days: -60) {
            if let rhr = r.restingHR, (r.steps ?? 0) > 0 { r.walkingHR = (rhr + 27 + rng.normal(0, 2.5)).rounded() }
            guard r.day >= today.adding(days: -28), let steps = r.steps, steps > 0 else { continue }
            let lastHour = r.day == today ? max(0, min(23, now.hour)) : 23
            r.stepsByHour = hourly(steps: steps, day: r.day, lastHour: lastHour, profile: p,
                                   sessions: sessionsByDay[r.day] ?? [], rng: &rng)
            r.standHours = min(lastHour + 1, r.stepsByHour.filter { $0 >= 150 }.count + rng.int(0...2))
        }

        // How fit the heart is, for recovery: lower resting heart rate, faster recovery.
        let recentRHR = Stats.mean(records.suffix(14).compactMap(\.restingHR)) ?? 65
        var recoveryByDay: [Date: [Double]] = [:]
        for s in sessions where s.start >= today.adding(days: -28) && s.start <= now {
            guard let avg = s.avgHR, s.minutes >= 5 else { continue }
            s.hrSeries = series(minutes: Int(s.minutes), avg: avg, rest: recentRHR, type: s.type, hard: s.isHard, rng: &rng)
            if avg >= 0.6 * hrMax {
                let r = (30 - 0.4 * (recentRHR - 60) - 0.1 * (age - 40) + rng.normal(0, 3)).rounded()
                s.hrRecovery = min(48, max(9, r))
                recoveryByDay[s.day, default: []].append(s.hrRecovery!)
            }
        }
        for r in records { if let list = recoveryByDay[r.day] { r.hrRecovery = Stats.mean(list)?.rounded() } }

        // A smart scale writes body fat with each weight (estimated from BMI, age and sex).
        let byDay = Dictionary(records.map { ($0.day, $0) }, uniquingKeysWith: { a, _ in a })
        let male = p.sex == .male ? 1.0 : 0
        for w in weights.sorted(by: { $0.time < $1.time }) {
            guard let r = byDay[w.time.startOfDay] else { continue }
            let bmi = w.value / pow(p.heightCm / 100, 2)
            let fat = (1.2 * bmi + 0.23 * age - 10.8 * male - 5.4 + rng.normal(0, 0.6)).rounded(to: 0.1)
            r.bodyFatPct = min(55, max(5, fat))
            r.leanMassKg = (w.value * (1 - r.bodyFatPct! / 100)).rounded(to: 0.1)
        }

        // The sports they like: what they did most in the last 8 weeks, walking aside.
        if p.favoriteSportsRaw.isEmpty {
            let recent = sessions.filter { $0.start >= today.adding(days: -56) && $0.type != .walk && $0.type != .other }
            let counts = Dictionary(grouping: recent, by: \.type).mapValues(\.count)
            p.favoriteSports = counts.filter { $0.value >= 4 }.sorted { $0.value > $1.value }.prefix(2)
                .map { SportPreference(type: $0.key, level: .regular) }
        }
        // Every sample user wears a CGM: fill the last 8 weeks where the generator left no sensor readings.
        addCGM(ctx, persona: persona, profile: p, records: records, sessions: sessions, now: now)

        if p.hasBPMonitor == nil,
           ((try? ctx.fetch(FetchDescriptor<VitalReading>())) ?? []).contains(where: { $0.kind == .bloodPressure }) {
            p.hasBPMonitor = true
        }
    }

    /// The day's steps spread over waking hours: commute and lunch on workdays, the hour of a walk or run.
    static func hourly(steps: Int, day: Date, lastHour: Int, profile p: UserProfile, sessions: [ActivitySession],
                       rng: inout SeededRandom) -> [Int] {
        let wake = max(5, min(10, p.wakeMinutes / 60))
        let bed = max(wake + 12, min(24, (p.bedtimeMinutes < 12 * 60 ? 24 : p.bedtimeMinutes / 60)))
        let weekday = Calendar.pulse.component(.weekday, from: day)
        let workday = weekday != 1 && weekday != 7
        var weight = [Double](repeating: 0, count: 24)
        for h in wake..<min(24, bed) where h <= lastHour {
            var w = 1.0
            if workday && (h == wake + 1 || h == 18) { w = 3 }
            if h == 12 { w = workday ? 2.2 : 1.4 }
            if !workday && (10...17).contains(h) { w = 1.6 }
            if h == 19 || h == 20 { w = max(w, 1.4) }
            weight[h] = w * (0.75 + 0.5 * rng.next())
        }
        var out = [Int](repeating: 0, count: 24)
        var left = steps
        // A walk or run puts its own steps in its hour.
        for s in sessions where [.walk, .run].contains(s.type) {
            let h = s.start.hour
            guard h <= lastHour else { continue }
            let own = min(Int(Double(left) * 0.7), Int(s.minutes * (s.type == .run ? 160 : 110)))
            out[h] += own
            left -= own
        }
        let total = weight.reduce(0, +)
        guard total > 0 else { out[min(lastHour, 12)] += left; return out }
        var given = 0
        for h in 0..<24 where weight[h] > 0 {
            let n = Int((Double(left) * weight[h] / total).rounded(.down))
            out[h] += n
            given += n
        }
        if let busiest = (0..<24).max(by: { weight[$0] < weight[$1] }) { out[busiest] += left - given }
        return out
    }

    /// Minute-by-minute heart rate whose mean is the session's: a warm-up, then steady work, intervals, or the
    /// rise and fall of rallies in a ball game, and an easy last few minutes.
    static func series(minutes n: Int, avg: Double, rest: Double, type: WorkoutType, hard: Bool, rng: inout SeededRandom) -> [Int] {
        guard n > 0 else { return [] }
        let warm = min(6, max(1, n / 6))
        var raw: [Double] = []
        for i in 0..<n {
            var v: Double
            if i < warm {
                v = rest + 25 + (avg - rest - 25) * Double(i + 1) / Double(warm)
            } else if type.isBallGame {
                v = avg + 10 * sin(Double(i) / 2.3) + rng.normal(0, 5)
            } else if hard || type == .hiit {
                v = avg + ((i - warm) % 7 < 4 ? 11 : -12) + rng.normal(0, 2.5)
            } else {
                v = avg + rng.normal(0, 3) + Double(i - warm) * 0.05
            }
            if i >= n - 3 && n > 10 { v -= Double(i - (n - 4)) * 6 }
            raw.append(v)
        }
        let shift = avg - raw.reduce(0, +) / Double(n)
        return raw.map { Int(($0 + shift).rounded()) }
    }

    // MARK: CGM

    /// How a sample user's glucose curve looks: a level, the rise after each meal, the early-morning rise.
    struct CGMShape {
        var baseline: Double
        var meals: [(hour: Double, peak: Double)]
        var dawn: Double
        var variability: Double
        var exerciseDrop: Double
        /// Minutes to each meal's peak (healthy people peak sooner).
        var peakHours: Double
        var floor: Double
        var ceiling: Double
    }

    static let cgmDays = 56

    static func cgmShape(persona: String, profile p: UserProfile) -> CGMShape {
        let spec = DemoPersona(rawValue: persona)?.spec
        // Users the generator already gives a sensor: the same curve, without the one-off night lows.
        if let g = spec?.glucose {
            return CGMShape(baseline: g.baseline, meals: g.meals.map { ($0.hour, $0.peak) }, dawn: g.dawnRise, variability: g.variability,
                            exerciseDrop: max(g.exerciseDrop, 0.6), peakHours: 1.0, floor: 3.6, ceiling: 16)
        }
        if spec == nil {   // 晓林: his two weeks of "metabolic insight" sensor
            return CGMShape(baseline: 5.0, meals: [(7.5, 2.6), (12.5, 3.0), (19.0, 3.3)], dawn: 0.2, variability: 0.2,
                            exerciseDrop: 0.6, peakHours: 0.75, floor: 4.0, ceiling: 11.5)
        }
        // Without diabetes: the meals the user logs, higher rises with more weight, more years and less movement.
        let bmi = p.bmi
        let age = Double(p.age ?? 40)   // sample users always have a birth year
        var k = 0.032 + (bmi >= 28 ? 0.016 : bmi >= 24 ? 0.008 : 0) + (age >= 60 ? 0.005 : 0)
        if p.activityLevel == .sedentary { k += 0.004 }
        let meals = (spec?.meals ?? []).map { (hour: Double($0.minute) / 60, peak: min(4.6, $0.carbs * k)) }
        let baseline = min(5.9, max(4.7, 4.9 + (bmi - 22) * 0.05 + (age - 40) * 0.008))
        let apnea = p.conditions.contains(.sleepApnea) || bmi >= 28
        return CGMShape(baseline: baseline, meals: meals, dawn: apnea ? 0.6 : 0.3, variability: 0.25,
                        exerciseDrop: 0.5, peakHours: 0.8, floor: 4.0, ceiling: 11.5)
    }

    /// 15-minute readings for the last 8 weeks wherever there is no sensor reading yet (a two-hour gap at each
    /// sensor change). A late dinner comes later and rises more; a walk or workout soon after a meal blunts its rise.
    static func addCGM(_ ctx: ModelContext, persona: String, profile p: UserProfile, records: [DailyRecord], sessions: [ActivitySession], now: Date) {
        let shape = cgmShape(persona: persona, profile: p)
        var rng = SeededRandom(seed: seed("cgm-" + persona))
        let firstDay = records.first?.day ?? now.startOfDay
        let start = max(firstDay, now.startOfDay.adding(days: -cgmDays))
        let existing = Set(((try? ctx.fetch(FetchDescriptor<VitalReading>())) ?? [])
            .filter { $0.kind == .glucose && $0.context == .random }
            .map { Int($0.time.timeIntervalSinceReferenceDate / 900) })
        let lateMeal = Set(records.filter(\.lateMeal).map(\.day))
        let byDay = Dictionary(grouping: sessions, by: \.day)
        var day = start
        var index = 0
        while day <= now {
            let offset = rng.normal(0, shape.variability)
            let workouts = byDay[day] ?? []
            for slot in 0..<96 {
                defer { index += 1 }
                let t = day.addingTimeInterval(Double(slot) * 900)
                guard t <= now else { break }
                if index % (14 * 96) < 8 { continue }   // sensor change
                guard !existing.contains(Int(t.timeIntervalSinceReferenceDate / 900)) else { continue }
                let h = Double(slot) / 4
                var v = shape.baseline + offset + rng.normal(0, 0.15)
                if h >= 4 && h < 8 { v += shape.dawn * min(1, (h - 4) / 3) }
                for (i, meal) in shape.meals.enumerated() {
                    let dinner = i == shape.meals.count - 1
                    let mealHour = meal.hour + (dinner && lateMeal.contains(day) ? 1.5 : 0)
                    var peak = meal.peak * (dinner && lateMeal.contains(day) ? 1.2 : 1)
                    let walked = workouts.contains { w in
                        let wh = Double(w.start.minutesOfDay) / 60
                        return wh > mealHour && wh - mealHour <= 1.5
                    }
                    if walked { peak *= 0.75 }
                    let dt = h - mealHour
                    if dt > 0 && dt < 4 { v += peak * (dt / shape.peakHours) * exp(1 - dt / shape.peakHours) }
                }
                // Muscles take up sugar during a workout and for a couple of hours after.
                if workouts.contains(where: { w in
                    let wh = Double(w.start.minutesOfDay) / 60
                    return h >= wh && h <= wh + w.minutes / 60 + 2
                }) { v -= shape.exerciseDrop }
                ctx.insert(VitalReading(time: t, kind: .glucose, value: min(shape.ceiling, max(shape.floor, v)).rounded(to: 0.1),
                                        context: .random, source: .demo))
            }
            day = day.adding(days: 1)
        }
    }

    /// A stable seed per sample user (Swift's own hash changes between launches).
    static func seed(_ s: String) -> UInt64 {
        var h: UInt64 = 0xcbf29ce484222325
        for b in ("enrich-" + s).utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return h
    }
}
