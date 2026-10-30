import SwiftUI
import SwiftData
import Charts

extension GlucoseModelInput {
    /// Glucose readings and logged meals as the model takes them.
    init(vitals: [VitalPoint], meals: [MealLog], profile: ProfileSnapshot, now: Date = .app) {
        self.init(glucose: vitals.filter { $0.kind == .glucose }.map { ($0.time, $0.value) },
                  meals: meals.map { MealInfo(time: $0.time, kind: $0.kind, carbs: $0.carbsG, note: $0.note) },
                  profile: profile, now: now)
    }
}

extension GlucoseProfile.Level {
    var glyph: (icon: String, color: Color) {
        switch self {
        case .normal: ("checkmark.seal.fill", .green)
        case .watch: ("exclamationmark.circle.fill", .orange)
        case .consult: ("stethoscope.circle.fill", .red)
        case .insufficient: ("hourglass.circle.fill", .gray)
        }
    }
}

/// 血糖代谢画像: control against common targets, signs of reduced insulin sensitivity with their
/// evidence, how each meal moves glucose, and what a meal will probably do — as signs, never a diagnosis.
struct GlucoseProfileView: View {
    @Query private var profiles: [UserProfile]
    @Query private var meds: [MedicationEntry]
    @Query(sort: \VitalReading.time) private var vitals: [VitalReading]
    @Query(sort: \MealLog.time) private var meals: [MealLog]
    @State private var kind: MealKind = .lunch
    @State private var carbs: Double?

    var body: some View {
        let snap = profiles.first?.snapshot(medications: meds) ?? ProfileSnapshot()
        let input = GlucoseModelInput(vitals: vitals.map(\.point), meals: meals, profile: snap)
        let model = GlucoseModels.current
        ScreenScroll {
            if let p = model.profile(input) {
                summary(p)
                if p.level != .insufficient {
                    controlCard(p)
                    signsCard(p)
                    if !p.meals.isEmpty { mealsCard(p) }
                    predictionCard(input, model: model, profile: p)
                }
            }
            PageFootnote("分析方式：\(model.name)，参考国际 CGM 共识与常用的血糖参考值。这些是迹象，不是诊断；是否存在胰岛素抵抗或糖代谢异常，需要化验确认。今后可以接入经过验证的模型（例如 Google GlucoFM）来补充分析。")
        }
        .navigationTitle("血糖代谢画像").calmStyle()
        .navigationBarTitleDisplayMode(.inline)
    }

    private func summary(_ p: GlucoseProfile) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.item) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.iconGap) {
                Image(systemName: p.level.glyph.icon).imageScale(.small).foregroundStyle(p.level.glyph.color).accessibilityHidden(true)
                Text(p.title).fixedSize(horizontal: false, vertical: true)
            }
            .font(.title3.weight(.semibold))
            Text(p.summary).font(.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if !p.tests.isEmpty {
                Text("\(Text("建议检查：").fontWeight(.semibold).foregroundStyle(.primary))\(p.tests)")
                    .font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Divider().padding(.top, Theme.Space.tight)
            Text(p.by).font(.footnote).foregroundStyle(.secondary)
        }
        .cardSurface()
        .accessibilityElement(children: .combine)
    }

    private func controlCard(_ p: GlucoseProfile) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.tight) {
            CardTitle("血糖控制", detail: "近 \(p.days) 天")
            ForEach(Array(p.indicators.enumerated()), id: \.offset) { i, x in
                HStack(alignment: .firstTextBaseline, spacing: Theme.Space.block) {
                    VStack(alignment: .leading, spacing: Theme.Space.hairline) {
                        Text(x.name).font(.subheadline)
                        Text(x.reference).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: Theme.Space.item)
                    statusValue(x)
                }
                .padding(.vertical, Theme.Space.item)
                .accessibilityElement(children: .combine)
                if i < p.indicators.count - 1 { Divider() }
            }
        }
        .cardSurface()
    }

    @ViewBuilder private func statusValue(_ x: GlucoseProfile.Indicator) -> some View {
        let value = Text(x.value).font(.subheadline.weight(.semibold)).monospacedDigit()
        switch x.status {
        case .good: StatusLabel(text: x.value, icon: "checkmark.circle.fill", color: .green).font(.subheadline.weight(.semibold)).monospacedDigit()
        case .attention: StatusLabel(text: x.value, icon: "exclamationmark.circle.fill", color: .orange).font(.subheadline.weight(.semibold)).monospacedDigit()
        case .concern: StatusLabel(text: x.value, icon: "exclamationmark.triangle.fill", color: .red).font(.subheadline.weight(.semibold)).monospacedDigit()
        case .info: value
        }
    }

    private func signsCard(_ p: GlucoseProfile) -> some View {
        let glyphColumn: CGFloat = 22
        return VStack(alignment: .leading, spacing: Theme.Space.tight) {
            CardTitle(p.hasDiabetes ? "代谢迹象" : "胰岛素抵抗迹象", detail: "\(p.signs.filter(\.present).count)/\(p.signs.count) 项")
            ForEach(Array(p.signs.enumerated()), id: \.offset) { i, s in
                HStack(alignment: .firstTextBaseline, spacing: Theme.Space.iconGap) {
                    Image(systemName: s.present ? (s.strong ? "exclamationmark.triangle.fill" : "exclamationmark.circle.fill") : "checkmark.circle.fill")
                        .font(.subheadline).imageScale(.small)
                        .foregroundStyle(s.present ? (s.strong ? Color.red : Color.orange) : Color.green)
                        .frame(width: glyphColumn)
                    VStack(alignment: .leading, spacing: Theme.Space.hairline) {
                        Text(s.present ? s.title : s.absent).font(.subheadline.weight(s.present ? .semibold : .regular))
                        Text(s.evidence).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.vertical, Theme.Space.item)
                .accessibilityElement(children: .combine)
                if i < p.signs.count - 1 { Divider().padding(.leading, glyphColumn + Theme.Space.iconGap) }
            }
            Text(p.hasDiabetes ? "这些迹象可以和医生一起看；是否调整治疗由医生决定。"
                               : "CGM 只能看到迹象。胰岛素抵抗要通过空腹血糖和胰岛素（HOMA-IR）或口服糖耐量试验来确认。")
                .font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(.top, Theme.Space.tight)
        }
        .cardSurface()
    }

    private func mealsCard(_ p: GlucoseProfile) -> some View {
        let colors: [MealKind: Color] = [.breakfast: .orange, .lunch: Theme.nutrition, .dinner: Theme.glucose]
        return VStack(alignment: .leading, spacing: Theme.Space.block) {
            CardTitle("饭后反应", detail: "比饭前升高多少")
            Chart {
                ForEach(p.meals) { m in
                    ForEach(Array(m.curve.enumerated()), id: \.offset) { i, r in
                        LineMark(x: .value("分钟", i * 15), y: .value("升高", r), series: .value("餐", m.kind.label))
                            .foregroundStyle(by: .value("餐", m.kind.label))
                            .interpolationMethod(.monotone)
                    }
                }
                RuleMark(y: .value("饭前", 0)).foregroundStyle(Color.secondary.opacity(0.4))
            }
            .chartForegroundStyleScale(domain: p.meals.map(\.kind.label), range: p.meals.map { colors[$0.kind] ?? .gray })
            .chartXAxis { AxisMarks(values: [0, 60, 120, 180]) { v in AxisGridLine(); AxisValueLabel { Text("\(v.as(Int.self) ?? 0) 分") } } }
            .chartYAxis { AxisMarks(position: .trailing) }
            .frame(height: 150)
            .accessibilityLabel("各餐饭后 3 小时的平均血糖升高曲线")
            ForEach(p.meals) { m in
                HStack(spacing: Theme.Space.item) {
                    HStack(spacing: Theme.Space.iconGap) {
                        Circle().fill(colors[m.kind] ?? .gray).frame(width: 8, height: 8).accessibilityHidden(true)
                        Text(m.kind.label).font(.subheadline.weight(.semibold))
                    }
                    Text("+\(m.rise.oneDecimal) · \(m.peakMinutes) 分钟达峰 · " + (m.backMinutes.map { "\(RuleGlucoseModel.duration($0))回落" } ?? "3 小时内未回落"))
                        .font(.footnote).foregroundStyle(.secondary).monospacedDigit()
                    Spacer(minLength: 0)
                    Text("\(m.count) 餐").font(.footnote).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .cardSurface()
    }

    private func predictionCard(_ input: GlucoseModelInput, model: GlucoseMetabolismModel, profile p: GlucoseProfile) -> some View {
        let past = input.meals.filter { $0.kind == kind }.compactMap(\.carbs)
        let typical = Stats.median(past).map { ($0 / 5).rounded() * 5 }
        let prediction = model.predict(input, kind: kind, carbs: carbs ?? typical, at: nil)
        let line = p.hasDiabetes ? 10.0 : 7.8
        return VStack(alignment: .leading, spacing: Theme.Space.block) {
            CardTitle("饭后血糖预测")
            Picker("餐次", selection: $kind) {
                ForEach([MealKind.breakfast, .lunch, .dinner], id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .onChange(of: kind) { _, _ in carbs = nil }
            if let t = typical {
                Stepper(value: Binding(get: { carbs ?? t }, set: { carbs = $0 }), in: 10...200, step: 10) {
                    Text("这一餐约 \(Int(carbs ?? t)) g 碳水").font(.subheadline)
                }
            }
            if let pr = prediction {
                Chart {
                    RuleMark(y: .value("参考", line)).lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4])).foregroundStyle(Color.gray)
                    ForEach(pr.points, id: \.minutes) { pt in
                        AreaMark(x: .value("分钟", pt.minutes), yStart: .value("低", pt.low), yEnd: .value("高", pt.high))
                            .foregroundStyle(Theme.glucose.opacity(0.15)).interpolationMethod(.monotone)
                        LineMark(x: .value("分钟", pt.minutes), y: .value("mmol/L", pt.mid))
                            .foregroundStyle(Theme.glucose).lineStyle(StrokeStyle(lineWidth: 2, dash: [4, 3])).interpolationMethod(.monotone)
                    }
                }
                .chartXAxis { AxisMarks(values: [0, 60, 120, 180]) { v in AxisGridLine(); AxisValueLabel { Text("\(v.as(Int.self) ?? 0) 分") } } }
                .chartYAxis { AxisMarks(position: .trailing) }
                .chartYScale(domain: max(2, (pr.points.map(\.low).min() ?? 4) - 1)...max(line + 1, (pr.points.map(\.high).max() ?? 10) + 0.5))
                .frame(height: 140)
                .accessibilityLabel("\(kind.label)饭后 3 小时血糖预测")
                .accessibilityValue("峰值约 \(pr.peak.low.oneDecimal) 到 \(pr.peak.high.oneDecimal)")
                Text("虚线为预测，浅色带为可能的范围；灰色虚线为 \(line.oneDecimal) mmol/L。").font(.caption).foregroundStyle(.secondary)
                Text(pr.message).font(.subheadline).fixedSize(horizontal: false, vertical: true)
                Text(MealPrediction.caveat).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                Text("记录几次\(kind.label)的进餐时间后，就能按你自己的饭后反应来预测。").font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .cardSurface()
    }
}

/// The way in from 趋势 › 关键指标 and 血糖管理: the profile's conclusion in one line.
struct GlucoseProfileEntry: View {
    @Query private var profiles: [UserProfile]
    @Query private var meds: [MedicationEntry]
    @Query(sort: \VitalReading.time) private var vitals: [VitalReading]
    @Query(sort: \MealLog.time) private var meals: [MealLog]

    var body: some View {
        let snap = profiles.first?.snapshot(medications: meds) ?? ProfileSnapshot()
        let input = GlucoseModelInput(vitals: vitals.map(\.point), meals: meals, profile: snap)
        if input.glucose.count >= 48, let p = GlucoseModels.current.profile(input) {
            NavigationLink { GlucoseProfileView() } label: {
                HStack(spacing: Theme.Space.block) {
                    IconTile(icon: "chart.xyaxis.line", color: Theme.glucose)
                    VStack(alignment: .leading, spacing: Theme.Space.hairline) {
                        Text("血糖代谢画像").font(.headline)
                        StatusLabel(text: p.title, icon: p.level.glyph.icon, color: p.level.glyph.color, secondaryText: true)
                            .font(.subheadline).lineLimit(2)
                    }
                    Spacer(minLength: Theme.Space.tight)
                    Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                }
                .cardSurface()
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
}
