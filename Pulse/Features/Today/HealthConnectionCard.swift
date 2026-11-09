import SwiftUI

struct HealthConnectionCard: View {
    let profile: UserProfile
    private var health: HealthKitService { .shared }
    var body: some View {
        Card {
            CardTitle(health.isSyncing ? "正在同步 Apple 健康" : profile.useHealthKit ? "检查健康数据" : "连接健康数据")
            if health.isSyncing { ProgressView().accessibilityLabel("健康数据同步中") }
            Text(profile.useHealthKit ? "已连接不代表每项都有记录。可查看读取结果、数据来源和缺失项目，也可以手动补充。" : "连接 Apple 健康读取已有记录，或继续手动记录。")
                .foregroundStyle(.secondary)
            if let last = profile.lastSync { Text("最近同步：" + last.formatted(date: .abbreviated, time: .shortened)).foregroundStyle(.secondary) }
            NavigationLink(profile.useHealthKit ? "查看数据与重新同步" : "连接 Apple 健康") { DataSourcesView(profile: profile) }
                .buttonStyle(.borderedProminent).frame(minHeight: Theme.Size.tap)
        }
    }
}
