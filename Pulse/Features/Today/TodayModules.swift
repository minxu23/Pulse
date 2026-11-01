import SwiftUI
import SwiftData
import Charts

/// Where glucose is heading in the next hour: the slope, or — within two hours of a meal — that meal's
/// usual curve from the user's own past meals.
enum GlucoseOutlook {
    static func make(vitals: [VitalPoint], meals: [MealLog], profile p: ProfileSnapshot, now: Date)
        -> (forecast: NextHourForecast, meal: (log: MealLog, prediction: MealPrediction)?)? {
        guard let f = NextHourForecaster.glucose(vitals, profile: p, now: now) else { return nil }
        guard let m = meals.filter({ $0.time <= now && $0.time > now.addingTimeInterval(-2 * 3600) }).max(by: { $0.time < $1.time }),
              [.breakfast, .lunch, .dinner, .snack].contains(m.kind) else { return (f, nil) }
        // The meal itself is not yet part of what the prediction learns from.
        let input = GlucoseModelInput(vitals: vitals, meals: meals.filter { $0.id != m.id }, profile: p, now: now)
        guard let pr = GlucoseModels.current.predict(input, kind: m.kind, carbs: m.carbsG, at: m.time) else { return (f, nil) }
        return (NextHourForecaster.following(f, meal: pr, eatenAt: m.time, label: m.kind.label, profile: p), (m, pr))
    }
}

/// Out-of-range readings still waiting for the user to recall a cause.
enum AbnormalRecall {
    /// The latest out-of-range reading of the last day without a note. A CGM run out of range counts
    /// once: any note within 3 hours of it answers it. `readings` newest first.
    static func pending(_ readings: [VitalReading], profile p: ProfileSnapshot, now: Date) -> (reading: VitalReading, abnormal: AbnormalReading)? {
        guard let r = readings.first(where: { $0.time > now.adding(days: -1) && AbnormalReadings.check($0.point, profile: p) != nil }),
              let a = AbnormalReadings.check(r.point, profile: p),
              !readings.contains(where: { !$0.note.isEmpty && abs($0.time.timeIntervalSince(r.time)) < 3 * 3600 }) else { return nil }
        return (r, a)
    }
    /// The latest out-of-range reading of the last day that has a note.
    static func noted(_ readings: [VitalReading], profile p: ProfileSnapshot, now: Date) -> VitalReading? {
        readings.first { $0.time > now.adding(days: -1) && !$0.note.isEmpty && AbnormalReadings.check($0.point, profile: p) != nil }
    }
}

/// A module on the home page, shown when that module is on. 血糖 and 血压 are small tiles the size of
/// the 全天安排 tiles — key number, one line on where it is heading, a badge when out of range — that
/// open their module page, where the chart, the next hour and the prompt to note a cause live; a
/// long press offers the cause note and the Health Agent straight away. 专项运动 stays a card.
struct TodayModuleCard: View {
    let data: TodayData
    let card: HomeCard
    var onRemove: () -> Void = {}
    var onEdit: () -> Void = {}
    @Query(sort: \VitalReading.time, order: .reverse) private var vitals: [VitalReading]
    @Query(sort: \MealLog.time) private var meals: [MealLog]
    @State private var noting: VitalReading?
    @State private var agentQuestion: String?

    var body: some View {
        let recent = Array(vitals.prefix(while: { $0.time > data.now.adding(days: -15) }))
        let kind: VitalKind? = card == .glucose ? .glucose : (card == .bloodPressure ? .bloodPressure : nil)
        let pending = kind.flatMap { k in AbnormalRecall.pending(recent.filter { $0.kind == k }, profile: data.p, now: data.now) }
        Group {
            switch card {
            case .glucose: glucoseTile(recent)
            case .bloodPressure: bpTile(recent)
            case .race: if let race = data.p.race { raceCard(race) }
            default: EmptyView()
            }
        }
        .contextMenu {
            if let (r, a) = pending {
                Button("记下可能的原因", systemImage: "square.and.pencil") { noting = r }
                Button(AgentNameSettings.shared.phrase("问问"), systemImage: "sparkles") { agentQuestion = a.question(at: r.time, causes: [], text: "") }
                Divider()
            }
            Button("从首页移除", systemImage: "minus.circle", role: .destructive, action: onRemove)
            Button("编辑首页", systemImage: "square.grid.2x2", action: onEdit)
        }
        .sheet(item: $noting) { r in
            if let a = AbnormalReadings.check(r.point, profile: data.p) {
                NavigationStack {
                    AbnormalNoteForm(reading: r, abnormal: a, onAsk: { q in noting = nil; agentQuestion = q })
                        .navigationTitle("回想一下原因").navigationBarTitleDisplayMode(.inline)
                        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { noting = nil } } }
                }
                .pageMargins()
            }
        }
        .sheet(item: Binding(get: { agentQuestion.map(IdentifiedText.init) }, set: { agentQuestion = $0?.text })) { q in
            HealthAgentChatView(initialQuestion: q.text)
        }
    }

    // MARK: Tiles

    private func glucoseTile(_ recent: [VitalReading]) -> some View {
        let latest = recent.first { $0.kind == .glucose }
        let outlook = GlucoseOutlook.make(vitals: data.recentVitals, meals: meals, profile: data.p, now: data.now)
        let abnormal = latest.flatMap { AbnormalReadings.check($0.point, profile: data.p) }
        var flag: (String, Color)? = abnormal.map { ($0.direction == .high ? "偏高" : "偏低", $0.severe ? .red : .orange) }
        if flag == nil, let alert = outlook?.forecast.alert {
            flag = switch alert { case .lowSoon: ("可能偏低", .orange); case .highSoon: ("可能偏高", .orange) }
        }
        var caption = latest.map { "最近 \(Self.when($0.time))" } ?? "还没有记录"
        if let o = outlook {
            let peakAt = o.meal.map { $0.log.time.addingTimeInterval(Double($0.prediction.peakMinutes) * 60) }
            if let m = o.meal, let t = peakAt, t > data.now {
                caption = "\(m.log.kind.label)后 \(Clock.text(t.minutesOfDay)) 前后到高点"
            } else {
                caption = "1 小时后 \(o.forecast.end.low.oneDecimal)–\(o.forecast.end.high.oneDecimal)"
            }
        }
        return NavigationLink { DiabetesCareView() } label: {
            ModuleTile(title: "血糖", icon: "drop.fill", color: Theme.glucose, metric: latest.map { $0.value.oneDecimal } ?? "—",
                       unit: "mmol/L", rate: outlook?.forecast.rate, caption: caption, flag: flag)
        }
        .buttonStyle(.plain)
    }

    private func bpTile(_ recent: [VitalReading]) -> some View {
        let bp = recent.filter { $0.kind == .bloodPressure }
        let latest = bp.first
        let week = bp.filter { $0.time > data.now.adding(days: -7) }
        let abnormal = latest.flatMap { AbnormalReadings.check($0.point, profile: data.p) }
        let flag = abnormal.map { ($0.direction == .high ? "偏高" : "偏低", $0.severe ? Color.red : Color.orange) }
        let caption = Stats.mean(week.map(\.value)).flatMap { s in Stats.mean(week.compactMap(\.value2)).map { "7 天平均 \(Int(s))/\(Int($0))" } }
            ?? latest.map { "最近 \(Self.when($0.time))" } ?? "还没有记录"
        return NavigationLink { CardioCareView() } label: {
            ModuleTile(title: "血压", icon: "heart.text.square.fill", color: Theme.heartData,
                       metric: latest.map { "\(Int($0.value))/\(Int($0.value2 ?? 0))" } ?? "—", unit: "mmHg", rate: nil, caption: caption, flag: flag)
        }
        .buttonStyle(.plain)
    }

    private func raceCard(_ race: RaceInfo) -> some View {
        let w = MarathonPlanner.week(profile: data.p, race: race, weekStart: data.day.weekStart)
        return ModuleCard(title: race.name.isEmpty ? "专项运动" : race.name, icon: "flag.checkered", color: Theme.activity,
                       subtitle: w.weeksToRace > 0 ? "距比赛 \(w.weeksToRace) 周 · \(w.phase.label)" : w.phase.label) {
                HStack(alignment: .firstTextBaseline, spacing: Theme.Space.tight) {
                    Text(w.weeklyKm.noDecimal).font(.system(.title, design: .rounded).weight(.semibold)).monospacedDigit()
                    Text("公里 · 本周跑量").font(.subheadline).foregroundStyle(.secondary)
                    Spacer(minLength: Theme.Space.item)
                    Text("最长 \(w.longRunKm.noDecimal) 公里").font(.subheadline).foregroundStyle(.secondary)
                }
                Text(w.phase.focus).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } prompt: { EmptyView() } destination: { MarathonView() }
    }

    static func when(_ t: Date) -> String {
        t.isSameDay(.app) ? Clock.text(t.minutesOfDay) : (t.isSameDay(Date.app.adding(days: -1)) ? "昨天 \(Clock.text(t.minutesOfDay))" : t.formatted(.dateTime.month().day()))
    }
}

/// A module tile, built like the 全天安排 tiles: glyph and badge, title, key number, one line.
struct ModuleTile: View {
    let title: String
    let icon: String
    let color: Color
    let metric: String
    let unit: String
    /// Change per minute, shown as an arrow after the number (glucose).
    var rate: Double?
    let caption: String
    var flag: (text: String, color: Color)?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                Image(systemName: icon)
                    .font(.headline).foregroundStyle(.white)
                    .frame(width: Theme.Size.tileIcon, height: Theme.Size.tileIcon)
                    .background(color.gradient, in: RoundedRectangle(cornerRadius: Theme.Radius.tile(Theme.Size.tileIcon), style: .continuous))
                Spacer()
                if let flag {
                    StatusLabel(text: flag.text, icon: "exclamationmark.circle.fill", color: flag.color).font(.caption.weight(.semibold))
                }
            }
            Spacer(minLength: Theme.Space.block)
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.tight) {
                Text(metric).font(.system(.title2, design: .rounded).weight(.bold)).monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.7)
                Text(unit).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if let r = rate {
                    Image(systemName: abs(r) < 0.03 ? "arrow.right" : (r > 0 ? (r >= 0.1 ? "arrow.up" : "arrow.up.right") : (r <= -0.1 ? "arrow.down" : "arrow.down.right")))
                        .font(.caption.weight(.bold)).foregroundStyle(.secondary)
                        .accessibilityLabel(abs(r) < 0.03 ? "平稳" : (r > 0 ? "上升" : "下降"))
                }
            }
            .padding(.top, Theme.Space.hairline)
            Text(caption).font(.caption).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
                .padding(.top, Theme.Space.hairline)
        }
        .padding(Theme.Space.cardPadding)
        .frame(maxWidth: .infinity, minHeight: 156, alignment: .topLeading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// On the 血糖管理 page: the next hour as a chart, with the line on where it is heading.
struct GlucoseOutlookCard: View {
    @Query private var profiles: [UserProfile]
    @Query private var meds: [MedicationEntry]
    @Query(sort: \VitalReading.time) private var vitals: [VitalReading]
    @Query(sort: \MealLog.time) private var meals: [MealLog]

    var body: some View {
        let p = profiles.first?.snapshot(medications: meds) ?? ProfileSnapshot()
        let now = Date.app
        let points = vitals.filter { $0.time > now.adding(days: -15) }.map(\.point)
        if let o = GlucoseOutlook.make(vitals: points, meals: meals, profile: p, now: now) {
            VStack(alignment: .leading, spacing: Theme.Space.block) {
                CardTitle("未来 1 小时", detail: "按最近的变化\(o.meal != nil ? "和这一餐" : "")推算")
                GlucoseHourChart(history: NextHourForecaster.cgm(points).filter { $0.time > o.forecast.from.addingTimeInterval(-3 * 3600) },
                                 forecast: o.forecast, low: p.glucoseLow, high: p.glucoseHigh)
                Label {
                    Text(o.forecast.message).fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: o.forecast.alert != nil ? "exclamationmark.triangle.fill" : "clock.arrow.circlepath")
                        .foregroundStyle(o.forecast.alert != nil ? Color.orange : Color.secondary)
                }
                .font(.subheadline)
                Text(NextHourForecaster.caveat).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .cardSurface()
        }
    }
}

/// On a module page: the latest out-of-range reading still without a cause, with the way to note it
/// or ask the Health Agent — or what was noted.
struct AbnormalRecallCard: View {
    let kind: VitalKind
    @Query private var profiles: [UserProfile]
    @Query private var meds: [MedicationEntry]
    @Query(sort: \VitalReading.time, order: .reverse) private var vitals: [VitalReading]
    @State private var noting: VitalReading?
    @State private var agentQuestion: String?

    var body: some View {
        let p = profiles.first?.snapshot(medications: meds) ?? ProfileSnapshot()
        let now = Date.app
        let readings = vitals.filter { $0.kind == kind && $0.time > now.adding(days: -2) }
        Group {
            if let (r, a) = AbnormalRecall.pending(readings, profile: p, now: now) {
                VStack(alignment: .leading, spacing: Theme.Space.block) {
                    StatusLabel(text: "\(TodayModuleCard.when(r.time)) \(a.title) \(a.valueText)", icon: "exclamationmark.circle.fill",
                                color: a.severe ? .red : .orange)
                        .font(.headline)
                    Text(a.firstLine ?? "回想一下之前发生了什么，记下来，下次更容易找到规律。")
                        .font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: Theme.Space.item) {
                        Button("记下可能的原因") { noting = r }.buttonStyle(.bordered)
                        Button { agentQuestion = a.question(at: r.time, causes: [], text: "") } label: {
                            Text(AgentNameSettings.shared.phrase("问问")).frame(minHeight: Theme.Size.tap).contentShape(Rectangle())
                        }
                        .buttonStyle(.borderless)
                        Spacer(minLength: 0)
                    }
                    .font(.subheadline.weight(.semibold))
                }
                .cardSurface()
            } else if let r = AbnormalRecall.noted(readings, profile: p, now: now) {
                // The user's own note, of any length: a two-line preview.
                Label("\(TodayModuleCard.when(r.time)) 已记下：\(r.note)", systemImage: "note.text")
                    .font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, Theme.Space.tight)
            }
        }
        .sheet(item: $noting) { r in
            if let a = AbnormalReadings.check(r.point, profile: p) {
                NavigationStack {
                    AbnormalNoteForm(reading: r, abnormal: a, onAsk: { q in noting = nil; agentQuestion = q })
                        .navigationTitle("回想一下原因").navigationBarTitleDisplayMode(.inline)
                        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { noting = nil } } }
                }
                .pageMargins()
            }
        }
        .sheet(item: Binding(get: { agentQuestion.map(IdentifiedText.init) }, set: { agentQuestion = $0?.text })) { q in
            HealthAgentChatView(initialQuestion: q.text)
        }
    }
}

private struct IdentifiedText: Identifiable {
    let text: String
    var id: String { text }
}

/// A white module card: glyph, title and subtitle with a chevron, the content — together one link to
/// the module page — then an optional prompt with its own buttons, outside the link.
private struct ModuleCard<Content: View, Prompt: View, Destination: View>: View {
    let title: String
    let icon: String
    let color: Color
    let subtitle: String
    @ViewBuilder var content: Content
    @ViewBuilder var prompt: Prompt
    @ViewBuilder var destination: Destination

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.block) {
            NavigationLink { destination } label: {
                VStack(alignment: .leading, spacing: Theme.Space.block) {
                    HStack(spacing: Theme.Space.item) {
                        HStack(spacing: Theme.Space.iconGap) {
                            Image(systemName: icon).imageScale(.small).foregroundStyle(color)
                            Text(title)
                        }
                        .font(.headline)
                        Text(subtitle).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                        Spacer(minLength: Theme.Space.tight)
                        Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                    }
                    content
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            prompt
        }
        .cardSurface()
    }
}

/// The last three hours of CGM readings and the next hour as a dashed line in a widening band.
struct GlucoseHourChart: View {
    let history: [(time: Date, value: Double)]
    let forecast: NextHourForecast
    let low: Double
    let high: Double

    var body: some View {
        let ahead = [NextHourForecast.Point(minutes: 0, mid: forecast.now, low: forecast.now, high: forecast.now)] + forecast.points
        let values = history.map(\.value) + ahead.flatMap { [$0.low, $0.high] } + [low, high]
        Chart {
            RectangleMark(yStart: .value("下限", low), yEnd: .value("上限", high)).foregroundStyle(Color.green.opacity(0.07))
            ForEach(Array(history.enumerated()), id: \.offset) { _, p in
                LineMark(x: .value("时间", p.time), y: .value("mmol/L", p.value), series: .value("线", "实际"))
                    .foregroundStyle(Theme.glucose).lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
            }
            ForEach(ahead, id: \.minutes) { p in
                AreaMark(x: .value("时间", forecast.from.addingTimeInterval(Double(p.minutes) * 60)),
                         yStart: .value("低", p.low), yEnd: .value("高", p.high))
                    .foregroundStyle(Theme.glucose.opacity(0.15))
                LineMark(x: .value("时间", forecast.from.addingTimeInterval(Double(p.minutes) * 60)), y: .value("mmol/L", p.mid), series: .value("线", "预测"))
                    .foregroundStyle(Theme.glucose).lineStyle(StrokeStyle(lineWidth: 2, dash: [4, 3]))
            }
            RuleMark(x: .value("现在", forecast.from)).foregroundStyle(Color.secondary.opacity(0.4)).lineStyle(StrokeStyle(lineWidth: 1))
        }
        .chartYScale(domain: max(2, (values.min() ?? 4) - 0.5)...((values.max() ?? 10) + 0.5))
        .chartXAxis { AxisMarks(values: .stride(by: .hour, count: 1)) { _ in AxisGridLine(); AxisValueLabel(format: .dateTime.hour()) } }
        .chartYAxis { AxisMarks(position: .trailing, values: [low, high]) }
        .frame(height: 110)
        .accessibilityLabel("最近 3 小时血糖和未来 1 小时的推算范围")
        .accessibilityValue("1 小时后约 \(forecast.end.low.oneDecimal) 到 \(forecast.end.high.oneDecimal) 毫摩尔每升")
    }
}

/// Recall what may have caused an out-of-range reading: pick likely causes, add a line, save it as
/// the reading's note — or think it through with the Health Agent.
struct AbnormalNoteForm: View {
    let reading: VitalReading
    let abnormal: AbnormalReading
    var onAsk: ((String) -> Void)? = nil
    var onSaved: (() -> Void)? = nil
    @Environment(\.modelContext) private var ctx
    @Environment(\.dismiss) private var dismiss
    @State private var picked: [String] = []
    @State private var text = ""

    var body: some View {
        Form {
            Section {
                StatusLabel(text: "\(TodayModuleCard.when(reading.time)) \(abnormal.title) \(abnormal.valueText)", icon: "exclamationmark.circle.fill",
                            color: abnormal.severe ? .red : .orange)
                    .font(.headline)
                if let first = abnormal.firstLine {
                    Text(first).font(.subheadline).fixedSize(horizontal: false, vertical: true)
                }
            }
            Section {
                ForEach(abnormal.causes, id: \.self) { c in
                    let on = picked.contains(c)
                    Button {
                        if on { picked.removeAll { $0 == c } } else { picked.append(c) }
                    } label: {
                        HStack(spacing: Theme.Space.block) {
                            Image(systemName: on ? "checkmark.circle.fill" : "circle").font(.title3)
                                .foregroundStyle(on ? Theme.accent : Color.secondary.opacity(0.5))
                            Text(c).foregroundStyle(.primary)
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
                TextField("其他情况（可选）", text: $text, axis: .vertical).lineLimit(1...4)
            } header: {
                Text("之前发生了什么？")
            } footer: {
                Text(AgentNameSettings.shared.phrase("记下来的原因会作为这次读数的备注，复盘和", "都能参考。只是你的回想，不代表确定的原因。"))
            }
            Section {
                Button {
                    reading.note = AbnormalReading.note(causes: picked, text: text)
                    try? ctx.save()
                    onSaved?()
                    dismiss()
                } label: {
                    Text("保存备注").frame(maxWidth: .infinity).fontWeight(.semibold)
                }
                .disabled(picked.isEmpty && text.trimmingCharacters(in: .whitespaces).isEmpty)
                if let onAsk {
                    Button {
                        let note = AbnormalReading.note(causes: picked, text: text)
                        if !note.isEmpty { reading.note = note; try? ctx.save() }
                        onAsk(abnormal.question(at: reading.time, causes: picked, text: text))
                    } label: {
                        Label(AgentNameSettings.shared.phrase("和", "一起分析"), systemImage: "sparkles").frame(maxWidth: .infinity)
                    }
                }
            }
        }
    }
}
