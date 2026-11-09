import SwiftUI
import SwiftData

/// 选择方案: the recommended pack first, the others below, and what a round of the chosen one asks for.
struct PackPickerView: View {
    @Environment(\.modelContext) private var ctx
    @Query private var profiles: [UserProfile]
    @Query private var meds: [MedicationEntry]
    @State private var showSafety = false
    @State private var safetyRevision = 0
    let result: BaselineResult
    let profile: ProfileSnapshot
    let onStart: (ProgramPack) -> Void
    @State private var selected: ProgramPack
    @State private var askDoctor = false
    /// Worked out once on opening and after the safety questions, not on every tap.
    @State private var refreshed: BaselineResult?
    @State private var base: (target: TargetMetric, value: Double?)?

    init(result: BaselineResult, profile: ProfileSnapshot, onStart: @escaping (ProgramPack) -> Void) {
        self.result = result
        self.profile = profile
        self.onStart = onStart
        _selected = State(initialValue: result.recommendation.recommended.pack)
    }

    private var currentResult: BaselineResult { refreshed ?? result }
    private var currentProfile: ProfileSnapshot { profiles.first?.snapshot(medications: meds) ?? profile }

    var body: some View {
        let latest = currentResult
        let person = currentProfile
        let rec = latest.recommendation
        let options = [rec.recommended] + rec.alternatives
        ScreenScroll {
            Card {
                ForEach(Array(options.enumerated()), id: \.element.pack) { i, o in
                    if i > 0 { Divider() }
                    row(o, recommended: i == 0, enabled: true)
                }
                ForEach(rec.blocked, id: \.pack) { o in
                    Divider()
                    row(o, recommended: false, enabled: false)
                }
            }
            detail(selected, result: latest, profile: person)
            confirmationSummary(latest, person)
            if let p = profiles.first, !p.canStartImprovement {
                Button("补充年龄与运动前安全问题") { showSafety = true }
                Text("记录身体状况不需要填写；开始改善方案前需要逐项确认。")
                    .foregroundStyle(.secondary)
            }
            if rec.doctorFirst {
                Callout(kind: .urgent, title: "先就医", text: "基线报告里有需要先就医的情况。医生确认可以运动之前，只做基础层：步行、拉伸和作息。")
            }
            Button("开始「\(selected.title)」") {
                guard let p = profiles.first else { return }
                if !p.canStartImprovement { showSafety = true }
                else if ProgramFlow.doctorStillNeeded(p, latest.report) { askDoctor = true }
                else { onStart(selected) }
            }
            .buttonStyle(.borderedProminent)
            .disabled(ProgramPacks.blocker(selected, latest.report, person) != nil)
            .frame(maxWidth: .infinity, alignment: .leading)
            PageFootnote(selected == .event ? "按比赛日期分阶段，每 4 周复盘一次训练阶段，比赛结束后进入总结期。中途也可以换方案。"
                         : "每轮 4 周，每周复盘一次；生病或出差的周不计入，这一轮最多顺延 2 周。第 4 周结束时看主靶点有没有达到目标：达到了进入总结期，没达到就调整后再来一轮。中途也可以换方案。")
        }
        .calmStyle()
        .task(id: safetyRevision) {
            guard let p = profiles.first else { return }
            // Switching packs starts from the last 14 days; the frozen baseline report stays as it is.
            refreshed = DataHub.baseline(in: ctx, window: ProgramFlow.startWindow(p, result: result))
        }
        .task(id: "\(selected.rawValue)|\(safetyRevision)|\(refreshed != nil)") {
            guard profiles.first != nil else { return }
            let r = currentResult
            let t = ProgramPacks.target(for: selected, report: r.report, profile: currentProfile)
            base = (t, ProgramFlow.baselineValue(t, result: r, in: ctx))
        }
        .sheet(isPresented: $showSafety, onDismiss: { safetyRevision += 1 }) {
            if let p = profiles.first { CalmNavigationStack { BaselineQuestionsView(profile: p) } }
        }
        .navigationTitle("选择方案")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("医生已经看过报告里需要先就医的情况，确认你可以开始运动了吗？", isPresented: $askDoctor, titleVisibility: .visible) {
            Button("已确认，开始") {
                if let p = profiles.first { ProgramFlow.confirmDoctor(p, currentResult.report) }
                onStart(selected)
            }
            Button("还没有", role: .cancel) {}
        } message: {
            Text("这只用于开始方案。心脏或肾脏方面的强度限制不变，要放开请在照护设置里填写医生确认的范围。")
        }
    }

    private func confirmationSummary(_ result: BaselineResult, _ person: ProfileSnapshot) -> some View {
        let r = result.report
        let t = ProgramPacks.target(for: selected, report: r, profile: person)
        let preview = ProgramFlow.preview(selected, result: result, profile: person)
        let trainings = preview.sessions.filter { $0.kind.isTraining }
        let minutes = trainings.map(\.minutes).reduce(0, +)
        let days = Set(trainings.map(\.weekday)).count
        let start = ProgramFlow.roundStart()
        let loading = profiles.first != nil && self.base?.target != t
        let base = self.base?.target == t ? self.base?.value : nil
        let goal = base.map { TargetTracker.goal(t, baseline: $0, profile: person, report: r) } ?? TargetTracker.defaultGoal(t, profile: person)
        return Card {
            CardTitle("本轮安排")
            FactRow(label: "开始", value: start.formatted(date: .abbreviated, time: .omitted))
            FactRow(label: "结束", value: start.adding(days: 27).formatted(date: .abbreviated, time: .omitted))
            if t == .weeklyRunKm {
                FactRow(label: "近 4 周周跑量", value: loading ? "正在计算" : base.map { "\($0.shortDecimal) 公里" } ?? "没有跑步记录")
                FactRow(label: "本轮目标", value: "每周完成计划跑量的 90% 以上")
            } else {
                FactRow(label: t.isBloodPressure ? "基线收缩压" : "基线", value: loading ? "正在计算" : base.map { TargetTracker.text(t, $0) + " " + t.unit } ?? "数据不足")
                FactRow(label: t.isBloodPressure ? "收缩压目标" : "本轮目标", value: loading ? "正在计算" : goal.map { (t.higherIsBetter ? "≥ " : "≤ ") + TargetTracker.text(t, $0) + " " + t.unit } ?? "先补充读数")
            }
            FactRow(label: "首周训练", value: "\(days) 天，共约 \(minutes) 分钟")
            if let steps = preview.stepsTarget { FactRow(label: "首周日均步数", value: "\(steps) 步") }
            Text(t.howToMeasure).foregroundStyle(.secondary)
            if start > Date.app.startOfDay { Text("正式开始前保留原有安排，不计入本轮完成率。").foregroundStyle(.secondary) }
            if profiles.first?.programPhase == .improve { Text("确认更换后开始新一轮，已有记录和报告保留。").foregroundStyle(.secondary) }
        }
    }

    private func row(_ o: PackRecommendation.Option, recommended: Bool, enabled: Bool) -> some View {
        Button {
            selected = o.pack
        } label: {
            HStack(alignment: .top, spacing: Theme.Space.block) {
                IconTile(icon: o.pack.icon, color: enabled ? o.pack.color : .secondary)
                VStack(alignment: .leading, spacing: Theme.Space.hairline) {
                    HStack(spacing: Theme.Space.item) {
                        Text(o.pack.title).font(Theme.TypeScale.body.weight(.semibold)).foregroundStyle(enabled ? .primary : .secondary)
                        if recommended { Chip(text: "推荐", color: Theme.good) }
                    }
                    Text(o.reason).font(Theme.TypeScale.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: Theme.Space.item)
                if enabled {
                    Image(systemName: selected == o.pack ? "checkmark.circle.fill" : "circle")
                        .font(Theme.TypeScale.title).foregroundStyle(selected == o.pack ? Color.accentColor : Color.secondary)
                }
            }
            .frame(minHeight: Theme.Size.tap)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityAddTraits(selected == o.pack ? .isSelected : [])
    }

    private func detail(_ pack: ProgramPack, result: BaselineResult, profile: ProfileSnapshot) -> some View {
        let target = ProgramPacks.target(for: pack, report: result.report, profile: profile)
        return Card {
            CardTitle("\(pack.title)：这 4 周做什么")
            FactRow(label: "主靶点", value: target.title)
            Text(target.howToMeasure).font(Theme.TypeScale.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: Theme.Space.item) {
                ForEach(Self.contents(pack), id: \.self) { line in
                    HStack(alignment: .firstTextBaseline, spacing: Theme.Space.item) {
                        Image(systemName: "checkmark").font(Theme.TypeScale.body.weight(.semibold)).foregroundStyle(.secondary)
                        Text(line).font(Theme.TypeScale.body).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            Text("所有方案都包含基础习惯：步数逐步增加、久坐时起身、睡够 7 小时、每周 2 次力量。方案从你基线期实际做到的量开始，喜欢的运动会算进训练。")
                .font(Theme.TypeScale.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    static func contents(_ pack: ProgramPack) -> [String] {
        switch pack {
        case .fitness: ["每周 3–4 次有氧，大部分是能说话的强度", "身体允许时，每周 1–2 次让心跳明显加快的间歇", "第 4 周做一次户外快走或跑步，看最大摄氧量的变化"]
        case .event: ["按比赛日期分阶段：打基础、加量、减量", "每周 1 次长距离，周跑量循序渐进", "长距离时练习比赛补给"]
        case .cardio: ["多数日子做 30–45 分钟中等强度有氧", "有高血压时，每周 3 次靠墙静蹲等静力练习", "少盐、限酒、睡够，按方案测血压或看静息心率"]
        case .metabolic: ["饭后走 10–15 分钟，先从晚饭后开始", "每周 2–3 次力量训练", "每周 150 分钟以上中等强度运动"]
        case .sleep: ["每天同一时间起床，周末也不晚于平时 1 小时", "睡得少的，上床时间每周提前 15 分钟，直到睡够 7 小时", "下午不喝咖啡和浓茶，睡前几小时不喝酒、不做剧烈运动"]
        }
    }
}

#if DEBUG
/// `-PulseOpen packs`: the pack picker for the current records, for screenshots.
struct DebugPackPicker: View {
    @Environment(\.modelContext) private var ctx
    @State private var result: BaselineResult?
    var body: some View {
        Group {
            if let result {
                PackPickerView(result: result, profile: DataHub.analytics(in: ctx).profile) { _ in }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task { result = DataHub.baseline(in: ctx, window: DataHub.historyWindow()) }
    }
}
#endif
