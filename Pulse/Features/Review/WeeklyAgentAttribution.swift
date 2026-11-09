import SwiftUI

/// Keep the interpretation and its origin visible without adding a fourth top-level card.
struct WeeklyAgentAttribution: View {
    let state: ReviewWriter.State?
    var onRetry: () -> Void
    var onDiscuss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.tight) {
            AdaptiveRow {
                Label(AgentNameSettings.shared.name, systemImage: "sparkles").fontWeight(.semibold)
            } trailing: {
                Button("聊聊这周", action: onDiscuss).frame(minHeight: Theme.Size.tap)
            }
            switch state {
            case .written(_, let source)?:
                DisclosureGroup("解读来源") {
                    Text(source).foregroundStyle(.secondary)
                    Button("重新生成解读", action: onRetry).frame(minHeight: Theme.Size.tap)
                }
            case .rules(let reason)?:
                DisclosureGroup("本机分析 · 模型暂不可用") {
                    Text(reason).foregroundStyle(.secondary)
                    Button("重试生成解读", action: onRetry).frame(minHeight: Theme.Size.tap)
                }
            default:
                HStack(spacing: Theme.Space.item) {
                    ProgressView().controlSize(.small)
                    Text("正在生成解读，先显示本机分析").foregroundStyle(.secondary)
                }
            }
        }
        .font(Theme.TypeScale.body)
    }
}
