import SwiftUI
import SwiftData

/// 睡前记录: fatigue, soreness, stress, caffeine and tonight's sleep arrangement. A bedtime
/// blood pressure / glucose reading pairs with tomorrow morning's to show the overnight trend.
struct EveningCheckInView: View {
    @Environment(\.modelContext) private var ctx
    @Environment(\.dismiss) private var dismiss
    @Query private var profiles: [UserProfile]

    @State private var fatigue: Int? = nil
    @State private var soreness: Int? = nil
    @State private var area: SorenessArea = .none
    @State private var stress: Int? = nil
    @State private var cups = 0
    @State private var lastCaffeine = 9
    @State private var alcohol = 0.0
    @State private var bedtime = Date.app
    @State private var wake = Date.app
    @State private var plan = ""
    @State private var log: QuickLogKind?

    var body: some View {
        let p = profiles.first
        CalmNavigationStack {
            Form {
                Section("今天的身体感受") {
                    labeled("疲劳程度") { RatingPicker(value: $fatigue, lowLabel: "精神很好", highLabel: "非常疲劳") }
                    labeled("肌肉酸痛") { RatingPicker(value: $soreness, range: 0...3, labels: ["无", "轻微", "明显", "严重"]) }
                    if (soreness ?? 0) >= 1 {
                        Picker("主要部位", selection: $area) { ForEach(SorenessArea.allCases) { Text($0.label).tag($0) } }
                    }
                    labeled("压力") { RatingPicker(value: $stress, lowLabel: "很放松", highLabel: "压力很大") }
                }
                Section {
                    Stepper("咖啡 / 茶 \(cups) 杯", value: $cups, in: 0...12)
                    if cups > 0 {
                        Picker("最后一杯", selection: $lastCaffeine) { ForEach(6...23, id: \.self) { Text("\($0):00 左右").tag($0) } }
                    }
                    Stepper("今天饮酒 \(alcohol.oneDecimal) 单位", value: $alcohol, in: 0...20, step: 0.5)
                } header: { Text("咖啡因与饮酒") }

                Section {
                    DatePicker("计划上床", selection: $bedtime, displayedComponents: .hourAndMinute)
                    DatePicker("计划起床", selection: $wake, displayedComponents: .hourAndMinute)
                    let short = planMinutes < Int((p?.sleepNeedHours ?? 7.5) * 60) - 30
                    StatusLabel(short ? .attention("计划睡眠约 \((Double(planMinutes) / 60).oneDecimal) 小时，少于目标 \(p.map { $0.sleepNeedHours.oneDecimal } ?? "7.5") 小时")
                                : .good("计划睡眠约 \((Double(planMinutes) / 60).oneDecimal) 小时（目标 \(p.map { $0.sleepNeedHours.oneDecimal } ?? "7.5") 小时）"))
                        .font(.footnote)
                    TextField(p?.apneaTreatment == .cpap ? "如：整晚使用 CPAP、侧卧睡" : "如：侧卧睡、睡前不看手机", text: $plan)
                } header: { Text("睡眠安排") }

                Section {
                    Button { log = .bloodPressure } label: { Label("测量睡前血压", systemImage: "gauge.with.dots.needle.33percent") }
                    if p?.hasModule(.diabetesCare) == true || p?.conditions.contains(where: \.isDiabetes) == true {
                        Button { log = .glucose } label: { Label("记录睡前血糖", systemImage: "drop.fill") }
                    }
                } header: {
                    Text("睡前指标（可选）")
                } footer: {
                    Text("睡前与明早的测量配对，可以看到夜间血压、血糖的变化。")
                }
            }
            .navigationTitle("睡前记录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("保存") { save() }.fontWeight(.semibold) }
            }
            .onAppear(perform: load)
            .sheet(item: $log) { QuickLogSheet(kind: $0) }
        }
    }

    private var planMinutes: Int { (wake.minutesOfDay - bedtime.minutesOfDay + 1440) % 1440 }

    private func labeled<C: View>(_ title: String, @ViewBuilder _ c: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline.weight(.medium))
            c()
        }
        .padding(.vertical, 4)
    }

    private func load() {
        let r = DataHub.record(for: DayClock.logicalToday(.app, DayClock.current), in: ctx)
        let p = profiles.first
        fatigue = r.eveningFatigue
        soreness = r.eveningSoreness ?? r.soreness
        area = r.sorenessArea
        stress = r.eveningStress ?? r.stress
        cups = r.caffeineCups
        lastCaffeine = r.lastCaffeineHour ?? 9
        alcohol = r.alcoholUnits
        let window = DayClock.window(for: DayClock.logicalToday(.app, DayClock.current), profile: DayClock.current)
        bedtime = r.plannedBedtime ?? window.bed
        wake = r.plannedWake ?? window.nextWake
        plan = r.sleepPlanNote
    }

    private func save() {
        let r = DataHub.record(for: DayClock.logicalToday(.app, DayClock.current), in: ctx)
        let cutoff = profiles.first?.caffeineCutoffHour ?? 14
        r.eveningCheckInAt = .app
        r.eveningFatigue = fatigue
        r.eveningSoreness = soreness
        r.sorenessArea = area
        r.eveningStress = stress
        r.toggle(.highStress, on: (stress ?? 0) >= 4 || (r.stress ?? 0) >= 4)
        r.caffeineCups = cups
        r.lastCaffeineHour = cups > 0 ? lastCaffeine : nil
        r.toggle(.lateCaffeine, on: cups > 0 && lastCaffeine >= cutoff)
        r.alcoholUnits = alcohol
        r.toggle(.alcohol, on: alcohol > 0)
        // A bedtime after midnight belongs to the following calendar day.
        let bedMin = bedtime.minutesOfDay
        let day = DayClock.logicalToday(.app, DayClock.current)
        r.plannedBedtime = day.adding(days: bedMin < 12 * 60 ? 1 : 0).adding(minutes: bedMin)
        r.plannedWake = day.adding(days: 1).adding(minutes: wake.minutesOfDay)
        r.sleepPlanNote = plan
        try? ctx.save()
        dismiss()
    }
}
