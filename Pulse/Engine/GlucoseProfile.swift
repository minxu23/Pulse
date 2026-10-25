import Foundation

// 血糖代谢画像 — the rules version. From continuous glucose and logged meals it describes how well
// glucose is controlled, which signs of reduced insulin sensitivity show in the curves, how each
// meal tends to move glucose, and what a meal like one before will probably do. Everything is
// stated as signs against common reference values, never as a diagnosis: insulin resistance is
// confirmed with blood tests (fasting glucose and insulin → HOMA-IR, OGTT, HbA1c), which the page
// names. A learned model (GlucoFM or another) can take over parts through `GlucoseMetabolismModel`
// once validated weights are available; `GlucoseModelInput.fiveMinuteGrid` already gives its input.

// MARK: - Model interface

struct GlucoseModelInput {
    /// mmol/L, any spacing.
    var glucose: [(time: Date, value: Double)]
    var meals: [MealInfo]
    var profile: ProfileSnapshot
    var now: Date

    /// The input a CGM foundation model such as GlucoFM takes: the last 24 hours on a 5-minute grid
    /// (288 points) in mg/dL, with a mask for the slots that have no reading (a 15-minute sensor fills
    /// one slot in three).
    func fiveMinuteGrid(endingAt end: Date? = nil) -> (mgdl: [Double], observed: [Bool]) {
        let stop = end ?? now, start = stop.addingTimeInterval(-24 * 3600)
        var values = [Double](repeating: 0, count: 288), seen = [Bool](repeating: false, count: 288)
        for p in glucose where p.time > start && p.time <= stop {
            let i = min(287, Int(p.time.timeIntervalSince(start) / 300))
            values[i] = p.value * 18.0
            seen[i] = true
        }
        return (values, seen)
    }
}

protocol GlucoseMetabolismModel {
    /// Shown on the page ("规则分析").
    var name: String { get }
    func profile(_ input: GlucoseModelInput) -> GlucoseProfile?
    /// `time` nil: from this meal's usual pre-meal level; otherwise from the reading at that time.
    func predict(_ input: GlucoseModelInput, kind: MealKind, carbs: Double?, at time: Date?) -> MealPrediction?
}

enum GlucoseModels {
    /// The model in use. Rules until a validated learned model is added.
    static var current: GlucoseMetabolismModel = RuleGlucoseModel()
}

// MARK: - Results

struct GlucoseProfile: Equatable {
    enum Level: Equatable { case insufficient, normal, watch, consult }
    enum Status: Equatable { case good, attention, concern, info }

    struct Indicator: Identifiable, Equatable {
        var id: String { name }
        let name: String
        let value: String
        let reference: String
        let status: Status
    }
    /// A sign seen in the curves, with what it rests on.
    struct Sign: Identifiable, Equatable {
        let id: String
        let title: String
        /// Said when the sign is not there ("饭后回落正常").
        let absent: String
        let evidence: String
        let present: Bool
        /// Present and in a range that should be checked by a doctor.
        let strong: Bool
    }
    struct MealSummary: Identifiable, Equatable {
        var id: MealKind { kind }
        let kind: MealKind
        let count: Int
        let rise: Double
        let peakMinutes: Int
        /// Minutes until back within 1 mmol/L of the pre-meal level; nil when longer than 3 hours.
        let backMinutes: Int?
        /// Average rise above the pre-meal level every 15 minutes, 0–180.
        let curve: [Double]
    }

    var level: Level
    var title: String
    var summary: String
    var hasDiabetes: Bool
    var days: Int
    var coverage: Double
    var mealsAnalysed: Int
    var indicators: [Indicator]
    var signs: [Sign]
    var meals: [MealSummary]
    var tests: String
    var by: String
}

struct MealPrediction: Equatable {
    struct Point: Equatable { let minutes: Int; let mid: Double; let low: Double; let high: Double }
    let kind: MealKind
    let start: Double
    let points: [Point]
    let basis: Int
    let peakMinutes: Int
    let backMinutes: Int?
    let message: String
    var peak: Point { points.first { $0.minutes == peakMinutes } ?? points[0] }
    static let caveat = "按你过去相似的饭后反应推算，这一餐不一定如此；不能用来计算胰岛素或药物剂量。"
}

// MARK: - Rules

/// One meal's curve: rise above the pre-meal level every 15 minutes for 3 hours.
struct MealCurve: Equatable {
    let meal: MealInfo
    let before: Double
    /// nil where no reading lies within 10 minutes.
    let rise: [Double?]
    var peak: (minutes: Int, rise: Double)? {
        rise.enumerated().compactMap { i, r in r.map { (i * 15, $0) } }.max { $0.1 < $1.1 }
    }
    /// Back within 1 mmol/L of the pre-meal level after the peak; nil when not within 3 hours.
    var backMinutes: Int? {
        guard let p = peak else { return nil }
        return rise.enumerated().first { i, r in i * 15 > p.minutes && (r ?? 9) <= 1.0 }.map { $0.offset * 15 }
    }
}

struct RuleGlucoseModel: GlucoseMetabolismModel {
    let name = "规则分析"
    static let offsets = Array(stride(from: 0, through: 180, by: 15))

    /// Readings at least every 15 minutes count as continuous.
    static func continuous(_ g: [(time: Date, value: Double)]) -> [(time: Date, value: Double)] {
        g.sorted { $0.time < $1.time }
    }

    static func curves(_ input: GlucoseModelInput) -> [MealCurve] {
        let g = continuous(input.glucose)
        func at(_ t: Date) -> Double? {
            // Nearest reading within 10 minutes.
            var best: (Double, TimeInterval)?
            for p in g where abs(p.time.timeIntervalSince(t)) <= 600 {
                let d = abs(p.time.timeIntervalSince(t))
                if best == nil || d < best!.1 { best = (p.value, d) }
            }
            return best?.0
        }
        return input.meals.filter { [.breakfast, .lunch, .dinner, .snack].contains($0.kind) && $0.time.addingTimeInterval(3 * 3600) <= input.now }
            .compactMap { m in
                let pre = g.filter { $0.time <= m.time && $0.time > m.time.addingTimeInterval(-30 * 60) }.map(\.value)
                guard let before = Stats.mean(pre) else { return nil }
                let rise = offsets.map { at(m.time.addingTimeInterval(Double($0) * 60)).map { $0 - before } }
                guard rise.compactMap({ $0 }).count >= 10 else { return nil }
                return MealCurve(meal: m, before: before, rise: rise)
            }
    }

    func profile(_ input: GlucoseModelInput) -> GlucoseProfile? {
        let p = input.profile, now = input.now
        let recent = input.glucose.filter { $0.time > now.adding(days: -14) && $0.time <= now }
        let perDay = Dictionary(grouping: recent, by: { $0.time.startOfDay }).mapValues(\.count)
        let days = perDay.values.filter { $0 >= 48 }.count
        // Over the days the sensor was worn, so a few days of CGM still count as continuous.
        let m = GlucoseAnalyzer.metrics(recent, low: p.glucoseLow, high: p.glucoseHigh, windowDays: max(3, min(14, days)), now: now)
        let diabetes = p.hasDiabetes
        let curves = Self.curves(GlucoseModelInput(glucose: recent, meals: input.meals, profile: p, now: now))
        let by = "\(name) · 近 \(days) 天 CGM · \(curves.count) 餐"
        guard m.isContinuous, days >= 3 else {
            return GlucoseProfile(level: .insufficient, title: "数据还不够", summary: "连续佩戴 CGM 3 天以上，并记录几次进餐时间，就能看到你的血糖代谢画像。",
                                  hasDiabetes: diabetes, days: days, coverage: m.coverage, mealsAnalysed: curves.count,
                                  indicators: [], signs: [], meals: [], tests: "", by: by)
        }
        let pct = { (x: Double) in "\(Int((x * 100).rounded()))%" }

        // Control: the ranges that matter differ with and without diabetes.
        let tight = recent.isEmpty ? 0 : Double(recent.filter { $0.value >= 3.9 && $0.value <= 7.8 }.count) / Double(recent.count)
        var indicators: [GlucoseProfile.Indicator] = [
            .init(name: "平均血糖", value: "\((m.mean ?? 0).oneDecimal) mmol/L",
                  reference: diabetes ? "按个人目标" : "健康成人通常约 5–6", status: diabetes ? .info : ((m.mean ?? 0) > 6.1 ? .attention : .good)),
        ]
        if diabetes {
            indicators += [
                .init(name: "目标范围内", value: pct(m.tir ?? 0), reference: "\(p.glucoseLow.oneDecimal)–\(p.glucoseHigh.oneDecimal)，常用目标 >70%",
                      status: (m.tir ?? 0) >= 0.7 ? .good : ((m.tir ?? 0) >= 0.5 ? .attention : .concern)),
                .init(name: "低于范围", value: pct(m.tbr ?? 0), reference: "常用目标 <4%", status: (m.tbr ?? 0) < 0.04 ? .good : .concern),
                .init(name: "波动（CV）", value: pct((m.cv ?? 0) / 100), reference: "≤36% 为较稳定", status: (m.cv ?? 0) <= 36 ? .good : .attention),
                .init(name: "估算糖化（GMI）", value: "\((m.gmi ?? 0).oneDecimal)%", reference: "常用目标 <7%，以化验为准",
                      status: (m.gmi ?? 0) < 7 ? .good : .attention),
            ]
        } else {
            indicators += [
                .init(name: "3.9–7.8 范围内", value: pct(tight), reference: "健康成人通常 >90%", status: tight >= 0.9 ? .good : .attention),
                .init(name: "低于 3.9", value: pct(m.tbr ?? 0), reference: "通常很少", status: (m.tbr ?? 0) < 0.04 ? .good : .attention),
                .init(name: "波动（CV）", value: pct((m.cv ?? 0) / 100), reference: "健康成人通常约 15–20%", status: .info),
                .init(name: "估算糖化（GMI）", value: "\((m.gmi ?? 0).oneDecimal)%", reference: "估算值，不能代替 HbA1c 化验", status: .info),
            ]
        }

        // Signs of reduced insulin sensitivity, each against a common reference value.
        var signs: [GlucoseProfile.Sign] = []
        let peakLine = diabetes ? 10.0 : 7.8
        if curves.count >= 3 {
            let peaks = curves.compactMap { c in c.peak.map { c.before + $0.rise } }
            let high = peaks.filter { $0 >= peakLine }.count
            let veryHigh = peaks.filter { $0 >= 11.1 }.count
            signs.append(.init(id: "peak", title: diabetes ? "饭后峰值高于 10.0" : "饭后峰值达到 7.8 以上",
                               absent: diabetes ? "饭后峰值大多在 10.0 以内" : "饭后峰值大多低于 7.8",
                               evidence: "\(curves.count) 餐里有 \(high) 餐" + (diabetes ? "（常用目标：饭后 1–2 小时 <10.0）" : "（7.8 是糖耐量检查 2 小时的分界）"),
                               present: high * 2 >= curves.count, strong: !diabetes && veryHigh >= 2))
            let slow = curves.filter { $0.backMinutes == nil }.count
            signs.append(.init(id: "slow", title: "饭后回落慢", absent: "饭后回落正常", evidence: "\(curves.count) 餐里有 \(slow) 餐 3 小时后仍比饭前高 1 mmol/L 以上",
                               present: slow * 2 >= curves.count, strong: false))
        }
        let overnight = recent.filter { (3..<6).contains($0.time.hour) }.map(\.value)
        if let night = Stats.mean(overnight) {
            let line = diabetes ? 7.2 : 5.6
            signs.append(.init(id: "fasting", title: diabetes ? "夜间到清晨偏高" : "夜间空腹水平偏高",
                               absent: diabetes ? "夜间到清晨在目标内" : "夜间空腹水平正常",
                               evidence: "凌晨 3–6 点平均 \(night.oneDecimal) mmol/L（参考：\(diabetes ? "空腹目标 4.4–7.2" : "空腹 5.6 起为偏高")）",
                               present: night >= line, strong: !diabetes && night >= 7.0))
        }
        let dawns = Self.dawnRises(recent, meals: input.meals)
        if dawns.count >= 3 {
            let risen = dawns.filter { $0 >= 1.1 }.count
            signs.append(.init(id: "dawn", title: "黎明现象", absent: "没有明显的黎明现象", evidence: "\(dawns.count) 个早晨里有 \(risen) 个，起床前比凌晨最低时高 1.1 mmol/L 以上",
                               present: risen * 2 >= dawns.count, strong: false))
        }

        // Meals by kind.
        let meals = [MealKind.breakfast, .lunch, .dinner].compactMap { k -> GlucoseProfile.MealSummary? in
            let cs = curves.filter { $0.meal.kind == k }
            guard cs.count >= 2 else { return nil }
            let curve = Self.offsets.indices.map { i in Stats.median(cs.compactMap { $0.rise[i] }) ?? 0 }
            let peakIndex = curve.indices.max { curve[$0] < curve[$1] } ?? 0
            let back = curve.indices.first { $0 > peakIndex && curve[$0] <= 1.0 }
            return .init(kind: k, count: cs.count, rise: curve[peakIndex], peakMinutes: peakIndex * 15, backMinutes: back.map { $0 * 15 }, curve: curve)
        }

        let present = signs.filter(\.present)
        let concern = indicators.contains { $0.status == .concern } || present.contains(where: \.strong)
        let level: GlucoseProfile.Level = concern ? .consult : (present.isEmpty ? .normal : .watch)
        let title: String
        let summary: String
        let tests: String
        if diabetes {
            title = switch level {
            case .consult: "有几项明显偏离目标，建议尽快和医生一起看"
            case .watch: "\(present.count) 项值得和医生一起看"
            default: "主要指标达到常用目标"
            }
            summary = present.isEmpty ? "继续保持现在的饮食、运动和用药节奏。"
                : "2 型糖尿病常伴随胰岛素抵抗。" + present.map(\.title).joined(separator: "、") + "，复诊时可以把这份画像带给医生。"
            tests = "HbA1c 复查；是否调整治疗由医生决定。"
        } else {
            title = switch level {
            case .consult: "有几项接近糖尿病范围的迹象，建议去医院查一查"
            case .watch: "有 \(present.count) 项值得留意的迹象"
            default: "未见明显的糖代谢异常迹象"
            }
            summary = present.isEmpty ? "饭后升得不高、回落也快，夜间水平正常。保持现在的饮食和活动。"
                : present.map(\.title).joined(separator: "、") + "。这可能和胰岛素敏感性下降有关，但 CGM 只能看到迹象，需要化验才能确认。"
            tests = "空腹血糖、HbA1c、空腹胰岛素（可算 HOMA-IR）；必要时做口服糖耐量试验（OGTT）。"
        }
        return GlucoseProfile(level: level, title: title, summary: summary, hasDiabetes: diabetes, days: days, coverage: m.coverage,
                              mealsAnalysed: curves.count, indicators: indicators, signs: signs, meals: meals,
                              tests: level == .normal ? "" : tests, by: by)
    }

    /// Rise from the night's lowest point (2–5 am) to the last half hour before 7 am or the first meal.
    static func dawnRises(_ g: [(time: Date, value: Double)], meals: [MealInfo]) -> [Double] {
        let days = Set(g.map(\.time.startOfDay))
        return days.sorted().compactMap { d in
            let night = g.filter { $0.time >= d.addingTimeInterval(2 * 3600) && $0.time < d.addingTimeInterval(5 * 3600) }.map(\.value)
            let firstMeal = meals.filter { $0.time.isSameDay(d) }.map(\.time).min()
            let end = min(d.addingTimeInterval(7 * 3600), firstMeal ?? .distantFuture)
            let morning = g.filter { $0.time > end.addingTimeInterval(-30 * 60) && $0.time <= end }.map(\.value)
            guard night.count >= 6, let low = night.min(), let m = Stats.mean(morning) else { return nil }
            return m - low
        }
    }

    func predict(_ input: GlucoseModelInput, kind: MealKind, carbs: Double?, at time: Date?) -> MealPrediction? {
        let all = Self.curves(input)
        var basis = all.filter { $0.meal.kind == kind }
        var scale = 1.0
        if let c = carbs {
            let near = basis.filter { $0.meal.carbs.map { abs($0 - c) <= 25 } ?? false }
            if near.count >= 3 { basis = near }
            // More carbohydrate, more rise — within limits, the person's own meals stay the guide.
            if let mean = Stats.mean(basis.compactMap(\.meal.carbs)), mean > 0 { scale = min(1.4, max(0.7, c / mean)) }
        }
        if basis.count < 3 { basis = all.count >= 4 ? all : [] }
        guard basis.count >= 3 else { return nil }

        // Starting point: the glucose now (a recent reading), or this meal's usual pre-meal level.
        let g = Self.continuous(input.glucose)
        let start = time.flatMap { t in g.last(where: { $0.time <= t && t.timeIntervalSince($0.time) <= 20 * 60 })?.value }
            ?? Stats.median(basis.map(\.before)) ?? 5.5
        let points = Self.offsets.indices.map { i -> MealPrediction.Point in
            let xs = basis.compactMap { $0.rise[i] }.map { $0 * scale }.sorted()
            let mid = Stats.median(xs) ?? 0
            let lo = xs.count >= 5 ? xs[xs.count / 5] : (xs.first ?? mid)
            let hi = xs.count >= 5 ? xs[xs.count * 4 / 5] : (xs.last ?? mid)
            // Never narrower than ±0.4: a handful of meals says less than it seems.
            return .init(minutes: Self.offsets[i], mid: start + mid, low: start + min(lo, mid - 0.4), high: start + max(hi, mid + 0.4))
        }
        let peak = points.max { $0.mid < $1.mid }!
        let back = points.first { $0.minutes > peak.minutes && $0.mid - start <= 1.0 }?.minutes
        let line = input.profile.hasDiabetes ? 10.0 : 7.8
        var message = "按你过去 \(basis.count) 次\(basis.allSatisfy { $0.meal.kind == kind } ? "相似的\(kind.label)" : "进餐")，"
            + "饭后约 \(peak.minutes) 分钟达到峰值 \(peak.low.oneDecimal)–\(peak.high.oneDecimal) mmol/L，"
            + (back.map { "约 \(Self.duration($0))回到饭前水平。" } ?? "3 小时内可能回不到饭前水平。")
        if peak.mid >= line { message += "可以试试先吃蔬菜和蛋白质、主食放最后，饭后散步 10–15 分钟。" }
        return MealPrediction(kind: kind, start: start, points: points, basis: basis.count, peakMinutes: peak.minutes,
                              backMinutes: back, message: message)
    }

    static func duration(_ minutes: Int) -> String {
        minutes % 60 == 0 ? "\(minutes / 60) 小时" : (minutes > 60 ? "\(minutes / 60) 小时 \(minutes % 60) 分钟" : "\(minutes) 分钟")
    }
}
