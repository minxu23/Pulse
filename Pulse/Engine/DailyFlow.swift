import Foundation

// MARK: - Day phases: 起床 → 早餐前 → 日间 → 睡前 → 回顾

enum DayPhase: Int, CaseIterable, Identifiable {
    case morning, exercise, nutrition, evening, review
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .morning: "晨起评估"
        case .exercise: "运动"
        case .nutrition: "饮食与指标"
        case .evening: "睡前"
        case .review: "全天回顾"
        }
    }
    var subtitle: String {
        switch self {
        case .morning: "起床后 · 早餐前"
        case .exercise: "按准备度安排与调整"
        case .nutrition: "饮食、饮水、补给与身体指标"
        case .evening: "睡前记录与恢复安排"
        case .review: "汇总全天，安排恢复"
        }
    }
    var icon: String {
        switch self {
        case .morning: "sunrise.fill"
        case .exercise: "figure.run"
        case .nutrition: "fork.knife"
        case .evening: "moon.stars.fill"
        case .review: "text.book.closed.fill"
        }
    }

    /// The phase of the day the user is in, from their waking window (roster-aware).
    static func current(at now: Date, window w: DayWindow) -> DayPhase {
        if now < w.wake.addingTimeInterval(150 * 60) { return .morning }
        if now >= w.bed { return .review }
        if now >= w.bed.addingTimeInterval(-150 * 60) { return .evening }
        return .exercise
    }

    /// Regular hours (no roster).
    static func current(at date: Date, wakeMinutes: Int, bedtimeMinutes: Int) -> DayPhase {
        var p = ProfileSnapshot()
        p.wakeMinutes = wakeMinutes
        p.bedtimeMinutes = bedtimeMinutes
        return current(at: date, window: DayClock.window(for: DayClock.logicalToday(date, p), profile: p))
    }
}

// MARK: - Overnight analysis (晨起健康评估)

struct OvernightBP: Equatable {
    var bedtime: VitalPoint?
    var morning: VitalPoint?
    var night: [VitalPoint] = []
    var riseSys: Double?
    var morningAvgSys: Double?
    var morningAvgDia: Double?
    var previousAvgSys: Double?
    var morningDays: Int = 0
    var series: [VitalPoint] = []
    var notes: [String] = []
    var needsAttention = false
}

struct OvernightGlucose: Equatable {
    var window: DateInterval
    var points: [VitalPoint] = []
    var isContinuous = false
    var min: Double?
    var max: Double?
    var mean: Double?
    var minutesBelow = 0
    var minutesAbove = 0
    var dawnRise: Double?
    var fasting: VitalPoint?
    var notes: [String] = []
    var lowAlert = false
}

struct OvernightBreathing: Equatable {
    var snoring = false
    var gasping = false
    var witnessed = false
    var spo2Min: Double?
    var disturbances: Double?
    var disturbancesNorm: Double?
    var cpapHours: Double?
    var cpapTarget: Double?
    var notes: [String] = []
    var needsAttention = false
}

enum OvernightAnalyzer {
    /// The night ending on `day`: device sleep times when available, else 22:00 → 07:00.
    static func nightWindow(for day: Date, today: DayData?) -> DateInterval {
        let d = day.startOfDay
        let start = today?.sleepStart ?? d.adding(minutes: -120)
        let end = today?.sleepEnd ?? d.adding(minutes: 7 * 60)
        return DateInterval(start: min(start, end), end: max(start, end))
    }

    static func bloodPressure(_ vitals: [VitalPoint], morningOf day: Date, profile p: ProfileSnapshot) -> OvernightBP {
        let d = day.startOfDay
        let bp = vitals.filter { $0.kind == .bloodPressure }.sorted { $0.time < $1.time }
        var r = OvernightBP()
        r.bedtime = bp.last { $0.time >= d.adding(minutes: -6 * 60) && $0.time < d.adding(minutes: 2 * 60) }
        r.morning = bp.first { $0.time >= d.adding(minutes: 4 * 60) && $0.time < d.adding(minutes: 11 * 60) }
        r.night = bp.filter { $0.context == .night && $0.time >= d.adding(minutes: -6 * 60) && $0.time < d.adding(minutes: 7 * 60) }
        if let m = r.morning, let b = r.bedtime { r.riseSys = m.value - b.value }

        func morningReadings(daysBack range: ClosedRange<Int>) -> [VitalPoint] {
            range.compactMap { i in
                let day = d.adding(days: -i)
                return bp.first { $0.time >= day.adding(minutes: 4 * 60) && $0.time < day.adding(minutes: 11 * 60) }
            }
        }
        let week = morningReadings(daysBack: 0...6)
        let prev = morningReadings(daysBack: 7...13)
        r.series = morningReadings(daysBack: 0...13).reversed()
        r.morningDays = week.count
        r.morningAvgSys = Stats.mean(week.map(\.value))
        r.morningAvgDia = Stats.mean(week.compactMap(\.value2))
        r.previousAvgSys = prev.count >= 3 ? Stats.mean(prev.map(\.value)) : nil

        if let m = r.morning {
            var line = "今晨 \(Int(m.value))/\(Int(m.value2 ?? 0)) mmHg"
            if let b = r.bedtime, let rise = r.riseSys {
                line += "，睡前 \(Int(b.value))/\(Int(b.value2 ?? 0))，" + (abs(rise) < 5 ? "夜间前后基本一致。" : "晨起\(rise > 0 ? "高" : "低") \(Int(abs(rise))) mmHg。")
            } else {
                line += "。"
            }
            r.notes.append(line)
        } else {
            r.notes.append("今晨尚未测量。建议起床后 1 小时内、排尿后、早餐和服药前，静坐 5 分钟测量。")
        }
        if let s = r.morningAvgSys, let di = r.morningAvgDia, week.count >= 3 {
            var line = "近 7 天晨起平均 \(Int(s))/\(Int(di)) mmHg（\(week.count) 天）"
            if let ps = r.previousAvgSys {
                let delta = s - ps
                line += abs(delta) < 3 ? "，与前一周相近。" : "，较前一周\(delta < 0 ? "下降" : "上升") \(Int(abs(delta))) mmHg。"
            } else { line += "。" }
            r.notes.append(line)
            if s >= 135 || di >= 85 {
                r.needsAttention = true
                r.notes.append("晨起家庭血压平均达到 135/85 mmHg 及以上，值得持续关注并与医生沟通。")
            }
        }
        if let rise = r.riseSys, rise >= 20 {
            r.needsAttention = true
            r.notes.append("晨起比睡前明显升高，可继续记录几天睡前与晨起血压，复诊时提供给医生。")
        }
        if p.hasCardiac, let m = r.morning, m.value > Double(p.bpTargetSys) || (m.value2 ?? 0) > Double(p.bpTargetDia) {
            r.needsAttention = true
        }
        return r
    }

    static func glucose(_ vitals: [VitalPoint], window w: DateInterval, profile p: ProfileSnapshot) -> OvernightGlucose {
        var r = OvernightGlucose(window: w)
        let g = vitals.filter { $0.kind == .glucose }.sorted { $0.time < $1.time }
        let night = g.filter { w.contains($0.time) }
        r.points = night
        r.isContinuous = night.count >= 12
        if r.isContinuous {
            let vals = night.map(\.value)
            r.min = vals.min(); r.max = vals.max(); r.mean = Stats.mean(vals)
            let step = w.duration / 60 / Double(night.count)
            r.minutesBelow = Int(Double(vals.filter { $0 < p.glucoseLow }.count) * step)
            r.minutesAbove = Int(Double(vals.filter { $0 > p.glucoseHigh }.count) * step)
            let early = night.filter { $0.time >= w.end.addingTimeInterval(-5 * 3600) && $0.time < w.end.addingTimeInterval(-3 * 3600) }.map(\.value)
            let late = night.filter { $0.time >= w.end.addingTimeInterval(-90 * 60) }.map(\.value)
            if let a = Stats.mean(early), let b = Stats.mean(late) { r.dawnRise = b - a }

            r.notes.append("夜间 \(r.min!.oneDecimal)–\(r.max!.oneDecimal) mmol/L，平均 \(r.mean!.oneDecimal)。")
            if r.minutesBelow >= 15 {
                r.lowAlert = true
                r.notes.append("夜间约 \(r.minutesBelow) 分钟低于 \(p.glucoseLow.oneDecimal) mmol/L。夜间低血糖需要重视，请查看前一天的运动、晚餐与用药情况，并与医疗团队沟通。")
            }
            if r.minutesAbove >= 60 { r.notes.append("夜间约 \(r.minutesAbove) 分钟高于 \(p.glucoseHigh.oneDecimal) mmol/L。") }
            if let rise = r.dawnRise, rise >= 1.0 { r.notes.append("清晨前血糖上升约 \(rise.oneDecimal) mmol/L。") }
            if r.minutesBelow < 15 && r.minutesAbove < 60 && (r.dawnRise ?? 0) < 1.0 { r.notes.append("夜间血糖整体平稳。") }
        } else {
            let morningStart = w.end.addingTimeInterval(-30 * 60), morningEnd = w.end.startOfDay.adding(minutes: 11 * 60)
            r.fasting = g.first { $0.time >= morningStart && $0.time <= morningEnd && [.fasting, .morning, .preMeal].contains($0.context) }
            if let f = r.fasting {
                r.notes.append("空腹血糖 \(f.value.oneDecimal) mmol/L。")
                if f.value < p.glucoseLow { r.lowAlert = true; r.notes.append("晨起血糖偏低，请按照护计划处理并复测。") }
            } else if p.hasDiabetes {
                r.notes.append("今晨尚未记录空腹血糖。佩戴 CGM 可以看到夜间完整的波动趋势。")
            }
        }
        return r
    }

    static func breathing(today: DayData?, history: [DayData], profile p: ProfileSnapshot) -> OvernightBreathing {
        var r = OvernightBreathing()
        guard let t = today else { return r }
        r.snoring = t.snoring; r.gasping = t.gasping; r.witnessed = t.witnessedApnea
        r.spo2Min = t.spo2Min
        r.disturbances = t.breathingDisturbances
        r.disturbancesNorm = Stats.mean(history.suffix(30).compactMap(\.breathingDisturbances))
        if p.apneaStatus == .diagnosed && p.apneaTreatment == .cpap { r.cpapHours = t.cpapHours; r.cpapTarget = p.cpapTargetHours }

        var cues: [String] = []
        if t.snoring { cues.append("打鼾") }
        if t.gasping { cues.append("憋醒") }
        if t.witnessedApnea { cues.append("被观察到呼吸暂停") }
        if let s = t.spo2Min, s < 88 { cues.append("最低血氧 \(Int(s))%") }
        if let d = r.disturbances, let n = r.disturbancesNorm, n > 0, d > n * 1.5 { cues.append("呼吸紊乱高于平时") }
        if cues.isEmpty {
            r.notes.append("昨夜未记录到明显的睡眠呼吸线索。")
        } else {
            r.notes.append("昨夜线索：\(cues.joined(separator: "、"))。")
            r.needsAttention = t.gasping || t.witnessedApnea || (t.spo2Min ?? 100) < 88
            if t.hadAlcohol || history.last?.hadAlcohol == true {
                r.notes.append("饮酒会加重打鼾与夜间呼吸问题。")
            }
        }
        if let h = r.cpapHours, let target = r.cpapTarget {
            r.notes.append(h >= target ? "CPAP 使用 \(h.oneDecimal) 小时，达到目标。" : "CPAP 使用 \(h.oneDecimal) 小时，低于目标 \(Int(target)) 小时。")
            if h < target { r.needsAttention = true }
        } else if p.apneaStatus == .diagnosed && p.apneaTreatment == .cpap {
            r.notes.append("记得在晨起感受中记录昨夜 CPAP 使用时长。")
        }
        return r
    }
}

// MARK: - Body Readiness → today's arrangements

struct ReadinessGuidance: Equatable {
    var exercise: String
    var load: String
    var recovery: String
    /// Two-to-six character versions for compact display.
    var exerciseShort: String = ""
    var loadShort: String = ""
    var recoveryShort: String = ""
}

extension ReadinessEngine {
    /// Turns the readiness result into the three arrangements the day is built on:
    /// 运动安排、负荷调整、恢复安排.
    static func guidance(_ r: ReadinessResult, profile p: ProfileSnapshot) -> ReadinessGuidance {
        guard r.score != nil else {
            return ReadinessGuidance(exercise: "按计划以中低强度进行，留意身体感受。",
                                     load: "暂按计划负荷，完成晨起评估后再决定是否调整。",
                                     recovery: "按时上床，保证 \((p.sleepNeedMinutes / 60).oneDecimal) 小时睡眠。",
                                     exerciseShort: "中低强度", loadShort: "暂按计划", recoveryShort: "按时上床")
        }
        let cardiac = p.cardiacLimited
        switch r.level {
        case .high:
            return ReadinessGuidance(exercise: cardiac ? "可完成计划中的低–中等强度训练。" : "可完成计划内容，包括较高强度训练。",
                                     load: "维持计划负荷，不需要额外加量。",
                                     recovery: "常规恢复：训练后补充水分与营养，按时上床。",
                                     exerciseShort: cardiac ? "中低强度" : "按计划进行", loadShort: "维持", recoveryShort: "常规恢复")
        case .moderate:
            return ReadinessGuidance(exercise: "可以按计划训练，强度课以完成质量为先。",
                                     load: "强度课减少约 1/3 的高强度部分，其余照常。",
                                     recovery: "训练后及时补充，今晚按时上床，避免熬夜。",
                                     exerciseShort: "按计划进行", loadShort: "强度课减量", recoveryShort: "按时上床")
        case .low:
            return ReadinessGuidance(exercise: "以低强度有氧、步行或灵活性训练为主，暂缓强度课。",
                                     load: "总负荷降低约 30–50%，不在之后补回。",
                                     recovery: "今晚提前 30 分钟上床，减少咖啡因与酒精。",
                                     exerciseShort: "低强度为主", loadShort: "降 30–50%", recoveryShort: "早睡 30 分钟")
        case .rest:
            return ReadinessGuidance(exercise: "以休息为主，可以轻松散步或拉伸。",
                                     load: "暂停训练负荷。",
                                     recovery: "全天以恢复为主：\(p.fluidLimited ? "" : "补水、")放松、早睡；如有不适请关注症状变化。",
                                     exerciseShort: "休息或散步", loadShort: "暂停", recoveryShort: "全天恢复")
        }
    }
}

// MARK: - 全天回顾

struct DaySummary: Equatable {
    var morning: String
    var activity: String
    var indicators: String
    var evening: String
    var arrangements: [String]
}

extension RecoveryAdvisor {
    static func daySummary(today: DayData?, readiness: ReadinessResult, trainingsDone: Int, trainingsPlanned: Int,
                           vitality: VitalityResult, readings: [VitalPoint], openEvents: Int,
                           tomorrow: [SessionSnapshot], profile p: ProfileSnapshot) -> DaySummary {
        let d = today ?? DayData(day: .app)
        let morning: String = {
            var parts: [String] = []
            if let s = readiness.score { parts.append("准备度 \(s)（\(readiness.level.label)）") } else { parts.append("准备度待评估") }
            if let sl = d.sleepMinutes { parts.append("睡眠 \((sl / 60).oneDecimal) 小时") }
            if let h = d.rhr { parts.append("静息心率 \(h.noDecimal)") }
            if let e = d.energy { parts.append("精力 \(e)/5") }
            return parts.joined(separator: " · ")
        }()
        let activity = "训练 \(trainingsDone)/\(trainingsPlanned) · 活动 \(Int(vitality.activeMinutes)) 分钟 · \(vitality.steps) 步 · 活力度 \(vitality.score)"
        let indicators: String = {
            let kinds = Dictionary(grouping: readings, by: \.kind)
            var parts: [String] = []
            if let bp = kinds[.bloodPressure]?.last { parts.append("血压 \(Int(bp.value))/\(Int(bp.value2 ?? 0))") }
            if let g = kinds[.glucose], !g.isEmpty {
                parts.append(g.count >= 24 ? "血糖均值 \(Stats.mean(g.map(\.value))!.oneDecimal)" : "血糖 \(g.last!.value.oneDecimal)")
            }
            if let hr = kinds[.heartRate]?.last { parts.append("心率 \(Int(hr.value))") }
            if parts.isEmpty { parts.append("今天没有测量记录") }
            if openEvents > 0 { parts.append("\(openEvents) 项待跟进") }
            return parts.joined(separator: " · ")
        }()
        let evening: String = {
            var parts: [String] = []
            if let f = d.eveningFatigue { parts.append("疲劳 \(f)/5") }
            if let s = d.eveningSoreness { parts.append("酸痛 \(["无", "轻微", "明显", "严重"][min(3, s)])") }
            if let st = d.eveningStress { parts.append("压力 \(st)/5") }
            if d.caffeineCups > 0 { parts.append("咖啡因 \(d.caffeineCups) 杯") }
            if let b = d.plannedBedtime { parts.append("计划 \(Clock.text(b.minutesOfDay)) 上床") }
            return parts.isEmpty ? "尚未完成睡前记录" : parts.joined(separator: " · ")
        }()

        var arr: [String] = []
        let fatigue = d.eveningFatigue ?? 0, soreness = d.eveningSoreness ?? (d.soreness ?? 0), stress = d.eveningStress ?? (d.stress ?? 0)
        if let key = tomorrow.first(where: { $0.isKey && $0.status == .planned }), fatigue >= 4 || soreness >= 2 {
            arr.append("明天的「\(key.title)」先看晨起准备度，再决定是否减量。")
        }
        if soreness >= 2 { arr.append("今晚 10 分钟拉伸或放松酸痛部位，明天避免同一部位的高负荷。") }
        if d.hardSession || (readiness.level == .low && d.activeMinutes > 45) {
            arr.append("今天负荷偏高：晚餐补充蛋白质和碳水，今晚优先睡眠。")
        }
        if stress >= 4 { arr.append("压力较大：睡前 10 分钟慢呼吸或轻柔拉伸。") }
        if d.lateCaffeine(cutoff: p.caffeineCutoffHour) { arr.append("午后摄入了咖啡因，入睡可能推迟，按计划时间上床即可，不必强迫入睡。") }
        if d.hadAlcohol { arr.append("今天饮酒，明早心率偏高时会考虑这一因素\(p.fluidLimited ? "。" : "；睡前补水。")") }
        if let b = d.plannedBedtime {
            let late = Clock.nightOffset(b.minutesOfDay) - Clock.nightOffset(p.bedtimeMinutes)
            if late > 30 { arr.append("计划上床时间比目标晚 \(late) 分钟，可能影响明天的准备度。") }
        }
        if openEvents > 0 { arr.append("有 \(openEvents) 项身体指标或症状待跟进，请在「趋势 › 异常跟进」中处理。") }
        if arr.isEmpty { arr.append("今天整体平稳，按时上床即可。") }
        return DaySummary(morning: morning, activity: activity, indicators: indicators, evening: evening, arrangements: arr)
    }
}
