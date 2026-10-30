import Foundation
import SwiftData
import Testing
@testable import Pulse

private let day = Calendar.pulse.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 9))!

@Suite("Lab results and kidney diet")
@MainActor
struct LabDietTests {
    private func lab(_ daysAgo: Int, _ kind: LabKind, _ v: Double) -> LabPoint {
        LabPoint(date: day.adding(days: -daysAgo), kind: kind, value: v)
    }

    @Test func estimatesEGFRAndReadsStages() {
        // CKD-EPI 2021: a 57-year-old man with creatinine 127 μmol/L is around 57.
        let e = try? #require(LabAnalyzer.ckdEPI(creatinine: 127, age: 57, sex: .male))
        #expect(abs((e ?? 0) - 57) < 1.5)
        #expect(LabAnalyzer.ckdEPI(creatinine: 127, age: 57, sex: .unspecified) == nil)
        // Women get a higher estimate for the same creatinine at the same age.
        #expect((LabAnalyzer.ckdEPI(creatinine: 80, age: 60, sex: .female) ?? 0) < (LabAnalyzer.ckdEPI(creatinine: 80, age: 60, sex: .male) ?? 0) + 30)
        #expect(LabAnalyzer.egfrStage(92).code == "G1" && LabAnalyzer.egfrStage(59.9).code == "G3a" && LabAnalyzer.egfrStage(14).code == "G5")
        #expect(LabAnalyzer.uacrStage(29).code == "A1" && LabAnalyzer.uacrStage(86).code == "A2" && LabAnalyzer.uacrStage(301).code == "A3")
        let p = ProfileSnapshot()
        #expect(LabAnalyzer.status(.potassium, 4.5, profile: p).level == .normal)
        #expect(LabAnalyzer.status(.potassium, 3.2, profile: p).text == "偏低")
        #expect(LabAnalyzer.status(.potassium, 2.8, profile: p).level == .urgent)
        #expect(LabAnalyzer.status(.potassium, 5.4, profile: p).level == .abnormal)
        #expect(LabAnalyzer.status(.potassium, 6.1, profile: p).level == .urgent)
        var woman = ProfileSnapshot()
        woman.sex = .female
        #expect(LabAnalyzer.status(.hemoglobin, 125, profile: woman).level == .normal)
        #expect(LabAnalyzer.status(.hemoglobin, 125, profile: p).level == .watch)
        // HbA1c is read against the usual target for people with diabetes, not the diagnosis cut-off.
        var diabetic = ProfileSnapshot()
        diabetic.conditions = [.diabetesT2]
        #expect(LabAnalyzer.status(.hba1c, 6.8, profile: diabetic).level == .normal)
        #expect(LabAnalyzer.status(.hba1c, 6.8, profile: p).level == .abnormal)
    }

    @Test func reportsInOtherUnitsAreConverted() {
        // A3 starts at 30 mg/mmol = 300 mg/g, A2 at 3 mg/mmol = 30 mg/g.
        #expect(abs(LabKind.uacr.standard(34, unit: "mg/mmol") - 300) < 1)
        #expect(LabAnalyzer.uacrStage(LabKind.uacr.standard(5.1, unit: "mg/mmol")).code == "A2")
        #expect(abs(LabKind.creatinine.standard(1.44, unit: "mg/dL") - 127) < 1)
        #expect(abs(LabKind.uricAcid.standard(7, unit: "mg/dL") - 416) < 1)
        #expect(abs(LabKind.phosphorus.standard(4.5, unit: "mg/dL") - 1.45) < 0.01)
        #expect(abs(LabKind.hemoglobin.standard(12.7, unit: "g/dL") - 127) < 0.001)
        #expect(abs(LabKind.hba1c.standard(53, unit: "mmol/mol") - 7.0) < 0.05, "IFCC 53 ≈ NGSP 7.0%")
        #expect(LabKind.potassium.units == ["mmol/L"] && LabKind.allCases.allSatisfy { $0.units.first == $0.unit && $0.standard(5, unit: $0.unit) == 5 })
    }

    @Test func followsTheEGFRTrendAndRaisesWhatShouldNotWait() {
        let slow = [lab(520, .egfr, 63), lab(380, .egfr, 62), lab(200, .egfr, 60), lab(100, .egfr, 58), lab(12, .egfr, 57)]
        let t = LabAnalyzer.egfrTrend(slow)
        #expect(t?.fast == false && t?.text.contains("每年下降约 4") == true, "\(t?.text ?? "")")
        let fast = [lab(500, .egfr, 70), lab(300, .egfr, 62), lab(10, .egfr, 55)]
        #expect(LabAnalyzer.egfrTrend(fast)?.fast == true)
        // Two results: the change since the last one.
        #expect(LabAnalyzer.egfrTrend([lab(120, .egfr, 60), lab(5, .egfr, 42)])?.text.contains("下降 30%") == true)
        // An estimate from creatinine counts only on days without a measured value.
        let mixed = [lab(30, .egfr, 50), LabPoint(date: day.adding(days: -30), kind: .egfr, value: 48, estimated: true),
                     LabPoint(date: day.adding(days: -5), kind: .egfr, value: 47, estimated: true)]
        #expect(LabAnalyzer.egfrSeries(mixed).map(\.value) == [50, 47])

        let p = ProfileSnapshot()
        let k = LabAnalyzer.alert(for: [lab(0, .potassium, 6.2)], history: [], profile: p)
        #expect(k?.severity == .urgent && k?.kind == .labAbnormal && k?.guidance.contains("不做运动") == true)
        #expect(LabAnalyzer.alert(for: [lab(0, .potassium, 5.0)], history: [], profile: p) == nil)
        let drop = LabAnalyzer.alert(for: [lab(0, .egfr, 42)], history: [lab(150, .egfr, 60)], profile: p)
        #expect(drop?.title == "eGFR 比上次下降 30%")
        #expect(LabAnalyzer.alert(for: [lab(0, .egfr, 55)], history: [lab(150, .egfr, 60)], profile: p) == nil)
    }

    @Test func kidneyDietAgainstTheDoctorsAmounts() {
        var p = ProfileSnapshot()
        p.tracksNutrients = true
        p.proteinTargetG = 55
        p.potassiumLimit = true
        var d = DayData(day: day.startOfDay)
        #expect(KidneyDiet.lines(d, profile: p).isEmpty)
        d.nutrientsLogged = true
        d.saltSources = ["咸菜、腌制品", "外卖或在外吃"]
        d.proteinServings = 10
        d.potassiumFoods = ["香蕉", "土豆、红薯、芋头"]
        let lines = KidneyDiet.lines(d, profile: p)
        #expect(lines.count == 4)
        #expect(lines[0].tone == .attention && lines[0].text.hasPrefix("偏咸"))
        #expect(lines[1].tone == .attention && lines[1].text.contains("超过医生定的 55 g"))
        #expect(lines[2].tone == .attention && lines[2].text == "高钾食物 2 份（约 750 mg 钾）：香蕉；土豆、红薯、芋头", "\(lines[2].text)")
        #expect(lines[3].tone == .neutral && lines[3].text == "没有高磷食物")
        // Foods counted in portions, staples included, replace the older 「肉蛋奶豆 N 份」.
        var counted = d
        counted.proteinFoods = ["鸡蛋", "瘦肉", "瘦肉", "米饭", "米饭", "蔬菜"]
        counted.potassiumFoods = ["香蕉", "香蕉", "番茄"]
        #expect(KidneyDiet.proteinG(counted) == 36 && KidneyDiet.proteinG(d) == 70)
        let c = KidneyDiet.lines(counted, profile: p)
        #expect(c[1].tone == .good && c[1].text == "蛋白质约 36 g（医生定的 55 g）", "\(c[1].text)")
        #expect(c[2].text == "高钾食物 3 份（约 850 mg 钾）：香蕉 ×2；番茄", "\(c[2].text)")
        var noTarget = p
        noTarget.proteinTargetG = nil
        #expect(KidneyDiet.lines(counted, profile: noTarget)[1].text == "蛋白质约 36 g（鸡蛋；瘦肉 ×2 等）")
        // Measured salt wins over the food list.
        d.saltG = 4
        #expect(KidneyDiet.lines(d, profile: p)[0].tone == .good)
        // Without a limit, high-potassium food is only listed.
        p.potassiumLimit = false
        #expect(KidneyDiet.lines(d, profile: p)[2].tone == .neutral)
        // Too little protein is worth a word too.
        d.proteinServings = 3
        #expect(KidneyDiet.lines(d, profile: p)[1].text.contains("明显少于"))

        var other = DayData(day: day.startOfDay.adding(days: -1))
        other.nutrientsLogged = true
        other.saltSources = ["咸菜、腌制品", "香肠、火腿、腊肉", "方便面、速冻食品"]
        other.proteinServings = 6
        let w = KidneyDiet.week([d, other, DayData(day: day.startOfDay.adding(days: -2))], profile: p, now: day)
        #expect(w?.days == 2 && w?.saltyDays == 1)
        #expect(w?.potassiumPerDay == 1 && w?.potassiumMgPerDay == 375 && w?.proteinAvgG == 31.5)
        #expect(KidneyDiet.digest([d, other], profile: p, now: day)?.contains("近 7 天记录了 2 天") == true)
    }

    @Test func theAgentReadsLabsAndTheKidneyDiet() throws {
        let container = try ModelContainer(for: Schema(PulseSchema.models), configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        let ctx = container.mainContext
        DemoDataGenerator.populate(ctx, persona: .wangjianguo, now: day)
        let profile = DataHub.profile(in: ctx)!
        let a = DataHub.analytics(in: ctx, now: day)
        #expect(a.profile.conditions.contains(.ckd) && a.profile.tracksNutrients && a.profile.proteinTargetG == 55)
        let labs = ((try? ctx.fetch(FetchDescriptor<LabResult>())) ?? []).map(\.point)
        #expect(LabAnalyzer.latest(labs).count == LabKind.allCases.count)
        #expect(a.days.filter(\.nutrientsLogged).count >= 8)
        let c = AgentContext.make(profile: a.profile, name: profile.displayName, days: a.days, plan: [], workouts: [], vitals: [],
                                  events: [], stopBang: [], baselineSetAt: nil, raceName: "", labs: labs, now: day)
        #expect(HealthAgent.intent(for: "我的肾功能怎么样？") == .labs)
        #expect(HealthAgent.intent(for: "血钾低会怎样") == .labs)
        let r = HealthAgent.reply(to: "我的化验结果怎么样？", context: c)
        #expect(r.intent == .labs && r.destination == .labs)
        #expect(r.text.contains("eGFR 57") && r.text.contains("G3a") && r.text.contains("血钾偏高"), "\(r.text)")
        let digest = HealthAgent.digest(c)
        #expect(digest.contains("化验（最近一次）：") && digest.contains("肾脏饮食（近 7 天"))
        // Diet answers bring in the record; training answers the recent potassium.
        #expect(HealthAgent.reply(to: "饮食上要注意什么？", context: c).text.contains("近 7 天记录了"))
        let t = HealthAgent.reply(to: "明天能跑间歇吗？", context: c)
        #expect(t.text.hasPrefix("不建议") && t.text.contains("血钾 5.4"), "\(t.text)")
        // A condition named in the question is not taken for a question about lab results.
        #expect(HealthAgent.reply(to: "我是低血钾症患者", context: c).intent == .condition)
    }
}
