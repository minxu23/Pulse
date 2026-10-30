import SwiftUI
import SwiftData
import Charts

/// 改善睡眠并跟进睡眠呼吸问题 (需求 6). Device signals and self-reported cues are kept
/// separate from diagnosis; diagnosed users track ongoing treatment and care.
struct SleepCareView: View {
    @Environment(\.modelContext) private var ctx
    @Query private var profiles: [UserProfile]
    @Query private var meds: [MedicationEntry]
    @Query(sort: \DailyRecord.day) private var records: [DailyRecord]
    @Query(sort: \ActivitySession.start) private var sessions: [ActivitySession]
    @Query(sort: \CareTask.createdAt, order: .reverse) private var tasks: [CareTask]
    @State private var logSleep = false
    @State private var addTask = false
    @State private var exportURL: URL?

    var body: some View {
        let a = Analytics(profile: profiles.first, medications: meds, records: records, sessions: sessions)
        let s = SleepAnalyzer.summary(days: a.days, profile: a.profile)
        let cues = SleepAnalyzer.breathingCues(days: a.days)
        ScreenScroll {
            if let p = profiles.first {
                summaryCard(s, a)
                chartCard(a)
                tipsCard(s, a)
                breathingCard(cues, p)
                if p.apneaStatus == .diagnosed { treatmentCard(p, a) }
                sleepTasksCard
            }
        }
        .sheet(isPresented: $logSleep) { QuickLogSheet(kind: .sleep) }
        .sheet(isPresented: $addTask) { AddCareTaskSheet(defaultTitle: "睡眠门诊评估", area: .sleep) }
    }

    private func summaryCard(_ s: SleepSummary, _ a: Analytics) -> some View {
        Card {
            CardHeader(title: "近 14 晚", subtitle: s.regularityText, icon: "bed.double.fill", color: Theme.sleep) {
                Button { logSleep = true } label: {
                    Text("补记睡眠").frame(minHeight: Theme.Size.tap).contentShape(Rectangle())
                }
                .font(.subheadline)
            }
            MetricRow {
                MetricTile(label: "平均睡眠", value: s.avgMinutes.map { ($0 / 60).oneDecimal } ?? "—", unit: "小时", icon: "moon", color: Theme.sleep,
                           footnote: "目标 \((a.profile.sleepNeedMinutes / 60).oneDecimal) 小时")
                MetricTile(label: "平均入睡", value: s.avgBedtime.map(Clock.text) ?? "—", icon: "clock", color: Theme.sleep,
                           footnote: "目标 \(Clock.text(a.profile.bedtimeMinutes))")
                MetricTile(label: "睡够的夜晚", value: "\(s.nightsMeetingNeed)", unit: "/ \(s.nights)", icon: "checkmark.circle", color: .green,
                           footnote: "共 \(s.nights) 晚")
            }
        }
    }

    private func chartCard(_ a: Analytics) -> some View {
        let nights = a.days.filter { $0.day > Date.app.adding(days: -21) }.compactMap { d in d.sleepMinutes.map { (d.day, $0 / 60) } }
        return Card {
            CardHeader(title: "睡眠时长", subtitle: "近 3 周", icon: "chart.bar", color: Theme.sleep)
            if nights.isEmpty {
                EmptyHint(icon: "moon.zzz", text: "佩戴设备入睡，或手动补记睡眠。")
            } else {
                Chart {
                    RuleMark(y: .value("目标", a.profile.sleepNeedMinutes / 60))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4])).foregroundStyle(Color.gray)
                    ForEach(nights, id: \.0) { n in
                        BarMark(x: .value("日期", n.0, unit: .day), y: .value("小时", n.1))
                            .foregroundStyle(n.1 >= a.profile.sleepNeedMinutes / 60 - 0.5 ? Theme.sleep : Theme.sleep.opacity(0.45))
                            .cornerRadius(3)
                    }
                }
                .frame(height: 150)
            }
        }
    }

    private func tipsCard(_ s: SleepSummary, _ a: Analytics) -> some View {
        var tips: [String] = []
        if (s.bedtimeSD ?? 0) > 45 { tips.append("入睡时间波动较大：先固定起床时间（包括周末），再逐步把上床时间稳定下来。") }
        if let avg = s.avgMinutes, avg < a.profile.sleepNeedMinutes - 30 { tips.append("平均睡眠少于目标：可以每周把上床时间提前 15 分钟，直到睡够。") }
        let late = a.days.suffix(14).filter { $0.lateCaffeine(cutoff: a.profile.caffeineCutoffHour) }.count
        if late >= 3 { tips.append("近两周有 \(late) 天在 \(a.profile.caffeineCutoffHour) 点后摄入咖啡因，可能影响入睡。") }
        let alcohol = a.days.suffix(14).filter(\.hadAlcohol).count
        if alcohol >= 3 { tips.append("饮酒会让睡眠变浅、夜间心率升高，近两周饮酒 \(alcohol) 天。") }
        tips.append("睡前 1 小时调暗灯光、放下工作；卧室保持凉爽、安静、黑暗。")
        tips.append("白天接触自然光、规律运动有助于夜间入睡，但睡前 2 小时内避免剧烈运动。")
        return Card {
            CardHeader(title: "作息与睡眠习惯", icon: "sparkles", color: .yellow)
            ForEach(tips, id: \.self) { BulletText(text: $0) }
        }
    }

    private func breathingCard(_ c: BreathingCues, _ p: UserProfile) -> some View {
        let color: Color = c.level == .notable ? .orange : (c.level == .some ? .yellow : .green)
        return Card {
            CardHeader(title: "睡眠呼吸", subtitle: p.apneaStatus.label, icon: "lungs.fill", color: Theme.respiratory) {
                Chip(text: c.level.label, color: color)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Theme.Space.item), count: 3), spacing: Theme.Space.item) {
                cueTile("打鼾", c.snoring, "zzz")
                cueTile("憋醒", c.gasping, "exclamationmark.bubble")
                cueTile("被观察到暂停", c.witnessed, "eye")
                cueTile("晨起头痛", c.headache, "brain.head.profile")
                cueTile("白天困倦", c.sleepy, "cup.and.saucer")
                cueTile("血氧 <88%", c.lowSpO2Nights, "lungs")
            }
            Text("近 30 天记录 \(c.nightsObserved) 晚。\(c.message)").font(.subheadline)
            if p.apneaStatus != .diagnosed {
                NavigationLink { StopBangView(profile: p) } label: {
                    HStack {
                        Label(p.stopBangAnswers.count == 8 ? "STOP-BANG 自评：\(SleepAnalyzer.stopBang(p.stopBangAnswers).score)/8（\(SleepAnalyzer.stopBang(p.stopBangAnswers).risk)）" : "完成 STOP-BANG 自评（1 分钟）",
                              systemImage: "checklist")
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                    }
                    .font(.subheadline)
                    .frame(minHeight: Theme.Size.tap)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if c.level == .notable || p.apneaStatus == .suspected || (p.stopBangAnswers.count == 8 && SleepAnalyzer.stopBang(p.stopBangAnswers).score >= 3) {
                    Callout(kind: .info, title: "获得专业评估",
                            text: "睡眠呼吸暂停的诊断需要专业评估，通常包括问诊和睡眠监测（家庭睡眠监测或医院多导睡眠图）。可以到睡眠门诊、呼吸科或耳鼻喉科就诊，并带上 Pulse 生成的就诊摘要。")
                    HStack {
                        Button { addTask = true } label: { Label("添加就诊事项", systemImage: "calendar.badge.plus") }
                            .buttonStyle(.bordered)
                        Spacer()
                        Button {
                            exportURL = try? DataExporter.clinicianSummary(ctx, categories: [.profile, .sleep, .heart, .medications, .vitals])
                        } label: { Label("生成就诊摘要", systemImage: "doc.text") }
                            .buttonStyle(.bordered)
                    }
                    if let url = exportURL {
                        ShareLink(item: url) {
                            Label("分享 / 保存摘要", systemImage: "square.and.arrow.up")
                                .frame(minHeight: Theme.Size.tap).contentShape(Rectangle())
                        }
                        .font(.subheadline)
                    }
                }
            }
            Picker("我的状态", selection: Binding(get: { p.apneaStatus }, set: { p.apneaStatus = $0 })) {
                ForEach(ApneaStatus.allCases) { Text($0.label).tag($0) }
            }
            .font(.subheadline)
            Text("设备的呼吸紊乱、血氧信号和自述线索只能提示可能性，不能代替专业诊断。").font(.footnote).foregroundStyle(.secondary)
        }
    }

    private func cueTile(_ title: String, _ count: Int, _ icon: String) -> some View {
        VStack(spacing: Theme.Space.tight) {
            Image(systemName: icon).font(.caption).foregroundStyle(count > 0 ? .orange : .secondary)
            Text("\(count)").font(.headline).monospacedDigit()
            Text(title).font(.caption).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
        .padding(Theme.Space.block)
        .background(Theme.subtle.opacity(0.6), in: RoundedRectangle(cornerRadius: Theme.Radius.inner, style: .continuous))
    }

    private func treatmentCard(_ p: UserProfile, _ a: Analytics) -> some View {
        let recent = a.days.filter { $0.day > Date.app.adding(days: -30) }
        let used = recent.compactMap { d in d.cpapHours.map { (d.day, $0) } }
        let adherent = used.filter { $0.1 >= p.cpapTargetHours }.count
        return Card {
            CardHeader(title: "治疗跟进", subtitle: p.apneaTreatment.label, icon: "cross.case", color: Theme.respiratory)
            Picker("当前治疗", selection: Binding(get: { p.apneaTreatment }, set: { p.apneaTreatment = $0 })) {
                ForEach(ApneaTreatment.allCases) { Text($0.label).tag($0) }
            }
            if p.apneaTreatment == .cpap {
                MetricRow {
                    MetricTile(label: "达标夜晚 · ≥\(Int(p.cpapTargetHours)) 小时", value: "\(adherent)", unit: "/ \(used.count)", icon: "checkmark.circle", color: .green)
                    MetricTile(label: "平均使用", value: Stats.mean(used.map(\.1)).map { $0.oneDecimal } ?? "—", unit: "小时", icon: "clock", color: Theme.respiratory)
                }
                if !used.isEmpty {
                    Chart {
                        RuleMark(y: .value("目标", p.cpapTargetHours)).lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3])).foregroundStyle(Color.gray)
                        ForEach(used, id: \.0) { u in
                            BarMark(x: .value("日期", u.0, unit: .day), y: .value("小时", u.1)).foregroundStyle(Theme.respiratory)
                        }
                    }
                    .frame(height: 110)
                }
                Text("在晨起感受中记录每晚使用时长。面罩不适、漏气、口干等问题，请与睡眠医生或设备服务方沟通调整，而不是自行停用。")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Text("持续治疗后，可留意白天精力、血压与静息心率是否有变化，并在复诊时与医生讨论。").font(.subheadline).foregroundStyle(.secondary)
        }
    }

    private var sleepTasksCard: some View {
        let list = tasks.filter { $0.area == .sleep }
        return Card {
            CardHeader(title: "睡眠照护事项", subtitle: "复诊、检查、设备耗材更换等", icon: "list.clipboard") {
                Button { addTask = true } label: {
                    Image(systemName: "plus.circle").font(.title3)
                        .frame(width: Theme.Size.tap, height: Theme.Size.tap).contentShape(Rectangle())
                }
                .accessibilityLabel("添加睡眠照护事项")
            }
            if list.isEmpty { Text("暂无事项").font(.subheadline).foregroundStyle(.secondary) }
            ForEach(list) { CareTaskRow(task: $0) }
        }
    }
}

struct StopBangView: View {
    @Bindable var profile: UserProfile
    @Query private var meds: [MedicationEntry]
    @State private var answers: [Bool] = []

    var body: some View {
        let result = SleepAnalyzer.stopBang(answers)
        Form {
            Section {
                ForEach(SleepAnalyzer.stopBangQuestions) { q in
                    if q.id < answers.count {
                        Toggle(isOn: $answers[q.id]) {
                            HStack(alignment: .top, spacing: Theme.Space.item) {
                                Text(q.letter).font(.headline).foregroundStyle(.secondary).frame(width: 18)
                                VStack(alignment: .leading, spacing: Theme.Space.hairline) {
                                    Text(q.text).font(.subheadline)
                                    if q.autoDerived { Text("已根据档案预填").font(.caption).foregroundStyle(.secondary) }
                                }
                            }
                        }
                    }
                }
            } footer: {
                Text("STOP-BANG 是常用的阻塞性睡眠呼吸暂停筛查问卷，只用于判断是否需要进一步评估，不能用于诊断。")
            }
            Section("结果") {
                HStack {
                    Text("\(result.score) / 8").font(.title2.bold()).monospacedDigit()
                    Spacer()
                    Chip(text: result.risk, color: result.score >= 5 ? .red : (result.score >= 3 ? .orange : .green), filled: true)
                }
                Text(result.advice).font(.subheadline)
            }
            Section {
                Button("保存结果") {
                    profile.stopBangAnswers = answers
                    profile.stopBangDate = .app
                    if result.score >= 3 && profile.apneaStatus == .unknown { profile.apneaStatus = .suspected }
                    if result.score <= 2 && profile.apneaStatus == .unknown { profile.apneaStatus = .lowConcern }
                }
            }
        }
        .navigationTitle("STOP-BANG 自评").calmStyle()
        .onAppear {
            if answers.isEmpty {
                let defaults = SleepAnalyzer.stopBangDefaults(profile: profile.snapshot(medications: meds))
                answers = profile.stopBangAnswers.count == 8 ? profile.stopBangAnswers : defaults
            }
        }
    }
}
