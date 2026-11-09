import SwiftUI
import SwiftData

struct UsageDirectionView: View {
    @Bindable var profile: UserProfile
    @Environment(\.modelContext) private var ctx
    @Environment(\.dismiss) private var dismiss
    @State private var selection: UsageIntent
    @State private var note: String
    init(profile: UserProfile) {
        self.profile = profile
        _selection = State(initialValue: profile.usageIntent)
        _note = State(initialValue: profile.goalNote)
    }
    var body: some View {
        Form {
            Section("使用方向") { UsageIntentSelector(selection: $selection) }
            Section { TextField("补充说明（可选）", text: $note, axis: .vertical) }
            Section {
                Text(selection == .recording ? "确认后停止安排新的训练，保留身体记录、已完成训练和历史报告。" : "具体方案与指标将在基线评估后确认，已有记录和报告保留。")
                    .foregroundStyle(.secondary)
                Button("确认使用方向") {
                    ProgramFlow.setUsageIntent(selection, note: note, profile: profile, in: ctx)
                    dismiss()
                }
            }
        }
        .navigationTitle("使用方向").navigationBarTitleDisplayMode(.inline)
        .calmStyle()
    }
}

struct ProgramHistoryView: View {
    @Query private var profiles: [UserProfile]
    @Query(sort: \ProgramSnapshot.createdAt, order: .reverse) private var snapshots: [ProgramSnapshot]
    @Environment(\.modelContext) private var ctx
    @State private var reassess = false
    var body: some View {
        List {
            if let p = profiles.first {
                Section("当前方案") {
                    Text(p.usageIntent.label)
                    if p.programPhase.runsPack {
                        NavigationLink("查看与更换方案") { ProgramDetailScreen() }
                    }
                    NavigationLink("使用方向") { UsageDirectionView(profile: p) }
                    NavigationLink("基础信息") { BaselineQuestionsView(profile: p) }
                    if p.usageIntent != .recording { Button("重新评估") { reassess = true } }
                }
                Section("历史报告") {
                    if snapshots.isEmpty { Text("暂无报告").foregroundStyle(.secondary) }
                    ForEach(snapshots) { saved in
                        switch saved.reportKind {
                        case .baseline?, .summary?:
                            if let result = try? JSONDecoder().decode(BaselineResult.self, from: saved.payload) {
                                NavigationLink {
                                    BaselineReportView(result: result, profile: p.snapshot(medications: []))
                                } label: {
                                    VStack(alignment: .leading) {
                                        Text(saved.reportKind == .summary ? "总结报告" : ProgramPack(rawValue: saved.packRaw)?.title ?? "基线报告")
                                        Text(saved.createdAt.formatted(date: .abbreviated, time: .omitted)).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        case .round?:
                            if let result = try? JSONDecoder().decode(ProgramRoundResult.self, from: saved.payload) {
                                Text("第 \(result.round) 轮 · \(result.headline)")
                            }
                        case nil:
                            EmptyView()
                        }
                    }
                }
            }
        }
        .navigationTitle("方案与报告").navigationBarTitleDisplayMode(.inline)
        .calmStyle()
        .confirmationDialog("保留已有记录和历史报告，重新开始基线评估？", isPresented: $reassess, titleVisibility: .visible) {
            Button("开始重新评估") {
                if let p = profiles.first {
                    ProgramFlow.startBaseline(p, in: ctx)
                }
            }
        }
    }
}
