import Foundation
import SwiftData
import Testing
@testable import Pulse

private let morning = Calendar.pulse.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 10, minute: 30))!

/// The answer template: every answer, written by the rules or a model, is read into the same parts,
/// and the numbers drawn with it are the ones its verdict gives.
@Suite("Answer layout")
@MainActor
struct AgentAnswerLayoutTests {
    private typealias L = AgentAnswerLayout

    private func list(_ s: L.Section) -> (title: String?, style: L.ListStyle, items: [L.Item])? {
        if case .list(let t, let st, let items) = s { (t, st, items) } else { nil }
    }

    @Test func verdictFirstWithoutTheWordsOfItsTag() {
        let verdict = "还没达标：近 30 天 16 次测量平均 142/86，目标是 130/80 以下。"
        let text = verdict + "\n\n晨起收缩压平均 143，晚上 135。\n\n• 每天固定时间吃药，别漏\n• 盐每天不超过 5 g，酱油、咸菜、外卖都算"
        let s = L.sections(of: text, conclusion: verdict, status: .attention("还没达标"), stepsTitle: "可以这样做")
        #expect(s.first == .verdict("近 30 天 16 次测量平均 142/86，目标是 130/80 以下。"))
        #expect(s[1] == .paragraph("晨起收缩压平均 143，晚上 135。"))
        let l = list(s[2])
        #expect(l?.title == "可以这样做" && l?.style == .steps && l?.items.map(\.icon) == ["pills.fill", "fork.knife"])
        // Without a tag the verdict keeps all its words.
        #expect(L.sections(of: text, conclusion: verdict).first == .verdict(verdict))
    }

    @Test func findingsStepsAndTheSafetyLineAreSetApart() {
        let first = "累的话今天先放轻松：训练降一级或换成散步，今晚早点睡。"
        let safety = "累了两周以上还不见好，或者伴有体重下降、发烧、气短、心慌，去看医生查一下（比如血常规、甲状腺、血糖）。"
        let text = first + "\n\n从你的记录看，可能有关的（不一定是原因）：\n• 血红蛋白 127 g/L 偏低，贫血会让人容易累\n• 近两周平均每晚睡 6.1 小时\n\n• 记下头晕的时间\n\n" + safety
        let s = L.sections(of: text, conclusion: first, safety: safety, stepsTitle: "可以这样做")
        #expect(s.count == 4)
        #expect(s[0] == .verdict(first))
        let findings = list(s[1]), steps = list(s[2])
        #expect(findings?.title == "从你的记录看，可能有关的（不一定是原因）" && findings?.style == .findings)
        #expect(findings?.items.map(\.icon) == ["testtube.2", "bed.double.fill"])
        #expect(steps?.title == "可以这样做" && steps?.items.count == 1)
        #expect(s[3] == .safety(safety))
        // A model's own wording of the line is recognised too.
        let reworded = first + "\n\n要是累了两周以上还不见好，或者伴有体重下降、发烧、气短、心慌，就去看医生。"
        #expect(L.sections(of: reworded, conclusion: first, safety: safety).last == .safety("要是累了两周以上还不见好，或者伴有体重下降、发烧、气短、心慌，就去看医生。"))
    }

    @Test func titlesListsUnderTheVerdictAndLabelledItems() {
        // 「你最近的化验结果：」 leads its list: it is the verdict, and the list needs no title of its own.
        let labs = L.sections(of: "你最近的化验结果：\n\n• eGFR 57 mL/min/1.73m²（10月9日）：G3a · 轻到中度下降\n• 血钾 5.4 mmol/L（10月9日）：偏高\n\n其他化验结果：\n\n• 血磷 1.32 mmol/L：正常",
                              stepsTitle: "可以这样做")
        #expect(labs[0] == .verdict("你最近的化验结果"))
        #expect(list(labs[1])?.title == nil && list(labs[1])?.items.count == 2)
        #expect(list(labs[2])?.title == "其他化验结果" && list(labs[2])?.style == .findings)
        // A short label before the colon is shown in bold; a long one stays in the line.
        let next = L.sections(of: "接下来最值得做的三件事：\n\n• 预约复查血钾：大约 11月6日 到期\n• 完成 7 天家庭血压监测：每天晨起、睡前各测 2 遍")
        #expect(list(next[1])?.items.map(\.label) == ["预约复查血钾", nil])
        #expect(list(labs[1])?.items.first?.label == nil)
    }

    @Test func aModelsListsInAnyMarkerAndSpacing() {
        let s = L.sections(of: "可以这样安排。\n\n1. 饭后散步 10–15 分钟\n\n2. 主食换一半粗粮\n\n- 睡前别吃夜宵", stepsTitle: "可以这样做")
        #expect(s.count == 2)
        #expect(list(s[1])?.items.map(\.text) == ["饭后散步 10–15 分钟", "主食换一半粗粮", "睡前别吃夜宵"])
        #expect(L.listItem("2024年体检") == nil && L.listItem("• ") == nil && L.listItem("1.5 小时就够了") == nil)
    }

    @Test func aHalfWrittenAnswerAlreadyHasItsShape() {
        #expect(L.sections(of: "还没达标：近 30 天") == [.verdict("还没达标：近 30 天")])
        let s = L.sections(of: "近 30 天平均 142/86。\n\n• 每天", stepsTitle: "可以这样做")
        #expect(s.count == 2 && list(s[1])?.items.first?.text == "每天")
    }

    @Test func finePrintAndMeasuredValues() {
        #expect(L.isNote("在「血糖管理」里能看到每餐后升了多少、运动前后的变化。"))
        #expect(L.isNote("各医院的参考范围略有不同，以化验单上的为准。"))
        #expect(!L.isNote("血钾偏高会影响心跳和肌肉：运动以中低强度为主，按医生的安排复查。"))
        let line = "近 14 天有 3 次，饭后散步 10–15 分钟，平均 142/86，目标范围内 68%，血钾 5.4 mmol/L"
        #expect(L.highlights(in: line).map { String(line[$0]) } == ["10–15 分钟", "142/86", "68%", "5.4 mmol/L"])
    }

    @Test func aPlanCardIsNotRepeatedAboveIt() throws {
        let f = try fixture(.wangjianguo)
        let r = HealthAgent.reply(to: "这周训练量减一点", context: f)
        let p = try #require(r.proposals.first)
        let shown = L.sections(of: r.text, reply: r, cards: r.blocks)
        let days = Set(p.lines.map { Weekday.name($0.weekday) })
        #expect(!shown.contains { list($0)?.items.contains { $0.label.map(days.contains) ?? false } ?? false })
        #expect(!shown.contains { if case .paragraph(let t) = $0 { p.notes.contains(t) } else { false } })
        #expect(shown.first.map { if case .verdict = $0 { true } else { false } } == true)
    }

    // MARK: Figures

    private func fixture(_ persona: DemoPersona) throws -> AgentContext {
        let container = try ModelContainer(for: Schema(PulseSchema.models), configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        let ctx = container.mainContext
        DemoDataGenerator.populate(ctx, persona: persona, now: morning)
        DataHub.ensureWeekPlan(in: ctx, now: morning)
        let a = DataHub.analytics(in: ctx, now: morning)
        let items = ((try? ctx.fetch(FetchDescriptor<PlanItem>())) ?? []).map(\.snapshot)
        let vitals = ((try? ctx.fetch(FetchDescriptor<VitalReading>())) ?? []).map(\.point).filter { $0.time > morning.adding(days: -60) }
        let labs = ((try? ctx.fetch(FetchDescriptor<LabResult>())) ?? []).map(\.point)
        return AgentContext.make(profile: a.profile, name: persona.name, days: a.days, plan: items, workouts: [], vitals: vitals, events: [], stopBang: [],
                                 baselineSetAt: nil, raceName: "", labs: labs, now: morning)
    }

    @Test func figuresShowTheNumbersTheVerdictGives() throws {
        let c = try fixture(.wangjianguo)
        let bp = HealthAgent.reply(to: "我最近血压怎么样", context: c)
        let avg = try #require(bp.figure?.tiles.first)
        #expect(bp.status == .attention("还没达标") && avg.tone == .attention)
        #expect(bp.text.contains("平均 \(avg.value)"))
        #expect(bp.figure?.chart == .bp)

        let g = HealthAgent.reply(to: "血糖控制得怎么样", context: c)
        let tir = try #require(g.figure?.tiles.first)
        #expect(g.text.contains("近 14 天 \(tir.value)% 的时间在目标范围内"))
        let parts = try #require(g.figure?.parts)
        #expect(parts.count == 3 && abs(parts.map(\.share).reduce(0, +) - 1) < 0.02)
        // The CGM summary only repeats the figure; the paragraph on lows does not.
        let paragraphs = g.text.components(separatedBy: "\n\n")
        let cgm = try #require(paragraphs.first { $0.hasPrefix("近 14 天 CGM") })
        #expect(L.restates(cgm, figure: g.figure!))
        #expect(!paragraphs.contains { $0.hasPrefix("有 ") && L.restates($0, figure: g.figure!) })

        for (q, chart) in [("静息心率为什么变高了", AgentChartMetric.rhr), ("HRV 是什么", .hrv), ("我的睡眠怎么样", .sleep), ("肾功能怎么样", .egfr)] {
            #expect(HealthAgent.reply(to: q, context: c).figure?.chart == chart, "\(q)")
        }
        let today = HealthAgent.reply(to: "今天适合运动吗", context: c)
        #expect(today.figure?.tiles.first?.label == "今天准备度" && today.status != nil)
        // A food and a reading say how they read in their tag.
        #expect(HealthAgent.reply(to: "能吃香蕉吗", context: c).status == .attention("先不吃"))
        #expect(HealthAgent.reply(to: "血压155要紧吗", context: c).status == .attention("偏高"))
        #expect(HealthAgent.reply(to: "血压165/95要紧吗", context: c).status == .attention("明显偏高"))
        #expect(HealthAgent.reply(to: "胸口闷", context: c).status?.tone == .urgent)
    }

    @Test func aFollowUpDropsTheTagAndTheNumbersItsVerdictHad() throws {
        let c = try fixture(.wangjianguo)
        let r = HealthAgent.continuing(HealthAgent.reply(to: "我最近血压怎么样，那该注意什么？", context: c), question: "那该注意什么？")
        #expect(r.status == nil && r.figure == nil)
    }
}
