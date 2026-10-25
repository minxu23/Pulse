import Foundation

// Analyzers for the optional professional modules: specialist sport (全马), cardiovascular
// health and glucose management. All are pure functions over value snapshots so they can be
// unit-tested; none of them diagnoses, prescribes or doses.

// MARK: - Training load (acute : chronic workload ratio)

struct WeeklyLoad: Identifiable, Equatable {
    var id: Date { weekStart }
    let weekStart: Date
    let load: Double
    let minutes: Double
    let km: Double
}

struct TrainingLoadStatus: Equatable {
    enum Zone: Equatable {
        case insufficient, low, optimal, caution, high
        var label: String {
            switch self {
            case .insufficient: "数据积累中"
            case .low: "负荷偏低"
            case .optimal: "负荷适宜"
            case .caution: "增长偏快"
            case .high: "增长过快"
            }
        }
    }
    var acute: Double
    var chronicWeekly: Double
    var ratio: Double?
    var zone: Zone
    var message: String
    var weeks: [WeeklyLoad]
}

enum TrainingLoad {
    /// Session load = minutes × RPE. Acute = last 7 days; chronic = average week over the last 28 days.
    /// A ratio of roughly 0.8–1.3 is the commonly cited range for building fitness with lower injury risk.
    static func status(_ workouts: [WorkoutPoint], now: Date = .app) -> TrainingLoadStatus {
        let end = now
        func load(_ w: WorkoutPoint) -> Double { w.minutes * Double(w.rpe ?? w.type.defaultRPE) }
        let acute = workouts.filter { $0.start > end.adding(days: -7) && $0.start <= end }.map(load).reduce(0, +)
        let chronic = workouts.filter { $0.start > end.adding(days: -28) && $0.start <= end }.map(load).reduce(0, +) / 4
        let weeks: [WeeklyLoad] = (0..<8).reversed().map { i in
            let ws = now.weekStart.adding(days: -7 * i)
            let list = workouts.filter { $0.start >= ws && $0.start < ws.adding(days: 7) }
            return WeeklyLoad(weekStart: ws, load: list.map(load).reduce(0, +), minutes: list.map(\.minutes).reduce(0, +),
                              km: list.filter { $0.type == .run }.compactMap(\.distanceKm).reduce(0, +))
        }
        let history = workouts.map(\.start).min().map { now.daysSince($0) } ?? 0
        guard history >= 21, chronic > 0 else {
            return TrainingLoadStatus(acute: acute, chronicWeekly: chronic, ratio: nil, zone: .insufficient,
                                      message: "需要约 3 周的运动记录才能比较近期与长期负荷。", weeks: weeks)
        }
        let ratio = acute / chronic
        let zone: TrainingLoadStatus.Zone
        let message: String
        switch ratio {
        case ..<0.8:
            zone = .low; message = "本周负荷低于近 4 周的平均水平。恢复周或减量期属正常；否则可以按计划逐步恢复。"
        case 0.8...1.3:
            zone = .optimal; message = "本周负荷与近 4 周的水平相符，增长节奏合适。"
        case 1.3...1.5:
            zone = .caution; message = "本周负荷比近 4 周平均高出较多，注意睡眠与酸痛，下周不要继续加量。"
        default:
            zone = .high; message = "本周负荷增长过快（超过近 4 周平均的 1.5 倍），伤病风险上升，建议接下来几天以轻松为主。"
        }
        return TrainingLoadStatus(acute: acute, chronicWeekly: chronic, ratio: ratio, zone: zone, message: message, weeks: weeks)
    }
}

// MARK: - Race prediction & pacing

struct RacePrediction: Equatable {
    var minutes: Int
    var basisKm: Double
    var basisMinutes: Double
    var basisDate: Date
}

enum RacePredictor {
    /// Riegel: T2 = T1 × (D2 / D1)^1.06.
    static func riegel(distanceKm: Double, minutes: Double, targetKm: Double = 42.195) -> Double {
        minutes * pow(targetKm / distanceKm, 1.06)
    }

    /// Best marathon estimate from runs of at least 5 km in the last 8 weeks. Training runs are
    /// rarely all-out, so the estimate is conservative.
    static func predict(_ workouts: [WorkoutPoint], now: Date = .app) -> RacePrediction? {
        let runs = workouts.filter { $0.type == .run && ($0.distanceKm ?? 0) >= 5 && $0.start > now.adding(days: -56) }
        let best = runs.min { riegel(distanceKm: $0.distanceKm!, minutes: $0.minutes) < riegel(distanceKm: $1.distanceKm!, minutes: $1.minutes) }
        guard let b = best, let km = b.distanceKm else { return nil }
        return RacePrediction(minutes: Int(riegel(distanceKm: km, minutes: b.minutes).rounded()), basisKm: km,
                              basisMinutes: b.minutes, basisDate: b.start)
    }

    static func timeText(_ minutes: Int) -> String { String(format: "%d:%02d", minutes / 60, minutes % 60) }

    /// Even-pace splits every 5 km plus the finish.
    static func splits(targetMinutes: Int) -> [(km: Double, minutes: Double)] {
        let pace = Double(targetMinutes) / 42.195
        return [5, 10, 15, 20, 21.0975, 25, 30, 35, 40, 42.195].map { ($0, $0 * pace) }
    }

    static func clockText(_ minutes: Double) -> String {
        let s = Int((minutes * 60).rounded())
        return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }
}

// MARK: - Heart-rate zones

struct HRZone: Identifiable, Equatable {
    var id: Int { index }
    let index: Int
    let name: String
    let low: Int
    let high: Int
    let purpose: String
    var aboveCap = false
}

enum HRZones {
    /// Lactate-threshold zones when a professionally assessed threshold HR exists; otherwise
    /// zones from the estimated maximum heart rate. A clinician's cap marks higher zones as off-limits.
    static func zones(profile p: ProfileSnapshot) -> (zones: [HRZone], basis: String) {
        var out: [HRZone]
        let basis: String
        if let lt = p.thresholdHR.map(Double.init) {
            basis = "以阈值心率 \(Int(lt)) bpm 为参照（乳酸测试 / 专业评估）"
            let b = [0.0, 0.85, 0.90, 0.95, 1.0, 1.06].map { Int(($0 * lt).rounded()) }
            out = [
                HRZone(index: 1, name: "恢复", low: Int(lt * 0.65), high: b[1] - 1, purpose: "热身、放松、恢复跑"),
                HRZone(index: 2, name: "有氧基础", low: b[1], high: b[2] - 1, purpose: "轻松跑、长距离主体"),
                HRZone(index: 3, name: "节奏", low: b[2], high: b[3] - 1, purpose: "马拉松配速附近"),
                HRZone(index: 4, name: "阈值", low: b[3], high: b[4] - 1, purpose: "阈值跑、巡航间歇"),
                HRZone(index: 5, name: "高强度", low: b[4], high: b[5], purpose: "短间歇，专项期少量使用"),
            ]
        } else {
            let mx = p.estimatedMaxHR
            basis = "以估算最大心率 \(Int(mx)) bpm 为参照（208 − 0.7 × 年龄，个体差异较大）"
            let b = [0.5, 0.6, 0.7, 0.8, 0.9, 1.0].map { Int(($0 * mx).rounded()) }
            out = [
                HRZone(index: 1, name: "恢复", low: b[0], high: b[1] - 1, purpose: "热身、放松、日常活动"),
                HRZone(index: 2, name: "有氧基础", low: b[1], high: b[2] - 1, purpose: "轻松有氧，改善静息心率的主体"),
                HRZone(index: 3, name: "节奏", low: b[2], high: b[3] - 1, purpose: "中等强度"),
                HRZone(index: 4, name: "阈值", low: b[3], high: b[4] - 1, purpose: "较高强度，需要良好恢复"),
                HRZone(index: 5, name: "高强度", low: b[4], high: b[5], purpose: "短时冲刺，有基础后少量使用"),
            ]
        }
        if let cap = p.hrCap {
            out = out.map { z in var z = z; z.aboveCap = z.low > cap; return z }
        }
        return (out, basis)
    }
}

// MARK: - Lactate step test

struct LactateStage: Equatable {
    var time: Date
    var lactate: Double
    var hr: Double?
    var pace: String?
}

struct LactateResult: Equatable {
    var baseline: Double
    var lt1HR: Double?
    var lt2HR: Double?
    var lt1Pace: String?
    var lt2Pace: String?
    var reached4: Bool
    var notes: [String]
}

enum LactateAnalyzer {
    /// Parses stages recorded as lactate readings (pulse = HR, note may contain "配速 6:30").
    static func stages(_ readings: [VitalPoint], pulses: [Double?], notes: [String]) -> [LactateStage] {
        zip(readings.indices, readings).map { i, r in
            LactateStage(time: r.time, lactate: r.value, hr: pulses[safe: i] ?? nil, pace: pace(in: notes[safe: i] ?? ""))
        }
        .sorted { $0.time < $1.time }
    }

    static func pace(in note: String) -> String? {
        guard let r = note.range(of: #"\d{1,2}:\d{2}"#, options: .regularExpression) else { return nil }
        return String(note[r])
    }

    /// LT1 ≈ first stage ≥ 0.5 mmol/L above baseline; LT2 ≈ 4 mmol/L by linear interpolation (OBLA).
    /// Methods differ between labs — these are estimates to discuss with the tester.
    static func analyze(_ stages: [LactateStage]) -> LactateResult? {
        guard stages.count >= 3 else { return nil }
        let s = stages.sorted { $0.time < $1.time }
        let baseline = min(s[0].lactate, s[1].lactate)
        var r = LactateResult(baseline: baseline, reached4: s.contains { $0.lactate >= 4 }, notes: [])
        if let i = s.firstIndex(where: { $0.lactate >= baseline + 0.5 }), i > 0 {
            r.lt1HR = s[i - 1].hr.flatMap { prev in s[i].hr.map { (prev + $0) / 2 } }
            r.lt1Pace = s[i - 1].pace
        }
        if let j = s.firstIndex(where: { $0.lactate >= 4 }), j > 0 {
            let a = s[j - 1], b = s[j]
            if let ha = a.hr, let hb = b.hr, b.lactate > a.lactate {
                r.lt2HR = ha + (hb - ha) * (4 - a.lactate) / (b.lactate - a.lactate)
            }
            r.lt2Pace = b.pace
        } else if let last = s.last, let prev = s.dropLast().last, let hl = last.hr, let hp = prev.hr, last.lactate > prev.lactate {
            // Not reached: extrapolate one stage at most, and say so.
            let est = hl + (hl - hp) * (4 - last.lactate) / (last.lactate - prev.lactate)
            if est - hl <= (hl - hp) * 1.5 {
                r.lt2HR = est
                r.notes.append("测试未达到 4 mmol/L，阈值心率由最后两级外推，可信度较低。")
            }
        }
        r.notes.append("基线乳酸 \(baseline.oneDecimal) mmol/L。不同实验室对阈值的定义不同，请与测试人员一起确认。")
        return r
    }
}

// MARK: - Home blood-pressure monitoring

struct HomeBPStatus: Equatable {
    var days: Int
    var morningCount: Int
    var eveningCount: Int
    var morningAvg: (sys: Double, dia: Double)?
    var eveningAvg: (sys: Double, dia: Double)?
    var overallAvg: (sys: Double, dia: Double)?
    var progress: Double
    var aboveHomeThreshold: Bool
    var aboveTarget: Bool
    var message: String

    static func == (a: HomeBPStatus, b: HomeBPStatus) -> Bool {
        a.days == b.days && a.morningCount == b.morningCount && a.eveningCount == b.eveningCount && a.message == b.message
    }
}

extension BPAnalyzer {
    /// Seven-day home monitoring (morning and evening readings each day). Home averages of
    /// 135/85 mmHg or more correspond to clinic 140/90 in common guidelines.
    static func homeMonitoring(_ readings: [VitalPoint], profile p: ProfileSnapshot, now: Date = .app) -> HomeBPStatus {
        let start = now.startOfDay.adding(days: -6)
        let bp = readings.filter { $0.kind == .bloodPressure && $0.time >= start && $0.time <= now }
        let morning = bp.filter { (4..<12).contains($0.time.hour) }
        let evening = bp.filter { $0.time.hour >= 17 || $0.time.hour < 2 }
        func avg(_ xs: [VitalPoint]) -> (sys: Double, dia: Double)? {
            guard let s = Stats.mean(xs.map(\.value)) else { return nil }
            return (s, Stats.mean(xs.compactMap(\.value2)) ?? 0)
        }
        let days = Set(bp.map(\.time.startOfDay)).count
        let overall = avg(bp)
        let progress = min(1, Double(min(7, Set(morning.map(\.time.startOfDay)).count) + min(7, Set(evening.map(\.time.startOfDay)).count)) / 14)
        let aboveHome = overall.map { $0.sys >= 135 || $0.dia >= 85 } ?? false
        let aboveTarget = overall.map { $0.sys > Double(p.bpTargetSys) || $0.dia > Double(p.bpTargetDia) } ?? false
        let message: String
        if bp.isEmpty {
            message = "连续 7 天，每天早晚各测量一次（每次 2 遍取平均），得到的平均值最能代表你的日常血压。"
        } else if progress < 0.7 {
            message = "已测量 \(days) 天。继续早晚测量，满 7 天后平均值更可靠。"
        } else if aboveHome {
            message = "7 天家庭血压平均达到 135/85 mmHg 及以上，请带上记录与医生讨论。"
        } else if aboveTarget {
            message = "平均值低于家庭血压参考线，但高于你的照护目标 \(p.bpTargetSys)/\(p.bpTargetDia)，复诊时可以讨论。"
        } else {
            message = "7 天平均在目标范围内，继续保持规律测量。"
        }
        return HomeBPStatus(days: days, morningCount: morning.count, eveningCount: evening.count,
                            morningAvg: avg(morning), eveningAvg: avg(evening), overallAvg: overall,
                            progress: progress, aboveHomeThreshold: aboveHome, aboveTarget: aboveTarget, message: message)
    }
}

// MARK: - Cardiovascular care

enum CardioAnalyzer {
    /// Share of recorded days with medication taken on time over the last `days` days.
    static func medicationAdherence(_ days: [DayData], now: Date = .app, window: Int = 14) -> (rate: Double?, recorded: Int, missed: Int) {
        let recent = days.filter { $0.day > now.startOfDay.adding(days: -window) && $0.day <= now.startOfDay }
        let rec = recent.compactMap(\.medsTaken)
        guard !rec.isEmpty else { return (nil, 0, 0) }
        let taken = rec.filter { $0 }.count
        return (Double(taken) / Double(rec.count), rec.count, rec.count - taken)
    }

    /// Rapid weight gain is a common sign of retained fluid in heart failure and kidney disease:
    /// ≥ 2 kg within 3 days, from the lowest of the earlier readings to the latest one.
    static func rapidWeightGain(_ weights: [VitalPoint], now: Date = .app) -> Double? { weightGain(weights, now: now)?.kg }

    static func weightGain(_ weights: [VitalPoint], now: Date = .app) -> (kg: Double, from: VitalPoint, to: VitalPoint)? {
        let w = weights.filter { $0.kind == .weight && $0.time > now.adding(days: -4) && $0.time <= now }.sorted { $0.time < $1.time }
        guard let last = w.last,
              let low = w.dropLast().filter({ $0.time >= last.time.adding(days: -3) && $0.time < last.time }).min(by: { $0.value < $1.value })
        else { return nil }
        let gain = last.value - low.value
        return gain >= 2 ? (gain, low, last) : nil
    }

    /// Exercise guidance consistent with cardiac rehabilitation principles.
    static func exerciseGuidance(profile p: ProfileSnapshot) -> [String] {
        var out: [String] = []
        if !p.clinicianCleared {
            out.append("医生确认强度范围前，只安排低–中等强度：能完整说话、主观用力 11–13 级（「有点吃力」）。")
        } else if let cap = p.hrCap {
            out.append("运动心率保持在医生给出的上限 \(cap) bpm 以下，接近时放慢速度。")
        } else {
            out.append("按医生确认的范围运动，强度以主观感受为准。")
        }
        if p.onRateLoweringMeds() {
            out.append("正在使用可能降低心率的药物：心率对强度的反映变弱，以主观用力程度为准。")
        }
        out.append("热身与放松各 10 分钟以上，避免憋气用力（如大重量力量训练）。")
        out.append("出现胸痛、胸闷、明显气短、头晕或心悸时立即停止运动；不缓解请拨打 120。")
        return out
    }
}

// MARK: - Glucose: meals, exercise and low episodes

struct MealGlucoseResponse: Identifiable, Equatable {
    var id: Date { time }
    let time: Date
    let kind: MealKind
    let carbs: Double?
    let note: String
    let before: Double
    let peak: Double
    let minutesToPeak: Int
    var rise: Double { peak - before }
}

struct ExerciseGlucoseResponse: Identifiable, Equatable {
    var id: Date { start }
    let start: Date
    let type: WorkoutType
    let minutes: Double
    let before: Double
    let after: Double
    let lowestNext12h: Double?
    var change: Double { after - before }
}

struct LowEpisode: Identifiable, Equatable {
    var id: Date { start }
    let start: Date
    let minutes: Int
    let nadir: Double
    var nocturnal: Bool { start.hour < 6 }
}

struct MealInfo: Equatable {
    var time: Date
    var kind: MealKind
    var carbs: Double?
    var note: String
}

extension GlucoseAnalyzer {
    /// Rise from the value at the meal to the peak within two hours (needs continuous data).
    static func mealResponses(_ glucose: [VitalPoint], meals: [MealInfo]) -> [MealGlucoseResponse] {
        let g = glucose.filter { $0.kind == .glucose }.sorted { $0.time < $1.time }
        return meals.compactMap { m in
            guard let before = g.last(where: { $0.time <= m.time && m.time.timeIntervalSince($0.time) <= 20 * 60 }) else { return nil }
            let after = g.filter { $0.time > m.time && $0.time <= m.time.addingTimeInterval(2 * 3600) }
            guard after.count >= 4, let peak = after.max(by: { $0.value < $1.value }) else { return nil }
            return MealGlucoseResponse(time: m.time, kind: m.kind, carbs: m.carbs, note: m.note, before: before.value, peak: peak.value,
                                       minutesToPeak: Int(peak.time.timeIntervalSince(m.time) / 60))
        }
        .sorted { $0.time > $1.time }
    }

    /// Glucose before and after each session, and the lowest value in the following 12 hours
    /// (delayed exercise-related hypoglycaemia often appears overnight).
    static func exerciseResponses(_ glucose: [VitalPoint], sessions: [WorkoutPoint]) -> [ExerciseGlucoseResponse] {
        let g = glucose.filter { $0.kind == .glucose }.sorted { $0.time < $1.time }
        return sessions.compactMap { s in
            let end = s.start.addingTimeInterval(s.minutes * 60)
            guard let before = g.last(where: { $0.time <= s.start && s.start.timeIntervalSince($0.time) <= 20 * 60 }),
                  let after = g.first(where: { $0.time >= end && $0.time.timeIntervalSince(end) <= 20 * 60 }) else { return nil }
            let next = g.filter { $0.time > end && $0.time <= end.addingTimeInterval(12 * 3600) }.map(\.value)
            return ExerciseGlucoseResponse(start: s.start, type: s.type, minutes: s.minutes, before: before.value, after: after.value,
                                           lowestNext12h: next.min())
        }
        .sorted { $0.start > $1.start }
    }

    /// Consecutive readings below `low` lasting at least 15 minutes count as one episode.
    static func lowEpisodes(_ glucose: [VitalPoint], low: Double) -> [LowEpisode] {
        let g = glucose.filter { $0.kind == .glucose }.sorted { $0.time < $1.time }
        var out: [LowEpisode] = []
        var run: [VitalPoint] = []
        func flush() {
            if let f = run.first, let l = run.last {
                let minutes = Int(l.time.timeIntervalSince(f.time) / 60) + 15
                if minutes >= 15 { out.append(LowEpisode(start: f.time, minutes: minutes, nadir: run.map(\.value).min()!)) }
            }
            run = []
        }
        for v in g {
            if v.value < low {
                if let last = run.last, v.time.timeIntervalSince(last.time) > 30 * 60 { flush() }
                run.append(v)
            } else { flush() }
        }
        flush()
        return out.sorted { $0.start > $1.start }
    }

    /// Time in range for daytime (06–24) and night (00–06) separately.
    static func dayNightTIR(_ glucose: [VitalPoint], low: Double, high: Double, now: Date = .app, windowDays: Int = 14) -> (day: Double?, night: Double?) {
        let g = glucose.filter { $0.kind == .glucose && $0.time > now.adding(days: -windowDays) }
        func tir(_ xs: [VitalPoint]) -> Double? {
            xs.isEmpty ? nil : Double(xs.filter { $0.value >= low && $0.value <= high }.count) / Double(xs.count)
        }
        return (tir(g.filter { $0.time.hour >= 6 }), tir(g.filter { $0.time.hour < 6 }))
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
