import Foundation
import SwiftData
import Testing
@testable import Pulse

private let day = Calendar.pulse.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 20))!

@Suite("Review priorities and the daily review")
@MainActor
struct ReviewPriorityTests {
    private func load(_ persona: DemoPersona) throws -> (AgentContext, ModelContext, ModelContainer) {
        let container = try ModelContainer(for: Schema(PulseSchema.models), configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        let ctx = container.mainContext
        DemoDataGenerator.populate(ctx, persona: persona, now: day)
        DataHub.ensureWeekPlan(in: ctx, now: day)
        let a = DataHub.analytics(in: ctx, now: day)
        let p = DataHub.profile(in: ctx)!
        let items = (try? ctx.fetch(FetchDescriptor<PlanItem>())) ?? []
        let vitals = ((try? ctx.fetch(FetchDescriptor<VitalReading>())) ?? []).map(\.point)
        let labs = ((try? ctx.fetch(FetchDescriptor<LabResult>())) ?? []).map(\.point)
        let c = AgentContext.make(profile: a.profile, name: p.displayName, days: a.days, plan: items.map(\.snapshot), workouts: [],
                                  vitals: vitals.filter { $0.time > day.adding(days: -60) }, events: [], stopBang: [], baselineSetAt: nil,
                                  raceName: p.raceName, labs: labs, now: day)
        return (c, ctx, container)
    }

    @Test func prioritiesFollowConditionsGoalsAndData() throws {
        let (w, _, c1) = try load(.wangjianguo)
        _ = c1
        let pr = ReviewPriorities.ranked(w)
        #expect(Set(pr.prefix(3).map(\.area)) == [.bloodPressure, .glucose, .kidney], "\(pr.map(\.area))")
        #expect(pr.allSatisfy { !$0.mine && !$0.reason.isEmpty })
        #expect(pr.first { $0.area == .kidney }?.reason == "你记录了慢性肾病")

        let (x, _, c2) = try load(.xiaolin)
        _ = c2
        let px = ReviewPriorities.ranked(x)
        #expect(px.prefix(2).contains { $0.area == .rhr } && !px.contains { $0.area == .kidney })

        // The user's own order comes first; Pulse points out what their data says is missing.
        let mine: [PriorityArea] = [.sleep, .stress, .activity]
        let own = ReviewPriorities.ranked(w, mine: mine)
        #expect(own.prefix(3).map(\.area) == mine && own.prefix(3).allSatisfy(\.mine))
        let hint = try #require(ReviewPriorities.suggestion(w, mine: mine))
        #expect(!mine.contains(hint.area))
        #expect(ReviewPriorities.suggestion(w, mine: []) == nil)
    }

    @Test func theWeeklyReviewLeadsWithThePriorities() throws {
        let (c, ctx, container) = try load(.wangjianguo)
        _ = container
        let pr = ReviewPriorities.ranked(c)
        let top = pr.prefix(3).map(\.area)
        // Suggestions for the priorities that the general rules do not make, e.g. a kidney recheck.
        let titles = ((try? ctx.fetch(FetchDescriptor<CareTask>())) ?? []).filter { !$0.done }.map(\.title)
        let extra = ReviewPriorities.proposals(c, priorities: pr, taskTitles: titles)
        // The potassium recheck is already a 照护与随访 task (化验复查提醒), so it is not offered again…
        #expect(titles.contains { LabRecheck.groups(inTitle: $0).contains(.potassium) } && !extra.contains { $0.id == "task-kidney" })
        // …and without that task, it is.
        let others = titles.filter { LabRecheck.groups(inTitle: $0).isEmpty }
        #expect(ReviewPriorities.proposals(c, priorities: pr, taskTitles: others).contains { $0.id == "task-kidney" && $0.rationale.contains("血钾 5.4") })
        let ranked = ReviewCoach.proposals(context: c, handledInsights: [], taskTitles: titles, priorities: pr)
        #expect(ranked.count <= 3 && !ranked.isEmpty)
        let ranks = ranked.map { p in ReviewPriorities.area(of: p).flatMap { pr.map(\.area).firstIndex(of: $0) } ?? pr.count }
        #expect(ranks == ranks.sorted(), "\(ranked.map(\.id))")
        #expect(ReviewPriorities.area(of: ranked[0]).map(top.contains) == true)

        // The numbers: the priorities' own first.
        let ws = c.weekStart, span = c.logicalToday.daysSince(ws) + 1
        let cur = ReviewCoach.week(days: c.days, plan: c.plan, weekStart: ws, span: span, source: c.trend.dominantSource, now: c.logicalToday)
        let prev = ReviewCoach.week(days: c.days, plan: c.plan, weekStart: ws.adding(days: -7), span: span, source: c.trend.dominantSource, now: c.logicalToday)
        let brief = ReviewCoach.brief(current: cur, previous: prev, context: c, isCurrentWeek: true, nextTarget: (75, ""), priorities: pr)
        #expect(brief.metrics.count == 6)
        #expect(brief.metrics.prefix(3).map(\.name) == top.compactMap(\.metricName), "\(brief.metrics.map(\.name))")
        // Without priorities the review is as before.
        #expect(ReviewCoach.brief(current: cur, previous: prev, context: c, isCurrentWeek: true, nextTarget: (75, "")).metrics.first?.name == "静息心率")
        // The model is told what to lead with; the reflection offers the top priority first.
        let facts = ReviewCoach.weeklyFacts(brief: brief, weekLabel: "本周", isCurrentWeek: true, proposals: ranked, plan: nil, priorities: pr)
        #expect(facts.text.contains("【优先事项】用户最在意：\(top.map(\.label).joined(separator: "、"))"))
        let focus = ReviewCoach.reflection(context: c, week: cur, priorities: pr).first { $0.id == "focus" }
        #expect(focus?.options.first == top[0].focusOption)
    }

    @Test func aDayIsReadAgainstThePriorities() throws {
        let (c, _, container) = try load(.wangjianguo)
        _ = container
        let pr = ReviewPriorities.ranked(c)
        let today = c.days.first { $0.day == c.logicalToday } ?? DayData(day: c.logicalToday)
        let lines = ReviewPriorities.day(today, context: c, priorities: pr)
        #expect(lines.map(\.area) == pr.map(\.area))
        #expect(lines.first { $0.area == .kidney }.map { !$0.text.isEmpty } == true)
        #expect(lines.first { $0.area == .glucose }?.text.contains("mmol/L") == true)
        let headline = ReviewPriorities.dayHeadline(lines, isToday: true)
        #expect(headline.hasPrefix("今天"))
        // A day with nothing recorded says so instead of judging it.
        let empty = DayData(day: c.logicalToday.adding(days: -200))
        let quiet = ReviewPriorities.day(empty, context: c, priorities: pr)
        #expect(quiet.allSatisfy { $0.tone == .neutral })
        #expect(ReviewPriorities.dayHeadline(quiet, isToday: false).contains("记录还不多"))
    }

    @Test func calendarDaysGetALevel() throws {
        func l(_ a: PriorityArea, _ t: DayLine.Tone) -> DayLine { DayLine(area: a, tone: t, text: a.label) }
        let calm = [l(.bloodPressure, .good), l(.glucose, .good), l(.kidney, .neutral), l(.sleep, .neutral)]
        #expect(ReviewPriorities.level(lines: calm, readiness: nil) == .smooth)
        #expect(ReviewPriorities.level(lines: [l(.bloodPressure, .good), l(.glucose, .neutral), l(.kidney, .neutral)], readiness: nil) == .steady)
        #expect(ReviewPriorities.level(lines: [l(.bloodPressure, .attention), l(.glucose, .good), l(.kidney, .good)], readiness: nil) == .mixed)
        #expect(ReviewPriorities.level(lines: [l(.bloodPressure, .attention), l(.glucose, .attention), l(.kidney, .good)], readiness: nil) == .watch)
        // Below the top three it takes two to matter.
        #expect(ReviewPriorities.level(lines: calm + [l(.weight, .attention)], readiness: nil) == .steady)
        #expect(ReviewPriorities.level(lines: calm + [l(.weight, .attention), l(.stress, .attention)], readiness: nil) == .mixed)
        // Against the person's own usual level: a standing problem weighs less than a worse day.
        func u(_ a: PriorityArea, _ usual: DayLine.Usual) -> DayLine { DayLine(area: a, tone: .attention, text: a.label, usual: usual) }
        #expect(ReviewPriorities.level(lines: [u(.bloodPressure, .same), u(.glucose, .same), l(.kidney, .good)], readiness: nil) == .mixed)
        #expect(ReviewPriorities.level(lines: [u(.bloodPressure, .worse), u(.glucose, .same), l(.kidney, .good)], readiness: nil) == .watch)
        #expect(ReviewPriorities.level(lines: [u(.bloodPressure, .same), l(.glucose, .good), l(.kidney, .good)], readiness: nil) == .steady)
        #expect(ReviewPriorities.level(lines: [u(.bloodPressure, .better), u(.glucose, .same), l(.kidney, .good)], readiness: nil) == .steady)
        #expect(ReviewPriorities.dayHeadline([u(.bloodPressure, .same), u(.glucose, .same), l(.kidney, .good)], isToday: false)
                == "这天血压、血糖和你平时差不多，仍高于目标")
        #expect(ReviewPriorities.dayHeadline([u(.bloodPressure, .worse), u(.glucose, .same), l(.kidney, .good)], isToday: true)
                == "今天需要留意：血压；血糖和平时差不多")
        // Nothing recorded: no level rather than a guess.
        #expect(ReviewPriorities.level(lines: [l(.bloodPressure, .neutral)], readiness: nil) == nil)
        #expect(ReviewPriorities.monthSummary([.smooth, .smooth, nil, .watch]) == "这个月 3 天有记录：顺利 2 天，需留意 1 天")
        #expect(ReviewPriorities.monthSummary([nil]) == "这个月还没有记录")

        let (c, _, container) = try load(.wangjianguo)
        _ = container
        let pr = ReviewPriorities.ranked(c)
        let month = (0..<14).map { c.logicalToday.adding(days: -$0) }.map { ReviewPriorities.verdict(on: $0, context: c, priorities: pr) }
        #expect(month.allSatisfy { $0.lines.count == pr.count })
        #expect(month.compactMap(\.level).count >= 10)
        #expect(Set(month.compactMap(\.level)).count >= 2, "a poorly controlled month is not all one colour")
        // Blood pressure and glucose above target most days: compared with his own usual level, at
        // most half are 需留意 — days worse than usual, far off target, or a week-long run's one reminder.
        let levels = month.compactMap(\.level)
        #expect(levels.filter { $0 == .watch }.count * 2 <= levels.count, "\(levels)")
        #expect(month.contains { $0.lines.contains { $0.text.contains("值得带着记录和医生谈谈") } }, "his glucose has been under 70% for a week")
        #expect(month.contains { $0.lines.contains { $0.usual == .same && $0.text.contains("和你平时差不多") } })
        // The page names what made a day need attention.
        if let w = month.first(where: { $0.level == .watch && $0.readiness?.level != .rest }) { #expect(w.flagged.count >= 2) }
    }

    /// Someone whose blood pressure or glucose has long been off target: their usual level is no
    /// excuse when it is far off, and a run of days off target is said once, with the doctor.
    @Test func aStandingProblemIsNotTakenAsUsual() {
        var p = ProfileSnapshot()
        p.conditions = [.hypertension]
        let today = day.startOfDay
        func context(_ vitals: [VitalPoint]) -> AgentContext {
            AgentContext.make(profile: p, name: "", days: [], plan: [], workouts: [], vitals: vitals, events: [], stopBang: [],
                              baselineSetAt: nil, raceName: "", labs: [], now: day)
        }
        func bp(_ sys: Double, _ dia: Double, days: Int) -> [VitalPoint] {
            (0..<days).map { VitalPoint(time: today.adding(days: -$0).adding(minutes: 450), kind: .bloodPressure, value: sys, value2: dia, context: .morning) }
        }
        func line(_ a: PriorityArea, _ c: AgentContext, daysAgo i: Int = 0) -> DayLine {
            ReviewPriorities.line(for: a, DayData(day: today.adding(days: -i)), c)!
        }
        let calm = [DayLine(area: .glucose, tone: .good, text: ""), DayLine(area: .kidney, tone: .good, text: "")]

        // Far above the line every day: not 「和你平时差不多」-and-平稳, however usual it is.
        let severe = line(.bloodPressure, context(bp(152, 96, days: 30)))
        #expect(severe.usual == .worse && severe.text.contains("明显高于 135/85") && severe.text.contains("最近量的 30 天都是这样"), "\(severe.text)")
        #expect(ReviewPriorities.level(lines: [severe] + calm, readiness: nil) == .mixed)

        // Just above it, day after day: said once, on the 7th measured day in a row, with the doctor…
        let crept = context(bp(138, 86, days: 20))
        let sixth = line(.bloodPressure, crept, daysAgo: 14), seventh = line(.bloodPressure, crept, daysAgo: 13)
        #expect(sixth.usual == .same && sixth.text.hasSuffix("和你平时差不多"), "\(sixth.text)")
        #expect(seventh.usual == .worse && seventh.text.contains("最近量的 7 天都是这样，值得带着记录和医生谈谈"), "\(seventh.text)")
        #expect(ReviewPriorities.level(lines: [seventh] + calm, readiness: nil) == .mixed)
        // …then each day says how long it has gone on, instead of 「和你平时差不多」.
        let later = line(.bloodPressure, crept)
        #expect(later.usual == .same && later.text.hasSuffix("最近量的 20 天都是这样") && !later.text.contains("医生"), "\(later.text)")
        #expect(later.standing && !sixth.standing)
        #expect(ReviewPriorities.dayHeadline([later, DayLine(area: .glucose, tone: .attention, text: "", usual: .same)], isToday: true)
                == "今天血压连续多天没达标，血糖和平时差不多")
        // A day back in range starts the count again.
        let broken = context(bp(138, 86, days: 20).filter { $0.time.startOfDay != today.adding(days: -3) }
                             + [VitalPoint(time: today.adding(days: -3).adding(minutes: 450), kind: .bloodPressure, value: 126, value2: 80, context: .morning)])
        #expect(line(.bloodPressure, broken).text.hasSuffix("和你平时差不多"))
        // Another run within four weeks is not reminded again.
        let again = context(bp(138, 86, days: 30).filter { $0.time.startOfDay != today.adding(days: -9) }
                            + [VitalPoint(time: today.adding(days: -9).adding(minutes: 450), kind: .bloodPressure, value: 126, value2: 80, context: .morning)])
        let second = line(.bloodPressure, again, daysAgo: 2)
        #expect(second.text.hasSuffix("最近量的 7 天都是这样") && second.usual == .same, "\(second.text)")
        // A diastolic higher than usual says so (not 「比你平时高 -3」).
        let dia = context(bp(138, 80, days: 10).filter { $0.time.startOfDay != today } + bp(135, 86, days: 1))
        #expect(line(.bloodPressure, dia).text.hasSuffix("舒张压比你平时高 6"), "\(line(.bloodPressure, dia).text)")

        // CGM: under half the day in range is never "usual" either.
        var cgm: [VitalPoint] = []
        for d in 0..<10 {
            for k in 0..<48 { cgm.append(VitalPoint(time: today.adding(days: -d).adding(minutes: 30 * k), kind: .glucose, value: k < 19 ? 6.0 : 12.0, context: .random)) }
        }
        let g = line(.glucose, context(cgm))
        #expect(g.usual == .worse && g.text.contains("范围内只有 39%") && g.text.contains("最近有记录的 10 天都是这样"), "\(g.text)")
    }
}
