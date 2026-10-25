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
                    .font(.subheadline)
                    .padding(16)
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                }
                .buttonStyle(.plain)
            }
            Disclaimer(text: "习惯改变从小处开始：每次只调整一两件事，观察身体感受和数据变化，再决定是否保留。")
        }
        .sheet(item: $logKind) { QuickLogSheet(kind: $0) }
    }

    private func header(_ title: String, _ sub: String, _ icon: String, _ color: Color, log: QuickLogKind) -> some View {
        CardHeader(title: title, subtitle: sub, icon: icon, color: color) {
            Button { logKind = log } label: { Image(systemName: "plus.circle.fill").font(.title3).frame(width: 44, height: 44) }
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
                StatusLabel(.attention("本周已超出上限 \((units - p.weeklyAlcoholLimit).oneDecimal) 单位")).font(.subheadline)
            }
            Text("酒精会让夜间心率升高、HRV 降低、睡眠变浅，影响通常持续到第二天早晨。睡前 3 小时内不饮酒、饮酒时同步补水，可以减少影响。")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private func caffeineCard(_ days: [DayData], _ p: ProfileSnapshot) -> some View {
        let withCaffeine = days.filter { $0.caffeineCups > 0 }
        let late = withCaffeine.filter { $0.lateCaffeine(cutoff: p.caffeineCutoffHour) }.count
        return Card {
            header("咖啡因", "近 7 天 \(late) 天晚于 \(p.caffeineCutoffHour):00", "cup.and.saucer", Theme.nutrition, log: .caffeine)
            Text("咖啡因的作用可持续 5–6 小时以上。下午改为低因咖啡或花草茶，有助于入睡和夜间恢复。")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private func hydrationCard(_ days: [DayData], _ p: ProfileSnapshot) -> some View {
        let logged = days.filter { $0.waterMl > 0 }
        let avg = Stats.mean(logged.map { Double($0.waterMl) }) ?? 0
        return Card {
            let limit = p.fluidLimited ? "上限" : "目标"
            header("饮水", logged.isEmpty ? "\(limit) \(p.waterTargetMl) ml/天" : "近 7 天平均 \(Int(avg)) / \(limit) \(p.waterTargetMl) ml", "drop", Theme.nutrition, log: .water)
            ProgressBar(value: avg / Double(p.waterTargetMl), color: p.fluidLimited && avg > Double(p.waterTargetMl) ? .orange : Theme.nutrition)
            Text(p.fluidLimited
                 ? "你开启了限水：每天饮水不超过医生定的 \(p.waterTargetMl) ml（汤、粥、水果里的水分也算）。口渴时小口慢喝，或含冰块润口。"
                 : "脱水会使心率升高。运动日和炎热天气多喝一些；有心力衰竭或肾脏疾病等需要限制饮水的情况，请在「我的 › 恢复目标」打开「限水」。")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private func dietCard(_ days: [DayData], _ p: ProfileSnapshot) -> some View {
        let q = days.compactMap(\.dietQuality)
        let balanced = q.filter { $0 >= 3 }.count
        let late = days.filter(\.lateMeal).count
        return Card {
            header("饮食", q.isEmpty ? "简单记录每天饮食整体情况" : "近 7 天均衡 \(balanced)/\(q.count) 天 · 晚餐过晚 \(late) 天", "fork.knife", Theme.nutrition, log: .diet)
            BulletText(text: "每餐有蔬菜、优质蛋白（鱼、豆制品、蛋、瘦肉），主食适量增加全谷物。")
            BulletText(text: "少盐、少加工食品，有助于血压管理。")
            BulletText(text: "晚餐尽量在睡前 2–3 小时完成，过晚过饱可能使夜间心率偏高。")
            if p.hasDiabetes {
                Callout(kind: .info, text: "糖尿病照护：按照护计划安排碳水分配，记录餐食碳水有助于理解血糖变化。")
            }
        }
    }

    private func fuelCard(_ p: ProfileSnapshot) -> some View {
        let plan60 = MarathonPlanner.fuelPlan(minutes: 60, carbsPerHour: p.race?.fuelCarbsPerHour ?? 45)
        let plan120 = MarathonPlanner.fuelPlan(minutes: 120, carbsPerHour: p.race?.fuelCarbsPerHour ?? 45)
        return Card {
            CardHeader(title: "运动补给", subtitle: "运动前、中、后", icon: "bolt.heart", color: Theme.nutrition)
            BulletText(text: "运动前 1–3 小时吃些易消化的碳水；空腹清晨的轻松运动通常不需要额外进食。")
            BulletText(text: "1 小时以内：\(plan60.note)")
            BulletText(text: "2 小时左右：约 \(plan120.carbs) g 碳水，饮水 \(plan120.fluidLow)–\(plan120.fluidHigh) ml，炎热时补充电解质。")
            BulletText(text: "运动后 1–2 小时内补充蛋白质与碳水，帮助恢复。")
            if p.hasDiabetes {
                Callout(kind: .caution, text: "使用胰岛素或磺脲类药物时，运动前后检测血糖，随身携带 15–20 g 快速碳水；运动后数小时及夜间注意低血糖。具体调整请遵循照护计划。")
            }
        }
    }

    private func stressCard(_ days: [DayData]) -> some View {
        let s = days.compactMap(\.stress).map(Double.init)
        let high = days.filter(\.highStress).count
        return Card {
            header("压力", s.isEmpty ? "在晨起感受或快速记录中记录" : "近 7 天平均 \(Stats.mean(s)!.oneDecimal)/5 · 高压力 \(high) 天", "brain.head.profile", Theme.mind, log: .stress)
            Text("持续压力会让静息心率升高、睡眠变差。每天 5–10 分钟慢呼吸、散步或与人交流都有帮助；长期情绪困扰请寻求专业支持。")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }
}
