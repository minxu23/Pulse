import Foundation

// Possible reasons for an item that ranks in the bottom quarter or misses its target (基线报告 2.7).
// Each reason is checked against the user's own records first; what the records can't show is a common
// reason; what could be a medical cause goes to the doctor. Never "because": "可能和……有关".

struct Cause: Equatable, Codable {
    enum Evidence: Int, Comparable, Codable {
        case data, common, doctor
        static func < (a: Evidence, b: Evidence) -> Bool { a.rawValue < b.rawValue }
        var label: String {
            switch self {
            case .data: "有数据支持"
            case .common: "常见原因"
            case .doctor: "需要医生排查"
            }
        }
    }
    var text: String
    var evidence: Evidence
}

struct Concern: Identifiable, Equatable, Codable {
    let metric: BaselineMetric.Kind
    var id: BaselineMetric.Kind { metric }
    var title: String
    var causes: [Cause]
}

enum CauseInference {
    static let maxCauses = 3

    static func concerns(_ r: BaselineReport, _ x: BaselineInput) -> [Concern] {
        // Exercise minutes are what the plan changes; they show up as a reason under other items instead.
        let flagged = r.cards.flatMap(\.metrics).filter { m in
            m.kind != .activeMinutes && ((m.verdict ?? .good) >= .attention || (m.rank?.band.isLow ?? false))
        }
        var out: [Concern] = []
        var weightDone = false
        for m in flagged.sorted(by: { ($0.verdict ?? .good) > ($1.verdict ?? .good) }) {
            // BMI, waist and body fat share their reasons: one concern.
            if [.bmi, .waist, .bodyFat].contains(m.kind) {
                if weightDone { continue }
                weightDone = true
            }
            let causes = candidates(m, r, x)
            // Few steps with nothing in the records to say why would only repeat the number.
            guard !causes.isEmpty, m.kind != .steps || causes.contains(where: { $0.evidence == .data }) else { continue }
            let ranked = causes.enumerated().sorted { ($0.element.evidence, $0.offset) < ($1.element.evidence, $1.offset) }.map(\.element)
            out.append(Concern(metric: m.kind, title: title(m), causes: Array(ranked.prefix(maxCauses))))
        }
        return out
    }

    static func title(_ m: BaselineMetric) -> String {
        switch m.kind {
        case .rhr: "静息心率偏高"
        case .vo2max: "心肺能力偏弱"
        case .hrRecovery: "运动后心率恢复偏慢"
        case .bloodPressure: "血压偏高"
        case .bmi, .waist, .bodyFat: "体重和体脂偏高"
        case .glucose: m.title == "血糖达标时间" ? "血糖达标时间偏少" : "血糖偏高"
        case .hba1c: "糖化血红蛋白偏高"
        case .sleepDuration: "睡得偏少"
        case .sleepRegularity: "作息不规律"
        case .breathing: "夜间呼吸有线索"
        case .steps: "活动量偏少"
        case .activeMinutes: "中高强度运动偏少"
        case .strength: "肌肉力量偏弱"
        case .rhythm: "心律有提示"
        case .hrv: "心率变异性偏低"
        }
    }

    // MARK: Candidates

    static func candidates(_ m: BaselineMetric, _ r: BaselineReport, _ x: BaselineInput) -> [Cause] {
        let p = x.profile
        let h = r.habits
        let days = x.days.filter { $0.day >= x.window.start && $0.day < x.window.end }
        let sleepH = r.metric(.sleepDuration)?.value
        let lowActivity = h.guidelineMinutes < 150
        let heavy = (r.metric(.bmi)?.value ?? 0) >= 24 || r.metric(.bodyFat)?.verdict == .attention
        let stressDays = days.filter(\.highStress).count
        var c: [Cause] = []
        func data(_ t: String) { c.append(Cause(text: t, evidence: .data)) }
        func common(_ t: String) { c.append(Cause(text: t, evidence: .common)) }
        func doctor(_ t: String) { c.append(Cause(text: t, evidence: .doctor)) }
        let activityLine = "近 4 周中高强度运动每周约 \(Int(h.guidelineMinutes)) 分钟，少于建议的 150 分钟"
        // 「这周」 for a week of baseline, 「这 14 天里」 for longer.
        let n = max(1, x.window.end.daysSince(x.window.start))
        let period = n <= 7 ? "这周" : "这 \(n) 天里"

        switch m.kind {
        case .vo2max:
            if lowActivity { data(activityLine) }
            else if h.vigorousMinutes < 20 { data("运动量够了，但几乎没有让心跳明显加快的训练，最大摄氧量主要靠这类训练提高") }
            if heavy { data("体重偏高：最大摄氧量按每公斤体重计算，体重越高这个数越低") }
            if let n = r.metric(.vo2max)?.note, n.contains("次估算") || n.contains("天前") { data("估算次数少，手表估算本身误差也较大，排名可能偏差一档") }
            if !h.zonesReliable { data("服用控制心率的药物，按心率估算的结果可能偏低") }
            if p.conditions.contains(.anemia) || hemoglobinLow(x) { data("血红蛋白偏低会降低心肺能力") }
            else if m.rank?.band == .bottom10 { doctor("如果平时爬楼梯也容易气短、乏力，建议查血常规和心肺功能") }
            common("遗传和过去的运动基础也有影响")

        case .rhr:
            if lowActivity || (r.metric(.vo2max)?.rank?.band.isLow ?? false) { data("有氧基础偏弱：规律的有氧运动通常能让静息心率慢慢降下来") }
            if let s = sleepH, s < 7 { data("平均每晚只睡 \(s.shortDecimal) 小时") }
            if let d = alcoholEffect(x), d >= 2 { data("你的记录里，喝酒后第二天的静息心率平均高 \(Int(d.rounded())) 次/分") }
            if h.lateCaffeineDays >= 2 { data("\(period)有 \(h.lateCaffeineDays) 天下午以后还喝咖啡或茶") }
            if stressDays >= 2 { data("\(period)有 \(stressDays) 天压力较大") }
            if days.contains(where: \.isIll) { data("\(period)有生病的记录，静息心率会暂时升高") }
            if p.conditions.contains(.thyroid) || p.conditions.contains(.anemia) || (m.value ?? 0) >= 90 {
                doctor("甲状腺功能亢进、贫血等也会让静息心率偏高，持续偏高建议查一查")
            }
            common("天热、喝水少也会让心率偏高")

        case .hrRecovery:
            if lowActivity || (r.metric(.vo2max)?.rank?.band.isLow ?? false) { data("体能基础偏弱，规律训练后心率恢复通常会变快") }
            if !h.zonesReliable { data("控制心率的药物会影响心率恢复") }
            if let share = Stats.median(h.sports.compactMap(\.reserveShare)), share < 0.5 { data("最近的运动强度不高，这个数不太可靠") }
            doctor("持续偏慢，或运动时胸闷、气短，建议就医检查")

        case .bloodPressure:
            if lowActivity { data(activityLine) }
            if heavy { data("体重偏高") }
            if h.alcoholPerWeek >= 7 { data("每周约 \(h.alcoholPerWeek.cleanText) 份酒") }
            let salty = days.filter { ($0.saltG ?? 0) > p.saltLimitG || !$0.saltSources.isEmpty }.count
            if salty >= 2 { data("饮食记录里有 \(salty) 天偏咸") }
            if let s = sleepH, s < 6.5 { data("睡得偏少（平均 \(s.shortDecimal) 小时）") }
            if (r.metric(.breathing)?.verdict ?? .good) >= .fair { data("夜间呼吸有线索，睡眠呼吸暂停也会让血压升高") }
            let missed = days.filter { $0.medsTaken == false }.count
            if missed >= 2 { data("\(period)有 \(missed) 天没按时吃药") }
            if !p.conditions.contains(.hypertension) { doctor("家庭血压平均达到 135/85，建议去医院确认是不是高血压") }
            common("测量方法也会影响读数：坐着休息 5 分钟再测，袖带和心脏同高")

        case .bmi, .waist, .bodyFat:
            if let s = h.stepsMean, s < 7000 { data("日均 \(Int(s.rounded())) 步，活动量偏少") } else if lowActivity { data(activityLine) }
            if !x.workouts.contains(where: { $0.type == .strength && $0.start >= x.window.end.adding(days: -28) && $0.start < x.window.end }) {
                data("近 4 周没有力量训练，肌肉少也会让体脂率偏高")
            }
            if h.lateMealDays >= 2 { data("\(period)有 \(h.lateMealDays) 天晚饭吃得晚") }
            if h.alcoholPerWeek >= 4 { data("每周约 \(h.alcoholPerWeek.cleanText) 份酒") }
            if let s = sleepH, s < 7 { data("睡得偏少，睡眠不足和体重增加有关") }
            common("体脂秤的读数受喝水和称重时间影响，看趋势比看单次更有意义")

        case .glucose, .hba1c:
            if h.afterMeal == 0 { data("近 4 周的运动都不在饭后，饭后走一走能让餐后血糖低一些") }
            if h.lateMealDays >= 2 { data("\(period)有 \(h.lateMealDays) 天晚饭吃得晚") }
            if heavy { data("体重和体脂偏高") }
            if let s = sleepH, s < 7 { data("睡得偏少，会让第二天血糖更难控制") }
            if lowActivity { data(activityLine) }
            if p.hasDiabetes { doctor("血糖长期不达标，或者低血糖多，请带着记录和医生调整方案") }
            else { doctor("建议查空腹血糖和糖化血红蛋白，确认是否为糖尿病前期") }
            common("高碳水的餐食会让餐后血糖升得快")

        case .sleepDuration, .sleepRegularity:
            if let b = h.bedtimeMean, b >= 24 * 60 { data("平均 \(clock(b)) 才睡") }
            if let w = h.weekendShift, w >= 60 { data("周末比平时晚睡约 \(Int(w.rounded())) 分钟") }
            if h.lateCaffeineDays >= 2 { data("\(period)有 \(h.lateCaffeineDays) 天下午以后还喝咖啡或茶") }
            if h.alcoholPerWeek >= 4 { data("睡前喝酒会让后半夜睡得浅") }
            if p.shift != nil { data("轮班会打乱作息") }
            if stressDays >= 2 { data("\(period)有 \(stressDays) 天压力较大") }
            if r.metric(.breathing)?.verdict == .attention { doctor("夜间呼吸线索较多，可能有睡眠呼吸暂停，建议做睡眠评估") }
            common("睡前看手机、卧室太亮太热也会影响入睡")

        case .breathing:
            if heavy { data("体重偏高是睡眠呼吸暂停最常见的原因之一") }
            if h.alcoholPerWeek >= 4 { data("睡前喝酒会让呼吸道更松弛") }
            doctor("建议做一次睡眠评估（问诊和睡眠监测），确认是否有睡眠呼吸暂停")

        case .steps, .activeMinutes:
            if let wd = h.weekdaySteps, let we = h.weekendSteps, we - wd >= 2000 { data("工作日比周末少走约 \(Int((we - wd).rounded())) 步，可能和久坐的工作有关") }
            if let st = h.standHours, st < 8 { data("平均每天只有 \(Int(st.rounded())) 个小时起身活动过") }
            if p.shift != nil { data("轮班会挤占运动时间") }
            common("通勤方式和天气也会影响活动量")

        case .rhythm:
            doctor("手表的提示需要医生用心电图确认")

        case .hrv:
            if let s = sleepH, s < 7 { data("睡得偏少") }
            if stressDays >= 2 { data("\(period)有 \(stressDays) 天压力较大") }
            common("HRV 随年龄下降，单次偏低意义有限")

        case .strength:
            let strength = x.workouts.filter { $0.type == .strength && $0.start >= x.window.end.adding(days: -28) && $0.start < x.window.end }.count
            if strength < 8 { data("近 4 周力量训练 \(strength) 次，少于每周 2 次的建议") }
            common("自测的姿势和节奏不同，结果会差几个；过几周用同样的方法再测一次更准")
        }
        return c
    }

    /// Next-morning resting heart rate after a drinking day minus after a dry day, over the last 60 days.
    static func alcoholEffect(_ x: BaselineInput) -> Double? {
        let byDay = Dictionary(x.days.map { ($0.day, $0) }, uniquingKeysWith: { a, _ in a })
        var after: [Double] = [], dry: [Double] = []
        for d in x.days where d.day >= x.window.end.adding(days: -60) && d.day < x.window.end {
            guard let rhr = d.rhr, let prev = byDay[d.day.adding(days: -1)] else { continue }
            if prev.hadAlcohol { after.append(rhr) } else { dry.append(rhr) }
        }
        guard after.count >= 3, dry.count >= 5, let a = Stats.mean(after), let b = Stats.mean(dry) else { return nil }
        return a - b
    }

    static func hemoglobinLow(_ x: BaselineInput) -> Bool {
        guard let hb = x.labs.filter({ $0.kind == .hemoglobin }).max(by: { $0.date < $1.date }) else { return false }
        return hb.value < (x.profile.sex == .female ? 115 : 130)
    }

    static func clock(_ minutes: Double) -> String {
        let m = Int(minutes.rounded()) % (24 * 60)
        return String(format: "%d:%02d", m / 60, m % 60)
    }
}
