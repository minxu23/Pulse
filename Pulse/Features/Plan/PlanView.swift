import SwiftUI
import SwiftData
import Charts

struct PlanView: View {
    enum Segment: String, CaseIterable, Identifiable {
        case exercise = "运动", sleep = "睡眠", habits = "恢复"
        var id: String { rawValue }
    }
    @State private var segment: Segment = .exercise

    var body: some View {
        NavigationStack {
            Group {
                switch segment {
                case .exercise: WeeklyPlanView()
                case .sleep: SleepCareView()
                case .habits: HabitsView()
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                Picker("", selection: $segment) {
                    ForEach(Segment.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .readableWidth()
                .padding(.horizontal, Theme.Space.gutter)
                .padding(.bottom, Theme.Space.item)
                .background(.bar)
            }
            .navigationTitle("计划")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

// MARK: - Weekly exercise plan (需求 4)

struct WeeklyPlanView: View {
    @Environment(\.modelContext) private var ctx
    @Query private var profiles: [UserProfile]
    @Query private var meds: [MedicationEntry]
    @Query(sort: \PlanItem.day) private var items: [PlanItem]
    @Query(sort: \ActivitySession.start) private var sessions: [ActivitySession]
    var startOnNextWeek = false
    @State private var selectedDay = Date.app.startOfDay
    @State private var logItem: PlanItem?
    @State private var showNext = false

    var body: some View {
        let p = profiles.first
        let snap = p?.snapshot(medications: meds) ?? ProfileSnapshot()
        let nextWs = Date.app.weekStart.adding(days: 7)
        let hasNext = items.contains { $0.weekStart == nextWs }
        let ws = showNext && hasNext ? nextWs : Date.app.weekStart
        let week = items.filter { $0.weekStart == ws }
        let generated = PlanGenerator.generate(profile: snap, weekStart: ws)
        ScreenScroll {
            if hasNext {
                Picker("查看", selection: $showNext) {
                    Text("本周").tag(false)
                    Text("下周").tag(true)
                }
                .pickerStyle(.segmented)
            }
            if let mw = generated.marathon, snap.modules.contains(.marathon) { MarathonPhaseCard(week: mw) }
            summaryCard(week, p, generated, weekStart: ws, isNext: ws == nextWs)
            if ws != nextWs { AgentContextReader { WeatherPlanCard(context: $0) } }
            // Three groups: the week, the chosen day, and the background to the plan.
            weekStrip(week, weekStart: ws)
                .padding(.top, Theme.Space.section - Theme.Space.cardGap)
            dayDetail(week.filter { $0.day == selectedDay })
            notesCard(generated.notes)
                .padding(.top, Theme.Space.section - Theme.Space.cardGap)
            historyCard
            if let p { NavigationLink { PlanSettingsView(profile: p) } label: { settingsRow } .buttonStyle(.plain) }
            Disclaimer(text: "运动计划为一般性健康建议。有心血管疾病、糖尿病、妊娠或其他健康状况时，请遵循医生的个人照护要求。")
        }
        .sheet(item: $logItem) { QuickLogSheet(kind: .workout, date: $0.day, planItemID: $0.id) }
        .onAppear {
            if startOnNextWeek && items.contains(where: { $0.weekStart == nextWs }) { showNext = true; selectedDay = nextWs }
        }
        .onChange(of: showNext) { _, next in selectedDay = next ? nextWs : Date.app.startOfDay }
    }

    private func summaryCard(_ week: [PlanItem], _ p: UserProfile?, _ plan: WeekPlan, weekStart ws: Date, isNext: Bool) -> some View {
        let trainings = week.filter { $0.kind.isTraining }
        let done = trainings.filter { $0.status == .done }.count
        let minutesDone = isNext ? 0 : sessions.filter { $0.start >= ws }.map(\.minutes).reduce(0, +)
        let planned = trainings.map(\.minutes).reduce(0, +)
        let target = isNext ? (p?.nextWeekTargetMinutes ?? plan.weeklyTargetMinutes) : (p?.weeklyTargetMinutes ?? plan.weeklyTargetMinutes)
        let strength = trainings.filter { $0.kind == .strength || $0.title.contains("力量") }.count
        let reasonText = isNext ? p?.nextWeekTargetReason : p?.weeklyTargetReason
        return Card {
            CardHeader(title: isNext ? "下周" : "本周", subtitle: "\(ws.formatted(.dateTime.month().day())) – \(ws.adding(days: 6).formatted(.dateTime.month().day()))",
                       icon: "calendar", color: Theme.activity) {
                Text(isNext ? "\(trainings.count) 次训练" : "\(done)/\(trainings.count) 次").font(.subheadline.weight(.semibold)).monospacedDigit()
            }
            MetricRow {
                if isNext {
                    MetricTile(label: "计划训练", value: "\(planned)", unit: "/ \(target) 分钟", icon: "timer", color: Theme.activity)
                } else {
                    MetricTile(label: "已活动", value: "\(Int(minutesDone))", unit: "/ \(target) 分钟", icon: "timer", color: Theme.activity)
                }
                MetricTile(label: "力量训练", value: "\(strength)", unit: "次/周", icon: "dumbbell", color: .orange)
            }
            if !isNext { ProgressBar(value: minutesDone / Double(max(1, target)), color: Theme.activity) }
            if let reason = reasonText, !reason.isEmpty {
                Label(reason, systemImage: "arrow.up.forward.circle").font(.footnote).foregroundStyle(.secondary)
            }
            Text("参考：成年人每周 150–300 分钟中等强度有氧，并进行 2 次以上力量训练。计划会从你的现状出发，按完成情况逐步进阶。")
                .font(.footnote).foregroundStyle(.secondary)
            AgentAskButton(title: AgentNameSettings.shared.phrase("和", "调整\(isNext ? "下周" : "本周")计划"),
                           question: isNext ? "帮我调整下周计划" : "帮我调整这周的训练计划")
        }
    }

    private func weekStrip(_ week: [PlanItem], weekStart ws: Date) -> some View {
        HStack(spacing: Theme.Space.item) {
            ForEach(0..<7, id: \.self) { i in
                let day = ws.adding(days: i)
                let dayItems = week.filter { $0.day == day }
                let main = dayItems.first { $0.kind.isTraining } ?? dayItems.first
                let selected = day == selectedDay
                Button { selectedDay = day } label: {
                    VStack(spacing: Theme.Space.tight) {
                        Text(Weekday.short(day.weekday)).font(.caption).foregroundStyle(.secondary)
                        Text("\(Calendar.pulse.component(.day, from: day))")
                            .font(.subheadline.weight(day.isSameDay(.app) ? .bold : .regular))
                        Image(systemName: main.map { $0.status == .planned ? $0.kind.icon : $0.status.icon } ?? "minus")
                            .font(.caption)
                            .foregroundStyle(main.map { $0.status == .planned ? Theme.intensity($0.intensity) : Theme.planStatus($0.status) } ?? .secondary)
                            .frame(height: 16)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Theme.Space.block)
                    .background(selected ? Theme.accent.opacity(0.12) : Theme.card, in: RoundedRectangle(cornerRadius: Theme.Radius.inner, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.inner, style: .continuous).stroke(selected ? Theme.accent : .clear, lineWidth: 1.5))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(Weekday.name(day.weekday)) \(Calendar.pulse.component(.day, from: day)) 日，\(main.map { "\($0.title)，\($0.intensity.label)，\($0.status.label)" } ?? "没有安排")")
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }

    private func dayDetail(_ dayItems: [PlanItem]) -> some View {
        Card {
            CardHeader(title: selectedDay.formatted(.dateTime.month().day().weekday(.wide)), icon: "list.bullet.clipboard", color: Theme.activity)
            if dayItems.isEmpty { EmptyHint(icon: "calendar", text: "这一天没有安排。") }
            ForEach(dayItems) { item in
                VStack(alignment: .leading, spacing: Theme.Space.item) {
                    HStack(alignment: .top, spacing: Theme.Space.block) {
                        Image(systemName: item.kind.icon).foregroundStyle(Theme.intensity(item.intensity)).frame(width: Theme.Size.iconTile)
                        VStack(alignment: .leading, spacing: Theme.Space.hairline) {
                            HStack(spacing: Theme.Space.item) {
                                Text(item.title).font(.headline)
                                if item.isKey { Chip(text: "重点", icon: "star.fill", color: .yellow) }
                            }
                            Text("\(item.minutes > 0 ? "\(item.minutes) 分钟 · " : "")\(item.intensity.label) · \(item.status.label)")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Menu {
                            ForEach(PlanStatus.allCases) { s in
                                Button { item.status = s; item.completedMinutes = s == .done ? item.minutes : (s == .planned || s == .skipped ? nil : item.completedMinutes) } label: { Label(s.label, systemImage: s.icon) }
                            }
                            if item.kind.isTraining { Button { logItem = item } label: { Label("记录运动详情", systemImage: "square.and.pencil") } }
                        } label: {
                            Image(systemName: item.status.icon).font(.title3).foregroundStyle(Theme.planStatus(item.status))
                                .frame(width: Theme.Size.tap, height: Theme.Size.tap)
                                .contentShape(Rectangle())
                        }
                        .accessibilityLabel("\(item.title)，\(item.status.label)，更改状态")
                    }
                    Text(item.detail).font(.subheadline)
                    Label(item.guidance, systemImage: "speedometer").font(.footnote).foregroundStyle(.secondary)
                    if item.minimumMinutes > 0 && !item.minimumDetail.isEmpty {
                        Label("忙碌时的精简版：\(item.minimumDetail)", systemImage: "timer").font(.footnote).foregroundStyle(.secondary)
                    }
                    if let note = item.adjustmentNote, item.wasAdjusted {
                        Callout(kind: .info, title: "已根据当天状态调整", text: note)
                    }
                }
                if item.id != dayItems.last?.id { Divider() }
            }
        }
    }

    private func notesCard(_ notes: [String]) -> some View {
        Card {
            CardHeader(title: "计划原则", icon: "lightbulb", color: .yellow)
            ForEach(notes, id: \.self) { n in
                if n.contains("医生") || n.contains("血糖") || n.contains("妊娠") { Callout(kind: .caution, text: n) }
                else { BulletText(text: n) }
            }
        }
    }

    private var historyCard: some View {
        let weeks = (1...6).map { Date.app.weekStart.adding(days: -7 * $0) }.reversed()
        let data: [(Date, Double)] = weeks.compactMap { ws in
            let t = items.filter { $0.weekStart == ws && $0.kind.isTraining }
            guard !t.isEmpty else { return nil }
            let score = t.reduce(0.0) { $0 + ($1.status == .done ? 1 : ($1.status == .partial ? 0.5 : 0)) }
            return (ws, score / Double(t.count))
        }
        return Group {
            if !data.isEmpty {
                Card {
                    CardHeader(title: "近 6 周完成率", subtitle: "完成率会自动影响下周的目标", icon: "chart.bar", color: .secondary)
                    Chart {
                        ForEach(data, id: \.0) { d in
                            BarMark(x: .value("周", d.0, unit: .weekOfYear), y: .value("完成率", d.1 * 100))
                                .foregroundStyle(Theme.activity)
                                .cornerRadius(4)
                        }
                        RuleMark(y: .value("良好", 85))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3])).foregroundStyle(Color.gray)
                    }
                    .chartYScale(domain: 0...100)
                    .chartYAxis { AxisMarks(values: [0, 50, 100]) { v in AxisGridLine(); AxisValueLabel { Text("\(v.as(Int.self) ?? 0)%") } } }
                    .frame(height: 120)
                    // Below the chart, not on it: bars reach the line and would cover the label.
                    Text("虚线为 85%，达到即为完成良好").font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var settingsRow: some View {
        HStack {
            Label("计划设置：可用日、时长、目标", systemImage: "slider.horizontal.3")
            Spacer()
            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
        }
        .font(.subheadline)
        .cardSurface()
    }
}

struct MarathonPhaseCard: View {
    let week: MarathonWeek
    var body: some View {
        Card {
            CardHeader(title: "专项：\(week.phase.label)", subtitle: week.weeksToRace >= 0 ? "距比赛 \(week.weeksToRace) 周" : "赛后恢复", icon: "flag.checkered", color: .purple)
            MetricRow {
                MetricTile(label: "本周跑量", value: "\(Int(week.weeklyKm))", unit: "km", icon: "road.lanes", color: Theme.activity)
                MetricTile(label: "长距离", value: "\(Int(week.longRunKm))", unit: "km", icon: "arrow.right", color: Theme.activity)
                MetricTile(label: "马拉松配速", value: MarathonPlanner.paceText(week.marathonPace), icon: "speedometer", color: Theme.activity)
            }
            Text(week.phase.focus).font(.subheadline).foregroundStyle(.secondary)
            ForEach(week.warnings, id: \.self) { Callout(kind: .caution, text: $0) }
        }
    }
}

struct PlanSettingsView: View {
    @Environment(\.modelContext) private var ctx
    @Bindable var profile: UserProfile
    @State private var regenerated = false

    var body: some View {
        Form {
            LifeConstraintsSection(p: profile)
            Section {
                Stepper("本周有氧目标 \(profile.weeklyTargetMinutes) 分钟", value: $profile.weeklyTargetMinutes, in: 30...600, step: 10)
            } footer: {
                Text("通常无需手动修改：每周会根据上周完成情况自动调整（完成良好 +10%，完成较少则降低）。")
            }
            ExerciseBaseSection(p: profile)
            Section {
                Button {
                    DataHub.regenerateWeekPlan(in: ctx)
                    try? ctx.save()
                    regenerated = true
                } label: {
                    Label(regenerated ? "已更新本周剩余安排" : "按新设置更新本周剩余安排", systemImage: regenerated ? "checkmark" : "arrow.clockwise")
                }
            } footer: {
                Text("已完成或已标记的项目会保留。")
            }
        }
        .navigationTitle("计划设置").calmStyle()
        .onChange(of: profile.availableWeekdays) { _, _ in regenerated = false }
        .onChange(of: profile.sessionMinutes) { _, _ in regenerated = false }
    }
}
