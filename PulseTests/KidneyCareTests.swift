import Foundation
import Testing
@testable import Pulse

private let now = Calendar.pulse.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 20))!

@Suite("Kidney care: swelling, painkillers, dialysis")
@MainActor
struct KidneyCareTests {
    private func ckd() -> ProfileSnapshot {
        var p = ProfileSnapshot()
        p.conditions = [.ckd]
        return p
    }

    private func day(_ daysAgo: Int, edema: Edema? = nil, urine: UrineAmount? = nil, foamy: Bool? = nil) -> DayData {
        var d = DayData(day: now.startOfDay.adding(days: -daysAgo))
        d.edema = edema?.rawValue
        d.urineOutput = urine?.rawValue
        d.foamyUrine = foamy
        return d
    }

    private func weight(_ daysAgo: Int, _ kg: Double, hour: Int = 7) -> VitalPoint {
        VitalPoint(time: now.startOfDay.adding(days: -daysAgo).adding(minutes: hour * 60), kind: .weight, value: kg, context: .morning)
    }

    @Test func swellingAndUrineAreRecordedAndRaised() {
        let p = ckd()
        #expect(KidneySigns.relevant(p) && !KidneySigns.relevant(ProfileSnapshot()))
        #expect(QuickLogKind.menu(for: p).contains(.kidneySigns) && !QuickLogKind.menu(for: ProfileSnapshot()).contains(.kidneySigns))
        var today = day(0, edema: .marked, urine: .less, foamy: true)
        today.edemaPlaces = ["脚踝", "小腿"]
        #expect(KidneySigns.lines(today).map(\.text) == ["水肿明显（脚踝、小腿）", "尿量比平时少", "泡沫尿"])
        #expect(KidneySigns.lines(today).filter { $0.tone == .attention }.count == 2)

        // One day of marked swelling is recorded, not raised; two days are.
        #expect(KidneySigns.alert([today], vitals: [], profile: p, now: now) == nil)
        let two = KidneySigns.alert([day(1, edema: .marked), today], vitals: [], profile: p, now: now)
        #expect(two?.severity == .consult && two?.detail.contains("明显水肿 2 天") == true && two?.guidance.contains("肾内科医生") == true)
        // One day, with weight up 2 kg in 3 days, is enough.
        let gain = KidneySigns.alert([today], vitals: [weight(3, 70), weight(0, 72.3)], profile: p, now: now)
        #expect(gain?.detail.contains("体重涨了 2.3 kg") == true)
        // Less urine two days running; not on dialysis, where it is expected.
        #expect(KidneySigns.alert([day(1, urine: .less), day(0, urine: .less)], vitals: [], profile: p, now: now)?.title == "尿量变少")
        var dialysis = p
        dialysis.onDialysis = true
        dialysis.dialysisWeekdays = [2, 4, 6]
        #expect(KidneySigns.alert([day(1, urine: .less), day(0, urine: .less)], vitals: [], profile: dialysis, now: now) == nil)
        // Nobody else is asked.
        #expect(KidneySigns.alert([day(1, edema: .marked), today], vitals: [], profile: ProfileSnapshot(), now: now) == nil)

        let s = KidneySigns.summary([day(0, edema: .mild, foamy: true), day(3, edema: .marked), day(5, urine: .usual), day(20, edema: .marked)], now: now)
        #expect(s?.text == "近 14 天记了 3 天：水肿 2 天（明显 1 天），泡沫尿 1 天", "\(s?.text ?? "")")
        // The daily review's 肾脏 line leads with it.
        let c = AgentContext.make(profile: p, name: "", days: [today], plan: [], workouts: [], vitals: [], events: [], stopBang: [],
                                  baselineSetAt: nil, raceName: "", now: now)
        let line = ReviewPriorities.line(for: .kidney, today, c)
        #expect(line?.tone == .attention && line?.text.hasPrefix("水肿明显") == true && line?.usual == .worse)
    }

    @Test func painkillersAreFlaggedForKidneys() {
        #expect(KidneyMeds.isNSAID("芬必得缓释胶囊") && KidneyMeds.isNSAID("Ibuprofen 200mg") && KidneyMeds.isNSAID("双氯芬酸钠凝胶"))
        #expect(!KidneyMeds.isNSAID("阿司匹林肠溶片") && !KidneyMeds.isNSAID("氨氯地平"))
        #expect(KidneyMeds.atRisk(ckd()) && !KidneyMeds.atRisk(ProfileSnapshot()))
        #expect(KidneyMeds.atRisk(ProfileSnapshot(), labs: [LabPoint(date: now, kind: .egfr, value: 52)]))

        func ask(_ q: String, _ p: ProfileSnapshot) -> AgentReply {
            let c = AgentContext.make(profile: p, name: "", days: [], plan: [], workouts: [], vitals: [], events: [], stopBang: [],
                                      baselineSetAt: nil, raceName: "", now: now)
            return HealthAgent.reply(to: q, context: c)
        }
        let kidney = ask("我能吃布洛芬吗", ckd())
        #expect(kidney.text.hasPrefix("布洛芬这类止痛消炎药（NSAIDs）可能让肾功能变差") && kidney.text.contains("肾内科医生或药师"), "\(kidney.text)")
        #expect(ask("头疼吃点止痛药行吗", ckd()).text.hasPrefix("先别自己吃布洛芬这类止痛药"), "the question asked is answered first")
        #expect(ask("我能吃布洛芬吗", ProfileSnapshot()).text.hasPrefix(KidneyMeds.general))
        #expect(ask("膝盖疼怎么办", ckd()).text.contains("布洛芬这类药可能伤肾"))
    }

    @Test func dialysisKeepsTrainingOffSessionsAndWatchesTheGain() {
        var p = ckd()
        p.onDialysis = true
        p.dialysisWeekdays = [2, 4, 6]
        p.fluidLimited = true
        #expect(Dialysis.schedule(p) == "周一、三、五")
        // 2026-10-21 is a Wednesday.
        #expect(Dialysis.isDay(now, p) && !Dialysis.isDay(now.adding(days: 1), p))
        #expect(Dialysis.next(from: now.adding(days: 1), p) == now.startOfDay.adding(days: 2))

        // Against the dry weight: 4% is worth a word.
        p.dryWeightKg = 60
        let ok = Dialysis.gain([weight(1, 61.8)], profile: p, now: now)
        #expect(ok.map { abs($0.kg - 1.8) < 0.01 && abs(($0.percent ?? 0) - 3) < 0.01 } == true && !Dialysis.tooMuch(ok!))
        #expect(Dialysis.alert([weight(1, 61.8)], profile: p, now: now) == nil)
        let high = Dialysis.alert([weight(0, 62.6)], profile: p, now: now)
        #expect(high?.title == "两次透析之间体重涨了 2.6 kg" && high?.detail.contains("干体重的 4%") == true, "\(high?.detail ?? "")")
        // Without a dry weight: against the lowest weight on the last dialysis day (after the session).
        p.dryWeightKg = nil
        let monday = 2
        let lastSession = (1...6).first { now.adding(days: -$0).weekday == monday }!
        let g = Dialysis.gain([weight(lastSession, 63.5, hour: 7), weight(lastSession, 61.0, hour: 13), weight(0, 64.2)], profile: p, now: now)
        #expect(g?.against == "上次透析后 61.0 kg" && g.map { abs($0.kg - 3.2) < 0.01 } == true && Dialysis.tooMuch(g!))
        // The 3-day weight rule is for other people: gaining between sessions is expected.
        #expect(AlertEngine.weightAlert([weight(3, 60), weight(0, 62.5)], profile: p, now: now) == nil)

        // No training on session days.
        let c = AgentContext.make(profile: p, name: "", days: [], plan: [], workouts: [], vitals: [], events: [], stopBang: [],
                                  baselineSetAt: nil, raceName: "", now: now.startOfDay.adding(minutes: 9 * 60))
        let r = TrainingCheck.reply("今天能跑间歇吗", context: c)
        #expect(r.text.hasPrefix("不建议") && r.text.contains("透析日"), "\(r.text)")

        // The profile keeps training off dialysis days, and dialysis means a fluid limit.
        let u = UserProfile()
        u.conditions = [.ckd]
        u.availableWeekdays = [2, 3, 5, 6]
        u.dialysis = true
        u.dialysisWeekdays = [2, 4, 6]
        let s = u.snapshot(medications: [])
        #expect(s.availableWeekdays == [3, 5] && s.fluidLimited && s.watchesWeight && s.onDialysis)
        // Every usual training day a session day: training moves to the days in between.
        u.availableWeekdays = [2, 4, 6]
        #expect(u.snapshot(medications: []).availableWeekdays == [3, 5, 7])
        u.availableWeekdays = [2, 3, 5, 6]
        u.dialysis = false
        #expect(u.snapshot(medications: []).availableWeekdays == [2, 3, 5, 6])
    }

    @Test func peritonealDialysisWatchesForInfectionNotSessions() {
        let u = UserProfile()
        u.conditions = [.ckd]
        u.availableWeekdays = [2, 3, 5, 6]
        u.dialysis = true
        u.dialysisWeekdays = [2, 4, 6]
        u.dryWeightKg = 60
        u.dialysisModeRaw = DialysisMode.peritoneal.rawValue
        let p = u.snapshot(medications: [])
        // Every day at home: no session days, no dry-weight rule; the usual weight and urine rules apply.
        #expect(p.onPeritoneal && !p.onHemodialysis && p.fluidLimited && p.availableWeekdays == [2, 3, 5, 6])
        #expect(!Dialysis.isDay(now, p) && Dialysis.gain([weight(0, 63)], profile: p, now: now) == nil)
        #expect(AlertEngine.weightAlert([weight(3, 60), weight(0, 62.5)], profile: p, now: now) != nil)
        #expect(KidneySigns.alert([day(1, urine: .less), day(0, urine: .less)], vitals: [], profile: p, now: now)?.guidance.contains("腹透中心") == true)

        // Cloudy effluent, belly pain or fever: urgent, ahead of anything else.
        var cloudy = day(0, edema: .marked)
        cloudy.pdSigns = ["透出液浑浊", "肚子疼"]
        let a = KidneySigns.alert([day(1, edema: .marked), cloudy], vitals: [], profile: p, now: now)
        #expect(a?.severity == .urgent && a?.title == "腹透可能有感染" && a?.guidance.contains("透出液带上") == true)
        #expect(KidneySigns.lines(cloudy).contains { $0.tone == .attention && $0.text == "腹透：透出液浑浊、肚子疼" })
        var exit = day(0)
        exit.pdSigns = ["导管出口红肿、有分泌物"]
        #expect(KidneySigns.alert([exit], vitals: [], profile: p, now: now)?.severity == .consult)

        // Exercise: nothing that presses on the belly; heavy lifting is out.
        let c = AgentContext.make(profile: p, name: "", days: [], plan: [], workouts: [], vitals: [], events: [], stopBang: [],
                                  baselineSetAt: nil, raceName: "", now: now.startOfDay.adding(minutes: 9 * 60))
        #expect(TrainingCheck.reply("今天能做大重量深蹲吗", context: c).text.contains("腹膜透析"))
        #expect(Dialysis.digest([], profile: p, now: now)?.hasPrefix("腹膜透析") == true)
    }
}
