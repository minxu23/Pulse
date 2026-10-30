import SwiftUI
import SwiftData

/// 持续记录、补充、修改和查看健康及运动历史 (需求 10).
struct HistoryView: View {
    @Environment(\.modelContext) private var ctx
    @Query(sort: \DailyRecord.day, order: .reverse) private var records: [DailyRecord]
    @State private var pickDate = false
    @State private var newDate = Date.app.adding(days: -1)
    @State private var openDate: IdentifiedDate?

    var body: some View {
        let grouped = Dictionary(grouping: records, by: { Calendar.pulse.dateInterval(of: .month, for: $0.day)!.start })
        List {
            Section {
                Button { pickDate = true } label: { Label("补记某一天", systemImage: "calendar.badge.plus") }
            }
            ForEach(grouped.keys.sorted(by: >), id: \.self) { month in
                Section(month.formatted(.dateTime.year().month(.wide))) {
                    ForEach(grouped[month]!) { r in
                        NavigationLink { DayEditorView(record: r) } label: { DayRow(r: r) }
                    }
                    .onDelete { idx in
                        let list = grouped[month]!
                        for i in idx { ctx.delete(list[i]) }
                    }
                }
            }
        }
        .navigationTitle("记录历史").calmStyle()
        .sheet(isPresented: $pickDate) {
            CalmNavigationStack {
                Form { DatePicker("日期", selection: $newDate, in: ...Date.app, displayedComponents: .date).datePickerStyle(.graphical) }
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("打开") {
                                _ = DataHub.record(for: newDate, in: ctx)
                                pickDate = false
                                openDate = IdentifiedDate(date: newDate.startOfDay)
                            }
                        }
                    }
            }
            .presentationDetents([.medium, .large])
        }
        .navigationDestination(item: $openDate) { d in
            if let r = records.first(where: { $0.day == d.date }) { DayEditorView(record: r) }
        }
    }
}

struct DayRow: View {
    let r: DailyRecord
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: Theme.Space.hairline) {
                Text(r.day.formatted(.dateTime.month().day().weekday())).font(.subheadline.weight(.medium))
                // Inline glyphs inside the row's own content (the row label itself keeps the List style).
                HStack(spacing: Theme.Space.item) {
                    if let h = r.restingHR { Label("\(h.noDecimal)", systemImage: "heart.fill") }
                    if let s = r.sleepMinutes { Label((s / 60).oneDecimal, systemImage: "bed.double.fill") }
                    if let st = r.steps { Label("\(st)", systemImage: "figure.walk") }
                }
                .font(.caption).labelStyle(.inline)
            }
            Spacer()
            HStack(spacing: Theme.Space.tight) {
                ForEach(Array(r.tags).prefix(4)) { Image(systemName: $0.icon).font(.caption2).foregroundStyle(.secondary) }
                if !r.manualFields.isEmpty { Image(systemName: "pencil").font(.caption2).foregroundStyle(.secondary) }
            }
        }
    }
}

struct DayEditorView: View {
    @Environment(\.modelContext) private var ctx
    @Bindable var record: DailyRecord
    @Query(sort: \ActivitySession.start) private var sessions: [ActivitySession]
    @Query(sort: \VitalReading.time) private var vitals: [VitalReading]
    @State private var addWorkout = false

    var body: some View {
        let daySessions = sessions.filter { $0.day == record.day }
        let dayVitals = vitals.filter { $0.time.startOfDay == record.day && $0.source != .cgm && !($0.source == .demo && $0.kind == .glucose) }
        Form {
            Section("静息心率与恢复") {
                numberRow("静息心率", Binding(get: { record.restingHR }, set: { record.restingHR = $0; record.markManual("restingHR"); if record.rhrSource == nil { record.rhrSource = .manual } }), "bpm")
                Picker("测量方式", selection: Binding(get: { record.rhrSource ?? .manual }, set: { record.rhrSource = $0 })) {
                    ForEach(RHRSource.allCases) { Text($0.label).tag($0) }
                }
                numberRow("HRV", $record.hrv, "ms")
                ratingRow("精力", $record.energy, 1...5)
                ratingRow("酸痛", $record.soreness, 0...3)
                ratingRow("压力", $record.stress, 1...5)
                Toggle("生病 / 不适", isOn: $record.illnessSymptoms)
            }
            Section("睡眠") {
                numberRow("睡眠时长", Binding(get: { record.sleepMinutes.map { $0 / 60 } }, set: { record.sleepMinutes = $0.map { $0 * 60 }; record.markManual("sleep") }), "小时", 1)
                Toggle("打鼾", isOn: $record.snoring)
                Toggle("憋醒", isOn: $record.gasping)
                Toggle("被观察到呼吸暂停", isOn: $record.witnessedApnea)
                numberRow("CPAP 使用", $record.cpapHours, "小时", 1)
            }
            Section("活动与行为") {
                numberRow("步数", Binding(get: { record.steps.map(Double.init) }, set: { record.steps = $0.map { Int($0) }; record.markManual("steps") }), "步")
                numberRow("运动分钟", $record.exerciseMinutes, "分钟")
                Stepper("饮酒 \(record.alcoholUnits.oneDecimal) 单位", value: $record.alcoholUnits, in: 0...20, step: 0.5)
                Stepper("咖啡因 \(record.caffeineCups) 杯", value: $record.caffeineCups, in: 0...12)
                Stepper("饮水 \(record.waterMl) ml", value: $record.waterMl, in: 0...5000, step: 250)
                Toggle("晚餐过晚", isOn: $record.lateMeal)
            }
            Section("状况标签") {
                FlowLayout(spacing: Theme.Space.item) {
                    ForEach(ContextTag.allCases) { t in
                        ToggleChip(text: t.label, icon: t.icon, isOn: Binding(get: { record.tags.contains(t) }, set: { record.toggle(t, on: $0) }))
                    }
                }
                .padding(.vertical, Theme.Space.tight)
            }
            Section {
                ForEach(daySessions) { s in
                    HStack {
                        Label("\(s.type.label) \(Int(s.minutes)) 分钟", systemImage: s.type.icon)
                        Spacer()
                        Text("RPE \(s.rpe ?? s.type.defaultRPE) · \(s.source.label)").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .onDelete { idx in for i in idx { ctx.delete(daySessions[i]) } }
                Button { addWorkout = true } label: { Label("添加运动", systemImage: "plus") }
            } header: { Text("运动") }
            if !dayVitals.isEmpty {
                Section("指标") {
                    ForEach(dayVitals) { VitalRow(v: $0) }
                        .onDelete { idx in for i in idx { ctx.delete(dayVitals[i]) } }
                }
            }
            Section("备注") {
                TextField("当天的情况", text: $record.dayNote, axis: .vertical)
            }
            if !record.manualFields.isEmpty {
                Section {
                    Button("恢复由设备同步的数值") { record.manualFields = [] }
                } footer: {
                    Text("手动修改过的字段（\(record.manualFields.count) 项）不会被设备同步覆盖。")
                }
            }
        }
        .navigationTitle(record.day.formatted(.dateTime.month().day().weekday())).calmStyle()
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $addWorkout) { QuickLogSheet(kind: .workout, date: record.day) }
    }

    private func numberRow(_ title: String, _ b: Binding<Double?>, _ unit: String, _ decimals: Int = 0) -> some View {
        HStack {
            Text(title)
            Spacer()
            TextField("—", text: b.text(decimals: decimals)).keyboardType(decimals > 0 ? .decimalPad : .numberPad)
                .multilineTextAlignment(.trailing).frame(width: 90)
            Text(unit).foregroundStyle(.secondary).frame(width: 40, alignment: .leading)
        }
    }

    private func ratingRow(_ title: String, _ b: Binding<Int?>, _ range: ClosedRange<Int>) -> some View {
        Picker(title, selection: b) {
            Text("—").tag(Int?.none)
            ForEach(Array(range), id: \.self) { Text("\($0)").tag(Int?.some($0)) }
        }
    }
}
