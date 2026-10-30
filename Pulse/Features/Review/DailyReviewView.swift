import SwiftUI
import SwiftData

// 每日回顾 and the priorities that steer 复盘. A day is read against what the user cares about
// most (their own order, or Pulse's from conditions, goals and recent data); the note and the
// 「完成回顾」 mark are the same as on 今日 › 全天回顾, so either place can be used.

/// 每日回顾 as a month calendar: each day tinted by how it went for the user's priorities (顺利 ·
/// 平稳 · 有起伏 · 需留意), a dot for training; tapping a day opens its review.
struct DailyReviewSection: View {
    let context: AgentContext
    var onAsk: (String?, Bool) -> Void
    @Query private var profiles: [UserProfile]
    @State private var month: Date?

    var body: some View {
        let today = context.logicalToday
        let pr = ReviewPriorities.ranked(context, mine: profiles.first?.reviewPriorities ?? [])
        // As far back as the records the agent reads (60 days of readings) reach.
        let earliest = max(context.days.first?.day ?? today, today.adding(days: -59)).monthStart
        let shown = month ?? today.monthStart
        let days = (0..<shown.daysInMonth).map { shown.adding(days: $0) }
        let verdicts = Dictionary(uniqueKeysWithValues: days.filter { $0 <= today && $0 >= earliest }.map {
            ($0, ReviewPriorities.verdict(on: $0, context: context, priorities: pr))
        })

        VStack(alignment: .leading, spacing: Theme.Space.block) {
            HStack {
                Button { month = shown.adding(months: -1) } label: {
                    Image(systemName: "chevron.left").frame(width: Theme.Size.tap, height: Theme.Size.tap).contentShape(Rectangle())
                }
                .disabled(shown <= earliest).accessibilityLabel("上个月")
                Spacer()
                Text(shown.formatted(.dateTime.year().month(.wide))).font(.headline)
                Spacer()
                Button { month = shown.adding(months: 1) } label: {
                    Image(systemName: "chevron.right").frame(width: Theme.Size.tap, height: Theme.Size.tap).contentShape(Rectangle())
                }
                .disabled(shown >= today.monthStart).accessibilityLabel("下个月")
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Theme.Space.item), count: 7), spacing: Theme.Space.item) {
                ForEach(["一", "二", "三", "四", "五", "六", "日"], id: \.self) { w in
                    Text(w).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                }
                ForEach(0..<PlanGenerator.order(shown.weekday), id: \.self) { _ in Color.clear.frame(height: 1) }
                ForEach(days, id: \.self) { d in
                    if let v = verdicts[d] {
                        NavigationLink {
                            DayReviewPage(context: context, day: d, earliest: earliest, onAsk: onAsk)
                        } label: {
                            DayCell(date: d, verdict: v, isToday: d == today)
                        }
                        .buttonStyle(.plain)
                    } else {
                        DayCell(date: d, verdict: nil, isToday: false).opacity(d > today ? 0.35 : 0.6)
                            .accessibilityLabel("\(d.formatted(.dateTime.month().day()))，\(d > today ? "还没到" : "没有记录")")
                    }
                }
            }
            Text(ReviewPriorities.monthSummary(verdicts.values.map(\.level))).font(.subheadline).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            CalendarLegend()
        }
        .cardSurface()

        PrioritiesCard(context: context)
        PageFootnote("颜色按你最在意的几件事和当天早上的身体状态来定；点开一天看全天回顾、写笔记。")
    }
}

/// One day in the calendar: the date, the level's glyph (colour is never the only cue) and a dot
/// for a day with training.
private struct DayCell: View {
    let date: Date
    let verdict: DayVerdict?
    let isToday: Bool

    var body: some View {
        let level = verdict?.level
        VStack(spacing: Theme.Space.tight) {
            Text("\(Calendar.pulse.component(.day, from: date))").font(.subheadline.weight(isToday ? .bold : .medium)).monospacedDigit()
            Image(systemName: level?.icon ?? "minus").font(.caption2.weight(.bold))
                .foregroundStyle(level.map(DayLevelStyle.glyph) ?? Color.secondary.opacity(verdict == nil ? 0 : 0.6))
        }
        .frame(maxWidth: .infinity, minHeight: 48)
        .background(level.map(DayLevelStyle.fill) ?? Theme.subtle.opacity(verdict == nil ? 0.5 : 1), in: RoundedRectangle(cornerRadius: Theme.Radius.inner, style: .continuous))
        .overlay {
            if isToday { RoundedRectangle(cornerRadius: Theme.Radius.inner, style: .continuous).strokeBorder(Color.primary, lineWidth: 2) }
        }
        .overlay(alignment: .topTrailing) {
            if verdict?.trained == true { Circle().fill(Color.primary).frame(width: 5, height: 5).padding(5) }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
    }

    private var label: String {
        var t = date.formatted(.dateTime.month().day().weekday(.wide))
        if isToday { t += "，今天" }
        if let l = verdict?.level { t += "，\(l.label)：\(l.meaning)" } else { t += "，记录不多" }
        if verdict?.trained == true { t += "，有训练" }
        return t
    }
}

enum DayLevelStyle {
    static func fill(_ l: DayLevel) -> Color {
        switch l {
        case .smooth: Color.green.opacity(0.32)
        case .steady: Color.green.opacity(0.12)
        case .mixed: Color.orange.opacity(0.22)
        case .watch: Color.red.opacity(0.18)
        }
    }
    static func glyph(_ l: DayLevel) -> Color {
        switch l {
        case .smooth: .green
        case .steady: .secondary
        case .mixed: .orange
        case .watch: .red
        }
    }
}

private struct CalendarLegend: View {
    var body: some View {
        // Entries a block apart, so each swatch reads with its own word.
        FlowLayout(spacing: Theme.Space.block) {
            ForEach(DayLevel.allCases, id: \.self) { l in
                HStack(spacing: Theme.Space.iconGap) {
                    RoundedRectangle(cornerRadius: Theme.Radius.mark, style: .continuous).fill(DayLevelStyle.fill(l)).frame(width: 14, height: 14)
                        .overlay(Image(systemName: l.icon).font(.system(size: 7, weight: .bold)).foregroundStyle(DayLevelStyle.glyph(l)))
                    Text(l.label).font(.footnote)
                }
            }
            HStack(spacing: Theme.Space.iconGap) {
                Circle().fill(Color.primary).frame(width: 5, height: 5)
                Text("有训练").font(.footnote)
            }
        }
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }
}

/// 全天回顾 for one day: how it went, the morning, each priority, the note; ‹ › for the days around it.
struct DayReviewPage: View {
    let context: AgentContext
    @State var day: Date
    let earliest: Date
    var onAsk: (String?, Bool) -> Void
    @Query private var profiles: [UserProfile]
    @Query(sort: \DailyRecord.day) private var records: [DailyRecord]

    var body: some View {
        let today = context.logicalToday
        let pr = ReviewPriorities.ranked(context, mine: profiles.first?.reviewPriorities ?? [])
        let v = ReviewPriorities.verdict(on: day, context: context, priorities: pr)
        let d = context.days.first { $0.day == day }
        let top = Array(v.lines.prefix(3)), more = Array(v.lines.dropFirst(3))
        let offset = today.daysSince(day)
        ScreenScroll {
            WeekSwitcher(title: day.formatted(.dateTime.month().day().weekday(.wide)),
                         subtitle: offset == 0 ? "今天" : (offset == 1 ? "昨天" : "\(offset) 天前"),
                         canGoForward: day < today,
                         onPrev: { if day > earliest { day = day.adding(days: -1) } }, onNext: { if day < today { day = day.adding(days: 1) } })

            VStack(alignment: .leading, spacing: Theme.Space.block) {
                if let l = v.level {
                    Label(l.label, systemImage: l.icon)
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, Theme.Space.item).padding(.vertical, Theme.Space.tight)
                        .background(DayLevelStyle.fill(l), in: Capsule())
                }
                Text(ReviewPriorities.dayHeadline(top, isToday: offset == 0))
                    .font(.title3.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                HStack(alignment: .top, spacing: Theme.Space.block) {
                    stat("准备度", v.readiness?.score.map(String.init) ?? "—", v.readiness?.level.label ?? "没有晨起数据")
                    stat("睡眠", d?.sleepMinutes.map { ($0 / 60).oneDecimal } ?? "—", d?.sleepMinutes == nil ? "没有记录" : "小时")
                    stat("静息心率", d?.rhr.map { $0.noDecimal } ?? "—", d?.rhr == nil ? "没有记录" : "bpm")
                    stat("训练", v.trained ? "有" : "无", d.map { $0.activeMinutes > 0 ? "活动 \(Int($0.activeMinutes)) 分钟" : "" } ?? "")
                }
            }
            .cardSurface()

            VStack(alignment: .leading, spacing: Theme.Space.block) {
                CardTitle("你最在意的几件事")
                ForEach(top) { DayLineRow(line: $0) }
                if !more.isEmpty {
                    Divider()
                    ForEach(more) { DayLineRow(line: $0, compact: true) }
                }
            }
            .cardSurface()

            if let r = records.first(where: { $0.day == day }) {
                DayNoteCard(record: r, isToday: offset == 0)
            }

            if offset == 0 {
                Button { onAsk("总结一下今天，明天要注意什么？", false) } label: {
                    NavRowLabel(icon: "sparkles", color: .purple, title: AgentNameSettings.shared.phrase("问问"), detail: "今天的数据说明了什么、明天要注意什么")
                }
                .buttonStyle(.plain)
                .cardSurface()
            }
        }
        .navigationTitle("全天回顾")
        .navigationBarTitleDisplayMode(.inline)
        .calmStyle()
    }

    private func stat(_ label: String, _ value: String, _ sub: String) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.hairline) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(.title3, design: .rounded).weight(.semibold)).monospacedDigit()
            Text(sub).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

private struct DayLineRow: View {
    let line: DayLine
    var compact = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.block) {
            Image(systemName: line.area.icon).font(.subheadline).foregroundStyle(.secondary).frame(width: Theme.Size.iconTile)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Theme.Space.tight) {
                Text(line.area.label).font(compact ? .subheadline : .subheadline.weight(.semibold))
                StatusLabel(status, secondaryText: true).font(.subheadline).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private var status: MetricStatus {
        switch line.tone {
        case .good: .good(line.text)
        case .attention: .attention(line.text)
        case .neutral: .neutral(line.text)
        }
    }
}

/// The day's note and the 「完成回顾」 mark (shared with 今日 › 全天回顾).
private struct DayNoteCard: View {
    @Bindable var record: DailyRecord
    let isToday: Bool
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.block) {
            CardTitle(title: isToday ? "今天的笔记" : "这天的笔记") {
                if record.reviewedAt != nil {
                    StatusLabel(text: "已回顾", icon: "checkmark.seal.fill", color: .green).font(.subheadline.weight(.semibold))
                }
            }
            TextField(isToday ? "今天感觉如何？有什么影响了你的状态？" : "那天发生了什么？补记一下也有用", text: $record.dayNote, axis: .vertical)
                .focused($focused)
                .lineLimit(3...6)
                .padding(Theme.Space.block)
                .background(Theme.subtle.opacity(0.6), in: RoundedRectangle(cornerRadius: Theme.Radius.inner, style: .continuous))
            Button {
                record.reviewedAt = .app
                focused = false
            } label: {
                Label(record.reviewedAt == nil ? "完成回顾" : "更新回顾", systemImage: "checkmark").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).controlSize(.large)
        }
        .cardSurface()
    }
}

// MARK: - Priorities

/// What 复盘 is ordered by, why, and a way to change it.
struct PrioritiesCard: View {
    let context: AgentContext
    @Query private var profiles: [UserProfile]
    @State private var editing = false

    var body: some View {
        let mine = profiles.first?.reviewPriorities ?? []
        let pr = Array(ReviewPriorities.ranked(context, mine: mine).prefix(3))
        let hint = ReviewPriorities.suggestion(context, mine: mine)
        VStack(alignment: .leading, spacing: Theme.Space.block) {
            CardTitle(title: "你的优先事项") {
                Button { editing = true } label: {
                    Text("调整").frame(minHeight: Theme.Size.tap).contentShape(Rectangle())
                }
                .font(.subheadline)
            }
            ForEach(Array(pr.enumerated()), id: \.element.id) { i, p in
                HStack(alignment: .firstTextBaseline, spacing: Theme.Space.block) {
                    Text("\(i + 1)").font(.footnote.weight(.bold)).monospacedDigit()
                        .frame(width: 24, height: 24).background(Theme.subtle, in: Circle())
                    VStack(alignment: .leading, spacing: Theme.Space.hairline) {
                        Text(p.area.label).font(.subheadline.weight(.semibold))
                        Text(p.reason).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .accessibilityElement(children: .combine)
            }
            if let h = hint, let profile = profiles.first {
                HStack(alignment: .firstTextBaseline) {
                    StatusLabel(.attention("最近\(h.area.label)需要留意：\(h.reason)")).font(.subheadline).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: Theme.Space.item)
                    Button("加入") { profile.reviewPriorities = Array(mine.prefix(2)) + [h.area] + mine.dropFirst(2) }
                        .buttonStyle(.bordered).font(.subheadline)
                }
            }
            Text(mine.isEmpty ? "按你的病情、目标和最近的数据自动排列，数据变了顺序也会跟着变。复盘的数据、建议和问题按这个顺序排。"
                              : "按你设定的顺序。复盘的数据、建议和问题按这个顺序排。")
                .font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .cardSurface()
        .sheet(isPresented: $editing) {
            if let profile = profiles.first {
                PrioritiesEditor(profile: profile, auto: ReviewPriorities.ranked(context).map(\.area))
            }
        }
    }
}

/// Choose and order the priorities, or go back to Pulse's automatic order.
private struct PrioritiesEditor: View {
    @Bindable var profile: UserProfile
    let auto: [PriorityArea]
    @Environment(\.dismiss) private var dismiss
    @State private var chosen: [PriorityArea] = []

    var body: some View {
        CalmNavigationStack {
            List {
                Section {
                    ForEach(chosen) { a in
                        Label(a.label, systemImage: a.icon)
                    }
                    .onMove { chosen.move(fromOffsets: $0, toOffset: $1) }
                    .onDelete { chosen.remove(atOffsets: $0) }
                    if chosen.isEmpty { Text("还没有选择").foregroundStyle(.secondary) }
                } header: {
                    Text("按重要程度排列")
                } footer: {
                    Text("拖动调整顺序，左滑移除。前 3 项会排在复盘的最前面。")
                }
                let rest = PriorityArea.allCases.filter { !chosen.contains($0) }
                if !rest.isEmpty {
                    Section("可以加入") {
                        ForEach(rest) { a in
                            Button { chosen.append(a) } label: {
                                HStack {
                                    Label(a.label, systemImage: a.icon).foregroundStyle(.primary)
                                    Spacer()
                                    Image(systemName: "plus.circle.fill").foregroundStyle(Theme.accent)
                                }
                            }
                            .accessibilityLabel("加入\(a.label)")
                        }
                    }
                }
                Section {
                    Button("恢复自动排列") {
                        profile.reviewPriorities = []
                        dismiss()
                    }
                } footer: {
                    Text("自动排列按你的病情、目标和最近的数据：哪方面最近不太好就往前排，稳定了就往后。")
                }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle("调整优先事项")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        profile.reviewPriorities = chosen
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
        .onAppear { chosen = profile.reviewPriorities.isEmpty ? Array(auto.prefix(3)) : profile.reviewPriorities }
    }
}
