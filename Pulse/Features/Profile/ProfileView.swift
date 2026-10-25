import SwiftUI
import SwiftData

struct ProfileView: View {
    @Environment(\.modelContext) private var ctx
    @Query private var profiles: [UserProfile]
    @Query private var meds: [MedicationEntry]
    @Query(sort: \DailyRecord.day) private var records: [DailyRecord]
    @Query(sort: \ActivitySession.start) private var sessions: [ActivitySession]
    @State private var pendingPersona: DemoPersona?

    var body: some View {
        NavigationStack {
            if let p = profiles.first {
                let a = Analytics(profile: p, medications: meds, records: records, sessions: sessions)
                List {
                    Section { headerCard(p, a) }
                        .listRowInsets(EdgeInsets()).listRowBackground(Color.clear)

                    Section {
                        link("基础信息", "person", Theme.body) { Form { BasicsSection(p: p) }.navigationTitle("基础信息").calmStyle() }
                        link("健康状况与用药", "cross.case", .pink) { Form { ConditionsSection(p: p); DietTargetsSection(p: p); MedicationsSection() }.navigationTitle("健康状况与用药").calmStyle() }
                        link("运动基础与生活节奏", "figure.walk", Theme.activity) { Form { ExerciseBaseSection(p: p); LifeConstraintsSection(p: p) }.navigationTitle("运动与生活节奏").calmStyle() }
                        link("改善方向与目标", "target", .blue) { Form { GoalsSection(p: p) }.navigationTitle("目标").calmStyle() }
                        link("静息心率基线", "heart.text.square", Theme.heartData) { BaselineView(profile: p, analytics: a) }
                        link("恢复目标", "moon.stars", Theme.sleep) { Form { HabitTargetsSection(p: p) }.navigationTitle("恢复目标").calmStyle() }
                        link("作息与倒班", "moon.haze", .indigo) { ShiftSettingsView(profile: p) }
                    } header: { Text("个人健康基础") }

                    Section {
                        ForEach(ProModule.allCases) { m in
                            HStack {
                                Toggle(isOn: Binding(get: { p.hasModule(m) }, set: { on in
                                    p.setModule(m, enabled: on)
                                    if m == .marathon && on && p.raceDate == nil { p.raceDate = p.targetDate ?? .app.adding(days: 140) }
                                    DataHub.regenerateWeekPlan(in: ctx)
                                })) {
                                    Label { VStack(alignment: .leading, spacing: 2) { Text(m.label); Text(m.subtitle).font(.caption).foregroundStyle(.secondary) } }
                                    icon: { Image(systemName: m.icon).foregroundStyle(m == .marathon ? Theme.activity : (m == .cardioCare ? Theme.heartData : Theme.glucose)) }
                                }
                            }
                            if p.hasModule(m) {
                                NavigationLink {
                                    switch m {
                                    case .marathon: MarathonView()
                                    case .cardioCare: CardioCareView()
                                    case .diabetesCare: DiabetesCareView()
                                    }
                                } label: { Text("打开\(m.label)").font(.subheadline).foregroundStyle(Theme.accent) }
                            }
                        }
                    } header: { Text("按需启用的专业支持") } footer: {
                        Text("专业支持用于配合教练或医生的个人要求，不替代专业评估与照护。")
                    }

                    Section {
                        link("数据来源", "applewatch", .gray) { DataSourcesView(profile: p) }
                        link("记录历史与补充修改", "clock.arrow.circlepath", .gray) { HistoryView() }
                        link("隐私与数据导出", "lock.shield", .blue) { DataPrivacyView() }
                    } header: { Text("我的数据") }

                    Section {
                        link("云端模型（测试）", "cloud", .gray) { CloudModelSettingsView() }
                    } header: { Text("实验功能") } footer: {
                        Text(CloudModelSettings.shared.isActive ? "Health Agent 正在使用云端模型，提问时会发送数据摘要。" : "默认关闭。开启前，Health Agent 的所有分析都在本机完成。")
                    }

                    Section {
                        ForEach(DemoPersona.allCases) { persona in
                            Button { pendingPersona = persona } label: {
                                HStack(spacing: 12) {
                                    Text(String(persona.name.prefix(1)))
                                        .font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                                        .frame(width: 32, height: 32).background(Color.gray.gradient, in: Circle())
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(persona.name).foregroundStyle(.primary)
                                        Text(persona.summary).font(.footnote).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if p.usesDemoData && (p.demoPersona == persona.rawValue || (p.demoPersona.isEmpty && persona == .xiaolin)) {
                                        Text("当前").font(.footnote).foregroundStyle(.secondary)
                                    }
                                }
                                .frame(minHeight: 44)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                        if p.usesDemoData {
                            NavigationLink { DemoTimeView() } label: {
                                LabeledContent("演示时间", value: DemoClock.isShifted ? Date.app.formatted(.dateTime.month().day().hour().minute()) : "实际时间")
                            }
                        }
                    } header: { Text("示例用户") } footer: {
                        Text("每位示例用户包含 120 天的模拟记录。陈杰、林悦、王建国的健康情况一般、计划遵从性较差，可用来查看 Pulse 和 Health Agent 如何应对。载入会替换当前所有记录。")
                    }
                    Section {
                        Disclaimer().listRowBackground(Color.clear)
                    }
                }
                .navigationTitle("我的")
                .confirmationDialog("载入「\(pendingPersona?.name ?? "")」的示例数据会替换当前所有记录。",
                                    isPresented: Binding(get: { pendingPersona != nil }, set: { if !$0 { pendingPersona = nil } }),
                                    titleVisibility: .visible, presenting: pendingPersona) { persona in
                    Button("载入示例数据", role: .destructive) {
                        DemoDataGenerator.populate(ctx, persona: persona)
                        DataHub.ensureWeekPlan(in: ctx)
                        try? ctx.save()
                    }
                }
            }
        }
    }

    private func link<D: View>(_ title: String, _ icon: String, _ color: Color, @ViewBuilder destination: @escaping () -> D) -> some View {
        NavigationLink(destination: destination) {
            Label { Text(title) } icon: {
                Image(systemName: icon).foregroundStyle(.white).font(.caption.weight(.semibold))
                    .frame(width: 28, height: 28).background(color, in: RoundedRectangle(cornerRadius: 7))
            }
        }
    }

    private func headerCard(_ p: UserProfile, _ a: Analytics) -> some View {
        Card {
            HStack(spacing: 14) {
                Text(String(p.displayName.prefix(1)))
                    .font(.title.bold()).foregroundStyle(.white)
                    .frame(width: 58, height: 58).background(Color.gray.gradient, in: Circle())
                VStack(alignment: .leading, spacing: 3) {
                    Text(p.displayName).font(.title3.bold())
                    Text("\(p.age) 岁 · \(p.sex.label) · BMI \(String(format: "%.1f", p.bmi)) · \(p.activityLevel.label)")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            MetricRow {
                MetricTile(label: "基线", value: a.trend.baseline.map { $0.noDecimal } ?? "—", unit: "bpm", icon: "flag", color: Theme.heartData)
                MetricTile(label: "近 4 周", value: a.trend.avg28.map { $0.noDecimal } ?? "—", unit: "bpm", icon: "calendar", color: Theme.heartData)
                MetricTile(label: "每周可用", value: "\(p.weeklyTimeBudget)", unit: "分钟", icon: "clock", color: .green)
            }
            FlowLayout(spacing: 6) {
                ForEach(Array(p.goals).sorted { $0.rawValue < $1.rawValue }) { Chip(text: $0.label, icon: $0.icon, color: .orange) }
                ForEach(Array(p.conditions).sorted { $0.rawValue < $1.rawValue }) { Chip(text: $0.label, icon: "cross.case", color: .gray) }
                ForEach(p.extraConditionsRaw, id: \.self) { Chip(text: ConditionLibrary.resolve($0).name, icon: "cross.case", color: .gray) }
                if p.fluidLimit { Chip(text: "限水 \(p.waterTargetMl) ml", icon: "drop", color: .gray) }
                ForEach(meds.filter(\.isActive)) { Chip(text: $0.name, icon: "pills", color: .gray) }
            }
            if !p.goalNote.isEmpty { Text("“\(p.goalNote)”").font(.subheadline).foregroundStyle(.secondary) }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Baseline

struct BaselineView: View {
    @Environment(\.modelContext) private var ctx
    @Bindable var profile: UserProfile
    let analytics: Analytics

    var body: some View {
        let t = analytics.trend
        let recent = t.points.filter { $0.day > Date.app.adding(days: -14) }
        let recentMedian = recent.count >= 7 ? Stats.median(recent.map(\.value)) : nil
        Form {
            Section {
                LabeledContent("当前基线", value: profile.baselineRHR.map { "\($0.oneDecimal) bpm" } ?? "尚未建立")
                if let d = profile.baselineSetAt { LabeledContent("建立时间", value: d.formatted(date: .abbreviated, time: .omitted)) }
                LabeledContent("方式", value: profile.baselineIsManual ? "手动设定" : "自动（前 14 天中位数）")
                LabeledContent("比较所用测量方式", value: t.dominantSource?.label ?? "—")
            } footer: {
                Text("基线是你自己的参照点，用于判断变化方向，不代表「正常」或「理想」值。")
            }
            Section("测量方式") {
                Picker("主要来源", selection: Binding(get: { profile.rhrMethod }, set: { profile.rhrMethod = $0 })) {
                    ForEach(RHRSource.allCases) { Text($0.label).tag($0) }
                }
                Text("改变测量方式后，前后数值不宜直接比较。建议以新方式记录 2 周后重新建立基线。").font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                if let m = recentMedian {
                    Button("以最近 14 天重新建立基线（\(m.oneDecimal) bpm）") {
                        profile.baselineRHR = m.rounded(to: 0.5)
                        profile.baselineSetAt = .app
                        profile.baselineIsManual = false
                    }
                }
                Stepper("手动设定 \(profile.baselineRHR.map { $0.oneDecimal } ?? "—") bpm",
                        onIncrement: { profile.baselineRHR = (profile.baselineRHR ?? 65) + 0.5; profile.baselineIsManual = true; profile.baselineSetAt = .app },
                        onDecrement: { profile.baselineRHR = (profile.baselineRHR ?? 65) - 0.5; profile.baselineIsManual = true; profile.baselineSetAt = .app })
                Button("清除基线，自动重新建立", role: .destructive) {
                    profile.baselineRHR = nil
                    profile.baselineSetAt = nil
                    DataHub.updateBaselineIfNeeded(in: ctx)
                }
            } header: {
                Text("重新建立")
            } footer: {
                Text("在开始或停用影响心率的药物、病愈后、或测量方式改变后，重新建立基线能让后续比较更有意义。")
            }
        }
        .navigationTitle("静息心率基线").calmStyle()
    }
}

// MARK: - Data sources

struct DataSourcesView: View {
    @Environment(\.modelContext) private var ctx
    @Bindable var profile: UserProfile
    private var hk: HealthKitService { HealthKitService.shared }

    var body: some View {
        Form {
            Section {
                Toggle("使用健康 App 数据", isOn: Binding(get: { profile.useHealthKit }, set: { on in
                    profile.useHealthKit = on
                    if on { Task { try? await hk.requestAuthorization(); await hk.sync(into: ctx) } }
                }))
                .disabled(!hk.isAvailable)
                if profile.useHealthKit {
                    Button {
                        Task { await hk.sync(into: ctx) }
                    } label: {
                        HStack {
                            Label("立即同步近 60 天", systemImage: "arrow.triangle.2.circlepath")
                            Spacer()
                            if hk.isSyncing { ProgressView() }
                        }
                    }
                    .disabled(hk.isSyncing)
                    if let last = profile.lastSync {
                        LabeledContent("上次同步", value: last.formatted(date: .abbreviated, time: .shortened))
                    }
                    if let msg = hk.lastMessage { Text(msg).font(.caption).foregroundStyle(.secondary) }
                }
            } header: {
                Text("智能手表 / 手环 / CGM")
            } footer: {
                Text(hk.isAvailable
                     ? "读取 Apple Watch 等设备写入健康 App 的静息心率、HRV、睡眠、活动、血氧、血压、血糖（含 CGM）等。Pulse 只读取，不会写入。权限可随时在「设置 › 健康 › 数据访问与设备」中修改。"
                     : "此设备不支持健康数据，可使用手动记录。")
            }
            Section {
                Label("晨起手动测量静息心率", systemImage: "hand.point.up.left")
                Label("手动补记睡眠、运动、血压、血糖", systemImage: "square.and.pencil")
                Label("快速记录饮食、饮酒、压力等背景", systemImage: "tag")
            } header: {
                Text("没有设备时")
            } footer: {
                Text("缺少设备时，仍然可以完成基本记录、准备度评估（基于主观感受）与回顾。手动修改的数值不会被设备同步覆盖。")
            }
            Section("如何选择") {
                BulletText(text: "只关注静息心率与睡眠：一块可整晚佩戴的手表即可。")
                BulletText(text: "血糖管理：CGM 能提供连续血糖与达标时间，比指尖血糖更适合回顾。")
                BulletText(text: "高血压 / 心血管健康：经过验证的上臂式血压计。")
                BulletText(text: "专项训练：胸带心率更准确；乳酸测试需专业人员与标准化条件。")
            }
            Section {
                AgentAskButton(title: "按我的训练指导设备使用", question: "根据我的训练，手表和 CGM 怎么用更准？")
            } footer: {
                Text("Health Agent 会结合你的训练内容和近期数据的完整度，给出佩戴与设置建议；开启云端模型时由云端模型生成个性化指导。")
            }
        }
        .navigationTitle("数据来源").calmStyle()
    }
}
