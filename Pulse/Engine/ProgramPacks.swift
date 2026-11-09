import Foundation

// 方案包 (三阶段计划): the five improvement packs, the main target (主靶点) each user gets in a pack, and
// which pack the baseline report recommends. Training content and 4-week goals live in PackPlanner.

/// Where the user is in the 三阶段计划.
enum ProgramPhase: String {
    case none = "", baseline, improve, summary
    var label: String {
        switch self {
        case .none: "还没开始"
        case .baseline: "基线期"
        case .improve: "改善期"
        case .summary: "总结期"
        }
    }
    /// A pack is running: its plan, main target and step targets apply (改善期 and 总结期).
    var runsPack: Bool { self == .improve || self == .summary }
}

/// The main target with where it started and where the round wants it.
struct TargetGoal: Equatable {
    var target: TargetMetric
    var baseline: Double?
    var goal: Double?
}

enum ProgramPack: String, CaseIterable, Identifiable, Codable {
    case fitness, event, cardio, metabolic, sleep
    var id: String { rawValue }
    var title: String {
        switch self {
        case .fitness: "运动能力提升"
        case .event: "关键事件准备"
        case .cardio: "心血管改善"
        case .metabolic: "代谢改善"
        case .sleep: "睡眠改善"
        }
    }
    var icon: String {
        switch self {
        case .fitness: "figure.run"
        case .event: "flag.checkered"
        case .cardio: "heart"
        case .metabolic: "flame"
        case .sleep: "bed.double"
        }
    }
    var subtitle: String {
        switch self {
        case .fitness: "提高最大摄氧量，让心肺更有劲"
        case .event: "为马拉松等比赛按阶段准备"
        case .cardio: "降低血压或静息心率"
        case .metabolic: "改善血糖、体重和体脂"
        case .sleep: "睡够 7 小时，作息更规律"
        }
    }
    /// The ability whose standing argues for this pack.
    var ability: Ability? {
        switch self {
        case .fitness: .fitness
        case .event: nil
        case .cardio: .heart
        case .metabolic: .metabolic
        case .sleep: .sleep
        }
    }
}

/// 主靶点: the one number a round is about, shown on 今日 in place of resting heart rate.
enum TargetMetric: String, Codable, CaseIterable {
    case vo2max, weeklyRunKm, homeBP, clinicBP, restingHR, cgmTIR, postMealGlucose, weight, fastingGlucose
    /// Hours asleep a night (7-night mean), and how much the time of falling asleep varies (SD in minutes).
    case sleepDuration, sleepRegularity

    var title: String {
        switch self {
        case .vo2max: "最大摄氧量"
        case .weeklyRunKm: "周跑量"
        case .homeBP: "血压"
        case .clinicBP: "血压"
        case .restingHR: "静息心率"
        case .cgmTIR: "血糖达标时间"
        case .postMealGlucose: "餐后血糖"
        case .weight: "体重"
        case .fastingGlucose: "空腹血糖"
        case .sleepDuration: "睡眠时长"
        case .sleepRegularity: "入睡时间波动"
        }
    }
    var unit: String {
        switch self {
        case .vo2max: "mL/kg/min"
        case .weeklyRunKm: "% 计划跑量"
        case .homeBP, .clinicBP: "mmHg"
        case .restingHR: "次/分"
        case .cgmTIR: "%"
        case .postMealGlucose: "% 时间高于 7.8"
        case .weight: "公斤"
        case .fastingGlucose: "mmol/L"
        case .sleepDuration: "小时"
        case .sleepRegularity: "分钟"
        }
    }
    var higherIsBetter: Bool { [.vo2max, .weeklyRunKm, .cgmTIR, .sleepDuration].contains(self) }
    /// Blood pressure, from a home monitor or from clinic and pharmacy readings.
    var isBloodPressure: Bool { self == .homeBP || self == .clinicBP }
    /// What measuring it takes, said when the round starts.
    var howToMeasure: String {
        switch self {
        case .vo2max: "每周至少 2 次 20 分钟以上的户外快走或慢跑，手表才会更新估算"
        case .weeklyRunKm: "跑步时戴着手表，距离自动记录；每周完成计划跑量的 90% 以上就算做到"
        case .homeBP: "每周至少 3 天，早晚各测 2 次；血压计同步到 Apple 健康后自动读取"
        case .clinicBP: "每周至少 2 次，在社区卫生服务中心或药店测，坐着休息 5 分钟后再测，测完记到 Pulse"
        case .restingHR: "夜里戴着手表，早上自动读取"
        case .cgmTIR, .postMealGlucose: "一直戴着 CGM，数据同步到 Apple 健康"
        case .weight: "每天早上起床、排便后空腹称"
        case .fastingGlucose: "每周至少 3 个早上测空腹血糖"
        case .sleepDuration, .sleepRegularity: "睡觉时戴着手表，并在健康 App 里打开睡眠追踪，早上自动读取"
        }
    }
}

struct PackRecommendation: Equatable, Codable {
    struct Option: Equatable, Codable {
        var pack: ProgramPack
        var reason: String
    }
    var recommended: Option
    var alternatives: [Option]
    /// Packs that can't start yet, with why.
    var blocked: [Option]
    /// A danger sign comes first: until a doctor has seen it, only the base layer.
    var doctorFirst: Bool
}

enum ProgramPacks {
    // MARK: Main target

    /// A blood-pressure problem: diagnosed hypertension, or a baseline home average at 135/85 or above.
    static func hasBPProblem(_ r: BaselineReport, _ p: ProfileSnapshot) -> Bool {
        p.conditions.contains(.hypertension) || (r.metric(.bloodPressure)?.verdict ?? .good) >= .attention
    }

    static func hasBPMonitor(_ r: BaselineReport, _ p: ProfileSnapshot) -> Bool {
        p.hasBPMonitor ?? (r.metric(.bloodPressure)?.value != nil)
    }

    static func wearsCGM(_ r: BaselineReport) -> Bool {
        guard let g = r.metric(.glucose) else { return false }
        return g.title == "血糖达标时间" || g.title == "餐后血糖"
    }

    /// The 主靶点 for this user in this pack (Docs/三阶段健康计划设计.md, 3.1).
    static func target(for pack: ProgramPack, report r: BaselineReport, profile p: ProfileSnapshot) -> TargetMetric {
        switch pack {
        case .fitness: return .vo2max
        case .event: return .weeklyRunKm
        case .cardio:
            guard hasBPProblem(r, p) else { return .restingHR }
            return hasBPMonitor(r, p) ? .homeBP : .clinicBP
        case .metabolic:
            let heavy = (r.metric(.bmi)?.value ?? 0) >= 24 || r.metric(.waist)?.verdict == .attention
            if wearsCGM(r) {
                if p.hasDiabetes { return .cgmTIR }
                // Glucose after meals already like healthy adults': with weight to lose, weight is what moves.
                return heavy && r.metric(.glucose)?.verdict == .good ? .weight : .postMealGlucose
            }
            if !heavy, p.hasDiabetes || p.conditions.contains(.prediabetes) { return .fastingGlucose }
            return .weight
        case .sleep:
            // Too little sleep first; enough sleep at irregular times: the regularity.
            return (r.metric(.sleepDuration)?.value ?? 0) < 7 ? .sleepDuration : .sleepRegularity
        }
    }

    // MARK: Which pack

    static func qualifies(_ pack: ProgramPack, _ r: BaselineReport, _ p: ProfileSnapshot) -> String? {
        switch pack {
        case .event:
            guard let race = p.race else { return p.goals.contains(.event) ? "你的目标里有赛事" : nil }
            let weeks = race.date.daysSince(r.window.end) / 7
            return (2...30).contains(weeks) ? "\(race.name.isEmpty ? "比赛" : race.name)还有约 \(weeks) 周" : nil
        case .metabolic:
            let bmi = r.metric(.bmi)?.value ?? 0
            if bmi >= 28 { return "BMI \(bmi.shortDecimal)，属于肥胖" }
            if bmi >= 24, r.metric(.waist)?.verdict == .attention { return "BMI 和腰围都超标" }
            if let g = r.metric(.glucose), (g.verdict ?? .good) >= .attention { return "\(g.title)：\(g.detail)" }
            if let a = r.metric(.hba1c), (a.verdict ?? .good) >= .fair { return "糖化血红蛋白 \(a.valueText) 偏高" }
            if r.metric(.bodyFat)?.verdict == .attention { return "体脂率在同龄人中偏高" }
            if p.hasDiabetes || p.conditions.contains(.prediabetes) { return "你记录了糖尿病或糖尿病前期" }
            return nil
        case .cardio:
            if let b = r.metric(.bloodPressure), (b.verdict ?? .good) >= .attention { return "家庭血压平均 \(b.valueText)" }
            if p.conditions.contains(.hypertension) { return "你记录了高血压" }
            if let h = r.metric(.rhr), let rank = h.rank, rank.band.isLow { return "静息心率在同龄同性别里\(rank.approx)" }
            if r.metric(.hrRecovery)?.verdict == .attention { return "运动后心率恢复偏慢" }
            if p.hasCardiac { return "你记录了心血管方面的情况" }
            return nil
        case .fitness:
            if let v = r.metric(.vo2max), let rank = v.rank, rank.band <= .lowerMid { return "最大摄氧量在同龄同性别里\(rank.approx)" }
            if p.goals.contains(.fitness) { return "你的目标里有提升运动能力" }
            return nil
        case .sleep:
            if let h = r.metric(.sleepDuration)?.value, h < 7 { return "平均每晚睡 \(h.shortDecimal) 小时，少于 7 小时" }
            if let g = r.metric(.sleepRegularity), g.verdict == .attention, let sd = g.value { return "入睡时间每天相差约 \(Int(sd.rounded())) 分钟" }
            return nil
        }
    }

    /// Why a pack can't start yet.
    static func blocker(_ pack: ProgramPack, _ r: BaselineReport, _ p: ProfileSnapshot) -> String? {
        switch pack {
        case .event:
            if p.race == nil { return "先在「专项运动」里填上比赛的名称和日期" }
            if p.cardiacLimited { return "你记录了心血管方面的情况，参加比赛前请先让医生确认" }
            return nil
        case .sleep:
            // A fixed schedule is the core of the pack; shifts set their own (倒班 has its sleep advice).
            if p.shift != nil { return "你在倒班，作息跟着排班走：这个方案按固定作息设计，倒班的睡眠安排在「我的 › 倒班 / 轮班作息」里" }
            // Breathing problems at night need a doctor first: more time in bed doesn't fix them (Docs 3.7).
            let untreated = p.apneaTreatment == .none
            if p.conditions.contains(.sleepApnea), untreated { return "睡眠呼吸暂停先治疗：请医生安排正压通气等治疗后，再来调整作息" }
            // STOP-BANG 5 or more is the self-check's 较高风险 (a sleep clinic soon); 3–4 needs more signs (AASM 2017).
            if r.metric(.breathing)?.verdict == .attention || p.apneaStatus == .suspected || (p.stopBangScore ?? 0) >= 5, untreated {
                return "夜间呼吸的线索较多：先请医生看看是不是睡眠呼吸暂停，排除或治疗后再来调整作息"
            }
            return nil
        default: return nil
        }
    }

    static func recommend(_ r: BaselineReport, profile p: ProfileSnapshot) -> PackRecommendation {
        var qualified: [(pack: ProgramPack, reason: String, score: Int)] = []
        for pack in ProgramPack.allCases {
            guard blocker(pack, r, p) == nil, let why = qualifies(pack, r, p) else { continue }
            qualified.append((pack, why, score(pack, r)))
        }
        // A race on the calendar leads; otherwise the weakest ability decides (ties: heart, metabolism, sleep, fitness).
        let order: [ProgramPack] = [.event, .cardio, .metabolic, .sleep, .fitness]
        qualified.sort { a, b in
            if (a.pack == .event) != (b.pack == .event) { return a.pack == .event }
            return a.score != b.score ? a.score > b.score : order.firstIndex(of: a.pack)! < order.firstIndex(of: b.pack)!
        }
        let first = qualified.first.map { PackRecommendation.Option(pack: $0.pack, reason: $0.reason) }
            ?? .init(pack: .fitness, reason: "各项都在中等以上，提升心肺能力能让你保持在前面")
        var alternatives = qualified.dropFirst().map { PackRecommendation.Option(pack: $0.pack, reason: $0.reason) }
        if first.pack != .fitness, !alternatives.contains(where: { $0.pack == .fitness }) {
            alternatives.append(.init(pack: .fitness, reason: "提高最大摄氧量，对心脏和代谢都有好处"))
        }
        // Anyone can pick these, unless a safety rule stops the pack (Docs 2.8).
        for pack in [ProgramPack.cardio, .metabolic, .sleep] where pack != first.pack && !alternatives.contains(where: { $0.pack == pack })
            && blocker(pack, r, p) == nil {
            alternatives.append(.init(pack: pack, reason: pack.subtitle))
        }
        let blocked = ProgramPack.allCases.compactMap { pack in blocker(pack, r, p).map { PackRecommendation.Option(pack: pack, reason: $0) } }
        return PackRecommendation(recommended: first, alternatives: alternatives, blocked: blocked, doctorFirst: !r.redFlags.isEmpty)
    }

    /// The health outcomes behind each pack (behaviours like steps or exercise minutes are what the pack
    /// changes, not what decides it).
    static let outcomes: [ProgramPack: Set<BaselineMetric.Kind>] = [
        .fitness: [.vo2max],
        .cardio: [.rhr, .bloodPressure, .hrRecovery],
        .metabolic: [.bmi, .waist, .bodyFat, .glucose, .hba1c],
        .sleep: [.sleepDuration, .sleepRegularity],
    ]

    /// How much a pack's outcomes need work: the worst verdict, then the lowest peer band.
    static func score(_ pack: ProgramPack, _ r: BaselineReport) -> Int {
        guard let kinds = outcomes[pack] else { return 0 }
        let m = r.cards.flatMap(\.metrics).filter { kinds.contains($0.kind) }
        let worst = m.compactMap(\.verdict).max()?.rawValue ?? 0
        let band = m.compactMap { $0.rank?.band }.min()?.rawValue ?? 5
        return worst * 10 + (5 - band)
    }
}
