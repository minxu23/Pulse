import Foundation

enum ReadinessLevel: String, Equatable {
    case high, moderate, low, rest
    var label: String {
        switch self {
        case .high: "恢复充分"
        case .moderate: "基本恢复"
        case .low: "恢复不足"
        case .rest: "需要休息"
        }
    }
    var recommendation: String {
        switch self {
        case .high: "可以按计划进行，包括计划中的较高强度训练。"
        case .moderate: "可以按计划进行；强度课建议缩短或减少组数。"
        case .low: "建议以低强度有氧、步行或灵活性训练为主，暂缓强度课。"
        case .rest: "建议休息或仅做轻松活动，优先睡眠和放松。"
        }
    }
    /// Highest intensity that fits today's readiness.
    var maxIntensity: Intensity {
        switch self {
        case .high, .moderate: .hard
        case .low: .easy
        case .rest: .rest
        }
    }
    static func from(score: Double) -> ReadinessLevel {
        switch score {
        case 75...: .high
        case 60..<75: .moderate
        case 40..<60: .low
        default: .rest
        }
    }
}

struct ReadinessFactor: Identifiable, Equatable {
    enum Impact { case positive, neutral, negative }
    let id: String
    let name: String
    let icon: String
    let score: Double?
    let weight: Double
    let value: String
    let detail: String
    var available: Bool { score != nil }
    var impact: Impact {
        guard let s = score else { return .neutral }
        return s >= 75 ? .positive : (s >= 55 ? .neutral : .negative)
    }
}

struct ReadinessResult: Equatable {
    var score: Int?
    var level: ReadinessLevel
    var factors: [ReadinessFactor]
    var confidence: Confidence
    var headline: String
    var recommendation: String
    var overrides: [String]
    var notes: [String]
    var missing: [String]
}

/// Body Readiness: "how should I arrange today?" — combines last night's sleep, overnight
/// physiology, recent load and how the user feels on waking (需求 3).
enum ReadinessEngine {
    static let weights: [String: Double] = ["sleep": 0.25, "rhr": 0.25, "hrv": 0.20, "load": 0.10, "feel": 0.20]

    static func evaluate(today: DayData?, history: [DayData], profile: ProfileSnapshot) -> ReadinessResult {
        let day = today ?? DayData(day: .app)
        let hist = history.filter { $0.day < day.day }.sorted { $0.day < $1.day }
        let recent28 = hist.filter { $0.day >= day.day.adding(days: -28) }
        var factors: [ReadinessFactor] = []
        var notes: [String] = []
        var missing: [String] = []

        // Sleep
        if let m = day.sleepMinutes {
            let need = profile.sleepNeedMinutes
            var s = Stats.interp(m / need, [(0.5, 20), (0.7, 50), (0.85, 75), (1.0, 100)])
            var detail = "睡眠 \((m / 60).oneDecimal) 小时，约为你所需的 \(Int(m / need * 100))%。"
            if let start = day.sleepStart {
                let starts = hist.suffix(7).compactMap(\.sleepStart).map { Double(Clock.nightOffset($0.minutesOfDay)) }
                if starts.count >= 4, let med = Stats.median(starts) {
                    let dev = abs(Double(Clock.nightOffset(start.minutesOfDay)) - med)
                    if dev > 90 {
                        s -= 10
                        detail += "入睡时间比平时偏离约 \(Int(dev)) 分钟。"
                    }
                }
            }
            if let feel = day.sleepFeel {
                s = 0.7 * s + 0.3 * feelScore(feel)
                detail += "主观睡眠感受 \(feel)/5。"
            }
            factors.append(.init(id: "sleep", name: "昨夜睡眠", icon: "bed.double.fill", score: max(0, s),
                                 weight: weights["sleep"]!, value: "\((m / 60).oneDecimal) 小时", detail: detail))
        } else if let feel = day.sleepFeel {
            factors.append(.init(id: "sleep", name: "昨夜睡眠", icon: "bed.double.fill", score: feelScore(feel),
                                 weight: weights["sleep"]!, value: "主观 \(feel)/5",
                                 detail: "暂无设备睡眠数据，按主观睡眠感受评估。"))
        } else {
            missing.append("昨夜睡眠")
            factors.append(.init(id: "sleep", name: "昨夜睡眠", icon: "bed.double.fill", score: nil,
                                 weight: weights["sleep"]!, value: "—", detail: "暂无睡眠数据。"))
        }

        // Resting heart rate vs personal norm (same measurement source)
        if let r = day.rhr {
            let src = day.rhrSource ?? .device
            let ref = recent28.filter { ($0.rhrSource ?? .device) == src }.compactMap(\.rhr)
            let norm = ref.count >= 5 ? Stats.mean(ref) : profile.baselineRHR
            if let n = norm {
                let dev = r - n
                let s = Stats.interp(dev, [(-1, 100), (2, 85), (4, 65), (6, 45), (9, 20)])
                let rel = abs(dev) < 1 ? "与近 4 周平均基本一致" : (dev > 0 ? "比近 4 周平均高 \(dev.noDecimal) bpm" : "比近 4 周平均低 \(abs(dev).noDecimal) bpm")
                factors.append(.init(id: "rhr", name: "静息心率", icon: "heart.fill", score: s, weight: weights["rhr"]!,
                                     value: "\(r.noDecimal) bpm", detail: "今晨 \(r.noDecimal) bpm，\(rel)。"))
            } else {
                factors.append(.init(id: "rhr", name: "静息心率", icon: "heart.fill", score: nil, weight: weights["rhr"]!,
                                     value: "\(r.noDecimal) bpm", detail: "个人参照尚未建立（需约 1–2 周数据），暂不计入评估。"))
                missing.append("静息心率参照")
            }
        } else {
            missing.append("今晨静息心率")
            factors.append(.init(id: "rhr", name: "静息心率", icon: "heart.fill", score: nil, weight: weights["rhr"]!,
                                 value: "—", detail: "暂无今晨数据。可佩戴设备入睡，或醒后静躺 1 分钟手动测量。"))
        }

        // HRV vs personal normal range (log-transformed)
        let hrvHist = recent28.compactMap(\.hrv).filter { $0 > 0 }
        if let h = day.hrv, h > 0, hrvHist.count >= 7 {
            let logs = hrvHist.map { log($0) }
            let m = Stats.mean(logs)!, sd = max(Stats.sd(logs) ?? 0.1, 0.05)
            let z = (log(h) - m) / sd
            let s = Stats.interp(z, [(-2.5, 15), (-2, 30), (-1.5, 50), (-1, 70), (-0.5, 95), (0, 100)])
            let rel = z >= -0.5 ? "处于你的常见范围" : (z >= -1.5 ? "略低于你的常见范围" : "明显低于你的常见范围")
            factors.append(.init(id: "hrv", name: "心率变异性", icon: "waveform.path.ecg", score: s, weight: weights["hrv"]!,
                                 value: "\(h.noDecimal) ms", detail: "夜间 HRV \(h.noDecimal) ms，\(rel)（近 4 周中位约 \(exp(m).noDecimal) ms）。"))
        } else {
            missing.append("心率变异性")
            factors.append(.init(id: "hrv", name: "心率变异性", icon: "waveform.path.ecg", score: nil, weight: weights["hrv"]!,
                                 value: day.hrv.map { "\($0.noDecimal) ms" } ?? "—",
                                 detail: day.hrv == nil ? "暂无 HRV 数据（需要支持的手表）。" : "HRV 参照需至少 7 天数据。"))
        }

        // Recent training load: acute (7 d) vs chronic (28 d)
        let loadDays = (1...28).map { i -> Double in
            let d = day.day.adding(days: -i)
            return hist.first(where: { $0.day == d })?.load ?? 0
        }
        let chronic = loadDays.reduce(0, +) / 28
        let acute = loadDays.prefix(7).reduce(0, +) / 7
        if chronic > 0 {
            let ratio = acute / chronic
            var s = Stats.interp(ratio, [(1.3, 100), (1.5, 75), (2.0, 40), (2.5, 25)])
            var detail = "近 7 天训练负荷为近 4 周平均的 \(String(format: "%.1f", ratio)) 倍。"
            if let y = loadDays.first, y > 2 * chronic, y > 200 {
                s -= 10
                detail += "昨天负荷较高。"
            }
            factors.append(.init(id: "load", name: "近期负荷", icon: "flame.fill", score: max(0, s), weight: weights["load"]!,
                                 value: "×\(String(format: "%.1f", ratio))", detail: detail))
        } else {
            factors.append(.init(id: "load", name: "近期负荷", icon: "flame.fill", score: nil, weight: weights["load"]!,
                                 value: "—", detail: "近 4 周暂无训练记录。"))
        }

        // How the user feels on waking
        var feelParts: [Double] = []
        var feelText: [String] = []
        if let e = day.energy { feelParts.append(Stats.interp(Double(e), [(1, 20), (2, 45), (3, 70), (4, 88), (5, 100)])); feelText.append("精力 \(e)/5") }
        if let so = day.soreness { feelParts.append(Stats.interp(Double(so), [(0, 100), (1, 80), (2, 50), (3, 25)])); feelText.append("酸痛 \(["无", "轻微", "明显", "严重"][min(3, so)])") }
        if let st = day.stress { feelParts.append(Stats.interp(Double(st), [(1, 100), (2, 92), (3, 78), (4, 55), (5, 35)])); feelText.append("压力 \(st)/5") }
        if let fs = Stats.mean(feelParts) {
            factors.append(.init(id: "feel", name: "醒后感受", icon: "face.smiling", score: fs, weight: weights["feel"]!,
                                 value: feelText.first ?? "", detail: feelText.joined(separator: " · ") + "。"))
        } else {
            missing.append("醒后感受")
            factors.append(.init(id: "feel", name: "醒后感受", icon: "face.smiling", score: nil, weight: weights["feel"]!,
                                 value: "—", detail: "完成晨起感受记录（约 20 秒）可让判断更准确。"))
        }

        // Context notes from yesterday
        if let y = hist.last, y.day == day.day.adding(days: -1) {
            if y.alcoholUnits >= 1 {
                notes.append("昨天饮酒 \(y.alcoholUnits.oneDecimal) 单位，可能使今晨心率偏高、HRV 偏低，这部分影响通常 1–2 天内消退。")
            }
            if y.tags.contains(.travel) { notes.append("昨天有出差 / 时差记录，作息变化会影响恢复指标。") }
        }

        // Combine
        let available = factors.filter(\.available)
        let wSum = available.map(\.weight).reduce(0, +)
        var overrides: [String] = []
        var scoreValue: Double? = wSum > 0 ? available.reduce(0) { $0 + $1.score! * $1.weight } / wSum : nil
        // Training load alone says nothing about last night's recovery: wait for sleep, overnight
        // heart rate / HRV or the morning check-in.
        if !available.contains(where: { $0.id != "load" }) { scoreValue = nil }

        if day.isIll {
            overrides.append("记录了生病 / 不适：今天以休息为主。发热或全身症状时避免运动，症状消退后再逐步恢复。")
            scoreValue = min(scoreValue ?? 35, 35)
        }
        if let s = day.soreness, s >= 3 {
            overrides.append("肌肉酸痛严重：避免对酸痛部位施加负荷。")
            scoreValue = min(scoreValue ?? 55, 55)
        }

        let confidence: Confidence
        let hasPhysio = available.contains { $0.id == "rhr" || $0.id == "hrv" }
        let hasSleep = available.contains { $0.id == "sleep" }
        if wSum >= 0.8 && hasPhysio && hasSleep { confidence = .high }
        else if wSum >= 0.45 { confidence = .medium }
        else { confidence = .low }

        guard let score = scoreValue else {
            return ReadinessResult(score: nil, level: .moderate, factors: factors, confidence: .low,
                                   headline: "完成晨起感受或同步设备数据后即可评估",
                                   recommendation: "在获得更多信息前，可按计划以中低强度进行，并留意身体感受。",
                                   overrides: overrides, notes: notes, missing: missing)
        }

        let level = ReadinessLevel.from(score: score)
        let negatives = available.filter { $0.impact == .negative }.map(\.name)
        let positives = available.filter { $0.impact == .positive }.map(\.name)
        var headline = level.label
        if !negatives.isEmpty {
            headline += "：主要受\(negatives.prefix(2).joined(separator: "、"))影响"
        } else if !positives.isEmpty {
            headline += "：\(positives.prefix(2).joined(separator: "、"))状态良好"
        }
        var recommendation = level.recommendation
        if profile.cardiacLimited && level.maxIntensity == .hard {
            recommendation = "可以按计划进行中低强度活动（较高强度需先与医生确认）。"
        }
        return ReadinessResult(score: Int(score.rounded()), level: level, factors: factors, confidence: confidence,
                               headline: headline, recommendation: recommendation,
                               overrides: overrides, notes: notes, missing: missing)
    }

    private static func feelScore(_ v: Int) -> Double {
        Stats.interp(Double(v), [(1, 20), (2, 45), (3, 70), (4, 88), (5, 100)])
    }
}

// MARK: - Body vitality (what was actually done today)

struct VitalityResult: Equatable {
    var score: Int
    var steps: Int
    var stepsTarget: Int
    var activeMinutes: Double
    var plannedMinutes: Int
    var load: Double
    var label: String
    var message: String
}

/// Body Vitality: "how much have I actually moved today?" — complements readiness (需求 5).
enum VitalityEngine {
    static func evaluate(today: DayData?, plannedMinutes: Int, stepsTarget: Int,
                         readiness: ReadinessResult?, now: Date = .app) -> VitalityResult {
        let steps = today?.steps ?? 0
        let active = today?.activeMinutes ?? 0
        let planned = max(plannedMinutes, 20)
        let stepsRatio = min(1, Double(steps) / Double(max(stepsTarget, 1)))
        let exRatio = min(1, active / Double(planned))
        let score = Int((100 * (0.5 * stepsRatio + 0.5 * exRatio)).rounded())
        let heavy = Double(steps) > 1.5 * Double(stepsTarget) || active > 1.5 * Double(planned)

        let label: String
        switch score {
        case ..<40: label = "活动较少"
        case 40..<80: label = "进行中"
        default: label = heavy ? "活动量较大" : "今日活动达标"
        }

        var message: String
        let level = readiness?.level
        if heavy, level == .low || level == .rest {
            message = "今天的活动量已超过准备度建议，剩余时间以放松和恢复为主。"
        } else if score >= 80 {
            message = "今天的活动已经比较完整，保持即可。"
        } else if now.hour >= 17 && (level == .high || level == .moderate) {
            let left = max(0, stepsTarget - steps)
            message = left > 0 ? "距步数目标还差约 \(left) 步，饭后散步 15–20 分钟就能完成。" : "步数已达标，可按计划完成训练。"
        } else {
            message = "白天多起身走动，每坐 1 小时活动 2–3 分钟也有帮助。"
        }
        return VitalityResult(score: score, steps: steps, stepsTarget: stepsTarget, activeMinutes: active,
                              plannedMinutes: plannedMinutes, load: today?.load ?? 0, label: label, message: message)
    }
}
