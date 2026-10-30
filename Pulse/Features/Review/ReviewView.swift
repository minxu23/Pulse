import SwiftUI
import SwiftData
import Charts

/// 复盘 (需求 9), AI-native: the Health Agent writes the conclusion first, then the page shows the
/// numbers behind it, proposes changes that can be adopted with one tap and guides the weekly
/// reflection. Pages stay calm: white cards, colour only on data glyphs and status, one question
/// bar at the bottom of the tab instead of ask buttons on every card.
struct ReviewView: View {
    enum Segment: String, CaseIterable, Identifiable {
        case day = "每日回顾", week = "本周复盘", longTerm = "长期复盘"
        var id: String { rawValue }
    }
    struct AgentRequest: Identifiable {
        let id = UUID()
        let question: String?
        let voice: Bool
    }
    @State private var segment: Segment = DebugLaunch.value("-PulseSegment") == "long" ? .longTerm
        : (DebugLaunch.value("-PulseSegment") == "day" ? .day : .week)
    @State private var agent: AgentRequest?

    var body: some View {
        NavigationStack {
            AgentContextReader { ctx in
                ScreenScroll {
                    switch segment {
                    case .day: DailyReviewSection(context: ctx, onAsk: ask)
                    case .week: WeeklyReviewSection(context: ctx, onAsk: ask)
                    case .longTerm: LongTermReviewSection(context: ctx, onAsk: ask)
                    }
                    Disclaimer(text: AgentNameSettings.shared.phrase("复盘中的关联来自你的记录，可能受其他因素影响；只有经过个人验证或专业确认的才标记为「已确认」。", "不做诊断。"))
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                Picker("复盘范围", selection: $segment) { ForEach(Segment.allCases) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, Theme.Space.gutter)
                    .padding(.bottom, Theme.Space.item)
                    .background(.bar)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                // The whole Health Agent, not a question box for this page: it explains, answers and changes plans.
                AskAgentBar(placeholder: "有什么想问、想调整的？", onAsk: ask)
            }
            .navigationTitle("复盘")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(item: $agent) { r in HealthAgentChatView(initialQuestion: r.question, startListening: r.voice) }
        }
    }

    private func ask(_ question: String?, _ voice: Bool) {
        agent = AgentRequest(question: question, voice: voice)
    }
}

// MARK: - Shared pieces

/// Persistent entry point to the agent: tap to type, or the microphone to speak.
struct AskAgentBar: View {
    let placeholder: String
    var onAsk: (String?, Bool) -> Void
    /// The avatar with an item's space around it, so it sits concentric in the capsule's round end.
    private let barHeight = Theme.Size.iconTile + 2 * Theme.Space.item

    var body: some View {
        HStack(spacing: Theme.Space.item) {
            Button { onAsk(nil, false) } label: {
                HStack(spacing: Theme.Space.block) {
                    AgentAvatar(size: Theme.Size.iconTile)
                    Text(placeholder).font(.body).foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.leading, Theme.Space.item).padding(.trailing, Theme.Space.block)
                .frame(minHeight: barHeight)
                .background(Theme.card, in: Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(AgentNameSettings.shared.phrase("问问"))
            Button { onAsk(nil, true) } label: {
                Image(systemName: "mic.fill").font(.body.weight(.semibold)).foregroundStyle(Theme.accent)
                    .frame(width: barHeight, height: barHeight)
                    .background(Theme.card, in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("语音提问")
        }
        .padding(.horizontal, Theme.Space.gutter)
        .padding(.top, Theme.Space.block)
        .padding(.bottom, Theme.Space.item)
        .background(LinearGradient(stops: [.init(color: Theme.page.opacity(0), location: 0), .init(color: Theme.page, location: 0.35)],
                                   startPoint: .top, endPoint: .bottom))
    }
}

/// Who wrote a review card: the language model (with its name), or the rules text and why.
struct ReviewByline: View {
    let state: ReviewWriter.State?
    var onRetry: () -> Void

    var body: some View {
        HStack(spacing: Theme.Space.iconGap) {
            switch state {
            case .written(_, let by)?:
                Image(systemName: "sparkles").imageScale(.small).foregroundStyle(.secondary).accessibilityHidden(true)
                Text(by).foregroundStyle(.secondary)
                Spacer(minLength: Theme.Space.item)
                retry("重写")
            case .rules(let reason)?:
                Image(systemName: "doc.text").imageScale(.small).foregroundStyle(.secondary).accessibilityHidden(true)
                Text(reason).foregroundStyle(.secondary)
                Spacer(minLength: Theme.Space.item)
                retry("重试")
            default:
                ProgressView().controlSize(.small)
                Text(AgentNameSettings.shared.phrase("", "正在根据你的记录撰写…")).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
        }
        .font(.footnote)
        // As tall as the retry button in every state, so the card does not jump when the text is written.
        .frame(minHeight: Theme.Size.tap)
    }

    private func retry(_ title: String) -> some View {
        Button(action: onRetry) { textLink(title, minWidth: Theme.Size.tap) }
            .buttonStyle(.borderless)
            .font(.footnote.weight(.semibold))
    }
}

/// The Health Agent's conclusion at the top of a review page: one headline, a short summary and
/// who wrote it. Until the model has written it, the rules text shows faded.
struct ReviewSummaryCard: View {
    let eyebrow: String
    var glyph: (icon: String, color: Color)? = nil
    let headline: String
    let summary: String
    let byline: ReviewWriter.State?
    var onRetry: () -> Void

    var body: some View {
        let writing = byline == nil || byline == .writing
        VStack(alignment: .leading, spacing: Theme.Space.item) {
            Text(eyebrow).font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: Theme.Space.item) {
                HStack(alignment: .firstTextBaseline, spacing: Theme.Space.iconGap) {
                    if let glyph {
                        Image(systemName: glyph.icon).font(.title3.weight(.semibold)).imageScale(.small)
                            .foregroundStyle(glyph.color).accessibilityHidden(true)
                    }
                    Text(headline).font(.title3.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                }
                if !summary.isEmpty {
                    Text(summary).font(.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .opacity(writing ? 0.4 : 1)
            .animation(.easeInOut(duration: 0.3), value: writing)
            .accessibilityElement(children: .combine)
            Divider().padding(.top, Theme.Space.tight)
            // The retry button's 44 pt target reaches into the card's bottom padding.
            ReviewByline(state: byline, onRetry: onRetry).padding(.bottom, -10)
        }
        .cardSurface()
    }
}

/// Remembers which proposals were adopted or dismissed for a week (kept on this device).
enum CoachLedger {
    private static let key = "coach.handled"
    static func state(_ id: String, week: Date) -> String? {
        (UserDefaults.standard.dictionary(forKey: key) as? [String: String])?["\(Int(week.timeIntervalSince1970))|\(id)"]
    }
    static func set(_ id: String, week: Date, _ value: String) {
        var d = (UserDefaults.standard.dictionary(forKey: key) as? [String: String]) ?? [:]
        d["\(Int(week.timeIntervalSince1970))|\(id)"] = value
        UserDefaults.standard.set(d, forKey: key)
    }
}

/// Label of a text-only (borderless) action: the whole row height is its tap target.
private func textLink(_ title: String, minWidth: CGFloat? = nil) -> some View {
    Text(title).frame(minWidth: minWidth, minHeight: Theme.Size.tap).contentShape(Rectangle())
}

/// Category colour for a data glyph (Apple Health conventions).
private func dataColor(_ icon: String) -> Color {
    switch icon {
    case "heart.fill", "lungs.fill": Theme.heartData
    case "bed.double.fill": Theme.sleep
    case "figure.walk", "checklist": Theme.activity
    case "bolt.fill": Theme.mind
    case "wineglass": Theme.nutrition
    default: .secondary
    }
}

// MARK: - 本周复盘

struct WeeklyReviewSection: View {
    let context: AgentContext
    var onAsk: (String?, Bool) -> Void
    @Environment(\.modelContext) private var ctx
    @Query private var profiles: [UserProfile]
    @Query(sort: \ReviewEntry.createdAt, order: .reverse) private var entries: [ReviewEntry]
    @Query private var insights: [InsightRecord]
    @Query(sort: \CareTask.createdAt, order: .reverse) private var tasks: [CareTask]
    @State private var weekOffset = 0
    @State private var adopted: [CoachProposal] = []
    @State private var ledgerTick = 0

    var body: some View {
        // Same day rule as the agent: until 5 am the user is still in the previous day (and week).
        let today = context.logicalToday
        let ws = context.weekStart.adding(days: -7 * weekOffset)
        let current = weekOffset == 0
        let span = current ? today.daysSince(ws) + 1 : 7
        let src = context.trend.dominantSource
        let cur = ReviewCoach.week(days: context.days, plan: context.plan, weekStart: ws, span: span, source: src, now: today)
        let prev = ReviewCoach.week(days: context.days, plan: context.plan, weekStart: ws.adding(days: -7), span: span, source: src, now: today)
        let next = PlanGenerator.nextWeeklyTarget(current: context.profile.weeklyTargetMinutes, lastWeekCompletion: cur.completion, profile: context.profile)
        // What the user cares about most leads: numbers, suggestions, the story and the reflection.
        let priorities = ReviewPriorities.ranked(context, mine: profiles.first?.reviewPriorities ?? [])
        let brief = ReviewCoach.brief(current: cur, previous: prev, context: context, isCurrentWeek: current, nextTarget: next, priorities: priorities)
        let _ = ledgerTick
        let proposals = current ? ReviewCoach.proposals(context: context,
                                                        handledInsights: Set(insights.filter { $0.status != .observed }.map(\.key)),
                                                        taskTitles: tasks.filter { !$0.done }.map(\.title), priorities: priorities)
            .filter { CoachLedger.state($0.id, week: ws) == nil } : []

        let saved = entries.first { $0.periodStart == ws }
        let plan = current ? ReviewCoach.nextWeekPlan(context: context, week: cur,
                                                      notes: saved.map { ReviewNotes(keep: $0.keep, change: $0.change, focus: $0.nextFocus) }) : nil
        // The rules decide; the language model writes the cards from those facts.
        let facts = ReviewCoach.weeklyFacts(brief: brief, weekLabel: weekLabel(ws, current: current, span: span),
                                            isCurrentWeek: current, proposals: proposals, plan: plan, priorities: priorities)
        let writer = ReviewWriter.shared
        let copy = writer.copy(for: facts)
        let state = writer.state(for: facts)
        let writing = state == nil || state == .writing

        WeekSwitcher(title: weekRange(ws), subtitle: current ? "本周 · 第 \(span) 天" : (weekOffset == 1 ? "上周" : "\(weekOffset) 周前"),
                     canGoForward: weekOffset > 0,
                     onPrev: { weekOffset += 1 }, onNext: { weekOffset = max(0, weekOffset - 1) })

        ReviewSummaryCard(eyebrow: current ? "本周总结" : "这周总结", headline: copy.headline, summary: copy.summary,
                          byline: state, onRetry: { Task { await writer.rewrite(facts) } })
            .task(id: facts.key) { await writer.write(facts) }

        WeekNumbersCard(metrics: brief.metrics)
        if current { PrioritiesCard(context: context) }
        WeekDaysCard(context: context, weekStart: ws)
        if !brief.watch.isEmpty { WatchCard(points: brief.watch) }

        if current {
            SectionTitle(title: "建议调整", subtitle: "采纳后立即生效")
            VStack(spacing: 0) {
                ForEach(adopted) { p in
                    if p.id != adopted.first?.id { Divider().padding(.leading, Theme.Size.iconTile + Theme.Space.block) }
                    StatusLabel(.good("已采纳：\(p.title)")).font(.subheadline)
                        .frame(maxWidth: .infinity, minHeight: Theme.Size.tap, alignment: .leading)
                }
                if proposals.isEmpty && adopted.isEmpty {
                    StatusLabel(.good("这周没有需要调整的地方，按现在的节奏继续。")).font(.subheadline)
                        .frame(maxWidth: .infinity, minHeight: Theme.Size.tap, alignment: .leading)
                }
                ForEach(Array(proposals.enumerated()), id: \.element.id) { i, p in
                    if i > 0 || !adopted.isEmpty { Divider().padding(.leading, Theme.Size.iconTile + Theme.Space.block) }
                    ProposalRow(proposal: p, rationale: copy.items[safe: i], writing: writing,
                                onAdopt: { apply(p, week: ws) },
                                onDismiss: { CoachLedger.set(p.id, week: ws, "dismissed"); ledgerTick += 1 })
                }
            }
            // The rows' own padding takes the place of the card's, so a row's text sits a card padding in.
            .padding(.vertical, -Theme.Space.item)
            .cardSurface()
        }

        SectionTitle(title: "一起复盘", subtitle: saved == nil ? "3 个问题，约 1 分钟" : nil)
        if let saved {
            SavedReviewCard(entry: saved, onRedo: { ctx.delete(saved) })
        } else {
            GuidedReflectionCard(steps: ReviewCoach.reflection(context: context, week: cur, priorities: priorities), brief: brief) { draft in
                let e = ReviewEntry(periodStart: ws, periodEnd: ws.adding(days: 6))
                e.summary = draft.summary; e.keep = draft.keep; e.change = draft.change; e.nextFocus = draft.focus
                e.rhrAverage = cur.rhr; e.planCompletion = cur.completion
                ctx.insert(e)
            }
        }

        if let plan {
            let told = NextWeekPlan(weekStart: plan.weekStart, targetMinutes: plan.targetMinutes, targetReason: plan.targetReason,
                                    changes: plan.changes.enumerated().map { j, c in
                                        AgentPoint(icon: c.icon, title: c.title, detail: copy.items[safe: proposals.count + j] ?? c.detail,
                                                   destination: c.destination)
                                    },
                                    sessions: plan.sessions, basis: plan.basis)
            SectionTitle(title: "下周计划", subtitle: "\(plan.weekStart.formatted(.dateTime.month().day())) 起")
            NextWeekPlanCard(plan: told, currentTarget: context.profile.weeklyTargetMinutes,
                             applied: profiles.first?.nextWeekPlannedFor == plan.weekStart,
                             reviewed: saved != nil, onApply: {
                                 DataHub.applyNextWeekPlan(plan, in: ctx)
                                 ledgerTick += 1
                             })
        }

        let past = entries.filter { $0.periodStart < ws }
        if !past.isEmpty {
            // Past weeks are a group of their own, after this week's.
            PastReviewsCard(entries: Array(past.prefix(3)))
                .padding(.top, Theme.Space.section - Theme.Space.cardGap)
        }
    }

    private func weekRange(_ ws: Date) -> String {
        let end = ws.adding(days: 6)
        let sameMonth = Calendar.pulse.component(.month, from: ws) == Calendar.pulse.component(.month, from: end)
        return "\(ws.formatted(.dateTime.month().day()))–\(sameMonth ? "\(Calendar.pulse.component(.day, from: end))日" : end.formatted(.dateTime.month().day()))"
    }

    /// The week as the model is told it (part of the facts, so it stays stable).
    private func weekLabel(_ ws: Date, current: Bool, span: Int) -> String {
        current ? "\(weekRange(ws)) · 第 \(span) 天" : weekRange(ws)
    }

    /// Applies an adopted proposal to the user's settings, plan or care list.
    private func apply(_ p: CoachProposal, week: Date) {
        guard let profile = profiles.first else { return }
        switch p.action {
        case .dropWeekday(let wd):
            profile.availableWeekdays.removeAll { $0 == wd }
            DataHub.regenerateWeekPlan(in: ctx)
        case .startExperiment(let key, let note):
            let r = insights.first { $0.key == key } ?? {
                let n = InsightRecord(key: key, status: .testing)
                ctx.insert(n)
                return n
            }()
            r.status = .testing
            r.experimentStart = .app.startOfDay
            r.experimentEnd = .app.startOfDay.adding(days: 14)
            r.note = note
        case .setBedtime(let m):
            profile.bedtimeMinutes = m
        case .setStepsTarget(let n):
            profile.stepsTarget = n
        case .addTask(let title, let area, let days):
            ctx.insert(CareTask(title: title, area: area, due: .app.adding(days: days)))
        }
        try? ctx.save()
        CoachLedger.set(p.id, week: week, "adopted")
        withAnimation { adopted.append(p); ledgerTick += 1 }
    }
}

/// Which week is shown, with previous / next.
struct WeekSwitcher: View {
    let title: String
    let subtitle: String
    let canGoForward: Bool
    var onPrev: () -> Void
    var onNext: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onPrev) {
                Image(systemName: "chevron.left").frame(width: Theme.Size.tap, height: Theme.Size.tap).contentShape(Rectangle())
            }
            .accessibilityLabel("上一周")
            Spacer(minLength: Theme.Space.item)
            VStack(spacing: Theme.Space.hairline) {
                Text(title).font(.headline)
                Text(subtitle).font(.footnote).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: Theme.Space.item)
            Button(action: onNext) {
                Image(systemName: "chevron.right").frame(width: Theme.Size.tap, height: Theme.Size.tap).contentShape(Rectangle())
            }
            .disabled(!canGoForward)
            .accessibilityLabel("下一周")
        }
        .font(.body.weight(.semibold))
    }
}

/// The week's key numbers, each against the same days of last week. The arrow shows which way the
/// number moved; its colour and the word next to it say whether that is good.
struct WeekNumbersCard: View {
    let metrics: [BriefMetric]

    var body: some View {
        let rows = stride(from: 0, to: metrics.count, by: 2).map { Array(metrics[$0..<min($0 + 2, metrics.count)]) }
        VStack(alignment: .leading, spacing: Theme.Space.tight) {
            CardTitle("关键数据", detail: "与上周同期比")
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
                    if i > 0 { Divider() }
                    // No tile behind the cells, so the columns sit a block apart.
                    HStack(alignment: .top, spacing: Theme.Space.block) {
                        ForEach(row) { WeekMetricCell(metric: $0) }
                        if row.count == 1 { Color.clear.frame(maxWidth: .infinity, maxHeight: 1) }
                    }
                    .padding(.vertical, Theme.Space.item)
                }
            }
        }
        // The last row's padding stands in for the card's.
        .padding(.bottom, -Theme.Space.item)
        .cardSurface()
    }
}

struct WeekMetricCell: View {
    let metric: BriefMetric

    var body: some View {
        let m = metric
        VStack(alignment: .leading, spacing: Theme.Space.tight) {
            Label {
                Text(m.name).foregroundStyle(.secondary)
            } icon: {
                Image(systemName: m.icon).foregroundStyle(dataColor(m.icon))
            }
            .font(.caption).lineLimit(1)
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.tight) {
                Text(m.value).font(.system(.title2, design: .rounded).weight(.semibold)).monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.7)
                Text(m.unit).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            change.font(.footnote).lineLimit(1).minimumScaleFactor(0.85)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(m.name) \(m.value) \(m.unit)，\(m.delta.map { "与上周同期比 \($0)，\(word)" } ?? "上周无数据")")
    }

    @ViewBuilder private var change: some View {
        if let d = metric.delta, metric.trend == .better || metric.trend == .worse {
            StatusLabel(text: "\(d.trimmingCharacters(in: CharacterSet(charactersIn: "+-"))) · \(word)",
                        icon: d.hasPrefix("-") ? "arrow.down" : "arrow.up",
                        color: metric.trend == .better ? .green : .orange, secondaryText: true)
        } else if metric.delta != nil {
            StatusLabel(text: "持平", icon: "equal", color: .gray, secondaryText: true)
        } else {
            Text("上周无数据").foregroundStyle(.secondary)
        }
    }

    private var word: String {
        switch metric.trend {
        case .better: "改善"
        case .worse: "变差"
        default: "持平"
        }
    }
}

/// Day by day, so each number above can be traced to the days behind it: a small chart row per
/// measure (training status, sleep and activity bars, resting-heart-rate dots) under the chosen day's
/// exact values — today until another day is tapped.
struct WeekDaysCard: View {
    let context: AgentContext
    let weekStart: Date
    @State private var picked: Date?

    private let rowHeight: CGFloat = 28
    private let labelWidth: CGFloat = 52

    var body: some View {
        let today = context.logicalToday
        let days = (0..<7).map { weekStart.adding(days: $0) }
        let shown = picked.flatMap { days.contains($0) ? $0 : nil } ?? (days.contains(today) ? today : days[6])
        let data = Dictionary(context.days.filter { days.contains($0.day) }.map { ($0.day, $0) }, uniquingKeysWith: { a, _ in a })
        let scale = Scale(days: days.filter { $0 <= today }.compactMap { data[$0] })
        VStack(alignment: .leading, spacing: Theme.Space.block) {
            CardTitle("每一天", detail: name(shown, today: today))
            values(shown, today: today, day: data[shown])
            ZStack {
                // The chosen day, behind the rows.
                lane(days) { d in
                    RoundedRectangle(cornerRadius: Theme.Radius.inner, style: .continuous).fill(d == shown ? Theme.subtle : Color.clear)
                }
                VStack(spacing: Theme.Space.item) {
                    row("训练", "checklist", Theme.activity, days) { d in training(d, today: today) }
                    row("睡眠", "bed.double.fill", Theme.sleep, days, bars: true) { d in
                        bar(d > today ? nil : data[d]?.sleepMinutes.map { $0 / 60 }, of: scale.sleepMax, color: Theme.sleep, future: d > today)
                    }
                    row("心率", "heart.fill", Theme.heartData, days) { d in rhrDot(d > today ? nil : data[d]?.rhr, scale: scale, future: d > today) }
                    row("活动", "figure.walk", Theme.activity, days, bars: true) { d in
                        bar(d > today ? nil : data[d].map(\.activeMinutes), of: scale.activeMax, color: Theme.activity, future: d > today)
                    }
                    lane(days) { d in
                        Text(name(d, today: today))
                            .font(.caption.weight(d == shown ? .semibold : .regular))
                            .foregroundStyle(d == shown ? Color.primary : Color.secondary)
                            .lineLimit(1).minimumScaleFactor(0.8)
                    }
                }
                .padding(.vertical, Theme.Space.item)
                .accessibilityHidden(true)
                // Tap a day to see its values.
                lane(days) { d in
                    Button { picked = d } label: { Color.clear.contentShape(Rectangle()) }
                        .buttonStyle(.plain)
                        .accessibilityLabel(name(d, today: today) + "：" + facts(d, today: today, day: data[d]).map { "\($0.0)\($0.1)" }.joined(separator: "，"))
                        .accessibilityAddTraits(d == shown ? .isSelected : [])
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .cardSurface()
    }

    /// The week's ranges, so every bar and dot is drawn on the same scale.
    private struct Scale {
        var sleepMax: Double, activeMax: Double, rhrLow: Double, rhrHigh: Double
        init(days: [DayData]) {
            sleepMax = max(9, days.compactMap(\.sleepMinutes).max().map { $0 / 60 } ?? 0)
            activeMax = max(30, days.map(\.activeMinutes).max() ?? 0)
            let rhr = days.compactMap(\.rhr)
            rhrLow = (rhr.min() ?? 60) - 3
            rhrHigh = (rhr.max() ?? 70) + 3
        }
    }

    private func name(_ d: Date, today: Date) -> String { d == today ? "今天" : Weekday.name(d.weekday) }

    /// Seven day cells after the label column.
    private func lane<Cell: View>(_ days: [Date], @ViewBuilder cell: @escaping (Date) -> Cell) -> some View {
        HStack(spacing: Theme.Space.tight) {
            Color.clear.frame(width: labelWidth)
            ForEach(days, id: \.self) { d in cell(d).frame(maxWidth: .infinity) }
        }
    }

    /// One measure across the week; bars stand on the row's bottom, so their label sits there too.
    private func row<Cell: View>(_ title: String, _ icon: String, _ color: Color, _ days: [Date], bars: Bool = false,
                                 @ViewBuilder cell: @escaping (Date) -> Cell) -> some View {
        ZStack(alignment: bars ? .bottomLeading : .leading) {
            lane(days) { d in cell(d) }
            HStack(spacing: Theme.Space.iconGap) {
                Image(systemName: icon).imageScale(.small).foregroundStyle(color)
                Text(title).foregroundStyle(.secondary).lineLimit(1).fixedSize()
            }
            .font(.footnote)
            .frame(width: labelWidth, alignment: .leading)
        }
        .frame(height: rowHeight)
    }

    /// The day's training status; an empty cell (not no cell) on a day without training keeps the columns aligned.
    @ViewBuilder private func training(_ d: Date, today: Date) -> some View {
        if let s = session(d, today: today) {
            Image(systemName: s.icon).font(.body).foregroundStyle(Theme.planStatus(s))
        } else {
            Color.clear.frame(height: 1)
        }
    }

    /// A bar from the bottom of the row; a faint dot when the day has no record, nothing for days to come.
    private func bar(_ value: Double?, of top: Double, color: Color, future: Bool) -> some View {
        VStack {
            Spacer(minLength: 0)
            if let v = value {
                Capsule().fill(color).frame(width: 12, height: max(3, rowHeight * min(1, v / top)))
            } else if !future {
                Circle().fill(Theme.subtle).frame(width: 5, height: 5)
            }
        }
        .frame(height: rowHeight)
    }

    private func rhrDot(_ value: Double?, scale: Scale, future: Bool) -> some View {
        GeometryReader { g in
            if let v = value {
                let y = (1 - (v - scale.rhrLow) / max(1, scale.rhrHigh - scale.rhrLow)) * (g.size.height - 10) + 5
                Circle().fill(Theme.heartData).frame(width: 9, height: 9).position(x: g.size.width / 2, y: y)
            } else if !future {
                Circle().fill(Theme.subtle).frame(width: 5, height: 5).position(x: g.size.width / 2, y: g.size.height / 2)
            }
        }
        .frame(height: rowHeight)
    }

    /// The chosen day's values as a row of small stats, or what is planned for a day to come.
    @ViewBuilder private func values(_ d: Date, today: Date, day: DayData?) -> some View {
        let items = facts(d, today: today, day: day)
        if d > today {
            Text(items.map { $0.0 + $0.1 }.joined(separator: "；")).font(.subheadline).foregroundStyle(.secondary)
                .frame(minHeight: 40, alignment: .topLeading)
        } else {
            HStack(alignment: .top, spacing: Theme.Space.item) {
                ForEach(items, id: \.0) { label, value in
                    VStack(alignment: .leading, spacing: Theme.Space.hairline) {
                        Text(label).font(.caption).foregroundStyle(.secondary)
                        Text(value).font(.subheadline.weight(.semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.8)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(minHeight: 40, alignment: .topLeading)
        }
    }

    /// (label, value) pairs for a day.
    private func facts(_ d: Date, today: Date, day: DayData?) -> [(String, String)] {
        if d > today {
            let planned = context.plan.filter { $0.day == d && $0.kind.isTraining }
            return planned.isEmpty ? [("没有安排训练", "")] : planned.map { ("计划 ", "\($0.title) \($0.minutes) 分钟") }
        }
        let status = session(d, today: today)?.label ?? "无安排"
        return [("训练", status),
                ("睡眠", day?.sleepMinutes.map { "\(($0 / 60).oneDecimal) 小时" } ?? "无记录"),
                ("心率", day?.rhr.map { "\($0.noDecimal) bpm" } ?? "无记录"),
                ("活动", day.map { "\(Int($0.activeMinutes)) 分钟" } ?? "无记录")]
    }

    private func session(_ d: Date, today: Date) -> PlanStatus? {
        guard let s = context.plan.first(where: { $0.day == d && $0.kind.isTraining }) else { return nil }
        // A past day still marked as planned did not happen.
        return d < today && s.status == .planned ? .skipped : s.status
    }
}

/// Things outside training that are worth a look this week.
struct WatchCard: View {
    let points: [AgentPoint]

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.tight) {
            CardTitle("需要关注")
            ForEach(points) { w in
                if let d = w.destination {
                    NavigationLink { d.view } label: { row(w, chevron: true) }.buttonStyle(.plain)
                } else {
                    row(w, chevron: false)
                }
            }
        }
        // The last row's padding stands in for the card's.
        .padding(.bottom, -Theme.Space.item)
        .cardSurface()
    }

    private func row(_ w: AgentPoint, chevron: Bool) -> some View {
        HStack(alignment: .top, spacing: Theme.Space.block) {
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange).frame(width: Theme.Size.iconTile).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Theme.Space.hairline) {
                Text(w.title).font(.subheadline.weight(.semibold))
                Text(w.detail).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Theme.Space.tight)
            if chevron { Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary).padding(.top, 3) }
        }
        .padding(.vertical, Theme.Space.item)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// One proposal: what changes, why, and a compact adopt / not now.
struct ProposalRow: View {
    let proposal: CoachProposal
    /// The model's wording of the reason (the rules reason until it is written).
    var rationale: String? = nil
    var writing = false
    var onAdopt: () -> Void
    var onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Space.block) {
            Image(systemName: proposal.icon).font(.body.weight(.semibold)).foregroundStyle(.secondary)
                .frame(width: Theme.Size.iconTile).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Theme.Space.tight) {
                Text(proposal.title).font(.subheadline.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                Text(rationale ?? proposal.rationale).font(.subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .opacity(writing ? 0.5 : 1)
                HStack(spacing: Theme.Space.item) {
                    Button(proposal.adoptLabel, action: onAdopt).buttonStyle(.bordered)
                    Button(action: onDismiss) { textLink("暂不", minWidth: 56) }
                        .buttonStyle(.borderless).foregroundStyle(.secondary)
                }
                .font(.subheadline.weight(.semibold))
            }
        }
        .padding(.vertical, Theme.Space.item)
    }
}

/// 一起复盘: three short questions, one at a time. Each says what its answer is used for; options are
/// rows to tick, with a line for the user's own words; the last step shows what will be saved.
struct GuidedReflectionCard: View {
    let steps: [ReflectionStep]
    let brief: WeeklyBrief
    var onSave: ((summary: String, keep: String, change: String, focus: String)) -> Void
    @State private var index = 0
    @State private var answers: [String: [String]] = [:]
    /// The user's own words per step, added to that step's answers.
    @State private var own: [String: String] = [:]
    @State private var note = ""

    private var collected: [String: [String]] {
        var a = answers
        for (id, text) in own {
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { a[id, default: []].append(t) }
        }
        return a
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.block) {
            // Each step replaces the last as a whole, so one question's rows never morph into the next one's.
            Group {
                if index < steps.count {
                    question(steps[index])
                } else {
                    summary
                }
            }
            .id(index)
            .transition(.opacity)
        }
        .cardSurface()
        .animation(.easeInOut(duration: 0.2), value: index)
    }

    @ViewBuilder private func question(_ step: ReflectionStep) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.tight) {
            HStack(alignment: .firstTextBaseline) {
                Text(step.question).font(.headline)
                Spacer(minLength: Theme.Space.item)
                Text("\(index + 1)/\(steps.count)").font(.footnote).foregroundStyle(.secondary).monospacedDigit()
                    .accessibilityLabel("第 \(index + 1) 题，共 \(steps.count) 题")
            }
            if !step.why.isEmpty {
                Text(step.why).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        VStack(spacing: 0) {
            ForEach(step.options, id: \.self) { o in
                let on = answers[step.id, default: []].contains(o)
                Button {
                    if on { answers[step.id, default: []].removeAll { $0 == o } } else { answers[step.id, default: []].append(o) }
                } label: {
                    HStack(spacing: Theme.Space.block) {
                        Image(systemName: on ? "checkmark.circle.fill" : "circle")
                            .font(.title3).foregroundStyle(on ? Theme.accent : Color.secondary.opacity(0.5))
                            .frame(width: Theme.Size.iconTile)
                        Text(o).font(.body).foregroundStyle(.primary)
                        Spacer(minLength: 0)
                    }
                    .frame(minHeight: Theme.Size.tap)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
                Divider().padding(.leading, Theme.Size.iconTile + Theme.Space.block)
            }
            HStack(spacing: Theme.Space.block) {
                Image(systemName: "pencil").font(.body).foregroundStyle(.secondary).frame(width: Theme.Size.iconTile)
                TextField(step.id == "change" ? "其他，或说说原因（可选）" : "其他（可选）",
                          text: Binding(get: { own[step.id] ?? (step.id == "change" ? note : "") },
                                        set: { if step.id == "change" { note = $0 } else { own[step.id] = $0 } }),
                          axis: .vertical)
                    .lineLimit(1...3)
            }
            .frame(minHeight: Theme.Size.tap)
        }
        HStack(spacing: Theme.Space.item) {
            if index > 0 {
                Button { index -= 1 } label: { textLink("上一步") }.buttonStyle(.borderless)
            }
            Spacer()
            let answered = !collected[step.id, default: []].isEmpty || (step.id == "change" && !note.trimmingCharacters(in: .whitespaces).isEmpty)
            if answered {
                Button(index == steps.count - 1 ? "完成" : "下一步") { index += 1 }.buttonStyle(.borderedProminent)
            } else {
                Button { index += 1 } label: { textLink("跳过") }.buttonStyle(.borderless).foregroundStyle(.secondary)
            }
        }
        .font(.subheadline.weight(.semibold))
        .frame(minHeight: Theme.Size.tap)
    }

    @ViewBuilder private var summary: some View {
        let draft = ReviewCoach.draft(brief: brief, answers: collected, note: note)
        VStack(alignment: .leading, spacing: Theme.Space.tight) {
            Text("这周的复盘").font(.headline)
            Text("保存后，下周计划会参考你的回答。").font(.footnote).foregroundStyle(.secondary)
        }
        ReviewNotesView(summary: draft.summary, keep: draft.keep, change: draft.change, focus: draft.focus)
        HStack(spacing: Theme.Space.item) {
            Button { index = 0 } label: { textLink("修改") }.buttonStyle(.borderless)
            Spacer()
            Button { onSave(draft) } label: { Label("保存复盘", systemImage: "checkmark") }
                .buttonStyle(.borderedProminent)
        }
        .font(.subheadline.weight(.semibold))
        .frame(minHeight: Theme.Size.tap)
    }
}

/// The saved answers of a weekly review, label above text.
private struct ReviewNotesView: View {
    let summary: String
    let keep: String
    let change: String
    let focus: String

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.item) {
            ForEach([("总结", summary), ("想保留", keep), ("想改变", change), ("下周重点", focus)].filter { !$0.1.isEmpty }, id: \.0) { item in
                VStack(alignment: .leading, spacing: Theme.Space.hairline) {
                    Text(item.0).font(.footnote).foregroundStyle(.secondary)
                    Text(item.1).font(.subheadline).fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
            }
        }
    }
}

struct SavedReviewCard: View {
    let entry: ReviewEntry
    var onRedo: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.block) {
            CardTitle(title: "这周的复盘", detail: "已保存") {
                Button(action: onRedo) { textLink("重新复盘") }.buttonStyle(.borderless).font(.subheadline)
            }
            ReviewNotesView(summary: entry.summary, keep: entry.keep, change: entry.change, focus: entry.nextFocus)
        }
        .cardSurface()
    }
}

/// Next week at a glance: three small numbers, every session (day, what, how long), what changes
/// compared with this week and why, and one action to apply it.
struct NextWeekPlanCard: View {
    let plan: NextWeekPlan
    /// This week's aerobic target, so a change shows as "45 → 60 分钟".
    let currentTarget: Int
    let applied: Bool
    let reviewed: Bool
    var onApply: () -> Void

    var body: some View {
        let trainings = plan.sessions.filter { $0.kind.isTraining }
        VStack(alignment: .leading, spacing: Theme.Space.block) {
            HStack(alignment: .top, spacing: Theme.Space.item) {
                stat("训练", "\(trainings.count) 次")
                stat("总时长", "\(trainings.map(\.minutes).reduce(0, +)) 分钟")
                stat("有氧目标", plan.targetMinutes == currentTarget ? "\(plan.targetMinutes) 分钟" : "\(currentTarget) → \(plan.targetMinutes) 分钟")
            }
            if !trainings.isEmpty {
                VStack(spacing: 0) {
                    Divider()
                    ForEach(Array(trainings.enumerated()), id: \.offset) { i, s in
                        session(s)
                        if i < trainings.count - 1 { Divider().padding(.leading, dayColumn + iconColumn + 2 * Theme.Space.item) }
                    }
                    Divider()
                }
            }
            if !plan.changes.isEmpty {
                VStack(alignment: .leading, spacing: Theme.Space.item) {
                    Text("有哪些变化").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(plan.changes) { c in
                        HStack(alignment: .top, spacing: Theme.Space.item) {
                            Image(systemName: c.icon).font(.footnote).foregroundStyle(.secondary).frame(width: 20).padding(.top, 2)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: Theme.Space.hairline) {
                                Text(c.title).font(.subheadline.weight(.semibold))
                                Text(c.detail).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
            if applied {
                HStack(spacing: Theme.Space.item) {
                    StatusLabel(.good("已应用到下周计划")).font(.subheadline)
                    Spacer()
                    Button(action: onApply) { textLink("重新生成") }.buttonStyle(.borderless).font(.subheadline)
                }
                NavigationLink { WeeklyPlanView(startOnNextWeek: true).navigationTitle("运动计划").navigationBarTitleDisplayMode(.inline).calmStyle() } label: {
                    NavRowLabel(icon: "calendar", title: "在计划中查看下周")
                }
                .buttonStyle(.plain)
            } else {
                VStack(alignment: .leading, spacing: Theme.Space.item) {
                    Button("应用到下周计划", action: onApply)
                        .buttonStyle(.borderedProminent)
                        .font(.subheadline.weight(.semibold))
                    Text(reviewed ? "只影响下周的安排，不会改动你的计划设置。" : "先做完上面的复盘，计划会参考你的回答；也可以直接应用。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        .cardSurface()
    }

    /// Columns of a session row: the weekday and the kind glyph, so titles line up down the list.
    private let dayColumn: CGFloat = 36
    private let iconColumn: CGFloat = 24

    /// One session: the day, what it is, and how long and hard on the right where the eye can run down them.
    private func session(_ s: PlannedSession) -> some View {
        HStack(spacing: Theme.Space.item) {
            Text(Weekday.name(s.weekday)).font(.subheadline.weight(.semibold)).frame(width: dayColumn, alignment: .leading)
            Image(systemName: s.kind.icon).font(.subheadline).imageScale(.small).foregroundStyle(Theme.activity)
                .frame(width: iconColumn).accessibilityHidden(true)
            HStack(spacing: Theme.Space.iconGap) {
                Text(s.title).font(.subheadline).fixedSize(horizontal: false, vertical: true)
                if s.isKey {
                    Image(systemName: "star.fill").font(.caption).foregroundStyle(.yellow).accessibilityLabel("重点")
                }
            }
            Spacer(minLength: Theme.Space.item)
            VStack(alignment: .trailing, spacing: Theme.Space.hairline) {
                Text("\(s.minutes) 分钟").font(.subheadline).monospacedDigit()
                Text(s.intensity.label).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, Theme.Space.item)
        .accessibilityElement(children: .combine)
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.hairline) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.subheadline.weight(.semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

struct PastReviewsCard: View {
    let entries: [ReviewEntry]
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.block) {
            CardTitle("过往复盘")
            ForEach(entries) { e in
                VStack(alignment: .leading, spacing: Theme.Space.tight) {
                    Text("\(e.periodStart.formatted(.dateTime.month().day())) 那周").font(.subheadline.weight(.semibold))
                    if !e.summary.isEmpty { Text(e.summary).font(.subheadline).foregroundStyle(.secondary) }
                    if !e.nextFocus.isEmpty { Text("重点：\(e.nextFocus)").font(.footnote).foregroundStyle(.secondary) }
                }
                .accessibilityElement(children: .combine)
                if e.id != entries.last?.id { Divider() }
            }
        }
        .cardSurface()
    }
}

// MARK: - 长期复盘

struct LongTermReviewSection: View {
    let context: AgentContext
    var onAsk: (String?, Bool) -> Void
    @Query private var insights: [InsightRecord]
    @Environment(\.modelContext) private var ctx

    var body: some View {
        let c = context
        let verdict = ReviewCoach.verdict(context: c)
        let points = ReviewCoach.strategy(context: c)
        let facts = ReviewCoach.longTermFacts(context: c, verdict: verdict, strategy: points)
        let writer = ReviewWriter.shared
        let copy = writer.copy(for: facts)
        let state = writer.state(for: facts)

        ReviewSummaryCard(eyebrow: c.progress.spanDays > 0 ? "长期总结 · 已记录 \(c.progress.spanDays) 天" : "长期总结",
                          glyph: verdictGlyph(verdict.kind), headline: copy.headline, summary: copy.summary,
                          byline: state, onRetry: { Task { await writer.rewrite(facts) } })
            .task(id: facts.key) { await writer.write(facts) }

        let journeys = GoalJourneys.paths(c)
        JourneyCard(paths: journeys)
            .task(id: journeys.map { "\($0.id):\($0.current)" }) { DataHub.recordJourneys(journeys, in: ctx) }
        DimensionsCard(dimensions: c.progress.dimensions, onAsk: onAsk)
        WeeklyRHRCard(context: c)
        HabitsAdherenceCard(adherence: c.adherence)
        AssociationsCard(associations: c.associations.filter { $0.sufficient && $0.strength >= .weak },
                         insights: insights, days: c.days, onAsk: onAsk)
        StrategyCard(points: points, details: copy.items, writing: state == nil || state == .writing)
    }

    private func verdictGlyph(_ kind: LongTermVerdict.Kind) -> (icon: String, color: Color) {
        switch kind {
        case .fits: ("checkmark.seal.fill", .green)
        case .partly: ("circle.lefthalf.filled", .yellow)
        case .adjust: ("arrow.triangle.2.circlepath.circle.fill", .orange)
        case .early: ("hourglass.circle.fill", .gray)
        }
    }
}

/// 所处阶段 for each management goal: a switcher when there are several, and the chosen goal's path as
/// a vertical timeline — finished stages folded into one step, the current one opened up (how far along,
/// what it is for, what moves you on), later ones on one line each. What to do now is said once, at
/// the end of the 长期总结 above.
struct JourneyCard: View {
    let paths: [GoalJourney]
    @AppStorage("review.journey.goal") private var chosen = ""

    var body: some View {
        let path = paths.first { $0.id == chosen } ?? paths[0]
        VStack(alignment: .leading, spacing: Theme.Space.block) {
            CardTitle("所处阶段", detail: path.isComplete ? "已完成全部阶段" : "第 \(path.current + 1)/\(path.stages.count) 阶段")
            if paths.count > 1 {
                // Every goal stays in view; a long list wraps instead of scrolling off the card.
                FlowLayout(spacing: Theme.Space.item) {
                    ForEach(paths) { p in GoalChip(path: p, selected: p.id == path.id) { chosen = p.id } }
                }
            }
            VStack(alignment: .leading, spacing: 0) {
                let done = path.stages.prefix(path.current)
                // Finished stages fold into one step; what matters is the stage you are in.
                if !done.isEmpty {
                    step(glyph: "checkmark.circle.fill", color: .green, line: .green, bottom: Theme.Space.block) {
                        Text("已完成 \(done.count) 个阶段").font(.subheadline).foregroundStyle(.secondary)
                        Text(done.map(\.title).joined(separator: " · ")).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                if path.isComplete {
                    step(glyph: "flag.checkered.circle.fill", color: .green, line: nil, bottom: 0) {
                        Text("已达成").font(.subheadline.weight(.semibold))
                        opened(path.standing, focus: nil)
                    }
                } else {
                    ForEach(path.stages.indices.dropFirst(path.current), id: \.self) { i in
                        let s = path.stages[i], last = i == path.stages.count - 1
                        if i == path.current {
                            // The open stage is a block of its own; the stages after it are one-line items.
                            step(glyph: "\(i + 1).circle.fill", color: .green, line: last ? nil : Theme.subtle, bottom: last ? 0 : Theme.Space.block) {
                                Text(s.title).font(.subheadline.weight(.semibold))
                                opened(path.standing, focus: s.focus)
                            }
                        } else {
                            step(glyph: "\(i + 1).circle", color: .secondary, line: last ? nil : Theme.subtle, bottom: last ? 0 : Theme.Space.item) {
                                Text(s.title).font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(spoken(path))
        }
        .cardSurface()
    }

    /// One step of the timeline: its glyph with the line down to the next step, and its text.
    private func step<Content: View>(glyph: String, color: Color, line: Color?, bottom: CGFloat,
                                     @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: Theme.Space.block) {
            VStack(spacing: Theme.Space.tight) {
                Image(systemName: glyph).font(.title3).foregroundStyle(color)
                if let line { Capsule().fill(line).frame(width: 2).frame(maxHeight: .infinity) }
            }
            .frame(width: Theme.Size.iconTile)
            VStack(alignment: .leading, spacing: Theme.Space.tight) { content() }
                .padding(.top, 2)
                .padding(.bottom, bottom)
            Spacer(minLength: 0)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    /// The current stage: how far along, what it is for, and what moves you on.
    @ViewBuilder private func opened(_ st: GoalJourney.Standing, focus: String?) -> some View {
        Text(st.met ? st.status : "进行中 · \(st.status)").font(.footnote).foregroundStyle(.secondary)
        if let p = st.progress, !st.met {
            ProgressBar(value: p, color: .green, height: 6).padding(.vertical, Theme.Space.tight)
        }
        if let focus { Text(focus).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        if let pass = st.toPass, !st.met {
            labelled("进入下一阶段", pass).padding(.top, Theme.Space.tight)
        }
    }

    /// "进入下一阶段：……" on one line, the label in the same size as the text so the line reads as one.
    private func labelled(_ label: String, _ text: String) -> some View {
        Text("\(Text(label + "：").fontWeight(.semibold).foregroundStyle(.secondary))\(text)")
            .font(.subheadline).fixedSize(horizontal: false, vertical: true)
    }

    private func spoken(_ p: GoalJourney) -> String {
        let done = p.stages.prefix(p.current).map(\.title)
        let now = p.isComplete ? "已完成全部阶段。\(p.standing.status)。"
            : "第 \(p.current + 1) 阶段，共 \(p.stages.count) 个：\(p.stages[p.current].title)。\(p.standing.status)。"
        return ["\(p.title)的所处阶段：", now, done.isEmpty || p.isComplete ? nil : "已完成：\(done.joined(separator: "、"))。",
                p.standing.toPass.flatMap { p.standing.met ? nil : "进入下一阶段需要：\($0)。" }]
            .compactMap { $0 }.joined()
    }
}

/// A goal in the 所处阶段 switcher.
private struct GoalChip: View {
    let path: GoalJourney
    let selected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            // Text only, so three goals fit on one line; the timeline below says which goal it is.
            Text(path.short)
                .font(.subheadline.weight(selected ? .semibold : .regular))
                .foregroundStyle(selected ? Theme.accent : Color.primary)
                .padding(.horizontal, Theme.Space.block).padding(.vertical, Theme.Space.item)
                .background(selected ? Theme.accent.opacity(0.14) : Theme.subtle, in: Capsule())
                .frame(minHeight: Theme.Size.tap)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(path.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Progress on every dimension, first four weeks against the last four. Long-press a row to ask about it.
struct DimensionsCard: View {
    let dimensions: [ProgressDimension]
    var onAsk: (String?, Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CardTitle("多维进展", detail: "起始 4 周 → 最近 4 周").padding(.bottom, Theme.Space.tight)
            ForEach(dimensions) { d in
                if d.id != dimensions.first?.id { Divider().padding(.leading, Theme.Size.iconTile + Theme.Space.block) }
                DimensionRow(dimension: d)
                    .contextMenu {
                        Button(AgentNameSettings.shared.phrase("问问"), systemImage: "sparkles") { onAsk(ReviewCoach.question(for: d), false) }
                    }
            }
        }
        // The last row's padding stands in for the card's.
        .padding(.bottom, -Theme.Space.item)
        .cardSurface()
    }
}

struct DimensionRow: View {
    let dimension: ProgressDimension

    var body: some View {
        let d = dimension
        HStack(alignment: .top, spacing: Theme.Space.block) {
            Image(systemName: d.icon).font(.body.weight(.semibold)).foregroundStyle(dataColor(d.icon))
                .frame(width: Theme.Size.iconTile).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Theme.Space.tight) {
                HStack(alignment: .firstTextBaseline) {
                    Text(d.name).font(.subheadline.weight(.semibold))
                    Spacer(minLength: Theme.Space.item)
                    StatusLabel(text: d.status.label, icon: icon, color: Theme.progress(d.status), secondaryText: true).font(.subheadline)
                }
                if let f = d.from, let t = d.to {
                    HStack(alignment: .firstTextBaseline, spacing: Theme.Space.iconGap) {
                        Text(f).foregroundStyle(.secondary)
                        Image(systemName: "arrow.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                        Text(t).fontWeight(.semibold)
                    }
                    .font(.subheadline).monospacedDigit()
                } else if let t = d.to {
                    Text("目前 \(t)").font(.subheadline).monospacedDigit()
                }
                Text(d.detail).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, Theme.Space.item)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var icon: String {
        switch dimension.status {
        case .improved: "arrow.up.right.circle.fill"
        case .needsWork: "exclamationmark.circle.fill"
        case .stable: "equal.circle.fill"
        case .insufficient: "hourglass"
        }
    }
}

struct WeeklyRHRCard: View {
    let context: AgentContext
    var body: some View {
        let t = context.trend
        let weeks: [(Date, Double)] = (0..<20).compactMap { w in
            let ws = context.weekStart.adding(days: -7 * w)
            let v = t.points.filter { $0.day >= ws && $0.day < ws.adding(days: 7) }.map(\.value)
            return v.count >= 3 ? (ws, Stats.mean(v)!) : nil
        }.reversed()
        if weeks.count >= 3 {
            HealthMetricCard(title: "静息心率周均值", icon: "heart.fill", color: Theme.heartData, time: "近 20 周",
                             value: weeks.last!.1.noDecimal, unit: "bpm",
                             status: t.baseline.map { b in weeks.last!.1 <= b - 1 ? MetricStatus.good("比基线低 \((b - weeks.last!.1).oneDecimal)") : MetricStatus.neutral("基线 \(b.noDecimal)") }) {
                Chart {
                    if let b = t.baseline {
                        RuleMark(y: .value("基线", b)).lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4])).foregroundStyle(Color.gray)
                    }
                    ForEach(weeks, id: \.0) { w in
                        LineMark(x: .value("周", w.0, unit: .weekOfYear), y: .value("bpm", w.1))
                            .interpolationMethod(.catmullRom).foregroundStyle(Theme.heartData)
                        PointMark(x: .value("周", w.0, unit: .weekOfYear), y: .value("bpm", w.1)).foregroundStyle(Theme.heartData).symbolSize(18)
                    }
                }
                .chartYScale(domain: ((weeks.map(\.1).min() ?? 60) - 3)...((weeks.map(\.1).max() ?? 75) + 3))
                .chartYAxis { AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) }
                .frame(height: 150)
                .accessibilityLabel("近 20 周静息心率周均值")
                Text("虚线为个人基线").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct HabitsAdherenceCard: View {
    let adherence: [HabitAdherence]
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CardTitle("哪些习惯能坚持", detail: "近 4 周").padding(.bottom, Theme.Space.tight)
            ForEach(adherence) { h in
                if h.id != adherence.first?.id { Divider() }
                VStack(alignment: .leading, spacing: Theme.Space.tight) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(h.name).font(.subheadline.weight(.semibold))
                        Spacer()
                        if let r = h.rate {
                            Text("\(Int((r * 100).rounded()))%").font(.subheadline.weight(.semibold)).monospacedDigit()
                        }
                    }
                    ProgressBar(value: h.rate ?? 0, color: Theme.habit(h.verdict), height: 6).accessibilityHidden(true)
                    StatusLabel(text: "\(h.verdict.label) · \(h.detail)", icon: verdictIcon(h.verdict), color: Theme.habit(h.verdict), secondaryText: true)
                        .font(.footnote)
                    if h.verdict == .struggling || h.verdict == .partial {
                        Text(h.suggestion).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.vertical, Theme.Space.item)
                .accessibilityElement(children: .combine)
            }
        }
        // The last row's padding stands in for the card's.
        .padding(.bottom, -Theme.Space.item)
        .cardSurface()
    }

    private func verdictIcon(_ v: HabitAdherence.Verdict) -> String {
        switch v {
        case .sustained: "checkmark.circle.fill"
        case .partial: "circle.lefthalf.filled"
        case .struggling: "exclamationmark.circle.fill"
        case .noData: "minus.circle.fill"
        }
    }
}

/// Observed associations, each with its verification state. Long-press a row to ask about it.
struct AssociationsCard: View {
    let associations: [Association]
    let insights: [InsightRecord]
    let days: [DayData]
    var onAsk: (String?, Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CardTitle("发现的关联", detail: "关联 ≠ 已确认的原因").padding(.bottom, Theme.Space.tight)
            if associations.isEmpty {
                Text("还没有足够数据发现稳定的关联。持续记录饮酒、睡眠、压力等背景后会逐步出现。")
                    .font(.subheadline).foregroundStyle(.secondary).padding(.vertical, Theme.Space.item)
            }
            ForEach(associations) { a in
                if a.id != associations.first?.id { Divider().padding(.leading, Theme.Size.iconTile + Theme.Space.block) }
                AssociationRow(association: a, record: insights.first { $0.key == a.id }, days: days, onAsk: onAsk)
            }
        }
        // The last row's padding stands in for the card's.
        .padding(.bottom, -Theme.Space.item)
        .cardSurface()
    }
}

struct AssociationRow: View {
    @Environment(\.modelContext) private var ctx
    let association: Association
    let record: InsightRecord?
    let days: [DayData]
    var onAsk: (String?, Bool) -> Void

    var body: some View {
        let a = association
        let status = record?.status ?? .observed
        VStack(alignment: .leading, spacing: Theme.Space.item) {
            HStack(alignment: .top, spacing: Theme.Space.block) {
                Image(systemName: a.icon).font(.body.weight(.semibold)).foregroundStyle(.secondary).frame(width: Theme.Size.iconTile).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Theme.Space.tight) {
                    Text(a.sentence).font(.subheadline).fixedSize(horizontal: false, vertical: true)
                    StatusLabel(text: "\(status.label) · 关联\(a.strength.label)", icon: statusIcon(status), color: statusColor(status), secondaryText: true)
                        .font(.footnote)
                }
            }
            .accessibilityElement(children: .combine)
            VStack(alignment: .leading, spacing: Theme.Space.item) {
                if status == .testing, let r = record, let start = r.experimentStart { experimentProgress(r, start) }
                HStack(spacing: Theme.Space.item) {
                    switch status {
                    case .observed:
                        Button("开始 2 周验证") { startExperiment() }.buttonStyle(.bordered)
                    case .testing:
                        Button("对我有效") { set(.confirmed) }.buttonStyle(.bordered)
                        Button { set(.notSupported) } label: { textLink("未得到支持") }
                            .buttonStyle(.borderless).foregroundStyle(.secondary)
                    case .confirmed, .notSupported:
                        Button { set(.observed) } label: { textLink("重新观察") }.buttonStyle(.borderless)
                    }
                }
                .font(.subheadline.weight(.semibold))
            }
            // Under the sentence, past the glyph column.
            .padding(.leading, Theme.Size.iconTile + Theme.Space.block)
        }
        .padding(.vertical, Theme.Space.item)
        .contentShape(Rectangle())
        .contextMenu {
            Button(AgentNameSettings.shared.phrase("问问"), systemImage: "sparkles") { onAsk(question, false) }
        }
    }

    private var question: String {
        switch association.id {
        case let id where id.hasPrefix("alcohol"): "饮酒对我的影响有多大？"
        case let id where id.hasPrefix("caffeine"): "咖啡因对我睡眠有影响吗？"
        case let id where id.hasPrefix("stress"): "压力对我的影响有多大？"
        case let id where id.hasPrefix("shortsleep"), let id where id.hasPrefix("regular"): "我的睡眠怎么样？"
        default: "为什么静息心率最近没怎么降？"
        }
    }

    private func statusIcon(_ s: InsightStatus) -> String {
        switch s {
        case .observed: "eye"
        case .testing: "flask"
        case .confirmed: "checkmark.seal.fill"
        case .notSupported: "xmark.circle"
        }
    }
    private func statusColor(_ s: InsightStatus) -> Color {
        switch s {
        case .confirmed: .green
        case .testing: .orange
        default: .gray
        }
    }

    @ViewBuilder
    private func experimentProgress(_ r: InsightRecord, _ start: Date) -> some View {
        let end = r.experimentEnd ?? start.adding(days: 14)
        let elapsed = min(Date.app.daysSince(start), end.daysSince(start))
        let total = max(1, end.daysSince(start))
        let during = days.filter { $0.day >= start && $0.day <= end }
        let before = days.filter { $0.day < start && $0.day >= start.adding(days: -28) }
        let metric: (DayData) -> Double? = association.metric == "HRV" ? { $0.hrv } : (association.metric == "醒后精力" ? { $0.energy.map(Double.init) } : (association.metric == "睡眠时长" ? { $0.sleepMinutes.map { $0 / 60 } } : { $0.rhr }))
        let m1 = Stats.mean(during.compactMap(metric)), m0 = Stats.mean(before.compactMap(metric))
        VStack(alignment: .leading, spacing: Theme.Space.tight) {
            HStack(alignment: .firstTextBaseline) {
                Text(r.note.isEmpty ? "验证中" : r.note).font(.footnote.weight(.medium)).fixedSize(horizontal: false, vertical: true)
                Spacer()
                Text("第 \(elapsed)/\(total) 天").font(.footnote).foregroundStyle(.secondary).monospacedDigit()
            }
            ProgressBar(value: Double(elapsed) / Double(total), color: .orange, height: 6).accessibilityHidden(true)
            if let m1, let m0 {
                Text("验证期间\(association.metric)平均 \(m1.oneDecimal) \(association.unit)，此前 4 周 \(m0.oneDecimal)（\((m1 - m0).signedText)）。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private func startExperiment() {
        let r = record ?? {
            let n = InsightRecord(key: association.id, status: .testing)
            ctx.insert(n)
            return n
        }()
        r.status = .testing
        r.experimentStart = .app.startOfDay
        r.experimentEnd = .app.startOfDay.adding(days: 14)
        r.note = "两周内减少「\(association.factor.replacingOccurrences(of: "的次日早晨", with: "").replacingOccurrences(of: "的早晨", with: "").replacingOccurrences(of: "的当晚", with: ""))」，观察\(association.metric)的变化"
    }

    private func set(_ s: InsightStatus) {
        let r = record ?? {
            let n = InsightRecord(key: association.id, status: s)
            ctx.insert(n)
            return n
        }()
        r.status = s
    }
}

/// What to focus on next, written by the model from the rules' strategy.
struct StrategyCard: View {
    let points: [AgentPoint]
    let details: [String]
    let writing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CardTitle("下一阶段", detail: AgentNameSettings.shared.phrase("", "的建议")).padding(.bottom, Theme.Space.tight)
            ForEach(Array(points.enumerated()), id: \.element.id) { i, p in
                if i > 0 { Divider().padding(.leading, Theme.Size.iconTile + Theme.Space.block) }
                if let d = p.destination {
                    NavigationLink { d.view } label: { row(p, detail: details[safe: i] ?? p.detail, chevron: true) }
                        .buttonStyle(.plain)
                } else {
                    row(p, detail: details[safe: i] ?? p.detail, chevron: false)
                }
            }
        }
        // The last row's padding stands in for the card's.
        .padding(.bottom, -Theme.Space.item)
        .cardSurface()
    }

    private func row(_ p: AgentPoint, detail: String, chevron: Bool) -> some View {
        HStack(alignment: .top, spacing: Theme.Space.block) {
            Image(systemName: p.icon).font(.body.weight(.semibold)).foregroundStyle(.secondary).frame(width: Theme.Size.iconTile).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Theme.Space.hairline) {
                Text(p.title).font(.subheadline.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                Text(detail).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .opacity(writing ? 0.5 : 1)
            }
            Spacer(minLength: Theme.Space.tight)
            if chevron { Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary).padding(.top, 3) }
        }
        .padding(.vertical, Theme.Space.item)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}
