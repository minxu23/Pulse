import SwiftUI
import SwiftData

/// 复查安排 on 化验结果: when each recheck is next due and why. Tapping one sets the date the doctor
/// gave; it is kept as a 照护与随访 task, which 今日 flags a week ahead and a newer result ticks off.
struct LabRecheckCard: View {
    let items: [LabRecheckItem]
    @Query(sort: \CareTask.createdAt, order: .reverse) private var tasks: [CareTask]
    @State private var editing: LabRecheckItem?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.item) {
            CardTitle("复查安排", detail: "按你的结果估算，以医生的安排为准")
            ForEach(items) { item in
                if item.id != items.first?.id { Divider().padding(.leading, Theme.Size.iconTile + Theme.Space.block) }
                Button { editing = item } label: { row(item, due: task(for: item)?.due ?? item.due) }
                    .buttonStyle(.plain)
                    .disabled(item.due == nil && task(for: item) == nil)
            }
        }
        .cardSurface()
        .sheet(item: $editing) { item in RecheckDateSheet(item: item, task: task(for: item)) }
    }

    /// The open task for this recheck: Pulse's own, or one the user or 复盘 added.
    private func task(for item: LabRecheckItem) -> CareTask? {
        tasks.first { !$0.done && $0.due != nil && LabRecheck.groups(inTitle: $0.title).contains(item.group) }
    }

    private func row(_ item: LabRecheckItem, due: Date?) -> some View {
        let now = Date.app
        let days = due.map { Calendar.pulse.dateComponents([.day], from: now.startOfDay, to: $0.startOfDay).day ?? 0 }
        let (tag, color): (String, Color) = switch days {
        case nil: ("还没有记录", .secondary)
        case let d? where d < 0: ("已到期", .orange)
        case 0?: ("今天", .orange)
        case let d? where d <= LabRecheck.taskLead: ("\(d) 天后", .primary)
        default: ("", .secondary)
        }
        return HStack(alignment: .top, spacing: Theme.Space.block) {
            IconTile(icon: "testtube.2", color: (days ?? 1) <= 0 ? .orange : .secondary)
            VStack(alignment: .leading, spacing: Theme.Space.hairline) {
                Text(item.title).font(.subheadline.weight(.semibold))
                Text(item.last.map { "上次 \($0.formatted(.dateTime.month().day())) · \(item.interval)" } ?? "记下最近一次的结果后，Pulse 帮你算下次的时间")
                    .font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if !item.tests.hasPrefix(item.name) {
                    Text(item.tests).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: Theme.Space.item)
            VStack(alignment: .trailing, spacing: Theme.Space.hairline) {
                if let due { Text(due.formatted(.dateTime.month().day())).font(.subheadline.weight(.semibold)).monospacedDigit() }
                if !tag.isEmpty { Text(tag).font(.footnote).foregroundStyle(color) }
            }
        }
        .frame(minHeight: Theme.Size.tap)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint(due == nil ? "" : "设置复查日期")
    }
}

/// The date of one recheck, as the doctor gave it.
private struct RecheckDateSheet: View {
    let item: LabRecheckItem
    let task: CareTask?
    @Environment(\.modelContext) private var ctx
    @Environment(\.dismiss) private var dismiss
    @State private var date: Date

    init(item: LabRecheckItem, task: CareTask?) {
        self.item = item
        self.task = task
        _date = State(initialValue: max(task?.due ?? item.due ?? Date.app.adding(days: 30), Date.app.startOfDay))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if !item.tests.hasPrefix(item.name) { Text(item.tests) }
                    Text("\(item.interval)（\(item.basis)）").foregroundStyle(.secondary)
                    if let last = item.last { LabeledContent("上次", value: last.formatted(.dateTime.year().month().day())) }
                }
                .font(.subheadline)
                Section {
                    DatePicker("复查日期", selection: $date, in: Date.app.startOfDay..., displayedComponents: .date)
                } footer: {
                    Text("医生给了日期就按医生的填。到期前一周，「今日 › 饮食与指标」会提醒你\(CareReminders.enabled ? "，手机也会通知你" : "（在「我的 › 提醒」打开后，手机也会通知）")；记下新的化验结果后，这项会自动完成。")
                }
            }
            .navigationTitle(item.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("保存") { save(); dismiss() }.fontWeight(.semibold) }
            }
            .calmStyle()
        }
        .pageMargins()
        .presentationDetents([.medium, .large])
    }

    private func save() {
        if let task {
            task.due = date
        } else {
            let t = CareTask(title: item.title, area: item.area, due: date, note: "\(item.interval)（\(item.basis)）")
            t.createdAt = .app
            ctx.insert(t)
        }
        try? ctx.save()
    }
}
