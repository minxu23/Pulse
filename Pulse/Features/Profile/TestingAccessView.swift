import SwiftUI

/// A deliberate testing entry, kept out of the welcome and everyday data settings.
struct TestingAccessView: View {
    @State private var taps = 0
    var body: some View {
        Form {
            Section {
                LabeledContent("Pulse", value: "健康记录与改善计划")
                Button("版本 " + (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")) { taps += 1 }
                    .foregroundStyle(.secondary)
            }
            if taps >= 7 || DataStores.shared.testingEnabled {
                Section("开发测试") {
                    Text("测试模式使用独立的示例档案，不读取 Apple 健康。退出后恢复自己的档案。")
                    Button("进入测试模式") {
                        let stores = DataStores.shared
                        stores.enterTesting()
                        let ctx = stores.container.mainContext
                        if DataHub.profile(in: ctx) == nil { DemoDataGenerator.populate(ctx, persona: .xiaolin) }
                    }
                }
            }
        }
        .navigationTitle("关于 Pulse").navigationBarTitleDisplayMode(.inline)
    }
}
