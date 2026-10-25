import Foundation

// Chronic conditions the user mentions to the Health Agent (「我是低血钾症患者」). A few have built-in
// care (`HealthCondition`); for others Pulse keeps a small library of well-established
// patient-education points, each tied to concrete changes: no hard sessions, hot-day sessions
// indoors, and what the agent keeps in mind. The library is local and fixed — nothing is looked up
// online or written by a model. Nothing is recorded until the user taps 记下 on the card; a
// condition without an entry is recorded by name only.

struct ConditionInfo: Identifiable, Equatable {
    var id: String
    var name: String
    var aliases: [String] = []
    /// Recording it ticks this built-in condition instead.
    var native: HealthCondition? = nil
    /// Why it matters for training and daily life, in a sentence.
    var summary = ""
    var exercise: [String] = []
    var daily: [String] = []
    /// When to stop and see a doctor.
    var stopSigns = ""
    /// No interval or other hard sessions until a doctor says otherwise.
    var moderateOnly = false
    /// Hot days move outdoor sessions indoors.
    var avoidHeat = false
    /// No jumping, sprinting or heavy loads.
    var noImpact = false

    /// Built in or in the library; otherwise only the name is known.
    var known: Bool { native != nil || !summary.isEmpty }

    /// What Pulse does differently once it is recorded.
    var changes: [String] {
        if let n = native { return ConditionLibrary.builtInChanges(n) }
        guard known else {
            return ["Health Agent 回答时会知道你有\(name)，就诊摘要里也会列出",
                    "Pulse 的资料库里还没有\(name)的要点：运动和饮食上的具体限制，请问医生后写进「我的 › 健康状况与用药」里的「身体限制」"]
        }
        var out: [String] = []
        if moderateOnly { out.append("运动计划不再安排间歇等高强度训练，问到高强度训练时会建议先问医生") }
        if noImpact { out.append("运动计划不安排间歇、冲刺和大重量，问到这类训练时会提醒你") }
        if avoidHeat { out.append("高温天（32°C 以上）的户外训练建议改到室内") }
        out.append("运动计划附上\(name)的运动要点，Health Agent 回答时也会考虑")
        out.append("就诊摘要里列出这一情况")
        return out
    }

    /// One line for the language models: what to keep in mind.
    var brief: String {
        guard known, native == nil else { return name }
        return "\(name)：\(summary)\((exercise + daily.prefix(2)).joined())\(stopSigns)"
    }
}

/// A condition the user mentioned, shown as a card to record (记下).
struct ConditionProposal: Identifiable, Equatable {
    let id: UUID
    var info: ConditionInfo
    /// What the user wrote, e.g. 「低血钾」.
    var said: String
}

enum ConditionLibrary {
    static let sourceNote = "要点整理自常见的患者教育资料，Pulse 不做诊断；具体怎么做以医生的建议为准。"

    /// Built-in conditions, by the words people use for them.
    static let builtIn: [ConditionInfo] = [
        .init(id: "ckd", name: "慢性肾病", aliases: ["慢性肾脏病", "慢性肾病", "肾功能不全", "肾功能衰竭", "肾衰竭", "肾衰", "尿毒症", "肾小球肾炎", "糖尿病肾病", "多囊肾", "肾病", "CKD"], native: .ckd,
              summary: "肾病需要重点管好血压，留意体重和水肿；规律运动有好处，强度和饮水按医生的要求。"),
        .init(id: "heartFailure", name: "心力衰竭", aliases: ["心力衰竭", "心功能不全", "心衰"], native: .heartFailure,
              summary: "心衰需要每天称体重、留意水肿和气短，运动强度按医生确认的范围。"),
        .init(id: "hypertension", name: "高血压", aliases: ["高血压"], native: .hypertension,
              summary: "血压管理靠规律测量、规律运动和少盐，运动时避免憋气用力。"),
        .init(id: "coronaryDisease", name: "冠心病", aliases: ["冠心病", "冠状动脉粥样硬化性心脏病"], native: .coronaryDisease,
              summary: "运动强度要在医生确认的范围内，出现胸痛、胸闷时立即停止。"),
        .init(id: "arrhythmia", name: "心律失常 / 房颤", aliases: ["心房颤动", "房颤", "心律失常"], native: .arrhythmia,
              summary: "心律不齐时手表心率可能不准，运动强度以主观感受为准。"),
        .init(id: "diabetesT1", name: "1 型糖尿病", aliases: ["1型糖尿病", "一型糖尿病", "Ⅰ型糖尿病"], native: .diabetesT1,
              summary: "运动前后看血糖，随身带快速碳水，留意运动后和夜间的低血糖。"),
        .init(id: "diabetesT2", name: "2 型糖尿病", aliases: ["2型糖尿病", "二型糖尿病", "Ⅱ型糖尿病"], native: .diabetesT2,
              summary: "规律运动帮助控制血糖；用胰岛素或磺脲类药物时留意运动后的低血糖。"),
        .init(id: "thyroid", name: "甲状腺疾病", aliases: ["甲状腺功能亢进", "甲状腺功能减退", "甲亢", "甲减", "桥本"], native: .thyroid,
              summary: "甲状腺功能会直接影响静息心率，解读心率变化时需要考虑。"),
        .init(id: "sleepApnea", name: "睡眠呼吸暂停", aliases: ["阻塞性睡眠呼吸暂停", "睡眠呼吸暂停"], native: .sleepApnea,
              summary: "规律使用呼吸机能改善夜间心率和白天精神。"),
        .init(id: "respiratory", name: "哮喘 / 慢阻肺", aliases: ["慢性阻塞性肺疾病", "慢阻肺", "哮喘", "COPD"], native: .respiratory,
              summary: "运动前充分热身，冷空气和空气污染时在室内运动。"),
        .init(id: "anemia", name: "贫血", aliases: ["贫血"], native: .anemia,
              summary: "贫血时心率会偏高、运动更容易累，强度循序渐进。"),
    ]

    /// Conditions without built-in care, with what Pulse changes for them.
    static let entries: [ConditionInfo] = [
        .init(id: "hypokalemia", name: "低血钾症", aliases: ["低钾血症", "低血钾症", "低血钾", "血钾偏低", "血钾低", "缺钾"],
              summary: "血钾低时肌肉和心脏更容易出问题：运动中可能乏力、抽筋，严重时心律不齐。",
              exercise: ["血钾恢复正常、医生同意之前，运动以中低强度为主，不做间歇和冲刺。",
                         "大量出汗会带走钾，高温天不在户外长时间运动。"],
              daily: ["腹泻、呕吐、大量出汗之后更容易低钾，这时留意乏力、抽筋等症状。",
                      "补钾的方式和量按医生的要求，不要自己加量或停掉。",
                      "利尿剂、泻药等会影响血钾，在「我的 › 健康状况与用药」里记下来，复诊时给医生看。",
                      "按医生的安排复查血钾。"],
              stopSigns: "运动中出现明显无力、抽筋、心慌或心跳不齐，马上停下休息；不缓解请就医。",
              moderateOnly: true, avoidHeat: true),
        .init(id: "hyperkalemia", name: "高钾血症", aliases: ["高钾血症", "高血钾症", "高血钾", "血钾偏高", "血钾高"],
              summary: "血钾高会影响心跳节律，饮食、低钠盐和一些药物都可能让血钾升高。",
              exercise: ["医生确认之前，运动以中低强度为主。"],
              daily: ["不少「低钠盐」用钾代替钠，血钾高时不要自己换用低钠盐，先问医生。",
                      "香蕉、橙子、土豆、菌菇、浓汤等含钾较多，怎么吃按医生或营养师的建议。",
                      "一些降压药和利尿剂会影响血钾，在「我的 › 健康状况与用药」里记下来，复诊时给医生看。",
                      "按医生的安排复查血钾。"],
              stopSigns: "出现明显无力、麻木、心慌或心跳不齐，尽快就医。",
              moderateOnly: true),
        .init(id: "gout", name: "痛风", aliases: ["痛风性关节炎", "痛风", "高尿酸血症", "高尿酸", "尿酸高"],
              summary: "痛风发作和饮酒、脱水关系很大，发作期关节需要休息。",
              exercise: ["发作期（关节红肿热痛）停止运动，让关节休息；缓解后从骑车、游泳、快走这类低冲击运动慢慢恢复。",
                         "高温天大量出汗容易脱水，不在户外长时间运动。"],
              daily: ["少喝酒，尤其是啤酒；少喝含糖饮料。",
                      "医生没有让你限水的话，每天多喝些水。",
                      "动物内脏、浓肉汤和部分海鲜嘌呤高，适量。"],
              stopSigns: "关节突然剧烈红肿热痛，或伴发热，请就医。",
              avoidHeat: true),
        .init(id: "osteoporosis", name: "骨质疏松", aliases: ["骨质疏松症", "骨质疏松", "骨量减少"],
              summary: "骨质疏松时跌倒和撞击容易骨折，但合适的负重运动对骨骼有好处。",
              exercise: ["选快走、爬楼梯、轻中等重量的力量训练，对骨骼有好处。",
                         "避免跳跃、冲撞，以及弯腰负重、大幅度扭转脊柱的动作。",
                         "雨雪、路面结冰时不在户外运动，防止滑倒。"],
              daily: ["钙和维生素 D 怎么补按医生的建议。",
                      "家里清掉容易绊脚的东西，夜里起床先开灯。"],
              stopSigns: "跌倒后剧烈疼痛、不能负重，或背部突然剧痛，请就医。",
              noImpact: true),
        .init(id: "rheumatoid", name: "类风湿关节炎", aliases: ["类风湿性关节炎", "类风湿关节炎", "类风湿"],
              summary: "关节炎症时好时坏，发作期需要减量，平稳期规律运动有助于保持关节功能。",
              exercise: ["发作期（关节肿痛、晨僵明显）减量，改做轻柔的关节活动。",
                         "优先骑车、游泳、快走、太极这类低冲击运动。",
                         "力量训练用轻重量、多次数，不做到力竭。"],
              daily: ["晨僵时长和肿痛的关节可以记在当天的备注里，复诊时给医生看。"],
              stopSigns: "关节突然明显肿胀、发热，或伴发烧，请就医。",
              noImpact: true),
        .init(id: "epilepsy", name: "癫痫", aliases: ["癫痫病", "癫痫", "羊癫疯"],
              summary: "规律作息、避开诱因是控制发作的关键；运动通常可以做，但要避开发作时有危险的场景。",
              exercise: ["不独自游泳、攀高，不在车流中骑车；游泳要有人陪同。",
                         "避免过度疲劳和严重脱水。"],
              daily: ["睡眠不足和饮酒是常见诱因：保持规律作息，少喝或不喝酒。",
                      "按时服药，在今天的记录里勾选「已按时服药」。"],
              stopSigns: "发作超过 5 分钟、连续发作，或发作后迟迟不醒，立即拨打 120。"),
        .init(id: "pots", name: "体位性心动过速综合征", aliases: ["体位性心动过速综合征", "体位性心动过速", "直立性心动过速", "POTS"],
              summary: "站起来时心率明显升高，静息心率和准备度会受影响，热天和久站会加重症状。",
              exercise: ["先从躺着或坐着的运动开始（卧式单车、划船机、游泳），适应后再慢慢加入站立运动。",
                         "循序渐进加量，不在高温环境下运动。"],
              daily: ["从躺着或坐着起身时慢一些。", "饮水和盐的量按医生的建议。"],
              stopSigns: "出现晕厥或几乎晕倒，停止活动并就医。",
              moderateOnly: true, avoidHeat: true),
        .init(id: "hypotension", name: "低血压", aliases: ["低血压症", "低血压", "血压偏低"],
              summary: "血压偏低时，起身太快、天热、久站和运动刚结束都可能头晕。",
              exercise: ["运动结束后多慢走几分钟放松，不要突然停下。", "高温天在凉快的地方运动。"],
              daily: ["起床、蹲下站起时慢一些。", "饮水和盐的量按医生的建议。"],
              stopSigns: "反复头晕、眼前发黑或晕倒，请就医。",
              avoidHeat: true),
    ]

    static func entry(id: String) -> ConditionInfo? { (builtIn + entries).first { $0.id == id } }

    /// A stored id, or a name Pulse has no entry for.
    static func resolve(_ raw: String) -> ConditionInfo { entry(id: raw) ?? ConditionInfo(id: raw, name: raw) }

    static func builtInChanges(_ c: HealthCondition) -> [String] {
        switch c {
        case .ckd:
            ["运动计划以中低强度为主，医生确认强度范围前不安排间歇等高强度训练",
             "3 天内体重增加 2 kg 以上时提醒你（可能是体内存了水）",
             "医生要求限水时，可以在「我的 › 恢复目标」打开「限水」，Pulse 就不再提醒多喝水",
             "血压按照护目标解读，Health Agent 回答时考虑肾病"]
        case .heartFailure:
            ["运动以低–中等强度为主，计划里不安排高强度训练",
             "3 天内体重增加 2 kg 以上时提醒你",
             "医生要求限水时，可以在「我的 › 恢复目标」打开「限水」"]
        case .hypertension, .coronaryDisease, .arrhythmia:
            ["打开血压照护目标和异常读数提醒",
             "医生确认强度范围前，运动以低–中等强度为主"]
        case .diabetesT1, .diabetesT2:
            ["运动计划附上运动前后看血糖的提醒",
             "血糖读数按糖尿病的目标范围解读"]
        default:
            ["解读静息心率、准备度和回答问题时考虑这一情况"]
        }
    }

    // MARK: Hearing it in a message

    private static let separators = Set("，。！？；,.!?;\n")
    /// What may stand between 「我」 and the condition in a statement about oneself.
    private static let cues = ["被诊断为", "被诊断出", "诊断为", "确诊为", "确诊了", "确诊", "患有", "得的是", "得了", "一直有", "本身有",
                               "自己有", "现在有", "也有", "也是", "属于", "是一名", "是一位", "是个", "一名", "一位", "是", "有", "患", "的"]
    /// A question or a doubt, not a statement.
    private static let doubts = ["怀疑", "担心", "会不会", "是不是", "有没有", "可能", "是否", "怕", "如果", "假如", "以前", "曾经"]
    /// Words that look like a condition name but are not one.
    private static let notConditions = ["毛病", "老毛病", "职业病", "小病", "大病", "炎症", "发炎", "病", "症", "炎", "强迫症", "拖延症", "选择困难症"]

    /// A chronic condition the user says they have, unless it is already recorded. Only statements
    /// about oneself count: 「我妈有高血压」「我是不是有低血钾？」「以前得过痛风」 do not.
    static func mention(in q: String, profile p: ProfileSnapshot) -> ConditionProposal? {
        let all = (builtIn + entries).flatMap { e in e.aliases.map { (e, $0) } }.sorted { $0.1.count > $1.1.count }
        for (e, alias) in all {
            guard let r = q.range(of: alias, options: .caseInsensitive), aboutSelf(q, at: r) else { continue }
            if let n = e.native { if p.conditions.contains(n) { return nil } }
            else if p.extraConditions.contains(where: { $0.id == e.id }) { return nil }
            return ConditionProposal(id: UUID(), info: e, said: String(q[r]))
        }
        // A condition the library does not know: 「我是 X 患者」「我有 X 病 / 症 / 炎」.
        let patterns = [#"(?:我|本人)(?:是|患有|得了|确诊了?|确诊为|有)(?:一名|一位|一个|个)?([\p{Han}A-Za-z0-9]{2,10}?)(?:患者|病人)"#,
                        #"(?:我|本人)(?:患有|得了|确诊了?|确诊为|一直有|有)([\p{Han}]{1,8}(?:综合征|病|症|炎))(?=[，。！？；,.!?;\s]|$)"#]
        for pattern in patterns {
            guard let m = q.range(of: pattern, options: .regularExpression),
                  let re = try? NSRegularExpression(pattern: pattern),
                  let match = re.firstMatch(in: q, range: NSRange(m, in: q)),
                  let nr = Range(match.range(at: 1), in: q) else { continue }
            let name = String(q[nr])
            guard aboutSelf(q, at: nr), !notConditions.contains(name), !name.contains("点"), !name.contains("些"),
                  !name.contains("糖尿病"), !name.contains("的"), !name.hasSuffix("科"),
                  !p.extraConditions.contains(where: { $0.name == name }) else { continue }
            return ConditionProposal(id: UUID(), info: ConditionInfo(id: name, name: name), said: name)
        }
        return nil
    }

    /// 「我（是 / 有 / 确诊了…）X」「作为一名 X 患者」 in one clause, with no doubt before it and no
    /// question right after.
    private static func aboutSelf(_ q: String, at r: Range<String.Index>) -> Bool {
        let clauseStart = q[..<r.lowerBound].lastIndex { separators.contains($0) }.map { q.index(after: $0) } ?? q.startIndex
        let before = String(q[clauseStart..<r.lowerBound])
        guard !doubts.contains(where: { before.contains($0) }) else { return false }
        let me = ["我", "本人", "作为"].compactMap { before.range(of: $0, options: .backwards) }.max { $0.lowerBound < $1.lowerBound }
        guard let me else { return false }
        var lead = String(before[me.upperBound...]).trimmingCharacters(in: .whitespaces)
        while let cue = cues.first(where: { lead.hasPrefix($0) }) { lead.removeFirst(cue.count) }
        guard lead.isEmpty else { return false }
        let clauseEnd = q[r.upperBound...].firstIndex { separators.contains($0) } ?? q.endIndex
        let after = q[r.upperBound..<clauseEnd]
        if after.contains("吗") || after.contains("么") { return false }
        if clauseEnd < q.endIndex, "？?".contains(q[clauseEnd]) { return false }
        return true
    }
}
