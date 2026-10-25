import Foundation

// MARK: - Observed associations

struct Association: Identifiable, Equatable {
    enum Strength: Int, Comparable {
        case none, weak, moderate, strong
        static func < (a: Strength, b: Strength) -> Bool { a.rawValue < b.rawValue }
        var label: String {
            switch self {
            case .none: "未见明显差异"
            case .weak: "较弱"
            case .moderate: "中等"
            case .strong: "较明显"
            }
        }
    }
    let id: String
    let factor: String
    let icon: String
    let metric: String
    let unit: String
    let withMean: Double
    let withoutMean: Double
    let nWith: Int
    let nWithout: Int
    let effect: Double
    let higherIsWorse: Bool
    var diff: Double { withMean - withoutMean }
    var sufficient: Bool { nWith >= 4 && nWithout >= 4 }
    var strength: Strength {
        guard sufficient else { return .none }
        switch abs(effect) {
        case 0.8...: return .strong
        case 0.5..<0.8: return .moderate
        case 0.2..<0.5: return .weak
        default: return .none
        }
    }
    var unfavorable: Bool { higherIsWorse ? diff > 0 : diff < 0 }
    var sentence: String {
        guard sufficient else { return "样本不足（\(nWith) 次 vs \(nWithout) 次），暂不判断。" }
        if strength == .none { return "\(factor)前后，\(metric)未见明显差异。" }
        let dir = diff > 0 ? "高" : "低"
        let value = unit == "分" ? String(format: "%.1f", abs(diff)) : abs(diff).oneDecimal
        return "\(factor)时，\(metric)平均\(dir) \(value) \(unit)（\(nWith) 次 vs \(nWithout) 次）。"
    }
}

struct HabitAdherence: Identifiable, Equatable {
    enum Verdict { case sustained, partial, struggling, noData
        var label: String {
            switch self {
            case .sustained: "能够坚持"
            case .partial: "部分坚持"
            case .struggling: "较难坚持"
            case .noData: "数据不足"
            }
        }
    }
    let id: String
    let name: String
    let icon: String
    let rate: Double?
    let detail: String
    let suggestion: String
    var verdict: Verdict {
        guard let r = rate else { return .noData }
        return r >= 0.7 ? .sustained : (r >= 0.4 ? .partial : .struggling)
    }
}

extension HabitAdherence {
    /// "9 / 20 晚在…" → (9, 20): how often the habit was kept, out of how many.
    var kept: (ok: Int, of: Int)? {
        let n = ReviewCopy.numbers(in: detail).compactMap { Int($0) }
        return n.count >= 2 ? (n[0], n[1]) : nil
    }
}

struct PlanFitIssue: Identifiable, Equatable {
    var id: String { title }
    let title: String
    let detail: String
}

enum InsightEngine {
    /// Compares outcomes with vs without a behaviour. Morning outcomes are paired with the
    /// previous day's behaviour (lag 1). Labels are always "observed", never causal.
    static func associations(days: [DayData], profile p: ProfileSnapshot, now: Date = .app) -> [Association] {
        let window = days.filter { $0.day > now.adding(days: -120) }.sorted { $0.day < $1.day }
        let byDay = Dictionary(window.map { ($0.day, $0) }, uniquingKeysWith: { a, _ in a })
        let avgLoad = Stats.mean(window.map(\.load).filter { $0 > 0 }) ?? 0

        func lagged(_ predicate: (DayData) -> Bool?, _ outcome: (DayData) -> Double?) -> ([Double], [Double]) {
            var w: [Double] = [], wo: [Double] = []
            for d in window {
                guard let next = byDay[d.day.adding(days: 1)], let y = outcome(next), let flag = predicate(d) else { continue }
                if next.isIll || d.isIll { continue }
                if flag { w.append(y) } else { wo.append(y) }
            }
            return (w, wo)
        }
        func sameDay(_ predicate: (DayData) -> Bool?, _ outcome: (DayData) -> Double?) -> ([Double], [Double]) {
            var w: [Double] = [], wo: [Double] = []
            for d in window where !d.isIll {
                guard let y = outcome(d), let flag = predicate(d) else { continue }
                if flag { w.append(y) } else { wo.append(y) }
            }
            return (w, wo)
        }
        func make(_ id: String, _ factor: String, _ icon: String, _ metric: String, _ unit: String,
                  _ groups: ([Double], [Double]), higherIsWorse: Bool) -> Association? {
            let (w, wo) = groups
            guard !w.isEmpty, !wo.isEmpty else { return nil }
            return Association(id: id, factor: factor, icon: icon, metric: metric, unit: unit,
                               withMean: Stats.mean(w)!, withoutMean: Stats.mean(wo)!,
                               nWith: w.count, nWithout: wo.count,
                               effect: Stats.effectSize(w, wo) ?? 0, higherIsWorse: higherIsWorse)
        }

        let rhr: (DayData) -> Double? = { $0.rhr }
        let hrv: (DayData) -> Double? = { $0.hrv }
        let energy: (DayData) -> Double? = { $0.energy.map(Double.init) }
        let sleepH: (DayData) -> Double? = { $0.sleepMinutes.map { $0 / 60 } }

        let candidates: [Association?] = [
            make("alcohol-rhr", "饮酒后的次日早晨", "wineglass", "静息心率", "bpm",
                 lagged({ $0.hadAlcohol }, rhr), higherIsWorse: true),
            make("alcohol-hrv", "饮酒后的次日早晨", "wineglass", "HRV", "ms",
                 lagged({ $0.hadAlcohol }, hrv), higherIsWorse: false),
            make("shortsleep-rhr", "睡眠不足 \(Int(p.sleepNeedMinutes / 60 - 0.5)) 小时的早晨", "moon.zzz", "静息心率", "bpm",
                 sameDay({ d in d.sleepMinutes.map { $0 < p.sleepNeedMinutes - 30 } }, rhr), higherIsWorse: true),
            make("shortsleep-energy", "睡眠不足的早晨", "moon.zzz", "醒后精力", "分",
                 sameDay({ d in d.sleepMinutes.map { $0 < p.sleepNeedMinutes - 30 } }, energy), higherIsWorse: false),
            make("caffeine-sleep", "\(p.caffeineCutoffHour) 点后摄入咖啡因的当晚", "cup.and.saucer", "睡眠时长", "小时",
                 lagged({ d in d.caffeineCups > 0 ? d.lateCaffeine(cutoff: p.caffeineCutoffHour) : false }, sleepH), higherIsWorse: false),
            make("stress-rhr", "压力大的次日早晨", "brain.head.profile", "静息心率", "bpm",
                 lagged({ d in d.stress.map { _ in d.highStress } ?? (d.tags.contains(.highStress) ? true : nil) }, rhr), higherIsWorse: true),
            make("hard-rhr", "高强度训练后的次日早晨", "flame", "静息心率", "bpm",
                 lagged({ d in d.hardSession || (avgLoad > 0 && d.load > 1.8 * avgLoad) }, rhr), higherIsWorse: true),
            make("latemeal-rhr", "晚餐过晚的次日早晨", "fork.knife", "静息心率", "bpm",
                 lagged({ $0.lateMeal }, rhr), higherIsWorse: true),
            make("active-energy", "步数达标后的次日早晨", "figure.walk", "醒后精力", "分",
                 lagged({ d in d.steps.map { $0 >= p.stepsTarget } }, energy), higherIsWorse: false),
            make("regular-energy", "按时入睡（±30 分钟）的早晨", "bed.double", "醒后精力", "分",
                 sameDay({ d in d.sleepStart.map { abs(Clock.nightOffset($0.minutesOfDay) - Clock.nightOffset(p.bedtimeMinutes)) <= 30 } }, energy),
                 higherIsWorse: false),
        ]
        return candidates.compactMap { $0 }
            .sorted { ($0.sufficient ? 1 : 0, abs($0.effect)) > ($1.sufficient ? 1 : 0, abs($1.effect)) }
    }

    /// Which habits are being sustained over the last `weeks` weeks.
    static func adherence(days: [DayData], plan: [SessionSnapshot], profile p: ProfileSnapshot,
                          weeks: Int = 4, now: Date = .app) -> [HabitAdherence] {
        let start = now.startOfDay.adding(days: -7 * weeks)
        let window = days.filter { $0.day >= start && $0.day < now.startOfDay }
        var out: [HabitAdherence] = []

        let trainings = plan.filter { $0.day >= start && $0.day < now.startOfDay && $0.kind.isTraining }
        if !trainings.isEmpty {
            let score = trainings.reduce(0.0) { $0 + ($1.status == .done ? 1 : ($1.status == .partial ? 0.5 : 0)) }
            let rate = score / Double(trainings.count)
            out.append(.init(id: "plan", name: "计划运动", icon: "figure.run", rate: rate,
                             detail: "完成 \(Int(score)) / \(trainings.count) 次（部分完成计半次）",
                             suggestion: rate < 0.6 ? "完成率偏低：考虑减少每次时长、调整到更容易执行的时段，或多使用精简版。" : "节奏合适，可以按计划逐步进阶。"))
        }

        let nights = window.compactMap(\.sleepStart)
        if nights.count >= 7 {
            let ok = nights.filter { abs(Clock.nightOffset($0.minutesOfDay) - Clock.nightOffset(p.bedtimeMinutes)) <= 45 }.count
            let rate = Double(ok) / Double(nights.count)
            out.append(.init(id: "bedtime", name: "按时入睡", icon: "bed.double", rate: rate,
                             detail: "\(ok) / \(nights.count) 晚在 \(Clock.text(p.bedtimeMinutes)) ±45 分钟内入睡",
                             suggestion: rate < 0.6 ? "可以先把目标就寝时间调整为更现实的时间，再每周提前 15 分钟。" : "作息比较规律，继续保持。"))
        }

        let sleeps = window.compactMap(\.sleepMinutes)
        if sleeps.count >= 7 {
            let ok = sleeps.filter { $0 >= p.sleepNeedMinutes - 30 }.count
            let rate = Double(ok) / Double(sleeps.count)
            out.append(.init(id: "sleepdur", name: "睡眠时长", icon: "moon.zzz", rate: rate,
                             detail: "\(ok) / \(sleeps.count) 晚达到 \((p.sleepNeedMinutes / 60 - 0.5).oneDecimal) 小时以上",
                             suggestion: rate < 0.6 ? "睡眠不足是静息心率偏高的常见原因之一，优先保证睡眠时长。" : "睡眠时长基本充足。"))
        }

        var weeksOK = 0, weeksN = 0
        for w in 0..<weeks {
            let ws = start.adding(days: 7 * w)
            let wk = window.filter { $0.day >= ws && $0.day < ws.adding(days: 7) }
            guard wk.count >= 4 else { continue }
            weeksN += 1
            if wk.map(\.alcoholUnits).reduce(0, +) <= p.weeklyAlcoholLimit { weeksOK += 1 }
        }
        if weeksN > 0 {
            let rate = Double(weeksOK) / Double(weeksN)
            out.append(.init(id: "alcohol", name: "饮酒控制", icon: "wineglass", rate: rate,
                             detail: "\(weeksOK) / \(weeksN) 周在 \(p.weeklyAlcoholLimit.noDecimal) 单位以内",
                             suggestion: rate < 0.7 ? "可以先从「工作日不饮酒」开始，观察次日静息心率与睡眠的变化。" : "控制得不错。"))
        }

        let caffeineDays = window.filter { $0.caffeineCups > 0 }
        if caffeineDays.count >= 5 {
            let ok = caffeineDays.filter { !$0.lateCaffeine(cutoff: p.caffeineCutoffHour) }.count
            let rate = Double(ok) / Double(caffeineDays.count)
            out.append(.init(id: "caffeine", name: "咖啡因截止", icon: "cup.and.saucer", rate: rate,
                             detail: "\(ok) / \(caffeineDays.count) 天在 \(p.caffeineCutoffHour):00 前结束",
                             suggestion: rate < 0.6 ? "下午改为低因或无咖啡因饮品。" : "保持即可。"))
        }

        let stepDays = window.compactMap(\.steps)
        if stepDays.count >= 7 {
            let ok = stepDays.filter { $0 >= p.stepsTarget }.count
            let rate = Double(ok) / Double(stepDays.count)
            out.append(.init(id: "steps", name: "日常步数", icon: "figure.walk", rate: rate,
                             detail: "\(ok) / \(stepDays.count) 天达到 \(p.stepsTarget) 步",
                             suggestion: rate < 0.5 ? "目标可能偏高，可以先设为近期平均步数 +1000。" : "日常活动良好。"))
        }

        let checkins = window.filter(\.checkedIn).count
        let total = max(1, min(7 * weeks, now.daysSince(start)))
        out.append(.init(id: "checkin", name: "晨起记录", icon: "sun.horizon", rate: Double(checkins) / Double(total),
                         detail: "\(checkins) / \(total) 天完成晨起感受",
                         suggestion: Double(checkins) / Double(total) < 0.5 ? "晨起感受只需 20 秒，它让准备度判断更贴近你的真实状态。" : "记录习惯良好。"))
        return out
    }

    /// Arrangements that repeatedly do not happen — signals that the plan does not fit.
    /// Training weekdays that keep not happening (last 6 weeks, at least 3 sessions, half or more missed),
    /// hardest first: highest miss rate, then most misses, then week order. The proposal, the next-week
    /// plan and the long-term strategy all name the same day from this list.
    static func missedWeekdays(plan: [SessionSnapshot], now: Date = .app) -> [(weekday: Int, missed: Int, total: Int)] {
        let past = plan.filter { $0.day < now.startOfDay && $0.day >= now.adding(days: -42) && $0.kind.isTraining }
        return Dictionary(grouping: past, by: { $0.day.weekday })
            .compactMap { wd, items -> (weekday: Int, missed: Int, total: Int)? in
                let missed = items.filter { $0.status == .skipped || $0.status == .planned }.count
                return items.count >= 3 && missed * 2 >= items.count ? (wd, missed, items.count) : nil
            }
            .sorted { a, b in
                let ra = Double(a.missed) / Double(a.total), rb = Double(b.missed) / Double(b.total)
                if ra != rb { return ra > rb }
                if a.missed != b.missed { return a.missed > b.missed }
                return PlanGenerator.order(a.weekday) < PlanGenerator.order(b.weekday)
            }
    }

    static func planFit(plan: [SessionSnapshot], now: Date = .app) -> [PlanFitIssue] {
        let past = plan.filter { $0.day < now.startOfDay && $0.day >= now.adding(days: -42) && $0.kind.isTraining }
        var issues: [PlanFitIssue] = []
        for (wd, skipped, total) in missedWeekdays(plan: plan, now: now) where Double(skipped) / Double(total) >= 0.6 {
            issues.append(.init(title: "\(Weekday.name(wd))的训练常常未完成",
                                detail: "最近 6 周\(Weekday.name(wd))的 \(total) 次训练有 \(skipped) 次没练成，可以把这天换成日常活动，或者挪到更容易练的日子。"))
        }
        // Grouped dictionaries are walked in a fixed order: the result feeds cached review text.
        let byKind = Dictionary(grouping: past, by: \.kind).sorted { $0.key.rawValue < $1.key.rawValue }
        for (kind, items) in byKind where items.count >= 3 {
            let skipped = items.filter { $0.status == .skipped || $0.status == .planned }.count
            if Double(skipped) / Double(items.count) >= 0.6 {
                issues.append(.init(title: "「\(kind.label)」完成率较低",
                                    detail: "「\(kind.label)」最近 6 周 \(items.count) 次里有 \(skipped) 次没练成，可以练短一点、换个更喜欢的形式，或者跟别的训练合在一起。"))
            }
        }
        let partials = past.filter { $0.status == .partial }
        if past.count >= 6 && Double(partials.count) / Double(past.count) >= 0.4 {
            issues.append(.init(title: "计划时长可能偏长", detail: "大约 \(Int(Double(partials.count) / Double(past.count) * 100))% 的训练只练了一部分，可以把每次的时长调到实际练得完的长度。"))
        }
        return issues
    }
}

// MARK: - Multi-dimensional progress

struct ProgressDimension: Identifiable, Equatable {
    enum Status { case improved, stable, needsWork, insufficient
        var label: String {
            switch self {
            case .improved: "改善"
            case .stable: "稳定"
            case .needsWork: "待加强"
            case .insufficient: "数据积累中"
            }
        }
    }
    let id: String
    let name: String
    let icon: String
    let status: Status
    let from: String?
    let to: String?
    let detail: String
}

struct ProgressReport: Equatable {
    var dimensions: [ProgressDimension]
    var overall: String
    var spanDays: Int
}

/// Progress is judged on several dimensions so a flat heart-rate curve does not erase real
/// gains in consistency, sleep, energy and capacity.
enum ProgressEvaluator {
    static func evaluate(days: [DayData], workouts: [WorkoutPoint], trend: RHRTrend,
                         profile p: ProfileSnapshot, now: Date = .app) -> ProgressReport {
        let sorted = days.filter { $0.day <= now.startOfDay }.sorted { $0.day < $1.day }
        guard let first = sorted.first?.day else {
            return ProgressReport(dimensions: [], overall: "开始记录后，这里会从多个维度呈现你的变化。", spanDays: 0)
        }
        let span = now.daysSince(first)
        let enough = span >= 42
        let earlyEnd = first.adding(days: 28)
        let lateStart = now.startOfDay.adding(days: -27)
        let early = sorted.filter { $0.day < earlyEnd }
        let late = sorted.filter { $0.day >= lateStart }
        var dims: [ProgressDimension] = []

        // 1. Resting heart rate
        let src = trend.dominantSource
        let earlyRHR = trend.baseline ?? Stats.mean(early.filter { $0.rhrSource == src }.compactMap(\.rhr))
        if enough, let e = earlyRHR, let l = trend.avg28 {
            let d = l - e
            let status: ProgressDimension.Status = d <= -1.5 ? .improved : (d >= 1.5 ? .needsWork : .stable)
            let detail = switch status {
            case .improved: "比起始水平低 \(abs(d).oneDecimal) bpm。"
            case .needsWork: "比起始水平高 \(d.oneDecimal) bpm，可结合睡眠、压力、生病和用药背景一起看。"
            default: "与起始水平相近。静息心率通常需要数周到数月的规律有氧才会出现变化，平稳期很常见。"
            }
            dims.append(.init(id: "rhr", name: "静息心率", icon: "heart.fill", status: status,
                              from: "\(e.noDecimal) bpm", to: "\(l.noDecimal) bpm", detail: detail))
        } else {
            dims.append(.init(id: "rhr", name: "静息心率", icon: "heart.fill", status: .insufficient,
                              from: nil, to: trend.avg7.map { "\($0.noDecimal) bpm" }, detail: "需要约 6 周数据才能比较起始与当前水平。"))
        }

        // 2. Activity consistency (weekly active minutes)
        func weeklyMinutes(_ ds: [DayData]) -> [Double] {
            Dictionary(grouping: ds, by: { $0.day.weekStart }).sorted { $0.key < $1.key }.map(\.value)
                .filter { $0.count >= 5 }
                .map { $0.reduce(0) { $0 + $1.activeMinutes } }
        }
        let ew = weeklyMinutes(early), lw = weeklyMinutes(late)
        if enough, let em = Stats.mean(ew), let lm = Stats.mean(lw) {
            let lateWeeksOK = lw.filter { $0 >= 150 }.count
            let status: ProgressDimension.Status = lm >= em * 1.15 || (lateWeeksOK >= 3 && lm >= em) ? .improved : (lm < em * 0.85 ? .needsWork : .stable)
            dims.append(.init(id: "activity", name: "活动持续性", icon: "figure.walk", status: status,
                              from: "\(Int(em)) 分钟/周", to: "\(Int(lm)) 分钟/周",
                              detail: "近 4 周有 \(lateWeeksOK) 周达到 150 分钟中等强度活动。"))
        } else {
            dims.append(.init(id: "activity", name: "活动持续性", icon: "figure.walk", status: .insufficient, from: nil, to: nil, detail: "继续记录活动，满 6 周后可比较。"))
        }

        // 3. Sleep regularity
        func bedtimeSD(_ ds: [DayData]) -> Double? {
            let v = ds.compactMap(\.sleepStart).map { Double(Clock.nightOffset($0.minutesOfDay)) }
            return v.count >= 10 ? Stats.sd(v) : nil
        }
        if enough, let es = bedtimeSD(early), let ls = bedtimeSD(late) {
            let edur = Stats.mean(early.compactMap(\.sleepMinutes)) ?? 0
            let ldur = Stats.mean(late.compactMap(\.sleepMinutes)) ?? 0
            let status: ProgressDimension.Status = (ls <= es - 10 || ldur >= edur + 15) ? .improved : (ls >= es + 15 ? .needsWork : .stable)
            dims.append(.init(id: "sleep", name: "睡眠规律", icon: "bed.double.fill", status: status,
                              from: "波动 ±\(Int(es)) 分钟", to: "波动 ±\(Int(ls)) 分钟",
                              detail: "平均睡眠 \((edur / 60).oneDecimal) → \((ldur / 60).oneDecimal) 小时。"))
        } else {
            dims.append(.init(id: "sleep", name: "睡眠规律", icon: "bed.double.fill", status: .insufficient, from: nil, to: nil, detail: "需要更多睡眠数据。"))
        }

        // 4. Subjective energy
        let ee = early.compactMap(\.energy).map(Double.init), le = late.compactMap(\.energy).map(Double.init)
        if enough, ee.count >= 7, le.count >= 7, let em = Stats.mean(ee), let lm = Stats.mean(le) {
            let status: ProgressDimension.Status = lm >= em + 0.3 ? .improved : (lm <= em - 0.3 ? .needsWork : .stable)
            dims.append(.init(id: "energy", name: "主观精力", icon: "bolt.fill", status: status,
                              from: "\(em.oneDecimal) / 5", to: "\(lm.oneDecimal) / 5", detail: "来自晨起感受记录。"))
        } else {
            dims.append(.init(id: "energy", name: "主观精力", icon: "bolt.fill", status: .insufficient, from: nil, to: nil, detail: "坚持晨起感受记录后可比较。"))
        }

        // 5. Exercise capacity: VO2max, else easy-session heart rate (aerobic efficiency)
        let ev = early.compactMap(\.vo2Max), lv = late.compactMap(\.vo2Max)
        if enough, ev.count >= 2, lv.count >= 2, let em = Stats.mean(ev), let lm = Stats.mean(lv) {
            let status: ProgressDimension.Status = lm >= em + 1 ? .improved : (lm <= em - 1 ? .needsWork : .stable)
            dims.append(.init(id: "capacity", name: "运动能力", icon: "lungs.fill", status: status,
                              from: "VO₂max \(em.oneDecimal)", to: "VO₂max \(lm.oneDecimal)", detail: "设备估算的最大摄氧量。"))
        } else {
            let easy = workouts.filter { [.walk, .run, .cycle].contains($0.type) && ($0.rpe ?? $0.type.defaultRPE) <= 4 && $0.avgHR != nil }
            let eh = easy.filter { $0.start < earlyEnd }.compactMap(\.avgHR)
            let lh = easy.filter { $0.start >= lateStart }.compactMap(\.avgHR)
            if enough, eh.count >= 3, lh.count >= 3, let em = Stats.mean(eh), let lm = Stats.mean(lh) {
                let status: ProgressDimension.Status = lm <= em - 3 ? .improved : (lm >= em + 3 ? .needsWork : .stable)
                dims.append(.init(id: "capacity", name: "运动能力", icon: "lungs.fill", status: status,
                                  from: "\(Int(em)) bpm", to: "\(Int(lm)) bpm",
                                  detail: "相似轻松训练中的平均心率。同样的轻松强度下心率更低，通常意味着有氧能力提升。"))
            } else {
                dims.append(.init(id: "capacity", name: "运动能力", icon: "lungs.fill", status: .insufficient, from: nil, to: nil, detail: "需要 VO₂max 或带心率的轻松训练记录。"))
            }
        }

        let improved = dims.filter { $0.status == .improved }
        let rhrDim = dims.first { $0.id == "rhr" }
        var overall: String
        if !enough {
            overall = "已记录 \(span) 天。约 6 周后，这里会比较起始与当前的多个维度。"
        } else if rhrDim?.status != .improved && !improved.isEmpty {
            overall = "静息心率暂时变化不大，但\(improved.map(\.name).joined(separator: "、"))已经在改善——这些同样是真实的进展。静息心率往往比习惯变化更慢，请给它更多时间。"
        } else if rhrDim?.status == .improved {
            overall = "静息心率与\(improved.count - 1 > 0 ? "另外 \(improved.count - 1) 个维度" : "整体状态")都在向好的方向变化，当前的管理方式适合你。"
        } else {
            overall = "目前各维度变化不明显。可以回顾哪些安排不容易坚持，先把计划调整得更可持续。"
        }
        return ProgressReport(dimensions: dims, overall: overall, spanDays: span)
    }
}

// MARK: - Journey stage: 了解个人基础 → 改善日常行为 → 按身体状态调整 → 验证长期效果

enum JourneyStage: Int, CaseIterable, Identifiable {
    case baseline, habits, adaptive, verify
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .baseline: "了解个人基础"
        case .habits: "改善日常行为"
        case .adaptive: "按身体状态调整"
        case .verify: "验证长期效果"
        }
    }
    var icon: String {
        switch self {
        case .baseline: "person.text.rectangle"
        case .habits: "repeat"
        case .adaptive: "slider.horizontal.3"
        case .verify: "chart.line.uptrend.xyaxis"
        }
    }
    var focus: String {
        switch self {
        case .baseline: "在一致的测量条件下记录约 2 周，建立你的静息心率基线。"
        case .habits: "从可持续的运动、睡眠和恢复习惯开始，每周小步进阶。"
        case .adaptive: "每天根据准备度和实际活动调整安排，忙碌时用精简版保持节奏。"
        case .verify: "综合心率趋势、活动、睡眠、精力和运动能力，判断管理方向是否合适。"
        }
    }
}

