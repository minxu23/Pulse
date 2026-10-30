import Foundation
import SwiftData
import Testing
@testable import Pulse

private let evening = Calendar.pulse.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 20))!

@Suite("化验复查提醒")
@MainActor
struct LabRecheckTests {
    private func load(_ persona: DemoPersona) throws -> (ModelContainer, ModelContext) {
        let container = try ModelContainer(for: Schema(PulseSchema.models), configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        let ctx = container.mainContext
        DemoDataGenerator.populate(ctx, persona: persona, now: evening)
        return (container, ctx)
    }

    private func lab(_ kind: LabKind, _ value: Double, daysAgo: Int) -> LabPoint {
        LabPoint(date: evening.adding(days: -daysAgo), kind: kind, value: value)
    }

    @Test func kidneyChecksFollowKDIGORisk() {
        #expect(LabRecheck.kidneyMonths(egfr: 70, uacr: 10) == 12)
        #expect(LabRecheck.kidneyMonths(egfr: 70, uacr: 400) == 6, "G1–G2 with A3: twice a year")
        #expect(LabRecheck.kidneyMonths(egfr: 57, uacr: 45) == 6)
        #expect(LabRecheck.kidneyMonths(egfr: 35, uacr: 10) == 6)
        #expect(LabRecheck.kidneyMonths(egfr: 35, uacr: 100) == 4)
        #expect(LabRecheck.kidneyMonths(egfr: 50, uacr: 400) == 4)
        #expect(LabRecheck.kidneyMonths(egfr: 25, uacr: nil) == 3)
    }

    @Test func itemsComeFromResultsAndConditions() {
        var p = ProfileSnapshot()
        #expect(LabRecheck.items([lab(.egfr, 95, daysAgo: 30)], profile: p, now: evening).isEmpty, "nothing to recheck for healthy kidneys")
        p.conditions = [.ckd]
        let none = LabRecheck.items([], profile: p, now: evening)
        #expect(none.map(\.group) == [.kidney] && none[0].due == nil && none[0].status(now: evening) == .noRecord)
        let labs = [lab(.egfr, 57, daysAgo: 160), lab(.uacr, 45, daysAgo: 160), lab(.potassium, 5.4, daysAgo: 20)]
        let items = LabRecheck.items(labs, profile: p, now: evening)
        let kidney = items.first { $0.group == .kidney }!
        #expect(kidney.due == evening.adding(days: -160).adding(months: 6).startOfDay && kidney.status(now: evening) == .soon)
        #expect(kidney.tests.contains("血钾") && kidney.basis.contains("G3a"))
        let k = items.first { $0.group == .potassium }!
        #expect(k.due == evening.adding(days: 8).startOfDay && k.interval.contains("偏高"))
        p.conditions = []
        p.modules = [.diabetesCare]
        let a1c = LabRecheck.items([lab(.hba1c, 6.6, daysAgo: 170)], profile: p, now: evening).first!
        #expect(a1c.group == .hba1c && a1c.interval.contains("6 个月") && a1c.status(now: evening) == .soon)
        #expect(LabRecheck.items([lab(.hba1c, 8.1, daysAgo: 100)], profile: p, now: evening).first?.status(now: evening) == .overdue,
                "not at target: every 3 months")
    }

    @Test func tasksAppearAMonthAheadAndANewResultTicksThemOff() {
        var p = ProfileSnapshot()
        p.conditions = [.ckd]
        let labs = [lab(.egfr, 57, daysAgo: 160), lab(.uacr, 45, daysAgo: 160), lab(.potassium, 5.4, daysAgo: 20)]
        let items = LabRecheck.items(labs, profile: p, now: evening)
        let fresh = LabRecheck.plan(items: items, tasks: [], labs: labs, now: evening)
        #expect(Set(fresh.add.map(\.group)) == [.kidney, .potassium] && fresh.complete.isEmpty)
        // 复盘's 「复查肾功能和血钾」 already covers both.
        let review = LabRecheck.Task(title: "复查肾功能和血钾", createdAt: evening.adding(days: -5), done: false, due: evening.adding(days: 9))
        #expect(LabRecheck.plan(items: items, tasks: [review], labs: labs, now: evening).add.isEmpty)
        // Ticked off by the user this round: not added again.
        let ticked = LabRecheck.Task(title: "复查血钾", createdAt: evening.adding(days: -10), done: true, due: evening)
        #expect(!LabRecheck.plan(items: items, tasks: [ticked], labs: labs, now: evening).add.contains { $0.group == .potassium })
        // A result after the task appeared answers it.
        let newer = labs + [lab(.potassium, 4.6, daysAgo: 1)]
        let after = LabRecheck.plan(items: LabRecheck.items(newer, profile: p, now: evening), tasks: [review], labs: newer, now: evening)
        #expect(after.complete == [0])
        // The task added for a result is not answered by that same result (no tick-off-and-add-again).
        let k = [lab(.potassium, 5.6, daysAgo: 0)]
        let kItems = LabRecheck.items(k, profile: p, now: evening)
        let added = LabRecheck.Task(title: "复查血钾", createdAt: evening.adding(minutes: 5), done: false,
                                    due: kItems.first { $0.group == .potassium }?.due)
        let again = LabRecheck.plan(items: kItems, tasks: [added], labs: k, now: evening)
        #expect(again.complete.isEmpty && again.add.isEmpty)
        // A task that was due before the latest result (added long ago, or on the doctor's date) is answered by it.
        let stale = LabRecheck.Task(title: "糖化血红蛋白（HbA1c）检测", createdAt: evening, done: false, due: evening.adding(days: -9))
        #expect(LabRecheck.plan(items: [], tasks: [stale], labs: [lab(.hba1c, 7.4, daysAgo: 3)], now: evening).complete == [0])
        // Due in more than a month: no task yet.
        let early = [lab(.egfr, 57, daysAgo: 30)]
        #expect(LabRecheck.plan(items: LabRecheck.items(early, profile: p, now: evening), tasks: [], labs: early, now: evening).add.isEmpty)
    }

    @Test func theSampleKidneyPatientIsReminded() throws {
        let (container, ctx) = try load(.wangjianguo)
        _ = container
        let p = DataHub.analytics(in: ctx, now: evening).profile
        let labs = ((try? ctx.fetch(FetchDescriptor<LabResult>())) ?? []).map(\.point)
        let due = LabRecheck.items(labs, profile: p, now: evening).filter { [.overdue, .soon].contains($0.status(now: evening)) }
        let tasks = { (try? ctx.fetch(FetchDescriptor<CareTask>())) ?? [] }
        for item in due {
            #expect(tasks().contains { !$0.done && LabRecheck.groups(inTitle: $0.title).contains(item.group) }, "\(item.title) is a task")
        }
        // Syncing again adds nothing, and does not tick off what was just added.
        let count = tasks().count, open = tasks().filter { !$0.done }.count
        DataHub.syncLabRechecks(in: ctx, profile: p, now: evening)
        #expect(tasks().count == count && tasks().filter { !$0.done }.count == open)
        // A new result for each due recheck ticks its task off.
        for item in due {
            let (kind, normal): (LabKind, Double) = switch item.group {
            case .kidney: (.egfr, 90)
            case .potassium: (.potassium, 4.5)
            case .hba1c: (.hba1c, 6.5)
            case .uricAcid: (.uricAcid, 300)
            }
            ctx.insert(LabResult(date: evening.adding(minutes: 60), kind: kind, value: normal))
        }
        DataHub.syncLabRechecks(in: ctx, profile: p, now: evening.adding(days: 1))
        for item in due {
            #expect(!tasks().contains { !$0.done && LabRecheck.groups(inTitle: $0.title).contains(item.group) }, "\(item.title) is done")
        }
    }

    @Test func theAgentUsesTheSameSchedule() throws {
        let (container, ctx) = try load(.wangjianguo)
        _ = container
        let a = DataHub.analytics(in: ctx, now: evening)
        let labs = ((try? ctx.fetch(FetchDescriptor<LabResult>())) ?? []).map(\.point)
        let c = AgentContext.make(profile: a.profile, name: "王建国", days: a.days, plan: [], workouts: [], vitals: [], events: [],
                                  stopBang: [], baselineSetAt: nil, raceName: "", labs: labs, now: evening)
        let r = HealthAgent.reply(to: "我该多久去复查一次", context: c)
        for item in LabRecheck.items(labs, profile: a.profile, now: evening) {
            #expect(r.text.contains(item.interval), "\(item.name) in the answer")
        }
        if let soon = LabRecheck.items(labs, profile: a.profile, now: evening).first(where: { [.overdue, .soon].contains($0.status(now: evening)) }) {
            #expect(HealthAgent.assess(c).nextSteps.contains { $0.title.hasPrefix("预约复查") && $0.destination == .labs }, "\(soon.title) in next steps")
        }
    }
}
