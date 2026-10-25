import Foundation

// Health Agent: turns the user's own records into an overall evaluation, next steps and
// answers to questions. The rules engine here is deterministic and always available; when the
// on-device language model is available it rephrases these grounded facts conversationally.
// Safety rules: no diagnosis, no medication or dose advice, emergencies → 120 first.

// MARK: - Context

struct AgentEvent: Equatable {
    var title: String
    var severity: Severity
    var date: Date
    var guidance: String
}

/// Everything the agent may talk about, computed once from the user's data.
struct AgentContext {
    var now: Date
    var name: String
    var profile: ProfileSnapshot
    var days: [DayData]
    var trend: RHRTrend
    var readiness: ReadinessResult
    var guidance: ReadinessGuidance
    var progress: ProgressReport
    var adherence: [HabitAdherence]
    var associations: [Association]
    var planFit: [PlanFitIssue]
    var sleep: SleepSummary
    var breathing: BreathingCues
    var stopBangScore: Int?
    var bp: BPSummary
    var homeBP: HomeBPStatus
    var glucose: GlucoseMetrics
    var lows: [LowEpisode]
    var load: TrainingLoadStatus
    var weekTrainingsDone: Int
    var weekTrainingsTotal: Int
    var weekActiveMinutes: Double
    var todayPlan: [SessionSnapshot]
    var tomorrow: [SessionSnapshot]
    var openEvents: [AgentEvent]
    var race: MarathonWeek?
    var raceName: String
    var raceTarget: Int?
    var racePrediction: RacePrediction?
    var targetRHR: Double? = nil
    var plan: [SessionSnapshot] = []
    var vitals: [VitalPoint] = []
    var workouts: [WorkoutPoint] = []
    /// Lab results from the reports the user entered.
    var labs: [LabPoint] = []
    /// The forecast from today on, and where it comes from ("示例天气", "Apple 天气"); empty without one.
    var weather: [DayWeather] = []
    var weatherSource = ""
    var medications: [MedicationInfo] { profile.medications.filter { $0.isActive(on: now) } }
    func weather(on day: Date) -> DayWeather? { weather.first { $0.day == day.startOfDay } }

    static func make(profile: ProfileSnapshot, name: String, days: [DayData], plan: [SessionSnapshot], workouts: [WorkoutPoint],
                     vitals: [VitalPoint], events: [AgentEvent], stopBang: [Bool], baselineSetAt: Date?, raceName: String,
                     targetRHR: Double? = nil, weather: [DayWeather] = [], weatherSource: String = "",
                     labs: [LabPoint] = [], now: Date = .app) -> AgentContext {
        // Before 5 am the night is not over: the user is still in the previous day, a record for the
        // new date has no morning in it yet, and the coming day's readiness is not known.
        let beforeWake = DayClock.isBeforeWake(now, profile)
        let logical = DayClock.logicalToday(now, profile)
        let days = beforeWake ? days.filter { $0.day < now.startOfDay } : days
        let trend = RHRTrendAnalyzer.analyze(days: days, profile: profile, today: now)
        // The day being lived has its own readiness; once its main sleep has begun, the next one is pending.
        let asleepWindow = beforeWake && now >= DayClock.window(for: logical, profile: profile).bed
        let today = days.first { $0.day == logical }
        let readiness = asleepWindow ? ReadinessResult.pending
            : ReadinessEngine.evaluate(today: today ?? DayData(day: logical), history: days.filter { $0.day < logical }, profile: profile)
        let week = plan.filter { $0.day >= logical.weekStart && $0.day < logical.weekStart.adding(days: 7) && $0.kind.isTraining }
        let race = profile.race.map { MarathonPlanner.week(profile: profile, race: $0, weekStart: logical.weekStart) }
        var c = AgentContext(
            now: now, name: name, profile: profile, days: days, trend: trend, readiness: readiness,
            guidance: ReadinessEngine.guidance(readiness, profile: profile),
            progress: ProgressEvaluator.evaluate(days: days, workouts: workouts, trend: trend, profile: profile, now: now),
            adherence: InsightEngine.adherence(days: days, plan: plan, profile: profile, now: now),
            associations: InsightEngine.associations(days: days, profile: profile, now: now),
            planFit: InsightEngine.planFit(plan: plan, now: now),
            sleep: SleepAnalyzer.summary(days: days, profile: profile, now: now),
            breathing: SleepAnalyzer.breathingCues(days: days, now: now),
            stopBangScore: stopBang.count == 8 ? SleepAnalyzer.stopBang(stopBang).score : nil,
            bp: BPAnalyzer.summary(vitals, profile: profile, now: now),
            homeBP: BPAnalyzer.homeMonitoring(vitals, profile: profile, now: now),
            glucose: GlucoseAnalyzer.metrics(vitals.filter { $0.kind == .glucose }.map { ($0.time, $0.value) },
                                             low: profile.glucoseLow, high: profile.glucoseHigh, now: now),
            lows: GlucoseAnalyzer.lowEpisodes(vitals.filter { $0.time > now.adding(days: -14) }, low: profile.glucoseLow),
            load: TrainingLoad.status(workouts, now: now),
            weekTrainingsDone: week.filter { $0.status == .done || $0.status == .partial }.count,
            weekTrainingsTotal: week.count,
            weekActiveMinutes: days.filter { $0.day >= logical.weekStart }.map(\.activeMinutes).reduce(0, +),
            todayPlan: plan.filter { $0.day == logical },
            tomorrow: plan.filter { $0.day == logical.adding(days: 1) },
            openEvents: events,
            race: race, raceName: raceName, raceTarget: profile.race?.targetMinutes,
            racePrediction: profile.race == nil ? nil : RacePredictor.predict(workouts, now: now))
        c.targetRHR = targetRHR
        c.plan = plan
        c.vitals = vitals
        c.workouts = workouts
        c.weather = weather.filter { $0.day >= logical }
        c.weatherSource = weatherSource
        c.labs = labs
        return c
    }

    /// The latest result of a kind within `days` days.
    func lab(_ kind: LabKind, within days: Int = 3650) -> LabPoint? {
        labs.filter { $0.kind == kind && $0.date > now.adding(days: -days) }.max { $0.date < $1.date }
    }

    var hasData: Bool { trend.points.count >= 3 || days.count >= 3 }
    /// The specialist plan is switched on (a race date alone only enables race questions).
    var marathonActive: Bool { race != nil && profile.modules.contains(.marathon) }
    /// Enough sleep-breathing signals that a professional sleep assessment is worth arranging.
    var needsSleepEvaluation: Bool {
        profile.apneaStatus != .diagnosed && (breathing.level == .notable || (stopBangScore ?? 0) >= 3 || breathing.witnessed > 0)
    }
    func adherence(_ id: String) -> HabitAdherence? { adherence.first { $0.id == id } }
    func association(_ id: String) -> Association? { associations.first { $0.id == id && $0.sufficient && $0.strength >= .weak } }
    func dimension(_ id: String) -> ProgressDimension? { progress.dimensions.first { $0.id == id } }
    var recent7: [DayData] { days.filter { $0.day > now.startOfDay.adding(days: -7) && $0.day <= now.startOfDay } }

    // MARK: Time of day

    /// Before 5 am: the night is not over yet.
    var beforeWake: Bool { DayClock.isBeforeWake(now, profile) }
    /// The day the user is living in: until its boundary (5 am, or the end of a roster's main sleep)
    /// this is still the previous date.
    var logicalToday: Date { DayClock.logicalToday(now, profile) }
    var weekStart: Date { logicalToday.weekStart }
    var clock: String { Clock.text(now.minutesOfDay) }
    /// This day from waking to its main sleep (follows the roster when there is one).
    var window: DayWindow { DayClock.window(for: logicalToday, profile: profile) }
    /// "你平时 23:15" or, on a roster, "今天安排的 09:00".
    var bedPhrase: String { "\(profile.shift == nil ? "你平时" : "今天安排的") \(Clock.text(window.bed.minutesOfDay))" }
    /// The main sleep should have begun.
    var pastBedtime: Bool { now >= window.bed }
    /// Within about three hours of the main sleep (or later).
    var nearBedtime: Bool { now >= window.bed.addingTimeInterval(-3 * 3600) }
    /// Sleep still possible before the next waking, from now (only once it is bedtime).
    var sleepLeftMinutes: Int? {
        guard pastBedtime else { return nil }
        return max(0, Int(window.nextWake.timeIntervalSince(now) / 60) - 15)
    }
    /// "现在 02:30，已过你平时 23:00 的入睡时间，到 07:00 起床最多还能睡约 4.2 小时。"
    var nightLine: String? {
        guard pastBedtime, let left = sleepLeftMinutes else { return nil }
        return "现在 \(clock)，已过\(bedPhrase) 的入睡时间，到 \(Clock.text(window.nextWake.minutesOfDay)) 起床最多还能睡约 \((Double(left) / 60).oneDecimal) 小时。"
    }
}

extension ReadinessResult {
    /// The coming day's readiness before the night is over: measured after waking.
    static let pending = ReadinessResult(score: nil, level: .moderate, factors: [], confidence: .low,
                                         headline: "睡醒后评估", recommendation: "今天的准备度在睡醒后评估。",
                                         overrides: [], notes: [], missing: [])
}

// MARK: - Output types

enum AgentDestination: String, Equatable {
    case sleep, recovery, plan, heart, vitals, glucose, cardio, marathon, events, labs
    var title: String {
        switch self {
        case .labs: "化验结果"
        case .sleep: "睡眠与呼吸"
        case .recovery: "恢复"
        case .plan: "运动计划"
        case .heart: "静息心率趋势"
        case .vitals: "关键指标"
        case .glucose: "血糖管理"
        case .cardio: "心血管健康"
        case .marathon: "专项运动"
        case .events: "异常与跟进"
        }
    }
    var icon: String {
        switch self {
        case .sleep: "bed.double.fill"
        case .recovery: "leaf.fill"
        case .plan: "calendar"
        case .heart: "heart.fill"
        case .vitals: "heart.text.square.fill"
        case .glucose: "drop.fill"
        case .cardio: "heart.text.square.fill"
        case .marathon: "flag.checkered"
        case .events: "exclamationmark.circle.fill"
        case .labs: "testtube.2"
        }
    }
}

struct AgentPoint: Identifiable, Equatable {
    var id: String { title }
    let icon: String
    let title: String
    let detail: String
    var destination: AgentDestination? = nil
}

struct AgentAssessment: Equatable {
    var headline: String
    var summary: String
    var going: [AgentPoint]
    var watch: [AgentPoint]
    var nextSteps: [AgentPoint]
    var basis: String
    var questions: [String]
}

struct AgentReply: Equatable {
    var text: String
    var sources: [String] = []
    var followUps: [String] = []
    var destination: AgentDestination? = nil
    var urgent = false
    var intent: AgentIntent = .unknown
    /// Interactive components (Generative UI) shown with the answer.
    var blocks: [AgentUIBlock] = []
    /// A safety-relevant conclusion (e.g. "不建议明天做大重量力量训练。") the language model must keep
    /// as its first sentence.
    var conclusion: String? = nil

    /// Plan changes for the user to adopt (none is adopted while the answer is shown).
    var proposals: [PlanChangeProposal] { blocks.compactMap(\.proposal) }
    var proposesPlan: Bool { !proposals.isEmpty }
}

enum AgentIntent: String, CaseIterable {
    case emergency, daySummary, meds, device, planChange, trainingCheck, labs, weather, glucose, bp, breathing, marathon, alcohol, caffeine, stress, diet, hrv, rhr
    case readiness, sleep, exercise, events, doctor, next, overall, greeting, condition, unknown

    /// Keywords in priority order (earlier intents win when several match).
    var keywords: [String] {
        switch self {
        case .emergency: ["胸痛", "胸口痛", "胸闷", "喘不上气", "呼吸困难", "憋得慌", "晕倒", "晕厥", "昏倒", "昏迷", "意识不清", "一侧无力", "半边", "口角歪", "说话不清", "言语不清", "抽搐", "心跳很快停不下来", "严重低血糖", "想自杀", "不想活"]
        case .daySummary: ["总结一下今天", "今天总结", "今天的总结", "今天怎么样", "今天的数据", "明天要注意", "明天注意", "今晚该注意", "今晚注意", "今晚要注意", "睡前注意"]
        case .meds: ["药", "剂量", "胰岛素", "停药", "减药", "加药"]
        case .device, .planChange, .trainingCheck, .condition: []
        case .labs: ["化验", "检验", "验血", "抽血", "肌酐", "eGFR", "egfr", "肾小球滤过率", "肾功能", "血钾", "尿蛋白", "尿白蛋白", "UACR", "血磷", "血红蛋白", "尿酸", "糖化血红蛋白", "HbA1c"]
        case .weather: ["天气", "下雨", "雨天", "雷阵雨", "雷雨", "高温", "太热", "天热", "下雪", "雾霾", "空气质量", "空气污染", "AQI", "台风", "降温"]
        case .glucose: ["血糖", "CGM", "cgm", "低血糖", "高血糖", "糖尿病", "糖化", "TIR", "餐后"]
        case .bp: ["血压", "高压", "低压", "收缩压", "舒张压"]
        case .breathing: ["打鼾", "打呼", "呼吸暂停", "憋醒", "血氧", "CPAP", "呼吸机", "睡眠呼吸", "睡眠门诊", "STOP"]
        case .marathon: ["马拉松", "全马", "半马", "比赛", "配速", "补给", "乳酸", "阈值", "长距离", "跑量"]
        case .alcohol: ["酒", "喝酒", "饮酒", "啤酒"]
        case .caffeine: ["咖啡", "咖啡因", "奶茶", "浓茶"]
        case .stress: ["压力", "焦虑", "紧张", "放松", "情绪", "冥想"]
        case .diet: ["饮食", "吃什么", "吃饭", "晚餐", "早餐", "喝水", "饮水", "营养", "体重", "减肥", "饿", "夜宵", "宵夜", "吃点", "吃东西"]
        case .hrv: ["HRV", "hrv", "变异性"]
        case .rhr: ["静息心率", "心率", "心跳", "基线"]
        case .readiness: ["准备度", "今天适合", "今天能", "今天要不要", "今天练", "能不能练", "能练", "适合运动", "适合跑", "要不要练", "累"]
        case .sleep: ["睡眠", "睡觉", "失眠", "早睡", "作息", "熬夜", "睡不着", "困", "怎么睡", "补觉", "睡好", "睡得", "倒班", "夜班"]
        case .exercise: ["运动", "训练", "计划", "锻炼", "跑步", "有氧", "力量", "步数", "下周"]
        case .events: ["异常", "提醒", "警告", "事件"]
        case .doctor: ["医生", "就医", "看病", "复诊", "医院", "门诊", "检查"]
        case .next: ["接下来", "下一步", "关注", "注意什么", "重点", "建议", "怎么做", "该做"]
        case .overall: ["总体", "整体", "怎么样", "评价", "总结", "进展", "效果", "状态"]
        case .greeting: ["你好", "您好", "hi", "Hi", "你是谁", "能做什么", "怎么用"]
        case .unknown: []
        }
    }

    /// A question about the weather over several days rather than one session.
    static func asksWeatherOverview(_ q: String) -> Bool {
        AgentIntent.weather.keywords.contains { q.contains($0) } && ["这几天", "这周", "本周", "最近", "未来", "几天", "下周", "周末"].contains { q.contains($0) }
    }

    func matches(_ q: String) -> Bool {
        switch self {
        case .device: DeviceGuide.isRequest(q)
        case .planChange: PlanChat.isRequest(q)
        // "明天下雨能跑吗" is a training question that weighs the weather; "这几天天气适合户外训练吗" asks about the weather.
        case .trainingCheck: TrainingCheck.isRequest(q) && !Self.asksWeatherOverview(q)
        default: keywords.contains { q.contains($0) }
        }
    }
}

// MARK: - Agent

enum HealthAgent {
    static let emergencyText = "你描述的情况可能需要紧急处理。如果正在出现胸痛或胸闷、呼吸困难、晕厥、一侧肢体无力、口角歪斜、言语不清或意识模糊，请立即拨打 120，不要自行驾车就医；身边有人时请让他们陪同。\n\n严重低血糖且意识不清时不要喂食，同样立即拨打 120。如果你有伤害自己的想法，请立刻联系身边的人或拨打心理援助热线 12356。"

    static func intent(for question: String) -> AgentIntent {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        // "饮食与血糖" etc.: the first intent in priority order with a keyword hit wins.
        for i in AgentIntent.allCases where i != .unknown {
            if i.matches(q) {
                // "心率" also matches "心率变异性"; HRV is checked first, so the order handles it.
                return i
            }
        }
        return .unknown
    }

    // MARK: Overall evaluation

    static func assess(_ c: AgentContext) -> AgentAssessment {
        let t = c.trend
        let rhrDim = c.dimension("rhr")
        let improved = c.progress.dimensions.filter { $0.status == .improved }
        let urgent = c.openEvents.filter { $0.severity >= .consult }

        // Headline
        let headline: String
        if !urgent.isEmpty { headline = "有 \(urgent.count) 项健康提醒需要优先处理" }
        else if !c.hasData { headline = "正在了解你的个人基础" }
        else if case .rise = t.sustained { headline = "最近静息心率持续偏高，先把恢复放在前面" }
        else if rhrDim?.status == .improved { headline = "静息心率在下降，当前的管理方向适合你" }
        else if !improved.isEmpty { headline = "习惯在改善，静息心率还需要更多时间" }
        else if c.progress.spanDays < 42 { headline = "基础已建立，接下来重在坚持" }
        else { headline = "整体平稳，可以调整计划让它更容易坚持" }

        // Summary
        var s: [String] = []
        if let a7 = t.avg7 {
            var line = "近 7 天静息心率平均 \(a7.noDecimal) bpm"
            if let b = t.baseline { line += "，较个人基线 \((a7 - b).signedText)" }
            if let target = c.targetRHR { line += "，目标 \(target.noDecimal)" }
            s.append(line + "。")
        }
        if let sl = c.sleep.avgMinutes {
            s.append("近两周平均睡眠 \((sl / 60).oneDecimal) 小时，\(c.sleep.regularityText)。")
        }
        s.append("本周完成 \(c.weekTrainingsDone)/\(c.weekTrainingsTotal) 次训练，活动 \(Int(c.weekActiveMinutes)) 分钟。")
        if !c.pastBedtime, let score = c.readiness.score { s.append("今天准备度 \(score)（\(c.readiness.level.label)）。") }
        if improved.count >= 2 && rhrDim?.status != .improved {
            s.append("\(improved.map(\.name).joined(separator: "、"))已经在改善，静息心率通常比习惯变化更慢。")
        }

        // Going well
        var going: [AgentPoint] = []
        for d in improved.prefix(2) {
            going.append(.init(icon: d.icon, title: "\(d.name)在改善", detail: [d.from, d.to].compactMap { $0 }.joined(separator: " → ")))
        }
        for h in c.adherence.filter({ $0.verdict == .sustained && $0.id != "checkin" }).prefix(3 - going.count) {
            going.append(.init(icon: h.icon, title: "\(h.name)坚持得不错", detail: h.detail))
        }

        // Watch
        var watch: [AgentPoint] = []
        for e in urgent.prefix(2) {
            watch.append(.init(icon: "exclamationmark.circle.fill", title: e.title, detail: e.severity.label, destination: .events))
        }
        if case .rise(let d) = t.sustained {
            watch.append(.init(icon: "heart.fill", title: "静息心率持续偏高", detail: "高于平时约 \(d.oneDecimal) bpm，留意睡眠、压力、饮酒与生病", destination: .heart))
        }
        if c.breathing.level == .notable || (c.profile.apneaStatus == .suspected && c.breathing.snoring >= 3) {
            watch.append(.init(icon: "lungs.fill", title: "睡眠呼吸线索",
                               detail: "近 30 天打鼾 \(c.breathing.snoring) 晚\(c.stopBangScore.map { "，STOP-BANG \($0)/8" } ?? "")，"
                                   + (c.needsSleepEvaluation ? "值得专业评估" : "继续记录，持续出现时咨询医生"), destination: .sleep))
        }
        if let avg = c.homeBP.overallAvg, c.homeBP.progress >= 0.5, avg.sys >= 135 || avg.dia >= 85 {
            watch.append(.init(icon: "heart.text.square.fill", title: "家庭血压偏高", detail: "7 天平均 \(Int(avg.sys))/\(Int(avg.dia)) mmHg", destination: c.profile.hasCardiac ? .cardio : .vitals))
        } else if let m = c.bp.morningSys, m >= 135, !watch.contains(where: { $0.title.contains("血压") }) {
            watch.append(.init(icon: "heart.text.square.fill", title: "晨起血压偏高", detail: "近 30 天晨起收缩压平均 \(Int(m)) mmHg", destination: .vitals))
        }
        if (c.glucose.tbr ?? 0) >= 0.04 || c.lows.count >= 2 {
            watch.append(.init(icon: "drop.fill", title: "低血糖时段", detail: "近 14 天 \(c.lows.count) 次低于 \(c.profile.glucoseLow.oneDecimal)", destination: .glucose))
        }
        if c.load.zone == .high {
            watch.append(.init(icon: "gauge.with.dots.needle.67percent", title: "训练负荷增长过快", detail: "近 7 天是近 4 周平均的 \(String(format: "%.1f", c.load.ratio ?? 0)) 倍", destination: .plan))
        }
        if let a = c.association("alcohol-rhr"), a.unfavorable, a.strength >= .moderate {
            watch.append(.init(icon: "wineglass", title: "饮酒与次日心率", detail: "饮酒后的早晨平均高 \(a.diff.oneDecimal) bpm（观察到的关联）", destination: .recovery))
        }
        if let sd = c.dimension("sleep"), sd.status == .needsWork {
            watch.append(.init(icon: "bed.double.fill", title: "睡眠规律变差", detail: sd.detail, destination: .sleep))
        } else if let h = c.adherence("sleepdur"), h.verdict == .struggling {
            watch.append(.init(icon: "moon.zzz", title: "睡眠时长不足", detail: h.detail, destination: .sleep))
        }
        if let h = c.adherence("plan"), h.verdict == .struggling {
            watch.append(.init(icon: "figure.run", title: "计划较难坚持", detail: h.detail, destination: .plan))
        }

        return AgentAssessment(headline: headline, summary: s.joined(), going: going, watch: Array(watch.prefix(4)),
                               nextSteps: nextSteps(c, watch: watch), basis: basis(c), questions: questions(c, watch: watch))
    }

    private static func nextSteps(_ c: AgentContext, watch: [AgentPoint]) -> [AgentPoint] {
        var steps: [AgentPoint] = []
        func add(_ icon: String, _ title: String, _ detail: String, _ dest: AgentDestination?) {
            guard steps.count < 3, !steps.contains(where: { $0.title == title }) else { return }
            steps.append(.init(icon: icon, title: title, detail: detail, destination: dest))
        }
        if c.openEvents.contains(where: { $0.severity >= .consult }) {
            add("exclamationmark.circle.fill", "先处理健康提醒", "按建议复测或就医，并记录处理结果。", .events)
        }
        if case .rise = c.trend.sustained {
            add("bed.double.fill", "这几天以恢复为主", "降低训练强度，优先保证睡眠；伴随不适时及时就医。", .heart)
        }
        if c.needsSleepEvaluation {
            add("stethoscope", "预约一次睡眠评估", "带上 Pulse 的就诊摘要，到睡眠门诊或呼吸科咨询。", .sleep)
        } else if watch.contains(where: { $0.title.contains("呼吸") }) {
            add("zzz", "继续记录打鼾与白天困倦", "饮酒后打鼾更多时，可以先减少睡前饮酒；线索增多再咨询医生。", .sleep)
        }
        if watch.contains(where: { $0.title.contains("血压") }) {
            add("heart.text.square.fill", "完成 7 天家庭血压监测", "每天晨起、睡前各测 2 遍，复诊时提供平均值。", c.profile.hasCardiac ? .cardio : .vitals)
        }
        if c.load.zone == .high {
            add("gauge.with.dots.needle.33percent", "下周不再加量", "接下来几天安排轻松活动，让负荷回到近 4 周水平。", .plan)
        }
        if let a = c.association("alcohol-rhr"), a.unfavorable {
            add("wineglass", "验证饮酒对你的影响", "两周内减少饮酒，对比次日静息心率与睡眠。", .recovery)
        }
        if let h = c.adherence("plan"), h.verdict != .sustained, h.verdict != .noData {
            add("calendar", "让计划更容易完成", c.planFit.first?.detail ?? "缩短单次时长，或在忙碌时使用精简版。", .plan)
        }
        if c.dimension("sleep")?.status != .improved, (c.sleep.avgMinutes ?? 999) < c.profile.sleepNeedMinutes - 15 {
            add("moon.stars.fill", "每周提前 15 分钟上床", "目标 \(Clock.text(c.profile.bedtimeMinutes)) 上床，固定起床时间。", .sleep)
        }
        if c.marathonActive, let race = c.race, race.weeksToRace >= 0 {
            add("flag.checkered", "完成本周 \(Int(race.longRunKm)) km 长距离", "按\(race.phase.label)安排，长距离中演练补给。", .marathon)
        }
        add("heart.circle", "保持每周 150 分钟以上的有氧", "规律有氧 4–8 周后，静息心率通常才会出现变化。", .plan)
        add("sun.horizon.fill", "坚持晨起记录", "醒后 20 秒的记录让每天的调整更准确。", nil)
        return steps
    }

    private static func basis(_ c: AgentContext) -> String {
        let span = min(28, c.progress.spanDays)
        var parts = ["近 \(max(span, c.days.count > 0 ? 1 : 0)) 天"]
        parts.append("静息心率 \(c.trend.points.filter { $0.day > c.now.adding(days: -28) }.count) 天")
        parts.append("睡眠 \(c.days.filter { $0.day > c.now.adding(days: -28) && $0.sleepMinutes != nil }.count) 晚")
        if c.glucose.readings > 0 { parts.append(c.glucose.isContinuous ? "CGM" : "血糖 \(c.glucose.readings) 次") }
        if c.bp.count > 0 { parts.append("血压 \(c.bp.count) 次") }
        return "依据：" + parts.joined(separator: " · ")
    }

    private static func questions(_ c: AgentContext, watch: [AgentPoint]) -> [String] {
        var q: [String] = []
        if c.dimension("rhr")?.status != .improved { q.append("为什么静息心率最近没怎么降？") } else { q.append("静息心率下降说明了什么？") }
        if c.pastBedtime {
            q.append("明天适合运动吗？")
            q.append("睡不着怎么办？")
        } else {
            q.append("今天适合运动吗？")
            q.append("这周有几天没空，帮我调整计划")
        }
        if !WeatherPlanner.advice(plan: c.plan, forecast: c.weather, now: c.now, profile: c.profile).affected.isEmpty { q.insert("这几天的天气适合户外训练吗？", at: min(2, q.count)) }
        q.append(DeviceGuide.usesCGM(c) ? "训练时手表和 CGM 怎么用更准？" : "跑步时手表测的心率准吗？")
        if watch.contains(where: { $0.title.contains("呼吸") }) { q.append("我需要去看睡眠门诊吗？") }
        if c.association("alcohol-rhr") != nil { q.append("饮酒对我的影响有多大？") }
        if c.bp.count > 0 { q.append("我的血压怎么样？") }
        if c.glucose.readings > 0 { q.append("我的血糖控制得怎么样？") }
        if c.race != nil { q.append("马拉松目标现实吗？") }
        q.append("接下来我该关注什么？")
        return Array(q.prefix(7))
    }

    // MARK: Answers

    static func reply(to question: String, context base: AgentContext) -> AgentReply {
        // A condition the user says they have counts for this answer already; a card records it.
        // The question is what is left without it: 「我是低血钾症患者」 is not a question about lab results.
        let told = intent(for: question) == .emergency ? nil : ConditionLibrary.mention(in: question, profile: base.profile)
        let i = intent(for: told.map { question.replacingOccurrences(of: $0.said, with: "") } ?? question)
        var c = base
        if let t = told { c.profile.include(t.info) }
        var r: AgentReply
        switch i {
        case .emergency:
            return AgentReply(text: emergencyText, sources: [], followUps: [], destination: nil, urgent: true, intent: .emergency)
        case .daySummary: r = daySummary(c)
        case .meds: r = meds(c)
        case .device: r = DeviceGuide.reply(question, context: c)
        case .planChange: r = PlanChat.reply(question, context: c)
        case .trainingCheck: r = TrainingCheck.reply(question, context: c)
        case .labs: r = labs(c)
        case .weather: r = weather(c)
        case .glucose: r = glucose(c)
        case .bp: r = bloodPressure(c)
        case .breathing: r = breathing(c)
        case .marathon: r = marathon(c)
        case .alcohol: r = alcohol(c, question: question)
        case .caffeine: r = caffeine(c, question: question)
        case .stress: r = stress(c)
        case .diet: r = diet(c, question: question)
        case .hrv: r = hrv(c)
        case .rhr: r = rhr(c, question: question)
        case .readiness: r = readiness(c)
        case .sleep: r = sleep(c, question: question)
        case .exercise: r = exercise(c)
        case .events: r = events(c)
        case .doctor: r = doctor(c)
        case .next: r = next(c)
        case .overall: r = overall(c)
        case .greeting: r = greeting(c)
        case .condition, .unknown: r = unknown(c)
        }
        r.intent = i
        if let t = told { r = withCondition(r, t, question: question, context: c, before: base) }
        return r
    }

    // MARK: A condition the user mentioned

    /// The context the answer was worked out in: with a condition the user just mentioned counted,
    /// so the language models see the same profile as the rules.
    static func context(_ c: AgentContext, answering r: AgentReply) -> AgentContext {
        guard let x = r.blocks.compactMap(\.condition).first?.info else { return c }
        var out = c
        out.profile.include(x)
        return out
    }

    /// Adds the card for a condition the user said they have, and the plan change it calls for.
    /// When the message is mostly that statement (「我是低血钾症患者」) the answer is about the
    /// condition; otherwise the card comes with the answer to the question.
    static func withCondition(_ r: AgentReply, _ t: ConditionProposal, question q: String, context c: AgentContext,
                              before base: AgentContext) -> AgentReply {
        let x = t.info
        var out = r
        var blocks: [AgentUIBlock] = [.condition(t)]
        if let plan = conditionPlan(x, question: q, context: c, before: base) { blocks.append(.plan(plan)) }
        let ask = "可以把「\(x.name)」记到你的健康状况里，点「记下」后生效。"
        if [.unknown, .greeting, .overall, .next, .doctor].contains(r.intent) {
            var parts: [String?] = [ask]
            if x.known, !x.summary.isEmpty { parts.append(x.summary) }
            parts.append(bullets(x.changes.map { "记下后，" + $0 }))
            let tips = Array(x.exercise.prefix(2) + x.daily.prefix(1)) + (x.stopSigns.isEmpty ? [] : [x.stopSigns])
            parts.append(bullets(tips).map { "平时要注意：\n" + $0 })
            if blocks.count > 1 { parts.append("本周计划里有需要跟着调整的训练，见下面的计划卡片，点「采纳」后才会修改。") }
            out = AgentReply(text: lines(parts), sources: [x.known ? "Pulse 内置的慢病要点" : "你的描述"],
                             followUps: ["\(x.name)运动时要注意什么？", "这周的训练要怎么调整？"], intent: .condition, conclusion: ask)
        } else {
            out.text += "\n\n你提到有\(x.name)。" + ask
        }
        out.blocks = Array((blocks + r.blocks.filter { b in !(blocks.count > 1 && b.proposal != nil) }).prefix(AgentUI.maxBlocks))
        return out
    }

    /// This week's sessions that the condition rules out: hard ones (to moderate) and, for a
    /// condition that avoids heat, outdoor ones on hot days (indoors). Nil when nothing changes.
    static func conditionPlan(_ x: ConditionInfo, question q: String, context c: AgentContext, before base: AgentContext) -> PlanChangeProposal? {
        var ops: [PlanEditOp] = [], notes: [String] = []
        if c.profile.heatSensitive && !base.profile.heatSensitive {
            let now = WeatherPlanner.advice(plan: c.plan, forecast: c.weather, now: c.now, profile: c.profile)
            let was = WeatherPlanner.advice(plan: c.plan, forecast: c.weather, now: c.now, profile: base.profile)
            ops = now.ops.filter { !was.ops.contains($0) }
            notes = now.notes.filter { !was.notes.contains($0) }
        }
        // The hard sessions are capped by the plan's own safety check once the condition counts.
        guard !ops.isEmpty || (c.profile.intensityCapped && !base.profile.intensityCapped) else { return nil }
        var p = PlanChat.propose(ops, scope: .thisWeek, request: q, context: c, source: "Pulse 规则", checksWeather: false)
        p.notes = notes + p.notes
        return p.hasChanges ? p : nil
    }

    /// "周五 雷阵雨 22°C（降水 90%）".
    static func weatherText(_ w: DayWeather, now: Date = .app) -> String {
        let name = w.day.isSameDay(now) ? "今天" : (w.day.isSameDay(now.adding(days: 1)) ? "明天" : Weekday.name(w.day.weekday))
        var t = "\(name) \(w.label) \(Int(w.low))–\(Int(w.high))°C"
        if w.rainChance >= 0.3 { t += "，降水 \(Int(w.rainChance * 100))%" }
        if let a = w.aqi, a > 100 { t += "，AQI \(a)" }
        return t
    }

    /// 天气: the coming days, what they mean for today's and this week's outdoor sessions, and the plan
    /// change to adopt when a session should move or go indoors.
    static func weather(_ c: AgentContext) -> AgentReply {
        guard !c.weather.isEmpty else {
            return AgentReply(text: "暂时拿不到天气预报。开启定位并在 App 中启用 Apple 天气（WeatherKit）后，我会按天气帮你安排户外训练。",
                              sources: [], followUps: ["今天适合运动吗？"], destination: .plan)
        }
        let today = c.weather(on: c.logicalToday)
        let reminder = WeatherPlanner.reminder(today: today, sessions: c.todayPlan, profile: c.profile)
        let advice = WeatherPlanner.advice(plan: c.plan, forecast: c.weather, now: c.now, profile: c.profile)
        let forecast = c.weather.prefix(4).map { weatherText($0, now: c.now) }.joined(separator: "；") + "。"
        let head = reminder.map { $0.line }
            ?? (advice.affected.isEmpty ? "这几天的天气不影响你的户外训练，按计划练就好。" : "今天的户外训练不受天气影响，这周有 \(advice.affected.count) 天要留意。")
        var parts = [head, "天气预报：" + forecast]
        let week = advice.notes.filter { n in reminder == nil || !n.hasPrefix(Weekday.name(c.logicalToday.weekday)) }
        if !week.isEmpty { parts.append(week.map { "• " + $0 }.joined(separator: "\n")) }
        var blocks: [AgentUIBlock] = []
        if let (p, _) = WeatherPlanner.proposal(context: c, forecast: c.weather, source: "按天气预报") {
            blocks.append(.plan(p))
            parts.append("下面是建议的调整，计划还没有改；采纳后才会生效。")
        }
        return AgentReply(text: parts.joined(separator: "\n\n"), sources: ["天气预报（\(c.weatherSource)）", "本周计划"],
                          followUps: ["明天适合户外跑步吗？"], destination: blocks.isEmpty ? .plan : nil, blocks: blocks,
                          conclusion: reminder?.line)
    }

    /// The question is about right now rather than habits in general.
    static func asksAboutNow(_ q: String) -> Bool {
        ["现在", "今晚", "这会", "这么晚", "还能喝", "可以喝", "能喝", "再喝", "等会", "马上"].contains { q.contains($0) }
    }

    /// The library's points for the conditions the user has, e.g. their daily-life ones.
    static func conditionPoints(_ p: ProfileSnapshot, _ points: KeyPath<ConditionInfo, [String]>) -> String? {
        let parts = p.extraConditions.filter { !$0[keyPath: points].isEmpty }.map { x in
            "\(x.name)：" + x[keyPath: points].prefix(3).joined()
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }

    private static func lines(_ parts: [String?]) -> String {
        parts.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }
    private static func bullets(_ items: [String]) -> String? {
        items.isEmpty ? nil : items.map { "• " + $0 }.joined(separator: "\n")
    }

    static func rhr(_ c: AgentContext, question: String = "") -> AgentReply {
        let t = c.trend
        guard let a7 = t.avg7 ?? t.latest?.value else {
            return AgentReply(text: "还没有足够的静息心率数据。连续佩戴手表入睡，或每天醒后静躺 1 分钟手动测量，约 2 周后就能建立你的个人基线。",
                              followUps: ["怎样测量静息心率更准确？", "今天适合运动吗？"], destination: .heart)
        }
        var first = "近 7 天静息心率平均 \(a7.noDecimal) bpm"
        if let a28 = t.avg28 { first += "，近 4 周 \(a28.noDecimal)" }
        if let b = t.baseline { first += "，个人基线 \(b.noDecimal)（\((a7 - b).signedText)）" }
        first += "。" + t.headline + (t.headline.hasSuffix("。") ? "" : "。")
        // Answer the premise first when the question assumes no progress but the data shows some.
        let assumesFlat = ["没怎么降", "没降", "不降", "降不下来", "没有下降", "没变化", "没效果"].contains { question.contains($0) }
        var correction: String? = nil
        if assumesFlat, let b = t.baseline, a7 <= b - 2 {
            correction = "从记录看，你的静息心率其实在下降：比个人基线 \(b.noDecimal) 低了 \((b - a7).oneDecimal) bpm。"
            var premise = correction ?? ""
            if let a28 = t.avg28, abs(a7 - a28) < 1.5 {
                premise += "最近 4 周变化不大，是因为越接近个人的稳定水平，下降越慢，这很常见。"
            }
            first = premise + "\n\n" + first
        }
        var why: [String] = []
        if case .rise(let d) = t.sustained {
            why.append("最近几天持续高于平时约 \(d.oneDecimal) bpm。常见原因有睡眠不足、压力、饮酒、生病或训练负荷过大；如同时有发热、胸闷、心悸等不适，请及时就医。")
        }
        let found = ["alcohol-rhr", "shortsleep-rhr", "stress-rhr", "hard-rhr", "latemeal-rhr"].compactMap { c.association($0) }.filter(\.unfavorable)
        if !found.isEmpty {
            why.append("从你的记录看（观察到的关联，不一定是原因）：\n" + found.prefix(3).map { "• " + $0.sentence }.joined(separator: "\n"))
        }
        let tags = c.trend.elevatedDays.flatMap { $0.tags.map(\.label) + $0.inferred }
        if !tags.isEmpty {
            let top = Dictionary(grouping: tags, by: { $0 }).sorted { $0.value.count != $1.value.count ? $0.value.count > $1.value.count : $0.key < $1.key }.prefix(3).map(\.key)
            why.append("近 3 周偏高的早晨，多伴随：\(top.joined(separator: "、"))。")
        }
        var advice = "降低静息心率最可靠的方式是：每周 150 分钟以上的规律有氧、稳定充足的睡眠、减少饮酒和压力。通常需要 4–8 周以上才看得到变化。"
        if c.dimension("rhr")?.status == .stable, c.dimension("activity")?.status == .improved {
            advice = "你的活动量已经提升，静息心率往往滞后于习惯变化。保持当前组合再观察 4–8 周，避免同时改变太多。"
        }
        let limit = t.limitations.first.map { "需要注意：\($0)" }
        return AgentReply(text: lines([first, why.joined(separator: "\n\n"), advice, limit]),
                          sources: ["静息心率 \(t.points.count) 天", "行为关联 近 120 天"],
                          followUps: ["饮酒对我的影响有多大？", "怎样安排运动更有效？", "我的睡眠怎么样？"], destination: .heart,
                          conclusion: correction)
    }

    static func daySummary(_ c: AgentContext) -> AgentReply {
        let d = c.days.first { $0.day == c.logicalToday }
        let trainings = c.todayPlan.filter { $0.kind.isTraining }
        var parts: [String?] = []
        if c.beforeWake { parts.append("现在是凌晨 \(c.clock)，这里总结的是 \(c.logicalToday.formatted(.dateTime.month().day()))，「明天」指睡醒后的白天。") }
        var morning: [String] = []
        if !c.beforeWake, let s = c.readiness.score { morning.append("准备度 \(s)（\(c.readiness.level.label)）") }
        if let sl = d?.sleepMinutes { morning.append("睡眠 \((sl / 60).oneDecimal) 小时") }
        if let h = d?.rhr { morning.append("静息心率 \(h.noDecimal)") }
        if !morning.isEmpty { parts.append("今天早上：\(morning.joined(separator: "，"))。") }
        let doneT = trainings.filter { $0.status == .done || $0.status == .partial }
        parts.append(trainings.isEmpty ? "今天没有训练安排，活动 \(Int(d?.activeMinutes ?? 0)) 分钟、\(d?.steps ?? 0) 步。"
                     : "训练完成 \(doneT.count)/\(trainings.count) 次，活动 \(Int(d?.activeMinutes ?? 0)) 分钟、\(d?.steps ?? 0) 步。")
        var evening: [String] = []
        if let f = d?.eveningFatigue { evening.append("疲劳 \(f)/5") }
        if let st = d?.eveningStress { evening.append("压力 \(st)/5") }
        if (d?.alcoholUnits ?? 0) > 0 { evening.append("饮酒 \(d!.alcoholUnits.oneDecimal) 单位") }
        if d?.lateCaffeine(cutoff: c.profile.caffeineCutoffHour) == true { evening.append("午后有咖啡因") }
        if !evening.isEmpty { parts.append("晚上：\(evening.joined(separator: "，"))。") }
        var tips: [String] = []
        if let line = c.nightLine {
            tips.append(line + "现在先睡；起床时间尽量不变，白天午睡不超过 30 分钟。")
        } else if (d?.eveningFatigue ?? 0) >= 4 || c.readiness.level == .low {
            tips.append("比平时早 30 分钟上床。")
        }
        if (d?.alcoholUnits ?? 0) > 0 { tips.append("今晚饮酒后\(c.profile.fluidLimited ? "" : "多补水，")明早静息心率偏高时不必担心，属于常见反应。") }
        let tomorrow = c.tomorrow.filter { $0.kind.isTraining }
        let short = (c.sleepLeftMinutes ?? 999) < 360
        tips.append(tomorrow.isEmpty ? "明天没有训练安排，保持日常活动。"
                    : "明天：\(tomorrow.map { "\($0.title) \($0.minutes) 分钟" }.joined(separator: "、"))，"
                        + (short ? "今晚睡眠不足，起床后先看准备度，偏低就改成轻松活动。" : "起床后先记录醒后感受。"))
        parts.append("明天要注意：\n" + tips.map { "• " + $0 }.joined(separator: "\n"))
        return AgentReply(text: parts.compactMap { $0 }.joined(separator: "\n\n"), sources: ["今天的记录"],
                          followUps: c.pastBedtime ? ["睡不着怎么办？", "明天适合运动吗？"] : ["今晚该注意什么？", "这周的训练完成得怎么样？"])
    }

    static func hrv(_ c: AgentContext) -> AgentReply {
        let r7 = Stats.mean(c.recent7.compactMap(\.hrv))
        let r28 = Stats.mean(c.days.filter { $0.day > c.now.adding(days: -28) }.compactMap(\.hrv))
        guard let a = r7 else {
            return AgentReply(text: "还没有心率变异性（HRV）数据。佩戴支持的手表入睡后会自动记录。", destination: .heart)
        }
        var text = "近 7 天 HRV 平均 \(a.noDecimal) ms\(r28.map { "，近 4 周 \($0.noDecimal) ms" } ?? "")。HRV 个体差异很大，只适合和你自己比较：比平时低，通常代表恢复不足或压力较大。"
        if let al = c.association("alcohol-hrv"), al.unfavorable { text += "\n\n" + al.sentence + "（观察到的关联）" }
        return AgentReply(text: text, sources: ["HRV 近 28 天"], followUps: ["今天适合运动吗？", "为什么静息心率最近没怎么降？"], destination: .heart)
    }

    static func readiness(_ c: AgentContext) -> AgentReply {
        // In the evening the morning's score no longer says what to do now; the next one comes after sleep.
        if c.nearBedtime {
            let short = (c.sleepLeftMinutes ?? 999) < 360
            let morning = !c.beforeWake ? c.readiness.score.map { "今天早上的准备度是 \($0)（\(c.readiness.level.label)），今天剩下的时间以放松为主。" } : nil
            let timing = c.nightLine ?? "现在 \(c.clock)，离\(c.bedPhrase) 入睡约 \((c.window.bed.timeIntervalSince(c.now) / 3600).oneDecimal) 小时。"
            return AgentReply(text: lines([
                morning,
                "\(c.beforeWake ? "今天" : "明天")的身体准备度要等你睡醒后才能评估，它取决于今晚的睡眠、夜间静息心率和 HRV。",
                timing + (short ? "睡眠会明显不足，明天大概率需要降低强度。" : ""),
                bullets([c.pastBedtime ? "现在先睡，放下手机、调暗灯光" : "按时上床，睡前 1 小时调暗灯光、放下手机", "起床后记录醒后感受（约 20 秒），Pulse 会给出准备度和当天的安排", short ? "明天的强度课或大重量先别安排，看准备度再定" : nil].compactMap { $0 }),
            ]), sources: ["现在时间与起床时间"], followUps: ["明天适合运动吗？", "熬夜后怎么恢复？"])
        }
        let r = c.readiness
        guard let score = r.score else {
            return AgentReply(text: "今天的身体准备度还没有评估。记录醒后感受（约 20 秒）后，我会结合昨夜睡眠、静息心率和 HRV 告诉你今天适合安排多少。\n\n在那之前：\(c.guidance.exercise)",
                              followUps: ["我的睡眠怎么样？"])
        }
        let plan = c.todayPlan.filter { $0.kind.isTraining || $0.kind == .walk }.map { "\($0.title)（\($0.minutes) 分钟，\($0.intensity.label)，\($0.status.label)）" }
        let factors = r.factors.filter { $0.available && $0.impact == .negative }.map(\.name)
        return AgentReply(text: lines([
            "今天准备度 \(score)，\(r.level.label)（\(r.confidence.label)）。\(r.recommendation)",
            factors.isEmpty ? nil : "主要拉低准备度的是：\(factors.joined(separator: "、"))。",
            bullets(["运动：\(c.guidance.exercise)", "负荷：\(c.guidance.load)", "恢复：\(c.guidance.recovery)"]),
            plan.isEmpty ? "今天没有训练安排，保持日常活动即可。" : "今天的计划：\(plan.joined(separator: "；"))。",
            r.overrides.first,
        ]), sources: ["昨夜睡眠", "静息心率与 HRV", "近期负荷", "醒后感受"],
                          followUps: ["今晚该注意什么？", "这周的训练完成得怎么样？"])
    }

    static func sleep(_ c: AgentContext, question q: String = "") -> AgentReply {
        let s = c.sleep
        // After a late night: what helps the next day, without trying to "pay back" sleep.
        if q.contains("熬夜") {
            let cutoff = c.profile.caffeineCutoffHour
            return AgentReply(text: lines([
                c.nightLine.map { $0 + "能睡多少就先睡多少。" },
                "熬夜后的第二天：",
                bullets(["起床时间尽量不变，起床后多见自然光，晚上更容易按时困", "困的话午睡 20–30 分钟，下午 3 点后不再睡",
                         "咖啡因放在 \(cutoff):00 前，不靠加量硬撑", "训练降为轻松，起床后看准备度再定；强度课和大重量换一天",
                         "当晚按平时时间上床，提前不超过 1 小时，不要一次补很久"]),
                "一晚睡少对静息心率和 HRV 的影响通常 1–2 天就能恢复；连续几晚睡不够影响才会累积。",
            ]), sources: ["睡眠时间设置"], followUps: ["明天适合运动吗？", "我的睡眠怎么样？"], destination: .sleep)
        }
        if let roster = c.profile.shift, c.window.kind == .night || c.window.afterNightShift
            || ["夜班", "下班", "补觉", "倒班"].contains(where: { q.contains($0) }) {
            return shiftSleep(c, roster: roster)
        }
        if let line = c.nightLine, ["睡不着", "失眠", "还没睡", "现在"].contains(where: { q.contains($0) }) {
            return AgentReply(text: lines([
                line,
                bullets(["放下手机，调暗灯光，房间偏凉一些更容易入睡", "慢呼吸几分钟：吸 4 秒、呼 6 秒",
                         "躺了 20 分钟仍睡不着，就起来在暗光下做点安静的事，困了再回床上", "不看时间、不喝咖啡和酒，也不要现在运动",
                         "明天起床时间尽量不变，白天午睡不超过 30 分钟"]),
                "偶尔一晚睡不好不用担心；如果每周有 3 晚以上难以入睡、持续超过 3 个月，可以咨询医生或睡眠门诊。",
            ]), sources: ["现在时间与睡眠设置"], followUps: ["熬夜后怎么恢复？", "明天适合运动吗？"], destination: .sleep)
        }
        guard let avg = s.avgMinutes else {
            return AgentReply(text: "近两周没有睡眠数据。佩戴手表入睡，或在「快速记录」中补记睡眠后，我可以帮你分析作息规律。", destination: .sleep)
        }
        var tips: [String] = []
        if (s.bedtimeSD ?? 0) > 45 { tips.append("入睡时间波动较大：先固定起床时间（包括周末），再稳定上床时间。") }
        if avg < c.profile.sleepNeedMinutes - 30 { tips.append("平均睡眠少于目标：每周把上床时间提前 15 分钟，直到睡够。") }
        if let a = c.association("caffeine-sleep"), a.unfavorable { tips.append(a.sentence + "可以把咖啡因截止时间提前。") }
        if tips.isEmpty { tips.append("作息基本稳定，继续保持固定的起床时间。") }
        let effects = ["shortsleep-rhr", "shortsleep-energy"].compactMap { c.association($0) }.filter(\.unfavorable).map(\.sentence)
        return AgentReply(text: lines([
            "近 14 晚平均睡眠 \((avg / 60).oneDecimal) 小时（目标 \((c.profile.sleepNeedMinutes / 60).oneDecimal)），\(s.avgBedtime.map { "平均 \(Clock.text($0)) 入睡，" } ?? "")\(s.regularityText)；\(s.nightsMeetingNeed)/\(s.nights) 晚睡够。",
            effects.isEmpty ? nil : "睡眠对你的影响（观察到的关联）：\n" + effects.map { "• " + $0 }.joined(separator: "\n"),
            bullets(tips),
            c.breathing.level != .none ? "另外，近 30 天记录到睡眠呼吸线索（打鼾 \(c.breathing.snoring) 晚），可以问我「需要去看睡眠门诊吗？」" : nil,
            c.pastBedtime ? "现在 \(c.clock)，已过你平时的入睡时间，今晚先睡吧，其他的明天再看。" : nil,
        ]), sources: ["睡眠 \(s.nights) 晚"], followUps: ["我需要去看睡眠门诊吗？", "咖啡因对我睡眠有影响吗？"], destination: .sleep)
    }

    /// Sleep around night shifts, with this roster's times.
    static func shiftSleep(_ c: AgentContext, roster s: ShiftSchedule) -> AgentReply {
        let w = c.window
        let next = DayClock.window(for: c.logicalToday.adding(days: 1), profile: c.profile)
        var parts: [String?] = []
        if w.kind == .night {
            let hours = (next.wake.timeIntervalSince(w.bed) / 3600).oneDecimal
            parts.append("这个夜班 \(Clock.text(s.nightEnd)) 下班，安排 \(Clock.text(w.bed.minutesOfDay)) 到 \(Clock.text(next.wake.minutesOfDay)) 睡，约 \(hours) 小时。"
                         + (next.kind == .night ? "明晚还要上夜班，这一觉尽量睡满。"
                            : "这是这一轮的最后一个夜班：只补约 4 小时，下午起来见见光，晚上 \(Clock.text(next.bed.minutesOfDay)) 按时上床，把作息调回来。"))
        } else if w.afterNightShift {
            parts.append("今天是夜班后的恢复日：补觉到 \(Clock.text(w.wake.minutesOfDay)) 左右就起来，白天多见光，晚上 \(Clock.text(w.bed.minutesOfDay)) 按时上床。")
        } else if let nextNight = (1...7).map({ c.logicalToday.adding(days: $0) }).first(where: { s.kind(on: $0) == .night }) {
            let nw = DayClock.window(for: nextNight, profile: c.profile)
            parts.append("下一个夜班在 \(nextNight.formatted(.dateTime.month().day()))：当天下午 \(Clock.text((nw.nap?.start ?? nextNight.atClock(s.nightStart - 240)).minutesOfDay)) 左右小睡 90 分钟再去上班。")
        }
        let caffeineEnd = Clock.text(w.bed.addingTimeInterval(-6 * 3600).minutesOfDay)
        parts.append(bullets([
            "下班路上戴墨镜、少看手机，到家后尽快睡",
            "睡前吃点清淡的，别空腹也别吃太饱",
            "卧室全遮光（遮光帘或眼罩），用耳塞或白噪音，手机静音；告诉家人这段时间是你的「夜里」",
            w.kind == .night ? "\(caffeineEnd) 以后不再喝咖啡和浓茶" : nil,
        ].compactMap { $0 }))
        if let avg = c.sleep.avgMinutes {
            parts.append("近 14 天平均睡眠 \((avg / 60).oneDecimal) 小时（需要 \((c.profile.sleepNeedMinutes / 60).oneDecimal) 小时）\(avg < c.profile.sleepNeedMinutes - 30 ? "，休息日可以多睡一会儿把欠的觉补回来" : "")。")
        }
        // The schedule sentence carries the times; the model has to keep it.
        let first = parts.first.flatMap { $0 }.flatMap { $0.split(separator: "。", maxSplits: 1).first.map { String($0) + "。" } }
        return AgentReply(text: lines(parts), sources: ["倒班安排", "睡眠 近 14 天"], followUps: ["现在可以喝咖啡吗？", "明天适合运动吗？"], destination: .sleep,
                          conclusion: first)
    }

    static func breathing(_ c: AgentContext) -> AgentReply {
        let b = c.breathing
        var text = "近 30 天：打鼾 \(b.snoring) 晚、憋醒 \(b.gasping) 晚、被观察到呼吸暂停 \(b.witnessed) 晚、最低血氧低于 88% 的夜晚 \(b.lowSpO2Nights) 晚。\(b.message)"
        if let score = c.stopBangScore {
            let r = SleepAnalyzer.stopBang(Array(repeating: true, count: score) + Array(repeating: false, count: 8 - score))
            text += "\n\n你的 STOP-BANG 自评为 \(score)/8（\(r.risk)）。\(r.advice)"
        }
        if c.profile.apneaStatus == .diagnosed {
            text += "\n\n你已确诊睡眠呼吸暂停：坚持治疗（如每晚使用 CPAP ≥ \(Int(c.profile.cpapTargetHours)) 小时），留意白天精力、血压和静息心率的变化，复诊时与医生讨论。"
        } else {
            text += "\n\n设备信号和自述线索只能提示可能性，诊断需要专业的睡眠监测。饮酒、仰卧和体重增加都会加重打鼾。"
        }
        return AgentReply(text: text, sources: ["睡眠呼吸线索 近 30 天"], followUps: ["饮酒对我的影响有多大？", "接下来我该关注什么？"], destination: .sleep)
    }

    static func exercise(_ c: AgentContext) -> AgentReply {
        var parts: [String?] = []
        parts.append("本周完成 \(c.weekTrainingsDone)/\(c.weekTrainingsTotal) 次训练，活动 \(Int(c.weekActiveMinutes)) 分钟（本周目标 \(c.profile.weeklyTargetMinutes) 分钟）。")
        if let h = c.adherence("plan") { parts.append("近 4 周：\(h.detail)，\(h.verdict.label)。\(h.suggestion)") }
        if let fit = c.planFit.first { parts.append("可能不适合你的安排：\(fit.title)。\(fit.detail)") }
        if let ratio = c.load.ratio { parts.append("训练负荷比 \(String(format: "%.2f", ratio))（\(c.load.zone.label)）。\(c.load.message)") }
        if let act = c.dimension("activity"), act.status != .insufficient { parts.append("长期看，活动持续性\(act.status.label)：\([act.from, act.to].compactMap { $0 }.joined(separator: " → "))。") }
        parts.append("对静息心率最有帮助的是规律的中低强度有氧（能说话但不能唱歌），每周 150–300 分钟，并加入 2 次力量训练。")
        if c.profile.intensityCapped { parts.append("你记录了\(c.profile.intensityCaps.joined(separator: "、"))：医生确认之前，计划里不安排间歇和大重量。") }
        parts.append(conditionPoints(c.profile, \.exercise))
        return AgentReply(text: lines(parts), sources: ["计划完成情况", "训练负荷 近 28 天"],
                          followUps: ["今天适合运动吗？", "为什么静息心率最近没怎么降？"], destination: .plan)
    }

    static func marathon(_ c: AgentContext) -> AgentReply {
        guard let w = c.race else {
            return AgentReply(text: "还没有设置赛事目标。在「专项运动」中填写比赛日期、目标成绩和当前跑量后，我可以评估可行性并解释每个阶段的重点。", destination: .marathon)
        }
        var parts: [String?] = ["\(c.raceName.isEmpty ? "全程马拉松" : c.raceName)：距比赛 \(w.weeksToRace) 周，当前处于\(w.phase.label)。\(w.phase.focus)",
                                "本周目标跑量约 \(Int(w.weeklyKm)) km，长距离 \(Int(w.longRunKm)) km；轻松跑 \(MarathonPlanner.paceText(w.easyPace))，马拉松配速 \(MarathonPlanner.paceText(w.marathonPace))。"]
        if let pr = c.racePrediction {
            var line = "按近 8 周最好的一次训练（\(pr.basisKm.oneDecimal) km）估算，全马约 \(RacePredictor.timeText(pr.minutes))"
            if let t = c.raceTarget {
                line += t >= pr.minutes ? "，目标 \(RacePredictor.timeText(t)) 比较稳妥。" : "，比目标 \(RacePredictor.timeText(t)) 慢 \(pr.minutes - t) 分钟。距比赛还有时间，按计划进阶有机会缩小差距；如果进展不及预期，以完赛为目标更安全。"
            } else { line += "。" }
            parts.append(line + "（训练跑通常不是全力，估算偏保守。）")
        }
        if c.load.zone == .high || c.load.zone == .caution { parts.append(c.load.message) }
        parts.append(w.warnings.first)
        if c.profile.cardiacLimited { parts.append("你记录了心血管相关情况：较高强度内容需要医生确认后再进行。") }
        return AgentReply(text: lines(parts), sources: ["专项计划", "跑步记录 近 8 周"], followUps: ["长距离怎么补给？", "今天适合运动吗？"], destination: .marathon)
    }

    static func alcohol(_ c: AgentContext, question q: String = "") -> AgentReply {
        let week = c.days.filter { $0.day >= c.weekStart }.map(\.alcoholUnits).reduce(0, +)
        var parts: [String?] = []
        var nowAnswer: String? = nil
        if asksAboutNow(q), c.nearBedtime {
            nowAnswer = "现在 \(c.clock)，今晚不建议再喝酒。"
            parts.append("现在 \(c.clock)，\(c.pastBedtime ? "已过" : "离")\(c.bedPhrase) 的入睡时间\(c.pastBedtime ? "" : "不到 3 小时")，今晚不建议再喝：睡前 3 小时内饮酒对夜间心率和睡眠的影响最大。想喝点什么可以换成温水或无糖的热饮。")
        }
        parts.append("本周饮酒 \(week.oneDecimal) 单位（你的上限 \(c.profile.weeklyAlcoholLimit.noDecimal) 单位）。\(c.adherence("alcohol").map { "近 4 周 \($0.detail)。" } ?? "")")
        let found = ["alcohol-rhr", "alcohol-hrv"].compactMap { c.association($0) }
        if found.isEmpty {
            parts.append("目前还没有足够的记录来判断饮酒对你的具体影响（需要饮酒与不饮酒的早晨各 4 次以上）。")
        } else {
            parts.append("从你的记录看：\n" + found.map { "• " + $0.sentence + "（关联\($0.strength.label)）" }.joined(separator: "\n"))
            parts.append("这是观察到的关联，可能同时受睡眠、聚餐时间等影响。想确认的话，可以在「复盘」中开始 2 周个人验证：减少饮酒，对比次日静息心率。")
        }
        parts.append("一般来说，酒精会让夜间心率升高、HRV 降低、睡眠变浅，还会加重打鼾。睡前 3 小时内不饮酒\(c.profile.fluidLimited ? "" : "、同时补水")，影响会小一些。")
        return AgentReply(text: lines(parts), sources: ["饮酒记录", "次日静息心率与 HRV"], followUps: ["为什么静息心率最近没怎么降？", "我的睡眠怎么样？"], destination: .recovery,
                          conclusion: nowAnswer)
    }

    static func caffeine(_ c: AgentContext, question q: String = "") -> AgentReply {
        var parts: [String?] = []
        var nowAnswer: String? = nil
        if asksAboutNow(q), c.profile.shift != nil, c.window.kind == .night {
            // On a night shift the cutoff follows the daytime sleep: about six hours before it.
            let cutoff = c.window.bed.addingTimeInterval(-6 * 3600)
            let late = c.now >= cutoff
            nowAnswer = late ? "现在 \(c.clock)，离今天安排的 \(Clock.text(c.window.bed.minutesOfDay)) 补觉不到 6 小时，不建议再喝。"
                : "现在 \(c.clock)，离今天安排的 \(Clock.text(c.window.bed.minutesOfDay)) 补觉还有 6 小时以上，可以喝。"
            parts.append(nowAnswer! + (late ? "夜班后半段的咖啡因会让下班后的白天睡眠更浅、更短。想提神可以起身走动、用冷水洗脸。"
                                            : "\(Clock.text(cutoff.minutesOfDay)) 以后就别再喝了。"))
        } else if asksAboutNow(q) {
            let cutoff = c.profile.caffeineCutoffHour
            let late = c.beforeWake || c.now.hour >= cutoff
            nowAnswer = late ? "现在 \(c.clock)，已过你设定的 \(cutoff):00 咖啡因截止时间，不建议再喝。" : "现在 \(c.clock)，还在你设定的 \(cutoff):00 截止时间之前，可以喝。"
            parts.append(late ? "现在 \(c.clock)，已过你设定的 \(cutoff):00 咖啡因截止时间，不建议再喝：咖啡因的作用会持续 5–6 小时以上，现在喝会推迟入睡、让睡眠变浅。想喝热饮可以选低因咖啡或花草茶。"
                            : "现在 \(c.clock)，还在你设定的 \(cutoff):00 截止时间之前，可以喝，把它当作今天的最后一杯。")
        }
        if let h = c.adherence("caffeine") { parts.append("近 4 周：\(h.detail)。\(h.suggestion)") }
        if let a = c.association("caffeine-sleep") { parts.append(a.sentence + "（观察到的关联）") }
        if !asksAboutNow(q) {
            parts.append("咖啡因的作用可持续 5–6 小时以上。把最后一杯放在 \(c.profile.caffeineCutoffHour):00 前，下午改为低因或花草茶，有助于入睡和夜间恢复。")
        }
        return AgentReply(text: lines(parts), sources: ["咖啡因记录"], followUps: ["我的睡眠怎么样？"], destination: .recovery,
                          conclusion: nowAnswer)
    }

    static func stress(_ c: AgentContext) -> AgentReply {
        let s = c.recent7.compactMap(\.stress).map(Double.init)
        let high = c.recent7.filter(\.highStress).count
        var parts: [String?] = [s.isEmpty ? "近 7 天没有压力记录。" : "近 7 天压力平均 \(Stats.mean(s)!.oneDecimal)/5，\(high) 天压力较大。"]
        if let a = c.association("stress-rhr") { parts.append(a.sentence + "（观察到的关联）") }
        parts.append(bullets(["每天 5–10 分钟慢呼吸（吸 4 秒、呼 6 秒）", "白天散步或轻松有氧", "睡前 1 小时放下工作，减少屏幕"]))
        parts.append("如果长期情绪低落、焦虑或睡不好，请寻求专业支持。")
        return AgentReply(text: lines(parts), sources: ["压力记录"], followUps: ["我的睡眠怎么样？", "今天适合运动吗？"], destination: .recovery)
    }

    static func diet(_ c: AgentContext, question q: String = "") -> AgentReply {
        if (c.now.hour >= 21 || c.beforeWake), ["饿", "夜宵", "宵夜", "吃点", "加餐", "吃东西"].contains(where: { q.contains($0) }) {
            var parts: [String?] = ["现在 \(c.clock)，饿了可以少量吃点清淡的，比如一杯温牛奶或无糖酸奶、一小把坚果、一片全麦面包；避免油腻、辛辣、大份和含糖饮料，吃完不要马上躺下。"]
            if c.profile.hasDiabetes && c.profile.hypoRiskMeds(at: c.now) {
                parts.append("你使用的药物有低血糖风险：夜里突然很饿，或伴有心慌、出汗、手抖，先测一下血糖。低于 \(c.profile.glucoseLow.oneDecimal) mmol/L 时按低血糖处理（吃 15 g 快速碳水，15 分钟后复测），并告诉医生。")
            }
            if c.pastBedtime { parts.append("也已经过了你平时的入睡时间，吃完尽快休息。") }
            return AgentReply(text: lines(parts), sources: ["现在时间", c.profile.hasDiabetes ? "血糖照护计划" : "饮食记录"],
                              followUps: ["睡不着怎么办？"], destination: c.profile.hasDiabetes ? .glucose : nil)
        }
        let r = c.recent7
        let water = Stats.mean(r.filter { $0.waterMl > 0 }.map { Double($0.waterMl) })
        let q = r.compactMap(\.dietQuality)
        var parts: [String?] = []
        let limit = c.profile.fluidLimited
        parts.append("近 7 天：\(water.map { "平均饮水 \(Int($0)) ml（\(limit ? "上限" : "目标") \(c.profile.waterTargetMl)）" } ?? "饮水未记录")；\(q.isEmpty ? "饮食未记录" : "饮食均衡 \(q.filter { $0 >= 3 }.count)/\(q.count) 天")；晚餐过晚 \(r.filter(\.lateMeal).count) 天。")
        if let a = c.association("latemeal-rhr"), a.unfavorable { parts.append(a.sentence + "（观察到的关联）") }
        parts.append(bullets(["每餐有蔬菜和优质蛋白，主食适量增加全谷物", "少盐、少加工食品，有助于血压管理", "晚餐在睡前 2–3 小时完成",
                              limit ? "饮水不超过医生定的 \(c.profile.waterTargetMl) ml，口渴时小口慢喝" : "运动日和炎热天气多喝水"]))
        if c.profile.conditions.contains(.ckd) { parts.append("肾病饮食：盐、蛋白质、钾和磷各吃多少，按肾内科医生或营养师给你的要求。") }
        if let w = KidneyDiet.week(c.days, profile: c.profile, now: c.now) {
            var line = "近 7 天记录了 \(w.days) 天：偏咸 \(w.saltyDays) 天"
            if let g = w.proteinAvgG { line += "，蛋白质平均约 \(Int(g)) g\(c.profile.proteinTargetG.map { "（医生定的 \($0) g）" } ?? "")" }
            line += "，高钾食物平均每天 \(w.potassiumPerDay.oneDecimal) 样，高磷食物 \(w.phosphorusPerDay.oneDecimal) 样。"
            // Lab and diet side by side: what was eaten, not proof of a cause.
            if let k = c.lab(.potassium, within: 60), k.value > 5.3, w.potassiumPerDay >= 1 {
                line += "最近一次血钾 \(k.valueText) 偏高，同期高钾食物吃得不少（这是记录里看到的情况，不一定是原因），怎么调整问医生或营养师。"
            }
            parts.append(line)
        }
        parts.append(conditionPoints(c.profile, \.daily))
        if c.profile.hasDiabetes { parts.append("血糖管理：碳水分配请按照护计划，记录每餐碳水有助于理解餐后血糖。") }
        return AgentReply(text: lines(parts), sources: ["饮食与饮水记录"], followUps: ["饮酒对我的影响有多大？"], destination: .recovery)
    }

    static func bloodPressure(_ c: AgentContext) -> AgentReply {
        let s = c.bp
        guard s.count > 0 else {
            return AgentReply(text: "还没有血压记录。建议用经过验证的上臂式血压计，连续 7 天每天晨起、睡前各测 2 遍，平均值最能代表你的日常血压。",
                              followUps: ["接下来我该关注什么？"], destination: .vitals)
        }
        var parts: [String?] = ["近 30 天 \(s.count) 次测量，平均 \(Int(s.avgSys ?? 0))/\(Int(s.avgDia ?? 0)) mmHg（\(s.category)）\(s.morningSys.map { "，晨起收缩压平均 \(Int($0))" } ?? "")\(s.eveningSys.map { "，晚间 \(Int($0))" } ?? "")。"]
        parts.append(c.homeBP.message)
        if let m = s.morningSys, let e = s.eveningSys, m - e >= 10 {
            parts.append("晨起比晚间高 \(Int(m - e)) mmHg，复诊时可以把晨起与睡前的记录一起提供给医生。")
        }
        if c.breathing.level != .none { parts.append("睡眠呼吸问题与晨起血压偏高常常同时出现，你也记录到了打鼾等线索。") }
        parts.append(bullets(["测量前静坐 5 分钟，背部有支撑，袖带与心脏同高", "少盐、规律有氧、减少饮酒、保证睡眠都有助于降低血压", "家庭血压平均 ≥135/85 mmHg 时，请与医生讨论"]))
        return AgentReply(text: lines(parts), sources: ["血压 \(s.count) 次"], followUps: ["我需要去看医生吗？"], destination: c.profile.hasCardiac ? .cardio : .vitals)
    }

    static func glucose(_ c: AgentContext) -> AgentReply {
        let m = c.glucose
        guard m.readings > 0 else {
            return AgentReply(text: "还没有血糖数据。可以通过健康 App 连接 CGM，或手动记录指尖血糖。\(c.profile.hasDiabetes ? "糖尿病管理中，CGM 的达标时间（TIR）比单次数值更适合回顾。" : "")",
                              destination: .glucose)
        }
        var parts: [String?] = []
        if m.isContinuous {
            parts.append("近 14 天 CGM：目标范围内 \(Int((m.tir ?? 0) * 100))%（参考 >70%），低于范围 \(String(format: "%.1f", (m.tbr ?? 0) * 100))%（参考 <4%），高于范围 \(Int((m.tar ?? 0) * 100))%；平均 \(m.mean?.oneDecimal ?? "—") mmol/L，波动 CV \(Int(m.cv ?? 0))%。")
        } else {
            parts.append("近 14 天 \(m.readings) 次指尖血糖，平均 \(m.mean?.oneDecimal ?? "—") mmol/L，目标范围内 \(Int((m.tir ?? 0) * 100))%。")
        }
        if !c.lows.isEmpty {
            parts.append("有 \(c.lows.count) 次低于 \(c.profile.glucoseLow.oneDecimal)，其中夜间 \(c.lows.filter(\.nocturnal).count) 次。低血糖时按 15-15 原则处理：15–20 g 快速碳水，15 分钟后复测。")
        } else {
            parts.append("近 14 天没有低于 \(c.profile.glucoseLow.oneDecimal) 的时段。")
        }
        parts.append("可以在「血糖管理」中查看每餐后的上升幅度和运动前后的变化。目标与用药调整请以医疗团队的照护计划为准。")
        return AgentReply(text: lines(parts), sources: [m.isContinuous ? "CGM 近 14 天" : "血糖 \(m.readings) 次"], followUps: ["运动前血糖要注意什么？"], destination: .glucose)
    }

    static func meds(_ c: AgentContext) -> AgentReply {
        var parts: [String?] = ["我不能提供开始、停止或调整药物（包括胰岛素剂量）的建议，这需要由你的医生或药师根据具体情况决定。"]
        let m = c.medications
        if !m.isEmpty {
            parts.append("你记录的用药：\(m.map { "\($0.name)（\($0.category.label)，\($0.category.hrEffect.label)）" }.joined(separator: "；"))。")
        }
        if c.profile.onRateLoweringMeds() {
            parts.append("其中有可能降低心率的药物：静息心率的变化需要结合用药一起解读，运动强度以主观感受为准。")
        }
        parts.append("复诊时，可以在「我的 › 隐私与数据导出」生成就诊摘要，带上血压、心率和用药记录。")
        return AgentReply(text: lines(parts), sources: ["用药记录"], followUps: ["我需要去看医生吗？"])
    }

    static func events(_ c: AgentContext) -> AgentReply {
        guard !c.openEvents.isEmpty else {
            return AgentReply(text: "目前没有待处理的健康提醒。出现异常读数或症状时，它们会单独进入「异常跟进」，便于复测和记录处理结果。",
                              followUps: ["接下来我该关注什么？"], destination: .events)
        }
        return AgentReply(text: lines(["有 \(c.openEvents.count) 项待处理的提醒：",
                                       bullets(c.openEvents.prefix(4).map { "\($0.title)（\($0.severity.label)）：\($0.guidance)" }),
                                       "处理后请在「异常跟进」中记录结果，例如复测数值或就医情况。"]),
                          sources: ["异常与跟进"], followUps: ["我需要去看医生吗？"], destination: .events)
    }

    /// 化验结果: the latest value of each test, how it reads, and how eGFR is moving.
    static func labs(_ c: AgentContext) -> AgentReply {
        let latest = LabAnalyzer.latest(c.labs)
        guard !latest.isEmpty else {
            return AgentReply(text: "还没有化验结果。拿到化验单后，在「趋势 › 关键指标 › 化验结果」或右上角「+」里填 eGFR、血肌酐、血钾、尿白蛋白/肌酐比等，我会按参考范围解读，并跟踪肾功能的变化。",
                              sources: [], followUps: ["我的血压控制得怎么样？"], destination: .labs)
        }
        var items = latest.map { l in
            "\(l.kind.label) \(l.valueText) \(l.kind.unit)（\(l.date.formatted(.dateTime.month().day()))\(l.estimated ? "，由肌酐估算" : "")）：\(LabAnalyzer.status(l.kind, l.value, profile: c.profile).text)"
        }
        if let t = LabAnalyzer.egfrTrend(c.labs) { items.insert("eGFR \(t.text)", at: 1) }
        var parts: [String?] = ["你最近的化验结果：", bullets(items)]
        let flagged = latest.filter { LabAnalyzer.status($0.kind, $0.value, profile: c.profile).level >= .abnormal }
        if let k = flagged.first(where: { $0.kind == .potassium }) {
            parts.append("血钾\(k.value < 3.5 ? "偏低" : "偏高")会影响心跳和肌肉：\(LabAnalyzer.status(.potassium, k.value, profile: c.profile).level == .urgent ? "请今天就联系医生；在这之前先不运动。" : "运动以中低强度为主，按医生的安排复查。")不要自己加减补钾药或利尿剂。")
        }
        if latest.contains(where: \.kind.isKidney) {
            parts.append("肾功能分期要看相隔 3 个月以上的结果，由医生确认。复查时把这些记录带上（「我的 › 隐私与数据导出」生成就诊摘要）。")
        }
        if latest.contains(where: { $0.kind == .hemoglobin && LabAnalyzer.status(.hemoglobin, $0.value, profile: c.profile).level >= .watch && $0.value < 130 }) {
            parts.append("血红蛋白偏低时，静息心率会偏高、运动更容易累，看心率趋势时要考虑这一点。")
        }
        parts.append(LabAnalyzer.rangeNote)
        return AgentReply(text: lines(parts), sources: ["化验记录"], followUps: ["饮食上要注意什么？", "今天适合运动吗？"], destination: .labs)
    }

    static func doctor(_ c: AgentContext) -> AgentReply {
        var reasons: [String] = []
        for e in c.openEvents where e.severity >= .consult { reasons.append("\(e.title)（\(e.severity.label)）") }
        if c.needsSleepEvaluation { reasons.append("睡眠呼吸线索较多：睡眠门诊或呼吸科") }
        if let avg = c.homeBP.overallAvg, c.homeBP.progress >= 0.5, avg.sys >= 135 || avg.dia >= 85 { reasons.append("家庭血压平均 \(Int(avg.sys))/\(Int(avg.dia))：心内科或全科") }
        if case .rise = c.trend.sustained { reasons.append("静息心率持续偏高且伴随不适时") }
        if (c.glucose.tbr ?? 0) >= 0.04 { reasons.append("低血糖时段偏多：与医疗团队讨论") }
        let text = reasons.isEmpty
            ? "根据目前的记录，没有需要尽快就医的信号。保持规律体检；如出现胸痛、晕厥、明显气短或持续心悸，请立即就医或拨打 120。"
            : lines(["根据你的记录，以下情况建议咨询医生：", bullets(reasons), "就诊时可以带上 Pulse 生成的就诊摘要（「我的 › 隐私与数据导出」），只选择与这次就诊相关的数据即可。"])
        return AgentReply(text: text, sources: ["异常提醒", "血压与睡眠呼吸线索"], followUps: ["接下来我该关注什么？"], destination: reasons.isEmpty ? nil : .events)
    }

    static func next(_ c: AgentContext) -> AgentReply {
        let a = assess(c)
        return AgentReply(text: lines([
            "接下来最值得做的三件事：",
            a.nextSteps.enumerated().map { "\($0.offset + 1). \($0.element.title)：\($0.element.detail)" }.joined(separator: "\n"),
            a.watch.isEmpty ? nil : "需要持续关注：" + a.watch.map(\.title).joined(separator: "、") + "。",
        ]), sources: [a.basis.replacingOccurrences(of: "依据：", with: "")], followUps: Array(a.questions.prefix(3)), destination: a.nextSteps.first?.destination)
    }

    static func overall(_ c: AgentContext) -> AgentReply {
        let a = assess(c)
        return AgentReply(text: lines([
            a.headline + "。",
            a.summary,
            a.going.isEmpty ? nil : "做得好的：" + a.going.map(\.title).joined(separator: "、") + "。",
            a.watch.isEmpty ? nil : "需要关注：" + a.watch.map { "\($0.title)（\($0.detail)）" }.joined(separator: "；") + "。",
        ]), sources: [a.basis.replacingOccurrences(of: "依据：", with: "")], followUps: ["接下来我该关注什么？", "为什么静息心率最近没怎么降？"])
    }

    static func greeting(_ c: AgentContext) -> AgentReply {
        AgentReply(text: "你好\(c.name.isEmpty || c.name == "你" ? "" : "，\(c.name)")。我是你的 Health Agent，会根据你在 Pulse 中的记录——静息心率、睡眠、运动、饮食、血压和血糖——解释变化、回答问题、按你的情况调整训练计划，并给出接下来的建议。\n\n我不做诊断，也不提供用药建议；所有分析都在这台设备上完成。",
                   followUps: ["我最近整体怎么样？", "今天适合运动吗？", "接下来我该关注什么？"])
    }

    static func unknown(_ c: AgentContext) -> AgentReply {
        AgentReply(text: "这个问题我暂时没法从你的记录中找到答案。我可以回答关于静息心率、睡眠与打鼾、运动计划、饮酒与咖啡因、压力、饮食、血压、血糖和马拉松训练的问题，也可以按你的情况调整训练计划、指导手表和 CGM 的使用，例如：",
                   followUps: ["我最近整体怎么样？", "为什么静息心率最近没怎么降？", "今天适合运动吗？", "接下来我该关注什么？"])
    }

    // MARK: Digest for the language model

    /// Compact plain-text summary of the user's data (kept short for the on-device context window).
    static func digest(_ c: AgentContext, anonymous: Bool = false) -> String {
        var d: [String] = []
        let p = c.profile
        let w = c.window
        d.append("现在：\(c.now.formatted(Date.FormatStyle().month().day().weekday(.abbreviated).locale(Locale(identifier: "zh_CN")))) \(Clock.text(c.now.minutesOfDay))\(c.pastBedtime ? "，已过\(c.bedPhrase) 的入睡时间，下次起床约 \(Clock.text(w.nextWake.minutesOfDay))" : "")。")
        if let s = p.shift, let k = w.kind {
            let next = (1...3).map { s.kind(on: c.logicalToday.adding(days: $0)).label }.joined(separator: "、")
            var line = "倒班：今天\(k.label)"
            if k == .night { line += " \(Clock.text(s.nightStart))–\(Clock.text(s.nightEnd))" } else if k == .day { line += " \(Clock.text(s.dayStart))–\(Clock.text(s.dayEnd))" }
            line += "；今天 \(Clock.text(w.wake.minutesOfDay)) 起床，主睡眠 \(Clock.text(w.bed.minutesOfDay)) 开始\(w.afterNightShift ? "（夜班后白天补觉）" : "")；之后三天：\(next)。"
            d.append(line)
        }
        var who = "用户：\(anonymous ? "" : "\(c.name)，")\(p.age) 岁，BMI \(p.bmi.oneDecimal)，活动水平\(p.level.label)"
        if !p.conditionNames.isEmpty { who += "；健康状况：\(p.conditionNames.joined(separator: "、"))" }
        if !c.medications.isEmpty { who += "；用药：\(c.medications.map { "\($0.name)（\($0.category.hrEffect.label)）" }.joined(separator: "、"))" }
        d.append(who + "。目标：\(p.goals.map(\.label).joined(separator: "、"))。")
        for x in p.extraConditions where x.known { d.append("\(x.brief)（Pulse 资料库的要点，不是诊断）") }
        if p.intensityCapped { d.append("运动强度：因为\(p.intensityCaps.joined(separator: "、"))，医生确认前只做中低强度，不做间歇和大重量。") }
        if p.fluidLimited { d.append("限水：医生要求每天饮水不超过 \(p.waterTargetMl) ml，不要建议多喝水。") }
        if let l = LabAnalyzer.digest(c.labs, profile: p) { d.append("化验（最近一次）：\(l)。") }
        if let k = KidneyDiet.digest(c.days, profile: p, now: c.now) { d.append(k + "。") }
        let t = c.trend
        if let a7 = t.avg7 {
            d.append("静息心率：近7天 \(a7.noDecimal)，近4周 \(t.avg28?.noDecimal ?? "—")，基线 \(t.baseline?.noDecimal ?? "—")。\(t.headline)")
        }
        if let s = c.readiness.score { d.append("今天准备度 \(s)（\(c.readiness.level.label)）：\(c.readiness.recommendation)") }
        if let sl = c.sleep.avgMinutes { d.append("睡眠：近14晚平均 \((sl / 60).oneDecimal) 小时，目标 \((p.sleepNeedMinutes / 60).oneDecimal)，\(c.sleep.regularityText)。睡眠呼吸：\(c.breathing.level.label)，打鼾 \(c.breathing.snoring) 晚\(c.stopBangScore.map { "，STOP-BANG \($0)/8" } ?? "")。") }
        d.append("运动：本周计划训练 \(c.weekTrainingsTotal) 次，已完成 \(c.weekTrainingsDone) 次；本周已活动 \(Int(c.weekActiveMinutes)) 分钟，每周目标 \(p.weeklyTargetMinutes) 分钟；训练负荷\(c.load.zone.label)。")
        let habits = c.adherence.filter { $0.verdict != .noData }.map { "\($0.name)\($0.verdict.label)" }
        if !habits.isEmpty { d.append("习惯：\(habits.joined(separator: "、"))。") }
        let assoc = c.associations.filter { $0.sufficient && $0.strength >= .weak }.prefix(3).map(\.sentence)
        if !assoc.isEmpty { d.append("观察到的关联（不等于原因）：\(assoc.joined())") }
        let dims = c.progress.dimensions.filter { $0.status != .insufficient }.map { "\($0.name)\($0.status.label)" }
        if !dims.isEmpty { d.append("长期进展：\(dims.joined(separator: "、"))。") }
        if c.bp.count > 0 { d.append("血压：近30天平均 \(Int(c.bp.avgSys ?? 0))/\(Int(c.bp.avgDia ?? 0))，\(c.bp.category)；目标 \(p.bpTargetSys)/\(p.bpTargetDia)。") }
        if c.glucose.readings > 0 { d.append("血糖：14天平均 \(c.glucose.mean?.oneDecimal ?? "—")，范围内 \(Int((c.glucose.tir ?? 0) * 100))%，低于范围 \(String(format: "%.1f", (c.glucose.tbr ?? 0) * 100))%。") }
        if let r = c.race { d.append("赛事：\(c.raceName)，距比赛 \(r.weeksToRace) 周，\(r.phase.label)，本周跑量 \(Int(r.weeklyKm)) km。") }
        if !c.weather.isEmpty {
            d.append("天气预报（\(c.weatherSource)）：" + c.weather.prefix(4).map { weatherText($0, now: c.now) }.joined(separator: "；") + "。")
            let notes = WeatherPlanner.advice(plan: c.plan, forecast: c.weather, now: c.now, profile: c.profile).notes
            if !notes.isEmpty { d.append("天气对本周户外训练的影响（只是建议，用户还没有采纳，计划尚未改变）：" + notes.joined()) }
        }
        d.append(c.openEvents.isEmpty ? "待处理提醒：无。" : "待处理提醒：\(c.openEvents.prefix(3).map(\.title).joined(separator: "、"))。")
        return d.joined(separator: "\n")
    }

    /// Every answer except the fixed emergency reply is written by a language model from the user's
    /// own data: the digest, the conversation, and what the rules engine computed from the records.
    /// Sections are marked 【…】 so small models don't echo them as headings.
    static func modelPrompt(question q: String, history: [String], context c: AgentContext, reply r: AgentReply,
                            anonymous: Bool) -> String {
        var parts = ["【数据】\n" + digest(c, anonymous: anonymous)]
        if !history.isEmpty { parts.append("【之前的对话】\n" + history.joined(separator: "\n")) }
        parts.append("【问题】\n\(q)")
        parts.append(r.intent == .unknown
                     ? "【要点】\nPulse 没有针对这个问题的现成分析。\n如果问题和健康、身体数据有关：只根据【数据】回答，【数据】里没有的说明 Pulse 中没有相关记录。\n如果问题和健康无关（比如写诗、闲聊、其他领域的问题）：只回复这一句，不要给建议：\(offTopicReply)"
                     : "【要点】（Pulse 根据记录算出的事实）\n" + String(r.text.prefix(900)))
        if let k = r.conclusion { parts.append("【第一句】\n\(k)") }
        if r.proposesPlan {
            parts.append("【说明】计划修改会以卡片展示给用户确认，用户点「采纳」前计划没有改变：用「建议」「可以改为」来说，不要说「已改为」「已调整」；每一天原来是什么、改成什么，以【要点】为准，不要说反；【数据】里的天气建议说的是调整前的计划，调整后各天的天气提醒以【要点】为准；只说明怎么改、为什么，不要另外提出不同的修改。"
                         + (r.intent == .planChange ? "这次不用另外给 2–3 条建议：每个改动的日子写一行，以「• 」开头，说怎么改、为什么，有天气提醒就带上；不要再加「保持准备度」「注意恢复」这类泛泛的话。" : ""))
        }
        if let x = r.blocks.compactMap(\.condition).first?.info {
            parts.append("【说明】用户提到有「\(x.name)」。下面的卡片请用户确认，点「记下」前还没有记录：不要说「已记下」「已记录」。可以结合【数据】里的要点说明平时和运动时要注意什么；不做诊断，不建议药物或补充剂的种类和用量。")
        }
        if r.blocks.contains(where: { if case .form = $0 { true } else { false } }) {
            parts.append("【说明】下面会显示一个表单让用户补充信息：只用一两句话说明需要用户选什么，不要给建议，也不要自己安排日期。")
        }
        return parts.joined(separator: "\n\n")
    }

    /// Prompt labels the model sometimes echoes at the start of a line.
    private static let echoedLabels = ["【数据】", "【问题】", "【要点】", "【第一句】", "【说明】", "【之前的对话】", "用户数据摘要：", "用户数据摘要:",
                                       "观察到的关联：", "分析要点：", "结论：", "结论:", "第一句话：", "第一句话:", "第一句：", "第一句:", "回答：", "现在："]

    /// Removes echoed prompt labels line by line. While streaming, a label still being written
    /// (「第一」, 「【数」) is held back too, so it never flashes up.
    static func stripLabels(_ text: String, streaming: Bool = false) -> String {
        var lines = text.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n").map { line -> String in
            var l = line.trimmingCharacters(in: .whitespaces)
            // 「**第一句**：」, 「**第一句：**」, 「第一句话:」…
            if let r = l.range(of: #"^\*{0,2}第一句话?\*{0,2}\s*[：:]\s*\*{0,2}\s*"#, options: .regularExpression) { l.removeSubrange(r) }
            for label in echoedLabels where l.hasPrefix(label) { l = String(l.dropFirst(label.count)).trimmingCharacters(in: .whitespaces) }
            // Any other short 【…】 heading the model made up.
            if let r = l.range(of: #"^【[^】]{1,8}】\s*"#, options: .regularExpression) { l.removeSubrange(r) }
            return l
        }
        // A section heading on its own line ("用户数据摘要") carries nothing.
        lines.removeAll { ["用户数据摘要", "观察到的关联", "数据", "要点"].contains($0) }
        if streaming, let last = lines.last?.replacingOccurrences(of: "*", with: ""), !last.isEmpty,
           echoedLabels.contains(where: { $0.count > last.count && $0.hasPrefix(last) }) {
            lines.removeLast()
        }
        return lines.joined(separator: "\n")
    }

    /// A proposal is not adopted while its answer is shown, so claims that the plan was already
    /// changed (「已从长距离跑改为轻松跑」「计划已更新」) become suggestions. Past facts from the data
    /// (「静息心率已从 72 降到 66」「已结合准备度做了安全检查」) stay: only plan-editing verbs count.
    /// The changed days are still ahead, so a clause saying a session on one of them is done
    /// (「周六长距离跑已完成」) is dropped.
    static func notApplied(_ text: String, changedDays: Set<String> = []) -> String {
        let change = "(?:改为|改成|改到|调整为|调整成|调整到|调为|调成|挪到|移到|换成|换为|更新为)"
        let done = "已经?(?:为你|帮你|给你)?"
        var t = text
        // 「已从 A 改为 B」「已经帮你把周三挪到周四」
        t = t.replacingOccurrences(of: done + "((?:从|把|将)[^，。；！\\n]{1,30}?" + change + ")", with: "建议$1", options: .regularExpression)
        // 「已改为」「已经调整成」
        t = t.replacingOccurrences(of: done + "(" + change + ")", with: "建议$1", options: .regularExpression)
        // 「计划已更新。」「已经调整好了，」
        t = t.replacingOccurrences(of: done + "(?:更新|修改|调整|改动|改好|安排好)好?了?(?=[，。；！\\n]|$)", with: "需要你采纳后才会更新", options: .regularExpression)
        // 「已调整下周计划」
        t = t.replacingOccurrences(of: done + "(调整|修改|更新)了?(?=[^，。；！\\n])", with: "建议$1", options: .regularExpression)
        return changedDays.isEmpty ? t : t.components(separatedBy: "\n").map { dropDoneClaims($0, days: changedDays) }.joined(separator: "\n")
    }

    private static func dropDoneClaims(_ line: String, days: Set<String>) -> String {
        let claim = "已经?(?:完成|练完|跑完)"
        guard line.range(of: claim, options: .regularExpression) != nil else { return line }
        let bullet = line.hasPrefix("• ") ? "• " : ""
        var clauses: [(text: String, end: String)] = []
        var current = ""
        for ch in line.dropFirst(bullet.count) {
            if "，。；！".contains(ch) { clauses.append((current, String(ch))); current = "" } else { current.append(ch) }
        }
        if !current.isEmpty { clauses.append((current, "")) }
        var kept: [(text: String, end: String)] = []
        for c in clauses {
            let past = c.text.contains("上周") || c.text.contains("昨天")
            if !past, days.contains(where: { c.text.contains($0) }), c.text.range(of: claim, options: .regularExpression) != nil {
                // The sentence ending moves to the clause before.
                if c.end != "，", let last = kept.indices.last, kept[last].end == "，" { kept[last].end = c.end }
                continue
            }
            kept.append(c)
        }
        let out = kept.map { $0.text + $0.end }.joined()
        return out.isEmpty ? "" : bullet + out
    }

    /// A plan-change answer is about the days it changes. A bullet naming none of them is generic
    /// (「保持今天准备度 99……」) and goes; the card below carries the safety checks. When no bullet is
    /// left, the rules' own day-by-day lines take their place.
    static func onlyChangedDays(_ lines: [String], days: Set<String>, rules: String) -> [String] {
        let kept = lines.filter { !isGeneric($0, days: days) }
        guard lines.contains(where: { $0.hasPrefix("•") }), !kept.contains(where: { $0.hasPrefix("•") }) else { return kept }
        return kept + [""] + rules.components(separatedBy: "\n").filter { $0.hasPrefix("•") && !isGeneric($0, days: days) }
    }

    private static func isGeneric(_ line: String, days: Set<String>) -> Bool {
        line.hasPrefix("•") && !days.contains { line.contains($0) }
    }

    /// A model's bullet about one changed day must get the change the right way round. One that
    /// doesn't say what the day becomes, or says it backwards (「周六：将「长距离跑」改为「轻松跑」」 when
    /// Saturday goes from the easy run to the long run), is replaced by the rules' line for that day
    /// and its weather note. Bullets about several days at once are left as they are.
    static func checkedDayLines(_ lines: [String], proposals: [PlanChangeProposal]) -> [String] {
        let changes = proposals.flatMap { p in p.lines.map { (line: $0, notes: p.notes) } }
        return lines.map { text in
            guard text.hasPrefix("•") else { return text }
            let named = changes.filter { c in dayNames(c.line.weekday).contains { text.contains($0) } }
            guard named.count == 1, let c = named.first, !agrees(text, with: c.line) else { return text }
            let name = Weekday.name(c.line.weekday)
            return (["• \(name)：原来是「\(c.line.before)」，改为「\(c.line.after)」。"] + c.notes.filter { $0.hasPrefix(name) }).joined()
        }
    }

    private static func agrees(_ text: String, with l: PlanChangeLine) -> Bool {
        // 「长距离跑 13 km 98 分钟」 → 「长距离跑」, 「室内有氧（跑步机…）30 分钟」 → 「室内有氧」.
        func core(_ s: String) -> String {
            String(s.prefix { !$0.isNumber && !" （(".contains($0) })
        }
        let was = core(l.before), becomes = core(l.after)
        guard was != becomes, !was.isEmpty, !becomes.isEmpty else {
            // The same kind of session: the new numbers have to be there.
            let old = Set(l.before.split(whereSeparator: { !$0.isNumber }).map(String.init))
            return l.after.split(whereSeparator: { !$0.isNumber }).map(String.init).filter { !old.contains($0) }.allSatisfy { text.contains($0) }
        }
        guard let at = text.range(of: becomes)?.lowerBound else { return false }
        // Where the old session is named, it comes first (「原来是 A，改为 B」); B's own letters don't count.
        let masked = text.replacingOccurrences(of: becomes, with: String(repeating: "＊", count: becomes.count))
        if let old = masked.range(of: was)?.lowerBound, masked.distance(from: masked.startIndex, to: old) > text.distance(from: text.startIndex, to: at) {
            return false
        }
        return true
    }

    /// 「周六」 and 「星期六」 for the days a set of plan changes touches.
    static func changedDays(_ proposals: [PlanChangeProposal]) -> Set<String> {
        Set(proposals.flatMap(\.lines).flatMap { dayNames($0.weekday) })
    }

    private static func dayNames(_ weekday: Int) -> [String] {
        let name = Weekday.name(weekday)
        return [name, name.replacingOccurrences(of: "周", with: "星期")]
    }

    /// What is shown while an answer streams in: labels stripped, and with a plan change to adopt, a
    /// clause holding 「已」 waits until it is complete so a claim like 「已改为」 never flashes up.
    /// A condition card records nothing until 记下, so 「已为你记下低血钾症」 becomes 「可以记下…」.
    /// Only clauses about the condition count: 「你已记录 5 天血压」 stays.
    static func notRecorded(_ text: String, of r: AgentReply) -> String {
        guard let name = r.blocks.compactMap(\.condition).first?.info.name else { return text }
        let claim = "已经?(?:为你|帮你|给你)?(?:记下|记录|添加|保存)(?:了|好)?"
        func rewrite(_ c: String) -> String {
            guard c.contains(name) || c.contains("健康状况") || c.contains("这个情况") else { return c }
            return c.replacingOccurrences(of: claim, with: "可以记下", options: .regularExpression)
        }
        var out = "", clause = ""
        for ch in text {
            clause.append(ch)
            guard "，。；！\n".contains(ch) else { continue }
            out += rewrite(clause)
            clause = ""
        }
        return out + rewrite(clause)
    }

    static func streamed(_ partial: String, of r: AgentReply, proposing: Bool? = nil) -> String {
        var t = notRecorded(stripLabels(partial, streaming: true), of: r)
        guard proposing ?? r.proposesPlan else { return t }
        // Day lines show once complete and checked, the way the final answer is.
        if r.intent == .planChange, !r.proposals.isEmpty {
            var lines = t.components(separatedBy: "\n")
            if lines.last?.hasPrefix("•") == true { lines.removeLast() }
            let days = changedDays(r.proposals)
            t = checkedDayLines(lines.filter { !isGeneric($0, days: days) }, proposals: r.proposals).joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let clauseStart = t.lastIndex(where: { "，。；！\n".contains($0) }).map { t.index(after: $0) } ?? t.startIndex
        let days = changedDays(r.proposals)
        guard let pending = t[clauseStart...].firstIndex(of: "已") else { return notApplied(t, changedDays: days) }
        return notApplied(String(t[..<pending]), changedDays: days)
    }

    /// Cleans a model answer: drops echoed section labels, keeps a form question short, and puts a
    /// dropped or rewritten conclusion back in front. With plan changes to adopt (`proposals`, by
    /// default those of the rules answer), claims that they are already done are reworded.
    static func finalize(_ text: String, of r: AgentReply, proposals: [PlanChangeProposal]? = nil) -> String {
        var lines = notRecorded(stripLabels(text), of: r).components(separatedBy: "\n")
        let pending = proposals ?? r.proposals
        if !pending.isEmpty {
            let days = changedDays(pending)
            lines = lines.map { notApplied($0, changedDays: days) }
            if r.intent == .planChange { lines = checkedDayLines(onlyChangedDays(lines, days: days, rules: r.text), proposals: pending) }
        }
        if r.blocks.contains(where: { if case .form = $0 { true } else { false } }) {
            lines = lines.filter { !$0.hasPrefix("•") }
        }
        var t = lines.joined(separator: "\n").replacingOccurrences(of: "\n\n\n", with: "\n\n")
            .replacingOccurrences(of: "【数据】", with: "你的数据").replacingOccurrences(of: "【要点】", with: "分析")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // The off-topic reply stands alone.
        if t.contains(offTopicReply) { return offTopicReply }
        if t.isEmpty { t = r.text }
        // The verdict sentence is what must survive; the reasons after it may be reworded.
        guard let k = r.conclusion else { return t }
        let verdict = k.split(separator: "。", maxSplits: 1).first.map { String($0) + "。" } ?? k
        if t.contains(k) || t.contains(verdict) { return t }
        return k + "\n\n" + t
    }

    /// Instructions for the on-device model (Apple Intelligence).
    static let groundedInstructions = """
    你是 Pulse 应用中的 Health Agent，根据用户自己的身体数据回答问题，长期目标是降低静息心率。
    【】里是给你的材料：不要输出这些标题，也不要整段复述【数据】。
    要求：
    1. 先用一句话直接回答【问题】。只使用【数据】和【要点】中的事实与数字，可以结合【数据】里与问题相关的其他数据（睡眠、静息心率、训练、血压、血糖等）；没有的数据直接说明没有记录，不要编造。
    2. 有【第一句】时，回答必须以它原样开头，后面的内容不能与它矛盾。
    3. 注意【数据】中的「现在」时间；问到户外运动时，参考【数据】里的天气预报。区分观察到的关联和原因；不做诊断；不建议开始、停止或调整任何药物和剂量。
    4. 然后给 2–3 条具体建议，每条单独一行，以「• 」开头。不超过 200 字，不加标题。
    5. 【要点】没有提到急救时，不要提及急救或 120。
    """

    static let offTopicReply = "这个我帮不上忙。我可以根据你的数据回答睡眠、静息心率、运动计划、血压和血糖等问题。"

}
