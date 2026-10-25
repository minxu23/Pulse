import SwiftUI
import SwiftData
import Charts

/// 化验结果: kidney function first (eGFR with its trend, albuminuria, creatinine), then the blood
/// tests that go with it. Each value is read against common ranges; the KDIGO stage is shown as a
/// range the value falls in, never as a diagnosis.
struct LabResultsView: View {
    @Query(sort: \LabResult.date) private var labs: [LabResult]
    @Query private var profiles: [UserProfile]
    @Query private var meds: [MedicationEntry]
    @State private var adding = false

    var body: some View {
        let p = profiles.first?.snapshot(medications: meds) ?? ProfileSnapshot()
        let points = labs.map(\.point)
        ScreenScroll {
            Button { adding = true } label: {
                Label("记录化验结果", systemImage: "plus")
                    .font(.subheadline.weight(.medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .foregroundStyle(Theme.accent)
            }
            .buttonStyle(.plain)
            if points.isEmpty {
                Card {
                    EmptyHint(icon: "testtube.2", text: "还没有化验结果。拿到化验单后，把 eGFR、血肌酐、血钾、尿白蛋白/肌酐比等填进来，Pulse 会按参考范围解读，并跟踪肾功能的变化。")
                }
            } else {
                if points.contains(where: \.kind.isKidney) { KidneyFunctionCard(labs: points, profile: p) }
                ForEach(LabKind.allCases.filter { k in !k.isKidney && points.contains { $0.kind == k } }) { k in
                    LabKindCard(kind: k, labs: points, profile: p)
                }
                NavigationLink { LabHistoryView() } label: {
                    Label("全部化验记录", systemImage: "list.bullet").font(.subheadline).frame(maxWidth: .infinity, minHeight: 44)
                }
            }
            Disclaimer(text: "解读按常见的成人参考范围和 KDIGO 肾功能分期，不能代替医生的判断。\(LabAnalyzer.rangeNote)")
        }
        .navigationTitle("化验结果")
        .navigationBarTitleDisplayMode(.inline)
        .calmStyle()
        .sheet(isPresented: $adding) { QuickLogSheet(kind: .lab) }
    }
}

/// eGFR (with its trend), albuminuria and creatinine together, and the KDIGO cell they fall in.
private struct KidneyFunctionCard: View {
    let labs: [LabPoint]
    let profile: ProfileSnapshot

    var body: some View {
        let egfr = LabAnalyzer.egfrSeries(labs)
        let uacr = labs.filter { $0.kind == .uacr }.sorted { $0.date < $1.date }
        let cr = labs.filter { $0.kind == .creatinine }.sorted { $0.date < $1.date }
        Card {
            CardHeader(title: "肾功能", subtitle: "eGFR · 尿白蛋白 · 肌酐", icon: "drop.halffull", color: Theme.labs) {
                if let e = egfr.last, let u = uacr.last {
                    Chip(text: "\(LabAnalyzer.egfrStage(e.value).code) · \(LabAnalyzer.uacrStage(u.value).code)", color: Theme.labs)
                }
            }
            if let e = egfr.last {
                LabValueRow(point: e, status: LabAnalyzer.status(.egfr, e.value, profile: profile))
                if let t = LabAnalyzer.egfrTrend(labs) {
                    StatusLabel(t.fast ? .attention(t.text) : .neutral(t.text)).font(.subheadline)
                }
                if egfr.count >= 2 {
                    Chart {
                        RuleMark(y: .value("60", 60)).lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4])).foregroundStyle(Color.gray)
                        ForEach(egfr, id: \.date) { l in
                            LineMark(x: .value("日期", l.date, unit: .day), y: .value("eGFR", l.value)).foregroundStyle(Theme.labs)
                            PointMark(x: .value("日期", l.date, unit: .day), y: .value("eGFR", l.value))
                                .foregroundStyle(Theme.labs).symbol(l.estimated ? .circle : .square).symbolSize(30)
                        }
                    }
                    .chartYScale(domain: 0...max(100, (egfr.map(\.value).max() ?? 90) + 10))
                    .frame(height: 140)
                    .accessibilityLabel("eGFR 变化：" + egfr.map { "\($0.date.formatted(.dateTime.month().day())) \($0.valueText)" }.joined(separator: "，"))
                    Text("虚线为 60：低于 60 持续 3 个月以上，属于慢性肾病的范围。\(egfr.contains(where: \.estimated) ? "圆点为按肌酐估算的值。" : "")")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            if let u = uacr.last {
                Divider()
                LabValueRow(point: u, status: LabAnalyzer.status(.uacr, u.value, profile: profile))
            }
            if let c = cr.last {
                Divider()
                LabValueRow(point: c, status: LabAnalyzer.status(.creatinine, c.value, profile: profile))
            }
            if egfr.last != nil && uacr.last != nil {
                Text("肾功能分期要看相隔 3 个月以上的结果，由医生确认；eGFR 和尿白蛋白一起看，比单看一项更准确。")
                    .font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct LabKindCard: View {
    let kind: LabKind
    let labs: [LabPoint]
    let profile: ProfileSnapshot

    var body: some View {
        let series = labs.filter { $0.kind == kind }.sorted { $0.date < $1.date }
        Card {
            CardHeader(title: kind.label, subtitle: kind.meaning, icon: kind.icon, color: Theme.labs) { EmptyView() }
            if let last = series.last {
                LabValueRow(point: last, status: LabAnalyzer.status(kind, last.value, profile: profile))
                if series.count >= 2 {
                    Chart(series, id: \.date) { l in
                        LineMark(x: .value("日期", l.date, unit: .day), y: .value(kind.label, l.value)).foregroundStyle(Theme.labs)
                        PointMark(x: .value("日期", l.date, unit: .day), y: .value(kind.label, l.value)).foregroundStyle(Theme.labs).symbolSize(30)
                    }
                    .chartYScale(domain: .automatic(includesZero: false))
                    .frame(height: 110)
                    .accessibilityLabel("\(kind.label)变化：" + series.map { "\($0.date.formatted(.dateTime.month().day())) \($0.valueText)" }.joined(separator: "，"))
                }
            }
        }
    }
}

/// Value, unit, date and how it reads.
private struct LabValueRow: View {
    let point: LabPoint
    let status: LabStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(point.kind.label).font(.subheadline.weight(.semibold))
                Spacer()
                Text(point.valueText).font(.system(.title2, design: .rounded).weight(.semibold)).monospacedDigit()
                Text(point.kind.unit).font(.footnote).foregroundStyle(.secondary)
            }
            HStack {
                StatusLabel(status.metric).font(.subheadline)
                Spacer()
                Text(point.date.formatted(.dateTime.year().month().day()) + (point.estimated ? " · 估算" : ""))
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

extension LabStatus {
    var metric: MetricStatus {
        switch level {
        case .normal: .good(text)
        case .watch: .neutral(text)
        case .abnormal: .attention(text)
        case .urgent: .urgent(text)
        }
    }
}

/// Every result by date, to check or delete a mistyped one.
struct LabHistoryView: View {
    @Environment(\.modelContext) private var ctx
    @Query(sort: \LabResult.date, order: .reverse) private var labs: [LabResult]

    var body: some View {
        List {
            ForEach(labs) { l in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(l.kind.label).font(.subheadline)
                        Text(l.date.formatted(.dateTime.year().month().day()) + (l.estimated ? " · 按肌酐估算" : "") + (l.note.isEmpty ? "" : " · \(l.note)"))
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(l.kind.format(l.value)).font(.subheadline.weight(.semibold)).monospacedDigit()
                    Text(l.kind.unit).font(.footnote).foregroundStyle(.secondary)
                }
            }
            .onDelete { idx in for i in idx { ctx.delete(labs[i]) } }
            if labs.isEmpty { Text("暂无记录").foregroundStyle(.secondary) }
        }
        .navigationTitle("化验记录").calmStyle()
        .toolbar { EditButton() }
    }
}

/// The 关键指标 entry: the latest kidney values at a glance.
struct LabSummaryCard: View {
    @Query(sort: \LabResult.date) private var labs: [LabResult]
    let profile: ProfileSnapshot

    var body: some View {
        let points = labs.map(\.point)
        let shown = LabAnalyzer.latest(points).filter { [.egfr, .uacr, .potassium, .hemoglobin].contains($0.kind) }.prefix(3)
        NavigationLink { LabResultsView() } label: {
            Card {
                CardHeader(title: "化验结果", subtitle: points.isEmpty ? nil : "最近 \(points.map(\.date).max()!.formatted(.dateTime.month().day()))", icon: "testtube.2", color: Theme.labs) {
                    Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                }
                if shown.isEmpty {
                    Text("记录 eGFR、血肌酐、血钾、尿白蛋白等化验结果，Pulse 帮你解读并跟踪趋势。").font(.subheadline).foregroundStyle(.secondary)
                } else {
                    ForEach(Array(shown), id: \.kind) { l in
                        HStack(alignment: .firstTextBaseline) {
                            Text(l.kind.label).font(.subheadline)
                            Text(l.valueText).font(.subheadline.weight(.semibold)).monospacedDigit()
                            Spacer()
                            StatusLabel(LabAnalyzer.status(l.kind, l.value, profile: profile).metric).font(.subheadline)
                        }
                    }
                }
            }
        }
        .buttonStyle(.plain)
    }
}
