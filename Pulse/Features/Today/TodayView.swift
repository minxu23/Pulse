import SwiftUI
import SwiftData
import Charts

enum TodaySheet: Identifiable {
    case checkIn, earlyStart, evening, adjust, log(QuickLogKind), workout(UUID?)
    var id: String {
        switch self {
        case .checkIn: "checkIn"
        case .earlyStart: "earlyStart"
        case .evening: "evening"
        case .adjust: "adjust"
        case .log(let k): "log-\(k.rawValue)"
        case .workout(let id): "workout-\(id?.uuidString ?? "")"
        }
    }
}

extension DayPhase {
    var color: Color {
        switch self {
        case .morning: Theme.sleep        // 夜间睡眠与恢复
        case .exercise: Theme.activity    // 活动
        case .nutrition: Theme.nutrition  // 营养
        case .evening: Theme.mind         // 放松与睡前
        case .review: .purple
        }
    }
}

/// 首页：
/// 1. 今日状态：身体准备度与静息心率两个关键数字，加一行今日建议（运动 / 负荷 / 恢复）；
/// 2. 现在：当前时段最该做的一件事，一个直接操作；
/// 3. 全天安排：从起床到入睡的阶段入口，每个入口显示关键数字。
struct TodayView: View {
    @Binding var tab: AppTab
    @Environment(\.modelContext) private var ctx
    @State private var sheet: TodaySheet?
    /// The user's card order and the cards ever laid out (see `HomeLayout`).
    @AppStorage(HomeLayout.orderKey) private var order = ""
    @AppStorage(HomeLayout.seenKey) private var seen = ""
    @State private var editing = false
    @State private var draft: [HomeCard] = []

    var body: some View {
        TodayDataReader { d in
            let available = HomeLayout.available(d.profile)
            let cards = HomeLayout.visible(order: order, seen: seen, available: available)
            NavigationStack {
                Group {
                    if editing {
                        HomeEditor(cards: $draft, available: available, onDone: {
                            save(draft, available)
                            withAnimation { editing = false }
                        })
                    } else {
                        ScreenScroll {
                            header(d)
                            // Health alerts are not a card: they always stay on top.
                            if !d.activeEvents.isEmpty { EventsBanner(events: d.activeEvents) }
                            if DayClock.canUndoEarlyStart(d.now, d.p), let s = DayClock.earlyStart { EarlyStartUndoRow(start: s) }
                            ForEach(HomeLayout.rows(cards), id: \.self) { row in
                                if row[0].isTile {
                                    HStack(alignment: .top, spacing: 12) {
                                        ForEach(row) { c in
                                            TodayModuleCard(data: d, card: c, onRemove: { save(cards.filter { $0 != c }, available) },
                                                            onEdit: { edit(cards) })
                                        }
                                        if row.count == 1 { Color.clear.frame(maxWidth: .infinity, maxHeight: 1) }
                                    }
                                } else {
                                    card(row[0], d)
                                        .contextMenu {
                                            Button("从首页移除", systemImage: "minus.circle", role: .destructive) {
                                                save(cards.filter { $0 != row[0] }, available)
                                            }
                                            Button("编辑首页", systemImage: "square.grid.2x2") { edit(cards) }
                                        }
                                }
                            }
                            Button { edit(cards) } label: { Label("编辑首页", systemImage: "square.grid.2x2") }
                                .buttonStyle(.bordered)
                                .font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity)
                            Disclaimer()
                        }
                    }
                }
                .navigationTitle("今日")
                .toolbar(editing ? .visible : .hidden, for: .navigationBar)
                .todaySheets($sheet, d)
                .task { _ = DataHub.record(for: d.day, in: ctx) }
            }
        }
    }

    @ViewBuilder private func card(_ c: HomeCard, _ d: TodayData) -> some View {
        switch c {
        case .state: StateCard(data: d, onHeart: { tab = .heart })
        case .now: NowCard(data: d, sheet: $sheet, tab: $tab)
        case .glucose, .bloodPressure, .race: TodayModuleCard(data: d, card: c, onEdit: { edit(HomeLayout.visible(order: order, seen: seen, available: HomeLayout.available(d.profile))) })
        case .phases:
            VStack(alignment: .leading, spacing: 12) {
                SectionTitle(title: "全天安排", subtitle: "起床 → 入睡")
                PhaseGrid(data: d, tab: $tab, sheet: $sheet)
            }
        case .week: WeekProgressCard(data: d)
        }
    }

    private func edit(_ cards: [HomeCard]) {
        draft = cards
        withAnimation { editing = true }
    }

    /// Keeps the order, and marks every card offered now as laid out, so a removed one stays removed.
    private func save(_ cards: [HomeCard], _ available: [HomeCard]) {
        order = HomeLayout.encode(cards)
        let known = Set(seen.split(separator: ",").map(String.init)).union(available.map(\.rawValue))
        seen = known.sorted().joined(separator: ",")
    }

    private func header(_ d: TodayData) -> some View {
        let cgm = d.recentVitals.filter { $0.kind == .glucose && $0.time > d.now.addingTimeInterval(-24 * 3600) }.count >= 48
        let source: String = d.profile?.useHealthKit == true ? "手表已连接"
            : (d.profile?.usesDemoData == true ? (DemoClock.isShifted ? "示例数据 · 演示 \(Clock.text(d.now.minutesOfDay))" : "示例数据") : "手动记录")
        return HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(d.day.formatted(.dateTime.month().day().weekday(.wide)))\(d.window.kind.map { " · \($0.label)" } ?? "")\(DayClock.startedEarly(d.now, d.p) ? DayClock.earlyStart.map { " · \(Clock.text($0.minutesOfDay)) 开始" } ?? "" : "") · \(source)\(cgm ? " · CGM" : "")")
                    .font(.footnote).foregroundStyle(.secondary)
                Text("\(greeting(d))，\(d.profile?.displayName ?? "你")").font(.title2.bold())
            }
            Spacer()
            Menu {
                ForEach(QuickLogKind.allCases) { k in
                    Button { sheet = k == .workout ? .workout(nil) : .log(k) } label: { Label(k.label, systemImage: k.icon) }
                }
            } label: {
                Image(systemName: "plus").font(.body.weight(.semibold)).foregroundStyle(.primary)
                    .frame(width: 44, height: 44).background(Theme.card, in: Circle())
            }
            .accessibilityLabel("快速记录")
        }
        .padding(.horizontal, 4)
        .padding(.top, 8)
    }

    private func greeting(_ d: TodayData) -> String {
        let now = d.now
        // On a roster the greeting follows the waking day, not the clock.
        if DayClock.startedEarly(now, d.p) || (d.window.kind != nil && d.phase == .morning) { return d.window.kind == .night ? "你好" : "早上好" }
        return switch now.hour {
        case 5..<11: "早上好"
        case 11..<14: "中午好"
        case 14..<18: "下午好"
        default: "晚上好"
        }
    }
}

// MARK: - 今日状态：两个关键数字 + 今日建议

struct StateCard: View {
    let data: TodayData
    var onHeart: () -> Void

    var body: some View {
        let r = data.readiness
        let color = Theme.readiness(r.score == nil ? nil : r.level)
        let t = data.analytics.trend
        let rhr = t.avg7 ?? t.latest?.value
        let delta = rhr.flatMap { v in t.baseline.map { v - $0 } }
        let series = t.rolling7.filter { $0.day > data.now.adding(days: -42) }

        // After bedtime (and until 5 am) the morning's score no longer says what to do; the next one comes after sleep.
        let night = data.phase == .review
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 0) {
                if night {
                    let left = max(0, Int(data.window.nextWake.timeIntervalSince(data.now) / 60) - 15)
                    metric(label: "明天的身体准备度", value: "—", unit: "睡醒后评估",
                           footnote: "今晚还能睡约 \((Double(left) / 60).oneDecimal) 小时") {
                        ProgressBar(value: 0, color: .gray, height: 5)
                    }
                } else {
                    NavigationLink { ReadinessDetailView(result: r, analytics: data.analytics) } label: {
                        metric(label: "身体准备度",
                               value: r.score.map(String.init) ?? "—", unit: r.score == nil ? "待评估" : r.level.label, unitDot: r.score == nil ? nil : color,
                               footnote: r.score == nil ? "记录醒后感受后评估" : "\(r.confidence.label)") {
                            ProgressBar(value: Double(r.score ?? 0) / 100, color: color, height: 5)
                        }
                    }
                    .buttonStyle(.plain)
                }

                Rectangle().fill(Color(.separator)).frame(width: 0.5).padding(.horizontal, 16)

                Button(action: onHeart) {
                    metric(label: "静息心率 · 7 日均值",
                           value: rhr.map { $0.noDecimal } ?? "—", unit: "bpm",
                           footnote: footnote(delta, t)) {
                        if series.count >= 5 { sparkline(series) } else { Color.clear.frame(height: 5) }
                    }
                }
                .buttonStyle(.plain)
            }

            Divider()

            HStack(alignment: .top, spacing: 0) {
                advice("运动", night ? "明天看准备度" : data.guidance.exerciseShort)
                advice("负荷", night ? "不再加练" : data.guidance.loadShort)
                advice("恢复", night ? "现在去睡" : data.guidance.recoveryShort)
            }
        }
        .padding(18)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private func metric<Visual: View>(label: String, value: String, unit: String, unitDot: Color? = nil, footnote: String,
                                      @ViewBuilder visual: () -> Visual) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(value).font(.system(.largeTitle, design: .rounded).weight(.bold)).monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.6)
                if let dot = unitDot {
                    StatusLabel(text: unit, icon: "circle.fill", color: dot)
                        .font(.subheadline.weight(.semibold)).lineLimit(1)
                        .imageScale(.small)
                } else {
                    Text(unit).font(.subheadline.weight(.semibold)).lineLimit(1)
                }
            }
            visual().frame(height: 22, alignment: .center)
            Text(footnote).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private func sparkline(_ series: [RHRPoint]) -> some View {
        let lo = (series.map(\.value).min() ?? 60) - 0.5, hi = (series.map(\.value).max() ?? 75) + 0.5
        return Chart(series) { p in
            LineMark(x: .value("日", p.day), y: .value("bpm", p.value))
                .foregroundStyle(Theme.heartData)
                .lineStyle(StrokeStyle(lineWidth: 1.8, lineCap: .round))
                .interpolationMethod(.catmullRom)
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartYScale(domain: lo...hi)
    }

    private func footnote(_ delta: Double?, _ t: RHRTrend) -> String {
        var parts: [String] = []
        if let d = delta { parts.append("较基线 \(d.signedText)") } else { parts.append("建立基线 \(t.points.count)/14") }
        if let target = data.profile?.targetRHR { parts.append("目标 \(target.noDecimal)") }
        return parts.joined(separator: " · ")
    }

    private func advice(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.subheadline.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - 现在：当前时段最该做的一件事

struct NowCard: View {
    let data: TodayData
    @Binding var sheet: TodaySheet?
    @Binding var tab: AppTab
    @Environment(\.modelContext) private var ctx

    private struct Content {
        var title: String
        var detail: String
        var icon: String
        var progress: Double?
        var action: (label: String, run: () -> Void)?
        var done: String?
        /// Today's weather for this session, on its own line.
        var weather: WeatherReminder?
    }

    private var phase: DayPhase {
        if data.phase == .morning { return data.record?.hasCheckIn == true ? .exercise : .morning }
        return data.phase == .nutrition ? .exercise : data.phase
    }

    var body: some View {
        let ph = phase
        VStack(spacing: 0) {
            main(ph)
            // From 3 am someone who is up for the day can start it early; quiet so it never nudges anyone awake.
            if ph == .review && DayClock.canStartEarly(data.now, data.p) {
                Divider().padding(.top, 12)
                HStack {
                    Text("已经起床了？").font(.subheadline).foregroundStyle(.secondary)
                    Spacer()
                    Button("开始今天") { sheet = .earlyStart }
                        .buttonStyle(.bordered).tint(Theme.accent)
                }
                .padding(.top, 8)
            }
        }
        .padding(16)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private func main(_ ph: DayPhase) -> some View {
        let c = content(ph)
        return HStack(alignment: .center, spacing: 14) {
            NavigationLink { TodayPhaseView(phase: ph, tab: $tab) } label: {
                HStack(alignment: .center, spacing: 14) {
                    Image(systemName: c.icon)
                        .font(.title3.weight(.semibold)).foregroundStyle(.white)
                        .frame(width: 46, height: 46)
                        .background(ph.color, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    VStack(alignment: .leading, spacing: 3) {
                        Text("现在 · \(ph.title)").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Text(c.title).font(.headline).lineLimit(1)
                        Text(c.detail).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                        if let w = c.weather {
                            StatusLabel(text: w.short, icon: w.icon, color: .orange, secondaryText: true)
                                .font(.footnote).lineLimit(1).symbolRenderingMode(.multicolor)
                        }
                        if let p = c.progress { ProgressBar(value: p, color: ph.color, height: 4).padding(.top, 3) }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if let done = c.done {
                Label(done, systemImage: "checkmark.circle.fill").labelStyle(.iconOnly)
                    .font(.title2).foregroundStyle(.green).accessibilityLabel(done)
            } else if let a = c.action {
                Button(action: a.run) {
                    Text(a.label).font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 16).frame(minHeight: 44)
                        .background(Theme.accent, in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func content(_ ph: DayPhase) -> Content {
        switch ph {
        case .morning:
            return Content(title: "记录醒后感受", detail: "约 20 秒，用于评估今天的身体准备度", icon: "sun.horizon.fill",
                           action: ("开始", { sheet = .checkIn }))
        case .evening:
            let target = data.record?.plannedBedtime?.minutesOfDay ?? data.window.bed.minutesOfDay
            let left = (target - data.now.minutesOfDay + 1440) % 1440
            let done = data.record?.hasEveningCheckIn == true
            return Content(title: "\(Clock.text(target)) 前上床",
                           detail: left < 600 ? "还有 \(left / 60) 小时 \(left % 60) 分钟 · 记录疲劳、压力与睡眠安排" : "记录疲劳、压力与睡眠安排",
                           icon: "moon.zzz.fill", action: done ? nil : ("睡前记录", { sheet = .evening }), done: done ? "已记录" : nil)
        case .review:
            let done = data.record?.reviewedAt != nil
            // Well past bedtime (or after midnight) sleep comes first; the review can wait until tomorrow.
            let late = data.now >= data.window.bed.addingTimeInterval(30 * 60)
            return Content(title: "全天回顾",
                           detail: late ? "已过入睡时间，先去睡，回顾明天再看"
                               : (data.summary.arrangements.first ?? "汇总全天，安排恢复"),
                           icon: "text.book.closed.fill", done: done ? "已回顾" : nil)
        default:
            if let item = data.trainings.first(where: { $0.status == .planned }) ?? data.trainings.first {
                let finished = item.status != .planned
                return Content(title: item.title,
                               detail: "\(item.minutes) 分钟 · \(item.intensity.label)\(item.wasAdjusted ? " · 已按状态调整" : "")",
                               icon: item.kind.icon,
                               action: finished ? nil : ("完成", {
                                   PlanActions.setStatus(item, .done, useHealthKit: data.profile?.useHealthKit ?? false, in: ctx)
                               }),
                               done: finished ? item.status.label : nil,
                               weather: finished ? nil : data.weatherReminder)
            }
            let v = data.vitality
            let zh = Locale(identifier: "zh_CN")
            return Content(title: data.todayItems.first?.title ?? "恢复日",
                           detail: "\(v.steps.formatted(.number.locale(zh))) / \(v.stepsTarget.formatted(.number.locale(zh))) 步 · 活动 \(Int(v.activeMinutes)) 分钟",
                           icon: "figure.walk", progress: Double(v.steps) / Double(max(1, v.stepsTarget)),
                           action: ("记录", { sheet = .workout(nil) }))
        }
    }
}

// MARK: - 全天安排：阶段入口

struct PhaseTileInfo {
    enum State { case done, current, pending }
    let phase: DayPhase
    let metric: String
    let unit: String
    let caption: String
    let state: State
    let flag: String?
    /// The badge's glyph (a weather symbol for a weather reminder).
    var flagIcon: String? = nil

    static func make(_ ph: DayPhase, _ data: TodayData) -> PhaseTileInfo {
        let d = data.analytics.today
        let p = data.p
        let current = ph == data.phase
        func state(_ done: Bool) -> State { done ? .done : (current ? .current : .pending) }
        switch ph {
        case .morning:
            let bp = OvernightAnalyzer.bloodPressure(data.recentVitals, morningOf: data.day, profile: p)
            let g = OvernightAnalyzer.glucose(data.recentVitals, window: OvernightAnalyzer.nightWindow(for: data.day, today: d), profile: p)
            let br = OvernightAnalyzer.breathing(today: d, history: data.analytics.history, profile: p)
            var parts: [String] = []
            if let m = bp.morning { parts.append("血压 \(Int(m.value))/\(Int(m.value2 ?? 0))") }
            if g.isContinuous { parts.append(g.lowAlert ? "夜间低血糖" : "血糖 \(g.min!.oneDecimal)–\(g.max!.oneDecimal)") }
            else if let f = g.fasting { parts.append("空腹 \(f.value.oneDecimal)") }
            let flag = g.lowAlert ? "血糖" : (bp.needsAttention ? "血压" : (br.needsAttention ? "呼吸" : nil))
            return PhaseTileInfo(phase: ph, metric: d?.sleepMinutes.map { ($0 / 60).oneDecimal } ?? "—", unit: "小时睡眠",
                                 caption: parts.isEmpty ? "夜间血压、血糖与呼吸" : parts.joined(separator: " · "),
                                 state: state(data.record?.hasCheckIn == true), flag: flag)
        case .exercise:
            let v = data.vitality
            if let main = data.trainings.first {
                let status = main.status == .planned ? (main.wasAdjusted ? "已调整" : "待完成") : main.status.label
                // Today's weather for the outdoor session still to do.
                let w = data.weatherReminder
                return PhaseTileInfo(phase: ph, metric: "\(main.minutes)", unit: "分钟", caption: w?.short ?? "\(main.title) · \(status)",
                                     state: state(data.trainings.allSatisfy { $0.status != .planned }), flag: w?.badge, flagIcon: w?.icon)
            }
            return PhaseTileInfo(phase: ph, metric: v.steps.formatted(.number.locale(Locale(identifier: "zh_CN"))), unit: "步", caption: "活力度 \(v.score) · 活动 \(Int(v.activeMinutes)) 分钟",
                                 state: state(v.score >= 80), flag: nil)
        case .nutrition:
            var parts: [String] = ["\(data.todayMeals.count) 餐"]
            let bp = data.todayVitals.filter { $0.kind == .bloodPressure }.count
            if bp > 0 { parts.append("血压 \(bp) 次") }
            let g = data.todayVitals.filter { $0.kind == .glucose }
            if g.count >= 24 { parts.append("血糖 \(Stats.mean(g.map(\.value))!.oneDecimal)") } else if let last = g.last { parts.append("血糖 \(last.value.oneDecimal)") }
            let due = data.openTasks.contains { ($0.due ?? .distantFuture) < data.now.adding(days: 1) }
            return PhaseTileInfo(phase: ph, metric: "\(data.record?.waterMl ?? 0)", unit: "ml 饮水", caption: parts.joined(separator: " · "),
                                 state: state(false), flag: due ? "照护" : nil)
        case .evening:
            let r = data.record
            let bed = r?.plannedBedtime?.minutesOfDay ?? data.window.bed.minutesOfDay
            var caption = "疲劳、酸痛、压力、咖啡因"
            if let r, r.hasEveningCheckIn {
                caption = [r.eveningFatigue.map { "疲劳 \($0)/5" }, r.eveningStress.map { "压力 \($0)/5" }].compactMap { $0 }.joined(separator: " · ")
            }
            return PhaseTileInfo(phase: ph, metric: Clock.text(bed), unit: "上床", caption: caption,
                                 state: state(r?.hasEveningCheckIn == true), flag: nil)
        case .review:
            let reviewed = data.record?.reviewedAt != nil
            return PhaseTileInfo(phase: ph, metric: reviewed ? "已完成" : "待回顾", unit: "",
                                 caption: reviewed ? (data.summary.arrangements.first ?? "") : "汇总全天，安排恢复",
                                 state: state(reviewed), flag: nil)
        }
    }
}

struct PhaseGrid: View {
    let data: TodayData
    @Binding var tab: AppTab
    @Binding var sheet: TodaySheet?

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
            ForEach(DayPhase.allCases) { ph in
                NavigationLink { TodayPhaseView(phase: ph, tab: $tab) } label: {
                    PhaseTile(info: PhaseTileInfo.make(ph, data))
                }
                .buttonStyle(.plain)
            }
            Menu {
                ForEach(QuickLogKind.allCases) { k in
                    Button { sheet = k == .workout ? .workout(nil) : .log(k) } label: { Label(k.label, systemImage: k.icon) }
                }
            } label: {
                QuickLogTile()
            }
            .buttonStyle(.plain)
        }
    }
}

struct PhaseTile: View {
    let info: PhaseTileInfo

    var body: some View {
        let color = info.phase.color
        let current = info.state == .current
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                Image(systemName: info.phase.icon)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(color.gradient, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                Spacer()
                badge
            }
            Spacer(minLength: 10)
            Text(info.phase.title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(info.metric).font(.system(.title2, design: .rounded).weight(.bold)).monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.7)
                if !info.unit.isEmpty { Text(info.unit).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
            .padding(.top, 2)
            Text(info.caption).font(.caption).foregroundStyle(.secondary).lineLimit(1).padding(.top, 2)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 156, alignment: .topLeading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(current ? color : .clear, lineWidth: 1.5))
    }

    @ViewBuilder
    private var badge: some View {
        if let flag = info.flag {
            StatusLabel(text: flag, icon: info.flagIcon ?? "exclamationmark.circle.fill", color: .orange).font(.caption.weight(.semibold))
        } else if info.state == .done {
            Image(systemName: "checkmark.circle.fill").font(.title3).foregroundStyle(.green)
        } else if info.state == .current {
            StatusLabel(text: "现在", icon: "circle.fill", color: info.phase.color)
                .font(.caption.weight(.semibold)).imageScale(.small)
                .padding(.horizontal, 8).padding(.vertical, 4).background(Theme.subtle, in: Capsule())
        }
    }
}

struct QuickLogTile: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Image(systemName: "plus")
                .font(.headline).foregroundStyle(Theme.accent)
                .frame(width: 40, height: 40)
                .background(Theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            Spacer(minLength: 10)
            Text("快速记录").font(.subheadline.weight(.semibold))
            HStack(spacing: 10) {
                ForEach(["fork.knife", "drop", "gauge.with.dots.needle.33percent", "drop.fill", "figure.run"], id: \.self) {
                    Image(systemName: $0).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            .padding(.top, 8)
            Text("饮食 · 饮水 · 指标 · 运动").font(.caption).foregroundStyle(.secondary).padding(.top, 6)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 156, alignment: .topLeading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Theme.accent.opacity(0.25), style: StrokeStyle(lineWidth: 1.2, dash: [5, 4])))
    }
}

// MARK: - Phase detail pages

struct TodayPhaseView: View {
    let phase: DayPhase
    @Binding var tab: AppTab
    @State private var sheet: TodaySheet?

    var body: some View {
        TodayDataReader { d in
            ScreenScroll {
                switch phase {
                case .morning:
                    MorningAssessmentView(data: d, onCheckIn: { sheet = .checkIn }, onLog: { sheet = .log($0) },
                                          onStartEarly: { sheet = .earlyStart })
                case .exercise:
                    ExerciseDayView(data: d, sheet: $sheet)
                case .nutrition:
                    NutritionDayView(data: d, sheet: $sheet)
                case .evening:
                    EveningDayView(data: d, sheet: $sheet)
                case .review:
                    if let r = d.record {
                        DayReviewView(record: r, summary: d.summary, onReview: { tab = .review })
                    }
                }
            }
            .navigationTitle(phase.title).calmStyle()
            .navigationBarTitleDisplayMode(.inline)
            .todaySheets($sheet, d)
        }
    }
}
