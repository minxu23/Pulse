import Foundation

// Shift work (倒班). For someone on a rotating roster the calendar date is a poor "day": after a
// night shift they sleep from mid-morning to the afternoon. Pulse instead divides days at the main
// sleep: a day starts when the person wakes and ends when they go to their main sleep. Everything
// that says "today" — the 今日 page, the agent, 复盘 — follows that window.

enum ShiftKind: String, CaseIterable, Codable, Identifiable {
    case day, night, off
    var id: String { rawValue }
    var label: String {
        switch self {
        case .day: "白班"
        case .night: "夜班"
        case .off: "休息"
        }
    }
    var short: String {
        switch self {
        case .day: "白"
        case .night: "夜"
        case .off: "休"
        }
    }
    var icon: String {
        switch self {
        case .day: "sun.max.fill"
        case .night: "moon.stars.fill"
        case .off: "house.fill"
        }
    }
}

/// A repeating roster and the shift times.
struct ShiftSchedule: Equatable {
    var pattern: [ShiftKind]
    /// The date that is day 1 of the pattern.
    var cycleStart: Date
    var dayStart = 8 * 60
    var dayEnd = 17 * 60
    var nightStart = 20 * 60
    var nightEnd = 8 * 60

    func kind(on date: Date) -> ShiftKind {
        guard !pattern.isEmpty else { return .off }
        let n = date.startOfDay.daysSince(cycleStart.startOfDay)
        return pattern[((n % pattern.count) + pattern.count) % pattern.count]
    }

    static let presets: [(name: String, pattern: [ShiftKind])] = [
        ("两白两夜两休", [.day, .day, .night, .night, .off, .off]),
        ("白夜休休", [.day, .night, .off, .off]),
        ("三夜三休", [.night, .night, .night, .off, .off, .off]),
        ("两白一夜两休", [.day, .day, .night, .off, .off]),
        ("做五休二（只上白班）", [.day, .day, .day, .day, .day, .off, .off]),
    ]
}

/// One day as the person lives it: from waking to the start of the main sleep.
struct DayWindow: Equatable {
    var day: Date
    /// nil without a roster.
    var kind: ShiftKind?
    var previous: ShiftKind?
    var wake: Date
    var bed: Date
    var nextWake: Date
    /// Until this moment it is still the previous day (5 am on a regular schedule).
    var rollover: Date
    /// A recommended nap before the first night shift, if any.
    var nap: DateInterval?

    /// The main sleep that ended this day's morning was a daytime sleep after a night shift.
    var afterNightShift: Bool { previous == .night }
}

extension Date {
    /// The clock time `minutes` after this day's midnight (past 24 h → the next day), set through the
    /// calendar so it stays right on days when the clocks change.
    func atClock(_ minutes: Int) -> Date {
        let days = Int((Double(minutes) / 1440).rounded(.down))
        let m = minutes - days * 1440
        return Calendar.pulse.date(bySettingHour: m / 60, minute: m % 60, second: 0, of: startOfDay.adding(days: days)) ?? adding(minutes: minutes)
    }
}

extension DayClock {
    /// The waking window for a day under the user's schedule (regular hours without a roster).
    static func window(for date: Date, profile p: ProfileSnapshot?) -> DayWindow {
        let d = date.startOfDay
        let wakeM = p?.wakeMinutes ?? 7 * 60
        let bedM = p?.bedtimeMinutes ?? 23 * 60
        let bedOffset = bedM < 12 * 60 ? bedM + 1440 : bedM
        guard let s = p?.shift, !s.pattern.isEmpty else {
            return DayWindow(day: d, kind: nil, previous: nil, wake: d.atClock(wakeM), bed: d.atClock(bedOffset),
                             nextWake: d.adding(days: 1).atClock(wakeM), rollover: d.atClock(rolloverHour * 60), nap: nil)
        }
        let need = Int(p?.sleepNeedMinutes ?? 450)
        func wake(_ day: Date) -> Date {
            let k = s.kind(on: day), prev = s.kind(on: day.adding(days: -1))
            let afterShift = day.atClock(s.nightEnd + 60)
            if prev == .night {
                // Another night ahead: a full daytime sleep. Otherwise a short recovery sleep, then back to nights off.
                return afterShift.adding(minutes: k == .night ? need : 240)
            }
            if k == .day { return day.atClock(min(wakeM, s.dayStart - 90)) }
            return day.atClock(wakeM)
        }
        let k = s.kind(on: d), next = s.kind(on: d.adding(days: 1))
        let bed: Date
        if k == .night {
            bed = d.adding(days: 1).atClock(s.nightEnd + 60)
        } else if next == .day {
            // Early enough to sleep `need` before getting up for the day shift.
            let latest = d.adding(days: 1).atClock(s.dayStart - 90).adding(minutes: -need)
            bed = min(d.atClock(bedOffset), latest)
        } else {
            bed = d.atClock(bedOffset)
        }
        let w = wake(d)
        // Before the first night of a run: a nap of about 90 minutes before leaving for work.
        let nap: DateInterval? = k == .night && s.kind(on: d.adding(days: -1)) != .night
            ? DateInterval(start: d.atClock(s.nightStart - 240), duration: 90 * 60) : nil
        return DayWindow(day: d, kind: k, previous: s.kind(on: d.adding(days: -1)), wake: w, bed: bed,
                         nextWake: wake(d.adding(days: 1)), rollover: w.addingTimeInterval(-2 * 3600), nap: nap)
    }

    /// The boundary between the previous day and `date` (5 am, or two hours before waking on a roster).
    static func rollover(on date: Date, profile p: ProfileSnapshot?) -> Date {
        window(for: date, profile: p).rollover
    }
}
