import SwiftUI
import SwiftData
import Charts

/// 血糖管理：结论在前（当前血糖与趋势、近 14 天达标情况），然后是最近 24 小时曲线、
/// 关键指标、每日规律、餐后与运动反应、低血糖处理、生病日与检查随访。CGM 数据优先。
struct DiabetesCareView: View {
    @Environment(\.modelContext) private var ctx
    @Query private var profiles: [UserProfile]
    @Query private var meds: [MedicationEntry]
    @Query(sort: \VitalReading.time) private var vitals: [VitalReading]
    @Query(sort: \MealLog.time, order: .reverse) private var meals: [MealLog]
    @Query(sort: \ActivitySession.start, order: .reverse) private var sessions: [ActivitySession]
    @Query(sort: \HealthEvent.createdAt, order: .reverse) private var events: [HealthEvent]
    @Query(sort: \CareTask.createdAt, order: .reverse) private var tasks: [CareTask]
    @State private var log: QuickLogKind?
    @State private var addTask = false
    @State private var editTargets = false

    var body: some View {
        let p = profiles.first
        let snap = p?.snapshot(medications: meds) ?? ProfileSnapshot()
        let g = vitals.filter { $0.kind == .glucose }.map(\.point)
        let m = GlucoseAnalyzer.metrics(g.map { ($0.time, $0.value) }, low: snap.glucoseLow, high: snap.glucoseHigh)
        ScreenScroll {
            GlucoseHeroCard(points: g, metrics: m, profile: snap, onLog: { log = $0 })
            AbnormalRecallCard(kind: .glucose)
            GlucoseOutlookCard()
            if !g.isEmpty {
                Last24hCard(points: g, meals: meals, sessions: sessions, profile: snap)
                SectionTitle(title: "近 14 天", subtitle: m.isContinuous ? "CGM 覆盖 \(Int(m.coverage * 100))%" : "指尖血糖 \(m.readings) 次")
                metricsGrid(m)
                if m.isContinuous { AGPCard(points: g, profile: snap) }
                GlucoseProfileEntry()
                SectionTitle(title: "餐后与运动")
                mealCard(g, snap)
                exerciseCard(g, snap)
            }
            lowCard(g, snap)
            guidanceCard(snap)
            followUpCard
            PageFootnote("参考目标来自国际 CGM 共识，个人目标与处理方式请以医疗团队制定的照护计划为准。Pulse 不提供胰岛素或药物剂量建议。")
        }
        .navigationTitle("血糖管理").calmStyle()
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .primaryAction) { Button("目标范围") { editTargets = true } } }
        .sheet(item: $log) { QuickLogSheet(kind: $0) }
        .sheet(isPresented: $addTask) { AddCareTaskSheet(defaultTitle: "糖化血红蛋白（HbA1c）检测", area: .diabetes) }
        .sheet(isPresented: $editTargets) { if let p { GlucoseTargetsSheet(profile: p) } }
    }

    // MARK: 14-day metrics

    private func metricsGrid(_ m: GlucoseMetrics) -> some View {
        MetricGrid {
            HealthMetricCard(title: "目标范围内", icon: "target", color: Theme.glucose,
                             value: m.tir.map { "\(Int($0 * 100))" } ?? "—", unit: "%",
                             status: (m.tir ?? 0) >= 0.7 ? .good("达到参考 >70%") : .attention("低于参考 70%"))
            HealthMetricCard(title: "低于范围", icon: "arrow.down.circle", color: Theme.glucose,
                             value: m.tbr.map { String(format: "%.1f", $0 * 100) } ?? "—", unit: "%",
                             status: (m.tbr ?? 0) < 0.04 ? .good("低于参考 4%") : .attention("高于参考 4%"))
            HealthMetricCard(title: "平均血糖", icon: "equal.circle", color: Theme.glucose,
                             value: m.mean.map { $0.oneDecimal } ?? "—", unit: "mmol/L",
                             status: m.gmi.map { .neutral("GMI 估算 \($0.oneDecimal)%") } ?? .neutral("—"))
            HealthMetricCard(title: "波动", icon: "waveform", color: Theme.glucose,
                             value: m.cv.map { "\(Int($0))" } ?? "—", unit: "% CV",
                             status: (m.cv ?? 0) <= 36 ? .good("平稳（参考 ≤36%）") : .attention("波动较大"))
        }
    }

    // MARK: Meals & exercise

    private func mealCard(_ g: [VitalPoint], _ p: ProfileSnapshot) -> some View {
        let responses = GlucoseAnalyzer.mealResponses(g, meals: meals.map { MealInfo(time: $0.time, kind: $0.kind, carbs: $0.carbsG, note: $0.note) })
        let byKind = Dictionary(grouping: responses, by: \.kind).compactMapValues { Stats.mean($0.map(\.rise)) }
        return VStack(alignment: .leading, spacing: Theme.Space.block) {
            CardTitle(title: "餐后反应") {
                Button { log = .diet } label: { Label("记录饮食", systemImage: "plus") }.buttonStyle(.bordered)
            }
            if responses.isEmpty {
                EmptyLine("记录进餐时间后，可在 CGM 曲线上看到每餐后的血糖上升。")
            } else {
                HStack(spacing: 0) {
                    ForEach([MealKind.breakfast, .lunch, .dinner], id: \.self) { k in
                        VStack(alignment: .leading, spacing: Theme.Space.tight) {
                            Text("\(k.label)平均").font(.caption).foregroundStyle(.secondary)
                            Text(byKind[k].map { "+\($0.oneDecimal)" } ?? "—").font(.headline).monospacedDigit()
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityElement(children: .combine)
                    }
                }
                Divider()
                ForEach(responses.prefix(5)) { r in
                    HStack(spacing: Theme.Space.block) {
                        IconTile(icon: r.kind.icon, color: Theme.nutrition)
                        VStack(alignment: .leading, spacing: Theme.Space.hairline) {
                            Text("\(r.kind.label) · \(r.time.formatted(.dateTime.month().day())) \(Clock.text(r.time.minutesOfDay))").font(.subheadline)
                            Text([r.carbs.map { "\(Int($0)) g 碳水" } ?? "", r.note, "\(r.minutesToPeak) 分钟达峰 \(r.peak.oneDecimal)"]
                                .filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                        }
                        Spacer(minLength: Theme.Space.tight)
                        StatusLabel(r.rise >= 3 ? .attention("+\(r.rise.oneDecimal)") : .neutral("+\(r.rise.oneDecimal)")).font(.subheadline).monospacedDigit()
                    }
                    .frame(minHeight: Theme.Size.tap)
                    .accessibilityElement(children: .combine)
                }
                Text("餐后上升超过 3 mmol/L 时，可以留意这一餐的碳水量、进餐顺序和餐后活动。这些是观察到的关联，调整饮食前请与医疗团队讨论。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .cardSurface()
    }

    private func exerciseCard(_ g: [VitalPoint], _ p: ProfileSnapshot) -> some View {
        let responses = GlucoseAnalyzer.exerciseResponses(g, sessions: sessions.map(\.point))
        return VStack(alignment: .leading, spacing: Theme.Space.block) {
            CardTitle("运动前后")
            if responses.isEmpty { EmptyLine("佩戴 CGM 运动后，这里会显示运动前后的血糖变化。") }
            ForEach(responses.prefix(4)) { r in
                let delayedLow = (r.lowestNext12h ?? 99) < p.glucoseLow
                HStack(spacing: Theme.Space.block) {
                    IconTile(icon: r.type.icon, color: Theme.activity)
                    VStack(alignment: .leading, spacing: Theme.Space.hairline) {
                        Text("\(r.type.label) \(Int(r.minutes)) 分钟 · \(r.start.formatted(.dateTime.month().day()))").font(.subheadline)
                        Text("\(r.before.oneDecimal) → \(r.after.oneDecimal) mmol/L\(r.lowestNext12h.map { " · 之后 12 小时最低 \($0.oneDecimal)" } ?? "")")
                            .font(.footnote).foregroundStyle(.secondary).monospacedDigit()
                    }
                    Spacer(minLength: Theme.Space.tight)
                    StatusLabel(delayedLow ? .attention("延迟低血糖") : .neutral(r.change.signedText)).font(.footnote)
                }
                .frame(minHeight: Theme.Size.tap)
                .accessibilityElement(children: .combine)
            }
            Divider()
            IconTextRow(icon: "drop", color: Theme.glucose, title: "运动前",
                        text: "低于 \(p.glucosePreExerciseMin.oneDecimal) 先补充碳水；高于 \(p.glucoseExerciseMax.oneDecimal) 按照护计划处理，1 型糖尿病先查酮体。")
            IconTextRow(icon: "timer", color: Theme.activity, title: "运动超过 1 小时",
                        text: "每 30–60 分钟查看一次血糖，按需补给。")
            IconTextRow(icon: "moon.stars.fill", color: Theme.sleep, title: "运动日的夜间",
                        text: "运动后数小时到夜间可能出现延迟性低血糖，睡前留意血糖。")
            if p.hypoRiskMeds() {
                StatusLabel(.attention("使用胰岛素或磺脲类药物时，运动相关低血糖风险较高，请随身携带 15–20 g 快速碳水。"))
                    .font(.subheadline)
            }
            AgentAskButton(title: "运动时怎么用 CGM", question: "运动时 CGM 怎么用？")
        }
        .cardSurface()
    }

    // MARK: Lows

    private func lowCard(_ g: [VitalPoint], _ p: ProfileSnapshot) -> some View {
        let episodes = GlucoseAnalyzer.lowEpisodes(g.filter { $0.time > Date.app.adding(days: -14) }, low: p.glucoseLow)
        let related = events.filter { [.glucoseLow, .glucoseSevereLow, .glucoseHigh].contains($0.kind) }.prefix(3)
        return VStack(alignment: .leading, spacing: Theme.Space.block) {
            CardTitle(title: "低血糖") {
                Button { log = .symptom } label: { Label("记录症状", systemImage: "plus") }.buttonStyle(.bordered)
            }
            StatusLabel(episodes.isEmpty ? .good("近 14 天没有低于 \(p.glucoseLow.oneDecimal) 的时段")
                        : .attention("近 14 天 \(episodes.count) 次低于 \(p.glucoseLow.oneDecimal)，其中夜间 \(episodes.filter(\.nocturnal).count) 次"))
                .font(.subheadline)
            ForEach(episodes.prefix(3)) { e in
                FactRow(label: "\(e.start.formatted(.dateTime.month().day())) \(Clock.text(e.start.minutesOfDay))\(e.nocturnal ? " · 夜间" : "")",
                        value: "约 \(e.minutes) 分钟 · 最低 \(e.nadir.oneDecimal)")
            }
            ForEach(Array(related)) { e in
                NavigationLink { HealthEventDetailView(event: e) } label: {
                    HStack { EventRow(event: e); Spacer(); Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary) }
                        .frame(minHeight: Theme.Size.tap).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Divider()
            Text("出现低血糖时（15-15 原则）").font(.subheadline.weight(.semibold))
            IconTextRow(icon: "1.circle.fill", color: Theme.glucose, title: "", text: "立即摄入 15–20 g 快速碳水，如半杯果汁或 3–4 片葡萄糖片。")
            IconTextRow(icon: "2.circle.fill", color: Theme.glucose, title: "", text: "15 分钟后复测；仍低于 \(p.glucoseLow.oneDecimal) 再重复一次。")
            IconTextRow(icon: "3.circle.fill", color: Theme.glucose, title: "", text: "恢复后如距下一餐较远，吃些含碳水和蛋白质的食物。")
            IconTextRow(icon: "exclamationmark.triangle.fill", color: .red, title: "",
                        text: "意识不清、无法吞咽或抽搐时不要喂食，立即拨打 120。")
        }
        .cardSurface()
    }

    private func guidanceCard(_ p: ProfileSnapshot) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.block) {
            CardTitle("生病日")
            IconTextRow(icon: "drop.triangle", color: .secondary, title: "更频繁地监测", text: "发热、呕吐或进食减少时，每 2–4 小时查看一次血糖；1 型糖尿病同时检测酮体。")
            IconTextRow(icon: "cup.and.saucer", color: .secondary, title: "补充水分", text: "少量多次饮水；进食困难时选择含碳水的流质。")
            IconTextRow(icon: "phone", color: .secondary, title: "联系医疗团队",
                        text: "血糖持续高于 13.9、酮体阳性、持续呕吐或无法进食时，及时联系医生。用药是否调整请按照护计划。")
        }
        .cardSurface()
    }

    private var followUpCard: some View {
        let list = tasks.filter { $0.area == .diabetes }
        let missing = DiabetesChecks.all.filter { c in !list.contains { $0.title == c.title } }
        return VStack(alignment: .leading, spacing: Theme.Space.item) {
            CardTitle(title: "检查与随访") {
                Button { addTask = true } label: { Label("添加", systemImage: "plus") }.buttonStyle(.bordered)
            }
            if list.isEmpty { EmptyLine("常规检查包括 HbA1c、眼底、足部和肾功能。") }
            ForEach(list) { CareTaskRow(task: $0).frame(minHeight: Theme.Size.tap) }
            if !missing.isEmpty {
                Button {
                    for c in missing { ctx.insert(CareTask(title: c.title, area: .diabetes, due: .app.adding(days: c.dueInDays), note: c.note)) }
                } label: { Label("添加常规检查提醒（\(missing.count) 项）", systemImage: "calendar.badge.plus") }
                    .buttonStyle(.bordered)
            }
        }
        .cardSurface()
    }
}

enum DiabetesChecks {
    struct Check { let title: String; let dueInDays: Int; let note: String }
    static let all: [Check] = [
        .init(title: "糖化血红蛋白（HbA1c）检测", dueInDays: 90, note: "通常每 3–6 个月一次"),
        .init(title: "眼底检查", dueInDays: 180, note: "通常每年一次"),
        .init(title: "足部检查", dueInDays: 120, note: "每年至少一次专业检查，平时每天自查"),
        .init(title: "肾功能与尿白蛋白检查", dueInDays: 180, note: "通常每年一次"),
    ]
}

// MARK: - Hero

struct GlucoseHeroCard: View {
    let points: [VitalPoint]
    let metrics: GlucoseMetrics
    let profile: ProfileSnapshot
    var onLog: (QuickLogKind) -> Void

    var body: some View {
        let p = profile
        let last = points.last
        let fresh = last.map { Date.app.timeIntervalSince($0.time) < 3600 } ?? false
        VStack(alignment: .leading, spacing: Theme.Space.block) {
            CardTitle(title: metrics.isContinuous ? "当前血糖" : "最近一次血糖") {
                if metrics.isContinuous { Chip(text: "CGM", icon: "sensor.tag.radiowaves.forward", color: .secondary) }
            }
            if let v = last {
                HStack(alignment: .firstTextBaseline, spacing: Theme.Space.tight) {
                    Text(v.value.oneDecimal).font(.system(.largeTitle, design: .rounded).weight(.bold)).monospacedDigit()
                    Text("mmol/L").font(.subheadline).foregroundStyle(.secondary)
                    if metrics.isContinuous && fresh, let arrow = trendArrow {
                        Image(systemName: arrow.icon).font(.title2.weight(.semibold)).foregroundStyle(Theme.glucose)
                            .accessibilityLabel(arrow.label)
                    }
                    Spacer()
                    Text(v.time.isSameDay(.app) ? Clock.text(v.time.minutesOfDay) : v.time.formatted(.dateTime.month().day().hour().minute()))
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                StatusLabel(v.value < p.glucoseLow ? .urgent("低于 \(p.glucoseLow.oneDecimal)，请按低血糖处理并复测")
                            : (v.value > p.glucoseHigh ? .attention("高于目标上限 \(p.glucoseHigh.oneDecimal)") : .good("在目标范围 \(p.glucoseLow.oneDecimal)–\(p.glucoseHigh.oneDecimal) 内")))
                    .font(.subheadline)
            } else {
                Text("还没有血糖数据。连接 CGM（通过健康 App）或手动记录指尖血糖。").font(.subheadline).foregroundStyle(.secondary)
            }
            if metrics.isContinuous {
                TIRBar(metrics: metrics)
            }
            HStack(spacing: Theme.Space.item) {
                Button { onLog(.glucose) } label: { Label("记录血糖", systemImage: "plus").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                Button { onLog(.diet) } label: { Label("记录饮食", systemImage: "fork.knife").frame(maxWidth: .infinity) }
                    .buttonStyle(.bordered).controlSize(.large)
            }
        }
        .cardSurface()
    }

    /// Direction over the last ~30 minutes, like a CGM trend arrow.
    private var trendArrow: (icon: String, label: String)? {
        guard let last = points.last, let ref = points.last(where: { last.time.timeIntervalSince($0.time) >= 25 * 60 }),
              last.time.timeIntervalSince(ref.time) <= 45 * 60 else { return nil }
        let d = last.value - ref.value
        switch d {
        case 1.0...: return ("arrow.up", "快速上升")
        case 0.5..<1.0: return ("arrow.up.right", "上升")
        case ...(-1.0): return ("arrow.down", "快速下降")
        case -1.0 ..< -0.5: return ("arrow.down.right", "下降")
        default: return ("arrow.right", "平稳")
        }
    }
}

/// Time-in-ranges bar with a readable legend (status colours carry meaning, text carries the numbers).
struct TIRBar: View {
    let metrics: GlucoseMetrics

    var body: some View {
        let m = metrics
        let parts: [(String, Double, Color)] = [
            ("很低", m.tbrSevere ?? 0, .red),
            ("偏低", (m.tbr ?? 0) - (m.tbrSevere ?? 0), .red.opacity(0.55)),
            ("范围内", m.tir ?? 0, .green),
            ("偏高", (m.tar ?? 0) - (m.tarSevere ?? 0), .orange.opacity(0.6)),
            ("很高", m.tarSevere ?? 0, .orange),
        ]
        VStack(alignment: .leading, spacing: Theme.Space.item) {
            GeometryReader { geo in
                HStack(spacing: 2) {
                    ForEach(parts.filter { $0.1 > 0.001 }, id: \.0) { part in
                        Rectangle().fill(part.2).frame(width: max(3, (geo.size.width - 8) * part.1))
                    }
                }
            }
            .frame(height: 12)
            .clipShape(Capsule())
            HStack(spacing: 0) {
                legend("低于", (m.tbr ?? 0), .red)
                legend("范围内", m.tir ?? 0, .green)
                legend("高于", m.tar ?? 0, .orange)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("近 14 天：范围内 \(Int((m.tir ?? 0) * 100))%，低于 \(String(format: "%.1f", (m.tbr ?? 0) * 100))%，高于 \(Int((m.tar ?? 0) * 100))%")
    }

    private func legend(_ label: String, _ v: Double, _ c: Color) -> some View {
        HStack(spacing: Theme.Space.iconGap) {
            Circle().fill(c).frame(width: 8, height: 8)
            Text("\(label) \(v < 0.1 && v > 0 ? String(format: "%.1f", v * 100) : "\(Int((v * 100).rounded()))")%")
                .font(.footnote).foregroundStyle(.secondary).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Last 24 hours

struct Last24hCard: View {
    let points: [VitalPoint]
    let meals: [MealLog]
    let sessions: [ActivitySession]
    let profile: ProfileSnapshot

    var body: some View {
        let from = Date.app.addingTimeInterval(-24 * 3600)
        let day = points.filter { $0.time > from }
        let continuous = day.count >= 24
        let mealTimes = meals.filter { $0.time > from }
        let ex = sessions.filter { $0.start > from }
        VStack(alignment: .leading, spacing: Theme.Space.block) {
            CardTitle("最近 24 小时")
            if day.isEmpty {
                EmptyLine("最近 24 小时没有血糖数据。")
            } else {
                Chart {
                    GlucoseRangeMarks(low: profile.glucoseLow, high: profile.glucoseHigh)
                    ForEach(ex) { s in
                        RectangleMark(xStart: .value("开始", s.start), xEnd: .value("结束", s.start.addingTimeInterval(s.minutes * 60)))
                            .foregroundStyle(Theme.activity.opacity(0.18))
                            .annotation(position: .top) { Image(systemName: "figure.run").font(.caption2).foregroundStyle(Theme.activity) }
                    }
                    ForEach(Array(day.enumerated()), id: \.offset) { _, v in
                        if continuous {
                            LineMark(x: .value("时间", v.time), y: .value("mmol/L", v.value))
                                .foregroundStyle(Theme.glucose).interpolationMethod(.monotone)
                                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                        } else {
                            PointMark(x: .value("时间", v.time), y: .value("mmol/L", v.value)).foregroundStyle(Theme.glucose)
                        }
                    }
                    ForEach(mealTimes) { m in
                        RuleMark(x: .value("进餐", m.time)).foregroundStyle(Color.gray.opacity(0.6))
                            .annotation(position: .top) { Image(systemName: "fork.knife").font(.caption2).foregroundStyle(Color.gray) }
                    }
                }
                .chartYScale(domain: 2.5...max(12, (day.map(\.value).max() ?? 8) + 1))
                .chartXAxis { AxisMarks(values: .stride(by: .hour, count: 6)) { _ in AxisGridLine(); AxisValueLabel(format: .dateTime.hour()) } }
                .chartYAxis { AxisMarks(position: .trailing, values: [4, 7, 10]) }
                .padding(.top, 14)
                .frame(height: 180)
                .accessibilityLabel("最近 24 小时血糖曲线")
                .accessibilityValue("范围 \((day.map(\.value).min() ?? 0).oneDecimal) 到 \((day.map(\.value).max() ?? 0).oneDecimal)")
                Text("虚线之间为目标范围 · 灰色竖线为进餐 · 跑步图标为运动").font(.footnote).foregroundStyle(.secondary)
            }
        }
        .cardSurface()
    }
}

// MARK: - Daily pattern (AGP)

struct AGPCard: View {
    let points: [VitalPoint]
    let profile: ProfileSnapshot

    var body: some View {
        let p = profile
        let prof = GlucoseAnalyzer.hourlyProfile(points.filter { $0.time > Date.app.adding(days: -14) }.map { ($0.time, $0.value) })
        let dn = GlucoseAnalyzer.dayNightTIR(points, low: p.glucoseLow, high: p.glucoseHigh)
        VStack(alignment: .leading, spacing: Theme.Space.block) {
            CardTitle("每日规律", detail: "14 天叠加")
            Chart {
                GlucoseRangeMarks(low: p.glucoseLow, high: p.glucoseHigh)
                ForEach(prof) { h in
                    AreaMark(x: .value("时", h.hour), yStart: .value("P10", h.p10), yEnd: .value("P90", h.p90))
                        .foregroundStyle(Theme.glucose.opacity(0.12))
                    AreaMark(x: .value("时", h.hour), yStart: .value("P25", h.p25), yEnd: .value("P75", h.p75))
                        .foregroundStyle(Theme.glucose.opacity(0.28))
                    LineMark(x: .value("时", h.hour), y: .value("中位数", h.median)).foregroundStyle(Theme.glucose)
                }
            }
            .chartXScale(domain: 0...23)
            .chartXAxis { AxisMarks(values: [0, 6, 12, 18, 23]) { v in AxisGridLine(); AxisValueLabel { Text("\(v.as(Int.self) ?? 0):00") } } }
            .chartYAxis { AxisMarks(position: .trailing, values: [4, 7, 10]) }
            .frame(height: 160)
            .accessibilityLabel("14 天每日血糖规律")
            Text("线为中位数，深色带为 25%–75%，浅色带为 10%–90%").font(.footnote).foregroundStyle(.secondary)
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: Theme.Space.tight) {
                    Text("白天范围内").font(.caption).foregroundStyle(.secondary)
                    Text(dn.day.map { "\(Int($0 * 100))%" } ?? "—").font(.headline).monospacedDigit()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .leading, spacing: Theme.Space.tight) {
                    Text("夜间范围内（0–6 点）").font(.caption).foregroundStyle(.secondary)
                    Text(dn.night.map { "\(Int($0 * 100))%" } ?? "—").font(.headline).monospacedDigit()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .cardSurface()
    }
}

// MARK: - Targets

struct GlucoseTargetsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var profile: UserProfile

    var body: some View {
        CalmNavigationStack {
            Form {
                Section {
                    Stepper("下限 \(profile.glucoseLow.oneDecimal)", value: $profile.glucoseLow, in: 3.0...6.0, step: 0.1)
                    Stepper("上限 \(profile.glucoseHigh.oneDecimal)", value: $profile.glucoseHigh, in: 7.0...13.9, step: 0.1)
                } header: { Text("目标范围（mmol/L）") } footer: {
                    Text("常用范围 3.9–10.0；老年或低血糖高风险者通常更宽松。请与医疗团队确认。")
                }
                Section("运动前") {
                    Stepper("下限 \(profile.glucosePreExerciseMin.oneDecimal)", value: $profile.glucosePreExerciseMin, in: 4.0...8.0, step: 0.1)
                    Stepper("上限 \(profile.glucoseExerciseMax.oneDecimal)", value: $profile.glucoseExerciseMax, in: 10.0...16.7, step: 0.1)
                }
            }
            .navigationTitle("目标范围")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() }.fontWeight(.semibold) } }
        }
    }
}
