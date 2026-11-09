import Foundation
import SwiftData
import BackgroundTasks
import UIKit

/// 异常提醒 in the background: iOS wakes Pulse now and then (it decides when, usually every few
/// hours), Pulse reads what came in through Apple Health, runs the same alert rules as when the app
/// is open, and notifies any new event that calls for the doctor or for help now. Best effort, never
/// a replacement for calling for help.
enum BackgroundCheck {
    static let id = "com.pulse.restingheart.refresh"

    /// Asks iOS for the next run, a few hours from now; only while 异常提醒 or 到期提醒 is on (a run
    /// also moves repeating reminders on, for a phone where Pulse stays closed).
    static func schedule() {
        guard CareReminders.eventsEnabled || CareReminders.enabled, CareReminders.schedulable else { return }
        let r = BGAppRefreshTaskRequest(identifier: id)
        r.earliestBeginDate = Date().addingTimeInterval(3 * 3600)
        try? BGTaskScheduler.shared.submit(r)
    }

    /// On your own records only: Health is never read into a sample user's data.
    @MainActor static func runOwn() async { await run(DataStores.shared.ownContainer()) }

    @MainActor static func run(_ container: ModelContainer) async {
        schedule()
        let ctx = container.mainContext
        if CareReminders.eventsEnabled, let p = DataHub.profile(in: ctx), p.onboardingDone {
            let new = await newEvents(in: ctx) {
                // Health data can only be read while the phone is unlocked; otherwise this check uses what is already here.
                if p.useHealthKit { await readInBackground(ctx, newReading: false) }
                DataHub.refreshAlerts(in: ctx)
                try? ctx.save()
            }
            await CareReminders.notifyNow(CareReminders.notices(new.map {
                CareReminders.Event(id: $0.id.uuidString, title: $0.title, detail: $0.detail, severity: $0.severity)
            }))
        }
        // Awaited: iOS suspends Pulse as soon as this run returns.
        await CareReminders.syncNow(in: ctx)
    }

    /// A new reading in Apple Health (HealthKit wakes Pulse for blood pressure, glucose, weight and VO2max):
    /// it is read into your own records at once and, with 异常提醒 on and Pulse not on screen, an event that
    /// calls for the doctor is notified. Health can't be read while the phone is locked; then the next check
    /// or opening Pulse reads it.
    @MainActor static func readingsArrived() async {
        let ctx = DataStores.shared.ownContainer().mainContext
        guard let p = DataHub.profile(in: ctx), p.onboardingDone, p.useHealthKit else { return }
        let new = await newEvents(in: ctx) {
            await readInBackground(ctx, newReading: true)
            DataHub.refreshAlerts(in: ctx)
            try? ctx.save()
        }
        // On screen, 今日 shows it.
        guard CareReminders.eventsEnabled, UIApplication.shared.applicationState != .active else { return }
        await CareReminders.notifyNow(CareReminders.notices(new.map {
            CareReminders.Event(id: $0.id.uuidString, title: $0.title, detail: $0.detail, severity: $0.severity)
        }))
    }

    // MARK: The last read in the background (数据来源)

    /// When Pulse last read Apple Health while not on screen, what woke it, and whether the read got
    /// through (Health can't be read while the phone is locked).
    struct BackgroundRead: Equatable {
        var date: Date
        var ok: Bool
        /// A new reading woke Pulse; otherwise the check iOS runs every few hours.
        var newReading: Bool
    }

    private static let readKey = "health.backgroundRead"

    static var lastRead: BackgroundRead? {
        guard let d = UserDefaults.standard.dictionary(forKey: readKey), let t = d["date"] as? Double else { return nil }
        return BackgroundRead(date: Date(timeIntervalSince1970: t), ok: d["ok"] as? Bool ?? false, newReading: d["new"] as? Bool ?? false)
    }

    static func note(_ r: BackgroundRead) {
        UserDefaults.standard.set(["date": r.date.timeIntervalSince1970, "ok": r.ok, "new": r.newReading], forKey: readKey)
    }

    /// The last 3 days from Apple Health; off screen, the attempt is noted for 数据来源.
    @MainActor static func readInBackground(_ ctx: ModelContext, newReading: Bool) async {
        let before = DataHub.profile(in: ctx)?.lastSync
        await HealthKitService.shared.sync(into: ctx, days: 3)
        guard UIApplication.shared.applicationState != .active else { return }
        let after = DataHub.profile(in: ctx)?.lastSync
        note(BackgroundRead(date: Date(), ok: after != nil && after != before, newReading: newReading))
    }

    /// The events `check` added or made more serious. The Health sync itself stores events, so what
    /// was there is noted before it starts.
    @MainActor static func newEvents(in ctx: ModelContext, during check: @MainActor () async -> Void) async -> [HealthEvent] {
        func stored() -> [HealthEvent] { (try? ctx.fetch(FetchDescriptor<HealthEvent>())) ?? [] }
        let before = Dictionary(stored().map { ($0.id, $0.severity) }, uniquingKeysWith: max)
        await check()
        return stored().filter { e in before[e.id].map { e.severity > $0 } ?? true }
    }
}
