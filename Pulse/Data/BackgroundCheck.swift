import Foundation
import SwiftData
import BackgroundTasks

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

    @MainActor static func run(_ container: ModelContainer) async {
        schedule()
        let ctx = container.mainContext
        if CareReminders.eventsEnabled, let p = DataHub.profile(in: ctx), p.onboardingDone {
            let new = await newEvents(in: ctx) {
                // Health data can only be read while the phone is unlocked; otherwise this check uses what is already here.
                if p.useHealthKit { await HealthKitService.shared.sync(into: ctx, days: 3) }
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

    /// The events `check` added or made more serious. The Health sync itself stores events, so what
    /// was there is noted before it starts.
    @MainActor static func newEvents(in ctx: ModelContext, during check: @MainActor () async -> Void) async -> [HealthEvent] {
        func stored() -> [HealthEvent] { (try? ctx.fetch(FetchDescriptor<HealthEvent>())) ?? [] }
        let before = Dictionary(stored().map { ($0.id, $0.severity) }, uniquingKeysWith: max)
        await check()
        return stored().filter { e in before[e.id].map { e.severity > $0 } ?? true }
    }
}
