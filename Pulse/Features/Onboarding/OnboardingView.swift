import SwiftUI
import SwiftData

/// 了解个人基础：building the health base, goals, constraints and data sources (需求 1).
struct OnboardingView: View {
    @Environment(\.modelContext) private var ctx
    @Query private var profiles: [UserProfile]
    @State private var step = 0
    @State private var connecting = false
    @State private var healthMessage: String?

    private let titles = ["", "基础信息", "健康状况与用药", "运动基础与生活节奏", "目标", "数据来源与测量", ""]

    var body: some View {
        Group {
            if let p = profiles.first {
                NavigationStack {
                    content(p)
                        .navigationTitle(titles[step])
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            if step > 0 && step < titles.count - 1 {
                                ToolbarItem(placement: .topBarLeading) {
                                    Button("上一步") { withAnimation { step -= 1 } }
                                }
                                ToolbarItem(placement: .principal) {
                                    ProgressView(value: Double(step), total: Double(titles.count - 2))
                                        .frame(width: 120)
                                }
                            }
                        }
                }
            } else {
                ProgressView()
            }
        }
        .onAppear {
            if profiles.isEmpty { ctx.insert(UserProfile()) }
        }
    }

    @ViewBuilder
    private func content(_ p: UserProfile) -> some View {
        switch step {
        case 0: welcome
        case 1: form(p) { BasicsSection(p: p) }
        case 2: form(p) { ConditionsSection(p: p); MedicationsSection() }
        case 3: form(p) { ExerciseBaseSection(p: p); LifeConstraintsSection(p: p) }
        case 4: form(p) { GoalsSection(p: p); modulesSection(p) }
        case 5: form(p) { dataSection(p); HabitTargetsSection(p: p) }
        default: finish(p)
        }
    }

    private func form<C: View>(_ p: UserProfile, @ViewBuilder _ c: () -> C) -> some View {
        Form {
            c()
            Section {
                Button {
                    withAnimation { step += 1 }
                } label: {
                    Text(step == 5 ? "完成" : "下一步").frame(maxWidth: .infinity).fontWeight(.semibold)
                }
                .buttonStyle(.borderedProminent)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }
        }
    }

    private var welcome: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.cardGap) {
                Image(systemName: "heart.text.square.fill")
                    .font(.system(size: 52))
                    .foregroundStyle(Theme.heartData)
                    .padding(.top, Theme.Space.section)
                VStack(alignment: .leading, spacing: Theme.Space.item) {
                    Text("Pulse").font(.largeTitle.bold())
                    Text("围绕智能穿戴设备的静息心率健康管理").font(.title3).foregroundStyle(.secondary)
                }
                Text("通过可持续的运动、睡眠、饮食和恢复管理，促进适合你个人情况的静息心率改善，同时提升日常精力与运动能力。")
                    .font(.body)
                VStack(alignment: .leading, spacing: Theme.Space.block) {
                    ForEach(JourneyStage.allCases) { s in
                        HStack(alignment: .top, spacing: Theme.Space.block) {
                            Text("\(s.rawValue + 1)")
                                .font(.subheadline.bold()).foregroundStyle(Color(.systemBackground))
                                .frame(width: 26, height: 26).background(Color.primary, in: Circle())
                            VStack(alignment: .leading, spacing: Theme.Space.hairline) {
                                Text(s.title).font(.headline)
                                Text(s.focus).font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Callout(kind: .info, text: "静息心率受运动水平、睡眠、压力、疾病、药物等多种因素影响。Pulse 结合你的个人背景与其他表现来评估进展，不提供医疗诊断。")
                VStack(spacing: Theme.Space.item) {
                    Button { withAnimation { step = 1 } } label: {
                        Text("建立我的健康档案").frame(maxWidth: .infinity).fontWeight(.semibold).padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    Button {
                        DemoDataGenerator.populate(ctx)
                    } label: {
                        Text("先用示例数据体验").frame(maxWidth: .infinity).padding(.vertical, 6)
                    }
                    .buttonStyle(.bordered)
                }
                // The actions are their own group: a section gap above them.
                .padding(.top, Theme.Space.section - Theme.Space.cardGap)
            }
            // Side margins come from the app's page margins; only the vertical inset is set here.
            .padding(.vertical, Theme.Space.block)
        }
    }

    private func modulesSection(_ p: UserProfile) -> some View {
        Section {
            ForEach(ProModule.allCases) { m in
                Toggle(isOn: Binding(get: { p.hasModule(m) }, set: { p.setModule(m, enabled: $0) })) {
                    Label {
                        VStack(alignment: .leading, spacing: Theme.Space.hairline) {
                            Text(m.label)
                            Text(m.subtitle).font(.footnote).foregroundStyle(.secondary)
                        }
                    } icon: { Image(systemName: m.icon) }
                }
            }
        } header: {
            Text("按需启用的专业支持（可稍后在「我的」中开启）")
        }
    }

    private func dataSection(_ p: UserProfile) -> some View {
        Section {
            Button {
                connecting = true
                Task {
                    do {
                        try await HealthKitService.shared.requestAuthorization()
                        p.useHealthKit = true
                        p.rhrMethod = .device
                        healthMessage = "已请求健康数据权限。完成后会自动同步近 60 天数据。"
                    } catch {
                        healthMessage = error.localizedDescription
                    }
                    connecting = false
                }
            } label: {
                HStack {
                    Label("连接健康 App（Apple Watch 等）", systemImage: "applewatch")
                    Spacer()
                    if connecting { ProgressView() } else if p.useHealthKit { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                }
            }
            if let healthMessage { Text(healthMessage).font(.footnote).foregroundStyle(.secondary) }
            Picker("静息心率主要来源", selection: Binding(get: { p.rhrMethod }, set: { p.rhrMethod = $0 })) {
                ForEach(RHRSource.allCases) { Text($0.label).tag($0) }
            }
        } header: {
            Text("数据来源")
        } footer: {
            Text("没有设备也可以使用：每天醒来后不起身，静躺 1 分钟，数 30 秒脉搏 × 2，记录在晨起感受中。为了可比性，尽量固定使用同一种方式。")
        }
    }

    private func finish(_ p: UserProfile) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.cardGap) {
                Image(systemName: "checkmark.seal.fill").font(.system(size: 48)).foregroundStyle(.green).padding(.top, Theme.Space.section)
                Text("档案已建立").font(.largeTitle.bold())
                Text("接下来的 2 周是「了解个人基础」阶段：").font(.headline)
                VStack(alignment: .leading, spacing: Theme.Space.item) {
                    BulletText(text: "每天在相同条件下获取静息心率（\(p.rhrMethod.label)），建立个人基线。")
                    BulletText(text: "每天早晨花 20 秒记录醒后感受，晚上看看恢复重点。")
                    BulletText(text: "第一周计划以 \(p.weeklyTargetMinutes) 分钟有氧为目标，安排在 \(p.availableWeekdays.sorted { PlanGenerator.order($0) < PlanGenerator.order($1) }.map(Weekday.name).joined(separator: "、"))。")
                    if p.conditions.contains(where: \.isCardiovascular) {
                        BulletText(text: "你记录了心血管相关情况，计划会先以低–中等强度为主，请与医生确认运动强度范围。", color: .pink)
                    }
                }
                Button {
                    p.weeklyTargetMinutes = max(45, min(p.activityLevel.startingWeeklyMinutes, Int(Double(p.weeklyTimeBudget) * 0.8)))
                    p.weeklyTargetReason = "按当前运动基础设置第一周的有氧目标。"
                    if p.hasModule(.marathon) && p.raceDate == nil { p.raceDate = p.targetDate }
                    p.onboardingDone = true
                    try? ctx.save()
                    DataHub.ensureWeekPlan(in: ctx)
                    if p.useHealthKit { Task { await HealthKitService.shared.sync(into: ctx) } }
                } label: {
                    Text("开始").frame(maxWidth: .infinity).fontWeight(.semibold).padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                // The action is its own group: a section gap above it.
                .padding(.top, Theme.Space.section - Theme.Space.cardGap)
            }
            // Side margins come from the app's page margins; only the vertical inset is set here.
            .padding(.vertical, Theme.Space.block)
        }
    }
}
