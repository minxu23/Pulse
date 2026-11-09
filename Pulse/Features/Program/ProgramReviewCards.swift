import SwiftUI
import SwiftData

/// 本周复盘 › 方案进度: which week of the round, what was done, where the main target stands, next week.
struct ProgramWeekCard: View {
    let weekStart: Date
    @Environment(\.modelContext) private var ctx
    @Query private var profiles: [UserProfile]
    @Query private var items: [PlanItem]
    @Query private var records: [DailyRecord]
    @State private var report: ProgramWeekReport?

    var body: some View {
        Group {
            if let r = report, let p = profiles.first {
                Card {
                    CardHeader(title: "方案进度", subtitle: "\(p.programPack?.title ?? "") · 第 \(p.programRound) 轮 第 \(r.week) / \(r.weeks) 周",
                               icon: p.programPack?.icon ?? "list.bullet.clipboard", color: p.programPack?.color ?? .secondary) {
                        Chip(text: r.excused ? "不计入" : r.met ? "这周做到了" : "还差一些", color: r.excused ? .secondary : r.met ? Theme.good : Theme.warning)
                    }
                    ForEach(r.checks, id: \.title) { c in
                        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.item) {
                            Image(systemName: c.met ? "checkmark.circle.fill" : "circle").foregroundStyle(c.met ? Theme.good : .secondary)
                            Text(c.title).font(Theme.TypeScale.body.weight(.semibold))
                            Spacer(minLength: Theme.Space.item)
                            Text(c.detail).font(Theme.TypeScale.body).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
                        }
                    }
                    Divider()
                    Text(r.targetLine).font(Theme.TypeScale.body).fixedSize(horizontal: false, vertical: true)
                    IconTextRow(icon: "arrow.turn.down.right", color: .secondary, title: "下周", text: r.next)
                }
            } else {
                Color.clear.frame(height: 0)
            }
        }
        .task(id: "\(weekStart)|\(items.count)|\(records.count)|\(profiles.first?.programRound ?? 0)") {
            guard let p = profiles.first else { return }
            report = ProgramFlow.weekReport(p, weekStart: weekStart, in: ctx)
        }
    }
}

/// 长期复盘 › 所处阶段: the three phases with where the user is now.
struct ProgramStageCard: View {
    @Environment(\.modelContext) private var ctx
    @Environment(\.dynamicTypeSize) private var size
    @Query private var profiles: [UserProfile]
    @State private var rounds: [ProgramRoundResult] = []

    var body: some View {
        let p = profiles.first
        let phase = p?.programPhase ?? .none
        Card {
            CardTitle("所处阶段", detail: p?.programPack?.title)
            // One above the other at accessibility sizes, so no stage name is cut off.
            AdaptiveStack(spacing: Theme.Space.item) {
                stage("基线期", index: 0, phase: phase)
                arrow
                stage(phase.runsPack ? "改善期 · 第 \(p?.programRound ?? 1) 轮" : "改善期", index: 1, phase: phase)
                arrow
                stage("总结期", index: 2, phase: phase)
            }
            Text(Self.line(phase, p)).font(Theme.TypeScale.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ForEach(Array(rounds.enumerated()), id: \.offset) { _, r in
                FactRow(label: "第 \(r.round) 轮", value: r.headline)
            }
        }
        .task(id: "\(phase.rawValue)|\(p?.programRound ?? 0)") { rounds = ProgramFlow.roundResults(in: ctx) }
    }

    /// Right between stages in a row, down when they stack at accessibility sizes.
    private var arrow: some View {
        Image(systemName: size.isAccessibilitySize ? "chevron.down" : "chevron.right")
            .font(Theme.TypeScale.body).imageScale(.small).foregroundStyle(.tertiary)
            .padding(.leading, size.isAccessibilitySize ? Theme.Space.item : 0)
            .accessibilityHidden(true)
    }

    private func stage(_ title: String, index: Int, phase: ProgramPhase) -> some View {
        let current: Int? = switch phase {
        case .none: nil
        case .baseline: 0
        case .improve: 1
        case .summary: 2
        }
        let isNow = current == index
        let passed = (current ?? -1) > index
        return Text(title)
            .font(Theme.TypeScale.body.weight(isNow ? .semibold : .regular))
            .foregroundStyle(isNow ? Color.primary : Color.secondary)
            .padding(.horizontal, Theme.Space.item).padding(.vertical, Theme.Space.tight)
            .background(isNow ? Theme.subtle : Color.clear, in: Capsule())
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel(title + (isNow ? "，当前" : passed ? "，已完成" : ""))
    }

    static func line(_ phase: ProgramPhase, _ p: UserProfile?) -> String {
        switch phase {
        case .none: "还没开始。在「计划」里开始基线评估：先记录一周，再按结果选改善方案。"
        case .baseline: "正在记录基线：照常生活，报告生成后选一个改善方案。"
        case .improve: p?.programPack == .event ? "每周复盘一次，每 4 周看一次训练阶段，比赛结束后进入总结期。"
            : "每周复盘一次；第 \(p?.programRoundWeeks ?? 4) 周结束时看主靶点\(p?.programTarget.map { "（\($0.title)）" } ?? "")有没有达到目标。"
        case .summary: "这一轮达到了目标。保持现在的节奏，3 个月后可以复评一次。"
        }
    }
}

/// When a round's weeks are over: the result and the one step that follows.
struct RoundEndCard: View {
    let result: ProgramRoundResult
    var onContinue: () -> Void
    /// The third round in a row without the goal: a new baseline instead.
    var onReassess: (() -> Void)? = nil

    var body: some View {
        let ends = result.outcome.endsProgram
        Card {
            CardHeader(title: result.headline, subtitle: result.outcome == .phaseCheck ? "第 \(result.round) 个 4 周" : "第 \(result.round) 轮结束",
                       icon: ends ? "checkmark.seal" : "arrow.triangle.2.circlepath", color: ends ? Theme.good : .secondary)
            Text(result.detail).font(Theme.TypeScale.body).fixedSize(horizontal: false, vertical: true)
            IconTextRow(icon: "arrow.turn.down.right", color: .secondary, title: "接下来", text: result.next)
            if result.suggestsReassessment == true, let onReassess {
                Button("重新做基线评估", action: onReassess).buttonStyle(.borderedProminent)
                Button("继续第 \(result.round + 1) 轮", action: onContinue).buttonStyle(.bordered)
            } else {
                Button(ends ? "进入总结期" : result.outcome == .phaseCheck ? "开始下一个 4 周" : "开始第 \(result.round + 1) 轮", action: onContinue)
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}

/// 总结期: baseline against now, what changed in the habits, and what comes next.
struct ProgramSummaryScreen: View {
    @Environment(\.modelContext) private var ctx
    @Query private var profiles: [UserProfile]
    @Query private var meds: [MedicationEntry]
    @State private var baseline: BaselineResult?
    @State private var now: BaselineResult?
    @State private var rounds: [ProgramRoundResult] = []
    @State private var worked: [Association] = []
    @State private var scheduled = false

    var body: some View {
        ScreenScroll {
            if let b = baseline, let n = now {
                Card {
                    CardTitle("这几轮的变化")
                    Text("基线 \(BaselineReportView.range(b.report.window))\n现在 \(BaselineReportView.range(n.report.window))")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    ForEach(Self.kinds, id: \.self) { k in
                        if let before = b.report.metric(k), let after = n.report.metric(k), before.value != nil, after.value != nil {
                            FactRow(label: before.title, value: "\(before.valueText) → \(after.valueText)" + Self.band(before, after))
                        }
                    }
                }
                Card {
                    CardTitle("习惯的变化")
                    if let s0 = b.report.habits.stepsMean, let s1 = n.report.habits.stepsMean {
                        FactRow(label: "日均步数", value: "\(Int(s0.rounded())) → \(Int(s1.rounded())) 步")
                    }
                    FactRow(label: "中高强度运动", value: "每周 \(Int(b.report.habits.guidelineMinutes)) → \(Int(n.report.habits.guidelineMinutes)) 分钟")
                    if let main = n.report.habits.mainSlot { FactRow(label: "常运动的时段", value: main.label) }
                }
            }
            Card {
                CardTitle("哪些做法有效")
                if worked.isEmpty {
                    Text("记录还不够多，暂时看不出哪些做法和结果有关。").foregroundStyle(.secondary)
                } else {
                    ForEach(worked) { a in
                        IconTextRow(icon: a.icon, color: .secondary, title: a.factor,
                                    text: "\(a.metric)平均\(a.diff > 0 ? "高" : "低") \(abs(a.diff).shortDecimal) \(a.unit)（关联\(a.strength.label)）")
                    }
                }
                Text("这些是你记录里的关联，不代表因果。").foregroundStyle(.secondary)
            }
            if !rounds.isEmpty {
                Card {
                    CardTitle("每一轮")
                    ForEach(Array(rounds.enumerated()), id: \.offset) { _, r in
                        VStack(alignment: .leading, spacing: Theme.Space.hairline) {
                            Text("第 \(r.round) 轮 · \(r.headline)").font(Theme.TypeScale.body.weight(.semibold))
                            Text(r.detail).font(Theme.TypeScale.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            Card {
                CardTitle("接下来")
                IconTextRow(icon: "repeat", color: .secondary, title: "维持方案",
                            text: "保持基础习惯（步数、起身活动、睡眠、每周 2 次力量），每周 2–3 次核心训练，强度不变，不再加量。计划页会按这个节奏安排。")
                Button(scheduled ? "已加到照护与随访" : "3 个月后提醒我复评") {
                    ProgramFlow.scheduleReassessment(in: ctx)
                    scheduled = true
                }
                .buttonStyle(.bordered)
                .disabled(scheduled)
                if let p = profiles.first {
                    Button("现在就选新方案") {
                        ProgramFlow.startBaseline(p, in: ctx)
                    }
                    .buttonStyle(.borderless)
                }
            }
            PageFootnote("对比用的是开始时冻结的基线报告和进入总结期时冻结的总结报告。手表和体脂秤的数值是估算，看方向比看单次更有意义。")
        }
        .navigationTitle("总结")
        .navigationBarTitleDisplayMode(.inline)
        .calmStyle()
        .task {
            baseline = ProgramFlow.baselineSnapshot(in: ctx)
            // The summary report frozen when 总结期 began; worked out now for older programs without one.
            now = ProgramFlow.summarySnapshot(in: ctx) ?? DataHub.baseline(in: ctx, window: DataHub.historyWindow())
            rounds = ProgramFlow.roundResults(in: ctx)
            let a = DataHub.analytics(in: ctx)
            worked = Array(InsightEngine.associations(days: a.days, profile: a.profile)
                .filter { $0.strength >= .weak && !$0.unfavorable }.sorted { abs($0.effect) > abs($1.effect) }.prefix(3))
        }
    }

    /// Steps are under 习惯的变化, not here as well.
    static let kinds: [BaselineMetric.Kind] = [.vo2max, .rhr, .bloodPressure, .bmi, .bodyFat, .glucose, .sleepDuration]

    static func band(_ a: BaselineMetric, _ b: BaselineMetric) -> String {
        guard let x = a.rank?.band, let y = b.rank?.band, x != y else { return "" }
        return "（\(x.label) → \(y.label)）"
    }
}
