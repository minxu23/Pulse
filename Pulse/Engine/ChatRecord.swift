import Foundation

// MARK: - Recording from the conversation

/// What the user asked the chat to record — 「帮我记一下血压 138/88」「我刚喝了一杯水」「脚有点肿，记下来」
/// 「午饭吃了两碗米饭、一个鸡蛋」「刚走了 40 分钟」「下周三提醒我去医院复查」. Nothing is written until the
/// user taps 记下 on the card (like a plan change or a condition), and it can be undone.
struct RecordProposal: Identifiable, Equatable {
    /// A meal: its foods from the diet lists (`DietFoods`), one entry per portion, and what was said.
    struct Meal: Equatable {
        var kind: MealKind
        var foods: [String]
        var said: String
        var at: Date
    }
    /// A workout; `estimated` when the minutes come from the distance.
    struct Workout: Equatable {
        var type: WorkoutType
        var minutes: Int
        var km: Double?
        var effort: Int
        var estimated: Bool
        var start: Date
    }

    enum Item: Equatable {
        case bloodPressure(sys: Int, dia: Int, context: MeasureContext)
        case glucose(Double, context: MeasureContext)
        case weight(kg: Double)
        case water(ml: Int)
        case swelling(Edema, places: [String])
        case urine(UrineAmount)
        case foamyUrine
        /// In Pulse's own unit.
        case lab(LabKind, value: Double)
        /// A 照护与随访 task; `timed` when the user gave a time of day.
        case reminder(title: String, area: CareArea, due: Date, timed: Bool)
        case meal(Meal)
        case workout(Workout)
    }

    let id: UUID
    var items: [Item]
    /// When it was measured, or the day it belongs to.
    var time: Date
    /// 「每天晚上 9 点」「每周一、四」「每月 5 号」: the reminder repeats.
    var repeats: CareRepeat? = nil
    /// A repeat Pulse can't follow yet (「每次透析后」「每隔两天」): it is added once.
    var repeatAsked = false

    var reminder: (title: String, area: CareArea, due: Date, timed: Bool)? {
        for i in items { if case .reminder(let t, let a, let d, let timed) = i { return (t, a, d, timed) } }
        return nil
    }

    /// 「血压 138/88 mmHg · 晨起」.
    static func label(_ i: Item) -> String {
        switch i {
        case .bloodPressure(let s, let d, let c): "血压 \(s)/\(d) mmHg" + (c == .random ? "" : " · \(c.label)")
        case .glucose(let v, let c): "血糖 \(v.oneDecimal) mmol/L" + (c == .random ? "" : " · \(c.label)")
        case .weight(let kg): "体重 \(kg.oneDecimal) kg"
        case .water(let ml): "饮水 \(ml) ml"
        case .swelling(let e, let places): "水肿：\(e.label)" + (places.isEmpty ? "" : "（\(places.joined(separator: "、"))）")
        case .urine(let u): "尿量：\(u.label)"
        case .foamyUrine: "泡沫尿"
        case .lab(let k, let v): "\(k.label) \(k.format(v)) \(k.unit)"
        case .reminder(let t, _, _, _): "提醒：\(t)"
        case .meal(let m): "\(m.kind.label)：" + (m.foods.isEmpty ? m.said : ChatRecord.portions(m.foods))
        case .workout(let w):
            w.type.label + (w.km.map { " \($0.cleanText) 公里" } ?? "") + (w.estimated ? " · 约 \(w.minutes) 分钟" : " \(w.minutes) 分钟")
        }
    }

    static func icon(_ i: Item) -> String {
        switch i {
        case .bloodPressure: "heart.text.square"
        case .glucose: "drop.fill"
        case .weight: "scalemass"
        case .water: "drop"
        case .swelling, .urine, .foamyUrine: "drop.triangle"
        case .lab: "testtube.2"
        case .reminder: "bell"
        case .meal: "fork.knife"
        case .workout(let w): w.type.icon
        }
    }
}

enum ChatRecord {
    /// 「帮我记一下」「记下来」, or a plain statement of what was just measured, drunk, eaten or done.
    static func wanted(_ a: AgentQuestion) -> Bool {
        if a.has(["帮我记", "记一下", "记下来", "帮我记录", "记录一下", "记上", "帮我登记", "记个"]) { return true }
        let question = a.has(["吗", "？", "?", "怎么", "要不要", "多少", "什么", "呢"])
        // 「今天早上血压 138/88」 states a reading; 「血压 155 要紧吗」 asks about one.
        guard !question else { return false }
        return a.has(["刚量", "量了", "测了", "刚测", "称了", "刚称", "喝了", "刚喝"]) || a.reading != nil
            || meal(a, now: .app) != nil || workout(a, now: .app) != nil
    }

    /// What a statement holds that Pulse can record; nil when nothing it can.
    static func proposal(_ a: AgentQuestion, now: Date) -> RecordProposal? {
        let q = a.text
        let day = a.has(["昨天", "昨晚"]) ? now.adding(days: -1) : now
        var items: [RecordProposal.Item] = []
        switch a.reading {
        case .bp(let s, let d?)?:
            let ctx: MeasureContext = a.has(["早上", "晨起", "起床", "早晨"]) ? .morning : (a.has(["睡前", "晚上", "睡觉前"]) ? .bedtime : .random)
            items.append(.bloodPressure(sys: s, dia: d, context: ctx))
        case .glucose(let v, let c)?:
            items.append(.glucose(v, context: c ?? .random))
        case .weight(let kg)?:
            items.append(.weight(kg: kg))
        case .lab(let k, let v, let unit, _)?:
            items.append(.lab(k, value: k.standard(v, unit: unit)))
        default: break
        }
        if let ml = water(in: q) { items.append(.water(ml: ml)) }
        if let m = meal(a, now: now) { items.append(.meal(m)) }
        if let w = workout(a, now: now) { items.append(.workout(w)) }
        if let s = a.symptom {
            switch s {
            case .swelling:
                let marked = a.has(["很肿", "明显", "厉害", "肿得", "按下去坑很深"])
                items.append(.swelling(marked ? .marked : .mild, places: KidneySigns.places.filter { q.contains($0) || (($0 == "脚踝") && q.contains("脚")) || ($0 == "眼睑" && q.contains("眼皮")) }))
            case .urine:
                if a.has(["泡沫"]) { items.append(.foamyUrine) }
                if a.has(["尿少", "尿量少", "尿量变少"]) { items.append(.urine(.less)) }
            default: break
            }
        }
        guard !items.isEmpty else { return nil }
        let time = Calendar.pulse.isDate(day, inSameDayAs: now) ? now : day.startOfDay.adding(minutes: 12 * 60)
        return RecordProposal(id: UUID(), items: items, time: time)
    }

    /// 「一杯水」「两杯」「一瓶水」「500ml」: millilitres drunk; a cup is 250 ml, a bottle 500 ml.
    static func water(in q: String) -> Int? {
        guard q.contains("水") || q.contains("ml") || q.contains("毫升"), q.contains("喝") || q.contains("饮水") else { return nil }
        if let g = AgentQuestion.groups(#"(\d{2,4})\s*(?:ml|毫升|mL)"#, q), let n = Int(g[0]), (50...3000).contains(n) { return n }
        if let g = AgentQuestion.groups(#"([0-9一二两三四五六七八九十半]+)\s*(杯|瓶)"#, q) {
            let n = g[0] == "半" ? 0.5 : AgentQuestion.number(g[0]) ?? 1
            return Int(n * (g[1] == "瓶" ? 500 : 250))
        }
        return nil
    }

    // MARK: Meals

    /// Words for foods on the diet lists, longest first when read; a word that names nothing on
    /// them (面包, 蛋糕) is read so that a shorter one inside it isn't.
    static let foodWords: [(words: [String], foods: [String])] = [
        (["鸡蛋", "鸭蛋", "荷包蛋", "煎蛋", "煮蛋", "茶叶蛋"], ["鸡蛋"]),
        (["牛奶", "酸奶", "纯奶"], ["牛奶、酸奶"]),
        (["瘦肉", "猪肉", "牛肉", "羊肉", "鸡肉", "鸭肉", "鸡腿", "鸡胸", "排骨", "肉片", "肉丝"], ["瘦肉"]),
        (["鱼肉", "鱼片", "鱼", "虾仁", "虾"], ["鱼虾"]),
        (["豆腐", "豆干", "腐竹", "千张", "豆制品"], ["豆腐、豆制品"]),
        (["豆浆"], ["豆浆"]),
        (["米饭", "白饭", "碗饭"], ["米饭"]),
        (["馒头", "包子", "花卷", "烧饼", "煎饼", "饼"], ["馒头、包子、饼"]),
        (["面条", "拉面", "挂面", "汤面", "碗面", "牛肉面", "炸酱面"], ["面条"]),
        (["蔬菜", "青菜", "白菜", "菠菜", "生菜", "油麦菜"], ["蔬菜"]),
        (["没焯水的绿叶菜", "没焯水的青菜"], ["没焯水的绿叶菜"]),
        (["香蕉"], ["香蕉"]),
        (["橙子", "橘子", "桔子"], ["橙子、橘子"]),
        (["猕猴桃", "奇异果"], ["猕猴桃"]),
        (["土豆", "红薯", "芋头", "地瓜", "马铃薯"], ["土豆、红薯、芋头"]),
        (["蘑菇", "香菇", "菌菇", "金针菇", "木耳"], ["菌菇"]),
        (["番茄", "西红柿"], ["番茄"]),
        (["坚果", "核桃", "花生", "杏仁", "腰果", "瓜子"], ["坚果、干果", "坚果、瓜子"]),
        (["干果", "红枣", "葡萄干"], ["坚果、干果"]),
        (["绿豆", "红豆", "黄豆", "豆类", "扁豆"], ["豆类"]),
        (["肉汤", "鸡汤", "浓汤", "老火汤"], ["浓汤、肉汤"]),
        (["骨头汤"], ["浓汤、肉汤", "骨头汤、浓肉汤"]),
        (["果汁", "橙汁", "苹果汁"], ["果汁"]),
        (["低钠盐", "代盐"], ["低钠盐、代盐"]),
        (["香肠", "火腿", "午餐肉", "腊肉", "培根", "腊肠"], ["香肠、午餐肉等加工食品", "香肠、火腿、腊肉"]),
        (["可乐", "汽水"], ["可乐等深色汽水"]),
        (["奶酪", "芝士"], ["奶酪、奶制品较多"]),
        (["内脏", "猪肝", "鸡肝", "腰子", "肥肠"], ["动物内脏"]),
        (["咸菜", "榨菜", "腌菜", "泡菜", "酸菜", "咸鸭蛋", "腐乳"], ["咸菜、腌制品"]),
        (["方便面", "泡面", "速冻"], ["方便面、速冻食品"]),
        (["外卖", "下馆子", "在外面吃"], ["外卖或在外吃"]),
        (["薯片", "辣条"], ["咸味零食"]),
        (["面包", "饼干", "蛋糕", "奶茶", "鱼香"], []),
    ]

    /// Foods named, one entry per portion: 「两碗米饭、一个鸡蛋」 → 米饭, 米饭, 鸡蛋. High-salt foods once.
    static func foods(in q: String) -> [String] {
        let words = foodWords.flatMap { e in e.words.map { ($0, e.foods) } }.sorted { $0.0.count > $1.0.count }
        var taken: [Range<String.Index>] = []
        var found: [(at: String.Index, foods: [String], n: Int)] = []
        for (w, foods) in words {
            var from = q.startIndex
            while let r = q.range(of: w, range: from..<q.endIndex) {
                from = r.upperBound
                guard !taken.contains(where: { $0.overlaps(r) }) else { continue }
                taken.append(r)
                // 「两碗」「3 个」「一根」 right before the food.
                let before = String(q[q.index(r.lowerBound, offsetBy: -min(5, q.distance(from: q.startIndex, to: r.lowerBound)))..<r.lowerBound])
                let n = AgentQuestion.groups(#"([0-9一二两三四五六七八九十半]+)\s*小?(?:碗|个|根|杯|两|块|份|盒|瓶|片|把|罐|只|串|袋|包|勺)?$"#, before)
                    .flatMap { AgentQuestion.number($0[0]) }.map { max(1, Int($0.rounded(.up))) } ?? 1
                found.append((r.lowerBound, foods, min(n, 6)))
            }
        }
        var out: [String] = []
        for f in found.sorted(by: { $0.at < $1.at }) {
            for name in f.foods {
                if DietFoods.salt.contains(name) { if !out.contains(name) { out.append(name) } }
                else { out += Array(repeating: name, count: f.n) }
            }
        }
        return out
    }

    /// 「米饭 ×2、鸡蛋」.
    static func portions(_ foods: [String]) -> String {
        KidneyDiet.counted(foods).map { $0.n > 1 ? "\($0.name) ×\($0.n)" : $0.name }.joined(separator: "、")
    }

    /// 「午饭吃了两碗米饭、一个鸡蛋」「刚吃完晚饭」: the meal, when the sentence says one was eaten.
    static func meal(_ a: AgentQuestion, now: Date) -> RecordProposal.Meal? {
        let q = a.text
        guard a.has(["吃了", "刚吃", "吃完", "吃过", "喝了", "刚喝"]) else { return nil }
        let named: [(String, MealKind)] = [("早饭", .breakfast), ("早餐", .breakfast), ("早点", .breakfast), ("午饭", .lunch), ("午餐", .lunch),
                                           ("中饭", .lunch), ("晚饭", .dinner), ("晚餐", .dinner), ("夜宵", .snack), ("宵夜", .snack),
                                           ("加餐", .snack), ("零食", .snack), ("下午茶", .snack)]
        let kindNamed = named.first { q.contains($0.0) }?.1
        let foods = foods(in: q)
        // Something eaten Pulse knows, or a meal named; 「吃了布洛芬」 is neither.
        guard !foods.isEmpty || kindNamed != nil else { return nil }
        let day = a.has(["昨天", "昨晚"]) ? now.adding(days: -1) : now
        let hour = Calendar.pulse.component(.hour, from: now)
        let kind = kindNamed ?? (q.contains("早上") ? .breakfast : q.contains("中午") ? .lunch : q.contains("晚上") ? .dinner
            : (5..<10).contains(hour) ? .breakfast : (10..<15).contains(hour) ? .lunch : (17..<21).contains(hour) ? .dinner : .snack)
        // A meal named earlier in the day is at its usual time; just now, it is now.
        let usual: [MealKind: Int] = [.breakfast: 7 * 60 + 30, .lunch: 12 * 60, .dinner: 18 * 60 + 30]
        var at = Calendar.pulse.isDate(day, inSameDayAs: now) ? now : day.startOfDay.adding(minutes: usual[kind] ?? 15 * 60)
        if kindNamed != nil, !a.has(["刚吃", "刚"]), let m = usual[kind] {
            let t = day.startOfDay.adding(minutes: m)
            if t < now { at = t }
        }
        var said = q
        for w in ["帮我记一下", "帮我记录", "记录一下", "记一下", "记下来", "帮我记", "记上", "我"] { said = said.replacingOccurrences(of: w, with: "") }
        said = said.trimmingCharacters(in: CharacterSet(charactersIn: " ，,。.！!、"))
        return RecordProposal.Meal(kind: kind, foods: foods, said: String(said.prefix(60)), at: at)
    }

    // MARK: Workouts

    static let workoutWords: [(words: [String], type: WorkoutType)] = [
        (["间歇", "HIIT", "hiit"], .hiit),
        (["跑步", "慢跑", "晨跑", "夜跑", "跑了"], .run),
        (["快走", "散步", "走路", "步行", "徒步", "走了", "遛弯", "爬山"], .walk),
        (["骑车", "骑行", "骑了", "单车"], .cycle),
        (["游泳", "游了"], .swim),
        (["力量", "举铁", "撸铁", "哑铃", "深蹲", "器械"], .strength),
        (["瑜伽", "拉伸", "太极", "八段锦"], .yoga),
        (["篮球", "足球", "羽毛球", "乒乓", "网球", "打球"], .ball),
    ]

    /// 「刚走了 40 分钟」「早上跑了 5 公里」「骑车一个半小时」: what, how long, when. Steps (「走了 8000 步」)
    /// come from Apple Health, not from here.
    static func workout(_ a: AgentQuestion, now: Date) -> RecordProposal.Workout? {
        let q = a.text
        guard let type = workoutWords.first(where: { a.has($0.words) })?.type,
              q.range(of: #"\d+\s*步(?!行)"#, options: .regularExpression) == nil else { return nil }
        var minutes = 0.0
        if let g = AgentQuestion.groups(#"([0-9.一二两三四五六七八九十]+)\s*个?\s*(半)?\s*(?:小时|钟头)"#, q), let h = AgentQuestion.number(g[0]) {
            minutes += h * 60 + (g.count > 1 && g[1] == "半" ? 30 : 0)
        } else if a.has(["半小时", "半个小时", "半个钟头"]) {
            minutes += 30
        }
        if let g = AgentQuestion.groups(#"([0-9一二两三四五六七八九十]+)\s*(?:分钟|min)"#, q), let m = AgentQuestion.number(g[0]) { minutes += m }
        let km = AgentQuestion.groups(#"([0-9.一二两三四五六七八九十]+)\s*(?:公里|千米|km|KM)"#, q).flatMap { AgentQuestion.number($0[0]) }
            .flatMap { (0.2...100).contains($0) ? $0 : nil }
        let perKm: [WorkoutType: Double] = [.run: 6, .walk: 12, .cycle: 3, .swim: 30]
        let estimated = minutes == 0
        if estimated, let km, let pace = perKm[type] { minutes = (km * pace / 5).rounded() * 5 }
        guard (5...360).contains(minutes) else { return nil }
        let base: [WorkoutType: Int] = [.walk: 3, .run: 5, .cycle: 4, .swim: 5, .strength: 5, .hiit: 7, .yoga: 2, .ball: 6]
        var effort = base[type] ?? 4
        if a.has(["累", "吃力", "喘", "很辛苦"]) { effort += 2 } else if a.has(["轻松"]) { effort -= 1 }
        // Ended just now, or at the time of day said.
        let day = a.has(["昨天", "昨晚"]) ? now.adding(days: -1) : now
        var start = Calendar.pulse.isDate(day, inSameDayAs: now) ? now.adding(minutes: -Int(minutes)) : day.startOfDay.adding(minutes: 19 * 60)
        if let clock = reminderTime(q) {
            let t = day.startOfDay.adding(minutes: clock)
            if t.adding(minutes: Int(minutes)) <= now { start = t }
        }
        return RecordProposal.Workout(type: type, minutes: Int(minutes), km: km, effort: min(max(effort, 1), 9), estimated: estimated, start: start)
    }

    /// Whether a workout counts for a planned session of this kind.
    static func fits(_ t: WorkoutType, _ k: PlanKind) -> Bool {
        switch k {
        case .aerobic, .long: [.run, .walk, .cycle, .swim].contains(t)
        case .quality: [.run, .hiit, .cycle, .swim].contains(t)
        case .strength: t == .strength
        case .mobility: t == .yoga
        default: false
        }
    }

    /// The planned session that day a workout counts for: one not done yet, of a kind it fits.
    static func planned(for w: RecordProposal.Workout, in plan: [SessionSnapshot]) -> SessionSnapshot? {
        plan.first { Calendar.pulse.isDate($0.day, inSameDayAs: w.start) && $0.kind.isTraining && [.planned, .partial].contains($0.status) && fits(w.type, $0.kind) }
    }

    // MARK: Reminders

    static func asksReminder(_ a: AgentQuestion) -> Bool {
        a.has(["提醒我", "到时候提醒", "记得提醒", "帮我设个提醒", "设个提醒", "帮我提醒", "叫我"]) && !a.has(["怎么", "在哪"])
    }

    /// 「下周三提醒我去医院复查」「提醒我明天早上 8 点量血压」: what, when (a day, and a time if said).
    static func reminder(_ a: AgentQuestion, now: Date) -> RecordProposal {
        let q = a.text
        let (day, dayWord) = reminderDay(q, now: now)
        let clock = reminderTime(q)
        var due = (day ?? now.startOfDay.adding(days: clock.map { now.startOfDay.adding(minutes: $0) > now } == true ? 0 : 1))
        if let m = clock { due = due.startOfDay.adding(minutes: m) }
        // A repeat without its day (「每周」「每个月」) keeps the day named, or today's.
        var repeats = repeating(q)
        if case .weekly(let w)? = repeats, w.isEmpty { repeats = .weekly([(day ?? now).weekday]) }
        if case .monthly(let d)? = repeats, d == 0 { repeats = .monthly(Calendar.pulse.component(.day, from: day ?? now)) }
        if let r = repeats { due = r.first(onOrAfter: now, minutes: clock) }
        // What to do: the sentence without the reminder words, the repeat, the day and the time.
        var title = q.replacingOccurrences(of: repeatWords, with: "", options: .regularExpression)
        for w in ["帮我设个提醒", "设个提醒", "到时候提醒我", "记得提醒我", "帮我提醒", "提醒我一下", "提醒我", "叫我", "到时候", "一下", "请", "帮我"] {
            title = title.replacingOccurrences(of: w, with: "")
        }
        if let dayWord { title = title.replacingOccurrences(of: dayWord, with: "") }
        for pattern in [clockDigits, clockWords] {
            title = title.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        title = title.replacingOccurrences(of: #"^(早上|上午|中午|下午|傍晚|晚上)"#, with: "", options: .regularExpression)
        title = title.trimmingCharacters(in: CharacterSet(charactersIn: " ，,。.！!？?、的要"))
        if title.isEmpty { title = "提醒" }
        let area: CareArea
        if ["血压", "心内", "降压"].contains(where: q.contains) { area = .cardio }
        else if ["血糖", "糖化", "胰岛素", "眼底", "足部"].contains(where: q.contains) { area = .diabetes }
        else if ["肾", "透析", "肌酐", "血钾", "化验", "复查"].contains(where: q.contains) { area = .kidney }
        else if ["睡", "呼吸机"].contains(where: q.contains) { area = .sleep }
        else { area = .general }
        return RecordProposal(id: UUID(), items: [.reminder(title: title, area: area, due: due, timed: clock != nil)], time: now,
                              repeats: repeats, repeatAsked: repeats == nil && a.has(["每次", "每隔", "每两", "每三", "每半"]))
    }

    /// 「每天」「每晚」「每周一三五」「每周一和周四」「每个月 5 号」.
    static let repeatWords = #"每(?:天|日|晚|早)|天天|每个?(?:周|星期|礼拜)(?:[一二三四五六日天、和及]|周|星期|礼拜)*|每个?月(?:\s*\d{1,2}\s*[号日])?"#

    /// The repeat a reminder asks for; a weekly or monthly one without its day has an empty day
    /// (filled in by `reminder`).
    static func repeating(_ q: String) -> CareRepeat? {
        if q.range(of: #"每(?:天|日|晚|早)|天天"#, options: .regularExpression) != nil { return .daily }
        if let r = q.range(of: #"每个?(?:周|星期|礼拜)(?:[一二三四五六日天、和及]|周|星期|礼拜)*"#, options: .regularExpression) {
            let names: [Character: Int] = ["一": 2, "二": 3, "三": 4, "四": 5, "五": 6, "六": 7, "日": 1, "天": 1]
            let days = Set(q[r].dropFirst().compactMap { names[$0] })
            return .weekly(Weekday.mondayFirst.filter(days.contains))
        }
        if let g = AgentQuestion.groups(#"每个?月\s*(\d{1,2})\s*[号日]"#, q), let d = Int(g[0]), (1...31).contains(d) { return .monthly(d) }
        if q.contains("每个月") || q.contains("每月") { return .monthly(0) }
        return nil
    }

    /// The day named: 今天/明天/后天, 周X (this week's, or next if past), 下周X, X月X日, X号, N天后.
    static func reminderDay(_ q: String, now: Date) -> (Date?, String?) {
        let today = now.startOfDay
        let names: [Character: Int] = ["一": 2, "二": 3, "三": 4, "四": 5, "五": 6, "六": 7, "日": 1, "天": 1]
        if let g = AgentQuestion.groups(#"(下个?(?:周|星期|礼拜))([一二三四五六日天])"#, q), let wd = names[Character(g[1])] {
            let nextMonday = today.weekStart.adding(days: 7)
            return (nextMonday.adding(days: Weekday.mondayFirst.firstIndex(of: wd) ?? 0), g[0] + g[1])
        }
        if let g = AgentQuestion.groups(#"((?:这|本)?(?:周|星期|礼拜))([一二三四五六日天])"#, q), let wd = names[Character(g[1])] {
            var d = today.weekStart.adding(days: Weekday.mondayFirst.firstIndex(of: wd) ?? 0)
            if d < today { d = d.adding(days: 7) }
            return (d, g[0] + g[1])
        }
        if let g = AgentQuestion.groups(#"(\d{1,2})\s*月\s*(\d{1,2})\s*[日号]"#, q), let m = Int(g[0]), let dd = Int(g[1]) {
            var c = Calendar.pulse.dateComponents([.year], from: today)
            c.month = m; c.day = dd
            if var d = Calendar.pulse.date(from: c) {
                if d < today { d = Calendar.pulse.date(byAdding: .year, value: 1, to: d) ?? d }
                return (d, "\(g[0])月\(g[1])" + (q.contains("\(g[1])号") ? "号" : "日"))
            }
        }
        if let g = AgentQuestion.groups(#"(?<![月\d])(\d{1,2})\s*号"#, q), let dd = Int(g[0]) {
            var c = Calendar.pulse.dateComponents([.year, .month], from: today)
            c.day = dd
            if var d = Calendar.pulse.date(from: c) {
                if d < today { d = Calendar.pulse.date(byAdding: .month, value: 1, to: d) ?? d }
                return (d, "\(g[0])号")
            }
        }
        if let g = AgentQuestion.groups(#"([0-9一二两三四五六七八九十]+)\s*(天|周|个星期|个月)(?:以?后|之后)"#, q), let n = AgentQuestion.number(g[0]) {
            let k = Int(n)
            let d = g[1] == "天" ? today.adding(days: k) : (g[1] == "个月" ? Calendar.pulse.date(byAdding: .month, value: k, to: today) ?? today : today.adding(days: 7 * k))
            return (d, AgentQuestion.groups(#"([0-9一二两三四五六七八九十]+\s*(?:天|周|个星期|个月)(?:以?后|之后))"#, q)?.first)
        }
        for (w, n) in [("大后天", 3), ("后天", 2), ("明天", 1), ("明早", 1), ("明晚", 1), ("今天", 0), ("今晚", 0)] where q.contains(w) {
            return (today.adding(days: n), w == "明早" || w == "明晚" || w == "今晚" ? nil : w)
        }
        if q.contains("下周") { return (today.weekStart.adding(days: 7), "下周") }
        if q.contains("下个月") { return (Calendar.pulse.date(byAdding: .month, value: 1, to: today), "下个月") }
        return (nil, nil)
    }

    /// 「8 点半」「21:30」, and 「晚上九点」 — a Chinese numeral only right after a part of the day, so
    /// 「多喝一点水」 is no time.
    static let clockDigits = #"(?:早上|上午|中午|下午|傍晚|晚上|今晚|明早|明晚|每晚|每早)?\s*(\d{1,2})\s*[点:：]\s*(半|\d{1,2})?\s*分?"#
    static let clockWords = #"(?:早上|上午|中午|下午|傍晚|晚上|今晚|明早|明晚|每晚|每早)\s*([一二两三四五六七八九十]{1,3})\s*点\s*(半)?"#

    /// Minutes past midnight: 「8 点」「晚上 9 点半」「下午 3:30」, or a part of the day alone (早上 8:00…).
    static func reminderTime(_ q: String) -> Int? {
        let part = AgentQuestion.groups(#"(早上|上午|中午|下午|傍晚|晚上|今晚|明早|明晚|每晚|每早)"#, q)?.first
        if let g = AgentQuestion.groups(clockDigits, q) ?? AgentQuestion.groups(clockWords, q), let h0 = AgentQuestion.number(g[0]) {
            var h = Int(h0)
            let m = g.count > 1 ? (g[1] == "半" ? 30 : Int(g[1]) ?? 0) : 0
            if ["下午", "傍晚", "晚上", "今晚", "明晚", "每晚"].contains(part ?? ""), h < 12 { h += 12 }
            if part == "中午", h < 6 { h += 12 }
            return (0...23).contains(h) && (0...59).contains(m) ? h * 60 + m : nil
        }
        switch part {
        case "早上", "明早", "每早": return 8 * 60
        case "上午": return 9 * 60
        case "中午": return 12 * 60
        case "下午": return 15 * 60
        case "傍晚": return 18 * 60
        case "晚上", "今晚", "明晚", "每晚": return 20 * 60
        default: return nil
        }
    }
}
