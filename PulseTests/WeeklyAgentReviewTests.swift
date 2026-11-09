import Foundation
import Testing
@testable import Pulse

@Suite("Personal Health Agent 周复盘")
@MainActor
struct WeeklyAgentReviewTests {
    private let now = Calendar.pulse.date(from: DateComponents(year: 2026, month: 11, day: 8, hour: 20))!

    private func context() -> AgentContext {
        var p = ProfileSnapshot()
        p.age = 45; p.sex = .male; p.conditions = [.hypertension]; p.goals = [.lowerRHR]
        let days = (0..<42).map { i in
            var d = DayData(day: now.startOfDay.adding(days: i - 41))
            d.rhr = 70; d.steps = 5000; d.sleepMinutes = 390
            return d
        }
        return AgentContext.make(profile: p, name: "不能发给模型的称呼", days: days, plan: [], workouts: [], vitals: [],
                                 events: [], stopBang: [], baselineSetAt: nil, raceName: "", now: now)
    }

    private func target() -> ProgramWeekReport {
        ProgramWeekReport(week: 2, weeks: 4, checks: [], excused: false,
                          target: TargetReading(target: .homeBP, value: 138, value2: 86, count: 14),
                          change: -2, beyondNoise: false, targetLine: "", next: "")
    }

    private func facts(recording: Bool = false, sample: Bool = false, notes: ReviewNotes? = nil,
                       proposals: [CoachProposal] = [], plan: NextWeekPlan? = nil) -> ReviewFacts {
        let c = WeeklyAgentReview.scoped(context(), weekStart: now.weekStart, recording: recording)
        let w = ReviewCoach.week(days: c.days, plan: c.plan, weekStart: now.weekStart, span: 7, source: nil, now: now)
        let previous = ReviewCoach.week(days: c.days, plan: c.plan, weekStart: now.weekStart.adding(days: -7), span: 7, source: nil, now: now)
        let brief = ReviewCoach.brief(current: w, previous: previous, context: c, isCurrentWeek: true,
                                      nextTarget: (90, "保持"))
        return WeeklyAgentReview.facts(context: c, brief: brief, week: w, weekLabel: "11月2日—8日", current: true,
                                       recording: recording, sample: sample, target: target(), goal: TargetGoal(target: .homeBP, baseline: 140, goal: 133),
                                       proposals: proposals, plan: plan, priorities: WeeklyAgentReview.priorities([], target: .homeBP), notes: notes)
    }

    @Test func interpretationLeadsWithTheTargetAndAcknowledgesNoise() {
        let f = facts()
        #expect(f.fallback.summary.contains("血压 · 7 日均值为 138/86"))
        #expect(f.fallback.summary.contains("还不能判断有稳定改善"))
        #expect(f.text.contains("45 岁") && f.text.contains("高血压") && f.text.contains("目标 133"))
        #expect(!f.text.contains("不能发给模型的称呼"))
    }

    @Test func aMissingMeasurementDoesNotTurnIntoAnImprovement() {
        var r = target(); r.target.value = nil; r.target.value2 = nil
        let text = WeeklyAgentReview.targetSummary(r, goal: TargetGoal(target: .homeBP, baseline: 140, goal: 133))
        #expect(text.contains("读数还不够") && !text.contains("已经改善"))
        r.target.value = 133
        #expect(WeeklyAgentReview.targetSummary(r, goal: TargetGoal(target: .homeBP, baseline: 140, goal: 133)).contains("单次达标不代表整轮已经完成"))
    }

    @Test func currentTargetMovesItsConcernToTheFront() {
        let priorities = [ReviewPriority(area: .sleep, reason: "睡眠少", mine: true), ReviewPriority(area: .rhr, reason: "旧目标", mine: false)]
        let result = WeeklyAgentReview.priorities(priorities, target: .homeBP)
        #expect(result.map(\.area) == [.bloodPressure, .sleep, .rhr])
        #expect(WeeklyAgentReview.priorities(result, target: .homeBP).count == result.count)
    }

    @Test func feedbackAndDataModeChangeTheGenerationCache() {
        let first = facts()
        #expect(first.key == facts().key)
        #expect(first.key != facts(notes: ReviewNotes(change: "周末加班，没能训练")).key)
        #expect(first.key != facts(sample: true).key)
        #expect(facts(notes: ReviewNotes(change: "周末加班，没能训练")).text.contains("周末加班"))
    }

    @Test func anOlderWeekCannotUseLaterRecordsAndAssociations() {
        var c = context()
        let ws = now.weekStart.adding(days: -14)
        let first = WeeklyAgentReview.scoped(c, weekStart: ws, recording: false)
        var future = DayData(day: now.startOfDay)
        future.rhr = 150; future.steps = 99999
        c.days.append(future)
        c.vitals.append(VitalPoint(time: now, kind: .bloodPressure, value: 200, value2: 120, context: .morning))
        c.openEvents.append(AgentEvent(title: "后来的异常", severity: .urgent, date: now, guidance: ""))
        let second = WeeklyAgentReview.scoped(c, weekStart: ws, recording: false)
        #expect(first.days == second.days && first.associations == second.associations)
        #expect(second.vitals.isEmpty && second.openEvents.isEmpty)
        #expect(second.now < ws.adding(days: 7))
    }

    @Test func recordingOnlyDoesNotAcquireTrainingGoalsOrActions() {
        let drop = CoachProposal(id: "drop", icon: "", title: "减少训练", rationale: "少排一天", action: .dropWeekday(7), adoptLabel: "采用")
        let task = CoachProposal(id: "care", icon: "", title: "复测血压", rationale: "先补充读数", action: .addTask(title: "复测血压", area: .cardio, inDays: 2), adoptLabel: "记下")
        let c = WeeklyAgentReview.scoped(context(), weekStart: now.weekStart, recording: true)
        #expect(c.plan.isEmpty && c.profile.goals.isEmpty && c.profile.program == nil)
        let f = facts(recording: true, proposals: [drop, task])
        #expect(f.fallback.items == [task.rationale])
        #expect(!f.text.contains("【主靶点】") && !f.text.contains("【下周已拟安排】"))
        #expect(!f.fallback.summary.contains("下周我们先") && !f.fallback.summary.contains("训练目标"))
    }

    @Test func observationsAreAssociationsRatherThanDiagnosedCauses() {
        var c = context()
        c.associations = [Association(id: "alcohol-rhr", factor: "饮酒", icon: "", metric: "静息心率", unit: "bpm",
                                      withMean: 75, withoutMean: 68, nWith: 10, nWithout: 12, effect: 1, higherIsWorse: true)]
        let w = ReviewCoach.week(days: c.days, plan: [], weekStart: now.weekStart, span: 7, source: nil, now: now)
        let brief = ReviewCoach.brief(current: w, previous: w, context: c, isCurrentWeek: true, nextTarget: (90, ""))
        let f = WeeklyAgentReview.facts(context: c, brief: brief, week: w, weekLabel: "本周", current: true,
                                       recording: false, sample: false, target: target(), goal: TargetGoal(target: .homeBP, baseline: 140, goal: 133),
                                       proposals: [], plan: nil, priorities: [], notes: nil)
        #expect(f.text.contains("【个人关联】饮酒") && f.text.contains("不能据此确定变化原因"))
    }

    @Test func aModelCannotTurnAnObservationIntoACertainCause() {
        let proposal = CoachProposal(id: "sleep", icon: "", title: "记录睡眠", rationale: "先把睡眠记录完整，再看变化是否持续。", action: .addTask(title: "记录睡眠", area: .sleep, inDays: 2), adoptLabel: "记下")
        let f = facts(proposals: [proposal])
        let copy = ReviewCopy(headline: "", summary: f.fallback.summary, items: ["因为你工作忙，所以血压没有改善。"])
        #expect(copy.checked(against: f).copy.items == f.fallback.items)
    }

    @Test func identifiersInTheWeeklyFeedbackAreMaskedBeforeCloudGeneration() {
        var f = facts(notes: ReviewNotes(change: "我是张小明，联系方式 demo@example.com"))
        f.knownNames = ["张小明"]
        let outgoing = ReviewWriter.cloudPrompt(for: f)
        #expect(!outgoing.text.contains("张小明") && !outgoing.text.contains("demo@example.com"))
        #expect(outgoing.text.contains("[邮箱") && outgoing.mask.restore(outgoing.text).contains("demo@example.com"))
        #expect(outgoing.text.contains("目标 133"), "health facts stay usable after identity filtering")
    }

    @Test func modelGenerationIsCachedAndCanBeRegeneratedWithoutNetwork() async {
        let suite = "weekly-writer.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var calls = 0
        let writer = ReviewWriter(defaults: defaults) { f in
            calls += 1
            return (ReviewCopy(headline: "不可替换规则结论", summary: "血压仍需继续观察，先把记录保持完整。", items: f.fallback.items), "测试模型")
        }
        let f = facts()
        await writer.write(f); await writer.write(f)
        #expect(calls == 1 && writer.copy(for: f).summary.contains("继续观察"))
        #expect(writer.copy(for: f).headline == f.fallback.headline)
        let reopened = ReviewWriter(defaults: defaults) { f in
            calls += 1; return (f.fallback, "不应调用")
        }
        await reopened.write(f)
        #expect(calls == 1 && reopened.copy(for: f) == writer.copy(for: f))
        await writer.rewrite(f)
        #expect(calls == 2)
    }

    @Test func noModelIsExplicitAndStillHasTheLocalInterpretation() async {
        let suite = "weekly-offline.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let writer = ReviewWriter(defaults: defaults) { _ in throw ReviewWriter.WriterError.noModel("测试环境未提供模型") }
        let f = facts()
        await writer.write(f)
        guard case .rules(let reason)? = writer.state(for: f) else { Issue.record("must label the fallback"); return }
        #expect(reason.contains("测试环境未提供模型") && writer.copy(for: f) == f.fallback)
    }

    @Test func inventedNumbersAndMedicationAdviceDoNotAppearAsGeneratedReview() async {
        let suite = "weekly-validation.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let writer = ReviewWriter(defaults: defaults) { _ in
            (ReviewCopy(headline: "", summary: "你的血压已经降到 99，可以把降压药减半。", items: []), "测试模型")
        }
        let f = facts()
        await writer.write(f)
        #expect(writer.copy(for: f).summary == f.fallback.summary)
    }
}
