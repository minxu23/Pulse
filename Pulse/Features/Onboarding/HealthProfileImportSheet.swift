import SwiftUI

struct HealthProfileImportSheet: View {
    let values: HealthProfileImport
    var onApply: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        CalmNavigationStack {
            Form {
                Section {
                    LabeledContent("出生年份", value: values.birthYear.map { String($0) } ?? "未读到，保留原填写")
                    LabeledContent("性别", value: values.sex?.label ?? "未读到，保留原填写")
                    measurement("身高", text: values.heightCm.map { "\($0.oneDecimal) cm" }, date: values.heightDate)
                    measurement("体重", text: values.weightKg.map { "\($0.oneDecimal) kg" }, date: values.weightDate)
                } header: {
                    Text("从 Apple 健康读取的信息")
                } footer: {
                    Text("确认后会替换对应的填写值；未读到的项目保持原样。测量日期较早时，请在填充后更新。")
                }
                Section {
                    Button("确认填充") { onApply(); dismiss() }
                        .disabled(values.isEmpty)
                }
            }
            .navigationTitle("核对档案信息")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
        }
    }

    private func measurement(_ title: String, text: String?, date: Date?) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.hairline) {
            LabeledContent(title, value: text ?? "未读到，保留原填写")
            if let date { Text("测量于 " + date.formatted(date: .abbreviated, time: .omitted)).font(Theme.TypeScale.body).foregroundStyle(.secondary) }
        }
    }
}
