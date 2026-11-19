import SwiftUI
import SwiftData
import Charts

struct HeartView: View {
    enum Segment: String, CaseIterable, Identifiable {
        case rhr = "静息心率", vitals = "关键指标", events = "异常跟进"
        var id: String { rawValue }
    }
    @State private var segment: Segment = DebugLaunch.value("-PulseSegment").flatMap { ["vitals": .vitals, "events": .events][$0] } ?? .rhr
    @Query(sort: \HealthEvent.createdAt, order: .reverse) private var events: [HealthEvent]

    var body: some View {
        NavigationStack {
            Group {
                switch segment {
                case .rhr: RHRTrendView()
                case .vitals: VitalsView()
                case .events: HealthEventsList()
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                Picker("", selection: $segment) {
                    ForEach(Segment.allCases) { s in
                        let open = events.filter { $0.status.isActive }.count
                        Text(s == .events && open > 0 ? "\(s.rawValue) \(open)" : s.rawValue).tag(s)
                    }
                }
                .pickerStyle(.segmented)
                .readableWidth()
                .padding(.horizontal, Theme.Space.gutter)
                .padding(.bottom, Theme.Space.item)
                .background(.bar)
            }
            .navigationTitle("趋势")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

// MARK: - Resting heart-rate trend (需求 2)

struct RHRTrendView: View {
    @Environment(\.modelContext) private var ctx
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Query private var profiles: [UserProfile]
    @Query private var meds: [MedicationEntry]
    @Query(sort: \DailyRecord.day) private var records: [DailyRecord]
    @Query(sort: \ActivitySession.start) private var sessions: [ActivitySession]
    @State private var range = 90
    @State private var selected: Date?
    @State private var contextDay: Date?

    var body: some View {
        let a = Analytics(profile: profiles.first, medications: meds, records: records, sessions: sessions)
        let t = a.trend
        ScreenScroll {
            summaryCard(t)
            chartCard(t, a)
            interpretationCard(t)
            if !t.elevatedDays.isEmpty { contextCard(t) }
            limitationsCard(t)
            hrvCard(a)
            guideCard
            Disclaimer()
        }
        .sheet(item: Binding(get: { contextDay.map(IdentifiedDate.init) }, set: { contextDay = $0?.date })) { d in
            CalmNavigationStack {
                ContextLogForm(initialDate: d.date).navigationTitle("补充背景").navigationBarTitleDisplayMode(.inline)
            }
        }
    }

    private func summaryCard(_ t: RHRTrend) -> some View {
        Card {
            AdaptiveRow(alignment: .firstTextBaseline, stackedSpacing: Theme.Space.item) {
                VStack(alignment: .leading, spacing: Theme.Space.hairline) {
                    Text("最近一次").font(Theme.TypeScale.body).foregroundStyle(.secondary)
                    HStack(alignment: .firstTextBaseline, spacing: Theme.Space.tight) {
                        Text(t.latest.map { $0.value.noDecimal } ?? "—").font(Theme.TypeScale.title.weight(.bold)).monospacedDigit()
                        Text("bpm").foregroundStyle(.secondary)
                    }
                    if let l = t.latest {
                        Text("\(l.day.formatted(.dateTime.month().day())) · \(l.source.label)").font(Theme.TypeScale.body).foregroundStyle(.secondary)
                    }
                }
            } trailing: {
                VStack(alignment: dynamicTypeSize.isAccessibilitySize ? .leading : .trailing, spacing: Theme.Space.item) {
                    statusChip(t)
                    if let c = t.changeFromBaseline {
                        let r = Int(abs(c).rounded())
                        StatusLabel(text: r == 0 ? "与基线持平" : "比基线\(c < 0 ? "低" : "高") \(r) bpm", icon: c <= -1 ? "arrow.down.circle.fill" : (c >= 2 ? "arrow.up.circle.fill" : "equal.circle.fill"),
                                    color: c <= -1 ? .green : (c >= 2 ? .orange : .gray), secondaryText: true).font(Theme.TypeScale.body)
                    }
                }
            }
            Text(t.headline).font(Theme.TypeScale.headline).fixedSize(horizontal: false, vertical: true)
            MetricRow {
                MetricTile(label: "7 日均值", value: t.avg7.map { $0.noDecimal } ?? "—", unit: "bpm",
                           footnote: "\(t.coverage7)/7 天")
                MetricTile(label: "4 周均值", value: t.avg28.map { $0.noDecimal } ?? "—", unit: "bpm",
                           footnote: "\(t.coverage28)/28 天")
                MetricTile(label: "个人基线", value: t.baseline.map { $0.noDecimal } ?? "—", unit: "bpm",
                           footnote: "波动 ±\(t.personalSD.noDecimal)")
            }
        }
    }

    @ViewBuilder
    private func statusChip(_ t: RHRTrend) -> some View {
        switch (t.sustained, t.shortTerm) {
        case (.rise, _): Chip(text: "持续偏高", icon: "arrow.up.right", color: .orange, filled: true)
        case (.drop, _): Chip(text: "持续偏低", icon: "arrow.down.right", color: .gray, filled: true)
        case (_, .spikeUp): Chip(text: "单次波动", icon: "waveform", color: .orange)
        case (_, .spikeDown): Chip(text: "单次波动", icon: "waveform", color: .gray)
        case (.none, _): Chip(text: "正常波动", icon: "checkmark", color: .green)
        default: Chip(text: "数据积累中", icon: "hourglass", color: .secondary)
        }
    }

    private func chartCard(_ t: RHRTrend, _ a: Analytics) -> some View {
        let from = Date.app.startOfDay.adding(days: -range)
        let pts = t.points.filter { $0.day >= from }
        let rolling = t.rolling7.filter { $0.day >= from }
        let excluded = t.excludedPoints.filter { $0.day >= from }
        let elevated = Set(t.elevatedDays.map(\.day))
        let values = (pts + excluded).map(\.value) + [t.baseline].compactMap { $0 }
        let lo = (values.min() ?? 50) - 3, hi = (values.max() ?? 80) + 3
        let sel = selected.flatMap { s in pts.first { $0.day.isSameDay(s) } }
        return Card {
            CardHeader(title: "趋势", icon: "chart.xyaxis.line", color: Theme.heartData)
            Picker("范围", selection: $range) {
                Text("30 天").tag(30); Text("90 天").tag(90); Text("180 天").tag(180); Text("1 年").tag(365)
            }
            .pickerStyle(.segmented)
            if pts.isEmpty {
                EmptyHint(icon: "heart.text.square", text: "暂无数据。连接设备或在晨起感受中手动记录。")
            } else {
                Chart {
                    if let a28 = t.avg28 {
                        RectangleMark(xStart: .value("起", from), xEnd: .value("止", Date.app),
                                      yStart: .value("低", a28 - t.personalSD), yEnd: .value("高", a28 + t.personalSD))
                            .foregroundStyle(Theme.heartData.opacity(0.07))
                    }
                    if let b = t.baseline {
                        RuleMark(y: .value("基线", b))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                            .foregroundStyle(Color.gray)
                            .annotation(position: .top, alignment: .leading) {
                                Text("基线 \(b.noDecimal)").font(Theme.TypeScale.caption).foregroundStyle(.secondary)
                            }
                    }
                    ForEach(excluded) { p in
                        PointMark(x: .value("日期", p.day, unit: .day), y: .value("bpm", p.value))
                            .symbol(Circle().strokeBorder(lineWidth: 1))
                            .foregroundStyle(.gray.opacity(0.6))
                            .symbolSize(18)
                    }
                    ForEach(pts) { p in
                        PointMark(x: .value("日期", p.day, unit: .day), y: .value("bpm", p.value))
                            .foregroundStyle(elevated.contains(p.day) ? Color.orange : Theme.heartData.opacity(0.4))
                            .symbolSize(elevated.contains(p.day) ? 36 : 16)
                    }
                    ForEach(rolling) { p in
                        LineMark(x: .value("日期", p.day, unit: .day), y: .value("7日均值", p.value), series: .value("系列", "7日均值"))
                            .interpolationMethod(.catmullRom)
                            .foregroundStyle(Theme.heartData)
                            .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    }
                    if let s = sel {
                        RuleMark(x: .value("选中", s.day, unit: .day))
                            .foregroundStyle(Color.gray.opacity(0.4))
                            .annotation(position: .top, overflowResolution: .init(x: .fit, y: .disabled)) {
                                VStack(spacing: Theme.Space.hairline) {
                                    Text("\(s.value.noDecimal) bpm").font(Theme.TypeScale.body.bold())
                                    Text(s.day.formatted(.dateTime.month().day())).font(Theme.TypeScale.body).foregroundStyle(.secondary)
                                }
                                .padding(Theme.Space.item)
                                .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.Radius.inner, style: .continuous))
                                .shadow(radius: 2)
                            }
                    }
                }.pulseChartAxes()
                .chartYScale(domain: lo...hi)
                .chartXSelection(value: $selected)
                .frame(height: 220)
                Text("点为每天的数值，线为 7 日均值，浅色带为日常波动范围" + (excluded.isEmpty ? "" : "；空心灰点来自其他测量方式，不计入趋势"))
                    .font(Theme.TypeScale.caption).foregroundStyle(.secondary)
                if let s = sel, let d = a.day(s.day) {
                    let tags = d.tags.union(a.day(s.day.adding(days: -1))?.tags.filter(\.actsOnNextMorning) ?? [])
                    if !tags.isEmpty {
                        FlowLayout(spacing: Theme.Space.item) {
                            ForEach(Array(tags).sorted { $0.rawValue < $1.rawValue }) { Chip(text: $0.label, icon: $0.icon, color: .orange) }
                        }
                    }
                }
            }
        }
    }

    private func interpretationCard(_ t: RHRTrend) -> some View {
        Card {
            CardHeader(title: "解读", icon: "text.magnifyingglass")
            ForEach(t.interpretation, id: \.self) { BulletText(text: $0) }
        }
    }

    private func contextCard(_ t: RHRTrend) -> some View {
        Card {
            CardHeader(title: "偏高的日子", subtitle: "近 3 周比 4 周均值高的早晨", icon: "list.bullet.rectangle", color: .orange)
            ForEach(t.elevatedDays.prefix(6)) { d in
                VStack(alignment: .leading, spacing: Theme.Space.item) {
                    AdaptiveRow {
                        Text(d.day.formatted(.dateTime.month().day().weekday())).font(Theme.TypeScale.body.weight(.medium))
                    } trailing: {
                        StatusLabel(text: "\(d.value.noDecimal) bpm（+\(d.delta.noDecimal)）", icon: "arrow.up.circle.fill", color: .orange).font(Theme.TypeScale.body).monospacedDigit()
                    }
                    if d.hasExplanation {
                        FlowLayout(spacing: Theme.Space.item) {
                            ForEach(d.tags) { Chip(text: $0.label, icon: $0.icon, color: .orange) }
                            ForEach(d.inferred, id: \.self) { Chip(text: $0, icon: "info.circle", color: .secondary) }
                        }
                    } else {
                        AdaptiveRow(stackedSpacing: Theme.Space.item) {
                            Text("没有记录到相关背景").font(Theme.TypeScale.body).foregroundStyle(.secondary)
                        } trailing: {
                            Button("补充背景") { contextDay = d.day }.buttonStyle(.bordered)
                        }
                    }
                }
                if d.id != t.elevatedDays.prefix(6).last?.id { Divider() }
            }
            Text("同一天出现不等于原因；哪些因素真的相关，看「复盘 › 长期」。")
                .font(Theme.TypeScale.body).foregroundStyle(.secondary)
        }
    }

    /// Only when something limits the reading; data in good shape needs no card.
    @ViewBuilder
    private func limitationsCard(_ t: RHRTrend) -> some View {
        if !t.limitations.isEmpty {
            Card {
                CardHeader(title: "会影响判断的情况", icon: "exclamationmark.circle", color: .gray)
                ForEach(t.limitations, id: \.self) { Callout(kind: .limitation, text: $0) }
            }
        }
    }

    @ViewBuilder
    private func hrvCard(_ a: Analytics) -> some View {
        let pts = a.days.filter { $0.day >= Date.app.adding(days: -range) }.compactMap { d in d.hrv.map { (d.day, $0) } }
        if pts.count >= 5 {
            Card {
                CardHeader(title: "心率变异性（HRV）", subtitle: "通常越高恢复越好，因人而异", icon: "waveform.path.ecg", color: Theme.heartData)
                Chart {
                    ForEach(pts, id: \.0) { p in
                        BarMark(x: .value("日期", p.0, unit: .day), y: .value("ms", p.1))
                            .foregroundStyle(Theme.heartData.opacity(0.6))
                    }
                }.pulseChartAxes()
                .frame(height: 120)
            }
        }
    }

    private var guideCard: some View {
        Card {
            CardHeader(title: "让数据可比较", icon: "ruler", color: .secondary)
            BulletText(text: "只用一种来源：手表夜间数据，或每天醒后静躺 1 分钟手动测。")
            BulletText(text: "手表松紧适中，睡前看一眼电量。")
            BulletText(text: "生病、饮酒、熬夜、倒时差、经期或换药时，在「状况」里记一笔。")
            BulletText(text: "成人静息心率通常在 60–100 bpm，规律运动的人可能更低。")
        }
    }
}

struct IdentifiedDate: Identifiable, Hashable {
    let date: Date
    var id: Date { date }
}
