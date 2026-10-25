import Foundation

struct RHRPoint: Identifiable, Equatable {
    var id: Date { day }
    let day: Date
    let value: Double
    let source: RHRSource
}

struct ElevatedDay: Identifiable, Equatable {
    var id: Date { day }
    let day: Date
    let value: Double
    let delta: Double
    let tags: [ContextTag]
    let inferred: [String]
    var hasExplanation: Bool { !tags.isEmpty || !inferred.isEmpty }
}

struct RHRTrend: Equatable {
    enum ShortTerm: Equatable { case insufficient, typical(Double), spikeUp(Double), spikeDown(Double) }
    enum Sustained: Equatable { case insufficient, none, rise(Double), drop(Double) }
    enum LongTerm: Equatable { case insufficient, stable(Double), decreasing(Double), increasing(Double) }

    var points: [RHRPoint] = []
    var excludedPoints: [RHRPoint] = []
    var rolling7: [RHRPoint] = []
    var latest: RHRPoint?
    var avg7: Double?
    var avg28: Double?
    var baseline: Double?
    var personalSD: Double = 2.5
    var coverage7 = 0
    var coverage28 = 0
    var weeksWithData = 0
    var shortTerm: ShortTerm = .insufficient
    var sustained: Sustained = .insufficient
    var longTerm: LongTerm = .insufficient
    var dominantSource: RHRSource?
    var limitations: [String] = []
    var elevatedDays: [ElevatedDay] = []
    var headline: String = ""
    var interpretation: [String] = []

    var changeFromBaseline: Double? {
        guard let current = avg28 ?? avg7, let b = baseline else { return nil }
        return current - b
    }
    var hasEnoughForBaseline: Bool { points.count >= 7 }
}

enum RHRTrendAnalyzer {
    static let minBaselineDays = 7

    /// Baseline = median of the first 14 comparable mornings (needs at least 7).
    static func computeBaseline(points: [RHRPoint]) -> Double? {
        guard let first = points.first else { return nil }
        let window = points.filter { $0.day < first.day.adding(days: 14) }
        guard window.count >= minBaselineDays else { return nil }
        return Stats.median(window.map(\.value))
    }

    static func analyze(days: [DayData], profile: ProfileSnapshot, medications: [MedicationInfo]? = nil,
                        today: Date = .app) -> RHRTrend {
        var t = RHRTrend()
        let todayStart = today.startOfDay
        let byDay = Dictionary(days.map { ($0.day, $0) }, uniquingKeysWith: { a, _ in a })
        let all = days
            .filter { $0.day <= todayStart }
            .compactMap { d -> RHRPoint? in
                guard let v = d.rhr else { return nil }
                return RHRPoint(day: d.day, value: v, source: d.rhrSource ?? .device)
            }
            .sorted { $0.day < $1.day }

        guard !all.isEmpty else {
            t.headline = "还没有静息心率数据"
            t.interpretation = ["连接手表 / 手环，或每天早晨醒来后静躺 1 分钟再手动测量，连续记录约 2 周即可建立个人参照。"]
            t.limitations = ["暂无数据，无法判断趋势。"]
            return t
        }

        // 1. Comparable measurement conditions: keep the dominant source of the last 4 weeks.
        let recent = all.filter { $0.day > todayStart.adding(days: -28) }
        let pool = recent.isEmpty ? all : recent
        let counts = Dictionary(grouping: pool, by: \.source).mapValues(\.count)
        let dominant = counts.max { a, b in a.value == b.value ? a.key.rawValue > b.key.rawValue : a.value < b.value }!.key
        t.dominantSource = dominant
        t.points = all.filter { $0.source == dominant }
        t.excludedPoints = all.filter { $0.source != dominant }
        let minorShare = 1 - Double(counts[dominant] ?? 0) / Double(pool.count)
        if minorShare >= 0.15 {
            t.limitations.append("近 4 周同时有设备与手动测量的数据。为保证可比性，趋势只使用「\(dominant.label)」的数值。")
        }
        let prior = all.filter { $0.day <= todayStart.adding(days: -7) && $0.day > todayStart.adding(days: -35) }
        if prior.count >= 5 {
            let priorCounts = Dictionary(grouping: prior, by: \.source).mapValues(\.count)
            if let priorDominant = priorCounts.max(by: { $0.value == $1.value ? $0.key.rawValue > $1.key.rawValue : $0.value < $1.value })?.key, priorDominant != dominant {
                t.limitations.append("测量方式近期由「\(priorDominant.label)」变为「\(dominant.label)」，变化前后的数值不宜直接比较。")
            }
        }

        let pts = t.points
        func values(in range: ClosedRange<Date>) -> [Double] {
            pts.filter { range.contains($0.day) }.map(\.value)
        }

        // 2. Rolling 7-day mean.
        t.rolling7 = pts.map { p in
            let w = values(in: p.day.adding(days: -6)...p.day)
            return RHRPoint(day: p.day, value: Stats.mean(w) ?? p.value, source: p.source)
        }

        let last7 = values(in: todayStart.adding(days: -6)...todayStart)
        let last28 = values(in: todayStart.adding(days: -27)...todayStart)
        t.coverage7 = last7.count
        t.coverage28 = last28.count
        t.avg7 = Stats.mean(last7)
        t.avg28 = Stats.mean(last28)
        t.baseline = profile.baselineRHR ?? computeBaseline(points: pts)
        t.personalSD = min(6, max(2, Stats.sd(last28.count >= 7 ? last28 : pts.suffix(28).map(\.value)) ?? 2.5))
        t.latest = pts.last

        // 3. Short-term: is the latest morning a one-off?
        if let latest = pts.last, latest.day >= todayStart.adding(days: -1) {
            let before = values(in: latest.day.adding(days: -8)...latest.day.adding(days: -1))
            if before.count >= 4, let m = Stats.mean(before) {
                let dev = latest.value - m
                let thr = max(5, 2 * t.personalSD)
                t.shortTerm = dev >= thr ? .spikeUp(dev) : (dev <= -thr ? .spikeDown(dev) : .typical(dev))
            }
        }

        // 4. Sustained change over the last week vs the four weeks before it.
        let ref = values(in: todayStart.adding(days: -34)...todayStart.adding(days: -7))
        let refMean: Double? = ref.count >= 8 ? Stats.mean(ref) : t.baseline
        if last7.count >= 4, let r = refMean, let m7 = t.avg7 {
            let thr = max(3, t.personalSD)
            let up = last7.filter { $0 - r >= thr }.count
            let down = last7.filter { r - $0 >= thr }.count
            let need = max(4, Int((0.7 * Double(last7.count)).rounded(.up)))
            if up >= need { t.sustained = .rise(m7 - r) }
            else if down >= need { t.sustained = .drop(m7 - r) }
            else { t.sustained = .none }
        }

        // 5. Long-term: weekly means over 12 weeks.
        var weekly: [(x: Double, y: Double)] = []
        for w in 0..<12 {
            let end = todayStart.adding(days: -7 * w)
            let vals = values(in: end.adding(days: -6)...end)
            if vals.count >= 3, let m = Stats.mean(vals) { weekly.append((x: Double(11 - w), y: m)) }
        }
        t.weeksWithData = weekly.count
        if weekly.count >= 4, let slope = Stats.slope(weekly) {
            let per4 = slope * 4
            if abs(per4) < 0.75 { t.longTerm = .stable(per4) }
            else if per4 < 0 { t.longTerm = .decreasing(per4) }
            else { t.longTerm = .increasing(per4) }
        }

        // 6. Context for elevated mornings in the last 3 weeks.
        if let a28 = t.avg28 {
            let thr = max(3, t.personalSD)
            let loads = days.filter { $0.day > todayStart.adding(days: -28) }.map(\.load)
            let avgLoad = Stats.mean(loads) ?? 0
            t.elevatedDays = pts
                .filter { $0.day > todayStart.adding(days: -21) && $0.value - a28 >= thr }
                .map { p in
                    let d = byDay[p.day]
                    let prev = byDay[p.day.adding(days: -1)]
                    var tags = Set(d?.tags.filter { !$0.actsOnNextMorning } ?? [])
                    tags.formUnion(prev?.tags.filter(\.actsOnNextMorning) ?? [])
                    if d?.isIll == true { tags.insert(.illness) }
                    if prev?.hadAlcohol == true { tags.insert(.alcohol) }
                    if prev?.highStress == true { tags.insert(.highStress) }
                    if prev?.lateMeal == true { tags.insert(.lateMeal) }
                    var inferred: [String] = []
                    if let s = d?.sleepMinutes, s < profile.sleepNeedMinutes - 60 {
                        inferred.append("前一晚睡眠 \((s / 60).oneDecimal) 小时")
                    }
                    if let l = prev?.load, avgLoad > 0, l > 1.8 * avgLoad, !tags.contains(.hardTraining) {
                        inferred.append("前一天训练负荷较高")
                    }
                    return ElevatedDay(day: p.day, value: p.value, delta: p.value - a28,
                                       tags: tags.sorted { $0.rawValue < $1.rawValue }, inferred: inferred)
                }
                .reversed()
        }

        // 7. Limitations.
        if t.coverage7 < 4 {
            t.limitations.append("近 7 天仅有 \(t.coverage7) 天有效数据，短期判断参考性有限。")
        }
        if t.coverage28 < 14 {
            t.limitations.append("近 4 周有效数据 \(t.coverage28) 天（建议 ≥14 天），长期趋势需要更多数据。")
        }
        let meds = medications ?? profile.medications
        for med in meds where med.category.hrEffect != .minimal {
            if med.start > todayStart.adding(days: -28) && med.start <= todayStart {
                t.limitations.append("\(med.start.formatted(.dateTime.month().day())) 开始使用「\(med.name)」（\(med.category.hrEffect.label)），用药前后数据可比性有限，建议以用药稳定 2 周后的数值重新作为参照。")
            } else if let end = med.end, end > todayStart.adding(days: -28), end <= todayStart {
                t.limitations.append("\(end.formatted(.dateTime.month().day())) 停用「\(med.name)」，停药前后数据可比性有限。")
            }
        }
        let illDays = days.filter { $0.day > todayStart.adding(days: -7) && $0.isIll }.count
        if illDays > 0 {
            t.limitations.append("近 7 天有 \(illDays) 天记录了生病 / 不适，短期数值可能偏高，不代表训练效果变化。")
        }
        if days.contains(where: { $0.day > todayStart.adding(days: -7) && $0.tags.contains(.travel) }) {
            t.limitations.append("近期有出差 / 时差记录，作息变化可能影响数值。")
        }

        buildNarrative(&t)
        return t
    }

    private static func buildNarrative(_ t: inout RHRTrend) {
        var lines: [String] = []
        if t.baseline == nil && t.points.count < minBaselineDays {
            t.headline = "正在建立个人参照：已有 \(t.points.count) 天，还需约 \(minBaselineDays - t.points.count) 天"
            lines.append("静息心率的个体差异很大，Pulse 以你自己的数据为参照，而不是与他人比较。")
            t.interpretation = lines
            return
        }

        switch t.shortTerm {
        case .spikeUp(let d):
            lines.append("最近一次比前一周平均高 \(d.noDecimal) bpm。单次升高常与前一晚饮酒、睡眠不足、压力或身体不适有关，单独一天不代表趋势改变。")
        case .spikeDown(let d):
            lines.append("最近一次比前一周平均低 \(abs(d).noDecimal) bpm，属于单次波动；请留意测量条件是否与平时一致。")
        case .typical(let d):
            lines.append("最近一次与前一周平均相差 \(d.signedText) bpm，在你的日常波动范围内（约 ±\(t.personalSD.noDecimal) bpm）。")
        case .insufficient:
            break
        }

        switch t.sustained {
        case .rise(let d):
            lines.append("近 7 天中多数日子高于此前 4 周水平，平均高 \(d.noDecimal) bpm——这是持续变化，而非单次波动。若同时感到疲劳、睡眠差或有感染迹象，可能是恢复不足或身体不适的信号：先减少训练强度、优先睡眠；持续 1 周以上或伴随胸闷、心悸、发热，请咨询医生。")
        case .drop(let d):
            lines.append("近 7 天持续低于此前 4 周水平约 \(abs(d).noDecimal) bpm。规律有氧训练后出现这种变化通常是积极信号；若伴随头晕、乏力或新开始用药，请咨询医生。")
        case .none:
            lines.append("近 7 天没有出现持续性的升高或下降。")
        case .insufficient:
            break
        }

        switch t.longTerm {
        case .decreasing(let s):
            lines.append("近 \(t.weeksWithData) 周呈缓慢下降趋势，约每 4 周 \(s.oneDecimal) bpm。")
        case .increasing(let s):
            lines.append("近 \(t.weeksWithData) 周呈缓慢上升趋势，约每 4 周 +\(s.oneDecimal) bpm，可结合训练、睡眠、压力和用药变化一起回顾。")
        case .stable:
            lines.append("近 \(t.weeksWithData) 周整体平稳。静息心率的改善通常需要数周到数月的规律有氧运动，平稳期也很常见。")
        case .insufficient:
            lines.append("长期趋势需要至少 4 周、每周 3 天以上的数据。")
        }

        if let b = t.baseline, let change = t.changeFromBaseline, let a = t.avg28 ?? t.avg7 {
            lines.append("个人基线 \(b.noDecimal) bpm，近 4 周平均 \(a.noDecimal) bpm（\(change.signedText) bpm）。")
        }

        switch (t.sustained, t.shortTerm, t.longTerm) {
        case (.rise(let d), _, _):
            t.headline = "近一周持续高于平时约 \(d.noDecimal) bpm"
        case (_, .spikeUp(let d), _):
            t.headline = "今天偏高 \(d.noDecimal) bpm，更像单次波动"
        case (.drop(let d), _, _):
            t.headline = "近一周持续低于平时约 \(abs(d).noDecimal) bpm"
        case (_, _, .decreasing(let s)):
            t.headline = "长期缓慢下降，约每 4 周 \(s.oneDecimal) bpm"
        case (_, _, .increasing(let s)):
            t.headline = "长期略有上升，约每 4 周 +\(s.oneDecimal) bpm"
        case (_, _, .stable):
            t.headline = "整体平稳，处于你的日常波动范围"
        default:
            t.headline = "近期在日常波动范围内"
        }
        t.interpretation = lines
    }
}
