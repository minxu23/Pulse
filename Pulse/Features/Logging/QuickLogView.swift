import SwiftUI
import SwiftData

enum QuickLogKind: String, Identifiable, CaseIterable {
    case workout, alcohol, caffeine, water, diet, stress, context, symptom, kidneySigns, bloodPressure, glucose, vital, lab, sleep
    var id: String { rawValue }
    /// What the + menus offer: 水肿与尿量 only to those who watch fluid.
    static func menu(for p: ProfileSnapshot) -> [QuickLogKind] {
        allCases.filter { $0 != .kidneySigns || KidneySigns.relevant(p) }
    }
    var label: String {
        switch self {
        case .workout: "运动"
        case .alcohol: "饮酒"
        case .caffeine: "咖啡因"
        case .water: "饮水"
        case .diet: "饮食"
        case .stress: "压力"
        case .context: "状况"
        case .symptom: "症状"
        case .kidneySigns: "水肿与尿量"
        case .bloodPressure: "血压"
        case .glucose: "血糖"
        case .vital: "其他指标"
        case .lab: "化验结果"
        case .sleep: "睡眠"
        }
    }
    var icon: String {
        switch self {
        case .workout: "figure.run"
        case .alcohol: "wineglass"
        case .caffeine: "cup.and.saucer"
        case .water: "drop"
        case .diet: "fork.knife"
        case .stress: "brain.head.profile"
        case .context: "tag"
        case .symptom: "person.fill.questionmark"
        case .kidneySigns: "drop.triangle"
        case .bloodPressure: "gauge.with.dots.needle.33percent"
        case .glucose: "drop.fill"
        case .vital: "waveform.path.ecg.rectangle"
        case .lab: "testtube.2"
        case .sleep: "bed.double"
        }
    }
}

/// Entry point for all quick logs. Every form can target an earlier date so records can be
/// supplemented or corrected later (需求 10).
struct QuickLogSheet: View {
    let kind: QuickLogKind
    var date: Date = .app
    var planItemID: UUID? = nil

    /// Day-level logs (drinks, water, stress…) made before 5 am belong to the day that is ending.
    private var day: Date {
        abs(date.timeIntervalSinceNow) < 120 && DayClock.isBeforeWake(date, DayClock.current) ? DayClock.logicalToday(date, DayClock.current) : date
    }

    var body: some View {
        CalmNavigationStack {
            Group {
                switch kind {
                case .workout: WorkoutLogForm(initialDate: date, planItemID: planItemID)
                case .alcohol: AlcoholLogForm(initialDate: day)
                case .caffeine: CaffeineLogForm(initialDate: day)
                case .water: WaterLogForm(initialDate: day)
                case .diet: DietLogForm(initialDate: day)
                case .stress: StressLogForm(initialDate: day)
                case .context: ContextLogForm(initialDate: day)
                case .symptom: SymptomLogForm()
                case .kidneySigns: KidneySignsLogForm(initialDate: day)
                case .bloodPressure: VitalLogForm(kind: .bloodPressure)
                case .glucose: VitalLogForm(kind: .glucose)
                case .vital: VitalLogForm(kind: .heartRate)
                case .lab: LabLogForm()
                case .sleep: SleepLogForm(initialDate: date)
                }
            }
            .navigationTitle("记录\(kind.label)")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

// MARK: - Shared save toolbar

private struct SaveToolbar: ViewModifier {
    var disabled = false
    let save: () -> Void
    @Environment(\.dismiss) private var dismiss
    func body(content: Content) -> some View {
        content.toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") { save(); dismiss() }.disabled(disabled).fontWeight(.semibold)
            }
        }
    }
}

extension View {
    fileprivate func saveToolbar(disabled: Bool = false, _ save: @escaping () -> Void) -> some View {
        modifier(SaveToolbar(disabled: disabled, save: save))
    }
}

// MARK: - Behaviour logs

struct AlcoholLogForm: View {
    @Environment(\.modelContext) private var ctx
    let initialDate: Date
    @State private var date = Date.app
    @State private var units = 0.0

    var body: some View {
        Form {
            DatePicker("日期", selection: $date, in: ...Date.app, displayedComponents: .date)
            Section {
                Stepper("当天合计 \(units.oneDecimal) 单位", value: $units, in: 0...20, step: 0.5)
                FlowLayout(spacing: Theme.Space.item) {
                    ForEach([("啤酒 330ml", 1.3), ("葡萄酒 150ml", 1.5), ("白酒 50ml", 2.0), ("烈酒 30ml", 1.0)], id: \.0) { item in
                        Button("+ \(item.0)") { units += item.1 }.buttonStyle(.bordered)
                    }
                }
            } footer: {
                Text("1 单位 ≈ 10 g 酒精。饮酒常使当晚睡眠变浅、次日静息心率升高，Pulse 会在解读数据时考虑这一点。")
            }
        }
        .onAppear { date = initialDate; units = DataHub.record(for: date, in: ctx).alcoholUnits }
        .onChange(of: date) { _, d in units = DataHub.record(for: d, in: ctx).alcoholUnits }
        .saveToolbar {
            let r = DataHub.record(for: date, in: ctx)
            r.alcoholUnits = units
            r.toggle(.alcohol, on: units > 0)
            r.markManual("alcohol")
        }
    }
}

struct CaffeineLogForm: View {
    @Environment(\.modelContext) private var ctx
    @Query private var profiles: [UserProfile]
    let initialDate: Date
    @State private var date = Date.app
    @State private var cups = 0
    @State private var lastHour = Date.app.hour

    var body: some View {
        let cutoff = profiles.first?.caffeineCutoffHour ?? 14
        Form {
            DatePicker("日期", selection: $date, in: ...Date.app, displayedComponents: .date)
            Stepper("咖啡 / 茶 / 功能饮料 \(cups) 杯", value: $cups, in: 0...12)
            if cups > 0 {
                Picker("最后一杯", selection: $lastHour) {
                    ForEach(6...23, id: \.self) { Text("\($0):00 左右").tag($0) }
                }
                if lastHour >= cutoff {
                    Callout(kind: .caution, text: "晚于你设定的 \(cutoff):00 截止时间，可能影响今晚入睡。")
                }
            }
        }
        .onAppear {
            date = initialDate
            let r = DataHub.record(for: date, in: ctx)
            cups = r.caffeineCups
            // The picker covers 6–23; after midnight the last cup still counts as late evening.
            lastHour = r.lastCaffeineHour ?? (DayClock.isBeforeWake(.app, DayClock.current) ? 23 : min(23, max(6, Date.app.hour)))
        }
        .saveToolbar {
            let r = DataHub.record(for: date, in: ctx)
            r.caffeineCups = cups
            r.lastCaffeineHour = cups > 0 ? lastHour : nil
            r.toggle(.lateCaffeine, on: cups > 0 && lastHour >= cutoff)
        }
    }
}

struct WaterLogForm: View {
    @Environment(\.modelContext) private var ctx
    @Query private var profiles: [UserProfile]
    let initialDate: Date
    @State private var date = Date.app
    @State private var ml = 0

    var body: some View {
        let target = profiles.first?.waterTargetMl ?? 1800
        let limited = profiles.first?.fluidLimit == true
        Form {
            DatePicker("日期", selection: $date, in: ...Date.app, displayedComponents: .date)
            Section {
                VStack(alignment: .leading, spacing: Theme.Space.block) {
                    HStack(alignment: .firstTextBaseline, spacing: Theme.Space.tight) {
                        Text("\(ml)").font(.largeTitle.bold()).monospacedDigit()
                        Text("/ \(limited ? "上限 " : "")\(target) ml").foregroundStyle(.secondary)
                    }
                    ProgressBar(value: Double(ml) / Double(target), color: limited && ml > target ? .orange : .cyan)
                    HStack(spacing: Theme.Space.item) {
                        ForEach([150, 250, 500], id: \.self) { v in
                            Button("+\(v)") { ml += v }.buttonStyle(.bordered).tint(Theme.accent)
                        }
                        Spacer()
                        Button("撤销") { ml = max(0, ml - 250) }.buttonStyle(.borderless)
                    }
                }
                .padding(.vertical, Theme.Space.tight)
            } footer: {
                Text(limited ? (ml > target ? "已超过医生定的 \(target) ml 上限，今天不再额外喝水；留意脚踝是否浮肿，明早称一下体重。" : "限水中：汤、粥、水果里的水分也算在内。")
                             : "运动日、炎热天气需要更多水分；睡前 1 小时少量饮水即可，减少夜醒。")
            }
        }
        .onAppear { date = initialDate; ml = DataHub.record(for: date, in: ctx).waterMl }
        .saveToolbar {
            let r = DataHub.record(for: date, in: ctx)
            r.waterMl = ml
            r.toggle(.dehydration, on: !limited && ml > 0 && Double(ml) < Double(target) * 0.5 && date.isSameDay(.app) == false)
        }
    }
}

struct DietLogForm: View {
    @Environment(\.modelContext) private var ctx
    @Query private var profiles: [UserProfile]
    @Query private var meds: [MedicationEntry]
    @Query(sort: \VitalReading.time) private var vitals: [VitalReading]
    @Query(sort: \MealLog.time) private var meals: [MealLog]
    let initialDate: Date
    @State private var date = Date.app
    @State private var quality: Int? = nil
    @State private var lateMeal = false
    @State private var addMeal = false
    @State private var mealKind: MealKind = .lunch
    @State private var carbs: Double? = nil
    @State private var note = ""
    // Kidney diet
    @State private var saltText = ""
    @State private var saltSources: Set<String> = []
    /// Portions of each food.
    @State private var protein: [String: Int] = [:]
    @State private var potassium: [String: Int] = [:]
    @State private var phosphorus: [String: Int] = [:]

    var body: some View {
        let showCarbs = (profiles.first?.hasModule(.diabetesCare) ?? false) || (profiles.first?.hasModule(.marathon) ?? false)
        let kidney = profiles.first?.nutrientTracking == true
        Form {
            DatePicker("日期", selection: $date, in: ...Date.app, displayedComponents: .date)
            Section("今天的饮食整体") {
                RatingPicker(value: $quality, range: 1...3, labels: ["不太理想", "一般", "比较均衡"])
                Toggle("晚餐较晚（睡前 2 小时内）", isOn: $lateMeal)
            }
            if kidney { kidneySections }
            Section {
                Toggle("记录一餐详情", isOn: $addMeal)
                if addMeal {
                    Picker("类型", selection: $mealKind) { ForEach(MealKind.allCases) { Text($0.label).tag($0) } }
                    if showCarbs || mealKind == .exerciseFuel {
                        HStack {
                            Text("碳水化合物")
                            Spacer()
                            TextField("g", text: $carbs.text()).keyboardType(.numberPad).multilineTextAlignment(.trailing).frame(width: 80)
                            Text("g").foregroundStyle(.secondary)
                        }
                    }
                    TextField("吃了什么（可选）", text: $note)
                }
            } footer: {
                Text("不需要精确计算。均衡饮食指蔬菜、优质蛋白和全谷物较充足，少油炸与高糖。")
            }
            // With a CGM, what this meal will probably do — from the user's own past meals.
            if addMeal, date.isSameDay(.app), [.breakfast, .lunch, .dinner, .snack].contains(mealKind),
               let pr = GlucoseModels.current.predict(
                   GlucoseModelInput(vitals: vitals.map(\.point), meals: meals, profile: profiles.first?.snapshot(medications: meds) ?? ProfileSnapshot()),
                   kind: mealKind, carbs: carbs, at: .app) {
                Section {
                    Text(pr.message).fixedSize(horizontal: false, vertical: true)
                } header: {
                    Text("饭后血糖预测")
                } footer: {
                    Text(MealPrediction.caveat)
                }
            }
        }
        .onAppear {
            date = initialDate
            let r = DataHub.record(for: date, in: ctx)
            quality = r.dietQuality; lateMeal = r.lateMeal
            saltText = r.saltG.map { $0.oneDecimal } ?? ""
            saltSources = Set(r.saltSources)
            func portions(_ list: [String]) -> [String: Int] { Dictionary(list.map { ($0, 1) }, uniquingKeysWith: +) }
            protein = portions(r.proteinFoods); potassium = portions(r.potassiumFoods); phosphorus = portions(r.phosphorusFoods)
        }
        .saveToolbar {
            let r = DataHub.record(for: date, in: ctx)
            r.dietQuality = quality
            r.lateMeal = lateMeal
            r.toggle(.lateMeal, on: lateMeal)
            if kidney {
                r.nutrientsLogged = true
                r.saltG = Double(saltText.replacingOccurrences(of: ",", with: ".")).flatMap { (0.5...40).contains($0) ? $0 : nil }
                // Kept in the order of the lists, one entry per portion, so the day reads the same each time.
                func list(_ foods: [String], _ n: [String: Int]) -> [String] { foods.flatMap { Array(repeating: $0, count: n[$0] ?? 0) } }
                r.saltSources = DietFoods.salt.filter(saltSources.contains)
                r.potassiumFoods = list(DietFoods.potassium, potassium)
                r.phosphorusFoods = list(DietFoods.phosphorus, phosphorus)
                r.proteinFoods = list(DietFoods.proteinFoods.map(\.name), protein)
                // An older 「肉蛋奶豆 N 份」 stands until foods are counted instead.
                if !r.proteinFoods.isEmpty { r.proteinServings = nil }
            }
            if addMeal {
                let m = MealLog(time: date.isSameDay(.app) ? .app : date.adding(minutes: 12 * 60), kind: mealKind)
                m.carbsG = carbs; m.note = note; m.balanced = (quality ?? 2) >= 3
                ctx.insert(m)
            }
        }
    }
}

extension DietLogForm {
    @ViewBuilder fileprivate var kidneySections: some View {
        let p = profiles.first
        Section {
            HStack {
                Text("用控盐勺量过的盐")
                Spacer()
                TextField("可不填", text: $saltText).keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(width: 80)
                Text("g").foregroundStyle(.secondary)
            }
            foodChips(DietFoods.salt, $saltSources)
        } header: {
            Text("盐")
        } footer: {
            Text("勾选今天吃过的高盐食物。每天盐不超过 \((p?.saltLimitG ?? 5).oneDecimal) g；一个啤酒瓶盖（去掉胶垫）的盐约 6 g。")
        }
        let proteinG = DietFoods.proteinFoods.reduce(0.0) { $0 + $1.proteinG * Double(protein[$1.name] ?? 0) }
        Section {
            ForEach(DietFoods.proteinFoods, id: \.name) { f in
                let n = protein[f.name] ?? 0
                Stepper(value: Binding(get: { n }, set: { protein[f.name] = $0 }), in: 0...12) {
                    VStack(alignment: .leading, spacing: Theme.Space.hairline) {
                        Text(n > 0 ? "\(f.name) ×\(n)" : f.name)
                        Text("\(f.portion) · 约 \(Int(f.proteinG)) g").font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .accessibilityValue("\(n) 份")
            }
        } header: {
            Text(proteinG > 0 ? "蛋白质 · 约 \(Int(proteinG)) g" : "蛋白质")
        } footer: {
            Text("按今天吃的份数估算，主食和蔬菜也算在内。" + (p?.proteinTargetG.map { "医生定的量：每天约 \($0) g。" } ?? ""))
        }
        Section {
            countChips(DietFoods.potassium, $potassium)
        } header: {
            Text(potassium.isEmpty ? "高钾食物" : "高钾食物 · 约 \(KidneyDiet.potassiumMg(potassium.flatMap { Array(repeating: $0.key, count: $0.value) })) mg 钾")
        } footer: {
            Text("点一下记 1 份（香蕉 1 根、土豆 1 个拳头大、绿叶菜 1 碗），再点加一份。只算这些食物里的钾，不是全天总量。"
                 + (p?.potassiumLimit == true ? "医生让你限钾：这些食物少吃；绿叶菜焯水后再炒能去掉一部分钾。低钠盐里也有钾。" : "吃多少合适按医生或营养师的建议。"))
        }
        Section {
            countChips(DietFoods.phosphorus, $phosphorus)
        } header: {
            Text(phosphorus.isEmpty ? "高磷食物" : "高磷食物 · 约 \(KidneyDiet.phosphorusMg(phosphorus.flatMap { Array(repeating: $0.key, count: $0.value) })) mg 磷")
        } footer: {
            Text("加工食品和深色汽水里的磷最容易被吸收。")
        }
    }

    /// Foods counted in portions: each tap adds one, up to three, then back to none.
    private func countChips(_ foods: [String], _ counts: Binding<[String: Int]>) -> some View {
        FlowLayout(spacing: Theme.Space.item) {
            ForEach(foods, id: \.self) { f in
                let n = counts.wrappedValue[f] ?? 0
                Button { counts.wrappedValue[f] = n >= 3 ? nil : n + 1 } label: {
                    Chip(text: n > 1 ? "\(f) ×\(n)" : f, icon: n > 0 ? "checkmark" : nil, color: n > 0 ? Theme.accent : .secondary, filled: n > 0)
                        .frame(minHeight: Theme.Size.tap)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityValue(n == 0 ? "没吃" : "\(n) 份")
                .accessibilityHint("点一下加一份，3 份后再点清零")
                .accessibilityAddTraits(n > 0 ? .isSelected : [])
            }
        }
        .padding(.vertical, Theme.Space.tight)
    }

    private func foodChips(_ foods: [String], _ chosen: Binding<Set<String>>) -> some View {
        FlowLayout(spacing: Theme.Space.item) {
            ForEach(foods, id: \.self) { f in
                ToggleChip(text: f, isOn: Binding(get: { chosen.wrappedValue.contains(f) },
                                                  set: { on in if on { chosen.wrappedValue.insert(f) } else { chosen.wrappedValue.remove(f) } }))
            }
        }
        .padding(.vertical, Theme.Space.tight)
    }
}

/// 化验结果: the values on one lab report, in the units the report uses (saved in Pulse's own).
/// Creatinine without an eGFR on the report gives an estimated eGFR (CKD-EPI 2021); values far
/// outside the usual range raise an event.
struct LabLogForm: View {
    @Environment(\.modelContext) private var ctx
    @Query private var profiles: [UserProfile]
    @Query private var meds: [MedicationEntry]
    @Query(sort: \LabResult.date) private var labs: [LabResult]
    @State private var date = Date.app
    @State private var texts: [LabKind: String] = [:]
    /// The report's unit for each value, remembered for the next report.
    @State private var units: [LabKind: String] = Dictionary(uniqueKeysWithValues: LabKind.allCases.compactMap { k in
        UserDefaults.standard.string(forKey: "lab.unit." + k.rawValue).flatMap { k.units.contains($0) ? (k, $0) : nil }
    })
    @State private var note = ""

    private func unit(_ k: LabKind) -> String { units[k] ?? k.unit }
    private func typed(_ k: LabKind) -> Double? {
        texts[k].flatMap { Double($0.replacingOccurrences(of: ",", with: ".")) }
    }
    /// What was typed, in Pulse's own unit.
    private func value(_ k: LabKind) -> Double? {
        typed(k).map { k.standard($0, unit: unit(k)) }
    }
    private var entered: [(LabKind, Double)] {
        LabKind.allCases.compactMap { k in value(k).flatMap { k.plausible.contains($0) ? (k, $0) : nil } }
    }

    var body: some View {
        let p = profiles.first?.snapshot(medications: meds) ?? ProfileSnapshot()
        Form {
            DatePicker("化验日期", selection: $date, in: ...Date.app, displayedComponents: .date)
            Section {
                ForEach(LabKind.allCases.filter(\.isKidney)) { row($0, p) }
            } header: {
                Text("肾功能")
            } footer: {
                if value(.egfr) == nil, let cr = value(.creatinine), let e = LabAnalyzer.ckdEPI(creatinine: cr, age: p.age, sex: p.sex) {
                    Text("化验单上没有 eGFR 时，按肌酐估算约 \(Int(e.rounded()))（CKD-EPI 2021），会一起保存。")
                } else {
                    Text("单位和化验单上的不一样时，点单位换一个，Pulse 会自动换算。")
                }
            }
            Section {
                ForEach(LabKind.allCases.filter { !$0.isKidney }) { row($0, p) }
            } header: {
                Text("血液")
            } footer: {
                Text("只填化验单上有的项目。\(LabAnalyzer.rangeNote)")
            }
            Section { TextField("备注（可选），如医院", text: $note) }
        }
        .saveToolbar(disabled: entered.isEmpty) { save(p) }
    }

    private func row(_ k: LabKind, _ p: ProfileSnapshot) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.tight) {
            HStack {
                VStack(alignment: .leading, spacing: Theme.Space.hairline) {
                    Text(k.label)
                    if k.units.count > 1 {
                        Menu {
                            Picker("单位", selection: Binding(get: { unit(k) }, set: { u in
                                units[k] = u
                                UserDefaults.standard.set(u, forKey: "lab.unit." + k.rawValue)
                            })) {
                                ForEach(k.units, id: \.self) { Text($0).tag($0) }
                            }
                        } label: {
                            HStack(spacing: Theme.Space.hairline) {
                                Text(unit(k))
                                Image(systemName: "chevron.up.chevron.down").imageScale(.small)
                            }
                            .font(.footnote)
                        }
                        .accessibilityLabel("单位：\(unit(k))")
                    } else {
                        Text(k.unit).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                TextField("—", text: Binding(get: { texts[k] ?? "" }, set: { texts[k] = $0 }))
                    .keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(width: 90)
            }
            if let raw = typed(k), let v = value(k) {
                if k.plausible.contains(v) {
                    if unit(k) != k.unit { Text("约 \(k.format(v)) \(k.unit)").font(.subheadline).foregroundStyle(.secondary) }
                    StatusLabel(LabAnalyzer.status(k, v, profile: p).metric).font(.subheadline)
                } else if let other = k.units.first(where: { $0 != unit(k) && k.plausible.contains(k.standard(raw, unit: $0)) }) {
                    StatusLabel(.attention("这个数值像是 \(other)，点单位换一下")).font(.subheadline)
                } else {
                    StatusLabel(.attention("数值好像不对，请对照化验单和单位")).font(.subheadline)
                }
            }
        }
    }

    private func save(_ p: ProfileSnapshot) {
        let day = date.startOfDay.adding(minutes: 8 * 60)
        var added: [LabPoint] = []
        for (k, v) in entered {
            let r = LabResult(date: day, kind: k, value: v)
            r.note = note
            ctx.insert(r)
            added.append(r.point)
        }
        if value(.egfr) == nil, let cr = value(.creatinine), LabKind.creatinine.plausible.contains(cr),
           let e = LabAnalyzer.ckdEPI(creatinine: cr, age: p.age, sex: p.sex) {
            let r = LabResult(date: day, kind: .egfr, value: e.rounded(), estimated: true)
            r.note = note
            ctx.insert(r)
            added.append(r.point)
        }
        if let c = LabAnalyzer.alert(for: added, history: labs.map(\.point), profile: p) { DataHub.addEvent(c, in: ctx) }
        try? ctx.save()
    }
}

struct StressLogForm: View {
    @Environment(\.modelContext) private var ctx
    let initialDate: Date
    @State private var date = Date.app
    @State private var stress: Int? = nil

    var body: some View {
        Form {
            DatePicker("日期", selection: $date, in: ...Date.app, displayedComponents: .date)
            Section("今天的压力感受") {
                RatingPicker(value: $stress, lowLabel: "很放松", highLabel: "压力很大")
            }
            if (stress ?? 0) >= 4 {
                Section("可以试试") {
                    BulletText(text: "慢呼吸：吸气 4 秒、呼气 6 秒，持续 5 分钟。")
                    BulletText(text: "10 分钟户外散步，或轻柔拉伸。")
                    BulletText(text: "把明天的待办写下来，减少睡前反复思考。")
                }
            }
        }
        .onAppear { date = initialDate; stress = DataHub.record(for: date, in: ctx).stress }
        .saveToolbar {
            let r = DataHub.record(for: date, in: ctx)
            r.stress = stress
            r.toggle(.highStress, on: (stress ?? 0) >= 4)
        }
    }
}

struct ContextLogForm: View {
    @Environment(\.modelContext) private var ctx
    let initialDate: Date
    @State private var date = Date.app
    @State private var tags: Set<ContextTag> = []

    var body: some View {
        Form {
            DatePicker("日期", selection: $date, in: ...Date.app, displayedComponents: .date)
            Section {
                FlowLayout(spacing: Theme.Space.item) {
                    ForEach(ContextTag.pickable) { t in
                        ToggleChip(text: t.label, icon: t.icon, isOn: Binding(
                            get: { tags.contains(t) },
                            set: { if $0 { tags.insert(t) } else { tags.remove(t) } }))
                    }
                }
                .padding(.vertical, Theme.Space.tight)
            } header: {
                Text("当天的特殊状况")
            } footer: {
                Text("这些背景会用于解释静息心率和准备度的变化，例如生病、出差或经期时数值偏高是常见的。")
            }
        }
        .onAppear { date = initialDate; tags = DataHub.record(for: date, in: ctx).tags }
        .onChange(of: date) { _, d in tags = DataHub.record(for: d, in: ctx).tags }
        .saveToolbar {
            let r = DataHub.record(for: date, in: ctx)
            let derived = r.tags.subtracting(ContextTag.pickable)
            r.tags = derived.union(tags)
            r.illnessSymptoms = tags.contains(.illness)
        }
    }
}

// MARK: - Swelling and urine (水肿与尿量)

/// One day's swelling, urine and foam, for kidney disease, heart failure, a fluid limit or dialysis.
/// Two days of marked swelling or less urine raise an event (`KidneySigns.alert`).
struct KidneySignsLogForm: View {
    @Environment(\.modelContext) private var ctx
    @Query private var profiles: [UserProfile]
    let initialDate: Date
    @State private var date = Date.app
    @State private var edema: Edema?
    @State private var places: Set<String> = []
    @State private var urine: UrineAmount?
    @State private var urineMl: Double?
    @State private var foamy = false
    @State private var pdSigns: Set<String> = []

    var body: some View {
        let dialysis = profiles.first?.dialysis == true
        let peritoneal = dialysis && profiles.first?.dialysisModeRaw == DialysisMode.peritoneal.rawValue
        Form {
            DatePicker("日期", selection: $date, in: ...Date.app, displayedComponents: .date)
            Section {
                Picker("水肿", selection: $edema) {
                    Text("没填").tag(Edema?.none)
                    ForEach(Edema.allCases) { Text($0.label).tag(Optional($0)) }
                }
                .pickerStyle(.segmented)
                if let e = edema {
                    Text(e.detail).font(.subheadline).foregroundStyle(.secondary)
                    if e != .none {
                        FlowLayout(spacing: Theme.Space.item) {
                            ForEach(KidneySigns.places, id: \.self) { f in
                                ToggleChip(text: f, isOn: Binding(get: { places.contains(f) }, set: { if $0 { places.insert(f) } else { places.remove(f) } }))
                            }
                        }
                        .padding(.vertical, Theme.Space.tight)
                    }
                }
            } header: {
                Text("水肿")
            } footer: {
                Text("用手指按脚踝或小腿前面几秒，松开后留下小坑就是水肿。")
            }
            Section {
                Picker("尿量", selection: $urine) {
                    Text("没填").tag(UrineAmount?.none)
                    ForEach(UrineAmount.allCases) { Text($0.label).tag(Optional($0)) }
                }
                HStack {
                    Text("量过 24 小时尿量")
                    Spacer()
                    TextField("可不填", text: $urineMl.text()).keyboardType(.numberPad).multilineTextAlignment(.trailing).frame(width: 80)
                    Text("ml").foregroundStyle(.secondary)
                }
                Toggle("尿里泡沫多，久久不散", isOn: $foamy)
            } header: {
                Text("尿")
            } footer: {
                Text(peritoneal ? "腹透的人保住剩下的尿量很重要，尿明显变少要告诉腹透中心。"
                     : (dialysis ? "透析后尿量少很常见，按透析中心的要求记。" : "尿量连续两天比平时少，或者同时脚肿、体重涨，要尽快联系医生。"))
            }
            if peritoneal {
                Section {
                    FlowLayout(spacing: Theme.Space.item) {
                        ForEach(KidneySigns.pdWarnings, id: \.self) { f in
                            ToggleChip(text: f, isOn: Binding(get: { pdSigns.contains(f) }, set: { if $0 { pdSigns.insert(f) } else { pdSigns.remove(f) } }))
                        }
                    }
                    .padding(.vertical, Theme.Space.tight)
                    if KidneySigns.peritonitis(Array(pdSigns)) {
                        StatusLabel(.urgent("可能是腹膜炎，请立即联系腹透中心或去急诊")).font(.subheadline)
                    }
                } header: {
                    Text("腹透")
                } footer: {
                    Text("透出液浑浊、肚子疼或发烧，可能是腹膜炎：保存后马上联系腹透中心，把那袋透出液带上。")
                }
            }
        }
        .onAppear { date = initialDate; load(date) }
        .onChange(of: date) { _, d in load(d) }
        .saveToolbar {
            let r = DataHub.record(for: date, in: ctx)
            r.edema = edema?.rawValue
            r.edemaPlaces = edema == nil || edema == Edema.none ? [] : KidneySigns.places.filter(places.contains)
            r.urineOutput = urine?.rawValue
            r.urineMl = urineMl.flatMap { (50...6000).contains($0) ? Int($0) : nil }
            r.foamyUrine = foamy ? true : (edema != nil || urine != nil ? false : nil)
            r.pdSigns = KidneySigns.pdWarnings.filter(pdSigns.contains)
            try? ctx.save()
            DataHub.refreshAlerts(in: ctx)
        }
    }

    private func load(_ d: Date) {
        let r = DataHub.record(for: d, in: ctx)
        edema = r.edema.flatMap(Edema.init)
        places = Set(r.edemaPlaces)
        urine = r.urineOutput.flatMap(UrineAmount.init)
        urineMl = r.urineMl.map(Double.init)
        foamy = r.foamyUrine == true
        pdSigns = Set(r.pdSigns)
    }
}

// MARK: - Symptoms (create events immediately)

struct SymptomLogForm: View {
    @Environment(\.modelContext) private var ctx
    @Environment(\.dismiss) private var dismiss
    @Query private var profiles: [UserProfile]
    @Query private var meds: [MedicationEntry]
    @State private var symptom: Symptom = .palpitations
    @State private var time = Date.app
    @State private var note = ""
    @State private var saved: AlertCandidate?

    var body: some View {
        Form {
            if let c = saved {
                Section {
                    StatusLabel(text: c.severity.label, icon: c.severity.icon, color: Theme.severity(c.severity)).font(.headline)
                    Text(c.guidance).fixedSize(horizontal: false, vertical: true)
                    if c.severity == .urgent {
                        Link(destination: URL(string: "tel://120")!) {
                            Label("拨打 120", systemImage: "phone.fill").frame(maxWidth: .infinity).fontWeight(.bold)
                        }
                        .buttonStyle(.borderedProminent).tint(.red)
                    }
                } footer: {
                    Text("已加入「异常与跟进」，你可以在那里记录复测、就医和处理结果。")
                }
                Button("完成") { dismiss() }
            } else {
                Section("症状") {
                    Picker("症状", selection: $symptom) {
                        ForEach(Symptom.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
                if symptom.severity == .urgent {
                    Callout(kind: .urgent, title: "如果症状正在发生", text: AlertEngine.emergencyLine)
                }
                Section("背景") {
                    DatePicker("时间", selection: $time, in: ...Date.app)
                    TextField("当时在做什么、持续多久、心率读数等", text: $note, axis: .vertical)
                }
            }
        }
        .toolbar {
            if saved == nil {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        let p = profiles.first?.snapshot(medications: meds) ?? ProfileSnapshot()
                        let c = AlertEngine.symptomEvent(symptom, at: time, note: note, profile: p)
                        DataHub.addEvent(c, in: ctx)
                        try? ctx.save()
                        withAnimation { saved = c }
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }
}

// MARK: - Vitals with context (需求 8)

struct VitalLogForm: View {
    @Environment(\.modelContext) private var ctx
    @Environment(\.dismiss) private var dismiss
    @Query private var profiles: [UserProfile]
    @Query private var meds: [MedicationEntry]
    @State var kind: VitalKind
    @State private var time = Date.app
    @State private var value: Double? = nil
    @State private var value2: Double? = nil
    @State private var pulse: Double? = nil
    @State private var context: MeasureContext = .random
    @State private var medsTaken: Bool? = nil
    @State private var note = ""
    @State private var result: AlertCandidate?
    @State private var savedNoAlert = false
    /// The saved reading, when it is out of range: a chance to note why.
    @State private var saved: VitalReading?
    @State private var agentQuestion: String?

    private var kinds: [VitalKind] {
        switch kind {
        case .bloodPressure: [.bloodPressure]
        case .glucose: [.glucose]
        case .lactate: [.lactate]   // professional sports module only
        default: [.heartRate, .spo2, .weight, .temperature]
        }
    }

    var body: some View {
        let profile = profiles.first
        Form {
            if let r = result {
                Section {
                    StatusLabel(text: r.title, icon: r.severity.icon, color: Theme.severity(r.severity)).font(.headline)
                    Text(r.detail)
                    Text(r.guidance).fixedSize(horizontal: false, vertical: true)
                    if r.severity == .urgent {
                        Link(destination: URL(string: "tel://120")!) {
                            Label("拨打 120", systemImage: "phone.fill").frame(maxWidth: .infinity).fontWeight(.bold)
                        }
                        .buttonStyle(.borderedProminent).tint(.red)
                    }
                } footer: { Text("已加入「异常与跟进」，请按建议复测或就医，并记录处理结果。") }
                recallSection
                Button("完成") { dismiss() }
            } else if savedNoAlert {
                Section { StatusLabel(text: "已保存", icon: "checkmark.circle.fill", color: .green) }
                recallSection
                Button("完成") { dismiss() }
            } else {
                if kinds.count > 1 {
                    Picker("指标", selection: $kind) { ForEach(kinds) { Text($0.label).tag($0) } }
                        .pickerStyle(.segmented)
                }
                Section {
                    switch kind {
                    case .bloodPressure:
                        numberRow("收缩压（高压）", $value, unit: "mmHg")
                        numberRow("舒张压（低压）", $value2, unit: "mmHg")
                        numberRow("脉搏（可选）", $pulse, unit: "bpm")
                    default:
                        numberRow(kind.label, $value, unit: kind.unit, decimals: [.glucose, .lactate, .temperature, .weight].contains(kind) ? 1 : 0)
                        if kind == .lactate { numberRow("当时心率（可选）", $pulse, unit: "bpm") }
                    }
                } footer: {
                    switch kind {
                    case .bloodPressure: Text("规范测量：测前安静坐 5 分钟，背部有支撑，袖带与心脏同高，测 2 次取平均。")
                    case .lactate: Text("乳酸数据需在标准化测试条件下、由专业人员指导采集，单次数值请结合测试方案解读。")
                    case .glucose: Text("单位 mmol/L。如使用 mg/dL，请除以 18。")
                    default: EmptyView()
                    }
                }
                Section("测量背景") {
                    DatePicker("时间", selection: $time, in: ...Date.app)
                    Picker("情境", selection: $context) { ForEach(MeasureContext.allCases) { Text($0.label).tag($0) } }
                    if meds.contains(where: \.isActive) {
                        Picker("测量前是否已服药", selection: $medsTaken) {
                            Text("未填写").tag(Bool?.none)
                            Text("已服药").tag(Bool?.some(true))
                            Text("未服药").tag(Bool?.some(false))
                        }
                    }
                    TextField(kind == .lactate ? "测试方案、阶段、配速等" : "备注（可选）", text: $note, axis: .vertical)
                }
                if kind == .glucose, let v = value, let p = profile {
                    Section("运动前参考（按你的照护计划阈值）") {
                        Text(GlucoseAnalyzer.preExerciseAdvice(glucose: v, profile: p.snapshot(medications: meds))).font(.subheadline)
                    }
                }
            }
        }
        .toolbar {
            if result == nil && !savedNoAlert {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .disabled(value == nil || (kind == .bloodPressure && value2 == nil))
                        .fontWeight(.semibold)
                }
            }
        }
    }

    private func numberRow(_ title: String, _ binding: Binding<Double?>, unit: String, decimals: Int = 0) -> some View {
        HStack {
            Text(title)
            Spacer()
            TextField("—", text: binding.text(decimals: decimals))
                .keyboardType(decimals > 0 ? .decimalPad : .numberPad)
                .multilineTextAlignment(.trailing).frame(width: 90)
            Text(unit).foregroundStyle(.secondary).frame(width: 52, alignment: .leading)
        }
    }

    /// After an out-of-range reading: recall what may have caused it, or ask the Health Agent.
    @ViewBuilder private var recallSection: some View {
        let p = profiles.first?.snapshot(medications: meds) ?? ProfileSnapshot()
        if let r = saved, let a = AbnormalReadings.check(r.point, profile: p) {
            Section {
                if r.note.isEmpty {
                    NavigationLink {
                        AbnormalNoteForm(reading: r, abnormal: a, onAsk: { agentQuestion = $0 })
                            .navigationTitle("回想一下原因").navigationBarTitleDisplayMode(.inline)
                    } label: {
                        Label("记下可能的原因", systemImage: "square.and.pencil")
                    }
                } else {
                    Label(r.note, systemImage: "note.text").foregroundStyle(.secondary)
                }
                Button { agentQuestion = a.question(at: r.time, causes: [], text: r.note) } label: {
                    Label(AgentNameSettings.shared.phrase("问问", "可能的原因"), systemImage: "sparkles")
                }
            } header: {
                Text("\(a.title)，回想一下原因")
            } footer: {
                Text(AgentNameSettings.shared.phrase("记下当时的情况，复盘和", "会参考，更容易找到规律。"))
            }
            .sheet(item: Binding(get: { agentQuestion.map(AgentPrompt.init) }, set: { agentQuestion = $0?.text })) { q in
                HealthAgentChatView(initialQuestion: q.text)
            }
        }
    }

    private struct AgentPrompt: Identifiable {
        let text: String
        var id: String { text }
    }

    private func save() {
        guard let v = value else { return }
        let reading = VitalReading(time: time, kind: kind, value: v, value2: kind == .bloodPressure ? value2 : nil, context: context)
        reading.pulse = pulse
        reading.medsTaken = medsTaken
        reading.note = note
        ctx.insert(reading)
        saved = reading
        if kind == .temperature && v >= 37.5 { DataHub.record(for: time, in: ctx).toggle(.illness, on: true) }
        let p = profiles.first?.snapshot(medications: meds) ?? ProfileSnapshot()
        // A weight is judged against the last few days: a quick rise may be retained fluid.
        let weights = kind == .weight
            ? ((try? ctx.fetch(FetchDescriptor<VitalReading>())) ?? []).filter { $0.kind == .weight && $0.time > time.adding(days: -4) }.map(\.point) + [reading.point]
            : []
        if let c = AlertEngine.evaluateVital(reading.point, profile: p) ?? AlertEngine.weightAlert(weights, profile: p, now: max(time, .app))
            ?? Dialysis.alert(weights, profile: p, now: max(time, .app)),
           DataHub.addEvent(c, in: ctx) != nil {
            withAnimation { result = c }
        } else {
            DataHub.refreshAlerts(in: ctx)
            withAnimation { savedNoAlert = true }
        }
        try? ctx.save()
    }
}

// MARK: - Sleep (manual, for nights without a device)

struct SleepLogForm: View {
    @Environment(\.modelContext) private var ctx
    @Query private var profiles: [UserProfile]
    let initialDate: Date
    @State private var date = Date.app
    @State private var bed = Date.app
    @State private var wake = Date.app
    @State private var feel: Int? = nil
    @State private var snoring = false
    @State private var gasping = false
    @State private var witnessed = false
    @State private var headache = false
    @State private var cpap: Double? = nil

    var body: some View {
        let p = profiles.first
        Form {
            DatePicker("醒来的日期", selection: $date, in: ...Date.app, displayedComponents: .date)
            Section("时间") {
                DatePicker("入睡", selection: $bed, displayedComponents: .hourAndMinute)
                DatePicker("醒来", selection: $wake, displayedComponents: .hourAndMinute)
                Text("约 \((Double(minutes) / 60).oneDecimal) 小时").foregroundStyle(.secondary)
            }
            Section("睡眠感受") {
                RatingPicker(value: $feel, lowLabel: "很差", highLabel: "很好")
            }
            Section {
                Toggle("打鼾（自己或家人察觉）", isOn: $snoring)
                Toggle("憋醒 / 喘息着醒来", isOn: $gasping)
                Toggle("有人观察到呼吸暂停", isOn: $witnessed)
                Toggle("晨起头痛", isOn: $headache)
                if p?.apneaTreatment == .cpap {
                    HStack {
                        Text("CPAP 使用时长")
                        Spacer()
                        TextField("小时", text: $cpap.text(decimals: 1)).keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(width: 70)
                        Text("小时").foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("睡眠呼吸线索")
            } footer: {
                Text("这些线索不能用于诊断，但持续记录有助于判断是否需要专业睡眠评估。")
            }
        }
        .onAppear {
            date = initialDate
            let r = DataHub.record(for: date, in: ctx)
            bed = r.sleepStart ?? date.startOfDay.adding(minutes: (p?.bedtimeMinutes ?? 1380) - 1440)
            wake = r.sleepEnd ?? date.startOfDay.adding(minutes: p?.wakeMinutes ?? 420)
            feel = r.sleepFeel; snoring = r.snoring; gasping = r.gasping; witnessed = r.witnessedApnea
            headache = r.morningHeadache; cpap = r.cpapHours
        }
        .saveToolbar {
            let r = DataHub.record(for: date, in: ctx)
            let wakeAt = date.startOfDay.adding(minutes: wake.minutesOfDay)
            let bedAt = wakeAt.adding(minutes: -minutes)
            r.sleepStart = bedAt; r.sleepEnd = wakeAt; r.sleepMinutes = Double(minutes)
            r.markManual("sleep")
            r.sleepFeel = feel; r.snoring = snoring; r.gasping = gasping; r.witnessedApnea = witnessed
            r.morningHeadache = headache; r.cpapHours = cpap
        }
    }

    private var minutes: Int {
        (wake.minutesOfDay - bed.minutesOfDay + 1440) % 1440
    }
}

// MARK: - Workout

struct WorkoutLogForm: View {
    @Environment(\.modelContext) private var ctx
    @Query private var profiles: [UserProfile]
    @Query(sort: \PlanItem.day) private var planItems: [PlanItem]
    let initialDate: Date
    var planItemID: UUID?
    @State private var type: WorkoutType = .walk
    @State private var start = Date.app
    @State private var minutes = 30.0
    @State private var rpe = 4.0
    @State private var avgHR: Double? = nil
    @State private var distance: Double? = nil
    @State private var carbs: Double? = nil
    @State private var fluid: Double? = nil
    @State private var linkedID: UUID? = nil
    @State private var feeling: WorkoutFeeling? = nil
    @State private var note = ""

    private static let rpeText = ["", "非常轻松", "很轻松", "轻松", "适中", "有点吃力", "吃力", "很吃力", "非常吃力", "接近极限", "极限"]

    var body: some View {
        let week = planItems.filter { $0.weekStart == start.weekStart && $0.kind.isTraining }
        let showFuel = minutes >= 75 || (profiles.first?.hasModule(.marathon) ?? false) || (profiles.first?.hasModule(.diabetesCare) ?? false)
        Form {
            Section {
                Picker("类型", selection: $type) {
                    ForEach(WorkoutType.allCases) { Label($0.label, systemImage: $0.icon).tag($0) }
                }
                DatePicker("开始时间", selection: $start, in: ...Date.app)
                Stepper("时长 \(Int(minutes)) 分钟", value: $minutes, in: 5...360, step: 5)
            }
            Section {
                VStack(alignment: .leading) {
                    HStack {
                        Text("主观用力程度")
                        Spacer()
                        Text("\(Int(rpe)) · \(Self.rpeText[Int(rpe)])").foregroundStyle(.secondary)
                    }
                    Slider(value: $rpe, in: 1...10, step: 1)
                }
                row("平均心率（可选）", $avgHR, "bpm")
                if [.run, .walk, .cycle, .swim].contains(type) { row("距离（可选）", $distance, "km", 1) }
            } header: {
                Text("强度")
            } footer: {
                Text("用力程度 × 时长用于估算训练负荷，进而影响准备度判断。")
            }
            Section {
                HStack(spacing: Theme.Space.item) {
                    ForEach(WorkoutFeeling.allCases) { f in
                        let on = feeling == f
                        Button { feeling = on ? nil : f } label: {
                            VStack(spacing: Theme.Space.tight) {
                                Image(systemName: f.icon)
                                Text(f.label).font(.caption)
                            }
                            .frame(maxWidth: .infinity, minHeight: Theme.Size.tap + Theme.Space.item)
                            .foregroundStyle(on ? Color.white : .primary)
                            .background(on ? (f == .unwell ? Color.red : Color.accentColor) : Theme.subtle, in: RoundedRectangle(cornerRadius: Theme.Radius.inner, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
                if feeling == .unwell {
                    Callout(kind: .urgent, text: "运动中出现胸痛、明显气短、头晕或心悸时，请停止运动；可在「症状」中记录，便于跟进。")
                }
            } header: { Text("运动感受") }
            if showFuel {
                Section {
                    row("碳水补给", $carbs, "g")
                    row("饮水", $fluid, "ml")
                } header: { Text("运动补给") } footer: {
                    let plan = MarathonPlanner.fuelPlan(minutes: Int(minutes), carbsPerHour: profiles.first?.fuelCarbsPerHour ?? 45)
                    Text(plan.carbs > 0 ? "参考：本次约 \(plan.carbs) g 碳水，饮水 \(plan.fluidLow)–\(plan.fluidHigh) ml。\(plan.note)" : plan.note)
                }
            }
            if !week.isEmpty {
                Section("对应本周计划") {
                    Picker("计划项目", selection: $linkedID) {
                        Text("不关联").tag(UUID?.none)
                        ForEach(week) { item in
                            Text("\(Weekday.name(item.day.weekday)) · \(item.title)").tag(UUID?.some(item.id))
                        }
                    }
                }
            }
            TextField("备注（可选）", text: $note, axis: .vertical)
        }
        .onAppear {
            if !initialDate.isSameDay(.app) { start = initialDate.startOfDay.adding(minutes: 19 * 60) }
            linkedID = planItemID
            if let id = planItemID, let item = planItems.first(where: { $0.id == id }) {
                minutes = Double(item.minutes)
                rpe = Double([1, 3, 5, 7][item.intensity.order])
                type = item.kind == .strength ? .strength : (item.kind == .mobility ? .yoga : .walk)
            }
        }
        .saveToolbar {
            let s = ActivitySession(start: start, type: type, minutes: minutes, source: .manual)
            s.rpe = Int(rpe); s.avgHR = avgHR; s.distanceKm = distance
            s.carbsG = carbs; s.fluidMl = fluid; s.note = note; s.planItemID = linkedID
            s.feeling = feeling
            ctx.insert(s)
            if let id = linkedID, let item = planItems.first(where: { $0.id == id }) {
                let done = (item.completedMinutes ?? 0) + Int(minutes)
                item.completedMinutes = done
                item.status = Double(done) >= Double(item.minutes) * 0.8 ? .done : .partial
            }
            if rpe >= 7 { DataHub.record(for: start, in: ctx).toggle(.hardTraining, on: true) }
        }
    }

    private func row(_ title: String, _ b: Binding<Double?>, _ unit: String, _ decimals: Int = 0) -> some View {
        HStack {
            Text(title)
            Spacer()
            TextField("—", text: b.text(decimals: decimals)).keyboardType(decimals > 0 ? .decimalPad : .numberPad)
                .multilineTextAlignment(.trailing).frame(width: 80)
            Text(unit).foregroundStyle(.secondary)
        }
    }
}
