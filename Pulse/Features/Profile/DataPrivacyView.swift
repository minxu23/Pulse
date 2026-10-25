import SwiftUI
import SwiftData

/// 健康信息的使用和对外提供受用户控制 (需求 10).
struct DataPrivacyView: View {
    @Environment(\.modelContext) private var ctx
    @State private var categories: Set<ExportCategory> = Set(ExportCategory.allCases)
    @State private var exported: URL?
    @State private var exportError: String?
    @State private var confirmDelete = false

    var body: some View {
        Form {
            Section {
                Label("所有数据仅保存在这台设备上，不需要账号，也不会上传到服务器。", systemImage: "iphone")
                Label("唯一的例外是你在「云端模型（测试）」中主动开启时：向 Health Agent 提问会把数据摘要发送到你配置的服务。默认关闭。", systemImage: "cloud")
                Label("健康 App 数据只读取、不写入，可随时撤销权限。", systemImage: "heart.text.square")
                Label("只有你主动导出或分享时，数据才会离开设备。", systemImage: "hand.raised")
            } header: { Text("你的数据由你掌握") }
            .font(.subheadline)

            Section {
                ForEach(ExportCategory.allCases) { c in
                    Toggle(isOn: Binding(get: { categories.contains(c) }, set: { if $0 { categories.insert(c) } else { categories.remove(c) } })) {
                        Label(c.label, systemImage: c.icon)
                    }
                }
            } header: {
                Text("选择要提供的信息")
            } footer: {
                Text("例如只把睡眠与呼吸线索提供给睡眠门诊，只把血压记录提供给心内科医生。")
            }

            Section {
                Button { run { try DataExporter.clinicianSummary(ctx, categories: categories) } } label: {
                    Label("生成就诊摘要（文本）", systemImage: "doc.text")
                }
                Button { run { try DataExporter.json(ctx, categories: categories) } } label: {
                    Label("导出完整数据（JSON）", systemImage: "curlybraces")
                }
                Button { run { try DataExporter.csv(ctx) } } label: {
                    Label("导出每日数据（CSV 表格）", systemImage: "tablecells")
                }
                if let url = exported {
                    ShareLink(item: url) {
                        Label("分享 / 保存「\(url.lastPathComponent)」", systemImage: "square.and.arrow.up")
                    }
                    .fontWeight(.semibold)
                }
                if let exportError { StatusLabel(.urgent(exportError)).font(.footnote) }
            } header: {
                Text("导出")
            }
            .disabled(categories.isEmpty)

            Section {
                Button("删除所有数据", role: .destructive) { confirmDelete = true }
            } footer: {
                Text("将永久删除 Pulse 中的所有记录与设置，无法恢复。健康 App 中的数据不受影响。")
            }
        }
        .navigationTitle("隐私与数据").calmStyle()
        .confirmationDialog("确定删除 Pulse 中的所有数据？此操作无法撤销。", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("永久删除", role: .destructive) { DataHub.deleteAll(in: ctx) }
        }
    }

    private func run(_ make: () throws -> URL) {
        do {
            exported = try make()
            exportError = nil
        } catch {
            exportError = "导出失败：\(error.localizedDescription)"
        }
    }
}
