import Foundation

// MARK: - Symptoms

/// 「最近脚有点肿」「我最近老是头晕」: what to do first, the signs that need a doctor or 120, and
/// what the person's own records show that often goes with it — worded as things to check, never
/// as a diagnosis. Emergencies (胸痛, 晕倒, 一侧无力…) never get here; they have the fixed reply.
enum SymptomGuide {
    static func reply(_ s: AskedSymptom, _ a: AgentQuestion, context c: AgentContext) -> AgentReply {
        switch s {
        case .fatigue: fatigue(a, c)
        case .dizzy: dizzy(a, c)
        case .swelling: swelling(a, c)
        case .cold: cold(a, c)
        case .pain: pain(a, c)
        case .soreness: soreness(a, c)
        case .palpitations: palpitations(a, c)
        case .cramps: cramps(a, c)
        case .thirst: thirst(a, c)
        case .urine: urine(a, c)
        case .headache: headache(a, c)
        case .itch: itch(a, c)
        case .appetite: appetite(a, c)
        case .nocturia: nocturia(a, c)
        }
    }

    /// The sentence that says when to see a doctor or call 120 is kept whatever a model writes.
    private static let warning = #"(120|就医|看医生|去医院|联系医生|骨科|心内科)"#

    private static func answer(_ first: String, _ parts: [String?], sources: [String], followUps: [String] = [],
                               destination: AgentDestination? = nil, blocks: [AgentUIBlock] = []) -> AgentReply {
        let safety = parts.compactMap { $0 }.first { !$0.hasPrefix("•") && !$0.hasPrefix("从你的记录看") && $0.range(of: warning, options: .regularExpression) != nil }
        return AgentReply(text: HealthAgent.lines([first] + parts), sources: sources, followUps: followUps, destination: destination,
                          intent: .symptom, blocks: blocks, conclusion: first, safety: safety)
    }

    private static func found(_ items: [String]) -> String? {
        items.isEmpty ? nil : "从你的记录看，可能有关的（不一定是原因）：\n" + items.prefix(3).map { "• " + $0 }.joined(separator: "\n")
    }

    // MARK: Shared readings

    private static func lowHb(_ c: AgentContext) -> LabPoint? {
        c.lab(.hemoglobin, within: 180).flatMap { $0.value < (c.profile.sex == .female ? 120 : 130) ? $0 : nil }
    }
    private static func offPotassium(_ c: AgentContext) -> LabPoint? {
        c.lab(.potassium, within: 120).flatMap { $0.value > 5.0 || $0.value < 3.5 ? $0 : nil }
    }
    private static func bpMeds(_ c: AgentContext) -> [MedicationInfo] {
        c.medications.filter { [.betaBlocker, .rateLimitingCCB, .otherAntihypertensive].contains($0.category) }
    }
    private static func recentBP(_ c: AgentContext, days: Int = 14) -> [VitalPoint] {
        c.vitals.filter { $0.kind == .bloodPressure && $0.time > c.now.adding(days: -days) }
    }
    private static func lastNight(_ c: AgentContext) -> Double? { c.days.first { $0.day == c.logicalToday }?.sleepMinutes }

    // MARK: Each symptom

    static func fatigue(_ a: AgentQuestion, _ c: AgentContext) -> AgentReply {
        let p = c.profile
        var why: [String] = []
        if let s = lastNight(c), s < p.sleepNeedMinutes - 60 { why.append("昨晚睡了 \((s / 60).oneDecimal) 小时，比你需要的少") }
        else if let avg = c.sleep.avgMinutes, avg < p.sleepNeedMinutes - 30 { why.append("近两周平均每晚睡 \((avg / 60).oneDecimal) 小时，比你需要的 \((p.sleepNeedMinutes / 60).oneDecimal) 小时少") }
        if c.load.zone == .high || c.load.zone == .caution { why.append("最近训练量加得偏快（负荷比 \(c.load.ratio.map { String(format: "%.2f", $0) } ?? "—")）") }
        if let h = lowHb(c) { why.append("血红蛋白 \(h.valueText) g/L 偏低，贫血会让人容易累") }
        if (c.glucose.tar ?? 0) > 0.25 { why.append("血糖高于范围的时间比较多（\(Int(((c.glucose.tar ?? 0) * 100).rounded()))%），血糖高也会让人乏力") }
        if !c.lows.isEmpty { why.append("近 14 天有 \(c.lows.count) 次低血糖") }
        if c.recent7.filter(\.highStress).count >= 3 { why.append("这周压力大的天比较多") }
        if c.days.contains(where: { $0.day >= c.logicalToday.adding(days: -3) && $0.isIll }) { why.append("这几天记录了生病") }
        if c.medications.contains(where: { $0.category == .betaBlocker }) { why.append("β 受体阻滞剂有时会让人觉得没劲") }
        let afterDialysis = p.onHemodialysis && a.has(["透析"])
        let first = afterDialysis ? "透析后觉得累很常见，多数休息几个小时到第二天会缓解：透析当天以休息为主，不安排训练。"
            : "累的话今天先放轻松：训练降一级或换成散步，今晚早点睡。"
        var parts: [String?] = []
        if afterDialysis { parts.append("每次透析后都累得厉害、要很久才缓过来，告诉透析中心：可能和脱水量、血压或贫血有关，可以调整。") }
        if why.isEmpty, let s = c.readiness.score, c.readiness.level == .high, !c.beforeWake {
            parts.append("今天的准备度是 \(s)，数据上恢复得不错，但你的感受更重要，按感受来。")
        }
        parts.append(found(why))
        parts.append("累了两周以上还不见好，或者伴有体重下降、发烧、气短、心慌，去看医生查一下（比如血常规、甲状腺、血糖）。")
        return answer(first, parts, sources: ["睡眠", "训练负荷", c.labs.isEmpty ? nil : "化验结果"].compactMap { $0 },
                      followUps: ["今天适合运动吗？", "我的睡眠怎么样？"], destination: .recovery)
    }

    static func dizzy(_ a: AgentQuestion, _ c: AgentContext) -> AgentReply {
        let p = c.profile
        let first = "头晕时先坐下或躺下，\(p.hasDiabetes ? "测一下血压和血糖" : "量一下血压")，好了再慢慢起来。"
        var why: [String] = []
        let bp = recentBP(c)
        let lows = bp.filter { $0.value < 90 }
        if !lows.isEmpty { why.append("近 14 天有 \(lows.count) 次血压低于 90") }
        else if bp.contains(where: { $0.value >= 160 }) { why.append("近 14 天有 \(bp.filter { $0.value >= 160 }.count) 次血压在 160 以上") }
        let meds = bpMeds(c)
        if !meds.isEmpty { why.append("你在吃降压药（\(meds.map(\.name).joined(separator: "、"))），起身太快时可能头晕：从躺着、坐着起来时慢一点") }
        if p.hypoRiskMeds(at: c.now) {
            let names = c.medications.filter(\.category.hypoglycemiaRisk).map(\.name).joined(separator: "、")
            why.append("你用的\(names)可能引起低血糖\(c.lows.isEmpty ? "" : "，近 14 天有 \(c.lows.count) 次")")
        } else if !c.lows.isEmpty { why.append("近 14 天有 \(c.lows.count) 次低血糖") }
        if let h = lowHb(c) { why.append("血红蛋白 \(h.valueText) g/L 偏低") }
        if let s = lastNight(c), s < 360 { why.append("昨晚只睡了 \((s / 60).oneDecimal) 小时") }
        return answer(first, [
            "如果同时有一侧手脚无力、口角歪斜、说话不清、胸痛或晕倒，立即拨打 120。",
            found(why),
            HealthAgent.bullets(["记下头晕的时间、当时在做什么、血压\(p.hasDiabetes ? "和血糖" : "")是多少", meds.isEmpty && !p.hasDiabetes ? nil : "降压药、降糖药不要自己停或减，把头晕的情况告诉医生",
                                 "反复出现，带着这些记录去看医生"].compactMap { $0 }),
        ], sources: ["血压", "用药", p.hasDiabetes ? "血糖" : nil].compactMap { $0 }, followUps: ["我的血压控制得怎么样？"], destination: .vitals)
    }

    static func swelling(_ a: AgentQuestion, _ c: AgentContext) -> AgentReply {
        let p = c.profile
        let why = ([HealthCondition.ckd, .heartFailure].filter { p.conditions.contains($0) }.map(\.label) + (p.fluidLimited ? ["限水"] : [])).joined(separator: "、")
        let place = ["眼皮", "眼睑", "脸", "手", "腿", "脚踝", "脚"].first { a.text.contains($0) } ?? "脚"
        let face = ["眼皮", "眼睑", "脸"].contains(place)
        let first = p.watchesWeight ? "\(place)肿对有\(why)的你需要留意，可能是身体存了水：今天称一下体重、量一下血压。"
            : (face ? "早上\(place)有点肿，可能是睡前喝水多、吃得咸或没睡好；如果天天这样，或者同时尿里泡沫多，去查一下尿常规和肾功能。"
               : "\(place)肿多数和久坐久站、吃得咸有关，先抬高腿休息；但有几种情况要尽快就医。")
        var seen: [String] = []
        if let g = CardioAnalyzer.weightGain(c.vitals, now: c.now) { seen.append("体重 3 天内涨了 \(g.kg.oneDecimal) kg") }
        if let s = KidneySigns.summary(c.days, now: c.now), s.edemaDays > 0 { seen.append("你记录的" + s.text.replacingOccurrences(of: "近 14 天记了 \(s.days) 天：", with: "近 14 天里，")) }
        if let g = Dialysis.gain(c.vitals, profile: p, now: c.now) { seen.append("体重比\(g.against)多 \(g.kg.oneDecimal) kg") }
        let ccb = c.medications.filter { $0.name.contains("地平") }
        if !ccb.isEmpty { seen.append("你吃的\(ccb.map(\.name).joined(separator: "、"))常见的副作用之一就是脚踝肿；复诊时告诉医生，不要自己停药") }
        if let u = c.lab(.uacr, within: 365), u.value >= 30 { seen.append("尿白蛋白/肌酐比 \(u.valueText) 偏高，尿里漏蛋白多时也容易肿") }
        if let w = KidneyDiet.week(c.days, profile: p, now: c.now), w.saltyDays > 0 { seen.append("这周记录里偏咸 \(w.saltyDays) 天，盐多会让身体存水") }
        if let avg = c.bp.avgSys, avg >= 140 { seen.append("近 30 天血压平均 \(Int(avg))/\(Int(c.bp.avgDia ?? 0))") }
        var tips = face ? ["晚饭和睡前少喝水、少吃咸的", "看看小腿、脚踝是不是也有按下去的坑", "少吃盐"]
            : ["按一按脚踝或小腿前面，松开后留下小坑就是水肿", "坐着时把腿抬高，少久站久坐", "少吃盐"]
        if p.watchesWeight { tips.insert("每天早上起床排尿后称体重，记在 Pulse 里", at: 1) }
        return answer(first, [
            found(seen),
            HealthAgent.bullets(tips),
            "有气短、躺下喘不过气、3 天体重涨 2 公斤以上，或者只有一条腿肿、发红发热又疼，尽快就医。",
        ], sources: ["体重", "用药", c.labs.isEmpty ? nil : "化验结果"].compactMap { $0 }, followUps: ["我需要去看医生吗？"], destination: .vitals)
    }

    static func cold(_ a: AgentQuestion, _ c: AgentContext) -> AgentReply {
        let p = c.profile
        let first = "看症状：只有鼻塞、流鼻涕、嗓子疼这类脖子以上的症状，可以做轻松活动；有发烧、全身酸痛、咳嗽有痰或胸闷，就先停练休息。"
        var parts: [String?] = ["退烧后至少 1–2 天、症状明显好转再恢复训练，第一次练平时的一半。"]
        if p.hasCardiac { parts.append("你有心血管方面的情况，感冒发烧时更要休息；有心慌、胸闷要及时就医。") }
        if p.hasDiabetes { parts.append("生病时血糖容易波动，多测几次；吃不下东西时，降糖药怎么用问医生。") }
        if p.conditions.contains(.hypertension) || p.hasCardiac { parts.append("很多感冒药含伪麻黄碱，会让血压和心率升高，买药时告诉药师你的情况。") }
        parts.append("在「今日」里记一下生病，准备度和计划会把它算进去。")
        // The rest of the week's demanding sessions, made easier on request.
        var blocks: [AgentUIBlock] = []
        let ahead = c.plan.filter { $0.day >= c.logicalToday && $0.day < c.weekStart.adding(days: 7) && $0.status == .planned
            && ($0.intensity == .hard || $0.kind == .long || $0.kind == .quality) }
        if !ahead.isEmpty {
            let r = PlanChat.reply("这周轻松一点", context: c)
            blocks = r.blocks.filter { $0.proposal != nil }
            if !blocks.isEmpty { parts.append("这周后面还有\(ahead.map { "\(Weekday.name($0.day.weekday))的\($0.title)" }.joined(separator: "、"))，下面是先换成轻松训练的建议，点「采纳」才会生效。") }
        }
        return answer(first, parts, sources: ["本周计划", "健康状况"], followUps: ["今天适合运动吗？"], destination: blocks.isEmpty ? .plan : nil, blocks: blocks)
    }

    static func pain(_ a: AgentQuestion, _ c: AgentContext) -> AgentReply {
        let q = a.text
        let part = ["膝盖", "膝", "脚踝", "踝", "跟腱", "足底", "小腿", "大腿", "髋", "腰", "背", "肩", "手腕", "肘", "腿", "脚"].first { q.contains($0) } ?? "这里"
        let running = q.contains("跑")
        let rest = "\(part)疼先别\(running ? "跑" : "练")了，换成不压到这个部位的运动，疼痛消了再慢慢恢复。"
        // 「膝盖疼能吃布洛芬吗」 is answered first.
        let painkiller = KidneyMeds.asksAbout(q) ? KidneyMeds.answer(c.profile, labs: c.labs) : nil
        let first = painkiller ?? rest
        var parts: [String?] = painkiller == nil ? [] : [rest]
        if running, ["膝", "踝", "跟腱", "足底", "小腿", "髋"].contains(where: { part.contains($0) }) {
            parts.append("跑步时\(part)疼，常见原因是跑量加得太快、鞋或路面不合适。")
        }
        if c.load.zone == .high || c.load.zone == .caution { parts.append("你最近训练量加得偏快（负荷比 \(c.load.ratio.map { String(format: "%.2f", $0) } ?? "—")），这也是常见原因。") }
        parts.append(HealthAgent.bullets(["这几天换成骑车、游泳这类不压\(part)的运动；走路不疼的话，日常走动没问题",
                                          "刚扭伤或明显肿痛，冰敷 15 分钟，一天几次",
                                          "不疼了先从平时一半的量开始，每周加不超过 10%"]))
        parts.append("肿得厉害、关节卡住或打软腿、不能负重，或者 1–2 周还没好转，去看骨科或运动医学科。")
        if painkiller == nil, KidneyMeds.atRisk(c.profile, labs: c.labs) { parts.append("想吃止痛药的话，布洛芬这类药可能伤肾，先问医生或药师用哪种。") }
        var blocks: [AgentUIBlock] = []
        if PlanChat.isRequest(q) {
            blocks = PlanChat.reply(q, context: c).blocks.filter { $0.proposal != nil }
            if !blocks.isEmpty { parts.append("下面是本周计划的调整建议，点「采纳」后才会生效。") }
        }
        return answer(first, parts, sources: ["训练负荷", "本周计划"], followUps: ["这周的训练完成得怎么样？"], destination: blocks.isEmpty ? .plan : nil, blocks: blocks)
    }

    static func soreness(_ a: AgentQuestion, _ c: AgentContext) -> AgentReply {
        let first = (a.form == .isItOK ? "正常。" : "") + "练完 1–2 天肌肉酸（延迟性肌肉酸痛）很常见，一般 3–5 天自己会好。"
        let recent = c.workouts.filter { $0.start > c.now.adding(days: -3) && $0.minutes >= 30 }.max { $0.minutes < $1.minutes }
        var parts: [String?] = []
        if let w = recent {
            parts.append("你\(w.start.formatted(.dateTime.month().day()))\(w.type.label)了 \(Int(w.minutes)) 分钟\(w.distanceKm.map { "（\($0.oneDecimal) km）" } ?? "")，酸是身体在适应。")
        }
        parts.append(HealthAgent.bullets(["今天做散步、轻松骑车或拉伸，动一动反而好得快", "睡够，练完吃点蛋白质", "还酸的部位先不做强度课和大重量"]))
        parts.append("酸痛特别厉害、腿明显肿，或者尿色像浓茶，尽快就医。")
        return answer(first, parts, sources: ["训练记录"], followUps: ["今天适合运动吗？"], destination: .plan)
    }

    static func palpitations(_ a: AgentQuestion, _ c: AgentContext) -> AgentReply {
        let p = c.profile
        let first = "心慌时先坐下休息，慢慢呼吸，\(p.hasDiabetes ? "测一下心率和血糖" : "看一下心率")。"
        var why: [String] = []
        let late = c.recent7.filter { $0.lateCaffeine(cutoff: p.caffeineCutoffHour) }.count
        if late > 0 { why.append("这周有 \(late) 天下午还喝了咖啡或浓茶") }
        if c.recent7.contains(where: \.hadAlcohol) { why.append("这周喝过酒") }
        if let s = lastNight(c), s < 360 { why.append("昨晚只睡了 \((s / 60).oneDecimal) 小时") }
        if c.recent7.filter(\.highStress).count >= 2 { why.append("最近压力大") }
        if let k = offPotassium(c) { why.append("血钾 \(k.valueText) 偏\(k.value > 5 ? "高" : "低")，会影响心跳") }
        if !c.lows.isEmpty { why.append("近 14 天有 \(c.lows.count) 次低血糖，低血糖时也会心慌") }
        let raising = c.medications.filter { $0.category.hrEffect == .raises }
        if !raising.isEmpty { why.append("\(raising.map(\.name).joined(separator: "、"))可能让心率加快") }
        return answer(first, [
            "同时有胸痛、胸闷、气短、头晕快要晕倒，或者心跳一直很快停不下来，立即拨打 120。",
            found(why),
            HealthAgent.bullets(["记下发生的时间、持续多久、当时在做什么", "手表有心电图功能的话，心慌时录一段给医生看", "经常发生就去心内科，可能需要做心电图或动态心电图"]),
        ], sources: ["咖啡因与饮酒", "睡眠", c.labs.isEmpty ? nil : "化验结果"].compactMap { $0 }, followUps: ["咖啡因对我有影响吗？"], destination: .heart)
    }

    static func cramps(_ a: AgentQuestion, _ c: AgentContext) -> AgentReply {
        let p = c.profile
        let first = "抽筋时先慢慢拉伸那块肌肉，小腿抽筋就把脚尖往身体方向勾，一般几分钟就会缓解。"
        var why: [String] = []
        if let k = offPotassium(c) { why.append("血钾 \(k.valueText) 偏\(k.value > 5 ? "高" : "低")") }
        if p.conditions.contains(.ckd) { why.append("肾病患者电解质容易失衡") }
        if c.load.zone == .high { why.append("最近训练量加得快") }
        return answer(first, [
            found(why),
            HealthAgent.bullets(["睡前拉伸小腿 5 分钟", p.fluidLimited ? "你在限水，别为了抽筋自己多喝水" : "运动出汗多时及时补水",
                                 "经常夜里抽筋，告诉医生，可能要查一下电解质"]),
        ], sources: ["化验结果", "训练负荷"], followUps: ["我的肾功能怎么样？"])
    }

    static func thirst(_ a: AgentQuestion, _ c: AgentContext) -> AgentReply {
        let p = c.profile
        if p.fluidLimited {
            let first = "你在限水：口渴时小口慢喝，可以含块冰或嚼无糖口香糖，别一次喝很多。"
            return answer(first, ["吃得咸会更渴，少盐是最有效的办法。\(p.hasDiabetes ? "血糖高也会口渴，先测一下血糖。" : "")",
                                  "每天喝的水不超过医生定的 \(p.waterTargetMl) ml，汤和水果里的水也算。"],
                          sources: ["饮水限制"], followUps: ["少吃盐有什么技巧？"])
        }
        if p.hasDiabetes {
            let first = "口渴、尿多常常是血糖偏高的表现，先测一下血糖。"
            return answer(first, [
                c.glucose.mean.map { "你近 14 天血糖平均 \($0.oneDecimal)，高于范围的时间 \(Int(((c.glucose.tar ?? 0) * 100).rounded()))%。" },
                "持续高于 13.9，或者伴有乏力、恶心、呕吐，今天就联系医生。",
            ], sources: ["血糖"], followUps: ["血糖老是高怎么办？"], destination: .glucose)
        }
        let first = "天热、运动出汗、吃得咸都会口渴，多喝点水就好。"
        return answer(first, ["如果一直口渴、尿多，人还越来越瘦，去医院查一下血糖。"], sources: ["常识"])
    }

    static func urine(_ a: AgentQuestion, _ c: AgentContext) -> AgentReply {
        let p = c.profile
        if a.text.contains("血") {
            return answer("尿里有血要尽快去医院查一下。", ["剧烈运动后偶尔会有，但不能自己判断，先查尿常规。"], sources: ["常识"])
        }
        if a.has(["尿少", "尿量"]) {
            if p.onPeritoneal {
                return answer("腹透的人保住剩下的尿量很重要，尿明显变少要告诉腹透中心。", ["每天称体重；体重涨得快、脚肿或气短，及时联系腹透中心。利尿剂不要自己加减。"],
                              sources: ["健康状况"], followUps: ["最近脚有点肿怎么办？"])
            }
            if p.onHemodialysis {
                return answer("透析以后尿量变少很常见，尿量的变化按透析中心的要求记录、告诉医护人员。", ["喝水按透析中心定的量；两次透析之间体重涨得多、气短或脚肿，及时联系透析中心。"],
                              sources: ["健康状况"], followUps: ["最近脚有点肿怎么办？"])
            }
            let first = p.watchesWeight ? "尿变少，同时有脚肿或体重涨，可能是身体存了水，尽快联系医生。" : "尿少多数是喝水少或出汗多，先看看这两天喝了多少。"
            return answer(first, [p.watchesWeight ? "利尿剂不要自己加减；今天称一下体重。" : "一天尿量明显少、颜色很深，或者伴有腰疼、发烧，去医院查一下。"],
                          sources: ["健康状况"], followUps: ["最近脚有点肿怎么办？"])
        }
        let first = "偶尔有泡沫不用紧张；一直有泡沫、久久不散，要告诉医生查尿蛋白。"
        let u = c.lab(.uacr, within: 365)
        return answer(first, [u.map { "你 \($0.date.formatted(.dateTime.month().day())) 的尿白蛋白/肌酐比是 \($0.valueText) mg/g（\(LabAnalyzer.status(.uacr, $0.value, profile: p).text)），泡沫尿可能和尿里漏蛋白有关。" },
                              p.conditions.contains(.ckd) ? "控制好血压和血糖、少吃盐，都能减少尿蛋白；复查时一起查尿白蛋白/肌酐比。" : nil],
                      sources: [u == nil ? "常识" : "化验结果"], followUps: ["我的肾功能怎么样？"], destination: u == nil ? nil : .labs)
    }

    static func itch(_ a: AgentQuestion, _ c: AgentContext) -> AgentReply {
        let p = c.profile
        let kidney = p.conditions.contains(.ckd) || p.onDialysis
        let first = kidney ? "皮肤痒在肾病里很常见，常和皮肤干、血磷偏高有关，告诉肾内科医生，有办法缓解。"
            : "皮肤痒多数是皮肤干，天冷、洗澡水太热、洗得太勤都会加重；先做好保湿，一两周不见好去看皮肤科。"
        var seen: [String] = []
        if let ph = c.lab(.phosphorus, within: 365), ph.value > 1.45 { seen.append("血磷 \(ph.valueText) mmol/L 偏高，磷高常让人皮肤痒") }
        if let w = KidneyDiet.week(c.days, profile: p, now: c.now), w.phosphorusPerDay >= 1 { seen.append("这周高磷食物平均每天 \(w.phosphorusPerDay.oneDecimal) 份") }
        if p.hasDiabetes, (c.glucose.tar ?? 0) > 0.25 { seen.append("血糖偏高的时间比较多，血糖高也会让皮肤干痒") }
        return answer(first, [
            found(seen),
            HealthAgent.bullets(["洗澡用温水、时间短一些，洗完趁皮肤还潮就涂保湿霜", "穿宽松的棉质衣服，别用力抓，指甲剪短",
                                 kidney ? "少吃加工食品、深色汽水这类高磷食物，降磷药按医生的安排吃" : "少吃辛辣，留意是不是换了洗衣液或护肤品"]),
            "痒得睡不着、起了大片疹子，或者皮肤、眼白发黄，尽快就医。",
        ], sources: ["健康状况", c.labs.isEmpty ? nil : "化验结果"].compactMap { $0 }, followUps: kidney ? ["我的化验结果怎么样？"] : [],
                      destination: c.labs.isEmpty ? nil : .labs)
    }

    static func appetite(_ a: AgentQuestion, _ c: AgentContext) -> AgentReply {
        let p = c.profile
        let hypoRisk = p.hypoRiskMeds()
        let first = hypoRisk ? "吃得少的时候要先留意血糖：你在用会引起低血糖的药，吃得比平时少时多测几次，药怎么调先问医生，别自己停。"
            : "一两天没胃口多数和累、压力、天热或着凉有关，先吃清淡、少量多餐；持续一周以上要查一下原因。"
        var seen: [String] = []
        if let e = LabAnalyzer.egfrSeries(c.labs).last, e.value < 30 { seen.append("eGFR \(e.valueText) 比较低，肾功能下降时也会没胃口、恶心") }
        if let h = lowHb(c) { seen.append("血红蛋白 \(h.valueText) g/L 偏低") }
        if c.recent7.filter(\.highStress).count >= 3 { seen.append("这周压力大的天比较多") }
        let weights = c.vitals.filter { $0.kind == .weight && $0.time > c.now.adding(days: -30) }.sorted { $0.time < $1.time }
        if let f = weights.first, let l = weights.last, f.value - l.value >= 2 { seen.append("近一个月体重少了 \((f.value - l.value).oneDecimal) kg") }
        return answer(first, [
            found(seen),
            HealthAgent.bullets(["少量多餐，选容易消化的", p.tracksNutrients ? "蛋白质别吃得太少，按医生定的量来" : "保证每餐有点蛋白质，比如鸡蛋、豆腐、鱼",
                                 "记下每天大概吃了多少，复诊时告诉医生"]),
            "一周以上吃不下、体重明显下降，或者伴有呕吐、腹痛、黑便，去看医生；\(p.conditions.contains(.ckd) || p.onDialysis ? "肾病的人还要告诉肾内科医生。" : "")",
        ], sources: ["健康状况", c.labs.isEmpty ? nil : "化验结果"].compactMap { $0 }, followUps: hypoRisk ? ["血糖控制得怎么样？"] : [])
    }

    static func nocturia(_ a: AgentQuestion, _ c: AgentContext) -> AgentReply {
        let p = c.profile
        let first = "晚上起夜两次以上，先看看是不是睡前喝水多、喝了茶或咖啡；如果最近才变多，或者白天尿也多、总口渴，要去查一下。"
        var seen: [String] = []
        if p.hasDiabetes, (c.glucose.tar ?? 0) > 0.25 { seen.append("血糖偏高的时间比较多，血糖高会让尿变多") }
        if p.conditions.contains(.ckd) { seen.append("你有慢性肾病，肾脏浓缩尿的能力下降时夜里尿会变多") }
        if c.medications.contains(where: { $0.name.contains("呋塞米") || $0.name.contains("利尿") || $0.name.contains("氢氯噻嗪") }) { seen.append("利尿剂下午或晚上吃，夜里尿会多，吃药时间问医生能不能调") }
        if p.sex == .male, p.age >= 50 { seen.append("50 岁以上的男性，前列腺增大也常让人起夜") }
        var tips = ["睡前 2 小时少喝水，晚上不喝茶、咖啡和酒", "记 2–3 天起夜几次、每次大概多少，看医生时带上"]
        if p.fluidLimited { tips[0] = "一天的水按医生定的上限，尽量放在白天喝" }
        return answer(first, [
            found(seen),
            HealthAgent.bullets(tips),
            "尿里有血、尿痛、发烧，或者起夜多同时脚肿、气短，尽快就医。",
        ], sources: ["健康状况"], followUps: p.hasDiabetes ? ["血糖控制得怎么样？"] : [])
    }

    static func headache(_ a: AgentQuestion, _ c: AgentContext) -> AgentReply {
        let p = c.profile
        let hasBP = p.conditions.contains(.hypertension) || c.bp.count > 0
        let rest = hasBP ? "头疼时先量一下血压。" : "先找个安静的地方休息一下；头疼常见的原因是睡得少、没吃饭、喝水少、压力大，或者咖啡突然停了。"
        // 「头疼能吃布洛芬吗」 is answered first.
        let painkiller = KidneyMeds.asksAbout(a.text) ? KidneyMeds.answer(p, labs: c.labs) : nil
        let first = painkiller ?? rest
        var why: [String] = []
        if let s = lastNight(c), s < 360 { why.append("昨晚只睡了 \((s / 60).oneDecimal) 小时") }
        if c.recent7.filter(\.highStress).count >= 2 { why.append("最近压力大") }
        if let y = c.days.first(where: { $0.day == c.logicalToday.adding(days: -1) }), y.hadAlcohol { why.append("昨天喝了酒") }
        if let last = recentBP(c, days: 3).max(by: { $0.time < $1.time }), last.value >= 160 { why.append("最近一次血压 \(Int(last.value))/\(Int(last.value2 ?? 0))") }
        return answer(first, [
            painkiller == nil ? nil : rest,
            hasBP ? "血压在 180/110 以上又头疼得厉害，或者伴有一侧无力、说话不清、看东西模糊，立即拨打 120。" : "突然剧烈头疼（像被打了一下），或者伴有发烧、脖子发硬、一侧无力，立即就医。",
            found(why),
            "头疼越来越频繁或越来越重，去看医生。",
            painkiller == nil && KidneyMeds.atRisk(p, labs: c.labs) ? "想吃止痛药的话，布洛芬这类药可能伤肾，先问医生或药师用哪种。" : nil,
        ], sources: ["睡眠", hasBP ? "血压" : nil].compactMap { $0 }, followUps: hasBP ? ["我的血压控制得怎么样？"] : ["我的睡眠怎么样？"])
    }
}
