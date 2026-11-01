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
                    Text("最近一次").font(.caption).foregroundStyle(.secondary)
                    HStack(alignment: .firstTextBaseline, spacing: Theme.Space.tight) {
                        Text(t.latest.map { $0.value.noDecimal } ?? "—").font(.system(.largeTitle, design: .rounded).weight(.bold)).monospacedDigit()
                        Text("bpm").foregroundStyle(.secondary)
                    }
                    if let l = t.latest {
                        Text("\(l.day.formatted(.dateTime.month().day())) · \(l.source.label)").font(.footnote).foregroundStyle(.secondary)
                    }
                }
            } trailing: {
                VStack(alignment: dynamicTypeSize.isAccessibilitySize ? .leading : .trailing, spacing: Theme.Space.item) {
                    statusChip(t)
                    if let c = t.changeFromBaseline {
                        StatusLabel(text: "较基线 \(c.signedText) bpm", icon: c <= -1 ? "arrow.down.circle.fill" : (c >= 2 ? "arrow.up.circle.fill" : "equal.circle.fill"),
                                    color: c <= -1 ? .green : (c >= 2 ? .orange : .gray), secondaryText: true).font(.caption)
                    }
                }
            }
            Text(t.headline).font(.headline).fixedSize(horizontal: false, vertical: true)
            MetricRow {
                MetricTile(label: "7 日均值", value: t.avg7.map { $0.noDecimal } ?? "—", unit: "bpm", icon: "7.circle", color: Theme.heartData,
                           footnote: "\(t.coverage7)/7 天")
                MetricTile(label: "4 周均值", value: t.avg28.map { $0.noDecimal } ?? "—", unit: "bpm", icon: "calendar", color: Theme.heartData,
                           footnote: "\(t.coverage28)/28 天")
                MetricTile(label: "个人基线", value: t.baseline.map { $0.noDecimal } ?? "—", unit: "bpm", icon: "flag", color: .secondary,
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
            CardHeader(title: "趋势", subtitle: "点：每日数值 · 线：7 日均值 · 带：日常波动范围", icon: "chart.xyaxis.line", color: Theme.heartData)
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
                                Text("基线 \(b.noDecimal)").font(.caption2).foregroundStyle(.secondary)
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
                                    Text("\(s.value.noDecimal) bpm").font(.caption.bold())
                                    Text(s.day.formatted(.dateTime.month().day())).font(.caption2).foregroundStyle(.secondary)
                                }
                                .padding(Theme.Space.item)
                                .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.Radius.inner, style: .continuous))
                                .shadow(radius: 2)
                            }
                    }
                }
                .chartYScale(domain: lo...hi)
                .chartXSelection(value: $selected)
                .frame(height: 220)
                if !excluded.isEmpty {
                    Text("空心灰点为其他测量方式的数值（\(excluded.count) 个），不参与趋势计算。").font(.footnote).foregroundStyle(.secondary)
                }
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
            CardHeader(title: "解读", subtitle: "区分单次波动、持续变化与长期趋势", icon: "text.magnifyingglass")
            ForEach(t.interpretation, id: \.self) { BulletText(text: $0) }
        }
    }

    private func contextCard(_ t: RHRTrend) -> some View {
        Card {
            CardHeader(title: "偏高的日子与可能背景", subtitle: "近 3 周高于 4 周均值的早晨", icon: "list.bullet.rectangle", color: .orange)
            ForEach(t.elevatedDays.prefix(6)) { d in
                VStack(alignment: .leading, spacing: Theme.Space.item) {
                    AdaptiveRow {
                        Text(d.day.formatted(.dateTime.month().day().weekday())).font(.subheadline.weight(.medium))
                    } trailing: {
                        StatusLabel(text: "\(d.value.noDecimal) bpm（+\(d.delta.noDecimal)）", icon: "arrow.up.circle.fill", color: .orange).font(.subheadline).monospacedDigit()
                    }
                    if d.hasExplanation {
                        FlowLayout(spacing: Theme.Space.item) {
                            ForEach(d.tags) { Chip(text: $0.label, icon: $0.icon, color: .orange) }
                            ForEach(d.inferred, id: \.self) { Chip(text: $0, icon: "info.circle", color: .secondary) }
                        }
                    } else {
                        AdaptiveRow(stackedSpacing: Theme.Space.item) {
                            Text("没有记录到相关背景").font(.footnote).foregroundStyle(.secondary)
                        } trailing: {
                            Button("补充背景") { contextDay = d.day }.buttonStyle(.bordered)
                        }
                    }
                }
                if d.id != t.elevatedDays.prefix(6).last?.id { Divider() }
            }
            Text("这些是同时出现的情况，不一定是原因。持续记录后，可在「复盘」中查看哪些因素与你的心率变化关联更稳定。")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private func limitationsCard(_ t: RHRTrend) -> some View {
        Card {
            CardHeader(title: "判断的局限", subtitle: t.limitations.isEmpty ? "当前数据条件良好" : "以下情况会影响解读", icon: "exclamationmark.circle", color: .gray)
            if t.limitations.isEmpty {
                Text("近期数据充足，测量方式一致，未记录到影响可比性的用药或生病。").font(.subheadline).foregroundStyle(.secondary)
            }
            ForEach(t.limitations, id: \.self) { Callout(kind: .limitation, text: $0) }
        }
    }

    @ViewBuilder
    private func hrvCard(_ a: Analytics) -> some View {
        let pts = a.days.filter { $0.day >= Date.app.adding(days: -range) }.compactMap { d in d.hrv.map { (d.day, $0) } }
        if pts.count >= 5 {
            Card {
                CardHeader(title: "心率变异性（HRV）", subtitle: "通常与静息心率反向变化，较高代表恢复较好（个体差异大）", icon: "waveform.path.ecg", color: Theme.heartData)
                Chart {
                    ForEach(pts, id: \.0) { p in
                        BarMark(x: .value("日期", p.0, unit: .day), y: .value("ms", p.1))
                            .foregroundStyle(Theme.heartData.opacity(0.6))
                    }
                }
                .frame(height: 120)
            }
        }
    }

    private var guideCard: some View {
        Card {
            CardHeader(title: "让数据可比较", icon: "ruler", color: .secondary)
            BulletText(text: "固定一种来源：手表夜间数据，或每天醒后静躺 1 分钟手动测量。")
            BulletText(text: "佩戴松紧适中，睡前确认手表电量。")
            BulletText(text: "生病、饮酒、熬夜、时差、经期、开始或停用药物时，在「状况」中记一笔，解读会更准确。")
            BulletText(text: "成人静息心率通常在 60–100 bpm，规律训练者可能更低。静息心率受运动水平、压力、药物等多种因素影响，评估进展时需要结合个人背景（American Heart Association）。")
        }
    }
}

struct IdentifiedDate: Identifiable, Hashable {
    let date: Date
    var id: Date { date }
}
