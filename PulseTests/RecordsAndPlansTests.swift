import Foundation
import SwiftData
import Testing
import UserNotifications
@testable import Pulse

@Suite("Undoing records, outdated plan cards, reminders and voice")
@MainActor
struct RecordsAndPlansTests {
    private let wednesday = Calendar.pulse.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 20))!

    private func store() throws -> ModelContainer {
        try ModelContainer(for: Schema(PulseSchema.models), configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    private func events(_ ctx: ModelContext) -> [HealthEvent] { (try? ctx.fetch(FetchDescriptor<HealthEvent>())) ?? [] }

    private func load(at now: Date) throws -> (AgentContext, ModelContext, ModelContainer) {
        let container = try store()
        let ctx = container.mainContext
        DemoDataGenerator.populate(ctx, persona: .xiaolin, now: now)
        DataHub.ensureWeekPlan(in: ctx, now: now)
        let a = DataHub.analytics(in: ctx, now: now)
        let items = ((try? ctx.fetch(FetchDescriptor<PlanItem>())) ?? []).map(\.snapshot)
        let c = AgentContext.make(profile: a.profile, name: "晓林", days: a.days, plan: items, workouts: [], vitals: [], events: [], stopBang: [],
                                  baselineSetAt: nil, raceName: "", labs: [], now: now)
        return (c, ctx, container)
    }

    private func crisis(at time: Date) -> RecordProposal {
        RecordProposal(id: UUID(), items: [.bloodPressure(sys: 190, dia: 125, context: .random)], time: time)
    }

    // MARK: Undoing a record

    @Test func undoingAReadingTakesItsAlertAway() throws {
        let container = try store()
        let ctx = container.mainContext
        let undo = DataHub.applyRecord(crisis(at: .app), in: ctx)
        #expect(events(ctx).map(\.severity) == [.urgent])
        DataHub.undoRecord(undo, in: ctx)
        #expect(events(ctx).isEmpty, "a mistyped reading leaves no alert behind")
    }

    @Test func anEarlierReadingKeepsItsAlert() throws {
        let container = try store()
        let ctx = container.mainContext
        ctx.insert(VitalReading(time: .app, kind: .bloodPressure, value: 188, value2: 122))
        DataHub.refreshAlerts(in: ctx)
        #expect(events(ctx).count == 1)

        let undo = DataHub.applyRecord(crisis(at: .app), in: ctx)
        #expect(undo.events.isEmpty && undo.raised.isEmpty)
        DataHub.undoRecord(undo, in: ctx)
        #expect(events(ctx).count == 1, "the first reading still stands, and so does its alert")
    }

    @Test func undoingPutsAMilderAlertBack() throws {
        let container = try store()
        let ctx = container.mainContext
        let now = Date.app
        DataHub.addEvent(AlertCandidate(dedupeKey: "bpCrisis-\(AlertEngine.dayKey(now))", kind: .bpCrisis, severity: .verify, title: "原来的提醒",
                                        detail: "原来", guidance: "", relatedDate: now), in: ctx)
        let undo = DataHub.applyRecord(crisis(at: now), in: ctx)
        #expect(events(ctx).first?.severity == .urgent)
        DataHub.undoRecord(undo, in: ctx)
        let e = try #require(events(ctx).first)
        #expect(events(ctx).count == 1 && e.severity == .verify && e.title == "原来的提醒" && e.followUpDue == nil)
    }

    @Test func everyGlassOnACardIsTakenBack() throws {
        let container = try store()
        let ctx = container.mainContext
        let now = Date.app
        let undo = DataHub.applyRecord(RecordProposal(id: UUID(), items: [.water(ml: 250), .water(ml: 500)], time: now), in: ctx)
        #expect(DataHub.record(for: now, in: ctx).waterMl == 750)
        DataHub.undoRecord(undo, in: ctx)
        #expect(DataHub.record(for: now, in: ctx).waterMl == 0)
    }

    // MARK: Labs

    @Test func bothLabAlertsAreRaised() throws {
        let day = wednesday
        let found = LabAnalyzer.alerts(for: [LabPoint(date: day, kind: .potassium, value: 6.4), LabPoint(date: day, kind: .egfr, value: 12)],
                                       history: [], profile: ProfileSnapshot())
        #expect(found.map(\.severity) == [.urgent, .consult])
        #expect(found[1].title.contains("eGFR"))

        let container = try store()
        let ctx = container.mainContext
        let undo = DataHub.applyRecord(RecordProposal(id: UUID(), items: [.lab(.potassium, value: 6.4), .lab(.egfr, value: 12)], time: .app), in: ctx)
        #expect(events(ctx).count == 2)
        DataHub.undoRecord(undo, in: ctx)
        #expect(events(ctx).isEmpty)
    }

    // MARK: Plan cards

    private func trainingDay(_ items: [SessionSnapshot], _ ws: Date) throws -> Int {
        try #require(Weekday.mondayFirst.first { wd in items.contains { $0.day == PlanChat.day(wd, ws) && $0.kind.isTraining } })
    }

    @Test func aCardForAWeekThatNowExistsAddsNothing() throws {
        let (c, ctx, container) = try load(at: wednesday)
        _ = container
        let (ws, items, generated) = PlanChat.slots(.nextWeek, context: c)
        #expect(generated)
        let p = PlanChat.propose([.minutes(day: try trainingDay(items, ws), minutes: 20)], scope: .nextWeek, request: "下周少一点", context: c, source: "test")
        #expect(!DataHub.isOutdated(p, in: ctx))

        // The card waits in the chat; the week begins and gets its plan.
        DataHub.insertPlan(for: try #require(DataHub.profile(in: ctx)), weekStart: ws, fromDay: ws, in: ctx)
        let made = DataHub.planItems(weekStart: ws, in: ctx).count
        #expect(made > 0 && DataHub.isOutdated(p, in: ctx))
        DataHub.applyPlanChange(p, in: ctx)
        #expect(DataHub.planItems(weekStart: ws, in: ctx).count == made, "no second set of sessions")
    }

    @Test func aCardForSessionsThatAreGoneIsOutdated() throws {
        let monday = Calendar.pulse.date(from: DateComponents(year: 2026, month: 10, day: 19, hour: 8))!
        let (c, ctx, container) = try load(at: monday)
        _ = container
        let (ws, items, _) = PlanChat.slots(.thisWeek, context: c)
        let p = PlanChat.propose([.minutes(day: try trainingDay(items.filter { $0.day >= monday.startOfDay }, ws), minutes: 20)],
                                 scope: .thisWeek, request: "少一点", context: c, source: "test")
        #expect(p.hasChanges && !DataHub.isOutdated(p, in: ctx))
        DataHub.regenerateWeekPlan(in: ctx, now: monday)
        #expect(DataHub.isOutdated(p, in: ctx))
    }

    @Test func tomorrowCanBeNextWeek() throws {
        let sunday = Calendar.pulse.date(from: DateComponents(year: 2026, month: 10, day: 25, hour: 10))!
        let (c, _, container) = try load(at: sunday)
        _ = container
        if case .edits(.nextWeek, _, _) = PlanChat.parse("明天加班没空练", context: c) {} else { Issue.record("Monday is next week") }
        #expect(!HealthAgent.reply(to: "明天加班没空练", context: c).text.contains("已经过去"))
        let p = PlanChat.propose([], scope: .nextWeek, request: "明天加班没空练", context: c, source: "test")
        #expect(PlanChat.lead(for: p).hasPrefix("按你说的，下周计划"), "no 「这周剩下的日子」: tomorrow was asked about")
    }

    @Test func aDayNamedStaysThatDay() throws {
        let saturday = Calendar.pulse.date(from: DateComponents(year: 2026, month: 10, day: 24, hour: 9))!
        let (c, _, container) = try load(at: saturday)
        _ = container
        if case .edits(.thisWeek, _, _) = PlanChat.parse("明天加班没空练", context: c) {} else { Issue.record("Sunday is this week") }
        if case .edits(.nextWeek, _, _) = PlanChat.parse("后天加班没空练", context: c) {} else { Issue.record("Monday is next week") }
    }

    // MARK: Repeating reminders

    private func reminder(_ q: String) -> RecordProposal { ChatRecord.reminder(AgentQuestion(q), now: wednesday) }

    @Test func howOftenIsNotWhichDay() {
        #expect(reminder("每周三次提醒我量血压").repeats == .weekly([2, 4, 6]))
        #expect(reminder("每周三次提醒我量血压").reminder?.title == "量血压")
        #expect(reminder("每周两次提醒我量血压").repeats == .weekly([2, 5]))
        #expect(reminder("每周3次提醒我量血压").repeats == .weekly([2, 4, 6]))
        #expect(reminder("每星期四次提醒我量血压").repeats == .weekly([2, 3, 5, 7]))
        #expect(reminder("每周七次提醒我量血压").repeats == .daily)

        #expect(reminder("每周一次提醒我称体重").repeats == .weekly([wednesday.weekday]), "once a week: the day it was asked on")
        #expect(reminder("每周一次提醒我称体重").reminder?.title == "称体重")
        #expect(reminder("每个月一次提醒我复查").repeats == .monthly(21))
        #expect(reminder("每个月一次提醒我复查").reminder?.title == "复查")

        // Days stay days.
        #expect(reminder("每周三提醒我量血压").repeats == .weekly([4]))
        #expect(reminder("每周一和周四提醒我量血压").repeats == .weekly([2, 5]))
    }

    @Test func aReminderCarriesItsCalendar() throws {
        let fire = Calendar.pulse.date(bySettingHour: 9, minute: 30, second: 0, of: Date().adding(days: 3))!
        let when = CareReminders.when(fire)
        #expect(when.calendar?.identifier == .gregorian)
        #expect(UNCalendarNotificationTrigger(dateMatching: when, repeats: false).nextTriggerDate() == fire)
    }

    // MARK: Voice

    @Test func wordsArrivingAfterSendingAreDropped() {
        let speech = SpeechInput()
        speech.receive("今天", done: false, run: speech.run)
        #expect(speech.transcript == "今天")

        let sent = speech.run
        speech.discard()
        #expect(speech.transcript.isEmpty)
        speech.receive("今天适合跑步吗", done: true, run: sent)
        #expect(speech.transcript.isEmpty, "the question was sent: the input stays empty")
    }

    // MARK: Wording

    @Test func thePermissionTextNamesWhatTheAppCallsIt() throws {
        let text = try #require(Bundle.main.object(forInfoDictionaryKey: "NSHealthShareUsageDescription") as? String)
        #expect(text.contains("回答方式") && !text.contains("（测试）"))
    }
}
