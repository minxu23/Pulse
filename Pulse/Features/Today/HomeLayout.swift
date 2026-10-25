import SwiftUI

/// The cards the home page can show. The user orders them and adds or removes them; module cards
/// are offered only when that module is on. Health alerts are not a card: they always stay on top.
enum HomeCard: String, CaseIterable, Identifiable {
    case state, now, glucose, bloodPressure, race, phases, week
    var id: String { rawValue }

    var title: String {
        switch self {
        case .state: "今日状态"
        case .now: "现在"
        case .glucose: "血糖"
        case .bloodPressure: "血压"
        case .race: "专项运动"
        case .phases: "全天安排"
        case .week: "本周进度"
        }
    }
    var detail: String {
        switch self {
        case .state: "身体准备度、静息心率和今日建议"
        case .now: "当前时段最该做的一件事"
        case .glucose: "血糖、未来 1 小时的变化和异常提醒"
        case .bloodPressure: "最近一次血压、近 7 天平均和异常提醒"
        case .race: "距比赛的周数、阶段和本周跑量"
        case .phases: "从起床到入睡的阶段入口"
        case .week: "本周训练次数和活动时长"
        }
    }
    var icon: String {
        switch self {
        case .state: "gauge.with.needle"
        case .now: "clock"
        case .glucose: "drop.fill"
        case .bloodPressure: "heart.text.square.fill"
        case .race: "flag.checkered"
        case .phases: "square.grid.2x2"
        case .week: "calendar"
        }
    }
    var color: Color {
        switch self {
        case .state: .green
        case .now: Theme.accent
        case .glucose: Theme.glucose
        case .bloodPressure: Theme.heartData
        case .race, .week: Theme.activity
        case .phases: .secondary
        }
    }
    /// The module a card needs.
    var module: ProModule? {
        switch self {
        case .glucose: .diabetesCare
        case .bloodPressure: .cardioCare
        case .race: .marathon
        default: nil
        }
    }
    /// Shown until the user removes it (otherwise it waits under 「可添加的卡片」).
    var shownByDefault: Bool { self != .week }
    /// A small tile, the size of the 全天安排 tiles; tiles next to each other share a row.
    var isTile: Bool { self == .glucose || self == .bloodPressure }
}

/// The home page's cards in the user's order, kept on this device.
enum HomeLayout {
    static let orderKey = "home.cards"
    static let seenKey = "home.cards.seen"

    static func available(_ p: UserProfile?) -> [HomeCard] {
        HomeCard.allCases.filter { c in
            guard let m = c.module else { return true }
            return p?.hasModule(m) == true && (c != .race || p?.raceDate != nil)
        }
    }

    /// The cards to show. A card never laid out before (a module just turned on) joins at its
    /// default place; cards the user removed stay away.
    static func visible(order: String, seen: String, available: [HomeCard]) -> [HomeCard] {
        let seenSet = Set(seen.split(separator: ",").map(String.init))
        var out = order.split(separator: ",").compactMap { HomeCard(rawValue: String($0)) }.filter(available.contains)
        for c in available where !seenSet.contains(c.rawValue) && c.shownByDefault && !out.contains(c) {
            // After the nearest earlier card in the default order that is shown.
            let before = HomeCard.allCases.prefix { $0 != c }.reversed()
            let at = before.lazy.compactMap { b in out.firstIndex(of: b) }.first.map { $0 + 1 } ?? 0
            out.insert(c, at: at)
        }
        return out
    }

    static func encode(_ cards: [HomeCard]) -> String { cards.map(\.rawValue).joined(separator: ",") }

    /// Rows to lay out: a card on its own, or up to two tiles that follow each other.
    static func rows(_ cards: [HomeCard]) -> [[HomeCard]] {
        var out: [[HomeCard]] = []
        for c in cards {
            if c.isTile, let last = out.last, last.count == 1, last[0].isTile { out[out.count - 1].append(c) } else { out.append([c]) }
        }
        return out
    }
}

/// 编辑首页, in place of the cards: drag to reorder, remove, and add back what is not shown.
struct HomeEditor: View {
    @Binding var cards: [HomeCard]
    let available: [HomeCard]
    var onDone: () -> Void

    var body: some View {
        let hidden = available.filter { !cards.contains($0) }
        List {
            Section {
                ForEach(cards) { c in row(c) }
                    .onMove { cards.move(fromOffsets: $0, toOffset: $1) }
                    .onDelete { cards.remove(atOffsets: $0) }
            } header: {
                Text("首页卡片")
            } footer: {
                Text("按住右侧的 \(Image(systemName: "line.3.horizontal")) 拖动调整顺序；点 \(Image(systemName: "minus.circle.fill")) 从首页移除。健康提醒始终显示在最上方。")
            }
            if !hidden.isEmpty {
                Section("可添加的卡片") {
                    ForEach(hidden) { c in
                        Button {
                            withAnimation { cards.append(c) }
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "plus.circle.fill").font(.title3).foregroundStyle(.green)
                                    .accessibilityHidden(true)
                                row(c)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("添加「\(c.title)」")
                    }
                }
            }
        }
        .environment(\.editMode, .constant(.active))
        .navigationTitle("编辑首页")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("完成", action: onDone).fontWeight(.semibold) }
        }
    }

    private func row(_ c: HomeCard) -> some View {
        HStack(spacing: 12) {
            Image(systemName: c.icon).font(.body.weight(.semibold)).foregroundStyle(c.color)
                .frame(width: 32, height: 32).background(c.color.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(c.title).font(.body)
                Text(c.detail).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

/// 本周进度: trainings done this week and active minutes against the weekly target.
struct WeekProgressCard: View {
    let data: TodayData

    var body: some View {
        let trainings = data.weekItems.filter { $0.kind.isTraining }
        let done = trainings.filter { $0.status == .done || $0.status == .partial }.count
        let minutes = data.weekItems.filter { $0.status == .done || $0.status == .partial }
            .map { $0.completedMinutes ?? $0.minutes }.reduce(0, +)
        let target = data.p.weeklyTargetMinutes
        NavigationLink { WeeklyPlanView().navigationTitle("运动计划").navigationBarTitleDisplayMode(.inline).calmStyle() } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("本周进度", systemImage: "calendar").font(.headline).labelStyle(.titleAndIcon)
                    Spacer()
                    Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                }
                HStack(alignment: .firstTextBaseline, spacing: 16) {
                    stat("训练", "\(done)/\(trainings.count)", "次")
                    stat("活动", "\(minutes)/\(target)", "分钟")
                }
                ProgressBar(value: Double(minutes) / Double(max(1, target)), color: Theme.activity, height: 6)
            }
            .cardSurface()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func stat(_ label: String, _ value: String, _ unit: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value).font(.system(.title3, design: .rounded).weight(.semibold)).monospacedDigit()
                Text(unit).font(.footnote).foregroundStyle(.secondary)
            }
        }
    }
}
