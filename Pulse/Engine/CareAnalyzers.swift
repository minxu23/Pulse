import Foundation

// MARK: - Sleep & sleep-breathing (需求 6)

struct SleepSummary: Equatable {
    var nights: Int
    var avgMinutes: Double?
    var avgBedtime: Int?
    var bedtimeSD: Double?
    var nightsMeetingNeed: Int
    var regularityText: String
}

struct BreathingCues: Equatable {
    enum Level { case none, some, notable
        var label: String {
            switch self {
            case .none: "暂无明显线索"
            case .some: "存在少量线索"
            case .notable: "线索较多"
            }
        }
    }
    var nightsObserved: Int
    var snoring: Int
    var gasping: Int
    var witnessed: Int
    var headache: Int
    var sleepy: Int
    var lowSpO2Nights: Int
    var avgDisturbances: Double?
    var level: Level
    var message: String
}

struct StopBangQuestion: Identifiable {
    let id: Int
    let letter: String
    let text: String
    let autoDerived: Bool
}

enum SleepAnalyzer {
    static func summary(days: [DayData], profile p: ProfileSnapshot, now: Date = .app, window: Int = 14) -> SleepSummary {
        let recent = days.filter { $0.day > now.startOfDay.adding(days: -window) }
        let mins = recent.compactMap(\.sleepMinutes)
        let starts = recent.compactMap(\.sleepStart).map { Double(Clock.nightOffset($0.minutesOfDay)) }
        let sd = starts.count >= 4 ? Stats.sd(starts) : nil
        let avgStart = Stats.mean(starts).map { (Int($0) + 720) % 1440 }
        let regularity: String
        switch sd {
        case .none: regularity = "数据不足"
        case .some(let s) where s <= 30: regularity = "作息很规律"
        case .some(let s) where s <= 60: regularity = "作息较规律"
        default: regularity = "入睡时间波动较大"
        }
        return SleepSummary(nights: mins.count, avgMinutes: Stats.mean(mins), avgBedtime: avgStart, bedtimeSD: sd,
                            nightsMeetingNeed: mins.filter { $0 >= p.sleepNeedMinutes - 30 }.count, regularityText: regularity)
    }

    static func breathingCues(days: [DayData], now: Date = .app, window: Int = 30) -> BreathingCues {
        let recent = days.filter { $0.day > now.startOfDay.adding(days: -window) }
        let observed = recent.filter { $0.checkedIn || $0.snoring || $0.gasping || $0.sleepMinutes != nil }.count
        let snoring = recent.filter(\.snoring).count
        let gasping = recent.filter(\.gasping).count
        let witnessed = recent.filter(\.witnessedApnea).count
        let headache = recent.filter(\.morningHeadache).count
        let sleepy = recent.filter(\.daytimeSleepy).count
        let lowO2 = recent.filter { ($0.spo2Min ?? 100) < 88 }.count
        let dist = Stats.mean(recent.compactMap(\.breathingDisturbances))

        var score = 0
        if witnessed > 0 { score += 3 }
        if gasping >= 2 { score += 2 }
        if snoring >= 8 { score += 2 } else if snoring >= 3 { score += 1 }
        if lowO2 >= 2 { score += 2 }
        if sleepy >= 8 { score += 1 }
        if headache >= 4 { score += 1 }
        let level: BreathingCues.Level = score >= 3 ? .notable : (score >= 1 ? .some : .none)
        let message: String
        switch level {
        case .notable:
            message = "近 \(window) 天记录到较多与睡眠呼吸相关的线索。这些线索不能用于诊断，但值得进行专业睡眠评估（通常包括问诊和睡眠监测）。"
        case .some:
            message = "有少量线索。继续记录打鼾、憋醒与白天困倦情况，必要时咨询医生。"
        case .none:
            message = "暂未记录到明显线索。若家人观察到你睡眠中打鼾或呼吸暂停，请及时记录。"
        }
        return BreathingCues(nightsObserved: observed, snoring: snoring, gasping: gasping, witnessed: witnessed,
                             headache: headache, sleepy: sleepy, lowSpO2Nights: lowO2, avgDisturbances: dist,
                             level: level, message: message)
    }

    static let stopBangQuestions: [StopBangQuestion] = [
        .init(id: 0, letter: "S", text: "是否大声打鼾（隔着门也能听到）？", autoDerived: false),
        .init(id: 1, letter: "T", text: "白天是否经常感到疲倦、困倦，甚至开车时想睡？", autoDerived: false),
        .init(id: 2, letter: "O", text: "是否有人观察到你睡眠中呼吸停止、憋气或喘息？", autoDerived: false),
        .init(id: 3, letter: "P", text: "是否有高血压，或正在接受高血压治疗？", autoDerived: true),
        .init(id: 4, letter: "B", text: "BMI 是否大于 35 kg/m²？", autoDerived: true),
        .init(id: 5, letter: "A", text: "年龄是否超过 50 岁？", autoDerived: true),
        .init(id: 6, letter: "N", text: "颈围是否大于 40 cm？", autoDerived: true),
        .init(id: 7, letter: "G", text: "性别是否为男性？", autoDerived: true),
    ]

    static func stopBangDefaults(profile p: ProfileSnapshot) -> [Bool] {
        [false, false, false,
         p.conditions.contains(.hypertension),
         p.bmi > 35,
         p.age > 50,
         (p.neckCm ?? 0) > 40,
         p.sex == .male]
    }

    /// STOP-BANG screening questionnaire: 0–2 low, 3–4 intermediate, 5–8 high risk.
    static func stopBang(_ answers: [Bool]) -> (score: Int, risk: String, advice: String) {
        let score = answers.filter { $0 }.count
        switch score {
        case 0...2: return (score, "低风险", "筛查提示风险较低。若出现明显打鼾、憋醒或白天困倦，可重新评估。")
        case 3...4: return (score, "中等风险", "建议与医生讨论睡眠情况，必要时进行睡眠监测评估。")
        default: return (score, "较高风险", "建议尽快到睡眠门诊或呼吸科进行专业评估（睡眠监测 / 多导睡眠图）。")
        }
    }
}

// MARK: - Glucose (糖尿病照护)

struct GlucoseMetrics: Equatable {
    var readings: Int
    var coverage: Double
    var isContinuous: Bool
    var mean: Double?
    var tir: Double?
    var tbr: Double?
    var tbrSevere: Double?
    var tar: Double?
    var tarSevere: Double?
    var cv: Double?
    var gmi: Double?
    var sufficient: Bool { isContinuous && coverage >= 0.7 }
}

struct HourlyGlucose: Identifiable, Equatable {
    var id: Int { hour }
    let hour: Int
    let p10: Double
    let p25: Double
    let median: Double
    let p75: Double
    let p90: Double
}

enum GlucoseAnalyzer {
    /// Consensus CGM metrics over a window: TIR 3.9–10.0 mmol/L, TBR <3.9 (<3.0 severe), TAR >10 (>13.9 severe).
    static func metrics(_ points: [(time: Date, value: Double)], low: Double = 3.9, high: Double = 10.0,
                        windowDays: Int = 14, now: Date = .app) -> GlucoseMetrics {
        let start = now.adding(days: -windowDays)
        let pts = points.filter { $0.time >= start && $0.time <= now }
        guard !pts.isEmpty else {
            return GlucoseMetrics(readings: 0, coverage: 0, isContinuous: false)
        }
        let slots = Set(pts.map { Int($0.time.timeIntervalSince1970 / 900) }).count
        let coverage = min(1, Double(slots) / Double(windowDays * 96))
        let isCGM = Double(pts.count) / Double(windowDays) >= 48
        let vals = pts.map(\.value)
        let n = Double(vals.count)
        let mean = Stats.mean(vals)
        return GlucoseMetrics(
            readings: pts.count, coverage: coverage, isContinuous: isCGM, mean: mean,
            tir: Double(vals.filter { $0 >= low && $0 <= high }.count) / n,
            tbr: Double(vals.filter { $0 < low }.count) / n,
            tbrSevere: Double(vals.filter { $0 < 3.0 }.count) / n,
            tar: Double(vals.filter { $0 > high }.count) / n,
            tarSevere: Double(vals.filter { $0 > 13.9 }.count) / n,
            cv: mean.flatMap { m in Stats.sd(vals).map { $0 / m * 100 } },
            gmi: mean.map { 3.31 + 0.02392 * ($0 * 18.016) })
    }

    /// Ambulatory-glucose-profile style percentiles per hour of day.
    static func hourlyProfile(_ points: [(time: Date, value: Double)]) -> [HourlyGlucose] {
        let groups = Dictionary(grouping: points, by: { $0.time.hour })
        return (0..<24).compactMap { h in
            guard let vals = groups[h]?.map(\.value), vals.count >= 3 else { return nil }
            return HourlyGlucose(hour: h, p10: Stats.quantile(vals, 0.1)!, p25: Stats.quantile(vals, 0.25)!,
                                 median: Stats.quantile(vals, 0.5)!, p75: Stats.quantile(vals, 0.75)!,
                                 p90: Stats.quantile(vals, 0.9)!)
        }
    }

    /// Pre-exercise guidance according to the user's care-plan thresholds.
    static func preExerciseAdvice(glucose: Double, profile p: ProfileSnapshot) -> String {
        if glucose < p.glucoseLow {
            return "低于 \(p.glucoseLow.oneDecimal)：先处理低血糖并复测，恢复后再考虑运动。"
        }
        if glucose < p.glucosePreExerciseMin {
            return "低于运动前下限 \(p.glucosePreExerciseMin.oneDecimal)：按照护计划先补充碳水（常见为 15–30 g），再开始运动。"
        }
        if glucose > p.glucoseExerciseMax {
            return "高于 \(p.glucoseExerciseMax.oneDecimal)：按照护计划处理，1 型糖尿病请先检测酮体；酮体阳性时不要运动。"
        }
        return "在照护计划的运动范围内，可以开始运动；时长超过 1 小时请带好补给。"
    }
}

// MARK: - Blood pressure summary

struct BPSummary: Equatable {
    var count: Int
    var avgSys: Double?
    var avgDia: Double?
    var morningSys: Double?
    var eveningSys: Double?
    var inTargetRate: Double?
    var category: String
}

enum BPAnalyzer {
    static func summary(_ readings: [VitalPoint], profile p: ProfileSnapshot, days: Int = 30, now: Date = .app) -> BPSummary {
        let bp = readings.filter { $0.kind == .bloodPressure && $0.time > now.adding(days: -days) }
        guard !bp.isEmpty else { return BPSummary(count: 0, category: "暂无记录") }
        let sys = bp.map(\.value), dia = bp.compactMap(\.value2)
        let avgS = Stats.mean(sys)!, avgD = Stats.mean(dia) ?? 0
        let inTarget = bp.filter { $0.value <= Double(p.bpTargetSys) && ($0.value2 ?? 0) <= Double(p.bpTargetDia) }.count
        let category: String
        switch (avgS, avgD) {
        case (180..., _), (_, 120...): category = "显著升高，请尽快就医评估"
        case (140..., _), (_, 90...): category = "高于 140/90"
        case (130..., _), (_, 80...): category = "130–139 / 80–89 区间"
        case (120..., _): category = "120–129 区间"
        default: category = "低于 120/80"
        }
        return BPSummary(count: bp.count, avgSys: avgS, avgDia: avgD,
                         morningSys: Stats.mean(bp.filter { $0.time.hour < 12 }.map(\.value)),
                         eveningSys: Stats.mean(bp.filter { $0.time.hour >= 17 }.map(\.value)),
                         inTargetRate: Double(inTarget) / Double(bp.count), category: category)
    }
}
