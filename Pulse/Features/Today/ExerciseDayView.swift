import SwiftUI
import SwiftData

/// 运动：结论在前（今天练什么、是否与准备度匹配、直接操作），依据在后（今天实际活动的数字、
/// 运动前提示、运动记录）。卡片结构与晨起评估一致。
struct ExerciseDayView: View {
    let data: TodayData
    @Binding var sheet: TodaySheet?
    @Environment(\.modelContext) private var ctx

    var body: some View {
        let pending = data.trainings.first { $0.status == .planned }
        let main = pending ?? data.trainings.first

        if let item = main {
            SessionHeroCard(item: item, readiness: data.readiness, cardiacLimited: data.p.cardiacLimited,
                            onDone: { setStatus(item, .done) },
                            onStatus: { setStatus(item, $0) },
                            onAdjust: { sheet = .adjust },
                            onLog: { sheet = .workout(item.id) })
        } else {
            ActivityDayHeroCard(title: data.todayItems.first?.title ?? "恢复日",
                                detail: data.todayItems.first?.detail ?? "今天没有训练安排，好好休息。",
                                vitality: data.vitality, onLog: { sheet = .workout(nil) })
        }

        if let w = data.weatherReminder { WeatherReminderCard(reminder: w) }

        let others = data.trainings.filter { $0.id != main?.id }
        if !others.isEmpty { OtherSessionsCard(items: others, onStatus: setStatus, onLog: { sheet = .workout($0) }) }

        if !tips.isEmpty { PreExerciseCard(tips: tips) }

        SectionTitle(title: "今天的活动")
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
            stepsCard
            activeMinutesCard
            vitalityCard
            weekCard
        }

        WorkoutLogCard(sessions: data.todaySessions, onLog: { sheet = .workout(nil) })

        Text("活力度综合步数与活动时间，反映今天实际活动了多少；准备度则说明今天适合安排多少。")
            .font(.footnote).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
    }

    private func setStatus(_ item: PlanItem, _ status: PlanStatus) {
        PlanActions.setStatus(item, status, useHealthKit: data.profile?.useHealthKit ?? false, in: ctx)
    }

    // MARK: Pre-exercise tips (CGM-assisted glucose check, fuelling, specialist goal)

    private var tips: [PreExerciseCard.Tip] {
        var out: [PreExerciseCard.Tip] = []
        let pending = data.trainings.filter { $0.status == .planned }
        if data.p.hasDiabetes, !pending.isEmpty,
           let g = data.recentVitals.last(where: { $0.kind == .glucose }), g.time > data.now.addingTimeInterval(-45 * 60) {
            out.append(.init(icon: "drop.fill", color: Theme.glucose,
                             title: "运动前血糖 \(g.value.oneDecimal) mmol/L · \(Int(data.now.timeIntervalSince(g.time) / 60)) 分钟前",
                             text: GlucoseAnalyzer.preExerciseAdvice(glucose: g.value, profile: data.p), destination: nil))
        }
        if let long = pending.first(where: { $0.minutes >= 75 }) {
            let fuel = MarathonPlanner.fuelPlan(minutes: long.minutes, carbsPerHour: data.p.race?.fuelCarbsPerHour ?? 45)
            out.append(.init(icon: "bolt.fill", color: Theme.nutrition,
                             title: "补给：约 \(fuel.carbs) g 碳水，\(fuel.fluidLow)–\(fuel.fluidHigh) ml 水",
                             text: fuel.note, destination: nil))
        }
        if data.suggestsMarathon {
            out.append(.init(icon: "flag.checkered", color: Theme.activity, title: "开启专项运动支持",
                             text: "识别到赛事目标，可获得分阶段计划、补给演练与复盘。", destination: .marathon))
        }
        return out
    }

    // MARK: Today's activity grid

    private var stepsCard: some View {
        let v = data.vitality
        let zh = Locale(identifier: "zh_CN")
        let left = max(0, v.stepsTarget - v.steps)
        return HealthMetricCard(title: "步数", icon: "figure.walk", color: Theme.activity,
                                value: v.steps.formatted(.number.locale(zh)), unit: "步",
                                status: left == 0 ? .good("达到目标") : .neutral("还差 \(left.formatted(.number.locale(zh)))")) {
            ProgressBar(value: Double(v.steps) / Double(max(1, v.stepsTarget)), color: Theme.activity, height: 6)
        }
    }

    private var activeMinutesCard: some View {
        let v = data.vitality
        let target = max(v.plannedMinutes, 20)
        return HealthMetricCard(title: "活动时间", icon: "flame.fill", color: Theme.activity,
                                value: "\(Int(v.activeMinutes))", unit: "分钟",
                                status: v.activeMinutes >= Double(target) ? .good("达到今日安排") : .neutral("今日安排 \(target) 分钟")) {
            ProgressBar(value: v.activeMinutes / Double(target), color: Theme.activity, height: 6)
        }
    }

    private var vitalityCard: some View {
        let v = data.vitality
        let heavy = v.label == "活动量较大"
        let status: MetricStatus = v.score >= 80 ? (heavy ? .attention(v.label) : .good(v.label)) : .neutral(v.label)
        return HealthMetricCard(title: "活力度", icon: "bolt.heart.fill", color: Theme.activity,
                                value: "\(v.score)", unit: "/ 100", status: status) {
            ProgressBar(value: Double(v.score) / 100, color: Theme.activity, height: 6)
        }
    }

    private var weekCard: some View {
        let trainings = data.weekItems.filter { $0.kind.isTraining }
        let done = trainings.filter { $0.status == .done || $0.status == .partial }.count
        let minutes = data.analytics.days.filter { $0.day >= data.day.weekStart }.map(\.activeMinutes).reduce(0, +)
        let target = data.p.weeklyTargetMinutes
        return HealthMetricCard(title: "本周训练", icon: "calendar", color: Theme.activity,
                                value: "\(done)/\(trainings.count)", unit: "次",
                                status: minutes >= Double(target) ? .good("达到本周目标") : .neutral("\(Int(minutes))/\(target) 分钟")) {
            ProgressBar(value: minutes / Double(max(1, target)), color: Theme.activity, height: 6)
        }
    }
}

// MARK: - Session hero

struct SessionHeroCard: View {
    let item: PlanItem
    let readiness: ReadinessResult
    let cardiacLimited: Bool
    var onDone: () -> Void
    var onStatus: (PlanStatus) -> Void
    var onAdjust: () -> Void
    var onLog: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("今日训练").font(.headline)
                Spacer()
                if item.isKey { Chip(text: "重点课", icon: "star.fill", color: .yellow) }
            }

            HStack(alignment: .top, spacing: 14) {
                Image(systemName: item.kind.icon)
                    .font(.title2.weight(.semibold)).foregroundStyle(.white)
                    .frame(width: 56, height: 56)
                    .background(Theme.activity.gradient, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    Text(item.title).font(.title3.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 10) {
                        if item.minutes > 0 { Text("\(item.minutes) 分钟").font(.subheadline.weight(.semibold)).monospacedDigit() }
                        StatusLabel(text: item.intensity.label, icon: "circle.fill", color: Theme.intensity(item.intensity), secondaryText: true)
                            .font(.subheadline).imageScale(.small)
                    }
                }
            }
            .accessibilityElement(children: .combine)

            StatusLabel(text: fit.text, icon: fit.icon, color: fit.color, secondaryText: true).font(.subheadline)

            if item.status == .planned {
                HStack(spacing: 10) {
                    Button(action: onDone) { Label("完成", systemImage: "checkmark").frame(maxWidth: .infinity) }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                    Button(action: onAdjust) { Label("调整", systemImage: "slider.horizontal.3").frame(maxWidth: .infinity) }
                        .buttonStyle(.bordered).controlSize(.large)
                    Menu {
                        Button { onStatus(.partial) } label: { Label("部分完成", systemImage: PlanStatus.partial.icon) }
                        Button { onStatus(.skipped) } label: { Label("今天不练", systemImage: PlanStatus.skipped.icon) }
                        Divider()
                        Button(action: onLog) { Label("记录运动详情", systemImage: "square.and.pencil") }
                    } label: {
                        Image(systemName: "ellipsis").font(.body.weight(.semibold))
                            .frame(width: 50, height: 50)
                            .background(Theme.subtle, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .accessibilityLabel("更多操作")
                }
            } else {
                HStack {
                    StatusLabel(text: "\(item.status.label) · \(item.completedMinutes ?? item.minutes) 分钟", icon: item.status.icon,
                                color: Theme.planStatus(item.status))
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Button("记录详情", action: onLog).buttonStyle(.bordered)
                    Menu {
                        ForEach(PlanStatus.allCases) { s in
                            Button { onStatus(s) } label: { Label(s.label, systemImage: s.icon) }
                        }
                    } label: {
                        Image(systemName: "ellipsis").font(.body.weight(.semibold)).frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("更改状态")
                }
            }

            Divider()
            VStack(alignment: .leading, spacing: 10) {
                IconTextRow(icon: "text.alignleft", color: .secondary, title: "内容", text: item.detail)
                IconTextRow(icon: "speedometer", color: .secondary, title: "强度参考", text: item.guidance)
                if item.minimumMinutes > 0 && !item.minimumDetail.isEmpty {
                    IconTextRow(icon: "timer", color: .secondary, title: "忙碌时的精简版", text: item.minimumDetail)
                }
                if let note = item.adjustmentNote, item.wasAdjusted {
                    IconTextRow(icon: "arrow.triangle.2.circlepath", color: .secondary, title: "已按今天的状态调整", text: note)
                }
            }
        }
        .padding(16)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    /// Does the session fit today's readiness?
    private var fit: MetricStatus {
        guard readiness.score != nil else { return .neutral("记录醒后感受后，可判断是否适合今天的状态") }
        if item.wasAdjusted { return .good("已按今天的准备度调整") }
        let level = readiness.level
        if (level == .low || level == .rest) && item.intensity >= .moderate {
            return .attention("准备度\(level.label)，建议点「调整」查看替代安排")
        }
        if level == .moderate && item.intensity == .hard { return .neutral("准备度一般：强度课可适当减量") }
        if cardiacLimited && item.intensity == .hard { return .attention("较高强度需先与医生确认") }
        return .good("与今天的准备度匹配")
    }
}

struct ActivityDayHeroCard: View {
    let title: String
    let detail: String
    let vitality: VitalityResult
    var onLog: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("今日安排").font(.headline)
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "figure.walk")
                    .font(.title2.weight(.semibold)).foregroundStyle(.white)
                    .frame(width: 56, height: 56)
                    .background(Theme.activity.gradient, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.title3.weight(.semibold))
                    Text(detail).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            StatusLabel(text: vitality.message, icon: vitality.score >= 80 ? "checkmark.circle.fill" : "figure.walk.circle.fill",
                        color: vitality.score >= 80 ? .green : Theme.activity, secondaryText: true)
                .font(.subheadline)
            Button(action: onLog) { Label("记录一次运动", systemImage: "plus").frame(maxWidth: .infinity) }
                .buttonStyle(.bordered).controlSize(.large)
        }
        .padding(16)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

struct OtherSessionsCard: View {
    let items: [PlanItem]
    var onStatus: (PlanItem, PlanStatus) -> Void
    var onLog: (UUID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("其他安排").font(.headline).padding(.bottom, 6)
            ForEach(items) { item in
                HStack(spacing: 12) {
                    Image(systemName: item.kind.icon).foregroundStyle(Theme.activity).frame(width: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title).font(.body)
                        Text("\(item.minutes) 分钟 · \(item.intensity.label)").font(.footnote).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Menu {
                        ForEach(PlanStatus.allCases) { s in
                            Button { onStatus(item, s) } label: { Label(s.label, systemImage: s.icon) }
                        }
                        Divider()
                        Button { onLog(item.id) } label: { Label("记录运动详情", systemImage: "square.and.pencil") }
                    } label: {
                        Image(systemName: item.status.icon).font(.title2).foregroundStyle(Theme.planStatus(item.status))
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("\(item.title)，\(item.status.label)")
                }
                .frame(minHeight: 52)
                if item.id != items.last?.id { Divider().padding(.leading, 40) }
            }
        }
        .padding(16)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

// MARK: - Pre-exercise tips

struct PreExerciseCard: View {
    enum Destination { case marathon }
    struct Tip: Identifiable {
        var id: String { title }
        let icon: String
        let color: Color
        let title: String
        let text: String
        let destination: Destination?
    }
    let tips: [Tip]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("提示").font(.headline).padding(.bottom, 6)
            ForEach(tips) { tip in
                Group {
                    if tip.destination == .marathon {
                        NavigationLink { MarathonView() } label: {
                            HStack {
                                IconTextRow(icon: tip.icon, color: tip.color, title: tip.title, text: tip.text)
                                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    } else {
                        IconTextRow(icon: tip.icon, color: tip.color, title: tip.title, text: tip.text)
                    }
                }
                .padding(.vertical, 8)
                if tip.id != tips.last?.id { Divider().padding(.leading, 44) }
            }
        }
        .padding(16)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

// MARK: - Workout records

struct WorkoutLogCard: View {
    let sessions: [ActivitySession]
    var onLog: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("运动记录").font(.headline)
                Spacer()
                Button(action: onLog) { Label("记录", systemImage: "plus") }
                    .buttonStyle(.bordered)
            }
            .padding(.bottom, 6)
            if sessions.isEmpty {
                Text("今天还没有运动记录。手表记录的运动会自动同步。")
                    .font(.subheadline).foregroundStyle(.secondary).padding(.vertical, 8)
            }
            ForEach(sessions) { s in
                HStack(alignment: .center, spacing: 12) {
                    Image(systemName: s.type.icon).font(.body.weight(.semibold)).foregroundStyle(Theme.activity)
                        .frame(width: 36, height: 36)
                        .background(Theme.activity.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(s.type.label) · \(Int(s.minutes)) 分钟\(s.distanceKm.map { " · \($0.oneDecimal) km" } ?? "")")
                            .font(.body)
                        Text([Clock.text(s.start.minutesOfDay), "用力 \(s.rpe ?? s.type.defaultRPE)/10",
                              s.avgHR.map { "平均心率 \(Int($0))" } ?? "", s.source.label]
                            .filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    if let f = s.feeling {
                        StatusLabel(text: f.label, icon: f.icon, color: f == .unwell ? .red : (f == .hard ? .orange : .gray), secondaryText: true)
                            .font(.footnote)
                    }
                }
                .frame(minHeight: 56)
                .accessibilityElement(children: .combine)
                if s.id != sessions.last?.id { Divider().padding(.leading, 48) }
            }
        }
        .padding(16)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

/// Today's weather for today's outdoor session, with the way to the plan when it is better moved indoors.
struct WeatherReminderCard: View {
    let reminder: WeatherReminder

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text("今天的天气").font(.headline)
            } icon: {
                Image(systemName: reminder.icon).symbolRenderingMode(.multicolor)
            }
            Text(reminder.line).font(.subheadline).fixedSize(horizontal: false, vertical: true)
            if reminder.changePlan {
                NavigationLink {
                    WeeklyPlanView().navigationTitle("运动计划").navigationBarTitleDisplayMode(.inline).calmStyle()
                } label: {
                    Label("按天气调整本周计划", systemImage: "calendar.badge.clock").font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.bordered)
            }
        }
        .cardSurface()
    }
}

