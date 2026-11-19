import SwiftUI
import SwiftData

/// 管理影响恢复的日常行为 (需求 7): diet, hydration, exercise fuelling, stress, caffeine and
/// alcohol — improved gradually with the user's real-life conditions in mind.
struct HabitsView: View {
    @Query private var profiles: [UserProfile]
    @Query private var meds: [MedicationEntry]
    @Query(sort: \DailyRecord.day) private var records: [DailyRecord]
    @Query(sort: \ActivitySession.start) private var sessions: [ActivitySession]
    @State private var logKind: QuickLogKind?

    var body: some View {
        let a = Analytics(profile: profiles.first, medications: meds, records: records, sessions: sessions)
        let p = a.profile
        let week = a.days.filter { $0.day >= Date.app.weekStart }
        let last7 = a.days.filter { $0.day > Date.app.adding(days: -7) }
        ScreenScroll {
            alcoholCard(week, p)
            caffeineCard(last7, p)
            hydrationCard(last7, p)
            dietCard(last7, p)
            fuelCard(p)
            stressCard(last7)
            if let profile = profiles.first {
                NavigationLink { Form { HabitTargetsSection(p: profile) }.navigationTitle("恢复目标").calmStyle() } label: {
                    HStack {
                        Label("调整恢复目标", systemImage: "slider.horizontal.3")
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                    }
                    .font(Theme.TypeScale.body)
                    .cardSurface()
                }
                .buttonStyle(.plain)
                // Settings are a group of their own, after the habit cards.
                .padding(.top, Theme.Space.section - Theme.Space.cardGap)
            }
            Disclaimer(text: "每次只改一两件事，看看身体和数据的变化，再决定留不留。")
        }
        .sheet(item: $logKind) { QuickLogSheet(kind: $0) }
    }

    private func header(_ title: String, _ sub: String, _ icon: String, _ color: Color, log: QuickLogKind) -> some View {
        CardHeader(title: title, subtitle: sub, icon: icon, color: color) {
            Button { logKind = log } label: {
                Image(systemName: "plus.circle.fill").font(Theme.TypeScale.title)
                    .frame(width: Theme.Size.tap, height: Theme.Size.tap).contentShape(Rectangle())
            }
            .tint(Theme.accent)
            .accessibilityLabel("记录\(title)")
        }
    }

    private func alcoholCard(_ week: [DayData], _ p: ProfileSnapshot) -> some View {
        let units = week.map(\.alcoholUnits).reduce(0, +)
        return Card {
            header("饮酒", "本周 \(units.oneDecimal) / \(p.weeklyAlcoholLimit.noDecimal) 单位", "wineglass", Theme.nutrition, log: .alcohol)
            ProgressBar(value: units / max(1, p.weeklyAlcoholLimit), color: units > p.weeklyAlcoholLimit ? .orange : Theme.nutrition)
            if units > p.weeklyAlcoholLimit {
                StatusLabel(.attention("本周已超出上限 \((units - p.weeklyAlcoholLimit).oneDecimal) 单位")).font(Theme.TypeScale.body)
            }
            Text("酒精让夜里心率升高、睡得浅，影响常到第二天早上。睡前 3 小时别喝，喝的时候多喝水。")
                .font(Theme.TypeScale.body).foregroundStyle(.secondary)
        }
    }

    private func caffeineCard(_ days: [DayData], _ p: ProfileSnapshot) -> some View {
        let withCaffeine = days.filter { $0.caffeineCups > 0 }
        let late = withCaffeine.filter { $0.lateCaffeine(cutoff: p.caffeineCutoffHour) }.count
        return Card {
            header("咖啡因", late == 0 ? "近 7 天都在 \(p.caffeineCutoffHour):00 前" : "近 7 天有 \(late) 天晚于 \(p.caffeineCutoffHour):00", "cup.and.saucer", Theme.nutrition, log: .caffeine)
            Text("咖啡因能管 5–6 小时以上，下午换成低因咖啡或花草茶。")
                .font(Theme.TypeScale.body).foregroundStyle(.secondary)
        }
    }

    private func hydrationCard(_ days: [DayData], _ p: ProfileSnapshot) -> some View {
        let logged = days.filter { $0.waterMl > 0 }
        let avg = Stats.mean(logged.map { Double($0.waterMl) }) ?? 0
        return Card {
            let limit = p.fluidLimited ? "上限" : "目标"
            header("饮水", logged.isEmpty ? "\(limit) \(p.waterTargetMl) ml/天" : "近 7 天平均 \(Int(avg)) ml，\(limit) \(p.waterTargetMl)", "drop", Theme.nutrition, log: .water)
            ProgressBar(value: avg / Double(p.waterTargetMl), color: p.fluidLimited && avg > Double(p.waterTargetMl) ? .orange : Theme.nutrition)
            Text(p.fluidLimited
                 ? "你开了限水：每天不超过医生定的 \(p.waterTargetMl) ml，汤、粥、水果里的水也算。口渴时小口喝，或含块冰。"
                 : "缺水会让心率升高，运动日和热天多喝。医生让你限水的话，到「我的 › 恢复目标」打开「限水」。")
                .font(Theme.TypeScale.body).foregroundStyle(.secondary)
        }
    }

    private func dietCard(_ days: [DayData], _ p: ProfileSnapshot) -> some View {
        let q = days.compactMap(\.dietQuality)
        let balanced = q.filter { $0 >= 3 }.count
        let late = days.filter(\.lateMeal).count
        return Card {
            header("饮食", q.isEmpty ? "简单记一下每天吃得怎样" : "近 7 天有 \(balanced)/\(q.count) 天均衡" + (late > 0 ? "，\(late) 天晚餐过晚" : ""), "fork.knife", Theme.nutrition, log: .diet)
            BulletText(text: "每餐有蔬菜和蛋白质（鱼、豆制品、蛋、瘦肉），主食多些粗粮。")
            BulletText(text: "少盐、少加工食品，对血压有好处。")
            BulletText(text: "晚饭在睡前 2–3 小时吃完，太晚太饱会让夜里心率偏高。")
            if p.hasDiabetes {
                Callout(kind: .info, text: "碳水按照护计划分配；记下每餐的碳水，更容易看懂血糖变化。")
            }
        }
    }

    private func fuelCard(_ p: ProfileSnapshot) -> some View {
        let plan60 = MarathonPlanner.fuelPlan(minutes: 60, carbsPerHour: p.race?.fuelCarbsPerHour ?? 45)
        let plan120 = MarathonPlanner.fuelPlan(minutes: 120, carbsPerHour: p.race?.fuelCarbsPerHour ?? 45)
        return Card {
            CardHeader(title: "运动补给", subtitle: "运动前、中、后", icon: "bolt.heart", color: Theme.nutrition)
            BulletText(text: "运动前 1–3 小时吃点好消化的碳水；早上空腹轻松练不用另外吃。")
            BulletText(text: "1 小时以内：\(plan60.note)")
            BulletText(text: "2 小时左右：约 \(plan120.carbs) g 碳水，饮水 \(plan120.fluidLow)–\(plan120.fluidHigh) ml，炎热时补充电解质。")
            BulletText(text: "运动后 1–2 小时内补蛋白质和碳水。")
            if p.hasDiabetes {
                Callout(kind: .caution, text: "用胰岛素或磺脲类药时，运动前后测血糖，随身带 15–20 g 快速碳水；运动后几小时和夜里留意低血糖。")
            }
        }
    }

    private func stressCard(_ days: [DayData]) -> some View {
        let s = days.compactMap(\.stress).map(Double.init)
        let high = days.filter(\.highStress).count
        return Card {
            header("压力", s.isEmpty ? "在晨起感受或快速记录里记" : "近 7 天平均 \(Stats.mean(s)!.oneDecimal)/5" + (high > 0 ? "，\(high) 天压力大" : ""), "brain.head.profile", Theme.mind, log: .stress)
            Text("压力大会让静息心率升高、睡不好。每天 5–10 分钟慢呼吸、散步或找人聊聊；长期情绪困扰请找专业人士。")
                .font(Theme.TypeScale.body).foregroundStyle(.secondary)
        }
    }
}
