import SwiftUI
import SwiftData

/// 演示时间: move the demo's clock to another moment — a morning, the evening, after midnight — to
/// see how Pulse looks then. The sample user's records are generated again up to that moment, so
/// nothing from "later" shows; the clock keeps running from there.
struct DemoTimeView: View {
    @Environment(\.modelContext) private var ctx
    @Query private var profiles: [UserProfile]
    @State private var picked = Date.app
    @State private var working = false

    private static let presets: [(String, String, Int, Int)] = [
        ("晨起", "刚起床，夜间数据已同步，进行晨起评估", 7, 40),
        ("中午", "白天的活动与饮食", 12, 30),
        ("傍晚", "运动时段", 18, 30),
        ("睡前", "晚间回顾与睡前准备", 22, 30),
        ("凌晨", "5 点前仍算前一天", 2, 0),
    ]

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: Theme.Space.hairline) {
                    Text(Date.app.formatted(.dateTime.month().day().weekday(.wide).hour().minute()))
                        .font(.title2.weight(.semibold))
                    Text(DemoClock.isShifted ? "演示时间 · 实际时间 \(Date().formatted(.dateTime.hour().minute()))" : "与实际时间相同")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .padding(.vertical, Theme.Space.tight)
            } header: { Text("现在的演示时间") }

            Section {
                ForEach(Self.presets, id: \.0) { name, detail, h, m in
                    Button { apply(Self.today(h, m)) } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: Theme.Space.hairline) {
                                Text("\(name) \(Clock.text(h * 60 + m))").foregroundStyle(.primary)
                                Text(detail).font(.footnote).foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        // On the label, so the whole 44 pt row is tappable.
                        .frame(minHeight: Theme.Size.tap)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            } header: { Text("跳到今天的某个时段") }

            Section {
                DatePicker("日期和时间", selection: $picked,
                           in: Date().adding(days: -30)...Date().adding(days: 30))
                Button("切换到这个时间") { apply(picked) }
            } header: { Text("任意时间") }

            if DemoClock.isShifted {
                Section {
                    Button("回到实际时间") { apply(nil) }
                }
            }
        }
        .navigationTitle("演示时间")
        .navigationBarTitleDisplayMode(.inline)
        .disabled(working)
        .overlay {
            if working {
                ProgressView("正在生成示例数据…")
                    .padding(Theme.Space.cardPadding)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous))
            }
        }
        .safeAreaInset(edge: .bottom) {
            // Not scroll content, so the page margin is set here by hand.
            Text("切换后会按新的时间重新生成当前示例用户的数据，演示中新增的记录会被替换。状态栏仍显示手机的实际时间。")
                .font(.footnote).foregroundStyle(.secondary)
                .padding(.horizontal, Theme.Space.gutter).padding(.bottom, Theme.Space.item)
        }
    }

    /// "07:00" (today) or "2026-10-23 07:00".
    static func parse(_ text: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = Calendar.pulse.timeZone
        for format in ["yyyy-MM-dd HH:mm", "HH:mm"] {
            f.dateFormat = format
            if let d = f.date(from: text) {
                guard format == "HH:mm" else { return d }
                let c = Calendar.pulse.dateComponents([.hour, .minute], from: d)
                return today(c.hour ?? 0, c.minute ?? 0)
            }
        }
        return nil
    }

    /// A time of day on the real today (the demo's own date may have moved).
    static func today(_ h: Int, _ m: Int) -> Date {
        Calendar.pulse.date(bySettingHour: h, minute: m, second: 0, of: Date())!
    }

    private func apply(_ date: Date?) {
        working = true
        DemoClock.set(date)
        let persona = profiles.first.flatMap { DemoPersona(rawValue: $0.demoPersona) } ?? .xiaolin
        DemoDataGenerator.populate(ctx, persona: persona, now: .app)
        DataHub.ensureWeekPlan(in: ctx, now: .app)
        try? ctx.save()
        picked = .app
        working = false
    }
}
