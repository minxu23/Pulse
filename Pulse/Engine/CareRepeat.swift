import Foundation

/// How a 照护与随访 task repeats: 「每天晚上 9 点吃药」「每周一、四称体重」「每月 5 号复查」. The task keeps
/// its next time as its due date; ticking it off moves it on to the time after (`CareTask.complete`).
enum CareRepeat: Equatable {
    case daily
    /// Calendar weekdays (Sunday = 1), Monday first.
    case weekly([Int])
    /// Day of the month; a short month uses its last day.
    case monthly(Int)

    var raw: String {
        switch self {
        case .daily: "daily"
        case .weekly(let w): "weekly:" + w.map(String.init).joined(separator: ",")
        case .monthly(let d): "monthly:\(d)"
        }
    }

    init?(raw: String) {
        let parts = raw.split(separator: ":", maxSplits: 1).map(String.init)
        switch parts.first {
        case "daily": self = .daily
        case "weekly":
            let w = (parts.count > 1 ? parts[1] : "").split(separator: ",").compactMap { Int($0) }.filter { (1...7).contains($0) }
            guard !w.isEmpty else { return nil }
            self = .weekly(Weekday.mondayFirst.filter(w.contains))
        case "monthly":
            guard parts.count > 1, let d = Int(parts[1]), (1...31).contains(d) else { return nil }
            self = .monthly(d)
        default: return nil
        }
    }

    /// 「每天」「每周一、四」「每月 5 号」.
    var label: String {
        switch self {
        case .daily: return "每天"
        case .weekly(let w):
            let short: [Int: String] = [2: "一", 3: "二", 4: "三", 5: "四", 6: "五", 7: "六", 1: "日"]
            return "每周" + w.compactMap { short[$0] }.joined(separator: "、")
        case .monthly(let d): return "每月 \(d) 号"
        }
    }

    func matches(_ day: Date) -> Bool {
        switch self {
        case .daily: return true
        case .weekly(let w): return w.contains(day.weekday)
        case .monthly(let d):
            let cal = Calendar.pulse
            let last = cal.range(of: .day, in: .month, for: day)?.count ?? 31
            return cal.component(.day, from: day) == min(d, last)
        }
    }

    /// The first time at `minutes` past midnight (midnight for a task without a time) that is not
    /// before `now` — for a task without a time, today counts all day.
    func first(onOrAfter now: Date, minutes: Int?) -> Date {
        let m = minutes ?? 0
        for i in 0..<400 {
            let day = now.startOfDay.adding(days: i)
            let at = day.adding(minutes: m)
            if matches(day), minutes == nil || at >= now { return at }
        }
        return now.startOfDay.adding(minutes: m)
    }

    /// The time after `date`, at the same time of day as `time`.
    func next(after date: Date, at time: Date) -> Date {
        let m = time.minutesOfDay
        for i in 0..<400 {
            let day = date.startOfDay.adding(days: i)
            let at = day.adding(minutes: m)
            if matches(day), at > date { return at }
        }
        return date.adding(days: 1)
    }

    /// The time before `date`, at the same time of day (to take a tick back).
    func previous(before date: Date) -> Date {
        let m = date.minutesOfDay
        for i in 1..<400 {
            let day = date.startOfDay.adding(days: -i)
            if matches(day) { return day.adding(minutes: m) }
        }
        return date.adding(days: -1)
    }
}
