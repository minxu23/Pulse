import Foundation

// "明天适合做大力量训练吗？" — a question about a day that has not started yet cannot be answered
// from a readiness score: that depends on tonight's sleep. This works out which day is meant
// (after midnight, "明天" is the coming daytime), how much sleep is still possible before the usual
// wake time, and what else argues for or against the session, then answers with a direct verdict.
// The language models only ever pass this verdict on; they never decide it.

enum TrainingCheck {
    enum Session: Equatable {
        case heavyStrength, strength, intervals, long, easy, any
        var label: String {
            switch self {
            case .heavyStrength: "大重量力量训练"
            case .strength: "力量训练"
            case .intervals: "高强度 / 间歇训练"
            case .long: "长距离训练"
            case .easy: "轻松活动"
            case .any: "训练"
            }
        }
        var demanding: Bool { [.heavyStrength, .intervals, .long].contains(self) }
    }

    enum Verdict: Equatable {
        case go, easier, notAdvised, morning
    }

    static func isRequest(_ q: String) -> Bool {
        let ask = ["适合", "能不能", "能否", "可以", "要不要", "该不该", "行不行", "合适", "能练", "能跑", "还要", "还能", "去不去", "该去"]
        let act = ["练", "训练", "运动", "跑", "骑", "游泳", "力量", "撸铁", "举铁", "举重", "深蹲", "间歇", "长距离", "健身", "锻炼",
                   "散步", "走路", "快走", "拉伸", "瑜伽", "动一动"]
        let asks = ask.contains(where: { q.contains($0) }) || q.range(of: "(能|可以)[^，。？]{0,8}(吗|不|么)", options: .regularExpression) != nil
        guard asks, act.contains(where: { q.contains($0) }) else { return false }
        // Glucose and blood-pressure thresholds before exercise have their own answers.
        return !q.contains("血糖") && !q.contains("血压")
    }

    static func session(in q: String) -> Session {
        if ["大力量", "大重量", "极限", "冲重量", "撸铁", "举铁", "举重", "1RM", "大强度力量"].contains(where: { q.contains($0) }) { return .heavyStrength }
        if q.contains("力量") && (q.contains("高强度") || q.contains("大强度")) { return .heavyStrength }
        if ["力量", "深蹲", "硬拉", "卧推", "健身房"].contains(where: { q.contains($0) }) { return .strength }
        if ["间歇", "强度课", "节奏跑", "冲刺", "HIIT", "高强度"].contains(where: { q.contains($0) }) { return .intervals }
        if ["长距离", "长跑", "LSD", "半马", "全马"].contains(where: { q.contains($0) }) { return .long }
        if ["轻松", "慢跑", "散步", "快走", "瑜伽", "拉伸"].contains(where: { q.contains($0) }) { return .easy }
        return .any
    }

    /// Before 5 am the night is not over: "明天" is the coming daytime, i.e. today's date.
    static func isBeforeWake(_ now: Date, profile p: ProfileSnapshot? = nil) -> Bool { DayClock.isBeforeWake(now, p) }

    static func targetDay(_ q: String, now: Date, profile p: ProfileSnapshot? = nil) -> Date {
        let today = now.startOfDay
        let early = isBeforeWake(now, profile: p)
        if q.contains("后天") { return today.adding(days: early ? 1 : 2) }
        if q.contains("明天") || q.contains("明早") || q.contains("明晚") { return today.adding(days: early ? 0 : 1) }
        if q.contains("今天") || q.contains("今晚") || q.contains("现在") || q.contains("等会") { return today }
        // No day named: late in the evening the next training day is meant.
        return now.minutesOfDay >= 21 * 60 ? today.adding(days: 1) : today
    }

    /// Minutes of sleep still possible before the usual wake time, when the target is the next
    /// morning and it is already evening or night.
    static func sleepOpportunity(now: Date, target: Date, profile p: ProfileSnapshot) -> Int? {
        let logical = DayClock.logicalToday(now, p)
        guard target == logical.adding(days: 1) else { return nil }
        let w = DayClock.window(for: logical, profile: p)
        // Only from the evening (four hours before the main sleep) on.
        guard now >= w.bed.addingTimeInterval(-4 * 3600) else { return nil }
        return max(0, Int(w.nextWake.timeIntervalSince(max(now, w.bed)) / 60) - 15)
    }

    static func reply(_ q: String, context c: AgentContext) -> AgentReply {
        let p = c.profile
        let now = c.now
        // "现在适合跑步吗？" (or "今天…" late in the evening) is about the time left before bed,
        // not about the coming day.
        let aboutNow = HealthAgent.asksAboutNow(q) || q.contains("这会儿")
            || (!c.beforeWake && q.contains("今天") && targetDay(q, now: now, profile: p) == now.startOfDay)
        if aboutNow, let s = p.shift, c.window.kind == .night, c.now < c.window.bed,
           c.now.minutesOfDay >= s.nightStart || c.now.minutesOfDay < s.nightEnd {
            let first = "你现在在上夜班，先别安排训练：下班后按安排 \(Clock.text(c.window.bed.minutesOfDay)) 补觉，睡醒以后再做 20–30 分钟轻松活动。"
            return AgentReply(text: first + "\n\n" + ["夜班中想提提神，可以起来走动几分钟、做做拉伸", "下班路上戴墨镜、少看手机，到家尽快睡",
                                                       "强度课和大重量放到作息调回来、睡够的一天"].map { "• " + $0 }.joined(separator: "\n"),
                              sources: ["倒班安排"], followUps: ["夜班后怎么补觉？"], destination: .sleep, conclusion: first)
        }
        if aboutNow, c.nearBedtime {
            return nowReply(q, context: c)
        }
        let today = now.startOfDay
        let target = targetDay(q, now: now, profile: p)
        var session = session(in: q)
        let planned = c.plan.filter { $0.day == target && $0.status == .planned }
        let plannedTraining = planned.filter { $0.kind.isTraining }
        let namedActivity = ["跑步", "跑", "骑车", "骑行", "游泳", "快走", "散步", "走路", "爬山", "徒步"].contains { q.contains($0) }
        let defaulted = session == .any && !namedActivity
        if session == .any, namedActivity { session = .easy }
        if session == .any {
            // Nothing named: judge the day's planned training, or light activity when none is planned.
            if let s = plannedTraining.max(by: { $0.intensity < $1.intensity }) {
                session = s.kind == .strength ? .strength : (s.intensity == .hard || s.kind == .quality ? .intervals : (s.kind == .long ? .long : .easy))
            } else {
                session = .easy
            }
        }
        let df = Date.FormatStyle().month().day().weekday(.abbreviated).locale(Locale(identifier: "zh_CN"))
        let early = c.beforeWake
        // Use the user's own word for the day: at 2 am, "明天" is today's date.
        let offset = target.daysSince(today) + (early ? 1 : 0)
        let said = q.contains("后天") ? "后天" : (q.contains("明天") || q.contains("明早") ? "明天" : (q.contains("今天") ? "今天" : nil))
        let dayName = said ?? (offset == 0 ? "今天" : (offset == 1 ? "明天" : (offset == 2 ? "后天" : "那天")))
        let dayText = "\(dayName)（\(target.formatted(df))）"
        var facts: [String] = []
        var sleepBlocked = false
        var sleepLine: String? = nil
        var blockers: [String] = []
        var cautions: [String] = []
        var weatherNotes: [String] = []
        // A dialysis day: no training; light walking at most, after resting.
        if Dialysis.isDay(target, p) {
            let line = "\(dayName)是透析日，透析前后身体负担大"
            if session == .easy { cautions.append(line + "，透析后先休息，想活动就在家慢慢走几分钟。") }
            else { blockers.append(line + "，不安排训练；把训练放到不透析的日子。") }
        }

        // At 2 am the user's "明天" (or "今天") both mean the coming daytime; say how it was read.
        let clarified = early && target == today && said != nil

        // 1. Sleep still possible tonight.
        let need = Int(p.sleepNeedMinutes)
        let opportunity = sleepOpportunity(now: now, target: target, profile: p)
        if let o = opportunity {
            let hours = (Double(o) / 60).oneDecimal
            let wakeText = Clock.text(DayClock.window(for: c.logicalToday, profile: p).nextWake.minutesOfDay)
            let line = (clarified ? "现在\(now.hour < 5 ? "是凌晨" : "") \(Clock.text(now.minutesOfDay))（「\(dayName)」按睡醒后的\(p.shift == nil ? "白天" : "这一天")理解），" : "现在 \(Clock.text(now.minutesOfDay))，")
                + "到\(p.shift == nil ? "你平时" : "下次") \(wakeText) 起床最多还能睡约 \(hours) 小时，你需要约 \((Double(need) / 60).oneDecimal) 小时。"
            if o < 360 {
                sleepLine = line
                blockers.append(line + (session == .easy ? "睡眠明显不足，身体恢复慢，以轻松活动为主。"
                                        : "睡眠明显不足时，力量、协调和反应都会下降，大重量和高强度训练更容易受伤，恢复也更慢。"))
                sleepBlocked = true
            } else if o < need - 30 {
                cautions.append(line + "睡眠会比平时少一些。")
            } else {
                facts.append(line)
            }
        }

        // 2. Readiness, only when the target day has actually started and been measured.
        let measured = target == today && !early && c.readiness.score != nil
            && (c.days.first { $0.day == today }.map { $0.rhr != nil || $0.sleepMinutes != nil || $0.checkedIn } ?? false)
        if measured, let s = c.readiness.score {
            let line = "今天准备度 \(s)（\(c.readiness.level.label)）。"
            switch c.readiness.level {
            case .rest: blockers.append(line + c.readiness.recommendation)
            case .low:
                if session.demanding || session == .strength { blockers.append(line + c.readiness.recommendation) } else { cautions.append(line) }
            case .moderate: cautions.append(line + "基本恢复，强度课和大重量适当减量。")
            case .high: facts.append(line)
            }
        }

        // 3. Tonight: alcohol, stress, fatigue, soreness (the record for the evening that is ending).
        let evening = c.days.first { $0.day == c.logicalToday }
        if let e = evening, opportunity != nil {
            if e.hadAlcohol { cautions.append("今晚喝了酒（\(e.alcoholUnits.oneDecimal) 单位），第二天早上静息心率通常偏高、恢复变慢。") }
            if (e.eveningFatigue ?? 0) >= 4 { cautions.append("今晚记录的疲劳感较高（\(e.eveningFatigue ?? 0)/5）。") }
            if (e.eveningSoreness ?? 0) >= 2, session == .heavyStrength || session == .strength {
                cautions.append("今晚记录了肌肉酸痛（\(e.eveningSoreness ?? 0)/3），酸痛部位不宜再加大重量。")
            }
        }
        // How the user says they feel counts as much as the numbers.
        if AskedSymptom.find(in: q) == .fatigue {
            cautions.append(measured && c.readiness.level == .high ? "你说今天有点累：数据显示恢复得不错，但感受更重要，按感受来。" : "你说今天有点累。")
        }
        if c.days.contains(where: { $0.day >= today.adding(days: -2) && $0.illness }) {
            blockers.append("最近两天记录了生病 / 不适，症状消退 1–2 天后再恢复训练。")
        }

        if p.shift != nil, session.demanding || session == .heavyStrength {
            let tw = DayClock.window(for: target, profile: p)
            if tw.afterNightShift { blockers.append("那天是夜班后的恢复日，白天只补几个小时觉，不做间歇、长距离和大重量。") }
            else if tw.kind == .night { blockers.append("那天晚上要上夜班，白天别把体力用在强度课上。") }
        }

        // 4. Load, care limits and vitals.
        if session.demanding || session == .strength, c.load.zone == .high {
            blockers.append("近期训练负荷增长过快（负荷比 \(c.load.ratio.map { String(format: "%.2f", $0) } ?? "—")），先稳住，不再加大强度。")
        } else if session.demanding, c.load.zone == .caution {
            cautions.append("近期训练负荷增长偏快，强度课适当减量。")
        }
        if c.openEvents.contains(where: { $0.severity == .urgent }) {
            blockers.append("有尚未处理的紧急提醒，确认身体状况之前不建议训练。")
        }
        if p.cardiacLimited, session == .heavyStrength || session == .intervals {
            blockers.append("你记录了心血管相关情况，较高强度和大重量需要医生确认后再做。")
        } else if p.intensityCapped, session == .heavyStrength || session == .intervals {
            blockers.append("你记录了\(p.intensityCaps.joined(separator: "、"))，较高强度和大重量需要医生确认后再做。")
        }
        if let k = c.lab(.potassium, within: 30) {
            let s = LabAnalyzer.status(.potassium, k.value, profile: p)
            if s.level == .urgent, session != .easy {
                blockers.append("\(k.date.formatted(.dateTime.month().day())) 的血钾 \(k.valueText) mmol/L \(s.text)，先联系医生，处理好之前不做运动。")
            } else if s.level == .abnormal, session.demanding || session == .heavyStrength {
                blockers.append("\(k.date.formatted(.dateTime.month().day())) 的血钾 \(k.valueText) mmol/L \(s.text)，复查正常之前不做高强度和大重量。")
            }
        }
        if let h = c.lab(.hemoglobin, within: 90), h.value < (p.sex == .female ? 120 : 130), session != .easy {
            cautions.append("血红蛋白 \(h.valueText) g/L 偏低，心率会比平时高、更容易累，强度以主观感受为准。")
        }
        if let x = p.extraConditions.first(where: { !$0.stopSigns.isEmpty }), session != .easy {
            cautions.append("\(x.name)：" + x.stopSigns)
        }
        if session == .heavyStrength, let sys = c.bp.avgSys?.rounded(), let dia = c.bp.avgDia?.rounded() {
            if sys >= 160 || dia >= 100 {
                blockers.append("近 30 天平均血压 \(Int(sys))/\(Int(dia)) mmHg，血压控制好之前先避免大重量和憋气用力，这类动作会让血压明显升高。")
            } else if sys >= 140 || dia >= 90 {
                cautions.append("近 30 天平均血压 \(Int(sys))/\(Int(dia)) mmHg，偏高：做力量时保持呼吸、不憋气，不冲极限重量。")
            }
        }
        if p.hasDiabetes && p.hypoRiskMeds(at: now) && session != .easy {
            cautions.append(c.lows.isEmpty ? "训练前看一下血糖，随身带快速碳水。" : "近 14 天有 \(c.lows.count) 次低血糖，训练前看一下血糖，随身带快速碳水。")
        }
        if session.demanding || session == .heavyStrength {
            let dayBefore = target.adding(days: -1)
            if c.plan.contains(where: { $0.day == dayBefore && ($0.intensity == .hard || $0.kind == .long) && $0.status != .skipped }) {
                cautions.append("前一天也安排了强度或长距离训练，两次高负荷之间最好隔一天。")
            }
        }

        // 5. Weather, for a session done outdoors.
        var weatherLine: String? = nil
        var indoors = false
        let indoorAsked = ["室内", "跑步机", "健身房", "动感单车", "游泳"].contains { q.contains($0) }
        let outdoor = !indoorAsked && (plannedTraining.isEmpty
            ? [.easy, .long, .intervals].contains(session) : plannedTraining.contains(where: WeatherPlanner.isOutdoor))
        if outdoor, target >= c.logicalToday, let w = c.weather(on: target) {
            let k = w.concerns
            let indoorsForMe = WeatherPlanner.movesIndoors(w, for: p)
            if (k.contains(.extremeHeat) || k.contains(.heat)) && !indoorsForMe {
                weatherNotes.append("\(dayName)最高 \(Int(w.high))°C，在户外的话强度降一级，放在早上 7 点前或傍晚 7 点后，带水，觉得头晕、恶心就停下来。")
            }
            if k.contains(.badAir) || k.contains(.air) {
                weatherNotes.append("\(dayName)空气质量\(k.contains(.badAir) ? "差" : "一般")（AQI \(w.aqi ?? 0)），在户外的话练得轻松些。")
            }
            if indoorsForMe {
                indoors = true
                weatherLine = "\(dayName)\(WeatherPlanner.reason(w, for: p))，不适合在户外练：改在\(k.contains(.heat) ? "有空调的" : "")室内（跑步机、动感单车或有氧操）完成，或者换到天气好的一天。"
            } else if k.contains(.cold) {
                weatherLine = "\(dayName)最高 \(Int(w.high))°C，热身多做 5 分钟，穿可以随时脱的几层衣服。"
            } else if k.contains(.wet) || k.contains(.storm) {
                weatherLine = "\(dayName)可能有雨，出门前看一眼雨情。"
            } else if k.isEmpty {
                facts.append("\(dayName)\(w.label)，\(Int(w.low))–\(Int(w.high))°C，适合户外。")
            }
        }

        // Verdict.
        let verdict: Verdict
        if !blockers.isEmpty && session != .easy { verdict = .notAdvised }
        else if !blockers.isEmpty || !cautions.isEmpty { verdict = .easier }
        else if !measured && target >= today { verdict = .morning }
        else { verdict = .go }

        // The user's own word for the activity, when it is a plain one ("跑步"), for the weather sentence.
        let asked = ["跑步", "骑行", "骑车", "快走", "散步", "徒步", "爬山", "游泳"].first { q.contains($0) } ?? (q.contains("跑") ? "跑步" : session.label)
        var head: String
        switch verdict {
        case .notAdvised: head = "不建议\(dayText)做\(session.label)。"
        case .easier: head = session == .easy ? "\(dayText)可以做轻松的活动，但量要少一点。" : "\(dayText)可以练，但要降低强度。"
        // The body can be ready while the weather is not: say both, and which is which.
        case .morning: head = indoors ? "身体方面目前没有明显的阻碍，但\(dayText)的天气不适合户外，\(asked)改在室内做。"
                                      : "目前没有看到明显的阻碍，\(dayText)能不能做\(session.label)，最后要看当天早上的准备度。"
        case .go: head = indoors ? "从身体状态看\(dayText)可以\(asked)，但天气不适合户外，改在室内做。" : "\(dayText)适合做\(session.label)。"
        }

        if namedActivity, session == .easy {
            switch verdict {
            case .go: head = indoors ? head : "\(dayText)可以去\(asked)，保持轻松。"
            case .easier: head = "\(dayText)可以去\(asked)，但量要少一点、强度放轻。"
            case .notAdvised: head = "不建议\(dayText)去\(asked)。"
            case .morning: break
            }
        } else if defaulted, plannedTraining.isEmpty, verdict == .go, target == today {
            head = "\(dayText)计划里是休息，状态不错，想动的话做点轻松活动就好。"
        }
        // Tired today: the answer is about how the user feels, with the plan for the day.
        if AskedSymptom.find(in: q) == .fatigue, target == today, verdict != .notAdvised {
            if plannedTraining.isEmpty {
                // A rest day anyway: nothing to grade, only to say so.
                let rest = "\(dayText)计划里本来就是休息，累的话就别\(asked == session.label ? "练" : asked)了，散散步或拉伸一下就好。"
                return AgentReply(text: rest + "\n\n" + ["今晚早点睡，明天起床看准备度再安排", "累了两三天还不见好，留意是不是快生病了"].map { "• " + $0 }.joined(separator: "\n"),
                                  sources: ["\(dayName)计划", measured ? "今天准备度" : nil].compactMap { $0 }, followUps: ["明天适合运动吗？"],
                                  destination: .plan, conclusion: rest)
            }
            head = "累的话\(dayText)的「\(plannedTraining[0].title)」降一级：强度放轻、时间缩短三分之一，练着更累就停。"
        }
        var parts: [String] = [([head] + facts + blockers).joined(separator: "")]
        if !(cautions + weatherNotes).isEmpty { parts.append((cautions + weatherNotes).joined(separator: "")) }
        if let w = weatherLine { parts.append(w) }
        if !planned.isEmpty {
            let desc = PlanChat.describe(planned)
            parts.append("计划里\(dayName)是：\(desc)。" + (session == .heavyStrength && !plannedTraining.contains { $0.kind == .strength } ? "计划里没有大重量训练，想加的话放在睡够、准备度好的一天。" : ""))
        }

        var tips: [String] = []
        if opportunity != nil, opportunity ?? 0 < need - 30 { tips.append("现在先睡，明早做晨起评估，Pulse 会按实际睡眠、静息心率和 HRV 给出准备度。") }
        switch verdict {
        case .notAdvised:
            tips.append(session == .easy ? "\(dayName)以散步、拉伸这类轻松活动为主，不额外加训练。"
                        : "\(dayName)改成 20–30 分钟轻松活动或拉伸；\(session.label)挪到睡够、准备度好的一天，不需要补练。")
            // Only when lack of sleep is the one reason: the morning can still change the picture.
            if sleepBlocked && blockers.count == 1, session == .heavyStrength || session == .strength {
                tips.append("如果早上状态确实不错，重量降到平时的 60–70%，减少组数，不做极限重量，不憋气。")
            }
        case .easier:
            tips.append(session == .heavyStrength || session == .strength ? "重量降到平时的 60–70%，组数减少约 1/3，以动作质量为主，不冲极限。"
                        : "强度降一级、时长缩短约 1/3，以能完整说话为准。")
        case .morning:
            tips.append("早上醒来记录感受（约 20 秒），准备度偏低就改成轻松活动。")
        case .go:
            tips.append(namedActivity ? "充分热身，\(asked == "跑步" ? "跑" : "练")的时候以能完整说话为准；计划里的训练照常做或者换一天，别一天塞太多。"
                        : (defaulted && plannedTraining.isEmpty ? "散步、骑车或拉伸 20–40 分钟就好，不用额外加训练。" : "充分热身 10 分钟，按计划完成，不额外加量。"))
        }
        if session == .heavyStrength || session == .strength { tips.append("任何时候出现胸痛、胸闷、头晕或明显气短，立即停止。") }
        parts.append(tips.map { "• " + $0 }.joined(separator: "\n"))

        // Offer to move a planned demanding session out of a day that is not advised.
        var blocks: [AgentUIBlock] = []
        if verdict == .notAdvised, let s = plannedTraining.first(where: { $0.kind == .strength || $0.intensity == .hard || $0.kind == .long }) {
            let scope: PlanScope = target >= today.weekStart.adding(days: 7) ? .nextWeek : .thisWeek
            let ws = PlanChat.weekStart(scope, now: now)
            let open = PlanChat.editable(c.plan.filter { $0.day >= ws && $0.day < ws.adding(days: 7) }, weekStart: ws, now: now)
            let free = Weekday.mondayFirst.filter { wd in
                let d = PlanChat.day(wd, ws)
                return d > target && open.contains(wd) && !c.plan.contains { $0.day == d && $0.kind.isTraining }
            }.first
            let wd = target.weekday
            let op: PlanEditOp = free.map { .move(from: wd, to: $0) }
                ?? .replace(day: wd, kind: .mobility, title: "轻松活动或拉伸", minutes: 25, intensity: .easy,
                            detail: "睡眠不足的一天以恢复为主，计划中的训练不需要补回。", target: s.kind)
            var proposal = PlanChat.propose([op], scope: scope, request: "睡眠不足，\(dayName)不做\(s.title)", context: c, source: "Pulse 规则")
            proposal.notes = [free == nil ? "这周后面没有空出来的日子，\(dayName)先换成轻松活动。" : "把「\(s.title)」挪到睡够之后的\(Weekday.name(free!))。"] + proposal.notes
            if proposal.hasChanges { blocks.append(.plan(proposal)) }
        }

        return AgentReply(text: parts.joined(separator: "\n\n"),
                          sources: [opportunity != nil ? "现在时间与起床时间" : nil, measured ? "今天准备度" : nil, "训练负荷", "\(dayName)计划",
                                    outdoor && c.weather(on: target) != nil ? "天气预报" : nil].compactMap { $0 },
                          followUps: opportunity != nil ? ["熬夜后怎么恢复？"] : ["这周的训练完成得怎么样？"],
                          destination: blocks.isEmpty ? .plan : nil, blocks: blocks,
                          // Not advised: the reason goes with the verdict, so a model rewording it keeps both.
                          conclusion: head + (sleepLine ?? (verdict == .notAdvised ? blockers.first ?? "" : ""))
                            + (weatherLine.flatMap { w in c.weather(on: target)?.movesIndoors == true ? w : nil } ?? ""))
    }

    /// "现在 / 今晚适合…吗？" near or after bedtime: graded by the time left before sleep.
    static func nowReply(_ q: String, context c: AgentContext) -> AgentReply {
        let p = c.profile
        let s = session(in: q)
        let toBed = c.pastBedtime ? 0 : Int(c.window.bed.timeIntervalSince(c.now) / 60)
        let finishBy = Clock.text(c.window.bed.minutesOfDay - 60)
        let text: String
        var tips: [String]
        let tired = AskedSymptom.find(in: q) == .fatigue
        if tired, !c.pastBedtime {
            let what = ["跑步", "跑", "骑车", "游泳", "力量", "健身"].first { q.contains($0) } ?? "练"
            text = "累的话今晚就别\(what == "跑" ? "跑了" : (what == "练" ? "练了" : "去\(what)了"))，散散步或拉伸 10 分钟就好。现在 \(c.clock)，离\(c.bedPhrase) 入睡约 \((Double(toBed) / 60).oneDecimal) 小时，今晚早点睡，明天起床看准备度再安排。"
            tips = ["洗个温水澡，睡前 1 小时放下手机", "训练不用补，明天按准备度来"]
        } else if c.pastBedtime {
            text = "现在不建议\(s == .any ? "运动" : "做\(s.label)")。现在 \(c.clock)，已过\(c.bedPhrase) 的入睡时间，运动会让心率和体温升高、推迟入睡，反而影响明天的恢复。"
            tips = ["现在做 5–10 分钟轻柔拉伸或慢呼吸（吸 4 秒、呼 6 秒），然后睡觉", "训练放到明天，起床后看准备度再定强度"]
        } else if toBed < 60 {
            text = s == .easy ? "可以，但只做轻柔的。现在 \(c.clock)，离\(c.bedPhrase) 入睡不到 1 小时，散步或拉伸 10–15 分钟就好。"
                : "现在不建议\(s == .any ? "运动" : "做\(s.label)")。现在 \(c.clock)，离\(c.bedPhrase) 入睡不到 1 小时，这时候运动容易推迟入睡。"
            tips = ["换成 10 分钟轻柔拉伸或慢呼吸", "训练放到明天，起床后看准备度再定强度"]
        } else if s.demanding || s == .heavyStrength {
            text = "现在不建议做\(s.label)。现在 \(c.clock)，离\(c.bedPhrase) 入睡约 \((Double(toBed) / 60).oneDecimal) 小时，睡前几小时的高强度训练会让身体迟迟静不下来，影响入睡和夜间恢复。"
            tips = ["想动的话换成轻松有氧或散步，\(finishBy) 前结束", "\(s.label)放到明天白天，起床后看准备度再定"]
        } else {
            text = "可以，保持\(s == .strength ? "中等强度" : "轻松")。现在 \(c.clock)，离\(c.bedPhrase) 入睡约 \((Double(toBed) / 60).oneDecimal) 小时，在 \(finishBy) 前结束，留出 1 小时让身体放松下来就不太影响入睡。"
            tips = [s == .strength ? "不冲重量、不做到力竭" : "强度保持能完整说话", "结束后洗个温水澡\(p.fluidLimited ? "" : "、补点水")，睡前不再看手机"]
        }
        if c.readiness.level == .low || c.readiness.level == .rest, !c.beforeWake, c.readiness.score != nil, !c.pastBedtime {
            tips.insert("今天准备度偏低（\(c.readiness.score ?? 0)），今晚更适合休息", at: 0)
        }
        let first = text.split(separator: "。", maxSplits: 1).first.map { String($0) + "。" }
        return AgentReply(text: text + "\n\n" + tips.map { "• " + $0 }.joined(separator: "\n"),
                          sources: ["现在时间", "入睡时间设置"], followUps: ["明天适合运动吗？", c.pastBedtime ? "睡不着怎么办？" : "今晚该注意什么？"],
                          conclusion: first)
    }
}
