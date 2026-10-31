import Foundation

// 复盘的优先事项: what matters most to this person, so the review leads with it. By default Pulse
// ranks the areas from the conditions and goals the user set and from how the last weeks went —
// an area that is struggling moves up, one that is improving moves down — and the user can put
// them in their own order. The review then orders its numbers, suggestions and the reflection's
// "next focus" by these priorities, and the daily review reads each day against them.

enum PriorityArea: String, CaseIterable, Identifiable, Codable {
    case rhr, sleep, activity, bloodPressure, glucose, kidney, weight, stress
    var id: String { rawValue }
    var label: String {
        switch self {
        case .rhr: "静息心率"
        case .sleep: "睡眠"
        case .activity: "运动"
        case .bloodPressure: "血压"
        case .glucose: "血糖"
        case .kidney: "肾脏"
        case .weight: "体重"
        case .stress: "压力与精力"
        }
    }
    var icon: String {
        switch self {
        case .rhr: "heart.fill"
        case .sleep: "bed.double.fill"
        case .activity: "figure.run"
        case .bloodPressure: "gauge.with.dots.needle.33percent"
        case .glucose: "drop.fill"
        case .kidney: "drop.halffull"
        case .weight: "scalemass.fill"
        case .stress: "brain.head.profile"
        }
    }
    /// The weekly number already in the review that tells how it went.
    var metricName: String? {
        switch self {
        case .rhr: "静息心率"
        case .sleep: "平均睡眠"
        case .activity: "训练完成"
        case .stress: "醒后精力"
        case .bloodPressure: "家庭血压"
        case .glucose: "血糖达标"
        case .kidney: "偏咸天数"
        case .weight: "体重"
        }
    }
    /// An answer to 「下周最想做好的一件事？」.
    var focusOption: String {
        switch self {
        case .rhr: "规律有氧，让静息心率稳住"
        case .sleep: "按时上床，睡够时长"
        case .activity: "按计划完成训练"
        case .bloodPressure: "每天早晚量血压"
        case .glucose: "饭后走一走，稳住血糖"
        case .kidney: "少盐，按医生的量吃蛋白质"
        case .weight: "每天早上同一时间称体重"
        case .stress: "每天留 10 分钟放松"
        }
    }
}

struct ReviewPriority: Identifiable, Equatable {
    let area: PriorityArea
    /// Why it is here: 「你记录了慢性肾病」「这周偏咸 3 天」.
    let reason: String
    /// Put here by the user rather than by Pulse.
    let mine: Bool
    var id: String { area.rawValue }
}

/// One line of a day read against a priority.
struct DayLine: Identifiable, Equatable {
    enum Tone: Equatable { case good, attention, neutral }
    /// Against the person's own usual level (the 4 weeks before): a value that is always out of
    /// range is a standing problem, a day that is worse than usual is news.
    enum Usual: Equatable { case better, same, worse }
    let area: PriorityArea
    let tone: Tone
    let text: String
    /// Nil without enough history, or for one-off events (a missed session): those count as worse.
    var usual: Usual? = nil
    /// Off target on every measured day for a while (`ReviewPriorities.standingRun` or more).
    var standing = false
    var id: String { area.rawValue + text }
    /// Needs attention and is not better than usual.
    var flagged: Bool { tone == .attention && usual != .better }
    /// Needs attention and is worse than usual (or has nothing to compare with).
    var worse: Bool { tone == .attention && (usual == nil || usual == .worse) }
}

enum ReviewPriorities {
    /// How much each area matters now, with the strongest reason. Conditions and goals set the
    /// base; the last weeks' data move areas up (struggling) or down (improving).
    static func scores(_ c: AgentContext) -> [PriorityArea: (score: Double, reason: String, fromData: Double)] {
        var s: [PriorityArea: [(Double, String, Bool)]] = [:]
        func add(_ a: PriorityArea, _ v: Double, _ why: String, data: Bool = false) { s[a, default: []].append((v, why, data)) }
        let p = c.profile

        // Conditions and care modules
        if p.conditions.contains(.ckd) {
            add(.kidney, 100, "你记录了慢性肾病")
            add(.bloodPressure, 60, "肾病需要把血压管好")
        }
        if let cardio = p.conditions.first(where: \.isCardiovascular) {
            add(.bloodPressure, 80, "你记录了\(cardio == .hypertension ? "高血压" : cardio.label)")
        }
        if p.conditions.contains(.heartFailure) { add(.weight, 70, "心衰需要每天称体重") }
        if let d = p.conditions.first(where: \.isDiabetes) { add(.glucose, 90, "你记录了\(d.label)") }
        if p.conditions.contains(.prediabetes) { add(.glucose, 50, "你记录了糖尿病前期") }
        if p.conditions.contains(.sleepApnea) { add(.sleep, 60, "你记录了睡眠呼吸暂停") }
        if p.fluidLimited { add(.weight, 50, "限水时要留意体重变化") }
        if p.modules.contains(.cardioCare) { add(.bloodPressure, 30, "你开启了心血管健康") }
        if p.modules.contains(.diabetesCare) { add(.glucose, 30, "你开启了血糖管理") }
        if p.modules.contains(.marathon) { add(.activity, 40, "你在准备比赛") }

        // Goals
        if p.goals.contains(.lowerRHR) { add(.rhr, 70, "你的目标：改善静息心率") }
        if p.goals.contains(.energy) { add(.sleep, 50, "你的目标：提升日常精力"); add(.stress, 35, "你的目标：提升日常精力") }
        if p.goals.contains(.fitness) { add(.activity, 60, "你的目标：提升运动能力") }
        if p.goals.contains(.event) { add(.activity, 60, "你的目标：完成运动目标") }

        // The last weeks
        if let avg = c.sleep.avgMinutes, avg < p.sleepNeedMinutes - 30 {
            add(.sleep, 30, "最近平均每晚只睡 \((avg / 60).oneDecimal) 小时", data: true)
        }
        if let h = c.adherence("plan"), h.verdict == .struggling { add(.activity, 25, "最近训练常常没练成", data: true) }
        if case .rise = c.trend.sustained { add(.rhr, 30, "静息心率最近持续偏高", data: true) }
        if c.dimension("rhr")?.status == .improved { add(.rhr, -15, "静息心率在下降", data: true) }
        if let bp = c.homeBP.overallAvg, bp.sys >= 135 || bp.dia >= 85 {
            add(.bloodPressure, 30, "最近在家量的血压平均 \(Int(bp.sys))/\(Int(bp.dia))", data: true)
        } else if let sys = c.bp.avgSys, let dia = c.bp.avgDia, c.bp.count >= 3, sys >= 135 || dia >= 85 {
            add(.bloodPressure, 25, "近 30 天血压平均 \(Int(sys))/\(Int(dia))", data: true)
        }
        if c.glucose.readings > 0, let tir = c.glucose.tir, tir < 0.7 {
            add(.glucose, 25, "血糖在目标范围内的时间只有 \(Int(tir * 100))%", data: true)
        }
        if let w = KidneyDiet.week(c.days, profile: p, now: c.now), w.saltyDays >= 3 {
            add(.kidney, 20, "这周偏咸 \(w.saltyDays) 天", data: true)
        }
        if let k = c.lab(.potassium, within: 90), LabAnalyzer.status(.potassium, k.value, profile: p).level >= .abnormal {
            add(.kidney, 30, "最近血钾 \(k.valueText)\(k.value < 3.5 ? "偏低" : "偏高")", data: true)
        }
        if LabAnalyzer.egfrTrend(c.labs)?.fast == true { add(.kidney, 30, "eGFR 下降较快", data: true) }
        if p.watchesWeight, let g = CardioAnalyzer.rapidWeightGain(c.vitals, now: c.now) {
            add(.weight, 40, "3 天内体重增加 \(g.oneDecimal) kg", data: true)
        }
        if c.recent7.filter(\.highStress).count >= 3 { add(.stress, 25, "这周有 \(c.recent7.filter(\.highStress).count) 天压力大", data: true) }

        return s.mapValues { list in
            let reason = list.max { $0.0 < $1.0 }?.1 ?? ""
            return (list.map(\.0).reduce(0, +), reason, list.filter(\.2).map(\.0).reduce(0, +))
        }
    }

    /// Areas in order: the user's own first (when set), then Pulse's ranking.
    static func ranked(_ c: AgentContext, mine: [PriorityArea] = []) -> [ReviewPriority] {
        let s = scores(c)
        let auto = s.filter { $0.value.score > 0 }.sorted { a, b in
            a.value.score != b.value.score ? a.value.score > b.value.score : PriorityArea.allCases.firstIndex(of: a.key)! < PriorityArea.allCases.firstIndex(of: b.key)!
        }.map { ReviewPriority(area: $0.key, reason: $0.value.reason, mine: false) }
        let own = mine.map { a in ReviewPriority(area: a, reason: s[a].map(\.reason) ?? "你设定的", mine: true) }
        let rest = auto.filter { a in !mine.contains(a.area) }
        let out = own + rest
        // Resting heart rate is what Pulse is built around: never an empty list.
        return out.isEmpty ? [ReviewPriority(area: .rhr, reason: "Pulse 的核心指标", mine: false)] : out
    }

    /// With the user's own order: an area their recent data says needs attention that is not
    /// among their top three — Pulse's suggestion to add it.
    static func suggestion(_ c: AgentContext, mine: [PriorityArea]) -> ReviewPriority? {
        guard !mine.isEmpty else { return nil }
        let top = Set(mine.prefix(3))
        return scores(c).filter { !top.contains($0.key) && $0.value.fromData >= 25 }
            .max { $0.value.fromData < $1.value.fromData }
            .map { ReviewPriority(area: $0.key, reason: $0.value.reason, mine: false) }
    }

    // MARK: The weekly review

    static func area(of p: CoachProposal) -> PriorityArea? {
        switch p.action {
        case .dropWeekday, .setStepsTarget: return .activity
        case .setBedtime: return .sleep
        case .startExperiment(let key, _):
            if key.hasSuffix("-sleep") { return .sleep }
            if key.hasPrefix("stress") { return .stress }
            return .rhr
        case .addTask(_, let area, _):
            switch area {
            case .sleep: return .sleep
            case .cardio: return .bloodPressure
            case .diabetes: return .glucose
            case .kidney: return .kidney
            case .training: return .activity
            case .general: return p.id.hasPrefix("task-kidney") || p.id.hasPrefix("task-salt") ? .kidney : nil
            }
        }
    }

    /// Suggestions for the priorities that the general rules do not make.
    static func proposals(_ c: AgentContext, priorities: [ReviewPriority], taskTitles: [String]) -> [CoachProposal] {
        let top = priorities.prefix(3).map(\.area)
        let p = c.profile
        var out: [CoachProposal] = []
        if top.contains(.kidney) {
            let k = c.lab(.potassium, within: 90)
            let kOff = k.map { LabAnalyzer.status(.potassium, $0.value, profile: p).level >= .abnormal } ?? false
            let fast = LabAnalyzer.egfrTrend(c.labs)?.fast == true
            if (kOff || fast), !taskTitles.contains(where: { $0.contains("肾功能") || $0.contains("血钾") }) {
                out.append(CoachProposal(id: "task-kidney", icon: "testtube.2", title: "和医生约复查肾功能和血钾",
                                         rationale: (kOff ? "最近一次血钾 \(k!.valueText) mmol/L\(k!.value < 3.5 ? "偏低" : "偏高")" : "eGFR 下降得比较快")
                                             + "，复查的时间和要不要调整治疗，需要医生来定。",
                                         action: .addTask(title: "复查肾功能和血钾", area: .general, inDays: 14), adoptLabel: "添加事项"))
            }
            if let w = KidneyDiet.week(c.days, profile: p, now: c.now), w.saltyDays >= 3,
               !taskTitles.contains(where: { $0.contains("少盐") }) {
                out.append(CoachProposal(id: "task-salt", icon: "fork.knife", title: "两周少盐：咸菜、酱料和外卖减一半",
                                         rationale: "这周记录的 \(w.days) 天里有 \(w.saltyDays) 天偏咸。盐吃多了血压难降，也会加重肾脏的负担，先从最咸的几样减起。",
                                         action: .addTask(title: "两周少盐：咸菜、酱料、外卖减一半", area: .general, inDays: 14), adoptLabel: "开始两周"))
            }
        }
        if top.contains(.bloodPressure), c.homeBP.progress < 0.5, !taskTitles.contains(where: { $0.contains("量血压") || $0.contains("家庭血压") }) {
            out.append(CoachProposal(id: "task-bp-week", icon: "gauge.with.dots.needle.33percent", title: "这周连续 7 天早晚量血压",
                                     rationale: "血压是你最在意的事之一，但最近在家量得不多。连续量 7 天、每次量 2 遍，平均值才能看出控制得怎么样。",
                                     action: .addTask(title: "连续 7 天早晚量血压", area: .cardio, inDays: 7), adoptLabel: "添加事项"))
        }
        if top.contains(.glucose), c.glucose.readings > 0, let tir = c.glucose.tir, tir < 0.7,
           !taskTitles.contains(where: { $0.contains("血糖") }) {
            out.append(CoachProposal(id: "task-glucose", icon: "drop.fill", title: "带上血糖记录和医生讨论",
                                     rationale: "近 14 天血糖在目标范围内的时间只有 \(Int(tir * 100))%（常见目标是 70% 以上）。治疗要不要调整由医生决定，带上 Pulse 的记录更容易说清楚。",
                                     action: .addTask(title: "就血糖记录咨询医生", area: .diabetes, inDays: 14), adoptLabel: "添加事项"))
        }
        return out
    }

    /// Suggestions in priority order (the rules' order within an area), at most `limit`.
    static func rank(_ proposals: [CoachProposal], by priorities: [ReviewPriority], limit: Int = 3) -> [CoachProposal] {
        guard !priorities.isEmpty else { return Array(proposals.prefix(limit)) }
        let order = priorities.map(\.area)
        func rank(_ p: CoachProposal) -> Int { area(of: p).flatMap { order.firstIndex(of: $0) } ?? order.count }
        return Array(proposals.enumerated().sorted { a, b in
            rank(a.element) != rank(b.element) ? rank(a.element) < rank(b.element) : a.offset < b.offset
        }.map(\.element).prefix(limit))
    }

    /// The week's numbers for priority areas the review does not otherwise show.
    static func weekMetrics(_ c: AgentContext, areas: [PriorityArea], weekStart ws: Date, span: Int) -> [BriefMetric] {
        let end = ws.adding(days: span), pws = ws.adding(days: -7), pend = pws.adding(days: span)
        func inRange(_ t: Date, _ a: Date, _ b: Date) -> Bool { t >= a && t < b }
        var out: [BriefMetric] = []
        for a in areas {
            switch a {
            case .bloodPressure:
                let cur = c.vitals.filter { $0.kind == .bloodPressure && inRange($0.time, ws, end) }
                let prev = c.vitals.filter { $0.kind == .bloodPressure && inRange($0.time, pws, pend) }
                guard let sys = Stats.mean(cur.map(\.value)), let dia = Stats.mean(cur.compactMap(\.value2)) else {
                    out.append(BriefMetric(name: "家庭血压", icon: a.icon, value: "—", unit: "mmHg", delta: nil, trend: .none)); continue
                }
                let ps = Stats.mean(prev.map(\.value))
                let d = ps.map { sys - $0 }
                out.append(BriefMetric(name: "家庭血压", icon: a.icon, value: "\(Int(sys.rounded()))/\(Int(dia.rounded()))", unit: "mmHg",
                                       delta: d.map { abs($0) < 2 ? "持平" : "收缩压 \($0 > 0 ? "+" : "")\(Int($0.rounded()))" },
                                       trend: d.map { abs($0) < 2 ? .flat : ($0 < 0 ? .better : .worse) } ?? .none))
            case .glucose:
                func tir(_ a: Date, _ b: Date) -> Double? {
                    GlucoseAnalyzer.metrics(c.vitals.filter { $0.kind == .glucose && inRange($0.time, a, b) }.map { ($0.time, $0.value) },
                                            low: c.profile.glucoseLow, high: c.profile.glucoseHigh, now: b).tir
                }
                let t = tir(ws, end), pt = tir(pws, pend)
                let d = t.flatMap { v in pt.map { (v - $0) * 100 } }
                out.append(BriefMetric(name: "血糖达标", icon: a.icon, value: t.map { "\(Int($0 * 100))" } ?? "—", unit: "%",
                                       delta: d.map { abs($0) < 3 ? "持平" : "\($0 > 0 ? "+" : "")\(Int($0.rounded()))%" },
                                       trend: d.map { abs($0) < 3 ? .flat : ($0 > 0 ? .better : .worse) } ?? .none))
            case .kidney:
                let cur = c.days.filter { inRange($0.day, ws, end) && $0.nutrientsLogged }
                let prev = c.days.filter { inRange($0.day, pws, pend) && $0.nutrientsLogged }
                if !cur.isEmpty {
                    let n = cur.filter { KidneyDiet.salty($0, limit: c.profile.saltLimitG) }.count
                    let pn = prev.isEmpty ? nil : prev.filter { KidneyDiet.salty($0, limit: c.profile.saltLimitG) }.count
                    out.append(BriefMetric(name: "偏咸天数", icon: "fork.knife", value: "\(n)/\(cur.count)", unit: "天",
                                           delta: pn.map { $0 == n ? "持平" : "\(n - $0 > 0 ? "+" : "")\(n - $0) 天" },
                                           trend: pn.map { $0 == n ? .flat : (n < $0 ? .better : .worse) } ?? .none))
                } else if let e = LabAnalyzer.egfrSeries(c.labs).last {
                    out.append(BriefMetric(name: "eGFR", icon: a.icon, value: e.valueText, unit: "", delta: e.date.formatted(.dateTime.month().day()), trend: .none))
                }
            case .weight:
                let cur = c.vitals.filter { $0.kind == .weight && inRange($0.time, ws, end) }.max { $0.time < $1.time }
                let prev = c.vitals.filter { $0.kind == .weight && inRange($0.time, pws, pend) }.max { $0.time < $1.time }
                let d = cur.flatMap { v in prev.map { v.value - $0.value } }
                out.append(BriefMetric(name: "体重", icon: a.icon, value: cur.map { $0.value.oneDecimal } ?? "—", unit: "kg",
                                       delta: d.map { abs($0) < 0.3 ? "持平" : "\($0 > 0 ? "+" : "")\($0.oneDecimal)" }, trend: .none))
            default:
                continue
            }
        }
        return out
    }

    /// The review's numbers in priority order: the priorities' own numbers first, then the rest,
    /// `limit` in all.
    static func ordered(_ metrics: [BriefMetric], by priorities: [ReviewPriority], limit: Int = 6) -> [BriefMetric] {
        let names = priorities.compactMap(\.area.metricName)
        let first = names.compactMap { n in metrics.first { $0.name == n } }
        let rest = metrics.filter { m in !first.contains(m) }
        return Array((first + rest).prefix(limit))
    }

    // MARK: The daily review

    /// One day read against the priorities, each area that has something to say.
    static func day(_ d: DayData, context c: AgentContext, priorities: [ReviewPriority]) -> [DayLine] {
        priorities.compactMap { line(for: $0.area, d, c) }
    }

    /// The person's usual level: the mean over days with a value in the `days` before `day`;
    /// nil with fewer than 5 such days.
    private static func usual(before day: Date, days: Int = 28, _ value: (Date) -> Double?) -> Double? {
        let xs = (1...days).compactMap { value(day.adding(days: -$0)) }
        return xs.count >= 5 ? Stats.mean(xs) : nil
    }

    private static func compared(_ v: Double, usual u: Double?, worseBy: Double, betterBy: Double, higherIsWorse: Bool = true) -> DayLine.Usual? {
        guard let u else { return nil }
        let d = higherIsWorse ? v - u : u - v
        return d >= worseBy ? .worse : (d <= -betterBy ? .better : .same)
    }

    /// Measured days in a row above the line before the daily review says so on its own, once: a
    /// usual level that has crept up still is not fine, however steady it is.
    static let standingRun = 7

    /// How many measured days in a row, back from `day`, were out of range (`out` is nil on a day
    /// without a measurement).
    private static func run(endingOn day: Date, days: Int = 60, _ out: (Date) -> Bool?) -> Int {
        var n = 0
        for i in 0..<days {
            guard let o = out(day.adding(days: -i)) else { continue }
            guard o else { break }
            n += 1
        }
        return n
    }

    /// How a blood pressure or glucose day off target ends: compared with the person's usual, except
    /// that a `severe` day is never "usual", and a run of measured days off target (`off`) says how
    /// long it has gone on instead of 「和你平时差不多」 — with the doctor once, on the day the run
    /// reaches `standingRun`, unless a run did in the four weeks before.
    private static func standing(_ cmp: DayLine.Usual?, _ vs: String, severe: Bool, on day: Date, days: String,
                                 _ off: (Date) -> Bool?) -> (text: String, usual: DayLine.Usual?, standing: Bool) {
        let streak = run(endingOn: day, off)
        guard streak >= standingRun else { return (vs, severe ? .worse : cmp, false) }
        let text = "，\(days) \(streak) 天都是这样" + (cmp == .same ? "" : vs)
        let first = streak == standingRun && !(1...28).contains { run(endingOn: day.adding(days: -$0), off) >= standingRun }
        return first ? (text + "，值得带着记录和医生谈谈", .worse, true) : (text, severe ? .worse : cmp, true)
    }

    /// Each day's home blood pressure: the mean of its readings.
    private static func bpByDay(_ c: AgentContext) -> [Date: (sys: Double, dia: Double, n: Int)] {
        Dictionary(grouping: c.vitals.filter { $0.kind == .bloodPressure }) { $0.time.startOfDay }.compactMapValues { r in
            guard let s = Stats.mean(r.map(\.value)), let d = Stats.mean(r.compactMap(\.value2)) else { return nil }
            return (s, d, r.count)
        }
    }

    /// Each day's CGM time in range, for days with a full enough trace.
    private static func cgmTIR(_ c: AgentContext) -> [Date: Double] {
        Dictionary(grouping: c.vitals.filter { $0.kind == .glucose }) { $0.time.startOfDay }.compactMapValues { g in
            guard g.count >= 24 else { return nil }
            let day = g[0].time.startOfDay
            return GlucoseAnalyzer.metrics(g.map { ($0.time, $0.value) }, low: c.profile.glucoseLow, high: c.profile.glucoseHigh, now: day.adding(days: 1)).tir
        }
    }

    static func line(for a: PriorityArea, _ d: DayData, _ c: AgentContext) -> DayLine? {
        let p = c.profile
        let next = d.day.adding(days: 1)
        let byDay = Dictionary(c.days.map { ($0.day, $0) }, uniquingKeysWith: { a, _ in a })
        switch a {
        case .rhr:
            guard let h = d.rhr else { return DayLine(area: a, tone: .neutral, text: "没有晨起心率") }
            guard let avg = c.trend.avg28 else { return DayLine(area: a, tone: .neutral, text: "\(h.noDecimal) bpm") }
            let diff = h - avg
            if diff >= 4 { return DayLine(area: a, tone: .attention, text: "\(h.noDecimal) bpm，比近 4 周平均高 \(diff.noDecimal)", usual: .worse) }
            return DayLine(area: a, tone: diff <= -1 ? .good : .neutral,
                           text: "\(h.noDecimal) bpm" + (abs(diff) < 1 ? "，和近 4 周平均差不多" : "，比近 4 周平均\(diff < 0 ? "低" : "高") \(abs(diff).noDecimal)"))
        case .sleep:
            guard let m = d.sleepMinutes else { return DayLine(area: a, tone: .neutral, text: "没有睡眠记录") }
            let need = p.sleepNeedMinutes
            let bed = d.sleepStart.map { "，\(Clock.text($0.minutesOfDay)) 入睡" } ?? ""
            let tone: DayLine.Tone = m >= need - 20 ? .good : (m < need - 60 ? .attention : .neutral)
            guard tone == .attention else {
                return DayLine(area: a, tone: tone, text: "前一晚睡了 \((m / 60).oneDecimal) 小时（需要 \((need / 60).oneDecimal)）\(bed)")
            }
            // Short nights every night are a habit to work on; one much shorter than usual is the day's news.
            let u = usual(before: d.day, days: 14) { byDay[$0]?.sleepMinutes }
            let cmp = compared(m, usual: u, worseBy: 45, betterBy: 30, higherIsWorse: false)
            let vs = cmp == .same ? "，和你平时差不多" : (cmp == .worse ? "，比你平时少睡 \(Int((u! - m).rounded())) 分钟" : "")
            return DayLine(area: a, tone: tone, text: "前一晚睡了 \((m / 60).oneDecimal) 小时（需要 \((need / 60).oneDecimal)）\(bed)\(vs)", usual: cmp)
        case .activity:
            let sessions = c.plan.filter { $0.day == d.day && $0.kind.isTraining }
            let steps = d.steps.map { "，走了 \($0.formatted()) 步" } ?? ""
            guard let s = sessions.first else { return DayLine(area: a, tone: .neutral, text: "休息日\(steps)") }
            switch s.status {
            case .done: return DayLine(area: a, tone: .good, text: "「\(s.title)」完成了\(steps)")
            case .partial: return DayLine(area: a, tone: .neutral, text: "「\(s.title)」完成了一部分\(steps)")
            case .skipped: return DayLine(area: a, tone: .attention, text: "「\(s.title)」没练成\(steps)")
            default:
                return d.day < c.logicalToday ? DayLine(area: a, tone: .attention, text: "「\(s.title)」没有记录\(steps)")
                    : DayLine(area: a, tone: .neutral, text: "计划「\(s.title)」，还没做\(steps)")
            }
        case .bloodPressure:
            let bp = bpByDay(c)
            guard let (sys, dia, n) = bp[d.day] else { return DayLine(area: a, tone: .neutral, text: "这天没量血压") }
            // Read against the person's own target (心血管健康 › 血压目标), as the other pages do.
            let (ts, td) = (Double(p.bpTargetSys), Double(p.bpTargetDia))
            let over = { (s: Double, d: Double) in s > ts || d > td }
            let sysOver = sys > ts, diaOver = dia > td
            let value = "\(n > 1 ? "平均 " : "")\(Int(sys.rounded()))/\(Int(dia.rounded())) mmHg\(n > 1 ? "（\(n) 次）" : "")"
            guard sysOver || diaOver else { return DayLine(area: a, tone: .good, text: value + "，在目标 \(p.bpTargetSys)/\(p.bpTargetDia) 以内") }
            // Compared with the person's own usual readings: the systolic, or a diastolic 4 higher.
            let uSys = usual(before: d.day) { bp[$0]?.sys }, uDia = usual(before: d.day) { bp[$0]?.dia }
            var cmp = compared(sys, usual: uSys, worseBy: 5, betterBy: 5)
            let diff = uSys.map { sys - $0 } ?? 0
            var vs = cmp == .same ? "，和你平时差不多" : (cmp == .worse ? "，比你平时高 \(Int(diff.rounded()))" : (cmp == .better ? "，比你平时低 \(Int((-diff).rounded()))" : ""))
            if cmp == .same, let uDia, dia - uDia >= 4 { cmp = .worse; vs = "，舒张压比你平时高 \(Int((dia - uDia).rounded()))" }
            // From 145/90 at home (about 160/100 at the clinic) a usual level is no excuse.
            let severe = sys >= 145 || dia >= 90
            let end = standing(cmp, vs, severe: severe, on: d.day, days: "最近量的") { bp[$0].map { over($0.sys, $0.dia) } }
            // Which number is over: 「舒张压高于目标 80」 when the systolic is within it.
            let higher = (severe ? "明显" : "") + "高于目标 "
            let what = sysOver && diaOver ? higher + "\(p.bpTargetSys)/\(p.bpTargetDia)" : (sysOver ? "收缩压" + higher + "\(p.bpTargetSys)" : "舒张压" + higher + "\(p.bpTargetDia)")
            return DayLine(area: a, tone: .attention, text: "\(value)，" + what + end.text, usual: end.usual, standing: end.standing)
        case .glucose:
            let g = c.vitals.filter { $0.kind == .glucose && $0.time >= d.day && $0.time < next }
            guard !g.isEmpty else { return DayLine(area: a, tone: .neutral, text: "这天没有血糖读数") }
            let m = GlucoseAnalyzer.metrics(g.map { ($0.time, $0.value) }, low: p.glucoseLow, high: p.glucoseHigh, now: next)
            if g.count >= 24, let tir = m.tir {
                let lows = g.contains { $0.value < p.glucoseLow }
                // Under half the day in range (the aim is over 70%): a usual level is no excuse.
                let severe = tir < 0.5
                let text = "平均 \(m.mean?.oneDecimal ?? "—") mmol/L，范围内\(severe && !lows ? "只有" : "") \(Int(tir * 100))%"
                // A low is always the day's news; time in range is compared with the person's usual.
                if lows { return DayLine(area: a, tone: .attention, text: text + "，有低于 \(p.glucoseLow.oneDecimal) 的时段", usual: .worse) }
                guard tir < 0.7 else { return DayLine(area: a, tone: .good, text: text) }
                let tirs = cgmTIR(c)
                let u = usual(before: d.day, days: 14) { tirs[$0] }
                let cmp = compared(tir, usual: u, worseBy: 0.1, betterBy: 0.1, higherIsWorse: false)
                let vs = cmp == .same ? "，和你平时差不多" : (cmp == .worse ? "，比你平时少 \(Int(((u! - tir) * 100).rounded())) 个百分点"
                    : (cmp == .better ? "，比你平时多 \(Int(((tir - u!) * 100).rounded())) 个百分点" : ""))
                let end = standing(cmp, vs, severe: severe, on: d.day, days: "最近有记录的") { tirs[$0].map { $0 < 0.7 } }
                return DayLine(area: a, tone: .attention, text: text + end.text, usual: end.usual, standing: end.standing)
            }
            let out = g.filter { $0.value < p.glucoseLow || $0.value > p.glucoseHigh }
            return DayLine(area: a, tone: out.isEmpty ? .good : .attention,
                           text: "测了 \(g.count) 次血糖\(out.isEmpty ? "，都在目标范围内" : "，\(out.count) 次不在目标范围内")")
        case .kidney:
            // Marked swelling or less urine is the day's news, ahead of the diet.
            if let sign = KidneySigns.lines(d).first(where: { $0.tone == .attention }) {
                let diet = d.nutrientsLogged ? KidneyDiet.lines(d, profile: p).first { $0.tone == .attention } : nil
                return DayLine(area: a, tone: .attention, text: sign.text + (diet.map { "；" + $0.text } ?? ""), usual: .worse)
            }
            guard d.nutrientsLogged else { return DayLine(area: a, tone: .neutral, text: "这天没记盐、蛋白质和钾") }
            let lines = KidneyDiet.lines(d, profile: p)
            let flagged = lines.filter { $0.tone == .attention }
            if flagged.isEmpty { return DayLine(area: a, tone: .good, text: lines.prefix(2).map(\.text).joined(separator: "；")) }
            // How many of salt, protein, potassium and phosphorus were off, against a usual recorded day.
            let u = usual(before: d.day) { day in
                byDay[day].flatMap { $0.nutrientsLogged ? Double(KidneyDiet.lines($0, profile: p).filter { $0.tone == .attention }.count) : nil }
            }
            let cmp = compared(Double(flagged.count), usual: u, worseBy: 1, betterBy: 1)
            return DayLine(area: a, tone: .attention,
                           text: flagged.prefix(2).map(\.text).joined(separator: "；") + (cmp == .same ? "（和你平时差不多）" : ""), usual: cmp)
        case .weight:
            let w = c.vitals.filter { $0.kind == .weight && $0.time >= d.day && $0.time < next }.max { $0.time < $1.time }
            guard let w else { return DayLine(area: a, tone: .neutral, text: "这天没称体重") }
            if p.watchesWeight, let g = CardioAnalyzer.rapidWeightGain(c.vitals.filter { $0.time < next }, now: w.time) {
                return DayLine(area: a, tone: .attention, text: "体重 \(w.value.oneDecimal) kg，3 天内增加 \(g.oneDecimal) kg", usual: .worse)
            }
            return DayLine(area: a, tone: .neutral, text: "体重 \(w.value.oneDecimal) kg")
        case .stress:
            guard d.stress != nil || d.energy != nil else { return DayLine(area: a, tone: .neutral, text: "没有记录压力和精力") }
            let parts = [d.stress.map { "压力 \($0)/5" }, d.energy.map { "醒后精力 \($0)/5" }].compactMap { $0 }
            guard d.highStress else { return DayLine(area: a, tone: .neutral, text: parts.joined(separator: "，")) }
            let u = usual(before: d.day) { byDay[$0]?.stress.map(Double.init) }
            let cmp = d.stress.flatMap { compared(Double($0), usual: u, worseBy: 1, betterBy: 1) }
            return DayLine(area: a, tone: .attention, text: parts.joined(separator: "，") + (cmp == .same ? "，和你平时差不多" : ""), usual: cmp)
        }
    }

    /// The day in one sentence, from the priorities' lines.
    static func dayHeadline(_ lines: [DayLine], isToday: Bool) -> String {
        let when = isToday ? "今天" : "这天"
        let top = Array(lines.prefix(3))
        if top.allSatisfy({ $0.tone == .neutral }) { return "\(when)关于\(top.map(\.area.label).joined(separator: "、"))的记录还不多" }
        let worse = top.filter(\.worse).map(\.area.label)
        let atUsual = top.filter { $0.tone == .attention && $0.usual == .same }
        // Off target day after day is said as such, not as 「和平时差不多」.
        let standing = atUsual.filter(\.standing).map(\.area.label), usual = atUsual.filter { !$0.standing }.map(\.area.label)
        let better = top.filter { $0.tone == .attention && $0.usual == .better }.map(\.area.label)
        if worse.isEmpty && atUsual.isEmpty && better.isEmpty { return "\(when)你最在意的几件事都还不错" }
        let rest = [standing.isEmpty ? nil : "\(standing.joined(separator: "、"))连续多天没达标",
                    usual.isEmpty ? nil : "\(usual.joined(separator: "、"))和平时差不多"].compactMap { $0 }
        if !worse.isEmpty { return "\(when)需要留意：\(worse.joined(separator: "、"))" + rest.map { "；" + $0 }.joined() }
        if !better.isEmpty { return "\(when)\(better.joined(separator: "、"))比你平时好" + rest.map { "，" + $0 }.joined() }
        if standing.isEmpty { return "\(when)\(usual.joined(separator: "、"))和你平时差不多，仍高于目标" }
        return when + rest.joined(separator: "，")
    }
}

// MARK: - The month calendar (每日回顾)

/// How a day went, for the calendar: the user's priorities first, then the morning's body state.
enum DayLevel: Int, CaseIterable, Comparable {
    case smooth, steady, mixed, watch
    static func < (a: DayLevel, b: DayLevel) -> Bool { a.rawValue < b.rawValue }
    var label: String {
        switch self {
        case .smooth: "顺利"
        case .steady: "平稳"
        case .mixed: "有起伏"
        case .watch: "需留意"
        }
    }
    /// What the level means, for the legend and VoiceOver.
    var meaning: String {
        switch self {
        case .smooth: "最在意的几件事都不错"
        case .steady: "没有明显的问题"
        case .mixed: "有一件事不太理想"
        case .watch: "有几件事需要留意"
        }
    }
    var icon: String {
        switch self {
        case .smooth: "checkmark"
        case .steady: "circle"
        case .mixed: "arrow.up.and.down"
        case .watch: "exclamationmark"
        }
    }
}

struct DayVerdict: Equatable {
    var level: DayLevel?
    var readiness: ReadinessResult?
    var lines: [DayLine]
    /// The areas that made it 有起伏 or 需留意.
    var flagged: [PriorityArea]
    var trained: Bool
}

extension ReviewPriorities {
    /// The day's level: nil when there is too little to judge. Two rules work together: the
    /// absolute one (does a priority need attention at all) and the person's own usual level (is
    /// it worse than usual). Among the top three priorities, two worse than usual — or one worse
    /// and one at its usual (still too high) level, or a morning that called for rest — make it
    /// 需留意; one worse, or two at their usual level, make it 有起伏; none needing attention, with
    /// at least two going well, makes it 顺利. A value better than usual counts in its favour.
    static func level(lines: [DayLine], readiness: ReadinessResult?) -> DayLevel? {
        let top = lines.prefix(3), rest = lines.dropFirst(3)
        let measured = lines.contains { $0.tone != .neutral } || readiness?.score != nil
        guard measured else { return nil }
        let topWorse = top.filter(\.worse).count
        let topUsual = top.filter { $0.tone == .attention && $0.usual == .same }.count
        let restWorse = rest.filter(\.worse).count
        let lowMorning = readiness?.score != nil && readiness?.level == .low
        let restMorning = readiness?.score != nil && readiness?.level == .rest
        if topWorse >= 2 || (topWorse == 1 && topUsual >= 1) || restMorning { return .watch }
        if topWorse == 1 || topUsual >= 2 || restWorse >= 2 || lowMorning { return .mixed }
        if !top.contains(where: { $0.tone == .attention }) && top.filter({ $0.tone == .good }).count >= 2 && restWorse == 0 { return .smooth }
        return .steady
    }

    /// Everything the calendar and the day page show about one day.
    static func verdict(on day: Date, context c: AgentContext, priorities: [ReviewPriority]) -> DayVerdict {
        let d = c.days.first { $0.day == day } ?? DayData(day: day)
        let history = c.days.filter { $0.day < day }
        let r = d.rhr != nil || d.hrv != nil || d.sleepMinutes != nil
            ? ReadinessEngine.evaluate(today: d, history: history, profile: c.profile) : nil
        let lines = Self.day(d, context: c, priorities: priorities)
        let flagged = lines.prefix(3).filter { $0.tone == .attention }.map(\.area)
            + lines.dropFirst(3).filter { $0.tone == .attention }.map(\.area)
        let trained = c.plan.contains { $0.day == day && $0.kind.isTraining && ($0.status == .done || $0.status == .partial) }
            || d.sessionMinutes > 0
        return DayVerdict(level: level(lines: lines, readiness: r), readiness: r?.score == nil ? nil : r, lines: lines,
                          flagged: flagged, trained: trained)
    }

    /// The month in one line: 「这个月 24 天有记录：顺利 6 天，平稳 10 天…」.
    static func monthSummary(_ levels: [DayLevel?]) -> String {
        let known = levels.compactMap { $0 }
        guard !known.isEmpty else { return "这个月还没有记录" }
        let parts = DayLevel.allCases.compactMap { l -> String? in
            let n = known.filter { $0 == l }.count
            return n > 0 ? "\(l.label) \(n) 天" : nil
        }
        return "这个月 \(known.count) 天有记录：" + parts.joined(separator: "，")
    }
}
