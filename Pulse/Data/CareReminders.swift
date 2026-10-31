import Foundation
import SwiftData
import UserNotifications

/// 到期提醒: system notifications for 照护与随访 tasks with a due date — a week ahead for one that
/// needs booking (a lab recheck, a visit, an examination), and at 9 on the day (or at the time
/// given); a repeating task at each of its next times. Local only: nothing
/// leaves the phone. The schedule is rebuilt from the tasks whenever the app comes to the front or
/// goes to the background, so a ticked-off or moved task never rings.
enum CareReminders {
    static let enabledKey = "reminders.care"
    static let prefix = "pulse.care."
    static let hour = 9
    /// iOS keeps 64 pending notifications per app; leave room.
    static let limit = 48
    /// A repeating task: its next times, so reminders keep coming while the app stays closed (each
    /// time Pulse opens or runs in the background the schedule moves on).
    static let repeatsAhead = 7

    static var enabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }
    /// 异常提醒: events found by the background check (`BackgroundCheck`) are notified at once.
    static let eventsKey = "reminders.events"
    static var eventsEnabled: Bool { UserDefaults.standard.bool(forKey: eventsKey) }
    /// Not from tests, not in a demo running on a shifted clock (the dates would be off), and not from
    /// a throwaway in-memory run, which would replace the device's own reminders with its sample ones.
    static var schedulable: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil && !DemoClock.isShifted
            && !ProcessInfo.processInfo.arguments.contains("-PulseInMemory")
    }

    struct Task: Equatable {
        let id: String
        let title: String
        let note: String
        let due: Date?
        let done: Bool
        var repeats: CareRepeat? = nil
    }

    struct Planned: Equatable {
        let id: String
        let title: String
        let body: String
        let fire: Date
    }

    /// Tasks worth a word a week ahead: something to book.
    static func needsBooking(_ title: String) -> Bool {
        !LabRecheck.groups(inTitle: title).isEmpty || ["复诊", "复查", "检查", "预约", "随访", "就诊"].contains { title.contains($0) }
    }

    /// What to schedule for these tasks, soonest first; nothing in the past.
    static func plan(_ tasks: [Task], now: Date) -> [Planned] {
        let day = Date.FormatStyle().month().day().weekday(.abbreviated).locale(Locale(identifier: "zh_CN"))
        var out: [Planned] = []
        for t in tasks where !t.done {
            guard let at = t.due else { continue }
            let due = at.startOfDay
            // A time of day given in the chat (「晚上 9 点」) rings then; a date alone at 9 o'clock.
            let timed = at != due
            let note = t.note == "在对话里添加" ? "" : t.note
            if let r = t.repeats {
                // Missed times are not caught up: from the next one on.
                var next = at < now ? r.next(after: (timed ? now : now.startOfDay).addingTimeInterval(-1), at: at) : at
                var n = 0
                while n < repeatsAhead, next < now.adding(days: 35) {
                    let fire = timed ? next : next.startOfDay.adding(minutes: hour * 60)
                    if fire > now {
                        out.append(Planned(id: prefix + t.id + ".r\(Int(fire.timeIntervalSince1970))", title: (timed ? "" : "今天：") + t.title,
                                           body: note.isEmpty ? "完成后在 Pulse 的「照护与随访」里打个勾，会自动排到下一次。" : note, fire: fire))
                        n += 1
                    }
                    next = r.next(after: next, at: at)
                }
                continue
            }
            if needsBooking(t.title) {
                out.append(Planned(id: prefix + t.id + ".week", title: "下周：\(t.title)",
                                   body: "大约 \(due.formatted(day))。需要预约的话，现在约正好；日期以医生的安排为准。",
                                   fire: due.adding(days: -7).adding(minutes: hour * 60)))
            }
            out.append(Planned(id: prefix + t.id + ".day", title: (timed ? "" : "今天：") + t.title,
                               body: note.isEmpty ? "完成后在 Pulse 的「照护与随访」里打个勾。" : note,
                               fire: timed ? at : due.adding(minutes: hour * 60)))
        }
        return Array(out.filter { $0.fire > now }.sorted { $0.fire < $1.fire }.prefix(limit))
    }

    struct Event: Equatable {
        let id: String
        let title: String
        let detail: String
        let severity: Severity
    }

    /// New events worth a notification: those that call for the doctor, or for help now.
    static func notices(_ events: [Event]) -> [Planned] {
        events.filter { $0.severity >= .consult }.map { e in
            let first = e.detail.split(separator: "。").first.map { $0 + "。" } ?? ""
            return Planned(id: "pulse.event." + e.id, title: (e.severity == .urgent ? "请尽快处理：" : "") + e.title,
                           body: first + "打开 Pulse 看看该怎么做。", fire: Date())
        }
    }

    /// Shows these now (they are found in the background, so the user is not looking).
    static func notifyNow(_ planned: [Planned]) async {
        let center = UNUserNotificationCenter.current()
        for p in planned {
            let content = UNMutableNotificationContent()
            content.title = p.title
            content.body = p.body
            content.sound = .default
            try? await center.add(UNNotificationRequest(identifier: p.id, content: content, trigger: nil))
        }
    }

    /// Asks once; false when the user said no (then only the system Settings can turn it on).
    static func requestPermission() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    /// Replaces Pulse's pending reminders with the ones the tasks call for now (none when turned off).
    @MainActor static func sync(in ctx: ModelContext) {
        guard schedulable else { return }
        let tasks = ((try? ctx.fetch(FetchDescriptor<CareTask>())) ?? [])
            .map { Task(id: $0.id.uuidString, title: $0.title, note: $0.note, due: $0.due, done: $0.done, repeats: $0.repeats) }
        let planned = enabled ? plan(tasks, now: Date()) : []
        _Concurrency.Task {
            let center = UNUserNotificationCenter.current()
            let ours = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix(prefix) }
            center.removePendingNotificationRequests(withIdentifiers: ours)
            for p in planned {
                let content = UNMutableNotificationContent()
                content.title = p.title
                content.body = p.body
                content.sound = .default
                let when = Calendar.pulse.dateComponents([.year, .month, .day, .hour, .minute], from: p.fire)
                try? await center.add(UNNotificationRequest(identifier: p.id, content: content,
                                                            trigger: UNCalendarNotificationTrigger(dateMatching: when, repeats: false)))
            }
        }
    }
}
