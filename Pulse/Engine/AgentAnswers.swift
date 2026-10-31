import Foundation

// MARK: - Answers to what a question names

/// Answers chosen from what the question itself says — a reading (「血压155要紧吗」), a food, a
/// symptom, or a kind of question the topic answers don't cover (「多久复查」「准备度怎么算」).
/// Each starts with a direct answer; data follows only where it bears on the question.
extension HealthAgent {
    static func specific(_ a: AgentQuestion, context c: AgentContext) -> AgentReply? {
        let q = a.text
        // Pulse itself: where the data goes, what the advice rests on.
        if a.has(["上传", "隐私", "泄露", "数据安全", "发到云", "服务器", "谁能看到", "会不会发送", "会发送"]) && !a.has(["血压", "血糖"]) {
            return privacyAnswer(c)
        }
        if a.has(["依据", "根据什么", "怎么得出", "靠谱吗", "准不准", "可信吗"]) && a.has(["你", "建议", "回答", "分析", "Pulse", "Agent"]) {
            return aboutAnswer(c)
        }
        if AgentName.asksName(q) { return nameAnswer(c) }
        // Nothing to read (「？？？」) or not Chinese: say so rather than guess.
        let letters = q.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        let chinese = q.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
        if letters.isEmpty || (!chinese && letters.count >= 3) {
            let text = letters.isEmpty ? "没太看懂你的问题，可以换个说法，或者点下面的问题试试。"
                : "现在请用中文提问，比如「今天适合跑步吗？」，我会结合你的记录回答。"
            return AgentReply(text: text, followUps: ["我最近整体怎么样？", "今天适合运动吗？"], intent: .about, conclusion: text, verbatim: true)
        }
        // Dialysis warning signs (peritonitis, a blocked fistula) come before anything else they mention.
        if let w = KidneySigns.askedWarning(q, profile: c.profile) { return w }
        if let r = courtesy(q) ?? reminderRequest(a, context: c) ?? mood(a, context: c) { return r }
        // A blood pressure or glucose reading decides the answer; the symptom with it is part of it
        // (「血压88/55头有点晕」).
        switch a.reading {
        case .bp(let sys, let dia)?: return bpReading(sys: sys, dia: dia, a, context: c)
        case .glucose(let v, let ctx)?: return glucoseReading(v, ctx, a, context: c)
        case .lab(let k, let v, let unit, let guessed)?: return labReading(k, value: v, unit: unit, guessed: guessed, a, context: c)
        case .weight(let kg)?: return weightReading(kg, a, context: c)
        default: break
        }
        // 「喝酒后第二天能跑步吗」 is about the drink, not the day's plan.
        if a.has(["喝酒后", "酒后", "喝了酒", "喝完酒", "宿醉", "喝过酒"]), a.has(["跑", "练", "运动", "锻炼", "健身", "骑"]) {
            var r = alcohol(c, question: q)
            r.intent = .alcohol
            return r
        }
        // A symptom matters more than the food or number that comes with it (「吃了香蕉头晕」).
        if let s = a.symptom {
            // 「有点累，还要去跑步吗」 is a training question; the check weighs the tiredness.
            if s == .fatigue, TrainingCheck.isRequest(q) { return nil }
            return SymptomGuide.reply(s, a, context: c)
        }
        if let k = knowledge(a, context: c) { return k }
        if let r = careAnswer(a, context: c) { return r }
        switch a.reading {
        case .sleepHours(let h)? where h * 60 < c.profile.sleepNeedMinutes - 60: return shortNight(hours: h, a, context: c)
        case .weightChange(let kg)?: return weightChange(kg: kg, a, context: c)
        default: break
        }
        if let f = a.food { return FoodGuide.reply(f, a, context: c) }
        if q.contains("准备度"), a.form == .explain || a.has(["怎么算", "怎么来", "依据", "根据什么"]) { return readinessExplained(c) }
        if a.has(["复查", "复诊", "检查", "化验", "抽血"]), a.has(["多久", "多长时间", "隔多", "频率", "几个月", "什么时候", "安排", "日程", "哪天", "日期"]) { return recheck(c) }
        if a.has(["盐"]), a.form == .why || a.has(["为什么", "为啥"]) { return saltWhy(c) }
        if a.has(["盐"]), a.form == .how || a.has(["少吃盐", "控盐", "限盐", "低盐", "减盐"]) { return saltTips(c) }
        if a.has(["药"]), a.has(["早上吃还是晚上吃", "什么时候吃", "几点吃", "饭前吃还是饭后吃", "饭前还是饭后", "早上还是晚上", "漏吃", "忘了吃", "漏服", "忘吃"]) {
            return medTiming(a, context: c)
        }
        if q.contains("空腹"), a.has(["跑", "运动", "练", "锻炼", "健身"]) { return fastedExercise(c) }
        if a.has(["马拉松", "全马", "半马"]), a.form == .canI || a.has(["适合", "能跑", "可以跑", "准备"]) {
            if c.race == nil { return marathonFit(a, context: c) }
            var r = marathon(c, question: q)
            r.intent = .marathon
            return r
        }
        if a.has(["减肥", "减重", "瘦下来", "减脂", "瘦一点"]) || (q.contains("饿") && !a.has(["低血糖"])) { return eating(a, context: c) }
        if a.has(["吃什么", "怎么吃", "吃点什么", "推荐吃", "该吃"]) { return mealIdeas(c) }
        return nil
    }

    // MARK: Readings

    /// 「今天早上血压155，要紧吗」: this reading, against the thresholds and the person's own usual.
    static func bpReading(sys: Int, dia: Int?, _ a: AgentQuestion, context c: AgentContext) -> AgentReply {
        let p = c.profile
        let shown = dia.map { "\(sys)/\($0)" } ?? "收缩压 \(sys)"
        let d = dia ?? 0
        let crisis = sys >= 180 || d >= 110
        let veryHigh = sys >= 160 || d >= 100
        let high = sys >= 135 || d >= 85
        let low = sys < 90 || (dia.map { $0 < 60 } ?? false)
        let verdict: String
        if crisis { verdict = "\(shown) 很高，需要马上处理。" }
        else if veryHigh { verdict = "\(shown) 明显偏高，但单次读数一般不需要紧急处理。" }
        else if high { verdict = "\(shown) 偏高，单次这样不用太紧张。" }
        else if low { verdict = "\(shown) 偏低。" }
        else { verdict = "\(shown) 在正常范围内。" }

        // Against the person's own usual at that time of day.
        let morning = a.has(["早上", "早晨", "晨起", "起床"]), evening = a.has(["晚上", "睡前"])
        let usual = morning ? c.bp.morningSys : (evening ? c.bp.eveningSys : c.bp.avgSys)
        var compare: String? = nil
        if let u = usual, c.bp.count >= 5 {
            let diff = Double(sys) - u
            let when = morning ? "晨起" : (evening ? "晚上" : "平时")
            compare = abs(diff) < 5 ? "和你\(when)的收缩压（约 \(Int(u))）差不多。"
                : "你\(when)的收缩压约 \(Int(u))，这次\(diff > 0 ? "高" : "低") \(Int(abs(diff).rounded()))。"
        }
        // What the day's records show that often goes with a high morning reading.
        var maybe: [String] = []
        let today = c.days.first { $0.day == c.logicalToday }
        let yesterday = c.days.first { $0.day == c.logicalToday.adding(days: -1) }
        if high || veryHigh {
            if today?.medsTaken == false || yesterday?.medsTaken == false, !c.medications.isEmpty { maybe.append(today?.medsTaken == false ? "今天的服药还没打勾" : "昨天记录了没按时吃药") }
            if let s = today?.sleepMinutes, s < 360 { maybe.append("昨晚只睡了 \((s / 60).oneDecimal) 小时") }
            if yesterday?.hadAlcohol == true { maybe.append("昨天喝了酒") }
            if let y = yesterday, y.nutrientsLogged, KidneyDiet.salty(y, limit: p.saltLimitG) { maybe.append("昨天吃得偏咸") }
            if yesterday?.highStress == true { maybe.append("昨天压力比较大") }
        }
        var steps: [String] = []
        if crisis {
            steps = ["静坐 5 分钟后再测一次",
                     "复测还在 180/110 以上，同时有胸痛、胸闷、气短、剧烈头痛、看东西模糊、一侧手脚无力或说话不清，立即拨打 120",
                     "没有这些症状，也请今天就联系医生"]
        } else if high || veryHigh {
            steps.append("静坐 5 分钟，背靠椅背、袖带和心脏同高，再测两次取平均")
            if today?.medsTaken == false, !c.medications.isEmpty { steps.append("如果今天的降压药还没吃，按医生交代的时间吃，不要自己加量") }
            steps.append(veryHigh ? "如果接下来两三天早上还在 160 以上，尽快约医生（要不要调整治疗由医生决定）"
                                  : "如果接下来一周早上的平均值都在 135/85 以上，复诊时把记录给医生看")
        } else if low {
            steps = ["先坐下或躺下，有头晕就别急着站起来", "过 5 分钟再测一次",
                     c.medications.isEmpty ? "经常低于 90 又有头晕乏力，去看医生" : "经常低于 90，或伴有头晕、乏力，告诉医生；降压药不要自己停"]
        } else {
            steps = ["继续按平时的时间测，早晚各一次最能看出变化"]
        }
        let exercise = a.has(["运动", "跑", "练", "锻炼", "散步", "健身"])
        var exerciseLine: String? = nil
        if exercise {
            let walk = a.has(["散步", "走路", "遛弯"])
            exerciseLine = crisis ? "今天先不要运动。"
                : veryHigh ? "复测降到 160/100 以下之前，只做散步这类轻松活动，不做力量和憋气用力的动作。"
                : high ? (walk ? "可以去散步，保持轻松。" : "可以运动，以中低强度为主，不做憋气用力的动作。")
                : low ? "有头晕的话今天先别运动。" : "可以按计划运动。"
        }
        let first = verdict + (compare ?? "")
        return AgentReply(text: lines([
            first,
            maybe.isEmpty ? nil : "记录里今天可能有关的：\(maybe.joined(separator: "、"))（不一定是原因）。",
            exerciseLine,
            bullets(steps),
        ]), sources: ["你说的读数", "血压 近 30 天"], followUps: ["我的血压控制得怎么样？"], destination: .vitals, intent: .reading,
                          conclusion: first, safety: crisis ? steps[1] + "；" + steps[2] + "。" : nil)
    }

    /// 「晚饭后血糖12正常吗」: this reading, with the target for when it was taken.
    static func glucoseReading(_ v: Double, _ ctx: MeasureContext?, _ a: AgentQuestion, context c: AgentContext) -> AgentReply {
        let p = c.profile
        let diabetes = p.hasDiabetes
        let t1 = p.conditions.contains(.diabetesT1)
        let shown = v.oneDecimal
        let post = ctx == .postMeal
        let fasting = ctx == .fasting || ctx == .preMeal
        let upper: Double = diabetes ? (fasting ? 7.0 : 10.0) : (fasting ? 6.1 : 7.8)
        let when = post ? "饭后 2 小时" : (fasting ? "空腹" : "")
        var verdict: String
        var steps: [String] = []
        if v < 3.0 {
            verdict = "\(shown) 是严重的低血糖，现在就要处理。"
            steps = ["马上吃 15–20 g 升糖快的东西：半杯果汁或含糖饮料、3–4 块方糖", "15 分钟后再测，还低就再吃一次",
                     "意识不清、吞咽困难时不要喂东西，立即拨打 120", "事后告诉医生"]
        } else if v < p.glucoseLow {
            verdict = "\(shown) 低于 \(p.glucoseLow.oneDecimal)，是低血糖，先处理。"
            steps = ["马上吃 15 g 升糖快的东西：半杯果汁、3 块方糖或几块饼干", "15 分钟后再测，还低就再吃一次", "回到正常后，离下顿饭还久的话再吃点主食"]
        } else if v >= 16.7 {
            verdict = "\(shown) 明显偏高。"
            steps = ["\(p.fluidLimited ? "在医生允许的饮水量内喝点水" : "多喝点水")，1–2 小时后再测",
                     "有口渴、尿多、恶心呕吐、明显乏力，或者一直降不下来，今天就联系医生"]
            if t1 { steps.insert("测一下血酮或尿酮", at: 1) }
        } else if v > upper {
            verdict = diabetes ? "\(shown) 偏高（\(when.isEmpty ? "" : when)一般希望在 \(upper.oneDecimal) 以下），单次这样不用紧张。"
                : "\(shown) 偏高（\(when.isEmpty ? "" : when)一般在 \(upper.oneDecimal) 以下）。"
            if post {
                steps = ["饭后散步 10–15 分钟", "先吃菜和肉，主食放最后，主食换一部分粗粮"]
            } else if fasting {
                steps = ["晚饭别太晚、别太多，睡前不吃夜宵"]
            }
            steps.append(diabetes ? "如果连续两周都这样，带着记录问医生要不要调整方案（药怎么调由医生定）"
                                  : "改天\(when.isEmpty ? "空腹" : when)再测一次；还偏高的话去医院查空腹血糖和糖化血红蛋白")
        } else {
            verdict = "\(shown) 在目标范围内\(when.isEmpty ? "" : "（\(when)一般希望在 \(upper.oneDecimal) 以下）")。"
        }
        var parts: [String?] = [verdict]
        if post && v >= p.glucoseLow { parts.append("按饭后 2 小时算；饭后 1 小时测的，高一些也常见。") }
        // The same meal over the last two weeks.
        if let m = AgentQuestion.meal(a.text) {
            let pts = c.vitals.filter { $0.kind == .glucose && $0.time > c.now.adding(days: -14) && m.hours.contains($0.time.hour) }.map(\.value)
            if pts.count >= 10, let avg = Stats.mean(pts) {
                let above = Double(pts.filter { $0 > 10 }.count) / Double(pts.count)
                parts.append("近 14 天\(m.name)后你的血糖平均 \(avg.oneDecimal)，\(Int((above * 100).rounded()))% 的时间高于 10。")
            }
        } else if let mean = c.glucose.mean, c.glucose.readings > 0, v >= p.glucoseLow, v < 16.7 {
            parts.append("你近 14 天平均 \(mean.oneDecimal)，目标范围内 \(Int(((c.glucose.tir ?? 0) * 100).rounded()))%。")
        }
        if a.has(["运动", "跑", "练", "锻炼", "散步", "健身"]) {
            parts.append(v < p.glucosePreExerciseMin ? "运动前低于 \(p.glucosePreExerciseMin.oneDecimal)，先吃 15–20 g 碳水再开始。"
                         : v > p.glucoseExerciseMax ? "高于 \(p.glucoseExerciseMax.oneDecimal) 先别做剧烈运动\(t1 ? "，先测酮体" : "")，散步可以。"
                         : "可以运动，随身带点糖。")
        }
        if c.lows.count >= 2, v >= p.glucoseLow, p.hypoRiskMeds(at: c.now) {
            parts.append("另外，近 14 天有 \(c.lows.count) 次低血糖，复诊时一起告诉医生。")
        }
        parts.append(bullets(steps))
        return AgentReply(text: lines(parts), sources: ["你说的读数", c.glucose.isContinuous ? "CGM 近 14 天" : "血糖记录"],
                          followUps: ["血糖老是高怎么办？"], destination: .glucose, intent: .reading, conclusion: verdict,
                          safety: v < 3.0 ? "意识不清、吞咽困难时不要喂东西，立即拨打 120。" : (v >= 16.7 ? steps.last.map { $0 + "。" } : nil))
    }

    /// 「昨晚只睡了5个小时，今天怎么安排」: a recovery day, by what is left of it.
    static func shortNight(hours h: Double, _ a: AgentQuestion, context c: AgentContext) -> AgentReply {
        let p = c.profile
        let need = p.sleepNeedMinutes / 60
        let evening = c.nearBedtime || c.now.hour >= 18
        let first = "只睡了 \(h.oneDecimal) 小时，比你需要的少约 \((need - h).oneDecimal) 小时，今天以恢复为主。"
        let training = c.todayPlan.filter { $0.kind.isTraining && $0.status == .planned }
        let hard = training.first { $0.intensity == .hard || $0.kind == .long || $0.kind == .quality || $0.kind == .strength }
        var parts: [String?] = [first]
        if c.profile.shift != nil, c.window.kind == .night || c.window.afterNightShift {
            parts.append("你在倒班，按倒班的安排补觉：下班后尽快睡，卧室全遮光；休息日别一次补太久，起床时间别比上班日晚太多。")
        } else if c.pastBedtime {
            parts.append("现在 \(c.clock)，已经过了你平时 \(Clock.text(c.window.bed.minutesOfDay)) 的入睡时间，先去睡吧，明天起床时间尽量不变。")
        } else if evening {
            parts.append("现在 \(c.clock)，今天剩下的时间不再安排训练，今晚比平时早 30 分钟左右上床。")
        } else if let s = hard {
            parts.append("今天的「\(s.title)」建议换成 20–30 分钟轻松活动，或者挪到后面睡够的一天，不需要补练。")
        } else if let s = training.first {
            parts.append("今天的「\(s.title)」可以照做，强度放轻、时间缩短三分之一左右。")
        } else {
            parts.append("今天没有训练安排，散散步就好。")
        }
        var tips: [String] = []
        let shiftNow = p.shift != nil && (c.window.kind == .night || c.window.afterNightShift)
        if !evening, !shiftNow, c.now.hour < p.caffeineCutoffHour { tips.append("咖啡放在 \(p.caffeineCutoffHour):00 前，别靠加量硬撑") }
        if !evening, !shiftNow, c.now.hour < 15 { tips.append("困的话午饭后小睡 20 分钟") }
        if !c.pastBedtime, !shiftNow { tips.append("今晚早点上床，但起床时间不变，这样明天晚上更容易睡着") }
        if !evening || shiftNow { tips.append("开车或做需要专注的事要格外小心") }
        parts.append(bullets(tips))
        parts.append("一晚睡少，静息心率和 HRV 通常 1–2 天就能恢复；连着几晚睡不够，影响才会累积。")
        var blocks: [AgentUIBlock] = []
        if !evening, let s = hard {
            let op = PlanEditOp.replace(day: c.logicalToday.weekday, kind: .mobility, title: "轻松活动或拉伸", minutes: 25, intensity: .easy,
                                        detail: "睡眠不足的一天以恢复为主，计划中的训练不需要补回。", target: s.kind)
            let proposal = PlanChat.propose([op], scope: .thisWeek, request: "昨晚只睡了 \(h.oneDecimal) 小时，今天不做\(s.title)", context: c, source: "Pulse 规则")
            if proposal.hasChanges { blocks.append(.plan(proposal)) }
        }
        return AgentReply(text: lines(parts), sources: ["你说的睡眠时长", "今天计划"], followUps: ["今晚该注意什么？", "熬夜后怎么恢复？"],
                          destination: .sleep, intent: .sleep, blocks: blocks, conclusion: first)
    }

    /// 「最近体重涨了两斤」: normal day-to-day change, or retained fluid for someone who watches it.
    static func weightChange(kg: Double, _ a: AgentQuestion, context c: AgentContext) -> AgentReply {
        let p = c.profile
        // In the user's own unit.
        let said = a.text.contains("斤") && !a.text.contains("公斤") ? "\(Int((kg * 2).rounded())) 斤"
            : (kg.truncatingRemainder(dividingBy: 1) == 0 ? "\(Int(kg)) 公斤" : "\(kg.oneDecimal) 公斤")
        let weights = c.vitals.filter { $0.kind == .weight && $0.time > c.now.adding(days: -8) }.sorted { $0.time < $1.time }
        var record: String? = nil
        if let f = weights.first, let l = weights.last, f.time < l.time {
            record = "你的记录里，\(f.time.formatted(.dateTime.month().day())) \(f.value.oneDecimal) kg，\(l.time.formatted(.dateTime.month().day())) \(l.value.oneDecimal) kg。"
        }
        if p.watchesWeight {
            let why = ([HealthCondition.ckd, .heartFailure].filter { p.conditions.contains($0) }.map(\.label) + (p.fluidLimited ? ["限水"] : [])).joined(separator: "、")
            let first = kg >= 2 ? "涨了 \(said)，对有\(why)的你需要留意，可能是身体存了水。"
                : "涨了 \(said)，先别慌，但要多看两天：对有\(why)的人，体重涨得快常常是身体存了水。"
            var steps = ["明早起床排尿后、吃早饭前再称一次，穿差不多的衣服",
                         "按一按脚踝或小腿前面，松开后留下小坑就是水肿；也留意尿量有没有变少、有没有气短",
                         "3 天内涨了 2 公斤以上，或者有气短、脚肿，联系医生；利尿剂不要自己加减"]
            if p.fluidLimited { steps.insert("对照一下这两天喝的水有没有超过 \(p.waterTargetMl) ml", at: 1) }
            let salty = KidneyDiet.week(c.days, profile: p, now: c.now).map { $0.saltyDays } ?? 0
            return AgentReply(text: lines([first, record, salty > 0 ? "这周记录里偏咸 \(salty) 天，盐多也会让身体存水。" : nil, bullets(steps)]),
                              sources: ["体重记录", "健康状况"], followUps: ["最近脚有点肿怎么办？"], destination: .vitals, intent: .reading,
                              conclusion: first)
        }
        let first = kg <= 1 ? "一两斤的波动很正常，不用担心。" : "涨了 \(said)，先看是不是一时的波动。"
        return AgentReply(text: lines([
            first,
            "体重一天里就能差 1 公斤左右：喝水多少、吃得咸不咸、排便和出汗都会影响。",
            record,
            bullets(["固定在早上起床排尿后、早饭前称", "看一周的平均值，而不是某一天", "连续 2–3 周平均值都在涨，再看看饮食和活动量"]),
        ]), sources: ["体重记录"], followUps: ["我想减肥，该怎么吃？"], destination: .vitals, intent: .reading, conclusion: first)
    }

    // MARK: Kinds of questions

    /// 「准备度是怎么算的」: the parts and their weights, then today's.
    static func readinessExplained(_ c: AgentContext) -> AgentReply {
        let first = "准备度把五项和你自己近 4 周的水平比，再加权算出 0–100 分。"
        var parts: [String?] = [first, bullets([
            "昨夜睡眠 25%：睡了多久、睡得好不好",
            "静息心率 25%：比你的基线高还是低",
            "心率变异性（HRV）20%：比平时高说明恢复得好",
            "醒后感受 20%：你早上记的精神、酸痛和压力",
            "近期训练负荷 10%：最近几天练得多不多",
        ])]
        parts.append("75 分以上可以按计划练；60–74 照常练，强度课减量；40–59 以轻松活动为主；40 以下建议休息。缺了某一项，就用其余几项算，可信度会标「依据有限」。生病或酸痛严重时，分数会被压低。")
        if let s = c.readiness.score, !c.beforeWake {
            let f = c.readiness.factors.filter(\.available).map { "\($0.name) \($0.value)\($0.impact == .negative ? "（拉低了分数）" : "")" }
            parts.append("今天 \(s) 分：\(f.joined(separator: "，"))。")
        }
        return AgentReply(text: lines(parts), sources: ["准备度的计算方法"], followUps: ["今天适合运动吗？"], destination: .recovery,
                          intent: .readiness, conclusion: first, verbatim: true)
    }

    /// 「我该多久去复查一次」: usual intervals for what the person has, from their own results.
    static func recheck(_ c: AgentContext) -> AgentReply {
        let p = c.profile
        let df = Date.FormatStyle().month().day()
        // The same schedule as 化验结果 › 复查安排.
        var items = LabRecheck.items(c.labs, profile: p, now: c.now).map { i in
            var line = "\(i.name)（\(i.tests)）：\(i.interval)"
            if let last = i.last, let due = i.due {
                line += "；上次 \(last.formatted(df))，下次大约 \(due.formatted(df))\(due < c.now.startOfDay ? "，已经到期了" : "")"
            } else {
                line += "；还没有记录结果，记下最近一次的化验单，Pulse 帮你算下次的时间"
            }
            return line
        }
        if p.hasDiabetes { items.append("眼底和足部：每年查一次") }
        if p.conditions.contains(.hypertension) || c.bp.count > 0 {
            items.append("血压：在家早晚测，每次复诊前把最近 7 天的记录带上")
        }
        if items.isEmpty { items.append("没有慢性病的话，每年做一次常规体检就够") }
        let first = "按你现在的情况，一般这样安排，具体以医生给你定的为准："
        return AgentReply(text: lines([first, bullets(items), "复诊时可以在「我的 › 隐私与数据导出」生成就诊摘要带上。"]),
                          sources: ["化验结果", "健康状况"], followUps: ["我的肾功能怎么样？"], destination: c.labs.isEmpty ? nil : .labs,
                          intent: .doctor, conclusion: first, verbatim: true)
    }

    /// 「肾病为什么要少吃盐」: the reason first, for this person's conditions, then how much.
    static func saltWhy(_ c: AgentContext) -> AgentReply {
        let p = c.profile
        let kidney = p.conditions.contains(.ckd) || p.onDialysis
        let first = kidney
            ? "盐吃多了，身体会存水，血压升高，肾脏要更费力地工作，尿里漏的蛋白也会变多，肾功能下降得更快。"
            : "盐吃多了，身体会存水，血压容易升高，心脏和血管的负担也会加重。"
        var parts: [String?] = []
        if kidney, p.conditions.contains(.hypertension) { parts.append("你同时有高血压，盐也是血压降不下来的常见原因，少吃盐能让降压药效果更好。") }
        else if p.conditions.contains(.hypertension) { parts.append("你有高血压，盐也是血压降不下来的常见原因，少吃盐能让降压药效果更好。") }
        if p.onDialysis { parts.append("做透析时，吃得咸会口渴、喝水多，两次透析之间体重就涨得多。") }
        parts.append("一般建议每天不超过 \(p.saltLimitG.noDecimal) g 盐，具体以医生给你定的为准。")
        if let w = KidneyDiet.week(c.days, profile: p, now: c.now), w.saltyDays > 0 {
            parts.append("你近 7 天记录了 \(w.days) 天，偏咸 \(w.saltyDays) 天。")
        }
        return AgentReply(text: lines(parts.isEmpty ? [first] : [first] + parts), sources: ["健康状况", "饮食记录"],
                          followUps: ["少吃盐有什么技巧？", "我这周吃得咸吗？"], intent: .diet, conclusion: first, verbatim: true)
    }

    /// 「少吃盐有什么技巧」: practical steps, starting from where this person's salt comes from.
    static func saltTips(_ c: AgentContext) -> AgentReply {
        let p = c.profile
        let first = "控盐最有效的是先管住看不见的盐：酱油、蚝油、咸菜、加工肉和外卖。"
        var data: String? = nil
        let recent = c.days.filter { $0.day > c.now.adding(days: -14) && $0.nutrientsLogged }
        let sources = Dictionary(grouping: recent.flatMap(\.saltSources), by: { $0 }).sorted { $0.value.count > $1.value.count }.prefix(3).map(\.key)
        if let w = KidneyDiet.week(c.days, profile: p, now: c.now) {
            data = "你近 7 天记录了 \(w.days) 天，偏咸 \(w.saltyDays) 天\(sources.isEmpty ? "" : "，最常见的是\(sources.joined(separator: "、"))")。"
        }
        var tips = ["用限盐勺，\(p.saltLimitG.noDecimal) g 盐大约是一个啤酒瓶盖平铺的量",
                    "出锅前再放盐，用醋、柠檬、葱姜蒜、花椒提味",
                    "酱油、蚝油、豆瓣酱都算盐，10 ml 酱油约有 1.5 g 盐",
                    "外卖备注少盐少油，汤汁不拌饭"]
        if p.limitsPotassium || p.conditions.contains(.ckd) { tips.append("别用低钠盐：它是用钾代替钠，你在限钾，换之前先问医生") }
        return AgentReply(text: lines([first, data, bullets(tips), "口味一般两三周就能适应变淡。"]),
                          sources: ["饮食记录"], followUps: ["我可以吃火锅吗？"], destination: nil, intent: .diet, conclusion: first)
    }

    /// 「降压药是早上吃还是晚上吃」: what matters (same time, not missed), the records, who decides.
    static func medTiming(_ a: AgentQuestion, context c: AgentContext) -> AgentReply {
        let m = c.medications
        let bpCats: [MedicationCategory] = [.betaBlocker, .rateLimitingCCB, .otherAntihypertensive]
        let named = m.filter { a.text.contains($0.name) }
        let kind = a.text.contains("降压") ? m.filter { bpCats.contains($0.category) }
            : a.has(["降糖", "胰岛素", "糖尿病"]) ? m.filter { [.insulin, .sulfonylurea, .otherGlucose].contains($0.category) } : []
        let which = (!named.isEmpty ? named : !kind.isEmpty ? kind : m).map(\.name)
        let first = "\(which.isEmpty ? "药" : which.joined(separator: "、"))什么时候吃，以医生或说明书交代的为准；没有特别交代的话，最要紧的是每天固定时间吃、不漏吃。"
        var parts: [String?] = [first]
        if a.has(["漏吃", "忘了吃", "漏服", "忘吃"]) {
            parts.append("漏吃了不要下一次吃双倍。想起来离下次吃药还早，一般可以补上；已经快到下次了，就跳过这次——各种药不一样，拿不准就问药师。")
        } else {
            parts.append("想换到别的时间吃，先问医生或药师再换。")
        }
        // Readings on days the medicine was not taken, against the other days.
        let missed = Set(c.days.filter { $0.day > c.now.adding(days: -30) && $0.medsTaken == false }.map(\.day))
        let bp = c.vitals.filter { $0.kind == .bloodPressure && $0.time > c.now.adding(days: -30) }
        let onMissed = bp.filter { missed.contains($0.time.startOfDay) }.map(\.value), others = bp.filter { !missed.contains($0.time.startOfDay) }.map(\.value)
        if onMissed.count >= 2, let x = Stats.mean(onMissed), let y = Stats.mean(others), x - y >= 3 {
            parts.append("你近 30 天有 \(missed.count) 天没按时吃药，那几天的收缩压平均 \(Int(x))，其他日子 \(Int(y))。")
        }
        parts.append(bullets(["设一个固定时间的提醒，和刷牙、吃早饭这类每天都做的事绑在一起", "每天在 Pulse 里勾一下「已按时服药」，复诊时医生能看到"]))
        return AgentReply(text: lines(parts), sources: ["用药记录", "血压"], followUps: ["我的血压控制得怎么样？"], intent: .meds, conclusion: first)
    }

    /// 「早上空腹跑步好吗」
    static func fastedExercise(_ c: AgentContext) -> AgentReply {
        let p = c.profile
        if p.hasDiabetes {
            let risky = p.medications.filter { $0.category.hypoglycemiaRisk && $0.isActive(on: c.now) }.map(\.name)
            let first = risky.isEmpty ? "可以，但运动前先测一下血糖，低于 \(p.glucosePreExerciseMin.oneDecimal) 就先吃点东西。"
                : "你在用\(risky.joined(separator: "、"))，空腹运动容易低血糖，最好先吃点东西再练。"
            return AgentReply(text: lines([first, bullets(["运动前测血糖，低于 \(p.glucosePreExerciseMin.oneDecimal) 先吃 15–20 g 碳水", "随身带糖或饮料", "运动后 1–2 小时再看一次血糖"]),
                                           c.lows.isEmpty ? nil : "你近 14 天有 \(c.lows.count) 次低血糖，更要注意。"]),
                              sources: ["用药", "血糖"], followUps: ["运动前血糖要注意什么？"], destination: .glucose, intent: .exercise, conclusion: first)
        }
        let first = "轻松跑空腹没问题，一小时以内都可以；强度课和长距离前最好吃点东西。"
        return AgentReply(text: lines([first, bullets([
            "醒来先喝几口水\(p.fluidLimited ? "（算进当天的饮水量）" : "")",
            "强度课或超过 60 分钟的跑，提前 30–60 分钟吃一根香蕉或一片面包",
            "跑完 1 小时内吃早饭，有碳水也有蛋白质",
        ]), "空腹跑不会让减脂效果明显更好，关键还是一周的总活动量。觉得头晕、手抖就停下来吃点东西。"]),
                          sources: ["运动常识"], followUps: ["跑步前吃香蕉好吗？"], destination: .plan, intent: .exercise, conclusion: first)
    }

    /// 「我适合跑马拉松吗」 without a race set: from the running of the last 8 weeks.
    static func marathonFit(_ a: AgentQuestion, context c: AgentContext) -> AgentReply {
        let p = c.profile
        let runs = c.workouts.filter { $0.type == .run && $0.start > c.now.adding(days: -56) }
        let km = runs.compactMap(\.distanceKm)
        let weekly = km.reduce(0, +) / 8
        let longest = km.max() ?? 0
        let full = !a.has(["半马"])
        var first: String
        if runs.isEmpty {
            first = "要看你现在的跑步基础：记录里近 8 周还没有跑步。先从每周 3 次、每次 20–30 分钟的轻松跑开始，能连续跑 1 小时以后再考虑比赛。"
        } else if weekly < 15 || longest < 8 {
            first = "现在先准备 10 公里或半马更合适：近 8 周你平均每周跑 \(Int(weekly)) km，最长一次 \(longest.oneDecimal) km。"
        } else if weekly < 30 || longest < 16 {
            first = full ? "全马还需要再积累 3–4 个月；半马现在就可以开始准备（8–12 周）：近 8 周你平均每周 \(Int(weekly)) km，最长一次 \(longest.oneDecimal) km。"
                : "半马可以，准备 8–12 周就够：近 8 周你平均每周 \(Int(weekly)) km，最长一次 \(longest.oneDecimal) km。"
        } else {
            first = "有基础：近 8 周你平均每周 \(Int(weekly)) km，最长一次 \(longest.oneDecimal) km，准备全马一般需要 16–20 周的专项训练。"
        }
        var parts: [String?] = [first]
        if p.cardiacLimited || p.intensityCapped {
            parts.append("你记录了\((p.intensityCaps + (p.cardiacLimited ? ["心血管相关情况"] : [])).joined(separator: "、"))，报名前先请医生评估能不能做长时间的耐力训练。")
        }
        parts.append(bullets(["每周加量不超过 10%，每 3–4 周减量一周", "在「专项运动」里填上比赛日期和目标，Pulse 会按周排出计划"]))
        return AgentReply(text: lines(parts), sources: ["跑步记录 近 8 周"], followUps: ["怎样安排运动更有效？"], destination: .marathon,
                          intent: .marathon, conclusion: first)
    }

    /// 「我想减肥，晚上饿了能吃点什么」 and other questions about eating less or being hungry.
    static func eating(_ a: AgentQuestion, context c: AgentContext) -> AgentReply {
        let p = c.profile
        let ckd = p.conditions.contains(.ckd)
        let hungry = a.text.contains("饿")
        var parts: [String?] = []
        let first: String
        if hungry {
            let snack = ckd ? "一个苹果或梨、几片苏打饼干，或者一小碗白粥"
                : "一杯无糖酸奶或牛奶、一个鸡蛋、一小把坚果，或者一根黄瓜、一个番茄"
            first = "饿了可以吃点顶饱、热量不高的：\(snack)。"
            parts.append(first)
            if a.has(["减肥", "减重", "减脂", "瘦"]) { parts.append("减肥时别硬扛着饿，硬扛容易后面吃得更多；关键是一天总共吃多少。") }
            parts.append(c.pastBedtime ? "已经过了你平时的入睡时间，吃一点垫一下就好，吃完稍坐一会儿再睡。" : "离睡觉最好还有 2 小时以上，吃完别马上躺下。")
            if ckd { parts.append("你在限\([p.limitsPotassium ? "钾" : nil, p.limitsPhosphorus ? "磷" : nil].compactMap { $0 }.joined(separator: "和").ifEmpty("盐"))，坚果、牛奶、香蕉这类含钾磷多的先不选。") }
            if p.hasDiabetes && p.hypoRiskMeds(at: c.now) { parts.append("你用的药有低血糖风险：突然很饿，或者伴有心慌、出汗、手抖，先测一下血糖。") }
        } else {
            first = "减重靠一天吃进去的比消耗的少一点：每天少吃 300–500 千卡，一周大约减 0.5 公斤，比节食更容易坚持。"
            parts.append(first)
            parts.append(bullets(["每餐先吃菜，主食减三分之一，换一部分粗粮", "饮料和零食换成水和水果",
                                  "每周活动 150 分钟以上，加 2 次力量训练保住肌肉", "每周固定一天早上称体重，看几周的趋势"]))
            parts.append("你本周已活动 \(Int(c.weekActiveMinutes)) 分钟，每周目标 \(p.weeklyTargetMinutes) 分钟。")
            if ckd { parts.append("你有慢性肾病，减重前先问医生，蛋白质不能随便加，也别吃代餐和减肥药。") }
            if p.hasDiabetes { parts.append("你有糖尿病，少吃的同时留意低血糖，用药要不要调整问医生。") }
        }
        return AgentReply(text: lines(parts), sources: ["饮食常识", "健康状况"], followUps: ["今天吃什么好？"], intent: .diet, conclusion: first)
    }

    /// Common exercise know-how (拉伸、热身、跑鞋、跑步呼吸), which a small on-device model gets wrong.
    /// Shown as written; with 端云结合 these plain knowledge questions go to the cloud model instead.
    static func knowledge(_ a: AgentQuestion, context c: AgentContext) -> AgentReply? {
        let p = c.profile
        let how = ["怎么", "如何", "多久", "多长", "方法", "动作", "要不要", "什么时候", "技巧", "注意"]
        var first: String, tips: [String], extra: String? = nil
        if a.has(["拉伸", "拉多久"]), a.has(how) || a.text.contains("拉多久") {
            first = "拉伸放在运动后、身体热了的时候效果最好：每个部位慢慢拉到有牵拉感但不疼，停 20–30 秒，做 2–3 次，别弹震。"
            tips = ["跑步的人重点拉小腿、大腿前后侧、臀部和髋部", "运动前不做长时间静态拉伸，换成 5–10 分钟动态热身（高抬腿、弓步走、摆腿）",
                    "拉的时候保持呼吸，疼了就退一点"]
            if p.conditions.contains(.jointPain) { extra = "你记录了关节或肌肉损伤：受伤的部位先问医生或康复师再拉。" }
        } else if a.has(["热身"]), a.has(how) {
            first = "热身 5–10 分钟就够：先慢跑或快走几分钟让心率慢慢上来，再做几组动态动作（高抬腿、后踢腿、弓步走、摆腿），强度课前多热几分钟。"
            tips = ["天冷、早上刚起床，热身多做几分钟", "热身后身体微微出汗、关节灵活了，再开始正式训练", "练完再慢走 5 分钟放松，不要突然停下"]
            if p.hasCardiac { extra = "你有心血管方面的情况，热身和放松都要做足，别一上来就快跑。" }
        } else if a.has(["跑鞋"]) || (a.text.contains("鞋") && a.text.contains("跑")) {
            first = "跑鞋最重要的是合脚、穿着舒服，不用追最贵的：到店里试穿，下午脚稍微肿一点时试，脚趾前留一指宽，跑几步不磨脚、不挤。"
            tips = ["刚开始跑选缓震好一些的入门款就够，体重大的人缓震更重要", "一双鞋跑 600–800 公里左右就该换了，鞋底明显变形也该换",
                    "有扁平足、高足弓，或者膝盖、脚踝老是疼，先让运动医学科或专业跑鞋店看看脚型"]
            if p.hasDiabetes { extra = "你有糖尿病：鞋要宽松不磨脚，配吸汗的袜子，每天看看脚有没有破皮。" }
        } else if a.has(["CGM", "cgm", "动态血糖", "传感器", "探头"]), a.has(["贴在哪", "贴哪", "位置", "部位", "贴的地方"]) {
            first = "CGM 一般贴在上臂后侧，有的型号也可以贴腹部，以产品说明书为准：选肉稍厚、不常被压到、不在关节和腰带上的地方，每次换一个位置。"
            tips = ["贴之前用酒精棉擦干净、等皮肤干透；出汗多可以加一层固定贴", "睡觉别总压着那一侧，压住时读数可能一过性偏低",
                    "新探头头一天读数可能不太稳，和感觉不一致时用指尖血核对"]
        } else if a.has(["跑"]), a.has(["呼吸", "岔气", "跑姿"]), !a.has(["呼吸困难"]) {
            first = "跑步时呼吸自然就好，用口鼻一起呼吸；轻松跑以能完整说话为准，说不了整句就是太快了。"
            tips = ["节奏可以试试两步一吸、两步一呼", "岔气了就放慢、深呼吸，按住疼的地方，缓过来再慢慢加速", "饭后 1–2 小时再跑，能减少岔气"]
            if p.conditions.contains(.respiratory) { extra = "你有哮喘或慢阻肺：随身带上医生开的药，喘得厉害就停下来。" }
        } else {
            return nil
        }
        return AgentReply(text: lines([first, bullets(tips), extra]), sources: ["运动常识"], followUps: ["今天适合运动吗？"],
                          destination: .plan, intent: .knowledge, conclusion: first, verbatim: true)
    }

    /// 「我的数据会上传吗」: what leaves the phone in the answer mode in effect.
    static func privacyAnswer(_ c: AgentContext) -> AgentReply {
        let first: String
        switch c.answerMode {
        case .onDevice: first = "不会。你现在用的是「仅本机」：所有记录只存在这台手机上，问答也在本机完成，不会上传。"
        case .hybrid: first = "你的健康记录不会上传。你现在用的是「端云结合」：用到你记录的问题在本机回答，只有不涉及你记录的通用问题，会把问题原文（不带任何记录）发到你配置的云端模型。"
        case .cloud: first = "会发送一部分。你现在用的是「全部云端」：每次提问会把数据摘要（年龄、健康状况、用药名称、最近一次化验结果和各项统计，不含姓名和逐条记录）、本机分析和你的问题发到你配置的云端模型。"
        }
        return AgentReply(text: lines([first,
                                       "Pulse 的数据只存在这台设备上，不需要账号；只有你主动导出或分享时，数据才会离开设备。紧急情况的提示始终由本机给出。",
                                       "在「我的 › Health Agent › 回答方式与云端模型」可以随时切换。"]),
                          sources: ["回答方式设置"], followUps: ["你的建议依据是什么？"], intent: .about, conclusion: first, verbatim: true)
    }

    /// 「你叫什么名字」: the name, and how to change it.
    static func nameAnswer(_ c: AgentContext) -> AgentReply {
        let first = c.agentName == AgentName.standard ? "我叫 \(AgentName.standard)，是 Pulse 里的健康助手。" : "我叫\(c.agentName)。"
        let how = c.agentName == AgentName.standard ? "想给我取个名字，直接说「以后叫你小安」，或者在「我的 › Health Agent › 名字」里改。"
            : "这是你给我取的名字。想换一个，直接说「以后叫你…」；想改回 \(AgentName.standard)，说「改回原来的名字」。"
        return AgentReply(text: lines([first, how]), followUps: ["你的建议依据是什么？"], intent: .about, conclusion: first, verbatim: true)
    }

    /// 「你的建议依据是什么」: where answers come from and what they never do.
    static func aboutAnswer(_ c: AgentContext) -> AgentReply {
        let first = "我的建议来自你在 Pulse 里的记录：睡眠、静息心率、HRV、训练、饮食、血压、血糖、化验和用药。"
        let how: String
        switch c.answerMode {
        case .onDevice: how = "Pulse 先在本机用规则算出事实和结论（比如准备度、训练负荷、和你平时比高了多少），再由 Apple 智能组织成文字；涉及安全的结论由规则决定，模型不能改。"
        case .hybrid: how = "用到你记录的问题，Pulse 在本机用规则算出事实和结论，再由 Apple 智能组织成文字；通用问题由云端模型凭常识回答，它看不到你的记录。"
        case .cloud: how = "Pulse 先在本机用规则算出事实和结论，再把这些和数据摘要交给云端模型组织成文字；涉及安全的结论由规则决定，模型不能改。"
        }
        return AgentReply(text: lines([first, how, "我不做诊断，也不替你调整药物；「观察到的关联」只说明两件事常一起出现，不等于原因。拿不准的时候，以医生的判断为准。"]),
                          sources: ["Pulse 的分析方式"], followUps: ["我的数据会上传吗？"], intent: .about, conclusion: first, verbatim: true)
    }

    /// 「今天吃什么好」: a simple plate, adjusted for the day's training and the person's limits.
    static func mealIdeas(_ c: AgentContext) -> AgentReply {
        let p = c.profile
        let ckd = p.conditions.contains(.ckd)
        let first = "按「一半蔬菜、四分之一肉蛋豆、四分之一主食」来配，最简单也最不容易出错。"
        var parts: [String?] = [first]
        let evening = c.now.hour >= 16
        var menu: [String] = []
        if !evening { menu.append("早饭：燕麦或全麦面包，一个鸡蛋，\(ckd ? "一小杯牛奶（算进饮水）" : "一杯牛奶或豆浆")") }
        if c.now.hour < 13 { menu.append("午饭：杂粮饭一拳头，清炒青菜\(ckd ? "（焯水后再炒）" : "")，鱼或鸡肉一掌心") }
        menu.append("晚饭：主食一拳头（一半粗粮），两样蔬菜，豆腐或鸡蛋，睡前 2–3 小时吃完")
        parts.append(bullets(menu))
        var notes: [String] = []
        if let s = c.todayPlan.first(where: { $0.kind.isTraining && $0.status == .planned && ($0.intensity == .hard || $0.kind == .long) }) {
            notes.append("今天有「\(s.title)」，练前 1–2 小时吃点主食，练完吃一份有碳水也有蛋白质的饭。")
        }
        if p.hasDiabetes { notes.append("主食一餐一拳头，一半换粗粮，先吃菜和肉再吃主食。") }
        if ckd {
            notes.append("盐不超过 \(p.saltLimitG.noDecimal) g\(p.proteinTargetG.map { "，蛋白质按医生定的每天约 \($0) g（大约 \($0 / 7) 份肉蛋奶豆）" } ?? "")\(p.limitsPotassium ? "，高钾的菜焯水后再做" : "")。")
        } else if p.conditions.contains(.hypertension) {
            notes.append("少放盐，酱油、咸菜也算盐。")
        }
        parts.append(notes.isEmpty ? nil : notes.joined())
        return AgentReply(text: lines(parts), sources: ["饮食常识", "今天计划"], followUps: ["少吃盐有什么技巧？"], intent: .diet, conclusion: first)
    }
}

private extension String {
    func ifEmpty(_ s: String) -> String { isEmpty ? s : self }
}
