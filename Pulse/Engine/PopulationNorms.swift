import Foundation

// Where a person sits among people of the same age and sex (三阶段计划, baseline report).
// Tables hold the P10 / P25 / P50 / P75 / P90 values of a published reference; a value between two
// knots is interpolated, one beyond P10 or P90 is extended along the same slope and capped at 1–99.
// Sources and caveats are listed in Docs/三阶段健康计划设计.md, 附录 A.

/// The six bands the report shows, always counted from the good end ("前 10%" is the best).
enum RankBand: Int, CaseIterable, Comparable {
    case bottom10, bottom25, lowerMid, upperMid, top25, top10

    static func < (a: RankBand, b: RankBand) -> Bool { a.rawValue < b.rawValue }

    /// From a "goodness" percentile (higher = better, 0–100).
    init(goodness g: Double) {
        switch g {
        case 90...: self = .top10
        case 75..<90: self = .top25
        case 50..<75: self = .upperMid
        case 25..<50: self = .lowerMid
        case 10..<25: self = .bottom25
        default: self = .bottom10
        }
    }

    var label: String {
        switch self {
        case .top10: "前 10%"
        case .top25: "前 25%"
        case .upperMid: "中上"
        case .lowerMid: "中下"
        case .bottom25: "后 25%"
        case .bottom10: "后 10%"
        }
    }
    /// Worth a closer look in the report (后 25% and below).
    var isLow: Bool { self <= .bottom25 }
}

/// A placement among peers: the percentile counted from the good end, its band and the reference used.
struct PeerRank: Equatable, Codable {
    /// 1–99, higher is better (for resting heart rate and body fat, lower values rank higher).
    let goodness: Double
    let reference: NormReference
    var band: RankBand { RankBand(goodness: goodness) }
    /// 「约前 30%」: rounded to 5, from the good end, and kept inside the band so the words and the bar agree.
    var approx: String {
        let edges: [RankBand: (lo: Int, hi: Int)] = [.top10: (5, 10), .top25: (15, 25), .upperMid: (30, 50),
                                                     .lowerMid: (50, 70), .bottom25: (75, 90), .bottom10: (95, 95)]
        let e = edges[band]!
        let top = min(e.hi, max(e.lo, Int((100 - goodness) / 5 + 0.5) * 5))
        return top <= 50 ? "约前 \(top)%" : "约后 \(100 - top)%"
    }
}

/// The population a table comes from, said in the report under each rank.
enum NormReference: String, Codable {
    case friend2022, nhanesRHR, chinaBIA2025, csepPushup, seniorFitness

    var note: String {
        switch self {
        case .friend2022: "参考美国 FRIEND 研究（2022）的跑步机实测数据。手表的估算和实测可能相差较多，排名可能偏差一档左右。"
        case .nhanesRHR: "参考美国 NHANES 调查的诊室脉搏。手表的静息心率通常比诊室测得低，所以排名可能偏好一档。"
        case .chinaBIA2025: "参考 2020 年国民体质监测的中国成人数据（多频生物电阻抗）。家用体脂秤的误差可能有好几个百分点。"
        case .csepPushup: "参考加拿大运动生理学会（CSEP）的俯卧撑分级，按五档换算成大致的排名，女性按跪姿俯卧撑。自测的姿势和节奏不同，结果会差几个。"
        case .seniorFitness: "参考美国老年人体能测试（Rikli & Jones）60 岁以上的常模，只分后 25%、中间一半和前 25% 三段。"
        }
    }
}

struct NormTable {
    /// Lower bound of each age band, ascending; the last band runs on.
    let ages: [Int]
    /// The value at each of `percentiles` for each band (P10, P25, P50, P75, P90 unless a table says otherwise).
    let men: [[Double]]
    let women: [[Double]]
    let higherIsBetter: Bool
    let reference: NormReference
    /// Where the knots sit; a table published as categories gives its own cut points.
    var percentiles: [Double] = [10, 25, 50, 75, 90]

    func knots(age: Int, sex: Sex) -> [Double] {
        let i = max(0, (ages.lastIndex { $0 <= age }) ?? 0)
        // Unspecified sex: halfway between the two tables.
        switch sex {
        case .male: return men[i]
        case .female: return women[i]
        default: return zip(men[i], women[i]).map { ($0 + $1) / 2 }
        }
    }

    /// The value's percentile among peers (0–100, in the table's own direction).
    func percentile(_ v: Double, age: Int, sex: Sex) -> Double {
        let k = knots(age: age, sex: sex)
        let ps = percentiles, n = k.count
        // Beyond the outer knots the last step continues, up to 1 and 99.
        if v <= k[0] { return max(1, ps[0] - (k[0] - v) / max(0.01, k[1] - k[0]) * (ps[1] - ps[0])) }
        if v >= k[n - 1] { return min(99, ps[n - 1] + (v - k[n - 1]) / max(0.01, k[n - 1] - k[n - 2]) * (ps[n - 1] - ps[n - 2])) }
        for j in 0..<(n - 1) where v <= k[j + 1] {
            return ps[j] + (v - k[j]) / max(0.01, k[j + 1] - k[j]) * (ps[j + 1] - ps[j])
        }
        return 50
    }

    func rank(_ v: Double, age: Int, sex: Sex) -> PeerRank {
        let p = percentile(v, age: age, sex: sex)
        return PeerRank(goodness: higherIsBetter ? p : 100 - p, reference: reference)
    }
}

extension Double {
    /// 「6.1」「7」: one decimal at most, without the tail floating point leaves after rounding.
    var shortDecimal: String {
        let s = String(format: "%.1f", self)
        return s.hasSuffix(".0") ? String(s.dropLast(2)) : s
    }
}

enum PopulationNorms {
    /// VO2max (mL/kg/min), treadmill, measured. Kaminsky et al., Mayo Clin Proc 2022 (FRIEND, 2022 standards).
    static let vo2max = NormTable(
        ages: [20, 30, 40, 50, 60, 70, 80],
        men: [[28.8, 37.3, 45.4, 52.6, 57.8], [25.0, 31.3, 38.6, 46.5, 54.3], [22.9, 28.4, 34.8, 41.8, 49.5],
              [19.2, 23.9, 29.4, 35.5, 42.7], [16.1, 19.7, 24.4, 29.9, 36.4], [13.6, 16.8, 20.6, 25.0, 29.6],
              [13.2, 15.9, 17.7, 20.9, 23.6]],
        women: [[22.2, 28.6, 35.6, 42.2, 47.3], [19.2, 23.1, 28.3, 34.5, 41.1], [17.4, 21.3, 25.9, 30.9, 37.5],
                [16.6, 19.5, 23.1, 27.3, 31.8], [13.5, 16.4, 19.4, 23.1, 27.3], [12.3, 14.8, 17.1, 20.0, 22.8],
                [11.4, 12.8, 15.1, 17.2, 19.9]],
        higherIsBetter: true, reference: .friend2022)

    /// Resting pulse (bpm), seated, clinic. Ostchega et al., NHSR No. 41, 2011 (NHANES 1999–2008).
    static let restingHR = NormTable(
        ages: [20, 40, 60, 80],
        men: [[55, 61, 69, 76, 84], [55, 61, 68, 77, 85], [54, 60, 67, 75, 84], [54, 61, 68, 78, 86]],
        women: [[60, 66, 74, 82, 89], [59, 64, 71, 79, 86], [59, 64, 70, 78, 86], [59, 64, 71, 77, 85]],
        higherIsBetter: false, reference: .nhanesRHR)

    /// Body fat (%), 8-electrode multi-frequency BIA, Chinese adults 20–79. Tu et al., Front Public Health 2025.
    static let bodyFat = NormTable(
        ages: [20, 25, 30, 35, 40, 45, 50, 55, 60, 65, 70, 75],
        men: [[13.3, 17.0, 22.2, 27.8, 32.3], [15.5, 19.7, 24.5, 29.3, 33.6], [17.1, 21.4, 25.9, 30.4, 34.5],
              [18.1, 22.4, 26.7, 31.0, 35.0], [18.6, 23.0, 27.3, 31.5, 35.5], [18.9, 23.3, 27.7, 32.1, 36.1],
              [19.0, 23.4, 28.1, 32.6, 36.7], [18.9, 23.4, 28.2, 32.9, 37.0], [18.6, 23.2, 28.4, 33.4, 37.4],
              [18.2, 22.9, 28.3, 33.5, 37.5], [17.7, 22.5, 28.1, 33.4, 37.3], [17.2, 22.0, 27.8, 33.1, 36.9]],
        women: [[16.5, 20.3, 24.7, 29.2, 33.5], [18.3, 22.1, 26.4, 30.8, 34.9], [19.9, 23.8, 27.9, 32.1, 36.1],
                [21.3, 25.1, 29.1, 33.1, 36.9], [22.5, 26.2, 30.1, 33.9, 37.7], [23.6, 27.2, 31.0, 34.7, 38.4],
                [24.4, 28.0, 31.7, 35.3, 38.9], [25.0, 28.6, 32.1, 35.7, 39.2], [25.6, 29.1, 32.6, 36.0, 39.4],
                [25.9, 29.5, 32.9, 36.2, 39.4], [26.0, 29.6, 32.9, 36.1, 39.1], [25.9, 29.5, 32.8, 35.8, 38.6]],
        higherIsBetter: false, reference: .chinaBIA2025)

    /// Push-ups to exhaustion, men full and women from the knees. CSEP fitness categories (The Canadian Physical
    /// Activity, Fitness & Lifestyle Approach, 3rd ed., 2003), as reproduced in the ACSM Guidelines: the lower
    /// bound of fair, good, very good and excellent, taken as the 20th, 40th, 60th and 80th percentiles.
    static let pushups = NormTable(
        ages: [20, 30, 40, 50, 60],
        men: [[17, 22, 29, 36], [12, 17, 22, 30], [10, 13, 17, 25], [7, 10, 13, 21], [5, 8, 11, 18]],
        women: [[10, 15, 21, 30], [8, 13, 20, 27], [5, 11, 15, 24], [2, 7, 11, 21], [2, 5, 12, 17]],
        higherIsBetter: true, reference: .csepPushup, percentiles: [20, 40, 60, 80])

    /// 30-second chair stands, 60 and over: the normal range (25th–75th percentile). Rikli & Jones, J Aging Phys
    /// Act 1999; Senior Fitness Test Manual, 2nd ed., 2013.
    static let chairStands = NormTable(
        ages: [60, 65, 70, 75, 80, 85, 90],
        men: [[14, 19], [12, 18], [12, 17], [11, 17], [10, 15], [8, 14], [7, 12]],
        women: [[12, 17], [11, 16], [10, 15], [10, 15], [9, 14], [8, 13], [4, 11]],
        higherIsBetter: true, reference: .seniorFitness, percentiles: [25, 75])

    // MARK: Fitness age

    /// FRIEND 2022 treadmill medians at the middle of each decade.
    private static let medianAnchors: [Sex: [(age: Double, vo2: Double)]] = [
        .male: [(25, 45.4), (35, 38.6), (45, 34.8), (55, 29.4), (65, 24.4), (75, 20.6), (85, 17.7)],
        .female: [(25, 35.6), (35, 28.3), (45, 25.9), (55, 23.1), (65, 19.4), (75, 17.1), (85, 15.1)],
    ]

    /// 心肺年龄: the age whose median VO2max equals this one (20–89).
    static func fitnessAge(vo2: Double, sex: Sex) -> Int {
        let a: [(age: Double, vo2: Double)]
        switch sex {
        case .male, .female: a = medianAnchors[sex]!
        default: a = zip(medianAnchors[.male]!, medianAnchors[.female]!).map { ($0.age, ($0.vo2 + $1.vo2) / 2) }
        }
        func line(_ i: Int) -> Double {
            let (p, q) = (a[i], a[i + 1])
            return p.age + (vo2 - p.vo2) / (q.vo2 - p.vo2) * (q.age - p.age)
        }
        let age: Double
        if vo2 >= a[0].vo2 { age = line(0) }
        else if vo2 <= a[a.count - 1].vo2 { age = line(a.count - 2) }
        else { age = line((0..<(a.count - 1)).first { vo2 <= a[$0].vo2 && vo2 >= a[$0 + 1].vo2 } ?? 0) }
        return Int(min(89, max(20, age)).rounded())
    }

    // MARK: Absolute bands (no defensible percentile)

    enum StepBand: Int, Comparable {
        case sedentary, low, fair, good, high
        static func < (a: StepBand, b: StepBand) -> Bool { a.rawValue < b.rawValue }
        var label: String {
            switch self {
            case .sedentary: "久坐（不到 5000 步）"
            case .low: "偏少（5000–7000 步）"
            case .fair: "中等（7000 步以上）"
            case .good: "达到你这个年龄的获益平台"
            case .high: "很活跃（12500 步以上）"
            }
        }
    }

    /// Daily steps against the dose–response evidence: risk keeps falling to ~7,000 steps and levels off at
    /// 8,000–10,000 under 60 and 6,000–8,000 from 60 (Paluch 2022; Ding 2025).
    static func stepBand(_ steps: Double, age: Int?) -> StepBand {
        if steps >= 12_500 { return .high }
        if steps >= Double(stepPlateau(age: age).lowerBound) { return .good }
        if steps >= 7000 { return .fair }
        if steps >= 5000 { return .low }
        return .sedentary
    }

    /// Where the step–mortality curve levels off for this age (the under-60 range when the age is unknown).
    static func stepPlateau(age: Int?) -> ClosedRange<Int> { (age ?? 0) >= 60 ? 6000...8000 : 8000...10_000 }

    enum BMIClass: String {
        case under, normal, over, obese
        var label: String {
            switch self {
            case .under: "偏瘦"
            case .normal: "正常"
            case .over: "超重"
            case .obese: "肥胖"
            }
        }
    }

    /// Chinese adult cut-offs, WS/T 428-2013: 18.5 / 24 / 28.
    static func bmiClass(_ bmi: Double) -> BMIClass {
        bmi >= 28 ? .obese : bmi >= 24 ? .over : bmi >= 18.5 ? .normal : .under
    }

    enum WaistClass { case normal, pre, central }

    /// Chinese adult cut-offs, WS/T 428-2013: men 85 / 90 cm, women 80 / 85 cm.
    static func waistClass(_ cm: Double, sex: Sex) -> WaistClass {
        let (pre, central): (Double, Double) = sex == .female ? (80, 85) : (85, 90)
        return cm >= central ? .central : cm >= pre ? .pre : .normal
    }
}
