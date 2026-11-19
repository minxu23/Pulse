import SwiftUI
import SwiftData
import Charts

/// 方案详情 (改善期): the main target from baseline to goal, this week of the round, and the baseline report.
struct ProgramDetailScreen: View {
    @Environment(\.modelContext) private var ctx
    @Query private var profiles: [UserProfile]
    @Query private var meds: [MedicationEntry]
    @Query(sort: \DailyRecord.day) private var records: [DailyRecord]
    @Query(sort: \ActivitySession.start) private var sessions: [ActivitySession]
    @Query(sort: \VitalReading.time) private var vitals: [VitalReading]
    @Query(sort: \PlanItem.day) private var items: [PlanItem]

    var body: some View {
        if let p = profiles.first, let pack = p.programPack, let target = p.programTarget {
            content(p, pack, target)
        } else {
            ContentUnavailableView("还没有选方案", systemImage: "list.bullet.clipboard", description: Text("先在「计划」里完成基线评估。"))
        }
    }

    private func content(_ p: UserProfile, _ pack: ProgramPack, _ target: TargetMetric) -> some View {
        let now = Date.app
        let today = DayClock.logicalToday(now)
        let a = Analytics(profile: p, medications: meds, records: records, sessions: sessions, now: now)
        let back = today.adding(days: -60)
        let r = TargetTracker.reading(target, days: a.days, vitals: vitals.filter { $0.time > back }.map(\.point),
                                      workouts: sessions.filter { $0.start > back }.map(\.point), end: today.adding(days: 1), profile: a.profile)
        let goal = p.targetGoal ?? TargetGoal(target: target)
        let week = ProgramFlow.week(p, now: now)
        let thisWeek = items.filter { $0.weekStart == today.weekStart && $0.kind.isTraining }
        let done = thisWeek.filter { $0.status == .done || $0.status == .partial }.count
        let steps = Stats.mean(a.days.filter { $0.day >= today.weekStart && $0.day < today }.compactMap { $0.steps.map(Double.init) })
        return ScreenScroll {
            Card {
                CardHeader(title: pack.title, subtitle: "第 \(p.programRound) 轮 · " + (week == 0 ? "下周一开始第 1 周" : "第 \(min(week, p.programRoundWeeks)) / \(p.programRoundWeeks) 周"),
                           icon: pack.icon, color: pack.color)
                WeekDots(current: week, total: p.programRoundWeeks)
                if p.programRoundWeeks > 4 {
                    Text("有生病或出差的周不计入，这一轮顺延到 \(p.programRoundWeeks) 周（每轮最多顺延 2 周）。").foregroundStyle(.secondary)
                }
            }

            Card {
                CardTitle("主靶点：\(target.title)")
                if target.isBloodPressure {
                    Text(p.conditions.contains(.hypertension) ? "你记录了高血压，因此本轮重点看血压变化。" : "基线血压偏高，因此本轮重点看血压变化。")
                        .foregroundStyle(.secondary)
                }
                HStack(alignment: .firstTextBaseline, spacing: Theme.Space.tight) {
                    Text(r.valueText).font(Theme.TypeScale.title.weight(.bold)).monospacedDigit()
                    Text(r.unitShort).font(Theme.TypeScale.body.weight(.semibold)).foregroundStyle(.secondary)
                    Spacer()
                    if TargetTracker.reached(target, value: r.value, goal: goal.goal) { Chip(text: "已达到目标", color: Theme.good) }
                }
                if let b = goal.baseline { FactRow(label: target.isBloodPressure ? "基线收缩压" : "基线", value: TargetTracker.text(target, b)) }
                if let g = goal.goal { FactRow(label: target.isBloodPressure ? "收缩压目标" : "这一轮的目标", value: (target.higherIsBetter ? "≥ " : "≤ ") + TargetTracker.text(target, g) + (target == .weeklyRunKm ? "%" : "")) }
                if let avg = r.average { FactRow(label: "4 周平均收缩压", value: TargetTracker.text(target, avg)) }
                if target == .weeklyRunKm, let planned = r.plannedKm { FactRow(label: "本周", value: "\((r.runKm ?? 0).shortDecimal) / \(planned.shortDecimal) 公里") }
                if r.series.count >= 2 { chart(r, goal: goal) }
                Text(Self.countLine(r)).font(Theme.TypeScale.body).foregroundStyle(.secondary)
                if target.isBloodPressure {
                    Text("本轮按收缩压评价，图表是每天收缩压的平均。" + (target == .homeBP ? "" : "大数字是最近一次读数；第 4 周结束时用最后两周的平均和基线比，所以每周都要有读数。"))
                        .foregroundStyle(.secondary)
                }
                Text(target.howToMeasure).font(Theme.TypeScale.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text(Self.why(target)).font(Theme.TypeScale.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if target == .clinicBP {
                    Button("我已经有血压计了") { ProgramFlow.switchToHomeBP(p, in: ctx) }
                        .buttonStyle(.bordered)
                    Text("改用家庭血压后主靶点还是血压，这一轮的基线不变，不用等下一轮。").foregroundStyle(.secondary)
                }
            }

            Card {
                CardTitle("本周")
                if week == 0 {
                    Text("这一轮还没开始，下面的步数不计入完成率。").foregroundStyle(.secondary)
                } else {
                    FactRow(label: "训练", value: "完成 \(done) / \(thisWeek.count) 次")
                    // 睡眠改善: this week's times, the ones the weekly check counts against.
                    if pack == .sleep, let x = p.programPlan {
                        let t = PackPlanner.sleepSchedule(a.profile, x, week: min(week, p.programRoundWeeks))
                        FactRow(label: "这周起床", value: Clock.text(t.wake) + (target == .sleepDuration ? "" : " 前后"))
                        FactRow(label: "这周上床", value: Clock.text(t.bed) + (target == .sleepDuration ? " 前" : " 前后"))
                    }
                }
                if let steps { FactRow(label: "日均步数", value: "\(Int(steps.rounded())) 步 · 目标 \(p.stepsTarget)") }
                Text("每周日在「复盘」看这一周，下周计划按完成情况调整。").font(Theme.TypeScale.body).foregroundStyle(.secondary)
            }

            Card {
                NavigationLink("更换改善方案") { ProgramReportScreen() }.buttonStyle(.bordered)
                Text("换方案会开始新的一轮，起点按最近 14 天重新算。").foregroundStyle(.secondary)
                NavigationLink { ProgramReportScreen() } label: {
                    NavRowLabel(icon: "doc.text", title: "基线报告", detail: "这一轮开始时的健康画像")
                }
                .buttonStyle(.plain)
            }
            PageFootnote(pack == .event ? "每 4 周复盘一次训练阶段，比赛结束后进入总结期。"
                         : "第 \(p.programRoundWeeks) 周结束时看有没有达到目标：达到了进入总结期，没达到就调整后再来一轮。")
        }
        .navigationTitle("我的方案")
        .navigationBarTitleDisplayMode(.inline)
        .calmStyle()
    }

    private func chart(_ r: TargetReading, goal t: TargetGoal) -> some View {
        Chart {
            ForEach(r.series, id: \.day) { pt in
                LineMark(x: .value("日", pt.day), y: .value("值", pt.value))
                    .foregroundStyle(r.target.color)
                    .interpolationMethod(.catmullRom)
                PointMark(x: .value("日", pt.day), y: .value("值", pt.value))
                    .foregroundStyle(r.target.color).symbolSize(16)
            }
            if let start = profiles.first?.programRoundStart {
                // The label sits on the side of the line with more room.
                let late = r.series.first.map { start.timeIntervalSince($0.day) > (r.series.last?.day ?? start).timeIntervalSince(start) } ?? false
                RuleMark(x: .value("本轮开始", start)).foregroundStyle(Color.gray).lineStyle(StrokeStyle(dash: [4, 4]))
                    .annotation(position: .top, alignment: late ? .trailing : .leading, overflowResolution: Self.inside) { Self.label("本轮开始") }
            }
            if let b = t.baseline {
                RuleMark(y: .value("基线", b)).foregroundStyle(Color.gray).lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .annotation(position: .top, alignment: .leading, overflowResolution: Self.inside) { Self.label("基线", .secondary) }
            }
            if let g = t.goal {
                RuleMark(y: .value("目标", g)).foregroundStyle(Theme.good)
                    .annotation(position: .top, alignment: .trailing, overflowResolution: Self.inside) { Self.label("目标") }
            }
        }.pulseChartAxes()
        .chartYScale(domain: .automatic(includesZero: false))
        .frame(height: 190)
    }

    /// Chart labels stay within the plot, clear of the rows above it and of the axis labels.
    static let inside = AnnotationOverflowResolution(x: .fit(to: .plot), y: .fit(to: .chart))

    /// A chart label on the card's own colour, so a line running through it passes behind the words.
    static func label(_ text: String, _ style: HierarchicalShapeStyle = .primary) -> some View {
        Text(text).font(Theme.TypeScale.caption).foregroundStyle(style)
            .padding(.horizontal, 2).background(Theme.card, in: .rect(cornerRadius: 2))
    }

    /// How many readings there are and when the last one was.
    static func countLine(_ r: TargetReading) -> String {
        switch r.target {
        case .weeklyRunKm:
            return "本周跑了 \(r.count) 次"
        case .sleepDuration, .sleepRegularity:
            // A night is stored under the morning it ends on; people name it by the evening before.
            return "近 7 晚记录了 \(r.count) 晚"
        default:
            return "\(r.count) 条读数" + (r.latest.map { "，最近 " + $0.formatted(.dateTime.month().day()) } ?? "")
        }
    }

    /// Why this goal: what four weeks can change, and how much the number wobbles on its own.
    static func why(_ t: TargetMetric) -> String {
        switch t {
        case .vo2max: "最大摄氧量通常练 3 周左右开始上升；手表每次估算会浮动 1–2，所以看近两周的平均。"
        case .restingHR: "规律有氧通常能让静息心率降 3–6，起点越高降得越多；每天会浮动约 3，所以看 7 天平均。"
        case .homeBP: "坚持有氧和静力练习，家庭血压通常几周内会降，降 5 就有意义；每周会自然浮动几个数，所以看整周平均。"
        case .clinicBP: "单次读数可能差 10 毫米汞柱以上，读数越多越准。"
        case .weight: "每周减 0.5–1 公斤比较稳妥；体重每天会浮动 1 公斤左右，所以看 7 天平均。"
        case .cgmTIR: "达标时间每提高 10 个百分点，糖化血红蛋白大约降 0.5–0.8%。"
        case .postMealGlucose: "健康成人大多数时间都在 7.8 以下。饭后走一走、晚饭别太晚，通常很快就能看到变化。"
        case .fastingGlucose: "空腹血糖每天会有波动，看一周的平均。"
        case .weeklyRunKm: "完成计划跑量的 90% 以上就算做到。单次最长的一跑不超过过去 30 天最长那次的 110%；赛前两周减量，强度不变。"
        case .sleepDuration: "起床时间固定、上床一点点提前，几周里每晚多睡二三十分钟很常见。每晚时长本身会差一小时，所以看 7 晚平均；第 4 周结束时看最后两周。"
        case .sleepRegularity: "入睡时间每天差得越多，心血管风险越高；几晚算出的波动不准，所以看整周。"
        }
    }
}

private struct WeekDots: View {
    let current: Int
    let total: Int
    var color: Color = .primary
    var body: some View {
        HStack(spacing: Theme.Space.item) {
            ForEach(1...max(1, total), id: \.self) { i in
                VStack(spacing: Theme.Space.tight) {
                    Capsule().fill(i < current ? color : i == current ? color.opacity(0.5) : Theme.subtle).frame(height: 6)
                    Text("第 \(i) 周").font(Theme.TypeScale.body).foregroundStyle(i == current ? .primary : .secondary)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(current == 0 ? "还没开始" : "第 \(current) 周，共 \(total) 周")
    }
}
