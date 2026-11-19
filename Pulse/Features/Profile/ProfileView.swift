import SwiftUI
import SwiftData

struct ProfileView: View {
    @Environment(\.modelContext) private var ctx
    @Query private var profiles: [UserProfile]
    @Query private var meds: [MedicationEntry]
    @Query(sort: \DailyRecord.day) private var records: [DailyRecord]
    @Query(sort: \ActivitySession.start) private var sessions: [ActivitySession]
    @State private var pendingPersona: DemoPersona?
    @State private var renamingAgent = false
    @AppStorage(CareReminders.enabledKey) private var careReminders = false
    @AppStorage(CareReminders.eventsKey) private var eventReminders = false
    @State private var remindersDenied = false

    var body: some View {
        NavigationStack {
            if let p = profiles.first {
                let a = Analytics(profile: p, medications: meds, records: records, sessions: sessions)
                List {
                    Section { headerCard(p, a) }
                        .listRowInsets(EdgeInsets()).listRowBackground(Color.clear)

                    Section {
                        link("方案与历史报告", "doc.text", .teal) { ProgramHistoryView() }
                        link("基础信息", "person", Theme.body) { Form { BasicsSection(p: p) }.navigationTitle("基础信息").calmStyle() }
                        link("健康状况与用药", "cross.case", .pink) { Form { ConditionsSection(p: p); DietTargetsSection(p: p); if p.conditions.contains(.ckd) || p.dialysis { DialysisSection(p: p) }; MedicationsSection() }.navigationTitle("健康状况与用药").calmStyle() }
                        link("运动基础与生活节奏", "figure.walk", Theme.activity) { Form { ExerciseBaseSection(p: p); LifeConstraintsSection(p: p) }.navigationTitle("运动与生活节奏").calmStyle() }
                        link("改善方向与目标", "target", .blue) { UsageDirectionView(profile: p) }
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
                                    Label { VStack(alignment: .leading, spacing: Theme.Space.hairline) { Text(m.label); Text(m.subtitle).font(Theme.TypeScale.body).foregroundStyle(.secondary) } }
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
                                } label: { Text("打开\(m.label)").font(Theme.TypeScale.body).foregroundStyle(Theme.accent) }
                            }
                        }
                    } header: { Text("专项管理") }

                    Section {
                        link("数据来源", "applewatch", .gray) { DataSourcesView(profile: p) }
                        link("记录历史与补充修改", "clock.arrow.circlepath", .gray) { HistoryView() }
                        link("隐私与数据导出", "lock.shield", .blue) { DataPrivacyView() }
                    } header: { Text("我的数据") }

                    Section {
                        Toggle(isOn: Binding(get: { careReminders }, set: { on in
                            guard on else { careReminders = false; CareReminders.sync(in: ctx); return }
                            Task {
                                let ok = await CareReminders.requestPermission()
                                careReminders = ok
                                remindersDenied = !ok
                                CareReminders.sync(in: ctx)
                                BackgroundCheck.schedule()
                            }
                        })) {
                            Label {
                                setting("到期提醒", "复查、复诊提前一周和当天早上提醒")
                            } icon: { tileIcon("bell", .red) }
                        }
                        Toggle(isOn: Binding(get: { eventReminders }, set: { on in
                            guard on else { eventReminders = false; return }
                            Task {
                                let ok = await CareReminders.requestPermission()
                                eventReminders = ok
                                remindersDenied = !ok
                                BackgroundCheck.schedule()
                            }
                        })) {
                            Label {
                                setting("异常提醒", "读数需要联系医生时通知你")
                            } icon: { tileIcon("exclamationmark.triangle", .orange) }
                        }
                        if remindersDenied {
                            Button("去系统设置允许通知") {
                                if let url = URL(string: UIApplication.openNotificationSettingsURLString) { UIApplication.shared.open(url) }
                            }
                        }
                    } header: { Text("提醒") } footer: {
                        Text(remindersDenied ? "通知被关掉了：在「设置 › 通知 › Pulse」里允许后再打开。" : "提醒在本机完成，不经过网络。异常提醒不能代替急救。")
                    }

                    Section {
                        Button { renamingAgent = true } label: {
                            LabeledContent {
                                Text(AgentNameSettings.shared.name)
                            } label: {
                                Label { Text("名字") } icon: { tileIcon("sparkles", .purple) }
                            }
                        }
                        // A settings row, not a blue action: the name shows on the right, the dialog edits it.
                        .tint(.primary)
                        link("回答方式与云端模型", "cloud", .gray) { CloudModelSettingsView() }
                    } header: { Text("Health Agent") } footer: {
                        switch CloudModelSettings.shared.effectiveMode {
                        case .cloud: Text("正在使用「全部云端」：提问时会发送数据摘要，姓名、电话等先在本机去掉。")
                        case .hybrid: Text(CloudModelSettings.shared.consented
                                           ? "正在使用「端云结合」：本机分析后，去掉姓名、电话等再发到云端写回答，在本机拼成完整回答。"
                                           : "正在使用「端云结合」：涉及你记录的问题在本机回答，通用问题只把问题原文发到云端。")
                        case .onDevice: Text(AgentNameSettings.shared.phrase("正在使用「仅本机」：", "的所有分析都在本机完成。"))
                        }
                    }

                    if DataStores.shared.testingEnabled {
                    Section {
                        if DataStores.shared.mode == .sample {
                            Button {
                                DataStores.shared.exitTesting()
                            } label: {
                                Label("回到我自己的数据", systemImage: "person.crop.circle.badge.checkmark")
                                    .frame(minHeight: Theme.Size.tap)
                            }
                        }
                        ForEach(DemoPersona.allCases) { persona in
                            Button { pendingPersona = persona } label: {
                                HStack(spacing: Theme.Space.block) {
                                    Text(String(persona.name.prefix(1)))
                                        .font(Theme.TypeScale.body.weight(.semibold)).foregroundStyle(.white)
                                        .frame(width: Theme.Size.iconTile, height: Theme.Size.iconTile).background(Color.gray.gradient, in: Circle())
                                    VStack(alignment: .leading, spacing: Theme.Space.hairline) {
                                        Text(persona.name).foregroundStyle(.primary)
                                        Text(persona.summary).font(Theme.TypeScale.body).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if p.usesDemoData && (p.demoPersona == persona.rawValue || (p.demoPersona.isEmpty && persona == .xiaolin)) {
                                        Text("当前").font(Theme.TypeScale.body).foregroundStyle(.secondary)
                                    }
                                }
                                .frame(minHeight: Theme.Size.tap)
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
                        Text("示例数据和你自己的记录分开保存，随时可以回来。")
                    }
                    }
                    Section {
                        NavigationLink("关于 Pulse") { TestingAccessView() }
                        Disclaimer().listRowBackground(Color.clear)
                    }
                }
                .navigationTitle("我的")
                // Small titles, as on every tab; pages opened from here inherit it.
                .navigationBarTitleDisplayMode(.inline)
                .agentRenameAlert(isPresented: $renamingAgent)
                .confirmationDialog(DataStores.shared.mode == .own
                                        ? "载入「\(pendingPersona?.name ?? "")」的示例数据？示例数据单独保存，你自己的记录不受影响，随时可以在这里回来。"
                                        : "载入「\(pendingPersona?.name ?? "")」的示例数据，替换当前的示例用户。",
                                    isPresented: Binding(get: { pendingPersona != nil }, set: { if !$0 { pendingPersona = nil } }),
                                    titleVisibility: .visible, presenting: pendingPersona) { persona in
                    Button("载入示例数据") {
                        // Into the sample store: your own records stay where they are.
                        DataStores.shared.use(.sample)
                        let c = DataStores.shared.container.mainContext
                        DemoDataGenerator.populate(c, persona: persona)
                        // Another person's sample data: the conversation was about someone else.
                        AgentConversation.shared.clear()
                        DataHub.ensureWeekPlan(in: c)
                        try? c.save()
                    }
                }
            }
        }
    }

    private func link<D: View>(_ title: String, _ icon: String, _ color: Color, @ViewBuilder destination: @escaping () -> D) -> some View {
        NavigationLink(destination: destination) {
            Label { Text(title) } icon: { tileIcon(icon, color) }
        }
    }

    /// A switch's name with what it does underneath, so the section needs no long footer.
    private func setting(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.hairline) {
            Text(title)
            Text(detail).font(Theme.TypeScale.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, Theme.Space.tight)
    }

    private func tileIcon(_ icon: String, _ color: Color) -> some View {
        Image(systemName: icon).foregroundStyle(.white).font(Theme.TypeScale.body.weight(.semibold))
            // Settings-style 28 pt square: the List aligns its separators to it.
            .frame(width: 28, height: 28).background(color, in: RoundedRectangle(cornerRadius: Theme.Radius.tile(28), style: .continuous))
    }

    private func headerCard(_ p: UserProfile, _ a: Analytics) -> some View {
        Card {
            HStack(spacing: Theme.Space.block) {
                Text(String(p.displayName.prefix(1)))
                    .font(Theme.TypeScale.title.bold()).foregroundStyle(.white)
                    .frame(width: Theme.Size.hero, height: Theme.Size.hero).background(Color.gray.gradient, in: Circle())
                VStack(alignment: .leading, spacing: Theme.Space.hairline) {
                    Text(p.displayName).font(Theme.TypeScale.title.bold())
                    Text(p.basicsSummary + " · " + p.activityLevel.label)
                        .font(Theme.TypeScale.body).foregroundStyle(.secondary)
                }
            }
            MetricRow {
                MetricTile(label: "基线", value: a.trend.baseline.map { $0.noDecimal } ?? "—", unit: "bpm")
                MetricTile(label: "近 4 周", value: a.trend.avg28.map { $0.noDecimal } ?? "—", unit: "bpm")
                MetricTile(label: "每周可用", value: "\(p.weeklyTimeBudget)", unit: "分钟")
            }
            FlowLayout(spacing: Theme.Space.item) {
                ForEach(Array(p.goals).sorted { $0.rawValue < $1.rawValue }) { Chip(text: $0.label, icon: $0.icon, color: .orange) }
                ForEach(Array(p.conditions).sorted { $0.rawValue < $1.rawValue }) { Chip(text: $0.label, icon: "cross.case", color: .gray) }
                ForEach(p.extraConditionsRaw, id: \.self) { Chip(text: ConditionLibrary.resolve($0).name, icon: "cross.case", color: .gray) }
                if p.fluidLimit { Chip(text: "限水 \(p.waterTargetMl) ml", icon: "drop", color: .gray) }
                ForEach(meds.filter(\.isActive)) { Chip(text: $0.name, icon: "pills", color: .gray) }
            }
            if !p.goalNote.isEmpty { Text("“\(p.goalNote)”").font(Theme.TypeScale.body).foregroundStyle(.secondary) }
        }
        .padding(.vertical, Theme.Space.tight)
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
                Text("基线是你自己的参照点，用来看变化方向，不代表「正常」或「理想」。")
            }
            Section("测量方式") {
                Picker("主要来源", selection: Binding(get: { profile.rhrMethod }, set: { profile.rhrMethod = $0 })) {
                    ForEach(RHRSource.allCases) { Text($0.label).tag($0) }
                }
                Text("换了测量方式，前后数值不好直接比；用新方式记 2 周后重新建立基线。").font(Theme.TypeScale.body).foregroundStyle(.secondary)
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
                Text("换药、病好以后或换了测量方式，都适合重新建立基线。")
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
                    if on { Task { try? await hk.requestAuthorization(); await hk.sync(into: ctx); hk.watchForReadings() } }
                    else { hk.watchForReadings() }
                }))
                .disabled(!hk.isAvailable || profile.usesDemoData)
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
                    // Whether Health is read while Pulse is closed: the way to check it on the phone.
                    let bg = BackgroundCheck.lastRead
                    LabeledContent("最近一次后台读取", value: bg.map { $0.date.formatted(date: .abbreviated, time: .shortened) + ($0.newReading ? " · 有新读数" : " · 定时检查") } ?? "还没有")
                    if let bg, !bg.ok {
                        Text("那次手机锁着读不到，解锁后会补上。").font(Theme.TypeScale.body).foregroundStyle(.secondary)
                    }
                    if let msg = hk.lastMessage { Text(msg).font(Theme.TypeScale.body).foregroundStyle(.secondary) }
                }
            } header: {
                Text("智能手表 / 手环 / CGM")
            } footer: {
                Text(profile.usesDemoData ? "示例用户不读取 Apple 健康；回到你自己的数据后再连接。" : hk.isAvailable
                     ? "读取手表、血压计、CGM 等写进健康 App 的数据，只读不写。权限在「设置 › 健康 › 数据访问与设备」里改。"
                     : "这台设备不支持健康数据，可以手动记录。")
            }
            if profile.useHealthKit && hk.isAvailable {
                Section {
                    if hk.inventory.isEmpty {
                        Text("正在检查…").foregroundStyle(.secondary)
                    }
                    ForEach(hk.inventory) { item in
                        VStack(alignment: .leading, spacing: Theme.Space.hairline) {
                            HStack {
                                Text(item.label)
                                Spacer()
                                Text(item.count == 0 ? "没有数据" : item.count >= 200 ? "200 条以上" : "\(item.count) 条")
                                    .foregroundStyle(item.count == 0 ? Theme.warning : .secondary)
                            }
                            if item.count > 0 {
                                Text(([item.latest.map { "最近 " + $0.formatted(.dateTime.month().day()) }].compactMap { $0 } + [item.sources.joined(separator: "、")] + [item.note].compactMap { $0 })
                                        .filter { !$0.isEmpty }.joined(separator: " · "))
                                    .font(Theme.TypeScale.body).foregroundStyle(.secondary)
                            }
                        }
                    }
                    Button("重新检查") { Task { await hk.checkInventory() } }
                } header: {
                    Text("Apple 健康里的数据（近 60 天）")
                } footer: {
                    Text("「没有数据」：设备没写进健康 App，或没允许 Pulse 读取。健康 App 里有、这里没有的，到「设置 › 健康 › 数据访问与设备 › Pulse」打开。静息心率、HRV 和睡眠分期通常只有 Apple Watch 会写入；手环只写心率时，用夜间最低心率估算静息心率。")
                }
                .task { if hk.inventory.isEmpty { await hk.checkInventory() } }
            }
            Section {
                Label("晨起手动测量静息心率", systemImage: "hand.point.up.left")
                Label("手动补记睡眠、运动、血压、血糖", systemImage: "square.and.pencil")
                Label("快速记录饮食、饮酒、压力等背景", systemImage: "tag")
            } header: {
                Text("没有设备时")
            } footer: {
                Text("没有设备也能记录、按感受评估准备度和复盘；手动改过的数值不会被同步覆盖。")
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
                Text(AgentNameSettings.shared.phrase("", "会按你的训练和数据完整度给出佩戴建议。"))
            }
        }
        .navigationTitle("数据来源").calmStyle()
    }
}
