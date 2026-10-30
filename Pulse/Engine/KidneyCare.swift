import Foundation

// 肾脏照护: what kidney disease asks people to watch besides diet and lab results — swelling, how
// much they pass, foamy urine; painkillers that strain the kidneys; and, on dialysis, the weight
// gained between sessions. Patient-education level: Pulse points to the doctor or the dialysis
// centre, never to a dose.

/// 水肿: pressing the ankle or shin leaves a dent.
enum Edema: Int, CaseIterable, Identifiable {
    case none = 0, mild, marked
    var id: Int { rawValue }
    var label: String {
        switch self {
        case .none: "没有"
        case .mild: "轻微"
        case .marked: "明显"
        }
    }
    var detail: String {
        switch self {
        case .none: "按脚踝、小腿前面不留坑"
        case .mild: "按下去有浅坑，晚上鞋子发紧"
        case .marked: "按下去坑深、回弹慢，或者眼睑、手也肿"
        }
    }
}

/// 尿量, against the person's own usual day.
enum UrineAmount: Int, CaseIterable, Identifiable {
    case less = -1, usual = 0, more = 1
    var id: Int { rawValue }
    var label: String {
        switch self {
        case .less: "比平时少"
        case .usual: "和平时差不多"
        case .more: "比平时多"
        }
    }
}

/// The last two weeks of swelling and urine records.
struct KidneySignsSummary: Equatable {
    var days: Int
    var edemaDays: Int
    var markedDays: Int
    var lessUrineDays: Int
    var foamyDays: Int

    var text: String {
        var parts: [String] = []
        if edemaDays > 0 { parts.append("水肿 \(edemaDays) 天" + (markedDays > 0 ? "（明显 \(markedDays) 天）" : "")) }
        if lessUrineDays > 0 { parts.append("尿量偏少 \(lessUrineDays) 天") }
        if foamyDays > 0 { parts.append("泡沫尿 \(foamyDays) 天") }
        return "近 14 天记了 \(days) 天：" + (parts.isEmpty ? "没有水肿、尿量变少或泡沫尿" : parts.joined(separator: "，"))
    }
}

enum KidneySigns {
    static let places = ["脚踝", "小腿", "眼睑", "手"]

    /// Who is asked about swelling and urine: kidney disease, heart failure, a fluid limit, dialysis.
    static func relevant(_ p: ProfileSnapshot) -> Bool { p.watchesWeight }

    static func recorded(_ d: DayData) -> Bool { d.edema != nil || d.urineOutput != nil || d.foamyUrine != nil }

    /// The day as lines: swelling, urine, foam.
    static func lines(_ d: DayData) -> [NutrientLine] {
        var out: [NutrientLine] = []
        if let e = d.edema.flatMap(Edema.init) {
            let at = d.edemaPlaces.isEmpty ? "" : "（\(d.edemaPlaces.joined(separator: "、"))）"
            out.append(e == .none ? .init(tone: .good, text: "没有水肿")
                       : .init(tone: e == .marked ? .attention : .neutral, text: "水肿\(e.label)\(at)"))
        }
        if let u = d.urineOutput.flatMap(UrineAmount.init) {
            let ml = d.urineMl.map { "，约 \($0) ml" } ?? ""
            out.append(.init(tone: u == .less ? .attention : .neutral, text: "尿量\(u.label)\(ml)"))
        }
        if d.foamyUrine == true { out.append(.init(tone: .neutral, text: "泡沫尿")) }
        return out
    }

    static func summary(_ days: [DayData], now: Date, window: Int = 14) -> KidneySignsSummary? {
        let end = now.startOfDay
        let recent = days.filter { $0.day > end.adding(days: -window) && $0.day <= end && recorded($0) }
        guard !recent.isEmpty else { return nil }
        return KidneySignsSummary(days: recent.count,
                                  edemaDays: recent.filter { ($0.edema ?? 0) > 0 }.count,
                                  markedDays: recent.filter { $0.edema == Edema.marked.rawValue }.count,
                                  lessUrineDays: recent.filter { $0.urineOutput == UrineAmount.less.rawValue }.count,
                                  foamyDays: recent.filter { $0.foamyUrine == true }.count)
    }

    /// Marked swelling on two of the last three days (or once, with weight up 2 kg), or less urine on
    /// two of them: retained fluid that should not wait for the next visit. Less urine is expected
    /// on dialysis, so it is not raised there.
    static func alert(_ days: [DayData], vitals: [VitalPoint], profile p: ProfileSnapshot, now: Date) -> AlertCandidate? {
        guard relevant(p) else { return nil }
        let end = now.startOfDay
        let recent = days.filter { $0.day > end.adding(days: -3) && $0.day <= end }.sorted { $0.day < $1.day }
        let marked = recent.filter { $0.edema == Edema.marked.rawValue }
        let less = p.onDialysis ? [] : recent.filter { $0.urineOutput == UrineAmount.less.rawValue }
        let gain = p.onDialysis ? nil : CardioAnalyzer.weightGain(vitals, now: now)
        var found: [String] = []
        if marked.count >= 2 || (!marked.isEmpty && gain != nil) {
            found.append("明显水肿 \(marked.count) 天" + (gain.map { "，3 天内体重涨了 \($0.kg.oneDecimal) kg" } ?? ""))
        }
        if less.count >= 2 { found.append("尿量比平时少 \(less.count) 天") }
        guard let last = (marked + less).map(\.day).max(), !found.isEmpty else { return nil }
        let centre = p.onDialysis ? "透析中心" : "肾内科医生"
        return AlertCandidate(
            dedupeKey: "kidneySigns-\(AlertEngine.dayKey(last.weekStart))", kind: .symptom, severity: .consult,
            title: found.count > 1 ? "水肿、尿量有变化" : (marked.isEmpty ? "尿量变少" : "水肿明显"),
            detail: "最近 3 天记录：\(found.joined(separator: "；"))。身体可能存了水。",
            guidance: "1. 少吃盐，按医生定的量喝水；坐着时把腿抬高。\n2. 明早起床排尿后称体重，量一次血压。\n3. 尽快联系\(centre)，带上这几天的记录。\n4. 不要自己加用或停用利尿剂。\n如果气短、躺下喘不过气，或者几乎没有尿，请立即就医。",
            relatedDate: last)
    }

    /// One line for the language models.
    static func digest(_ days: [DayData], profile p: ProfileSnapshot, now: Date) -> String? {
        guard relevant(p), let s = summary(days, now: now) else { return nil }
        return "水肿与尿量（用户自己记的）：" + s.text
    }
}

// MARK: - Painkillers that strain the kidneys

enum KidneyMeds {
    /// NSAIDs by the names on the box: generic names and common brands.
    static let nsaids = ["布洛芬", "芬必得", "美林", "双氯芬酸", "扶他林", "萘普生", "洛索洛芬", "乐松", "塞来昔布", "西乐葆",
                         "依托考昔", "安康信", "美洛昔康", "莫比可", "吲哚美辛", "消炎痛", "尼美舒利", "酮洛芬", "氟比洛芬",
                         "ibuprofen", "diclofenac", "naproxen", "celecoxib", "NSAID"]

    static func isNSAID(_ name: String) -> Bool {
        let n = name.lowercased()
        return nsaids.contains { n.contains($0.lowercased()) }
    }

    /// Asked about painkillers: an NSAID by name, or 止痛药 / 消炎药 in general.
    static func asksAbout(_ q: String) -> Bool { isNSAID(q) || ["止痛药", "止疼药", "消炎止痛", "退烧药"].contains { q.contains($0) } }

    /// Kidneys a painkiller could strain: kidney disease, dialysis, or an eGFR under 60.
    static func atRisk(_ p: ProfileSnapshot, labs: [LabPoint] = []) -> Bool {
        p.conditions.contains(.ckd) || p.onDialysis || (LabAnalyzer.egfrSeries(labs).last.map { $0.value < 60 } ?? false)
    }

    static let caution = "布洛芬这类止痛消炎药（NSAIDs）可能让肾功能变差，还会让血钾、血压升高。你的肾脏需要保护，吃之前先问肾内科医生或药师；需要止痛、退烧时用哪种药，请他们帮你选。"
    static let general = "布洛芬这类止痛药按说明书短期用；需要经常吃，或者有胃病、高血压、肾脏问题，先问医生或药师。"
    /// Low-dose aspirin for the heart is not what this is about.
    static let aspirin = "医生开的小剂量阿司匹林（护心用）不是这一类的问题，按医生的安排吃，不要自己停。"
}

// MARK: - Dialysis

enum Dialysis {
    /// Weight gained between sessions worth a word: 4% of the dry weight, or 3 kg without one.
    static let gainPercent = 4.0
    static let gainKg = 3.0

    static func isDay(_ d: Date, _ p: ProfileSnapshot) -> Bool { p.onDialysis && p.dialysisWeekdays.contains(d.weekday) }

    /// The next session from today on (today included).
    static func next(from now: Date, _ p: ProfileSnapshot) -> Date? {
        guard p.onDialysis, !p.dialysisWeekdays.isEmpty else { return nil }
        return (0..<7).map { now.startOfDay.adding(days: $0) }.first { p.dialysisWeekdays.contains($0.weekday) }
    }

    /// 「周一、三、五」.
    static func schedule(_ p: ProfileSnapshot) -> String {
        let names = Weekday.mondayFirst.filter(p.dialysisWeekdays.contains).map(Weekday.short)
        return names.isEmpty ? "" : "周" + names.joined(separator: "、")
    }

    struct Gain: Equatable {
        let kg: Double
        /// Of the dry weight, when the doctor gave one.
        let percent: Double?
        /// 「干体重 62.0 kg」 or 「上次透析后 61.4 kg」.
        let against: String
        let latest: VitalPoint
    }

    /// The latest weight (last 3 days) against the dry weight, or else the lowest weight on the last
    /// dialysis day before it (the weight after that session).
    static func gain(_ vitals: [VitalPoint], profile p: ProfileSnapshot, now: Date) -> Gain? {
        guard p.onDialysis else { return nil }
        let weights = vitals.filter { $0.kind == .weight && $0.time <= now }
        guard let w = weights.filter({ $0.time > now.adding(days: -3) }).max(by: { $0.time < $1.time }) else { return nil }
        if let dry = p.dryWeightKg, dry > 0 {
            return Gain(kg: w.value - dry, percent: (w.value - dry) / dry * 100, against: "干体重 \(dry.oneDecimal) kg", latest: w)
        }
        let before = weights.filter { $0.time.startOfDay < w.time.startOfDay && isDay($0.time, p) }
        guard let lastDay = before.map({ $0.time.startOfDay }).max(),
              let after = before.filter({ $0.time.startOfDay == lastDay }).min(by: { $0.value < $1.value }) else { return nil }
        return Gain(kg: w.value - after.value, percent: nil, against: "上次透析后 \(after.value.oneDecimal) kg", latest: w)
    }

    static func tooMuch(_ g: Gain) -> Bool { g.percent.map { $0 >= gainPercent } ?? (g.kg >= gainKg) }

    static func alert(_ vitals: [VitalPoint], profile p: ProfileSnapshot, now: Date) -> AlertCandidate? {
        guard let g = gain(vitals, profile: p, now: now), tooMuch(g) else { return nil }
        let pct = g.percent.map { "，是干体重的 \(Int($0.rounded()))%" } ?? ""
        return AlertCandidate(
            dedupeKey: "dialysisGain-\(AlertEngine.dayKey(g.latest.time))", kind: .weightGain, severity: .consult,
            title: "两次透析之间体重涨了 \(g.kg.oneDecimal) kg",
            detail: "\(g.latest.value.oneDecimal) kg，比\(g.against)多 \(g.kg.oneDecimal) kg\(pct)。涨得多，透析时要脱的水也多，容易抽筋、血压往下掉。",
            guidance: "1. 按透析中心定的量喝水；少吃盐和咸菜，盐会让人口渴。\n2. 下次透析时告诉医护人员这个体重。\n3. 有气短、躺下喘不过气、脚肿明显，立即联系透析中心或就医。",
            relatedDate: g.latest.time, valueText: "+\(g.kg.oneDecimal) kg")
    }

    /// One line for the language models.
    static func digest(_ vitals: [VitalPoint], profile p: ProfileSnapshot, now: Date) -> String? {
        guard p.onDialysis else { return nil }
        var s = "血液透析：\(schedule(p))" + (p.dryWeightKg.map { "，干体重 \($0.oneDecimal) kg" } ?? "")
        if isDay(now, p) { s += "，今天是透析日" }
        if let g = gain(vitals, profile: p, now: now) { s += "；最近体重比\(g.against)多 \(g.kg.oneDecimal) kg" }
        return s + "。透析日不安排训练；饮水按透析中心定的量。"
    }
}
