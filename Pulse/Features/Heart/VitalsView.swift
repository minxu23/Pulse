import SwiftUI
import SwiftData
import Charts

/// 关注相关身体指标 (需求 8): blood pressure, glucose and overnight indicators, each kept with
/// its measurement, activity, meal and medication context.
struct VitalsView: View {
    @Environment(\.modelContext) private var ctx
    @Query private var profiles: [UserProfile]
    @Query private var meds: [MedicationEntry]
    @Query(sort: \DailyRecord.day) private var records: [DailyRecord]
    @Query(sort: \VitalReading.time, order: .reverse) private var vitals: [VitalReading]
    @State private var logKind: QuickLogKind?

    var body: some View {
        let p = profiles.first?.snapshot(medications: meds) ?? ProfileSnapshot()
        let points = vitals.map(\.point)
        let bp = points.filter { $0.kind == .bloodPressure }
        let glucose = points.filter { $0.kind == .glucose }
        ScreenScroll {
            HStack(spacing: Theme.Space.item) {
                addButton("血压", "gauge.with.dots.needle.33percent") { logKind = .bloodPressure }
                addButton("血糖", "drop.fill") { logKind = .glucose }
                addButton("其他", "plus") { logKind = .vital }
            }
            bpCard(bp, p)
            // For kidney disease the lab results matter as much as blood pressure.
            if showsLabs(p) && p.conditions.contains(.ckd) { LabSummaryCard(profile: p) }
            glucoseCard(glucose, p)
            if showsLabs(p) && !p.conditions.contains(.ckd) { LabSummaryCard(profile: p) }
            GlucoseProfileEntry()
            overnightCard
            recentCard
            Disclaimer(text: "指标异常会单独进入「异常跟进」。设备与家用仪器读数可能有误差，需要时请复测或由专业人员核实。")
        }
        .sheet(item: $logKind) { QuickLogSheet(kind: $0) }
    }

    @Query private var labs: [LabResult]
    /// Lab results matter for kidney, blood-pressure and glucose care; anyone with results sees them.
    private func showsLabs(_ p: ProfileSnapshot) -> Bool {
        !labs.isEmpty || p.tracksNutrients || p.hasDiabetes || p.hasCardiac || p.conditions.contains(.ckd) || !p.extraConditions.isEmpty
    }

    private func addButton(_ title: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label("记录\(title)", systemImage: icon)
                .font(.subheadline.weight(.medium))
                .padding(.vertical, Theme.Space.item)
                .frame(maxWidth: .infinity, minHeight: Theme.Size.tap)
                .contentShape(Rectangle())
                .background(Theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: Theme.Radius.inner, style: .continuous))
                .foregroundStyle(Theme.accent)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func bpCard(_ bp: [VitalPoint], _ p: ProfileSnapshot) -> some View {
        let s = BPAnalyzer.summary(bp, profile: p)
        Card {
            CardHeader(title: "血压", subtitle: "近 30 天 · \(s.count) 次", icon: "gauge.with.dots.needle.33percent", color: Theme.heartData) {
                if s.count > 0 { Chip(text: s.category, color: Theme.heartData) }
            }
            if s.count == 0 {
                EmptyHint(icon: "gauge.with.dots.needle.33percent", text: "暂无血压记录。有高血压或心血管照护需求时，建议每周固定时间测量。")
            } else {
                MetricRow {
                    MetricTile(label: "平均", value: "\(Int(s.avgSys ?? 0))/\(Int(s.avgDia ?? 0))", unit: "mmHg", icon: "equal.circle", color: Theme.heartData)
                    MetricTile(label: "达到 \(p.bpTargetSys)/\(p.bpTargetDia)", value: "\(Int((s.inTargetRate ?? 0) * 100))", unit: "%", icon: "target", color: .green)
                }
                let recent = bp.filter { $0.time > Date.app.adding(days: -60) }
                Chart {
                    RuleMark(y: .value("目标", p.bpTargetSys)).lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4])).foregroundStyle(Color.gray)
                    ForEach(Array(recent.enumerated()), id: \.offset) { _, v in
                        PointMark(x: .value("日期", v.time), y: .value("收缩压", v.value)).foregroundStyle(by: .value("类型", "收缩压")).symbol(by: .value("类型", "收缩压"))
                        if let d = v.value2 {
                            PointMark(x: .value("日期", v.time), y: .value("舒张压", d)).foregroundStyle(by: .value("类型", "舒张压")).symbol(by: .value("类型", "舒张压"))
                        }
                    }
                }
                .chartForegroundStyleScale(["收缩压": Theme.heartData, "舒张压": Theme.heartData.opacity(0.45)])
                .frame(height: 160)
                if let m = s.morningSys, let e = s.eveningSys {
                    Text("早晨平均收缩压 \(Int(m))，晚间 \(Int(e)) mmHg。").font(.footnote).foregroundStyle(.secondary)
                }
                if let n = NextHourForecaster.bloodPressure(bp) {
                    Label("未来 1 小时：" + n.message, systemImage: "clock.arrow.circlepath").font(.footnote).foregroundStyle(.secondary)
                }
                Divider()
                if let f = VitalForecaster.bloodPressure(bp, profile: p) {
                    ForecastSection(forecast: f.systolic, color: Theme.heartData, target: Double(p.bpTargetSys), what: "收缩压周均值",
                                    risingIsWorse: true, warn: f.needsDoctor, message: f.message)
                } else {
                    ForecastSection.notYet
                }
            }
        }
    }

    /// 血糖：CGM 连续曲线（最近 24 小时）或指尖血糖点，整张卡片进入「血糖管理」。
    @ViewBuilder
    private func glucoseCard(_ g: [VitalPoint], _ p: ProfileSnapshot) -> some View {
        if !g.isEmpty || p.hasDiabetes {
            let m = GlucoseAnalyzer.metrics(g.map { ($0.time, $0.value) }, low: p.glucoseLow, high: p.glucoseHigh)
            let sorted = g.sorted { $0.time < $1.time }
            let day = sorted.filter { $0.time > Date.app.addingTimeInterval(-24 * 3600) }
            let shown = m.isContinuous ? day : sorted.filter { $0.time > Date.app.adding(days: -14) }
            let last = sorted.last
            NavigationLink { DiabetesCareView() } label: {
                Card {
                    CardHeader(title: "血糖", subtitle: m.isContinuous ? "CGM 连续监测 · 最近 24 小时" : "指尖血糖 · 近 14 天",
                               icon: "drop.fill", color: Theme.glucose) {
                        Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                    }
                    if let v = last {
                        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.tight) {
                            Text(v.value.oneDecimal).font(.system(.title, design: .rounded).weight(.semibold)).monospacedDigit()
                            Text("mmol/L").font(.subheadline).foregroundStyle(.secondary)
                            Text(v.time.isSameDay(.app) ? Clock.text(v.time.minutesOfDay) : v.time.formatted(.dateTime.month().day()))
                                .font(.footnote).foregroundStyle(.secondary)
                            Spacer()
                            StatusLabel(v.value < p.glucoseLow ? .urgent("低于范围") : (v.value > p.glucoseHigh ? .attention("高于范围") : .good("在范围内")))
                                .font(.footnote)
                        }
                    }
                    if shown.isEmpty {
                        EmptyHint(icon: "drop", text: "连接 CGM（通过健康 App）或手动记录血糖。")
                    } else {
                        Chart {
                            GlucoseRangeMarks(low: p.glucoseLow, high: p.glucoseHigh)
                            ForEach(Array(shown.enumerated()), id: \.offset) { _, v in
                                if m.isContinuous {
                                    LineMark(x: .value("时间", v.time), y: .value("mmol/L", v.value))
                                        .foregroundStyle(Theme.glucose).interpolationMethod(.monotone)
                                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                                } else {
                                    PointMark(x: .value("时间", v.time), y: .value("mmol/L", v.value))
                                        .foregroundStyle(Theme.glucose).symbolSize(24)
                                }
                            }
                        }
                        .chartYScale(domain: 2.5...max(11, (shown.map(\.value).max() ?? 8) + 1))
                        .chartXAxis {
                            if m.isContinuous {
                                AxisMarks(values: .stride(by: .hour, count: 6)) { _ in AxisGridLine(); AxisValueLabel(format: .dateTime.hour()) }
                            } else {
                                AxisMarks(values: .stride(by: .day, count: 3)) { _ in AxisGridLine(); AxisValueLabel(format: .dateTime.month().day()) }
                            }
                        }
                        .chartYAxis { AxisMarks(position: .trailing, values: [4, 7, 10]) }
                        .frame(height: 150)
                        .accessibilityLabel(m.isContinuous ? "最近 24 小时连续血糖曲线" : "近 14 天血糖记录")
                        .accessibilityValue("范围 \((shown.map(\.value).min() ?? 0).oneDecimal) 到 \((shown.map(\.value).max() ?? 0).oneDecimal) 毫摩尔每升")
                        Text("虚线之间为目标范围 \(p.glucoseLow.oneDecimal)–\(p.glucoseHigh.oneDecimal) mmol/L").font(.footnote).foregroundStyle(.secondary)
                    }
                    if let f = NextHourForecaster.glucose(g, profile: p) {
                        GlucoseHourChart(history: NextHourForecaster.cgm(g).filter { $0.time > f.from.addingTimeInterval(-3 * 3600) },
                                         forecast: f, low: p.glucoseLow, high: p.glucoseHigh)
                        Label("未来 1 小时：" + f.message, systemImage: f.alert != nil ? "exclamationmark.triangle.fill" : "clock.arrow.circlepath")
                            .font(.footnote).foregroundStyle(f.alert != nil ? Color.primary : Color.secondary)
                        Text(NextHourForecaster.caveat).font(.footnote).foregroundStyle(.secondary)
                    }
                    MetricRow {
                        MetricTile(label: "14 天平均", value: m.mean.map { $0.oneDecimal } ?? "—", unit: "mmol/L", icon: "equal.circle", color: Theme.glucose)
                        MetricTile(label: "目标范围内", value: m.tir.map { "\(Int($0 * 100))" } ?? "—", unit: "%", icon: "target", color: .green)
                        MetricTile(label: "低于范围", value: m.tbr.map { "\(Int(($0 * 100).rounded()))" } ?? "—", unit: "%", icon: "arrow.down", color: .red)
                    }
                    if !g.isEmpty {
                        Divider()
                        if let f = VitalForecaster.glucose(g, profile: p) {
                            ForecastSection(forecast: f.mean, color: Theme.glucose, target: f.threshold, what: "\(f.measure)周均值",
                                            risingIsWorse: true, warn: f.needsDoctor, message: f.message)
                        } else {
                            ForecastSection.notYet
                        }
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityHint("打开血糖管理")
        }
    }

    private var overnightCard: some View {
        let recent = records.filter { $0.day > Date.app.adding(days: -30) }
        let spo2 = recent.compactMap { r in r.spo2Min.map { (r.day, $0) } }
        let resp = recent.compactMap { r in r.respiratoryRate.map { (r.day, $0) } }
        let dist = recent.compactMap { r in r.breathingDisturbances.map { (r.day, $0) } }
        return Card {
            CardHeader(title: "夜间指标", subtitle: "来自可靠佩戴的设备 · 近 30 天", icon: "moon.stars", color: Theme.sleep)
            if spo2.isEmpty && resp.isEmpty && dist.isEmpty {
                EmptyHint(icon: "applewatch", text: "佩戴支持的设备入睡后，这里会显示夜间血氧、呼吸频率等指标。")
            } else {
                MetricRow {
                    MetricTile(label: "最低血氧", value: Stats.mean(spo2.map(\.1)).map { "\(Int($0))" } ?? "—", unit: "%", icon: "lungs", color: Theme.respiratory)
                    MetricTile(label: "呼吸频率", value: Stats.mean(resp.map(\.1)).map { $0.oneDecimal } ?? "—", unit: "次/分", icon: "wind", color: Theme.respiratory)
                    MetricTile(label: "呼吸紊乱", value: Stats.mean(dist.map(\.1)).map { $0.oneDecimal } ?? "—", unit: "次/时", icon: "waveform", color: Theme.respiratory)
                }
                if !spo2.isEmpty {
                    Text("最低血氧低于 88% 的夜晚：\(spo2.filter { $0.1 < 88 }.count) 晚").font(.footnote).foregroundStyle(.secondary)
                }
                if !spo2.isEmpty {
                    Chart {
                        RuleMark(y: .value("88%", 88)).lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3])).foregroundStyle(.red.opacity(0.5))
                        ForEach(spo2, id: \.0) { d in
                            LineMark(x: .value("日期", d.0, unit: .day), y: .value("最低血氧", d.1))
                                .foregroundStyle(Theme.respiratory)
                            PointMark(x: .value("日期", d.0, unit: .day), y: .value("最低血氧", d.1))
                                .foregroundStyle(d.1 < 88 ? Color.red : Theme.respiratory)
                                .symbol(d.1 < 88 ? .triangle : .circle).symbolSize(d.1 < 88 ? 40 : 14)
                        }
                    }
                    .chartYScale(domain: 80...100)
                    .frame(height: 120)
                }
                Text("设备信号与自述线索不等于诊断。多晚偏低时，请在「计划 › 睡眠」中查看睡眠呼吸线索，必要时进行专业睡眠评估。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private var recentCard: some View {
        let shown = vitals.filter { $0.source != .cgm && !($0.source == .demo && $0.kind == .glucose) }.prefix(8)
        return Card {
            CardHeader(title: "最近记录", icon: "list.bullet", color: .secondary) {
                NavigationLink { VitalsHistoryView() } label: {
                    Text("全部").font(.subheadline).frame(minHeight: Theme.Size.tap).contentShape(Rectangle())
                }
            }
            if shown.isEmpty { Text("暂无记录").foregroundStyle(.secondary).font(.subheadline) }
            ForEach(Array(shown)) { v in VitalRow(v: v) }
        }
    }
}

struct VitalRow: View {
    let v: VitalReading
    var body: some View {
        HStack(spacing: Theme.Space.iconGap) {
            Image(systemName: v.kind.icon).font(.subheadline).imageScale(.small).foregroundStyle(.secondary).frame(width: 24)
            VStack(alignment: .leading, spacing: Theme.Space.hairline) {
                HStack(spacing: Theme.Space.tight) {
                    Text(v.kind.label).font(.subheadline)
                    Text(v.valueText).font(.subheadline.weight(.semibold)).monospacedDigit()
                    Text(v.kind.unit).font(.caption).foregroundStyle(.secondary)
                }
                Text([v.time.formatted(.dateTime.month().day().hour().minute()), v.context.label,
                      v.medsTaken.map { $0 ? "已服药" : "未服药" } ?? "", v.note]
                    .filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.footnote).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            Text(v.source.label).font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct VitalsHistoryView: View {
    @Environment(\.modelContext) private var ctx
    @Query(sort: \VitalReading.time, order: .reverse) private var vitals: [VitalReading]
    @State private var kind: VitalKind = .bloodPressure

    var body: some View {
        let list = vitals.filter { $0.kind == kind }
        List {
            Picker("指标", selection: $kind) { ForEach(VitalKind.allCases) { Text($0.label).tag($0) } }
            ForEach(list.prefix(300)) { v in VitalRow(v: v) }
                .onDelete { idx in for i in idx { ctx.delete(list[i]) } }
            if list.isEmpty { Text("暂无记录").foregroundStyle(.secondary) }
        }
        .navigationTitle("指标记录").calmStyle()
        .toolbar { EditButton() }
    }
}

/// 未来 4 周: the weekly averages so far, and where their trend leads as a widening range — with
/// what it means in one sentence and what it cannot be used for.
private struct ForecastSection: View {
    let forecast: TrendForecast
    let color: Color
    /// Drawn as a dashed line (the care target, or the top of the target range).
    let target: Double?
    /// What the line is, for VoiceOver ("收缩压周均值").
    let what: String
    let risingIsWorse: Bool
    let warn: Bool
    let message: String

    static var notYet: some View {
        Text("有 4 周以上、每周都有的记录后，就能推算未来几周的趋势。").font(.footnote).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    var body: some View {
        let observed = forecast.weeks.filter { !$0.projected }
        // The projection starts from the last observed week, so line and band join it.
        let ahead = [forecast.latest] + forecast.weeks.filter(\.projected)
        let values = forecast.weeks.flatMap { [$0.low, $0.high] } + [target].compactMap { $0 }
        let lo = (values.min() ?? 0), hi = (values.max() ?? 1), pad = max(1, (hi - lo) * 0.15)
        VStack(alignment: .leading, spacing: Theme.Space.item) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.item) {
                Text("趋势预测").font(.subheadline.weight(.semibold))
                Text("到 \(forecast.end.start.formatted(.dateTime.month().day())) 那周").font(.footnote).foregroundStyle(.secondary)
                Spacer(minLength: Theme.Space.item)
                direction.font(.footnote)
            }
            Chart {
                if let target {
                    RuleMark(y: .value("目标", target)).lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4])).foregroundStyle(Color.gray)
                }
                ForEach(ahead, id: \.start) { w in
                    AreaMark(x: .value("周", w.start), yStart: .value("下限", w.low), yEnd: .value("上限", w.high))
                        .foregroundStyle(color.opacity(0.14))
                }
                ForEach(observed, id: \.start) { w in
                    LineMark(x: .value("周", w.start), y: .value(what, w.mid), series: .value("线", "实际"))
                        .foregroundStyle(color)
                    PointMark(x: .value("周", w.start), y: .value(what, w.mid)).foregroundStyle(color).symbolSize(22)
                }
                ForEach(ahead, id: \.start) { w in
                    LineMark(x: .value("周", w.start), y: .value(what, w.mid), series: .value("线", "预测"))
                        .foregroundStyle(color).lineStyle(StrokeStyle(lineWidth: 2, dash: [4, 3]))
                }
            }
            .chartYScale(domain: (lo - pad)...(hi + pad))
            .chartXAxis { AxisMarks(values: .stride(by: .weekOfYear, count: 2)) { _ in AxisGridLine(); AxisValueLabel(format: .dateTime.month().day()) } }
            .chartYAxis { AxisMarks(position: .trailing) }
            .frame(height: 130)
            .accessibilityLabel("\(what)：过去 \(observed.count) 周与未来 4 周的推算范围")
            .accessibilityValue("4 周后约 \(forecast.end.low.oneDecimal) 到 \(forecast.end.high.oneDecimal)")
            Text("实线为每周平均，虚线和浅色带为推算的范围。").font(.caption).foregroundStyle(.secondary)
            Text(message).font(.subheadline).fixedSize(horizontal: false, vertical: true)
            Text(VitalForecaster.caveat).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Direction in colour, glyph and words; rising is the worse way for both measures.
    private var direction: some View {
        switch forecast.direction {
        case .rising: StatusLabel(text: "可能上升", icon: "arrow.up.right.circle.fill", color: risingIsWorse ? .orange : .green, secondaryText: true)
        case .falling: StatusLabel(text: "可能下降", icon: "arrow.down.right.circle.fill", color: warn ? .orange : (risingIsWorse ? .green : .orange), secondaryText: true)
        case .steady: StatusLabel(text: "大致平稳", icon: "equal.circle.fill", color: .gray, secondaryText: true)
        }
    }
}
