import Foundation

// Adjusting the plan to the weather forecast. Outdoor sessions meet rain, storms, heat, cold and
// polluted air; the rules move a key session to a better day in the same week, swap the rest for
// an indoor alternative of the same length, ease intensity in the heat, or only add a note. The
// result is an ordinary plan-change proposal: the same safety checks, a before/after card, adopt
// and undo — nothing changes until the user adopts it.

struct DayWeather: Equatable, Identifiable {
    enum Sky: String, Equatable { case clear, cloudy, rain, heavyRain, thunder, snow }
    var id: Date { day }
    let day: Date
    let sky: Sky
    let high: Double
    let low: Double
    /// 0–1.
    let rainChance: Double
    /// Air quality index (China AQI), when known.
    var aqi: Int? = nil

    var icon: String {
        switch sky {
        case .clear: high >= 33 ? "sun.max.trianglebadge.exclamationmark" : "sun.max"
        case .cloudy: "cloud.sun"
        case .rain: "cloud.rain"
        case .heavyRain: "cloud.heavyrain"
        case .thunder: "cloud.bolt.rain"
        case .snow: "cloud.snow"
        }
    }
    var label: String {
        switch sky {
        case .clear: "晴"
        case .cloudy: "多云"
        case .rain: "小雨"
        case .heavyRain: "大雨"
        case .thunder: "雷阵雨"
        case .snow: "雪"
        }
    }

    enum Concern: Equatable { case wet, storm, heat, extremeHeat, cold, snow, air, badAir }
    /// What the day means for an outdoor session, worst first.
    var concerns: [Concern] {
        var out: [Concern] = []
        if sky == .thunder { out.append(.storm) }
        if sky == .heavyRain || (sky == .rain && rainChance >= 0.7) { out.append(.wet) }
        if sky == .snow || low <= -8 { out.append(.snow) }
        if high >= 35 { out.append(.extremeHeat) } else if high >= 32 { out.append(.heat) }
        if high <= 0 && sky != .snow { out.append(.cold) }
        if let a = aqi { if a > 150 { out.append(.badAir) } else if a > 100 { out.append(.air) } }
        return out
    }
    /// Too wet, stormy, hot, icy or polluted to train outdoors as planned.
    var movesIndoors: Bool { !concerns.filter { [.storm, .wet, .snow, .extremeHeat, .badAir].contains($0) }.isEmpty }
    var isGoodForOutdoors: Bool { concerns.isEmpty }
}

protocol WeatherSource {
    var name: String { get }
    /// The days from `from`, as far ahead as the source knows (7–10 days).
    func forecast(from: Date) async throws -> [DayWeather]
}

/// For the sample users: a week with a stormy day, a hot one and a polluted one, the same every time.
struct DemoWeather: WeatherSource {
    let name = "示例天气"
    func forecast(from: Date) async throws -> [DayWeather] { Self.days(from: from) }
    static func days(from: Date) -> [DayWeather] {
        let start = from.startOfDay
        let pattern: [(DayWeather.Sky, Double, Double, Double, Int)] = [
            (.clear, 33, 23, 0.0, 70), (.thunder, 22, 17, 0.9, 40), (.heavyRain, 20, 16, 0.85, 35),
            (.clear, 34, 24, 0.0, 88), (.clear, 27, 18, 0.05, 168), (.cloudy, 25, 17, 0.2, 75), (.clear, 26, 16, 0.0, 58),
            (.rain, 21, 15, 0.6, 50), (.cloudy, 23, 15, 0.2, 60), (.clear, 25, 15, 0.0, 55),
        ]
        return pattern.enumerated().map { i, d in
            DayWeather(day: start.adding(days: i), sky: d.0, high: d.1, low: d.2, rainChance: d.3, aqi: d.4)
        }
    }
}

enum WeatherPlanner {
    /// Sessions that are usually trained outdoors (a strength or mobility session is not).
    static func isOutdoor(_ s: SessionSnapshot) -> Bool {
        guard [.aerobic, .long, .quality, .walk, .test].contains(s.kind) else { return false }
        let indoor = ["室内", "跑步机", "动感单车", "椭圆机", "游泳", "健身房"]
        return !indoor.contains { s.title.contains($0) }
    }

    struct Advice: Equatable {
        /// Why each affected day changes or what to mind, by weekday.
        var notes: [String]
        var ops: [PlanEditOp]
        /// Days with weather worth knowing about, even when nothing changes.
        var affected: [Int]
    }

    /// Weather that keeps this person's session indoors: on a hot day too when sweating a lot is
    /// a risk for them (限水, 低血钾症…).
    static func movesIndoors(_ w: DayWeather, for p: ProfileSnapshot?) -> Bool {
        w.movesIndoors || (p?.heatSensitive == true && w.concerns.contains(.heat))
    }

    /// 「最高 33°C，限水期间不宜大量出汗」 for a hot day that moves a session indoors only for this person.
    static func reason(_ w: DayWeather, for p: ProfileSnapshot?) -> String {
        guard !w.movesIndoors, let p, p.heatSensitive, w.concerns.contains(.heat) else { return reason(w) }
        let causes = p.heatCauses.map { $0 == "限水" ? "限水期间" : $0 }.joined(separator: "、")
        return "最高 \(Int(w.high))°C，\(causes)不宜在高温下大量出汗"
    }

    /// What to do this week given the forecast: only sessions from today on, and only those planned.
    static func advice(plan: [SessionSnapshot], forecast: [DayWeather], now: Date, profile p: ProfileSnapshot? = nil) -> Advice {
        let today = now.startOfDay
        let ws = today.weekStart
        let week = plan.filter { $0.day >= today && $0.day < ws.adding(days: 7) && $0.status == .planned }
        let byDay = Dictionary(forecast.map { ($0.day.startOfDay, $0) }, uniquingKeysWith: { a, _ in a })
        var notes: [String] = [], ops: [PlanEditOp] = [], affected: [Int] = []
        var taken = Set(week.filter { $0.kind.isTraining }.map { $0.day.weekday })

        for s in week.sorted(by: { $0.day < $1.day }) where isOutdoor(s) {
            guard let w = byDay[s.day] else { continue }
            let wd = s.day.weekday, name = Weekday.name(wd), concerns = w.concerns
            guard !concerns.isEmpty else { continue }
            affected.append(wd)
            let why = reason(w, for: p)
            if movesIndoors(w, for: p) {
                // A key session (long or hard) is worth moving to a good day; the rest go indoors.
                let free = (1...6).map { s.day.adding(days: $0) }.filter { d in
                    d < ws.adding(days: 7) && !taken.contains(d.weekday) && (byDay[d]?.isGoodForOutdoors ?? false)
                        && !week.contains { $0.day == d.adding(days: -1) && $0.intensity == .hard }
                }
                if (s.isKey || s.kind == .long || s.intensity == .hard), let to = free.first {
                    ops.append(.move(from: wd, to: to.weekday))
                    taken.remove(wd); taken.insert(to.weekday)
                    notes.append("\(name)\(why)，「\(s.title)」建议挪到\(Weekday.name(to.weekday))（\(byDay[to]!.label) \(Int(byDay[to]!.high))°C）。")
                } else {
                    let (title, detail) = indoor(s, w)
                    ops.append(.replace(day: wd, kind: s.kind == .walk ? .aerobic : s.kind, title: title, minutes: s.minutes,
                                        intensity: concerns.contains(.extremeHeat) || concerns.contains(.heat) ? min(s.intensity, .moderate) : s.intensity,
                                        detail: detail, target: s.kind))
                    notes.append("\(name)\(why)，「\(s.title)」建议改为\(title)，时长不变。")
                }
            } else if concerns.contains(.heat) {
                if s.intensity == .hard { ops.append(.intensity(day: wd, .moderate)) }
                notes.append("\(name)最高 \(Int(w.high))°C，\(s.intensity == .hard ? "强度降一档，" : "")尽量在早上 7 点前或傍晚 7 点后练，带水，每 15–20 分钟喝几口。")
            } else if concerns.contains(.cold) {
                notes.append("\(name)最高 \(Int(w.high))°C，热身多做 5 分钟，穿可以随时脱的几层衣服。")
            } else if concerns.contains(.air) {
                if s.intensity == .hard { ops.append(.intensity(day: wd, .moderate)) }
                notes.append("\(name)空气质量一般（AQI \(w.aqi ?? 0)），户外\(s.intensity == .hard ? "强度降一档" : "练得轻松些")，避开车流多的路段。")
            } else if concerns.contains(.wet) || concerns.contains(.storm) {
                notes.append("\(name)\(why)，出门前看一眼雨情。")
            }
        }
        return Advice(notes: notes, ops: ops, affected: affected)
    }

    static func reason(_ w: DayWeather) -> String {
        let c = w.concerns
        if c.contains(.storm) { return "有雷阵雨" }
        if c.contains(.wet) { return "有\(w.label)（降水概率 \(Int(w.rainChance * 100))%）" }
        if c.contains(.snow) { return w.sky == .snow ? "有雪，路面可能结冰" : "最低 \(Int(w.low))°C，路面可能结冰" }
        if c.contains(.extremeHeat) { return "最高 \(Int(w.high))°C" }
        if c.contains(.badAir) { return "空气污染（AQI \(w.aqi ?? 0)）" }
        return w.label
    }

    /// What a session a plan change puts on this day will meet outdoors; nil when the weather is fine.
    static func note(forChanged s: SessionSnapshot, on w: DayWeather, profile p: ProfileSnapshot? = nil) -> String? {
        let c = w.concerns, name = Weekday.name(w.day.weekday), title = "改后的「\(s.title)」"
        if movesIndoors(w, for: p) { return "\(name)\(reason(w, for: p))，\(title)建议在\(c.contains(.heat) ? "有空调的" : "")室内完成，或换到天气好的一天。" }
        if c.contains(.heat) { return "\(name)最高 \(Int(w.high))°C，\(title)尽量放在早上 7 点前或傍晚 7 点后，带水。" }
        if c.contains(.cold) { return "\(name)最高 \(Int(w.high))°C，\(title)前多热身 5 分钟，穿可以随时脱的几层衣服。" }
        if c.contains(.air) { return "\(name)空气质量一般（AQI \(w.aqi ?? 0)），\(title)练得轻松些，避开车流多的路段。" }
        return nil
    }

    /// An indoor session of the same length and purpose.
    static func indoor(_ s: SessionSnapshot, _ w: DayWeather) -> (title: String, detail: String) {
        let air = w.concerns.contains(.badAir) ? "关好门窗，" : ""
        switch s.kind {
        case .quality: return ("室内间歇（跑步机或动感单车）", "\(air)按原计划的间歇结构在跑步机或动感单车上完成，热身和放松各 10 分钟。")
        case .long: return ("室内长时间有氧", "\(air)跑步机、椭圆机或动感单车，可以分两段完成，中间休息 5 分钟。")
        case .walk: return ("室内活动", "\(air)商场或室内健走、爬楼梯，或跟练一段有氧操。")
        default: return ("室内有氧（跑步机 / 动感单车 / 有氧操）", "\(air)强度和时长同原计划，能边运动边说话即可。")
        }
    }

    /// The proposal for this week, through the usual safety checks; nil when nothing needs to change.
    static func proposal(context c: AgentContext, forecast: [DayWeather], source: String) -> (PlanChangeProposal, Advice)? {
        let a = advice(plan: c.plan, forecast: forecast, now: c.now, profile: c.profile)
        guard !a.ops.isEmpty else { return nil }
        var p = PlanChat.propose(a.ops, scope: .thisWeek, request: "根据天气预报调整", context: c, source: source, checksWeather: false)
        p.notes = a.notes + p.notes
        return p.hasChanges ? (p, a) : nil
    }
}

/// Today's weather as a reminder for today's outdoor training.
struct WeatherReminder: Equatable {
    /// A word for the badge ("高温").
    let badge: String
    let icon: String
    /// One short line for a tile ("33°C · 早晚练、多喝水").
    let short: String
    /// The session would be better indoors (or moved), so the plan is worth a look.
    let changePlan: Bool
    /// The full sentence for the 运动 page.
    let line: String
}

extension WeatherPlanner {
    /// Nil when the weather is fine, or when no outdoor session is still to do today.
    static func reminder(today w: DayWeather?, sessions: [SessionSnapshot], profile p: ProfileSnapshot? = nil) -> WeatherReminder? {
        guard let w, let s = sessions.first(where: { $0.status == .planned && isOutdoor($0) }) else { return nil }
        let c = w.concerns, t = "\(Int(w.high))°C", title = "「\(s.title)」"
        if c.contains(.storm) {
            return .init(badge: "雷雨", icon: w.icon, short: "雷阵雨 · 改在室内练", changePlan: true,
                         line: "今天有雷阵雨，\(title)建议改在室内完成（跑步机、动感单车或有氧操），时长不变。")
        }
        if c.contains(.wet) {
            return .init(badge: "下雨", icon: w.icon, short: "\(w.label) · 改在室内练", changePlan: true,
                         line: "今天有\(w.label)（降水概率 \(Int(w.rainChance * 100))%），\(title)建议改在室内完成，时长不变。")
        }
        if c.contains(.snow) {
            return .init(badge: "路滑", icon: w.icon, short: "路面可能结冰 · 改在室内练", changePlan: true,
                         line: "今天\(w.sky == .snow ? "有雪" : "最低 \(Int(w.low))°C")，路面可能结冰，\(title)建议改在室内完成。")
        }
        if c.contains(.extremeHeat) {
            return .init(badge: "高温", icon: w.icon, short: "\(t) · 改在室内练", changePlan: true,
                         line: "今天最高 \(t)，户外容易中暑，\(title)建议改在有空调的室内，强度不超过中等。")
        }
        if c.contains(.badAir) {
            return .init(badge: "空气差", icon: "aqi.high", short: "AQI \(w.aqi ?? 0) · 改在室内练", changePlan: true,
                         line: "今天空气污染（AQI \(w.aqi ?? 0)），\(title)建议改在室内，关好门窗。")
        }
        if c.contains(.heat), let p, p.heatSensitive {
            return .init(badge: "高温", icon: w.icon, short: "\(t) · 改在室内练", changePlan: true,
                         line: "今天\(reason(w, for: p))，\(title)建议改在有空调的室内，强度不超过中等。")
        }
        if c.contains(.heat) {
            return .init(badge: "高温", icon: w.icon, short: "\(t) · 早晚练、多喝水", changePlan: false,
                         line: "今天最高 \(t)，\(title)尽量放在早上 7 点前或傍晚 7 点后，带水，每 15–20 分钟喝几口；觉得头晕、恶心就停下来。")
        }
        if c.contains(.cold) {
            return .init(badge: "低温", icon: w.icon, short: "\(t) · 多热身", changePlan: false,
                         line: "今天最高 \(t)，\(title)前多热身 5 分钟，穿可以随时脱的几层衣服。")
        }
        if c.contains(.air) {
            return .init(badge: "空气一般", icon: "aqi.medium", short: "AQI \(w.aqi ?? 0) · 练轻松些", changePlan: false,
                         line: "今天空气质量一般（AQI \(w.aqi ?? 0)），\(title)练得轻松些，避开车流多的路段。")
        }
        return nil
    }
}
