import SwiftUI
import SwiftData

// Reusable form sections for building and editing the personal health base (需求 1).

struct BasicsSection: View {
    @Bindable var p: UserProfile
    var body: some View {
        Section("基础信息") {
            TextField("怎么称呼你", text: $p.nickname)
            HStack {
                Text("出生年份")
                Spacer()
                TextField("未填写", text: Binding(get: { p.birthYear == 0 ? "" : String(p.birthYear) }, set: { p.birthYear = Int($0) ?? 0 }))
                    .keyboardType(.numberPad).multilineTextAlignment(.trailing)
            }
            Picker("性别", selection: Binding(get: { p.sex }, set: { p.sex = $0 })) {
                ForEach(Sex.allCases) { Text($0.label).tag($0) }
            }
            NumberField("身高（cm）", value: $p.heightCm)
            NumberField("体重（kg）", value: $p.weightKg)
            HStack {
                Text("颈围（可选）")
                Spacer()
                TextField("cm", text: $p.neckCm.text(decimals: 1)).keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing).frame(width: 80)
            }
        }
    }
}

/// A number typed in: the text stays as typed (「65.」 keeps its point on the way to 65.5), and the value
/// follows whenever the text reads as a number; empty is 0 (not filled in).
struct NumberField: View {
    let title: String
    @Binding var value: Double
    @State private var text: String

    init(_ title: String, value: Binding<Double>) {
        self.title = title
        _value = value
        _text = State(initialValue: value.wrappedValue > 0 ? value.wrappedValue.shortDecimal : "")
    }

    var body: some View {
        HStack {
            Text(title)
            TextField("未填写", text: $text)
                .keyboardType(.decimalPad).multilineTextAlignment(.trailing)
        }
        .onChange(of: text) { _, t in value = Self.parse(t) ?? 0 }
        // Filled in from elsewhere (Apple Health): the field shows the new value.
        .onChange(of: value) { _, v in if (Self.parse(text) ?? 0) != v { text = v > 0 ? v.shortDecimal : "" } }
    }

    /// 「65.5」, 「65.」 and 「65,5」 (a comma keypad) all read as numbers.
    static func parse(_ t: String) -> Double? {
        Double(t.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "."))
    }
}

struct ConditionsSection: View {
    @Bindable var p: UserProfile
    var body: some View {
        Section {
            Button {
                p.conditions = []
                p.otherConditions = ""
                p.extraConditionsRaw = []
                p.healthBackgroundReviewed = true
            } label: {
                Label("没有上述情况", systemImage: p.healthBackgroundReviewed && p.conditions.isEmpty && p.extraConditionsRaw.isEmpty && p.otherConditions.isEmpty ? "checkmark.circle.fill" : "circle")
            }
            .buttonStyle(.plain).frame(minHeight: Theme.Size.tap)
            FlowLayout(spacing: Theme.Space.item) {
                ForEach(HealthCondition.allCases) { c in
                    ToggleChip(text: c.label, isOn: Binding(
                        get: { p.conditions.contains(c) },
                        set: { on in
                            var s = p.conditions
                            if on { s.insert(c) } else { s.remove(c) }
                            p.conditions = s
                            p.healthBackgroundReviewed = true
                            if c == .sleepApnea && on { p.apneaStatus = .diagnosed }
                            if c == .ckd && on { p.nutrientTracking = true }
                        }))
                }
            }
            .padding(.vertical, Theme.Space.tight)
            if p.conditions.contains(where: \.watchesFluid) && !p.fluidLimit {
                Text("医生要求限制饮水时，在「恢复目标」里打开「限水」，Pulse 就不再提醒多喝水。")
                    .font(Theme.TypeScale.body).foregroundStyle(.secondary)
            }
            ForEach(p.extraConditionsRaw, id: \.self) { raw in
                let x = ConditionLibrary.resolve(raw)
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: Theme.Space.hairline) {
                        Text(x.name)
                        Text(x.known ? x.summary : "资料库未收录，只记了名字").font(Theme.TypeScale.body).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(role: .destructive) { p.extraConditionsRaw.removeAll { $0 == raw } } label: {
                        // 44 pt tap area; the glyph stays at the top trailing corner, on the name's baseline.
                        Image(systemName: "minus.circle.fill")
                            .frame(minWidth: Theme.Size.tap, minHeight: Theme.Size.tap, alignment: .topTrailing)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("移除\(x.name)")
                }
            }
            TextField("其他情况（可选）", text: $p.otherConditions)
            TextField("身体限制，如膝盖不适、腰痛（可选）", text: $p.limitations)
            Button("暂不填写") { p.healthBackgroundReviewed = false }
                .frame(minHeight: Theme.Size.tap)
            if !p.healthBackgroundReviewed && p.conditions.isEmpty && p.otherConditions.isEmpty && p.extraConditionsRaw.isEmpty {
                Text("健康状况尚未确认。").foregroundStyle(.secondary)
            }
        } header: {
            Text("健康状况")
        } footer: {
            Text("这些信息用于调整运动强度、提醒与解读方式，仅保存在本机。已在接受治疗的情况，请以医生的照护计划为准。\(p.extraConditionsRaw.isEmpty ? AgentNameSettings.shared.phrase("也可以在和", "聊天时告诉它，它会帮你记下。") : AgentNameSettings.shared.phrase("带名字的几项是在和", "聊天时记下的。"))")
        }
    }
}

/// 饮食限制: the amounts the doctor or dietitian gave, for the kidney-diet record.
struct DietTargetsSection: View {
    @Bindable var p: UserProfile
    var body: some View {
        Section {
            Toggle("记录盐、蛋白质、钾和磷", isOn: $p.nutrientTracking)
            if p.nutrientTracking {
                Stepper("每天盐不超过 \(p.saltLimitG.oneDecimal) g", value: $p.saltLimitG, in: 2...10, step: 0.5)
                Stepper(value: Binding(get: { p.proteinTargetG ?? 0 }, set: { p.proteinTargetG = $0 == 0 ? nil : $0 }), in: 0...150, step: 5) {
                    Text(p.proteinTargetG.map { "蛋白质每天约 \($0) g" } ?? "蛋白质：医生没给具体的量")
                }
                Toggle("医生让我限钾", isOn: $p.potassiumLimit)
                Toggle("医生让我限磷", isOn: $p.phosphorusLimit)
            }
        } header: {
            Text("饮食限制")
        } footer: {
            Text(p.nutrientTracking ? "按医生或营养师给你的量填写。蛋白质吃多少因人而异，Pulse 不替你定。" : "慢性肾病、高血压、痛风等需要管住盐、蛋白质、钾或磷时打开，在「今日 › 饮食」里记录。")
        }
    }
}

/// 透析: 血液透析 (the session days and the dry weight, from the dialysis centre) or 腹膜透析
/// (every day at home). Turning it on also limits fluids; haemodialysis days are kept free of training.
struct DialysisSection: View {
    @Environment(\.modelContext) private var ctx
    @Bindable var p: UserProfile
    @State private var dryText = ""
    var body: some View {
        let mode = DialysisMode(rawValue: p.dialysisModeRaw) ?? .hemo
        Section {
            Toggle("在做透析", isOn: Binding(get: { p.dialysis }, set: { on in
                p.dialysis = on
                if on {
                    p.fluidLimit = true
                    if p.dialysisWeekdays.isEmpty { p.dialysisWeekdays = [2, 4, 6] }
                }
            }))
            if p.dialysis {
                Picker("方式", selection: $p.dialysisModeRaw) {
                    ForEach(DialysisMode.allCases) { Text($0.label).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
            }
            if p.dialysis && mode == .hemo {
                VStack(alignment: .leading, spacing: Theme.Space.item) {
                    Text("透析日")
                    FlowLayout(spacing: Theme.Space.item) {
                        ForEach(Weekday.mondayFirst, id: \.self) { d in
                            ToggleChip(text: Weekday.name(d), isOn: Binding(get: { p.dialysisWeekdays.contains(d) }, set: { on in
                                p.dialysisWeekdays = Weekday.mondayFirst.filter { $0 == d ? on : p.dialysisWeekdays.contains($0) }
                            }))
                        }
                    }
                }
                .padding(.vertical, Theme.Space.tight)
                HStack {
                    Text("干体重")
                    Spacer()
                    TextField("医生定的", text: $dryText).keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(width: 90)
                    Text("kg").foregroundStyle(.secondary)
                }
                .onAppear { dryText = p.dryWeightKg.map(\.oneDecimal) ?? "" }
                .onChange(of: dryText) { _, t in
                    p.dryWeightKg = Double(t.replacingOccurrences(of: ",", with: ".")).flatMap { (30...200).contains($0) ? $0 : nil }
                }
            }
        } header: {
            Text("透析")
        } footer: {
            footer(mode)
        }
        // Haemodialysis days come out of this week's plan as soon as they are set.
        .onChange(of: [p.dialysis ? 1 : 0, mode == .hemo ? 1 : 0] + p.dialysisWeekdays) { DataHub.regenerateWeekPlan(in: ctx) }
    }

    @ViewBuilder private func footer(_ mode: DialysisMode) -> some View {
            switch (p.dialysis, mode) {
            case (false, _):
                Text("做透析时打开，Pulse 会按透析安排运动，并留意体重和需要尽快处理的情况。")
            case (true, .hemo):
                Text("透析日不安排训练；两次透析之间体重涨到干体重的 4% 以上时提醒你。干体重和每天喝多少水，按透析中心定的填（饮水在「恢复目标」里改）。")
            case (true, .peritoneal):
                Text("每天称体重、记下尿量；运动不压肚子、不做大重量。透出液浑浊、肚子疼或发烧时，在「水肿与尿量」里记下，Pulse 会马上提醒你联系腹透中心。")
            }
    }
}

struct MedicationsSection: View {
    @Environment(\.modelContext) private var ctx
    @Query(sort: \MedicationEntry.startDate, order: .reverse) private var meds: [MedicationEntry]
    @Query private var profiles: [UserProfile]
    @Query private var labs: [LabResult]
    @State private var adding = false

    var body: some View {
        let kidneys = KidneyMeds.atRisk(profiles.first?.snapshot(medications: meds) ?? ProfileSnapshot(), labs: labs.map(\.point))
        Section {
            ForEach(meds) { m in
                VStack(alignment: .leading, spacing: Theme.Space.hairline) {
                    HStack {
                        Text(m.name).font(Theme.TypeScale.body.weight(.medium))
                        if !m.isActive { Chip(text: "已停用", color: .gray) }
                        Spacer()
                        Text(m.category.label).font(Theme.TypeScale.body).foregroundStyle(.secondary)
                    }
                    Text("\(m.dose.isEmpty ? "" : m.dose + " · ")\(m.startDate.formatted(date: .numeric, time: .omitted)) 起 · \(m.category.hrEffect.label)")
                        .font(Theme.TypeScale.body).foregroundStyle(.secondary)
                    if kidneys && m.isActive && KidneyMeds.isNSAID(m.name) {
                        StatusLabel(.attention("这类止痛药可能伤肾，长期吃先问肾内科医生或药师")).font(Theme.TypeScale.body)
                    }
                }
                .swipeActions {
                    Button("删除", role: .destructive) { ctx.delete(m) }
                    if m.isActive { Button("停用") { m.endDate = .app }.tint(.orange) }
                }
            }
            Button { adding = true } label: { Label("添加用药", systemImage: "plus.circle") }
        } header: {
            Text("用药背景")
        } footer: {
            Text("部分药物会影响心率（如 β 受体阻滞剂会降低心率），开始或停用药物后，前后数据的可比性有限。Pulse 不提供用药建议。")
        }
        .sheet(isPresented: $adding) { AddMedicationSheet() }
    }
}

struct AddMedicationSheet: View {
    @Environment(\.modelContext) private var ctx
    @Environment(\.dismiss) private var dismiss
    @Query private var profiles: [UserProfile]
    @Query private var labs: [LabResult]
    @State private var name = ""
    @State private var category: MedicationCategory = .other
    @State private var dose = ""
    @State private var start = Date.app

    var body: some View {
        CalmNavigationStack {
            Form {
                TextField("药品名称", text: $name)
                Picker("类别", selection: $category) {
                    ForEach(MedicationCategory.allCases) { Text($0.label).tag($0) }
                }
                TextField("剂量与用法（可选）", text: $dose)
                DatePicker("开始日期", selection: $start, displayedComponents: .date)
                Section { Text(category.hrEffect.label).foregroundStyle(.secondary) }
                if KidneyMeds.isNSAID(name), KidneyMeds.atRisk(profiles.first?.snapshot(medications: []) ?? ProfileSnapshot(), labs: labs.map(\.point)) {
                    Section { StatusLabel(.attention(KidneyMeds.caution)).fixedSize(horizontal: false, vertical: true) }
                }
            }
            .navigationTitle("添加用药")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        ctx.insert(MedicationEntry(name: name, category: category, dose: dose, startDate: start))
                        if start > .app.adding(days: -2) {
                            DataHub.record(for: start, in: ctx).toggle(.medicationChange, on: true)
                        }
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

struct ExerciseBaseSection: View {
    @Bindable var p: UserProfile
    var body: some View {
        Section {
            Picker("目前的运动水平", selection: Binding(get: { p.activityLevel }, set: {
                p.activityLevel = $0
                p.weeklyTargetMinutes = max(60, min($0.startingWeeklyMinutes, Int(Double(p.weeklyTimeBudget) * 0.8)))
            })) {
                ForEach(ActivityLevel.allCases) { l in
                    VStack(alignment: .leading, spacing: Theme.Space.hairline) { Text(l.label); Text(l.detail).font(Theme.TypeScale.body) }.tag(l)
                }
            }
            .pickerStyle(.navigationLink)
            Stepper("近期每周运动约 \(p.weeklyExerciseMinutes) 分钟", value: $p.weeklyExerciseMinutes, in: 0...900, step: 15)
        } header: {
            Text("运动基础")
        }
    }
}

struct LifeConstraintsSection: View {
    @Bindable var p: UserProfile
    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: Theme.Space.item) {
                Text("哪几天可以安排运动").font(Theme.TypeScale.body)
                WeekdayPicker(selection: $p.availableWeekdays)
            }
            .padding(.vertical, Theme.Space.tight)
            Stepper("每次可投入 \(p.sessionMinutes) 分钟", value: $p.sessionMinutes, in: 10...150, step: 5)
            Stepper("每周总共可投入 \(p.weeklyTimeBudget) 分钟", value: $p.weeklyTimeBudget, in: 30...900, step: 15)
            Picker("偏好时段", selection: Binding(get: { p.preferredTime }, set: { p.preferredTime = $0 })) {
                ForEach(PreferredTime.allCases) { Text($0.label).tag($0) }
            }
            NavigationLink { ShiftSettingsView(profile: p) } label: {
                LabeledContent("倒班 / 轮班作息", value: p.shiftWork ? "已开启" : "未开启")
            }
        } header: {
            Text("生活节奏与可用时间")
        } footer: {
            Text("计划会放在你能执行的日子里。其他日子安排为日常活动或休息。倒班时，训练会避开夜班和夜班后的恢复日。")
        }
    }
}

struct WeekdayPicker: View {
    @Binding var selection: [Int]
    var body: some View {
        HStack(spacing: Theme.Space.item) {
            ForEach(Weekday.mondayFirst, id: \.self) { wd in
                let on = selection.contains(wd)
                Button {
                    if on { selection.removeAll { $0 == wd } } else { selection.append(wd) }
                } label: {
                    Text(Weekday.short(wd))
                        .font(Theme.TypeScale.body.weight(on ? .semibold : .regular))
                        .frame(maxWidth: .infinity, minHeight: Theme.Size.tap)
                        .foregroundStyle(on ? Color.white : Color.primary)
                        .background(on ? Color.accentColor : Theme.subtle, in: Circle())
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

struct GoalsSection: View {
    @Bindable var p: UserProfile
    var body: some View {
        Section("使用方向") { UsageIntentSelector(selection: $p.usageIntent) }
        Section {
            TextField("补充说明（可选）", text: $p.goalNote, axis: .vertical)
        } footer: {
            Text("选择记录身体状况时，不设置改善目标。具体方案和指标在基线评估后确认。")
        }
    }
}

/// The five directions (记录 or one of the packs), one of them chosen.
struct UsageIntentSelector: View {
    @Binding var selection: UsageIntent
    var body: some View {
        ForEach(UsageIntent.allCases) { intent in
            Button { selection = intent } label: {
                HStack(spacing: Theme.Space.block) {
                    Text(intent.label).foregroundStyle(.primary)
                    Spacer()
                    Image(systemName: selection == intent ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(selection == intent ? Color.accentColor : Color.secondary)
                }
                .font(Theme.TypeScale.body).frame(minHeight: Theme.Size.tap).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(selection == intent ? .isSelected : [])
        }
    }
}

struct HabitTargetsSection: View {
    @Bindable var p: UserProfile
    var body: some View {
        Section {
            DatePicker("目标上床时间", selection: minutesBinding($p.bedtimeMinutes), displayedComponents: .hourAndMinute)
            DatePicker("目标起床时间", selection: minutesBinding($p.wakeMinutes), displayedComponents: .hourAndMinute)
            Stepper("睡眠需要约 \(p.sleepNeedHours.oneDecimal) 小时", value: $p.sleepNeedHours, in: 6...10, step: 0.5)
            Stepper("咖啡因截止 \(p.caffeineCutoffHour):00", value: $p.caffeineCutoffHour, in: 10...20)
            Stepper("每周饮酒不超过 \(p.weeklyAlcoholLimit.noDecimal) 单位", value: $p.weeklyAlcoholLimit, in: 0...14, step: 1)
            Toggle("限水（医生要求）", isOn: $p.fluidLimit)
            Stepper(p.fluidLimit ? "每天饮水不超过 \(p.waterTargetMl) ml" : "饮水目标 \(p.waterTargetMl) ml", value: $p.waterTargetMl, in: 500...4000, step: 100)
            Stepper("步数目标 \(p.stepsTarget)", value: $p.stepsTarget, in: 3000...20000, step: 500)
        } header: {
            Text("恢复目标")
        } footer: {
            Text("限水：慢性肾病、心力衰竭等需要限制饮水时打开，按医生给的量设置上限；Pulse 不再提醒多喝水，接近或超过上限时提醒。\n1 单位酒精 ≈ 10 g：啤酒 330 ml（5%）约 1.3 单位，葡萄酒 150 ml 约 1.5 单位，白酒 50 ml（52%）约 2 单位。")
        }
    }
}

func minutesBinding(_ minutes: Binding<Int>) -> Binding<Date> {
    Binding<Date>(
        get: { Date.app.startOfDay.adding(minutes: minutes.wrappedValue) },
        set: { minutes.wrappedValue = $0.minutesOfDay })
}
