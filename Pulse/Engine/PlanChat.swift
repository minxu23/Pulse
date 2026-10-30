import Foundation

// Adjusting the training plan in conversation. The user says what changed ("周三加班", "膝盖有点疼",
// "想多练一点"); the rules engine — or the cloud model when it is on — turns that into a few plan
// edits. Every edit then goes through the same local safety checks (volume growth, hard sessions,
// care-plan limits, readiness, a rest day) before the user sees a before/after card to adopt.

enum PlanScope: String, Equatable {
    case thisWeek = "this_week", nextWeek = "next_week"
    var label: String { self == .thisWeek ? "本周" : "下周" }
}

enum PlanEditOp: Equatable {
    case move(from: Int, to: Int)
    case minutes(day: Int, minutes: Int)
    case intensity(day: Int, Intensity)
    /// `target` picks the session when a day has several (e.g. an easy run and strength).
    case replace(day: Int, kind: PlanKind, title: String, minutes: Int?, intensity: Intensity?, detail: String?, target: PlanKind? = nil)
    case scale(Double)
}

struct PlanChangeLine: Identifiable, Equatable {
    var id: Int { weekday }
    let weekday: Int
    let day: Date
    let before: String
    let after: String
}

struct PlanChangeProposal: Identifiable, Equatable {
    let id: UUID
    var scope: PlanScope
    var weekStart: Date
    var before: [SessionSnapshot]
    var after: [SessionSnapshot]
    /// Next week's plan did not exist yet: adopting it creates the whole week.
    var generated: Bool
    var lines: [PlanChangeLine]
    /// Safety checks that ran, and what they changed.
    var checks: [String]
    var request: String
    var source: String
    var minutesBefore: Int
    var minutesAfter: Int
    /// How the request was read, e.g. why a session was skipped rather than moved.
    var notes: [String] = []
    var hasChanges: Bool { !lines.isEmpty }
}

enum PlanChat {
    enum Parse: Equatable {
        case edits(PlanScope, [PlanEditOp], notes: [String] = [])
        case clarify(AgentForm)
    }

    // MARK: Recognising a plan request

    static let busyWords = ["没空", "没时间", "有事", "加班", "出差", "去不了", "来不及", "不在家", "聚餐", "请假", "想休息", "不想练", "不练"]
    static let moveWords = ["改到", "换到", "挪到", "移到", "调到", "放到", "推迟到", "提前到", "改成周", "换成周"]
    static let easierWords = ["轻松一点", "轻松些", "轻一点", "太累", "好累", "疲劳", "降低强度", "减量", "少练", "练少", "强度太大", "吃不消", "顶不住", "太多了"]
    static let moreWords = ["多练", "加一次", "加练", "加量", "再加", "练多", "增加训练", "增加一次", "提高强度", "加强", "多跑"]
    static let painWords = ["疼", "痛", "受伤", "扭伤", "拉伤", "不舒服"]
    static let lowerBody = ["膝", "脚踝", "踝", "腿", "跟腱", "足底", "脚", "髋", "小腿", "大腿"]
    static let upperBody = ["肩", "手腕", "胳膊", "手臂", "肘"]
    static let backWords = ["腰", "背"]
    private static let planWords = ["计划", "训练", "练", "跑", "运动", "课", "安排"]

    static func isRequest(_ q: String) -> Bool {
        let planish = planWords.contains { q.contains($0) }
        if moveWords.contains(where: { q.contains($0) }) { return true }
        if q.contains("调整") && planish { return true }
        if busyWords.contains(where: { q.contains($0) }) && !q.contains("睡") && (planish || !weekdays(in: q, now: .app).isEmpty) { return true }
        if ["轻松一点", "轻松些", "降低强度", "减量", "少练"].contains(where: { q.contains($0) }) { return true }
        if easierWords.contains(where: { q.contains($0) }) && planish { return true }
        if moreWords.contains(where: { q.contains($0) }) { return true }
        if q.contains("换成") && activity(in: q) != nil { return true }
        if painWords.contains(where: { q.contains($0) }) && (lowerBody + upperBody + backWords).contains(where: { q.contains($0) }) { return true }
        return false
    }

    /// Weekdays in the order they are mentioned; "周三到周五" expands to the range.
    static func weekdays(in q: String, now: Date, profile p: ProfileSnapshot? = nil) -> [Int] {
        var hits: [(Range<String.Index>, Int)] = []
        let map: [Character: Int] = ["一": 2, "二": 3, "三": 4, "四": 5, "五": 6, "六": 7, "日": 1, "天": 1]
        if let re = try? NSRegularExpression(pattern: "(周|星期|礼拜)([一二三四五六日天])") {
            for m in re.matches(in: q, range: NSRange(q.startIndex..., in: q)) {
                guard let r = Range(m.range, in: q), let c = q[r].last, let wd = map[c] else { continue }
                hits.append((r, wd))
            }
        }
        // Before 5 am the night is not over: "明天" is the coming daytime.
        let early = TrainingCheck.isBeforeWake(now, profile: p) ? 1 : 0
        for (word, offset) in [("今天", 0), ("明天", 1 - early), ("后天", 2 - early)] {
            var from = q.startIndex
            while let r = q.range(of: word, range: from..<q.endIndex) {
                hits.append((r, now.adding(days: offset).weekday))
                from = r.upperBound
            }
        }
        hits.sort { $0.0.lowerBound < $1.0.lowerBound }
        var out: [Int] = []
        for (i, h) in hits.enumerated() {
            if i > 0 {
                let between = q[hits[i - 1].0.upperBound..<h.0.lowerBound].trimmingCharacters(in: .whitespaces)
                if ["到", "至", "-", "~", "—", "～"].contains(between) {
                    let a = PlanGenerator.order(hits[i - 1].1), b = PlanGenerator.order(h.1)
                    if a < b { for k in (a + 1)..<b { out.append(Weekday.mondayFirst[k]) } }
                }
            }
            if !out.contains(h.1) { out.append(h.1) }
        }
        return out
    }

    static func minutes(in q: String) -> Int? {
        if q.contains("半小时") || q.contains("半个小时") { return 30 }
        if q.contains("一小时") || q.contains("一个小时") { return 60 }
        guard let re = try? NSRegularExpression(pattern: "(\\d+)\\s*(分钟|min)"),
              let m = re.firstMatch(in: q, range: NSRange(q.startIndex..., in: q)),
              let r = Range(m.range(at: 1), in: q) else { return nil }
        return Int(q[r])
    }

    static func activity(in q: String) -> (kind: PlanKind, title: String, detail: String)? {
        let table: [(String, PlanKind, String, String)] = [
            ("游泳", .aerobic, "游泳（轻松）", "低冲击的全身有氧，保持可以换气说话的节奏。"),
            ("骑行", .aerobic, "骑行（轻松）", "低冲击有氧，室内单车或户外骑行均可，保持可以说话的强度。"),
            ("单车", .aerobic, "骑行（轻松）", "低冲击有氧，室内单车或户外骑行均可，保持可以说话的强度。"),
            ("椭圆", .aerobic, "椭圆机（轻松）", "低冲击有氧，保持可以说话的强度。"),
            ("快走", .aerobic, "快走", "保持微微出汗、可以完整说话的速度。"),
            ("力量", .strength, "全身力量训练", "深蹲、俯卧撑、划船、臀桥、平板支撑，各 2–3 组，动作平稳、不憋气。"),
            ("瑜伽", .mobility, "瑜伽 / 拉伸", "以舒展和呼吸为主，不追求难度。"),
            ("拉伸", .mobility, "瑜伽 / 拉伸", "以舒展和呼吸为主，不追求难度。"),
            ("跑步", .aerobic, "轻松跑", "保持可以完整说话的强度。"),
        ]
        guard let i = q.range(of: "换成")?.upperBound else { return nil }
        let tail = String(q[i...])
        return table.first { tail.contains($0.0) }.map { ($0.1, $0.2, $0.3) }
    }

    // MARK: The week being edited

    static func weekStart(_ scope: PlanScope, now: Date) -> Date {
        scope == .thisWeek ? now.weekStart : now.weekStart.adding(days: 7)
    }

    /// The sessions of the week; next week's plan is generated from the current settings when it
    /// has not been created yet.
    static func slots(_ scope: PlanScope, context c: AgentContext) -> (weekStart: Date, items: [SessionSnapshot], generated: Bool) {
        let ws = weekStart(scope, now: c.now)
        let existing = c.plan.filter { $0.day >= ws && $0.day < ws.adding(days: 7) }
        if !existing.isEmpty { return (ws, existing.sorted { $0.day < $1.day }, false) }
        let plan = PlanGenerator.generate(profile: c.profile, weekStart: ws)
        let items = plan.sessions.map { s in
            SessionSnapshot(id: UUID(), day: ws.adding(days: PlanGenerator.order(s.weekday)), kind: s.kind, title: s.title,
                            minutes: s.minutes, minimumMinutes: s.minimumMinutes, minimumDetail: s.minimumDetail,
                            intensity: s.intensity, isKey: s.isKey, status: .planned, completedMinutes: nil, newDetail: s.detail)
        }
        return (ws, items, true)
    }

    /// Days that may still change: today or later, with nothing on them done yet.
    static func editable(_ items: [SessionSnapshot], weekStart ws: Date, now: Date) -> Set<Int> {
        Set(Weekday.mondayFirst.filter { wd in
            let day = ws.adding(days: PlanGenerator.order(wd))
            guard day >= now.startOfDay else { return false }
            return items.filter { $0.day == day }.allSatisfy { $0.status == .planned }
        })
    }

    static func day(_ wd: Int, _ ws: Date) -> Date { ws.adding(days: PlanGenerator.order(wd)) }

    private static func training(_ items: [SessionSnapshot], on day: Date) -> [SessionSnapshot] {
        items.filter { $0.day == day && $0.kind.isTraining }
    }

    // MARK: Rules: request → edits

    static func parse(_ q: String, context c: AgentContext) -> Parse {
        var scope: PlanScope = q.contains("下周") || q.contains("下个星期") ? .nextWeek : .thisWeek
        var (ws, items, _) = slots(scope, context: c)
        var open = editable(items, weekStart: ws, now: c.now)
        // Nothing left to change this week: work on next week instead.
        if scope == .thisWeek, !open.contains(where: { !training(items, on: day($0, ws)).isEmpty }) {
            scope = .nextWeek
            (ws, items, _) = slots(scope, context: c)
            open = editable(items, weekStart: ws, now: c.now)
        }
        let days = weekdays(in: q, now: c.now, profile: c.profile)
        let mins = minutes(in: q)
        let trainingDays = Weekday.mondayFirst.filter { open.contains($0) && !training(items, on: day($0, ws)).isEmpty }
        func free(excluding: Set<Int>, near wd: Int, in list: [SessionSnapshot]) -> Int? {
            let hard = Set(list.filter { $0.intensity == .hard || $0.kind == .long }.map(\.day.weekday))
            return Weekday.mondayFirst
                .filter { open.contains($0) && !excluding.contains($0) && training(list, on: day($0, ws)).isEmpty }
                .min { a, b in
                    func cost(_ x: Int) -> Int {
                        let d = PlanGenerator.order(x) - PlanGenerator.order(wd)
                        let near = [x - 1, x + 1].map { ($0 + 6) % 7 + 1 }.contains { hard.contains($0) }
                        return (d > 0 ? d : 10 - d) + (near ? 3 : 0)
                    }
                    return cost(a) < cost(b)
                }
        }

        // 1. Pain: keep moving, but without load on the sore area.
        if painWords.contains(where: { q.contains($0) }) {
            let lower = lowerBody.contains { q.contains($0) }
            let upper = upperBody.contains { q.contains($0) }
            let back = backWords.contains { q.contains($0) }
            if !(lower || upper || back), q.contains("全身") || q.contains("疲劳") {
                return parse(scope == .nextWeek ? "下周轻松一点的训练" : "轻松一点的训练", context: c)
            }
            guard lower || upper || back else {
                return .clarify(AgentForm(id: "plan-pain", title: "哪里不舒服？", fields: [
                    AgentFormField(id: "where", label: "不舒服的部位", kind: .choice(options: ["膝盖 / 小腿", "脚踝 / 足底", "腰背", "肩 / 手臂", "说不清，全身疲劳"], multiple: false)),
                ], submitLabel: "发送", context: q))
            }
            let target = (days.isEmpty ? trainingDays : days.filter { open.contains($0) })
            var ops: [PlanEditOp] = []
            for wd in target {
                for s in training(items, on: day(wd, ws)) {
                    if lower || back, [.aerobic, .long, .quality].contains(s.kind) {
                        ops.append(.replace(day: wd, kind: .aerobic, title: "低冲击有氧：骑行 / 游泳", minutes: s.kind == .long ? min(s.minutes, 45) : s.minutes,
                                            intensity: .easy, detail: "换成对\(back ? "腰背" : "下肢")冲击小的方式，保持可以说话的强度；动作引起疼痛就停下。", target: s.kind))
                    } else if s.kind == .strength {
                        let title = lower ? "上肢与核心力量（避开下肢）" : (upper ? "下肢与核心力量（避开上肢）" : "灵活性与轻柔拉伸")
                        ops.append(.replace(day: wd, kind: back ? .mobility : .strength, title: title, minutes: min(s.minutes, 30), intensity: .easy,
                                            detail: "避开不舒服的部位，只做不引起疼痛的动作。", target: s.kind))
                    } else if s.intensity > .easy {
                        ops.append(.intensity(day: wd, .easy))
                    }
                }
            }
            return .edits(scope, ops)
        }

        // 2. "把周三改到周五", "周六推迟一天".
        if moveWords.contains(where: { q.contains($0) }), days.count >= 2 {
            return .edits(scope, [.move(from: days[0], to: days[1])])
        }
        if q.contains("推迟一天") || q.contains("往后推") || q.contains("顺延"), let d = days.first {
            let next = Weekday.mondayFirst[min(6, PlanGenerator.order(d) + 1)]
            return .edits(scope, [.move(from: d, to: next)])
        }

        // 3. Busy days: shorten when there is some time, otherwise move to a free day.
        if busyWords.contains(where: { q.contains($0) }) {
            let busy = days.filter { open.contains($0) }
            guard !busy.isEmpty else {
                if !days.isEmpty {
                    return .clarify(AgentForm(id: "plan-busy-past", title: "这些日子已经过去了，是指下周吗？", fields: [
                        AgentFormField(id: "which", label: "调整哪一周", kind: .choice(options: ["下周", "不用了"], multiple: false)),
                    ], submitLabel: "发送", context: q))
                }
                return .clarify(AgentForm(id: "plan-busy", title: "\(scope.label)哪几天没空？", fields: [
                    AgentFormField(id: "days", label: "没空的日子", kind: .weekdays),
                    AgentFormField(id: "minutes", label: "那几天还能活动", kind: .number(min: 0, max: 60, step: 5, unit: "分钟", value: 0)),
                ], submitLabel: "调整计划", context: q))
            }
            var ops: [PlanEditOp] = []
            var notes: [String] = []
            var working = items
            let trip = q.contains("出差")
            for wd in busy where !training(working, on: day(wd, ws)).isEmpty {
                if let m = mins, m >= 10 {
                    ops.append(.minutes(day: wd, minutes: m))
                } else if trip {
                    ops.append(.replace(day: wd, kind: .walk, title: "出差日：快走 + 10 分钟徒手力量", minutes: 25, intensity: .easy,
                                        detail: "在酒店或附近快走，加 10 分钟深蹲、俯卧撑、平板支撑。做一点比完全中断更容易保持规律。"))
                } else if let to = free(excluding: Set(busy), near: wd, in: working) {
                    ops.append(.move(from: wd, to: to))
                    let a = day(wd, ws), b = day(to, ws)
                    working = working.map { s in var s = s; if s.day == a { s.day = b } else if s.day == b { s.day = a }; return s }
                } else if let s = training(working, on: day(wd, ws)).first {
                    if mins == 0 {
                        ops.append(.replace(day: wd, kind: .rest, title: "跳过，不必补练", minutes: 0, intensity: .rest,
                                            detail: "这周剩下的日子都已安排训练，这次跳过即可。", target: s.kind))
                        notes.append("这周剩下的日子都已经安排了训练，没有空出来的日子可以挪，\(Weekday.name(wd))的「\(s.title)」先跳过，不需要在其他日子补练。")
                    } else {
                        ops.append(.replace(day: wd, kind: s.kind, title: "精简版：\(s.title)", minutes: max(10, s.minimumMinutes), intensity: .easy,
                                            detail: s.minimumDetail.isEmpty ? "做一个短版本保持规律。" : s.minimumDetail, target: s.kind))
                        notes.append("这周没有空出来的日子可以挪，\(Weekday.name(wd))改成 \(max(10, s.minimumMinutes)) 分钟的精简版；完全没时间的话，跳过也可以，不需要补练。")
                    }
                }
            }
            return .edits(scope, ops, notes: notes)
        }

        // 4. Easier week.
        if easierWords.contains(where: { q.contains($0) }) {
            let target = days.isEmpty ? trainingDays : days.filter { open.contains($0) }
            var ops: [PlanEditOp] = []
            for wd in target {
                for s in training(items, on: day(wd, ws)) {
                    if s.intensity == .hard || s.kind == .quality {
                        ops.append(.replace(day: wd, kind: .aerobic, title: "轻松有氧（替代\(s.title)）", minutes: max(20, Int(Double(s.minutes) * 0.8).roundedTo5()),
                                            intensity: .easy, detail: "这周先不做强度课，轻松有氧同样在积累有氧能力。", target: s.kind))
                    } else {
                        ops.append(.minutes(day: wd, minutes: max(15, Int(Double(s.minutes) * 0.8).roundedTo5())))
                    }
                }
            }
            return .edits(scope, ops)
        }

        // 5. More training: one extra session on a free day (the checks cap the growth).
        if moreWords.contains(where: { q.contains($0) }) {
            let wantsStrength = q.contains("力量")
            let wd = days.first { open.contains($0) && training(items, on: day($0, ws)).isEmpty }
                ?? free(excluding: [], near: c.now.weekday, in: items)
            if let wd {
                let m = wantsStrength ? 25 : max(20, Int(Double(c.profile.sessionMinutes) * 0.6).roundedTo5())
                return .edits(scope, [wantsStrength
                    ? .replace(day: wd, kind: .strength, title: "全身力量训练", minutes: m, intensity: .moderate,
                               detail: "深蹲、俯卧撑、划船、臀桥、平板支撑，各 2–3 组，每组 8–12 次，动作平稳、不憋气。")
                    : .replace(day: wd, kind: .aerobic, title: "轻松有氧（加练）", minutes: m, intensity: .easy,
                               detail: "多出来的一次保持轻松强度，重点是规律。")])
            }
            if let wd = trainingDays.first(where: { d in training(items, on: day(d, ws)).contains { $0.kind == .long || $0.kind == .aerobic } }),
               let s = training(items, on: day(wd, ws)).first {
                return .edits(scope, [.minutes(day: wd, minutes: s.minutes + 10)])
            }
            return .edits(scope, [])
        }

        // 6. Another kind of exercise on given days.
        if activity(in: q) == nil, q.contains("换一种") || q.contains("换个运动") || q.contains("换种运动") {
            return .clarify(AgentForm(id: "plan-swap", title: "换成什么运动？", fields: [
                AgentFormField(id: "kind", label: "换成", kind: .choice(options: ["骑行", "游泳", "快走", "力量", "瑜伽"], multiple: false)),
                AgentFormField(id: "days", label: "哪几天", kind: .weekdays),
            ], submitLabel: "调整计划", context: q))
        }
        if let a = activity(in: q) {
            let target = days.filter { open.contains($0) }
            guard !target.isEmpty else {
                return .clarify(AgentForm(id: "plan-swap-days", title: "哪几天换成\(a.title)？", fields: [
                    AgentFormField(id: "days", label: "哪几天", kind: .weekdays),
                ], submitLabel: "调整计划", context: q))
            }
            return .edits(scope, target.map { wd in
                let m = training(items, on: day(wd, ws)).first?.minutes ?? 30
                return .replace(day: wd, kind: a.kind, title: a.title, minutes: a.kind == .strength ? min(m, 30) : m,
                                intensity: a.kind == .strength ? .moderate : .easy, detail: a.detail)
            })
        }

        // 7. Limited time on given days (or every session).
        if let m = mins, q.contains("只有") || q.contains("最多") || q.contains("每次") {
            let target = days.isEmpty ? trainingDays : days.filter { open.contains($0) }
            return .edits(scope, target.map { .minutes(day: $0, minutes: m) })
        }

        // Not specific enough: ask what should change.
        return .clarify(AgentForm(id: "plan-what-\(scope.rawValue)", title: "想怎么调整\(scope.label)的计划？", fields: [
            AgentFormField(id: "how", label: "想怎么调整", kind: .choice(options: ["有几天没空", "整体轻松一点", "想多练一点", "身体有点不舒服", "换一种运动"], multiple: false)),
        ], submitLabel: "发送", context: "调整\(scope.label)计划"))
    }

    // MARK: Edits → checked proposal

    /// `checksWeather`: note the forecast for each changed day (off for changes made for the weather).
    static func propose(_ ops: [PlanEditOp], scope: PlanScope, request: String, context c: AgentContext, source: String,
                        checksWeather: Bool = true) -> PlanChangeProposal {
        let (ws, before, generated) = slots(scope, context: c)
        let open = editable(before, weekStart: ws, now: c.now)
        let p = c.profile
        var after = before
        var checks: [String] = []
        func note(_ s: String) { if !checks.contains(s) { checks.append(s) } }
        let maxSession = c.marathonActive ? 210 : max(90, Int(Double(p.sessionMinutes) * 1.5))
        func restDays(_ list: [SessionSnapshot]) -> Int {
            Weekday.mondayFirst.filter { training(list, on: day($0, ws)).isEmpty }.count
        }
        func primary(_ list: [SessionSnapshot], _ d: Date, _ kind: PlanKind? = nil) -> Int? {
            kind.flatMap { k in list.firstIndex { $0.day == d && $0.kind == k } }
                ?? list.firstIndex { $0.day == d && $0.kind.isTraining } ?? list.firstIndex { $0.day == d }
        }

        for op in ops {
            var next = after
            switch op {
            case .move(let from, let to):
                guard from != to, open.contains(from), open.contains(to) else {
                    note("只能调整今天及以后、还没完成的安排，\(Weekday.name(open.contains(from) ? to : from))这次没有改动。"); continue
                }
                let a = day(from, ws), b = day(to, ws)
                guard after.contains(where: { $0.day == a && $0.kind.isTraining }) else {
                    note("\(Weekday.name(from))本来没有安排训练，没有可以挪的。"); continue
                }
                next = after.map { s in var s = s; if s.day == a { s.day = b } else if s.day == b { s.day = a }; return s }
            case .minutes(let wd, let m):
                guard open.contains(wd), let i = primary(after, day(wd, ws)), after[i].kind.isTraining else { continue }
                next[i].minutes = min(max(10, m.roundedTo5()), after[i].kind == .strength ? 60 : maxSession)
                if next[i].minimumMinutes > next[i].minutes { next[i].minimumMinutes = max(10, next[i].minutes / 2) }
            case .intensity(let wd, let level):
                guard open.contains(wd), let i = primary(after, day(wd, ws)), after[i].kind.isTraining else { continue }
                next[i].intensity = level == .rest ? .easy : level
            case .replace(let wd, let kind, let title, let m, let level, let detail, let target):
                guard open.contains(wd) else { note("\(Weekday.name(wd))已经过去或已完成，没有改动。"); continue }
                let d = day(wd, ws)
                let cleanTitle = AgentUI.isSafe(title) ? String(title.prefix(30)) : kind.label
                let i = primary(after, d, target)
                var s = i.map { after[$0] } ?? SessionSnapshot(id: UUID(), day: d, kind: kind, title: cleanTitle, minutes: 0, minimumMinutes: 10,
                                                              minimumDetail: "", intensity: .easy, isKey: false, status: .planned, completedMinutes: nil)
                s.kind = kind
                s.title = cleanTitle
                s.intensity = kind == .rest ? .rest : (level == .rest ? .easy : (level ?? (kind == .strength ? .moderate : .easy)))
                let base = m ?? (s.minutes > 0 ? s.minutes : p.sessionMinutes)
                s.minutes = kind == .rest ? 0 : min(max(10, base.roundedTo5()), kind == .strength ? 60 : maxSession)
                s.minimumMinutes = kind == .rest ? 0 : min(s.minimumMinutes > 0 ? s.minimumMinutes : 10, s.minutes)
                if s.minimumDetail.isEmpty || kind != (i.map { after[$0].kind } ?? kind) {
                    s.minimumDetail = kind.isTraining ? "\(max(10, s.minutes / 2)) 分钟轻松版本" : ""
                }
                s.isKey = kind == .long || kind == .quality
                s.newDetail = detail.flatMap { AgentUI.isSafe($0) ? String($0.prefix(160)) : nil } ?? s.newDetail
                if let i { next[i] = s } else { next.append(s) }
            case .scale(let f):
                let factor = min(max(f, 0.5), 1.1)
                for i in next.indices where next[i].kind.isTraining && open.contains(next[i].day.weekday) && next[i].day >= ws {
                    next[i].minutes = max(10, Int(Double(next[i].minutes) * factor).roundedTo5())
                }
            }
            // Keep at least one day a week without training.
            if restDays(next) == 0 && restDays(after) > 0 {
                note("每周至少保留 1 天不训练用于恢复，「\(describe(op))」这一项没有采用。")
                continue
            }
            after = next
        }

        // Hard sessions: care-plan limit, weekly count, not on consecutive days, not on a low-readiness day.
        let wasHard = Set(before.filter { $0.intensity == .hard }.map(\.id))
        if p.cardiacLimited {
            for i in after.indices where after[i].intensity == .hard && !wasHard.contains(after[i].id) {
                after[i].intensity = .moderate
                note("较高强度还没有得到医生确认，新增的强度课改为中等强度。")
            }
        }
        let allowedHard = max(before.filter { $0.intensity == .hard }.count, p.cardiacLimited ? 0 : (c.marathonActive || p.level.rank >= 3 ? 2 : 1))
        var hardIDs = after.filter { $0.intensity == .hard }.sorted { $0.day < $1.day }.map(\.id)
        while hardIDs.count > allowedHard, let extra = hardIDs.last(where: { !wasHard.contains($0) }), let i = after.firstIndex(where: { $0.id == extra }) {
            after[i].intensity = .moderate
            hardIDs.removeAll { $0 == extra }
            note("每周较高强度最多 \(allowedHard) 次，多出的一次改为中等强度。")
        }
        let hardDays = after.filter { $0.intensity == .hard }.map(\.day).sorted()
        for (a, b) in zip(hardDays, hardDays.dropFirst()) where b.daysSince(a) == 1 {
            if let i = after.firstIndex(where: { $0.day == b && $0.intensity == .hard && !wasHard.contains($0.id) }) {
                after[i].intensity = .moderate
                note("两次较高强度不排在相邻两天，\(Weekday.name(b.weekday))改为中等强度。")
            }
        }
        if scope == .thisWeek, c.readiness.level == .rest || c.readiness.level == .low {
            let today = c.now.startOfDay
            for i in after.indices where after[i].day == today && after[i].kind.isTraining && after[i].intensity > .easy {
                let old = before.first { $0.id == after[i].id }
                if old?.day != today || (old?.intensity ?? .easy) < after[i].intensity {
                    after[i].intensity = .easy
                    note("今天准备度\(c.readiness.score.map { " \($0)" } ?? "")（\(c.readiness.level.label)），今天的训练保持低强度。")
                }
            }
        }

        if p.intensityCapped {
            for i in after.indices where after[i].intensity == .hard && after[i].status == .planned && open.contains(after[i].day.weekday) {
                after[i].intensity = .moderate
                note("你记录了\(p.intensityCaps.joined(separator: "、"))：医生确认之前不安排较高强度，\(Weekday.name(after[i].day.weekday))改为中等强度。")
            }
        }

        // Volume: at most ~10 % more than the current week (none while load is climbing fast or an urgent event is open).
        let total: ([SessionSnapshot]) -> Int = { list in
            list.filter { $0.kind.isTraining && $0.status != .skipped }
                .map { $0.status == .planned ? $0.minutes : ($0.completedMinutes ?? $0.minutes) }.reduce(0, +)
        }
        let minutesBefore = total(before)
        let urgent = c.openEvents.contains { $0.severity == .urgent }
        var cap = max(Int(Double(minutesBefore) * 1.1), minutesBefore + 15)
        if c.load.zone == .high || c.load.zone == .caution {
            cap = minutesBefore
            note("近期训练负荷增长较快（\(c.load.zone.label)），这次调整不增加总训练时长。")
        }
        if urgent {
            cap = minutesBefore
            note("有待处理的紧急提醒，先处理提醒，这次调整不增加训练量。")
        }
        var excess = total(after) - cap
        if excess > 0 {
            let grown = after.indices.filter { i in
                after[i].kind.isTraining && after[i].status == .planned && after[i].minutes > (before.first { $0.id == after[i].id && $0.kind.isTraining }?.minutes ?? 0)
            }.reversed()
            var drop: [Int] = []
            for i in grown where excess > 0 {
                let old = before.first { $0.id == after[i].id }
                let floor = old.map { $0.kind.isTraining ? $0.minutes : 0 } ?? 0
                let cut = min(excess, after[i].minutes - floor)
                if floor == 0 && after[i].minutes - cut < 20 {
                    // A new session that does not fit is left out rather than shrunk to a token.
                    excess -= after[i].minutes
                    if var o = old { o.day = after[i].day; after[i] = o } else { drop.append(i) }
                } else {
                    after[i].minutes -= cut
                    excess -= cut
                }
            }
            for i in drop.sorted(by: >) { after.remove(at: i) }
            note("为避免训练量突增，\(scope.label)总训练时长控制在 \(cap) 分钟以内（约 +10%）。")
        }
        let minutesAfter = total(after)

        if painWords.contains(where: { request.contains($0) }) {
            note("疼痛持续超过 1 周、明显肿胀或影响走路时，请就医评估；运动中疼痛加重就停下。")
        }
        if p.hasDiabetes && p.hypoRiskMeds(at: c.now) {
            note("调整后的训练日照常按照护计划在运动前后看血糖，随身带快速碳水。")
        }
        if let cap = p.hrCap { note("心率上限仍为 \(cap) bpm（照护计划）。") }

        // Before/after per day.
        var lines: [PlanChangeLine] = []
        for wd in Weekday.mondayFirst {
            let d = day(wd, ws)
            let a = describe(before.filter { $0.day == d }), b = describe(after.filter { $0.day == d })
            if a != b { lines.append(PlanChangeLine(weekday: wd, day: d, before: a, after: b)) }
        }
        // The weather where a session lands: the forecast notes about the current plan don't cover it.
        var notes: [String] = []
        if checksWeather {
            for l in lines {
                guard let w = c.weather(on: l.day),
                      let s = after.first(where: { $0.day == l.day && $0.status == .planned && WeatherPlanner.isOutdoor($0) }),
                      let n = WeatherPlanner.note(forChanged: s, on: w, profile: p) else { continue }
                notes.append(n)
            }
        }
        if !lines.isEmpty {
            checks.insert(minutesAfter == minutesBefore ? "总训练时长不变（\(minutesBefore) 分钟）。"
                          : "总训练时长 \(minutesBefore) → \(minutesAfter) 分钟（\(minutesAfter > minutesBefore ? "+" : "")\(Int((Double(minutesAfter - minutesBefore) / Double(max(1, minutesBefore)) * 100).rounded()))%）。", at: 0)
        }
        return PlanChangeProposal(id: UUID(), scope: scope, weekStart: ws, before: before, after: after.sorted { $0.day < $1.day }, generated: generated,
                                  lines: lines, checks: checks, request: request, source: source, minutesBefore: minutesBefore, minutesAfter: minutesAfter,
                                  notes: notes)
    }

    static func describe(_ items: [SessionSnapshot]) -> String {
        let t = items.filter { $0.kind.isTraining }
        if t.isEmpty {
            if let r = items.first(where: { $0.kind == .rest }) { return r.title == "休息恢复" ? "休息" : r.title }
            if let w = items.first(where: { $0.kind == .walk && $0.title != "日常活动日" }) { return "\(w.title) \(w.minutes) 分钟" }
            return "日常活动"
        }
        return t.map { "\($0.title) \($0.minutes) 分钟" + ($0.intensity == .easy ? "" : " · \($0.intensity.label)") }.joined(separator: " + ")
    }

    static func describe(_ op: PlanEditOp) -> String {
        switch op {
        case .move(let a, let b): "\(Weekday.name(a))移到\(Weekday.name(b))"
        case .minutes(let d, let m): "\(Weekday.name(d)) \(m) 分钟"
        case .intensity(let d, let i): "\(Weekday.name(d))\(i.label)"
        case .replace(let d, _, let t, _, _, _, _): "\(Weekday.name(d))改为\(t)"
        case .scale(let f): "整体调整为 \(Int(f * 100))%"
        }
    }

    // MARK: Rules answer

    static func reply(_ q: String, context c: AgentContext) -> AgentReply {
        if q.hasSuffix("不用了") {
            return AgentReply(text: "好的，计划保持不变。之后有变化随时告诉我。", followUps: ["今天适合运动吗？"])
        }
        switch parse(q, context: c) {
        case .clarify(let form):
            // A question back to the user: shown as written, a model would only shorten it.
            return AgentReply(text: clarifyText(form), sources: ["\(form.id.contains("next") ? "下周" : "本周")计划"],
                              blocks: [.form(form)], conclusion: clarifyText(form).split(separator: "。").first.map { String($0) + "。" }, verbatim: true)
        case .edits(let scope, let ops, let notes):
            var p = propose(ops, scope: scope, request: q, context: c, source: "Pulse 规则")
            p.notes = notes + p.notes
            return reply(for: p, context: c)
        }
    }

    static func clarifyText(_ form: AgentForm) -> String {
        switch form.id {
        case "plan-busy": "好的，我来帮你挪一下。选一下没空的日子；如果那几天还能抽出一点时间，也告诉我，我会改成精简版而不是挪走。"
        case "plan-pain": "先确认一下哪里不舒服，我会把相关的训练换成不给这个部位加负荷的方式。"
        case "plan-busy-past": "你提到的日子这周已经过去了。"
        case "plan-swap-days": "可以，选一下要换的日子。"
        case "plan-swap": "可以。选一下换成什么，以及哪几天换；强度会保持在可以说话的程度。"
        default: "可以。你想怎么调整？选一项，或者直接告诉我具体情况，比如「周三加班」「膝盖有点疼」。"
        }
    }

    static func reply(for p: PlanChangeProposal, context c: AgentContext) -> AgentReply {
        guard p.hasChanges else {
            let text = p.checks.first.map { "这次没有可以改动的地方：\($0)" }
                ?? "\(p.scope.label)剩下的日子里没有找到可以这样调整的训练。可以说得具体一点，比如「周三加班，挪到周四」。"
            return AgentReply(text: text, sources: ["\(p.scope.label)计划"], followUps: ["帮我调整下周计划", "这周三和周四没空"], destination: .plan)
        }
        // Pinned as the first sentence: the model must not present the change as made.
        let lead = "按你说的，\(p.scope.label)计划可以这样调整，点「采纳」后才会生效。"
        var parts = [lead]
        // Before and after for each day, so a model rewording this can't swap them round.
        parts.append(p.lines.map { "• \(Weekday.name($0.weekday))：原来是「\($0.before)」，改为「\($0.after)」" }.joined(separator: "\n"))
        parts.append(contentsOf: p.notes)
        if c.readiness.score != nil || c.load.ratio != nil {
            var basis: [String] = []
            if let s = c.readiness.score { basis.append("今天准备度 \(s)（\(c.readiness.level.label)）") }
            if let r = c.load.ratio { basis.append("训练负荷比 \(String(format: "%.2f", r))（\(c.load.zone.label)）") }
            parts.append("已结合\(basis.joined(separator: "、"))做了安全检查。")
        }
        return AgentReply(text: parts.joined(separator: "\n\n"), sources: ["\(p.scope.label)计划", "准备度", "训练负荷"],
                          followUps: p.scope == .thisWeek ? ["帮我调整下周计划", "今天适合运动吗？"] : ["今天适合运动吗？"],
                          destination: nil, blocks: [.plan(p)], conclusion: lead)
    }

    // MARK: Cloud model

    static let cloudInstructions = """
    你是 Pulse 应用中的 Health Agent，正在根据对话帮用户调整训练计划。长期目标是降低静息心率。
    要求：
    1. 结合用户的要求、之前的对话和数据（准备度、训练负荷、完成情况、健康状况），给出具体的修改。只能修改标注「可调整」的日子。
    2. 先用简体中文 1–3 句话说明怎么改、为什么（引用数据中的数字），不超过 150 字；不要逐日复述计划，修改会以卡片展示给用户确认。用户点「采纳」前计划没有改变，不要说「已改为」「已调整」，用「建议」「可以改为」。
    3. 然后输出 <plan>{"scope":"this_week 或 next_week","edits":[…]}</plan>。edits 只能使用：
       {"op":"move","from":"周三","to":"周四"}（两天的安排互换）
       {"op":"minutes","day":"周五","minutes":25}
       {"op":"intensity","day":"周五","intensity":"easy|moderate|hard"}
       {"op":"replace","day":"周六","kind":"aerobic|long|quality|strength|mobility|walk|rest","title":"低冲击有氧：骑行","minutes":30,"intensity":"easy","detail":"一句说明"}
    4. 信息不足以确定怎么改时（例如不知道哪天没空、哪里疼），不要猜：用一句话说明需要什么，并用 <ui> 输出一个 form 让用户补充，这时不输出 <plan>。
    5. 必须遵守约束：每周总训练时长最多比当前增加 10%；每周至少 1 天不训练；较高强度不排在相邻两天；准备度低时当天只安排低强度；有心血管情况且未经医生确认时不安排较高强度；疼痛时只降低强度或换成低冲击方式，并提醒疼痛持续时就医。App 会再做一次安全检查，超出约束的部分会被收回。
    6. 不建议开始、停止或调整任何药物和剂量。用户描述胸痛、呼吸困难、晕厥等紧急症状时，第一句建议立即拨打 120，不输出 <plan>。
    """

    static func cloudPrompt(question q: String, history: [String], context c: AgentContext, rulesHint: String) -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "zh_CN")
        df.dateFormat = "M/d"
        func week(_ scope: PlanScope) -> String {
            let (ws, items, generated) = slots(scope, context: c)
            let open = editable(items, weekStart: ws, now: c.now)
            let rows = Weekday.mondayFirst.map { wd -> String in
                let d = day(wd, ws)
                let list = items.filter { $0.day == d }
                let desc = list.isEmpty ? "无安排" : list.map { s in
                    "\(s.kind.rawValue)「\(s.title)」\(s.minutes) 分钟 \(s.intensity.rawValue)\(s.status == .planned ? "" : "（\(s.status.label)）")"
                }.joined(separator: " + ")
                return "\(Weekday.name(wd)) \(df.string(from: d))：\(desc)\(open.contains(wd) ? " ·可调整" : "")"
            }
            return "\(scope.label)计划\(generated ? "（尚未生成，以下按当前设置预排）" : "")：\n" + rows.joined(separator: "\n")
        }
        let p = c.profile
        var limits = ["每周训练目标 \(p.weeklyTargetMinutes) 分钟，单次可用约 \(p.sessionMinutes) 分钟", "活动水平：\(p.level.label)"]
        if let s = c.readiness.score { limits.append("今天准备度 \(s)（\(c.readiness.level.label)）") }
        limits.append("训练负荷：\(c.load.zone.label)\(c.load.ratio.map { "，负荷比 \(String(format: "%.2f", $0))" } ?? "")")
        if p.cardiacLimited { limits.append("有心血管情况，较高强度未经医生确认") }
        if let cap = p.hrCap { limits.append("照护计划心率上限 \(cap) bpm") }
        if p.hasDiabetes { limits.append("糖尿病\(p.hypoRiskMeds(at: c.now) ? "，使用有低血糖风险的药物" : "")") }
        if !p.limitations.isEmpty { limits.append("身体限制：\(p.limitations)") }
        if c.marathonActive, let r = c.race { limits.append("备赛：距比赛 \(r.weeksToRace) 周，\(r.phase.label)") }
        return """
        今天：\(df.string(from: c.now)) \(Weekday.name(c.now.weekday))

        用户数据摘要：
        \(HealthAgent.digest(c, anonymous: true))

        \(week(.thisWeek))

        \(week(.nextWeek))

        约束：\(limits.joined(separator: "；"))。
        \(history.isEmpty ? "" : "\n之前的对话：\n" + history.joined(separator: "\n") + "\n")
        用户的要求：\(q)

        本机规则的理解（供参考，可以做得更好）：\(rulesHint)
        """
    }

    /// What the rules engine made of the request, for the cloud prompt.
    static func rulesHint(_ q: String, context c: AgentContext) -> String {
        switch parse(q, context: c) {
        case .clarify(let f): "信息不足，需要问用户：\(f.title)"
        case .edits(let scope, let ops, _): ops.isEmpty ? "没有识别出具体修改（\(scope.label)）" : "\(scope.label)：" + ops.map(describe).joined(separator: "；")
        }
    }

    /// Reads the `<plan>` JSON from a model answer.
    static func ops(fromJSON json: String) -> (scope: PlanScope?, ops: [PlanEditOp]) {
        let cleaned = json.replacingOccurrences(of: "```json", with: "").replacingOccurrences(of: "```", with: "")
        guard let data = cleaned.data(using: .utf8),
              let d = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return (nil, []) }
        let scope = (d["scope"] as? String).flatMap(PlanScope.init(rawValue:))
        let edits = (d["edits"] as? [[String: Any]]) ?? []
        let ops: [PlanEditOp] = edits.prefix(10).compactMap { e in
            func wd(_ k: String) -> Int? { weekday(from: e[k]) }
            func num(_ k: String) -> Int? { (e[k] as? Int) ?? (e[k] as? Double).map(Int.init) ?? (e[k] as? String).flatMap(Int.init) }
            let level = (e["intensity"] as? String).flatMap(Intensity.init(rawValue:))
            switch e["op"] as? String {
            case "move": guard let a = wd("from"), let b = wd("to") else { return nil }; return .move(from: a, to: b)
            case "minutes": guard let a = wd("day"), let m = num("minutes") else { return nil }; return .minutes(day: a, minutes: m)
            case "intensity": guard let a = wd("day"), let l = level else { return nil }; return .intensity(day: a, l)
            case "replace":
                guard let a = wd("day"), let k = (e["kind"] as? String).flatMap(PlanKind.init(rawValue:)), k != .test else { return nil }
                return .replace(day: a, kind: k, title: (e["title"] as? String) ?? k.label, minutes: num("minutes"), intensity: level, detail: e["detail"] as? String)
            default: return nil
            }
        }
        return (scope, ops)
    }

    /// "周三" / "星期三" / "三" / 3 (Monday = 1) / "wed" → calendar weekday.
    static func weekday(from v: Any?) -> Int? {
        if let n = (v as? Int) ?? (v as? String).flatMap(Int.init), (1...7).contains(n) { return Weekday.mondayFirst[n - 1] }
        guard let s = (v as? String)?.lowercased() else { return nil }
        let cn: [Character: Int] = ["一": 2, "二": 3, "三": 4, "四": 5, "五": 6, "六": 7, "日": 1, "天": 1]
        if let c = s.last, let wd = cn[c] { return wd }
        let en = ["mon": 2, "tue": 3, "wed": 4, "thu": 5, "fri": 6, "sat": 7, "sun": 1]
        return en.first { s.hasPrefix($0.key) }?.value
    }
}
