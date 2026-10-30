import SwiftUI
import SwiftData

// MARK: - 睡前

/// 睡前：结论在前（几点上床、可睡多久、是否已记录），然后是今晚的恢复重点、
/// 今天的身体感受和明天的安排。
struct EveningDayView: View {
    let data: TodayData
    @Binding var sheet: TodaySheet?

    var body: some View {
        TonightHeroCard(data: data, onRecord: { sheet = .evening })
        if let r = data.record {
            RecoveryChecklistCard(record: r, analytics: data.analytics, readiness: data.readiness, tomorrow: data.tomorrow)
        }
        SectionTitle(title: "今天的身体感受", subtitle: data.record?.eveningCheckInAt.map { "记录于 \(Clock.text($0.minutesOfDay))" })
        MetricGrid {
            fatigueCard
            sorenessCard
            stressCard
            caffeineCard
        }
        TomorrowCard(sessions: data.tomorrow)
        PageFootnote("睡前感受与今晚的睡眠会一起影响明天的身体准备度。明早记录醒后感受后，Pulse 会据此调整当天安排。")
    }

    private var checked: Bool { data.record?.hasEveningCheckIn == true }

    private var fatigueCard: some View {
        let f = data.record?.eveningFatigue
        return HealthMetricCard(title: "疲劳", icon: "battery.25percent", color: Theme.activity,
                                value: f.map { "\($0)" } ?? "—", unit: f == nil ? "" : "/ 5",
                                status: f.map { $0 >= 4 ? .attention("比较疲劳，今晚优先睡眠") : .good("疲劳可控") } ?? .neutral(checked ? "未填写" : "睡前记录后显示"))
    }

    private var sorenessCard: some View {
        let s = data.record?.eveningSoreness
        return HealthMetricCard(title: "酸痛", icon: "figure.cooldown", color: Theme.activity,
                                value: s.map { ["无", "轻微", "明显", "严重"][min(3, $0)] } ?? "—",
                                status: s.map { $0 >= 2 ? .attention("明天以轻松活动为主") : .good("不影响明天训练") } ?? .neutral(checked ? "未填写" : "睡前记录后显示"))
    }

    private var stressCard: some View {
        let st = data.record?.eveningStress
        return HealthMetricCard(title: "压力", icon: "brain.head.profile", color: Theme.mind,
                                value: st.map { "\($0)" } ?? "—", unit: st == nil ? "" : "/ 5",
                                status: st.map { $0 >= 4 ? .attention("睡前做 5 分钟慢呼吸") : .good("压力可控") } ?? .neutral(checked ? "未填写" : "睡前记录后显示"))
    }

    private var caffeineCard: some View {
        let r = data.record
        let cups = r?.caffeineCups ?? 0
        let cutoff = data.p.caffeineCutoffHour
        let status: MetricStatus = cups == 0 ? .good("今天没有咖啡因")
            : ((r?.lastCaffeineHour ?? 0) >= cutoff ? .attention("\(r!.lastCaffeineHour!):00 后仍有摄入") : .good("\(cutoff):00 前结束"))
        return HealthMetricCard(title: "咖啡因", icon: "cup.and.saucer.fill", color: Theme.nutrition,
                                time: r?.lastCaffeineHour.map { "最后 \($0):00" }, value: "\(cups)", unit: "杯", status: status)
    }
}

struct TonightHeroCard: View {
    let data: TodayData
    var onRecord: () -> Void

    var body: some View {
        let r = data.record
        let bed = r?.plannedBedtime?.minutesOfDay ?? data.window.bed.minutesOfDay
        let wake = r?.plannedWake?.minutesOfDay ?? data.window.nextWake.minutesOfDay
        let left = (bed - data.now.minutesOfDay + 1440) % 1440
        let window = Double((wake - bed + 1440) % 1440)
        VStack(alignment: .leading, spacing: Theme.Space.block) {
            CardTitle("今晚")
            HStack(alignment: .center, spacing: Theme.Space.block) {
                HeroIcon(icon: "moon.zzz.fill", color: Theme.sleep)
                VStack(alignment: .leading, spacing: Theme.Space.tight) {
                    Text("\(Clock.text(bed)) 前上床").font(.title3.weight(.semibold))
                    Text(left < 600 ? "还有 \(left / 60) 小时 \(left % 60) 分钟 · 计划 \(Clock.text(wake)) 起床" : "计划 \(Clock.text(wake)) 起床")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
            StatusLabel(status(window: window)).font(.subheadline)
            if let r, r.hasEveningCheckIn {
                HStack {
                    StatusLabel(text: "已完成睡前记录", icon: "checkmark.circle.fill", color: .green).font(.subheadline.weight(.semibold))
                    Spacer()
                    Button("修改", action: onRecord).buttonStyle(.bordered)
                }
                if !r.sleepPlanNote.isEmpty {
                    IconTextRow(icon: "text.quote", color: .secondary, title: "睡眠安排", text: r.sleepPlanNote)
                }
            } else {
                Button(action: onRecord) {
                    Label("睡前记录", systemImage: "moon.stars.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
                Text("约 1 分钟：疲劳、酸痛、压力和睡眠安排").font(.footnote).foregroundStyle(.secondary)
            }
        }
        .cardSurface()
    }

    private func status(window: Double) -> MetricStatus {
        let need = data.p.sleepNeedMinutes
        if data.readiness.level == .low || data.readiness.level == .rest, data.readiness.score != nil {
            return .attention("今天恢复偏弱，建议比平时早 30 分钟上床")
        }
        let hours = (window / 60).oneDecimal
        return window >= need ? .good("可睡 \(hours) 小时，满足 \((need / 60).oneDecimal) 小时的目标")
            : .attention("可睡 \(hours) 小时，少于目标 \((need / 60).oneDecimal) 小时")
    }
}

// MARK: - Tonight's recovery focus (includes sleep-breathing interventions)

struct RecoveryChecklistCard: View {
    @Bindable var record: DailyRecord
    let analytics: Analytics
    let readiness: ReadinessResult
    let tomorrow: [SessionSnapshot]

    var body: some View {
        let items = RecoveryAdvisor.bedtimeFocus(today: analytics.today, history: analytics.history, profile: analytics.profile,
                                                 readiness: readiness, tomorrow: tomorrow)
        let done = record.bedtimeDone.filter { id in items.contains { $0.id == id } }.count
        VStack(alignment: .leading, spacing: Theme.Space.item) {
            CardTitle(title: "今晚恢复重点") {
                Text("\(done)/\(items.count)").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary).monospacedDigit()
                    .accessibilityLabel("已完成 \(done) 项，共 \(items.count) 项")
            }
            // The checklist is its own block below the bar.
            ProgressBar(value: Double(done) / Double(max(1, items.count)), color: .green, height: 6)
                .padding(.bottom, Theme.Space.block - Theme.Space.item)
                .accessibilityHidden(true)
            ForEach(items) { item in
                let isDone = record.bedtimeDone.contains(item.id)
                ChecklistRow(done: isDone, title: item.title, detail: item.detail) {
                    if isDone { record.bedtimeDone.removeAll { $0 == item.id } } else { record.bedtimeDone.append(item.id) }
                }
                if item.id != items.last?.id { Divider().padding(.leading, ChecklistRow.textInset) }
            }
        }
        .cardSurface()
    }
}

struct TomorrowCard: View {
    let sessions: [SessionSnapshot]

    var body: some View {
        let trainings = sessions.filter { $0.kind.isTraining }
        VStack(alignment: .leading, spacing: Theme.Space.block) {
            CardTitle("明天")
            if trainings.isEmpty {
                IconTextRow(icon: "figure.walk", color: Theme.activity, title: sessions.first?.title ?? "日常活动日",
                            text: "没有训练安排，保持日常活动即可。")
            }
            ForEach(trainings) { s in
                IconTextRow(icon: s.kind.icon, color: Theme.activity, title: s.title,
                            text: "\(s.minutes) 分钟 · \(s.intensity.label)\(s.isKey ? " · 重点课" : "")")
            }
            IconTextRow(icon: "sun.horizon.fill", color: Theme.sleep, title: "明早",
                        text: "起床后记录醒后感受，Pulse 会按身体准备度确认或调整明天的安排。")
        }
        .cardSurface()
    }
}

// MARK: - 全天回顾

struct DayReviewView: View {
    @Bindable var record: DailyRecord
    let summary: DaySummary
    var onReview: () -> Void
    @State private var askAgent = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.block) {
            CardTitle(title: "今天的总结") {
                if record.reviewedAt != nil {
                    StatusLabel(text: "已回顾", icon: "checkmark.seal.fill", color: .green).font(.subheadline.weight(.semibold))
                }
            }
            IconTextRow(icon: "sunrise.fill", color: Theme.sleep, title: "晨起状态", text: summary.morning)
            IconTextRow(icon: "figure.run", color: Theme.activity, title: "日间运动", text: summary.activity)
            IconTextRow(icon: "heart.text.square.fill", color: Theme.heartData, title: "身体指标", text: summary.indicators)
            IconTextRow(icon: "moon.zzz.fill", color: Theme.mind, title: "睡前感受", text: summary.evening)
        }
        .cardSurface()

        VStack(alignment: .leading, spacing: Theme.Space.block) {
            CardTitle("今晚与明天的恢复安排")
            ForEach(Array(summary.arrangements.enumerated()), id: \.offset) { i, line in
                HStack(alignment: .top, spacing: Theme.Space.block) {
                    Text("\(i + 1)").font(.footnote.weight(.bold)).monospacedDigit()
                        .frame(width: 24, height: 24)
                        .background(Theme.subtle, in: Circle())
                    Text(line).font(.subheadline).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .cardSurface()

        VStack(alignment: .leading, spacing: Theme.Space.block) {
            CardTitle("今天的笔记")
            TextField("今天感觉如何？有什么影响了你的状态？", text: $record.dayNote, axis: .vertical)
                .focused($focused)
                .lineLimit(3...6)
                .padding(Theme.Space.block)
                .background(Theme.subtle.opacity(0.6), in: RoundedRectangle(cornerRadius: Theme.Radius.inner, style: .continuous))
            Button {
                record.reviewedAt = .app
                focused = false
            } label: {
                Label(record.reviewedAt == nil ? "完成回顾" : "更新回顾", systemImage: "checkmark").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).controlSize(.large)
        }
        .cardSurface()

        // A list of rows: each row has its own vertical padding, so the card adds the rest of its padding.
        VStack(spacing: 0) {
            Button { askAgent = true } label: {
                NavRowLabel(icon: "sparkles", color: .purple, title: AgentNameSettings.shared.phrase("问问"), detail: "今天的数据说明了什么、明天要注意什么")
                    .padding(.vertical, Theme.Space.item).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Divider().padding(.leading, Theme.Size.iconTile + Theme.Space.block)
            NavigationLink { HistoryView() } label: {
                NavRowLabel(icon: "clock.arrow.circlepath", title: "记录历史", detail: "补记或修改过去的记录")
                    .padding(.vertical, Theme.Space.item).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Divider().padding(.leading, Theme.Size.iconTile + Theme.Space.block)
            Button(action: onReview) {
                NavRowLabel(icon: "chart.line.uptrend.xyaxis", title: "本周复盘与长期复盘", detail: "查看行为与身体变化的关联")
                    .padding(.vertical, Theme.Space.item).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, Theme.Space.cardPadding)
        .padding(.vertical, Theme.Space.cardPadding - Theme.Space.item)
        .cardSurface(padding: 0)
        .sheet(isPresented: $askAgent) { HealthAgentChatView(initialQuestion: "总结一下今天，明天要注意什么？") }

        PageFootnote("每天的回顾会汇总进周复盘；持续记录后，回顾页会比较行为与身体变化之间的关联。")
    }
}
