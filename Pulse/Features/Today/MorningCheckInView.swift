import SwiftUI
import SwiftData

/// 20-second morning check-in: how the user feels on waking, plus optional manual resting HR
/// and sleep-breathing cues (需求 3、6、10).
struct MorningCheckInView: View {
    @Environment(\.modelContext) private var ctx
    @Environment(\.dismiss) private var dismiss
    @Query private var profiles: [UserProfile]

    @State private var energy: Int? = nil
    @State private var sleepFeel: Int? = nil
    @State private var soreness: Int? = nil
    @State private var area: SorenessArea = .none
    @State private var stress: Int? = nil
    @State private var ill = false
    @State private var manualRHR: Double? = nil
    @State private var snoring = false
    @State private var gasping = false
    @State private var witnessed = false
    @State private var headache = false
    @State private var sleepy = false
    @State private var cpap: Double? = nil
    @State private var deviceRHR: Double? = nil
    @State private var showGuide = false

    var body: some View {
        let p = profiles.first
        CalmNavigationStack {
            Form {
                Section("醒来后的感觉") {
                    labeled("精力") { RatingPicker(value: $energy, lowLabel: "很疲惫", highLabel: "精力充沛") }
                    labeled("睡眠感受") { RatingPicker(value: $sleepFeel, lowLabel: "很差", highLabel: "很好") }
                    labeled("肌肉酸痛") {
                        RatingPicker(value: $soreness, range: 0...3, labels: ["无", "轻微", "明显", "严重"])
                    }
                    if (soreness ?? 0) >= 1 {
                        Picker("主要部位", selection: $area) { ForEach(SorenessArea.allCases) { Text($0.label).tag($0) } }
                    }
                    labeled("压力") { RatingPicker(value: $stress, lowLabel: "很放松", highLabel: "压力很大") }
                    Toggle("有生病或不适症状（发热、咽痛、乏力等）", isOn: $ill)
                }

                Section {
                    if let d = deviceRHR {
                        LabeledContent("设备静息心率", value: "\(d.noDecimal) bpm")
                    }
                    HStack {
                        Text(deviceRHR == nil ? "静息心率" : "手动测量（可选）")
                        Spacer()
                        TextField("bpm", text: $manualRHR.text()).keyboardType(.numberPad).multilineTextAlignment(.trailing).frame(width: 70)
                        Text("bpm").foregroundStyle(.secondary)
                    }
                    DisclosureGroup("如何测量才可比较", isExpanded: $showGuide) {
                        VStack(alignment: .leading, spacing: Theme.Space.item) {
                            BulletText(text: "醒来后先不起身、不看手机，安静平躺 1 分钟。")
                            BulletText(text: "食指与中指轻按手腕拇指侧，数 30 秒脉搏 × 2，或数满 60 秒。")
                            BulletText(text: "每天在相同时间、相同姿势测量；起夜、闹钟惊醒后的数值会偏高。")
                        }
                    }
                } header: {
                    Text("静息心率")
                } footer: {
                    if deviceRHR != nil && p?.rhrMethod == .device {
                        Text("已有设备数据时，手动值会单独标记为「手动」，趋势分析只比较同一种测量方式。")
                    }
                }

                Section {
                    Toggle("打鼾（自己或家人察觉）", isOn: $snoring)
                    Toggle("憋醒 / 喘息着醒来", isOn: $gasping)
                    Toggle("有人观察到呼吸暂停", isOn: $witnessed)
                    Toggle("晨起头痛", isOn: $headache)
                    Toggle("最近白天容易犯困", isOn: $sleepy)
                    if p?.apneaTreatment == .cpap {
                        HStack {
                            Text("昨晚 CPAP 使用")
                            Spacer()
                            TextField("小时", text: $cpap.text(decimals: 1)).keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(width: 60)
                            Text("小时").foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("昨夜睡眠呼吸线索（可选）")
                }
            }
            .navigationTitle("晨起感受")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("保存") { save() }.fontWeight(.semibold) }
            }
            .onAppear(perform: load)
        }
    }

    private func labeled<C: View>(_ title: String, @ViewBuilder _ c: () -> C) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.item) {
            Text(title).font(.subheadline.weight(.medium))
            c()
        }
        .padding(.vertical, Theme.Space.tight)
    }

    private func load() {
        let r = DataHub.record(for: .app, in: ctx)
        energy = r.energy; sleepFeel = r.sleepFeel; soreness = r.soreness; area = r.sorenessArea
        stress = r.stress; ill = r.illnessSymptoms
        snoring = r.snoring; gasping = r.gasping; witnessed = r.witnessedApnea; headache = r.morningHeadache
        sleepy = r.daytimeSleepy; cpap = r.cpapHours
        if r.rhrSource == .manual { manualRHR = r.restingHR } else { deviceRHR = r.restingHR }
    }

    private func save() {
        let r = DataHub.record(for: .app, in: ctx)
        r.checkInAt = .app
        r.energy = energy; r.sleepFeel = sleepFeel; r.soreness = soreness; r.sorenessArea = area
        r.stress = stress; r.illnessSymptoms = ill
        r.toggle(.illness, on: ill)
        r.snoring = snoring; r.gasping = gasping; r.witnessedApnea = witnessed; r.morningHeadache = headache
        r.daytimeSleepy = sleepy; r.cpapHours = cpap
        if let m = manualRHR, m >= 30, m <= 150, deviceRHR == nil || profiles.first?.rhrMethod == .manual {
            r.restingHR = m
            r.rhrSource = .manual
            r.markManual("restingHR")
        }
        try? ctx.save()
        DataHub.updateBaselineIfNeeded(in: ctx)
        DataHub.refreshAlerts(in: ctx)
        try? ctx.save()
        dismiss()
    }
}
