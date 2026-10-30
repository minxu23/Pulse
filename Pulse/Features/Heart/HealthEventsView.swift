import SwiftUI
import SwiftData

/// Abnormal events get independent attention and a follow-up trail (需求 8).
struct HealthEventsList: View {
    @Query(sort: \HealthEvent.createdAt, order: .reverse) private var events: [HealthEvent]
    @Query(sort: \CareTask.createdAt, order: .reverse) private var tasks: [CareTask]

    var body: some View {
        let active = events.filter { $0.status.isActive }.sorted { ($0.severity, $0.createdAt) > ($1.severity, $1.createdAt) }
        let closed = events.filter { !$0.status.isActive }
        List {
            Section {
                if active.isEmpty {
                    StatusLabel(text: "目前没有待处理的异常", icon: "checkmark.shield.fill", color: .green)
                }
                ForEach(active) { e in NavigationLink { HealthEventDetailView(event: e) } label: { EventRow(event: e) } }
            } header: {
                Text("待处理")
            } footer: {
                Text("出现这些提示时，先按建议复测或核实；需要专业处理的，请及时就医，并在这里记录结果。")
            }
            let openTasks = tasks.filter { !$0.done }
            if !openTasks.isEmpty {
                Section("照护与随访事项") {
                    ForEach(openTasks) { CareTaskRow(task: $0) }
                }
            }
            if !closed.isEmpty {
                Section("已处理") {
                    ForEach(closed) { e in NavigationLink { HealthEventDetailView(event: e) } label: { EventRow(event: e) } }
                }
            }
        }
    }
}

struct HealthEventsView: View {
    var body: some View {
        HealthEventsList().navigationTitle("异常与跟进").calmStyle()
    }
}

struct EventRow: View {
    let event: HealthEvent
    var body: some View {
        HStack(spacing: Theme.Space.block) {
            Image(systemName: event.kind.icon)
                .foregroundStyle(Theme.severity(event.severity))
                .frame(width: Theme.Size.iconTile, height: Theme.Size.iconTile)
                .background(Theme.severity(event.severity).opacity(0.12), in: Circle())
            VStack(alignment: .leading, spacing: Theme.Space.hairline) {
                Text(event.title).font(.subheadline.weight(.semibold))
                HStack(spacing: Theme.Space.tight) {
                    Text(event.severity.label)
                    Text("·")
                    Text(event.status.label)
                    Text("·")
                    Text(event.relatedDate.formatted(.dateTime.month().day()))
                }
                .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, Theme.Space.hairline)
    }
}

struct HealthEventDetailView: View {
    @Environment(\.modelContext) private var ctx
    @Bindable var event: HealthEvent
    @State private var note = ""
    @State private var addingTask = false

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: Theme.Space.item) {
                    StatusLabel(text: event.severity.label, icon: event.severity.icon, color: Theme.severity(event.severity))
                        .font(.subheadline.weight(.semibold))
                    Text(event.title).font(.title3.bold())
                    Text(event.detail).font(.subheadline)
                    Text("\(event.relatedDate.formatted(date: .abbreviated, time: .shortened))\(event.valueText.isEmpty ? "" : " · \(event.valueText)")")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .padding(.vertical, Theme.Space.tight)
            }
            Section("建议的处理") {
                Text(event.guidance).font(.subheadline)
                if event.severity == .urgent {
                    Link(destination: URL(string: "tel://120")!) {
                        Label("拨打 120", systemImage: "phone.fill").fontWeight(.semibold)
                    }
                    .foregroundStyle(.red)
                }
            }
            Section("处理状态") {
                Picker("状态", selection: Binding(get: { event.status }, set: { s in
                    event.status = s
                    event.log("状态更新为「\(s.label)」")
                })) {
                    ForEach(EventStatus.allCases) { Text($0.label).tag($0) }
                }
                Toggle("设置跟进日期", isOn: Binding(get: { event.followUpDue != nil }, set: { event.followUpDue = $0 ? .app.adding(days: 3) : nil }))
                if let due = event.followUpDue {
                    DatePicker("跟进日期", selection: Binding(get: { due }, set: { event.followUpDue = $0 }), displayedComponents: .date)
                }
                Button { addingTask = true } label: { Label("添加就诊 / 随访事项", systemImage: "calendar.badge.plus") }
            }
            Section("跟进记录") {
                ForEach(event.followUpLog.reversed(), id: \.self) { Text($0).font(.subheadline) }
                HStack {
                    TextField("如：复测 128/82；已预约心内科", text: $note)
                    Button("添加") {
                        event.log(note)
                        note = ""
                    }
                    .disabled(note.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            Section {
                Text("Pulse 的提示基于你记录或设备提供的数据，用于提醒你核实或寻求专业帮助，不构成诊断。").font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("异常详情").calmStyle()
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $addingTask) {
            AddCareTaskSheet(defaultTitle: "就诊：\(event.title)", area: area)
        }
    }

    private var area: CareArea {
        switch event.kind {
        case .glucoseLow, .glucoseHigh, .glucoseSevereLow: .diabetes
        case .spo2Low: .sleep
        case .bpHigh, .bpCrisis, .bpLow, .irregularRhythm, .rhrHigh, .rhrLow: .cardio
        default: .general
        }
    }
}

struct CareTaskRow: View {
    @Bindable var task: CareTask
    var body: some View {
        HStack(spacing: Theme.Space.block) {
            Button {
                task.done.toggle()
                task.doneAt = task.done ? .app : nil
            } label: {
                Image(systemName: task.done ? "checkmark.circle.fill" : "circle").font(.title3)
                    .foregroundStyle(task.done ? .green : .secondary)
                    .frame(width: Theme.Size.tap, height: Theme.Size.tap)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(task.done ? "标记为未完成" : "标记为完成")
            VStack(alignment: .leading, spacing: Theme.Space.hairline) {
                Text(task.title).font(.subheadline).strikethrough(task.done)
                HStack(spacing: Theme.Space.item) {
                    Label(task.area.label, systemImage: task.area.icon)
                    if let due = task.due {
                        if !task.done && due < .app {
                            Label("已逾期 \(due.formatted(.dateTime.month().day()))", systemImage: "exclamationmark.circle.fill")
                                .symbolRenderingMode(.multicolor)
                        } else {
                            Text("· \(due.formatted(.dateTime.month().day()))")
                        }
                    }
                }
                .font(.footnote).foregroundStyle(.secondary)
                .labelStyle(.inline)
                if !task.note.isEmpty { Text(task.note).font(.footnote).foregroundStyle(.secondary) }
            }
        }
    }
}

struct AddCareTaskSheet: View {
    @Environment(\.modelContext) private var ctx
    @Environment(\.dismiss) private var dismiss
    var defaultTitle = ""
    var area: CareArea = .general
    @State private var title = ""
    @State private var selectedArea: CareArea = .general
    @State private var hasDue = true
    @State private var due = Date.app.adding(days: 7)
    @State private var note = ""

    var body: some View {
        CalmNavigationStack {
            Form {
                TextField("事项", text: $title)
                Picker("类别", selection: $selectedArea) { ForEach(CareArea.allCases) { Label($0.label, systemImage: $0.icon).tag($0) } }
                Toggle("设定日期", isOn: $hasDue)
                if hasDue { DatePicker("日期", selection: $due, displayedComponents: .date) }
                TextField("备注（可选）", text: $note, axis: .vertical)
            }
            .navigationTitle("照护事项")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        ctx.insert(CareTask(title: title, area: selectedArea, due: hasDue ? due : nil, note: note))
                        dismiss()
                    }
                    .disabled(title.isEmpty)
                }
            }
            .onAppear { title = defaultTitle; selectedArea = area }
        }
        .presentationDetents([.medium])
    }
}
