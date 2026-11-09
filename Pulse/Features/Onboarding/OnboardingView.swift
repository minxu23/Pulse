import SwiftUI
import SwiftData

/// 了解个人基础：building the health base, goals, constraints and data sources (需求 1).
struct OnboardingView: View {
    @Environment(\.modelContext) private var ctx
    @Query private var profiles: [UserProfile]
    @State private var step = 0
    @State private var connecting = false
    @State private var healthMessage: String?
    @State private var importingProfile = false
    @State private var profileImport: HealthProfileImport?
    @State private var profileImportMessage: String?

    private let titles = ["", "基础信息", "健康状况与用药", "运动基础与生活节奏", "数据来源", ""]

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
                                    Button("上一步") { withAnimation { step = (step == 4 && p.usageIntent == .recording) ? 2 : step - 1 } }
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
        .sheet(item: $profileImport) { imported in
            HealthProfileImportSheet(values: imported) {
                guard let p = profiles.first, !p.usesDemoData else { return }
                imported.apply(to: p)
                try? ctx.save()
                profileImportMessage = "已填充可读取的项目，请核对；其余信息可手动补充。"
            }
        }
        .onAppear {
            if DataHub.profile(in: ctx) == nil { ctx.insert(UserProfile()) }
        }
    }

    @ViewBuilder
    private func content(_ p: UserProfile) -> some View {
        switch step {
        case 0: welcome(p)
        case 1: form(p) { profileImportSection(p); BasicsSection(p: p) }
        case 2: form(p) { ConditionsSection(p: p); MedicationsSection() }
        case 3: form(p) { ExerciseBaseSection(p: p); LifeConstraintsSection(p: p) }
        case 4: form(p) { dataSection(p) }
        default: finish(p)
        }
    }

    private func form<C: View>(_ p: UserProfile, @ViewBuilder _ c: () -> C) -> some View {
        Form {
            c()
            Section {
                Button {
                    withAnimation { step = (step == 2 && p.usageIntent == .recording) ? 4 : step + 1 }
                } label: {
                    Text(step == 4 ? "完成" : "下一步").frame(maxWidth: .infinity).fontWeight(.semibold)
                }
                .buttonStyle(.borderedProminent)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }
        }
    }

    private func welcome(_ p: UserProfile) -> some View {
        ScreenScroll {
            Text("欢迎使用 Pulse").font(Theme.TypeScale.title).frame(maxWidth: .infinity, alignment: .leading)
            Text("选择你的使用方向").font(Theme.TypeScale.title).frame(maxWidth: .infinity, alignment: .leading)
            Text("可以只记录身体状况，方向以后也能更改。")
                .foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            Card {
                UsageIntentSelector(selection: Binding(get: { p.usageIntent }, set: { p.usageIntent = $0 }))
            }
            Button("建立我的档案") { withAnimation { step = 1 } }
                .buttonStyle(.borderedProminent).frame(maxWidth: .infinity, minHeight: Theme.Size.tap)
            Text("数据保存在本机。连接 Apple 健康后，可以查看身体指标和变化。")
                .foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func profileImportSection(_ p: UserProfile) -> some View {
        Section {
            Button {
                importingProfile = true
                profileImportMessage = nil
                Task { @MainActor in
                    defer { importingProfile = false }
                    do {
                        let values = try await HealthKitService.shared.readProfileForImport()
                        if values.isEmpty {
                            profileImportMessage = "没有读到可填充的信息。Apple 健康可能尚未记录，或未允许 Pulse 读取；你可以手动填写。"
                        } else {
                            profileImport = values
                        }
                    } catch {
                        profileImportMessage = "暂时无法读取：" + error.localizedDescription + "。你可以继续手动填写。"
                    }
                }
            } label: {
                HStack {
                    Label("从 Apple 健康填充", systemImage: "heart.text.square")
                    Spacer()
                    if importingProfile { ProgressView() }
                }
            }
            .disabled(importingProfile || p.usesDemoData || !HealthKitService.shared.isAvailable)
            if let profileImportMessage { Text(profileImportMessage).font(Theme.TypeScale.body).foregroundStyle(.secondary) }
        } footer: {
            Text("授权后读取出生年份、性别及最近记录的身高、体重，确认后填入。昵称、健康状况和用药由你填写。")
        }
    }

    private func modulesSection(_ p: UserProfile) -> some View {
        Section {
            ForEach(ProModule.allCases) { m in
                Toggle(isOn: Binding(get: { p.hasModule(m) }, set: { p.setModule(m, enabled: $0) })) {
                    Label {
                        VStack(alignment: .leading, spacing: Theme.Space.hairline) {
                            Text(m.label)
                            Text(m.subtitle).font(Theme.TypeScale.body).foregroundStyle(.secondary)
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
            if let healthMessage { Text(healthMessage).font(Theme.TypeScale.body).foregroundStyle(.secondary) }
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
        ScreenScroll {
            Text("档案已建立").font(Theme.TypeScale.title).frame(maxWidth: .infinity, alignment: .leading)
            Card {
                Text(p.usageIntent == .recording ? "记录身体状况" : "开始基线评估").font(Theme.TypeScale.title)
                Text(p.usageIntent == .recording
                     ? "查看身体指标和趋势，也可以随时补充记录。以后需要时再选择改善方案。"
                     : "先记录一周，了解身体状况和日常习惯，再确认改善方案。已有足够数据时，可以直接查看基线报告。")
                if !p.hasAge || !p.hasBodySize { Text("未填写的资料可稍后补充；相关排名和 BMI 暂不评价。").foregroundStyle(.secondary) }
            }
            Button(p.usageIntent == .recording ? "开始记录" : "开始评估") {
                p.onboardingDone = true
                try? ctx.save()
                Task { @MainActor in
                    if p.useHealthKit { await HealthKitService.shared.sync(into: ctx) }
                    if p.usageIntent != .recording { ProgramFlow.startBaseline(p, in: ctx) }
                }
            }
            .buttonStyle(.borderedProminent).frame(minHeight: Theme.Size.tap)
        }
    }
}
