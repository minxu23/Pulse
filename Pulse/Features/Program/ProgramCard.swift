import SwiftUI
import SwiftData

/// Top of 计划: where the user is in the 三阶段健康计划 and the one thing to do next.
struct ProgramCard: View {
    @Environment(\.modelContext) private var ctx
    @Query private var profiles: [UserProfile]
    @Query private var records: [DailyRecord]
    @State private var status: ProgramStatus?
    @State private var roundEnd: ProgramRoundResult?

    var body: some View {
        Group {
            if let p = profiles.first, let s = status {
                content(p, s)
            } else {
                Color.clear.frame(height: 0)
            }
        }
        .task(id: "\(profiles.first?.programPhaseRaw ?? "")|\(profiles.first?.programPackRaw ?? "")|\(records.count)") { refresh() }
    }

    private func refresh() {
        guard let p = profiles.first else { return }
        status = ProgramFlow.status(p, in: ctx)
        roundEnd = ProgramFlow.roundResult(p, in: ctx)
    }

    @ViewBuilder private func content(_ p: UserProfile, _ s: ProgramStatus) -> some View {
        switch s.phase {
        case .none where p.usageIntent == .recording:
            Card {
                CardTitle("记录身体状况")
                Text("当前不设置改善目标或训练完成率。需要时可以选择改善方向，再开始基线评估。")
                    .foregroundStyle(.secondary)
                NavigationLink("选择改善方向") { UsageDirectionView(profile: p) }
                    .buttonStyle(.borderedProminent)
            }
        case .none:
            Card {
                CardHeader(title: "三阶段健康计划", subtitle: "先用一周摸清身体和习惯，再按结果选改善方案", icon: "chart.line.uptrend.xyaxis")
                Text("基线期 1 周 → 改善期每轮 4 周、每周复盘 → 总结期。数据够的话，马上就能生成基线报告。")
                    .font(Theme.TypeScale.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("开始基线评估") {
                    ProgramFlow.startBaseline(p, in: ctx)
                    refresh()
                }
                .buttonStyle(.borderedProminent)
            }
        case .baseline:
            Card {
                if s.reportReady {
                    CardHeader(title: "基线报告已生成", subtitle: "看看你的健康画像，选一个改善方案", icon: "doc.text.magnifyingglass")
                    NavigationLink { ProgramReportScreen() } label: { Text("查看报告").fontWeight(.semibold) }
                        .buttonStyle(.borderedProminent)
                } else {
                    CardHeader(title: "基线期 · 第 \(min(s.baselineDays + 1, ProgramFlow.baselineDays)) / \(ProgramFlow.baselineDays) 天",
                               subtitle: "照常生活，不用刻意多练", icon: "calendar")
                    ProgressView(value: Double(min(s.baselineDays, ProgramFlow.baselineDays)), total: Double(ProgramFlow.baselineDays))
                    ForEach(s.missing, id: \.label) { item in
                        IconTextRow(icon: "circle.dashed", color: .secondary, title: "还差：\(item.label)", text: item.hint)
                    }
                }
                if !p.programQuestionsDone {
                    NavigationLink { BaselineQuestionsView(profile: p) } label: {
                        NavRowLabel(icon: "list.bullet.clipboard", title: "填写基础信息", detail: "运动前安全问题、喜欢的运动、力量自测，约 2 分钟")
                    }
                    .buttonStyle(.plain)
                }
            }
        case .improve where roundEnd != nil:
            RoundEndCard(result: roundEnd!, onContinue: {
                ProgramFlow.finishRound(roundEnd!, profile: p, in: ctx)
                refresh()
            }, onReassess: {
                ProgramFlow.reassess(after: roundEnd!, profile: p, in: ctx)
                refresh()
            })
        case .summary:
            Card {
                CardHeader(title: "总结期 · \(s.pack?.title ?? "")", subtitle: "达到了目标，保持现在的节奏", icon: "checkmark.seal", color: Theme.good)
                NavigationLink { ProgramSummaryScreen() } label: {
                    NavRowLabel(icon: "chart.bar.doc.horizontal", title: "查看总结", detail: "和基线比，哪些变好了，接下来怎么做")
                }
                .buttonStyle(.plain)
            }
        case .improve:
            Card {
                CardHeader(title: "\(s.pack?.title ?? "改善方案") · 第 \(s.round) 轮",
                           subtitle: s.week == 0 ? "下周一开始第 1 周" : "第 \(min(s.week, s.weeks)) / \(s.weeks) 周",
                           icon: s.pack?.icon ?? "figure.run", color: s.pack?.color ?? .secondary)
                if let t = s.target { FactRow(label: "主靶点", value: t.title) }
                NavigationLink("查看方案与调整") { ProgramDetailScreen() }.buttonStyle(.bordered)
                NavigationLink { ProgramReportScreen() } label: {
                    NavRowLabel(icon: "doc.text", title: "基线报告", detail: "这一轮开始时的健康画像")
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// 基线期 on 今日, inside the 「现在」 card: 「基线期第 3/7 天 · 还差：户外快走」, then 「基线报告已生成」.
struct BaselineProgressLine: View {
    @Binding var tab: AppTab
    @Environment(\.modelContext) private var ctx
    @Query private var profiles: [UserProfile]
    @Query private var records: [DailyRecord]
    @State private var status: ProgramStatus?

    var body: some View {
        Group {
            if let s = status, s.reportReady {
                NavigationLink { ProgramReportScreen() } label: {
                    NavRowLabel(icon: "doc.text.magnifyingglass", title: "基线报告已生成", detail: "看看你的健康画像，选一个改善方案")
                }
                .buttonStyle(.plain)
            } else if let s = status {
                Button { tab = .plan } label: {
                    NavRowLabel(icon: "calendar", title: s.baselineLine, detail: "照常生活，不用刻意多练；摸底周的安排在「计划」里")
                }
                .buttonStyle(.plain)
            } else {
                Color.clear.frame(height: 0)
            }
        }
        .task(id: "\(profiles.first?.programPhaseRaw ?? "")|\(records.count)|\(Date.app.startOfDay)") {
            guard let p = profiles.first, p.programPhase == .baseline else { status = nil; return }
            status = ProgramFlow.status(p, in: ctx)
        }
    }
}

/// The baseline report: worked out from the records while still in 基线期, the frozen one afterwards.
struct ProgramReportScreen: View {
    @Environment(\.modelContext) private var ctx
    @Environment(\.dismiss) private var dismiss
    @Query private var profiles: [UserProfile]
    @Query private var meds: [MedicationEntry]
    @State private var result: BaselineResult?
    @State private var picking = false

    var body: some View {
        let p = profiles.first
        let snap = p?.snapshot(medications: meds) ?? ProfileSnapshot()
        Group {
            if let result {
                BaselineReportView(result: result, profile: snap,
                                   onChoose: { picking = true })
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task { load() }
        .sheet(isPresented: $picking) {
            if let result, let p {
                CalmNavigationStack {
                    PackPickerView(result: result, profile: snap) { pack in
                        ProgramFlow.choose(pack, result: result, profile: p, in: ctx)
                        picking = false
                        dismiss()
                    }
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { picking = false } } }
                }
            }
        }
    }

    private func load() {
        guard let p = profiles.first else { return }
        if p.programPhase == .baseline || p.programPhase == .none {
            let window = p.programPhase == .none ? DataHub.historyWindow() : ProgramFlow.baselineWindow(p)
            result = DataHub.baseline(in: ctx, window: window)
        } else {
            result = ProgramFlow.baselineSnapshot(in: ctx)
        }
    }
}
