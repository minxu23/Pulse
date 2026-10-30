import SwiftUI
import SwiftData

/// 根据实际情况调整当天安排 (需求 5): readiness, what's already done, soreness, fatigue and
/// time available → proposed changes with reasons. Nothing changes until the user accepts.
struct AdjustPlanView: View {
    @Environment(\.modelContext) private var ctx
    @Environment(\.dismiss) private var dismiss
    let items: [PlanItem]
    let readiness: ReadinessResult
    let analytics: Analytics
    let weekItems: [PlanItem]
    let urgentOpen: Bool

    @State private var available: Int? = nil
    @State private var soreness: Int? = 0
    @State private var area: SorenessArea = .none
    @State private var energy: Int? = nil
    @State private var ill = false
    @State private var loaded = false

    private let timeOptions: [Int?] = [nil, 60, 45, 30, 20, 10, 5]

    var body: some View {
        let result = PlanAdjuster.adjust(sessions: items.map(\.snapshot), context: context)
        CalmNavigationStack {
            Form {
                Section {
                    HStack {
                        Text("身体准备度")
                        Spacer()
                        StatusLabel(text: readiness.score.map { "\($0) · \(readiness.level.label)" } ?? "待评估", icon: "circle.fill",
                                    color: Theme.readiness(readiness.score == nil ? nil : readiness.level), secondaryText: true)
                    }
                    HStack {
                        Text("今天已活动")
                        Spacer()
                        Text("\(Int(analytics.today?.activeMinutes ?? 0)) 分钟 · \(analytics.today?.steps ?? 0) 步").foregroundStyle(.secondary)
                    }
                } header: { Text("当前状态") }

                Section("今天的实际情况") {
                    Picker("可用时间", selection: $available) {
                        ForEach(timeOptions, id: \.self) { v in Text(v.map { "约 \($0) 分钟" } ?? "按计划").tag(v) }
                    }
                    VStack(alignment: .leading, spacing: Theme.Space.item) {
                        Text("肌肉酸痛").font(.subheadline)
                        RatingPicker(value: $soreness, range: 0...3, labels: ["无", "轻微", "明显", "严重"])
                    }
                    .padding(.vertical, Theme.Space.tight)
                    if (soreness ?? 0) >= 2 {
                        Picker("部位", selection: $area) { ForEach(SorenessArea.allCases) { Text($0.label).tag($0) } }
                    }
                    VStack(alignment: .leading, spacing: Theme.Space.item) {
                        Text("此刻的精力").font(.subheadline)
                        RatingPicker(value: $energy, lowLabel: "很疲惫", highLabel: "充沛")
                    }
                    .padding(.vertical, Theme.Space.tight)
                    Toggle("身体不适 / 生病", isOn: $ill)
                }

                Section {
                    if result.proposals.isEmpty {
                        Text("今天没有待完成的训练。").foregroundStyle(.secondary)
                    }
                    ForEach(result.proposals) { p in
                        VStack(alignment: .leading, spacing: Theme.Space.tight) {
                            if p.changed {
                                Text(p.original.title).font(.caption).strikethrough().foregroundStyle(.secondary)
                                HStack(alignment: .firstTextBaseline, spacing: Theme.Space.iconGap) {
                                    Image(systemName: "arrow.turn.down.right").imageScale(.small).foregroundStyle(.secondary)
                                    Text(p.countsAsDone ? "\(p.original.title)（已完成）" : p.title)
                                }
                                .font(.subheadline.weight(.semibold))
                                Text(p.countsAsDone ? "计为完成" : "\(p.minutes) 分钟 · \(p.intensity.label)")
                                    .font(.footnote).foregroundStyle(.secondary)
                                ForEach(p.reasons, id: \.self) { r in
                                    Label(r, systemImage: "lightbulb").font(.footnote).foregroundStyle(.primary)
                                }
                            } else {
                                Text(p.title).font(.subheadline.weight(.semibold))
                                Text("\(p.minutes) 分钟 · \(p.intensity.label) · 保持原计划").font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, Theme.Space.tight)
                    }
                    if let swap = result.swapSuggestion { Callout(kind: .insight, text: swap) }
                    ForEach(result.notes, id: \.self) { Callout(kind: .info, text: $0) }
                } header: {
                    Text("建议的安排")
                } footer: {
                    Text("调整的目的是在当下状态里继续保持规律，而不是追求完成量。漏掉的训练不需要补回。")
                }

                if items.contains(where: \.wasAdjusted) {
                    Section {
                        Button("恢复原计划", role: .destructive) { restore(); dismiss() }
                    }
                }
            }
            .navigationTitle("调整今日安排")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("保持原计划") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("应用") { apply(result); dismiss() }.disabled(!result.anyChange).fontWeight(.semibold)
                }
            }
            .onAppear {
                guard !loaded else { return }
                loaded = true
                let r = DataHub.record(for: DayClock.logicalToday(.app, DayClock.current), in: ctx)
                soreness = r.soreness ?? 0
                area = r.sorenessArea
                energy = r.energy
                ill = r.illnessSymptoms
                available = r.availableMinutesToday
            }
        }
    }

    private var context: AdjustmentContext {
        var c = AdjustmentContext()
        c.readiness = readiness.score == nil ? nil : readiness
        c.availableMinutes = available
        c.soreness = soreness ?? 0
        c.sorenessArea = area
        c.energy = energy
        c.illness = ill
        c.urgentEventOpen = urgentOpen
        c.activeMinutesSoFar = max(0, (analytics.today?.activeMinutes ?? 0) - Double(items.compactMap(\.completedMinutes).reduce(0, +)))
        c.stepsSoFar = analytics.today?.steps ?? 0
        c.stepsTarget = analytics.profile.stepsTarget
        c.cardiacLimited = analytics.profile.cardiacLimited
        c.missedKeySessions = weekItems
            .filter { $0.day < DayClock.logicalToday(.app, DayClock.current) && $0.isKey && ($0.status == .planned || $0.status == .skipped) }
            .map(\.snapshot)
        return c
    }

    private func apply(_ result: AdjustmentResult) {
        let r = DataHub.record(for: DayClock.logicalToday(.app, DayClock.current), in: ctx)
        r.availableMinutesToday = available
        r.soreness = soreness; r.sorenessArea = area
        if energy != nil { r.energy = energy }
        if ill { r.illnessSymptoms = true; r.toggle(.illness, on: true) }
        for p in result.proposals where p.changed {
            guard let item = items.first(where: { $0.id == p.id }) else { continue }
            if item.originalTitle == nil {
                item.originalTitle = item.title
                item.originalMinutes = item.minutes
                item.originalIntensityRaw = item.intensityRaw
                item.originalKindRaw = item.kindRaw
            }
            item.adjustmentNote = p.reasons.joined(separator: " ")
            item.adjustedAt = .app
            if p.countsAsDone {
                item.status = .done
                item.completedMinutes = Int(context.activeMinutesSoFar)
            } else {
                item.title = p.title
                item.minutes = p.minutes
                item.intensity = p.intensity
                if p.kind != item.kind { item.kind = p.kind }
            }
        }
        try? ctx.save()
    }

    private func restore() {
        for item in items where item.wasAdjusted {
            if let t = item.originalTitle { item.title = t }
            if let m = item.originalMinutes { item.minutes = m }
            if let i = item.originalIntensityRaw { item.intensityRaw = i }
            if let k = item.originalKindRaw { item.kindRaw = k }
            item.adjustedAt = nil
            item.adjustmentNote = nil
            if item.status == .done && item.completedMinutes != item.minutes { item.status = .planned; item.completedMinutes = nil }
        }
        try? ctx.save()
    }
}
