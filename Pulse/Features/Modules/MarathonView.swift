import SwiftUI
import SwiftData
import Charts

/// 专项运动支持：结论在前（目标、距比赛多久、能否按目标完成），然后是本周训练、负荷与恢复、
/// 配速与心率区间、补给演练，最后是专业场景下的乳酸测试。
struct MarathonView: View {
    @Environment(\.modelContext) private var ctx
    @Query private var profiles: [UserProfile]
    @Query private var meds: [MedicationEntry]
    @Query(sort: \ActivitySession.start) private var sessions: [ActivitySession]
    @Query(sort: \PlanItem.day) private var items: [PlanItem]
    @Query(sort: \VitalReading.time) private var vitals: [VitalReading]
    @Query(sort: \DailyRecord.day) private var records: [DailyRecord]
    @State private var editGoal = false
    @State private var addLactate = false
    @State private var fuelMinutes = 150.0

    var body: some View {
        if let p = profiles.first {
            let snap = p.snapshot(medications: meds)
            let workouts = sessions.map(\.point)
            ScreenScroll {
                if let race = snap.race {
                    let week = MarathonPlanner.week(profile: snap, race: race, weekStart: Date.app.weekStart)
                    RaceHeroCard(profile: p, race: race, week: week, prediction: RacePredictor.predict(workouts),
                                 onEdit: { editGoal = true }, onEnable: enable)
                    thisWeekCard(week, snap, enabled: p.hasModule(.marathon))
                    SectionTitle(title: "负荷与恢复")
                    loadSection(workouts, week: week)
                    SectionTitle(title: "配速与心率区间")
                    PaceCard(week: week, targetMinutes: race.targetMinutes)
                    HRZonesCard(profile: snap)
                    SectionTitle(title: "补给演练")
                    fuelCard(p)
                    SectionTitle(title: "乳酸测试", subtitle: "专业场景")
                    lactateCard(p)
                    if week.weeksToRace <= 3 && week.weeksToRace >= 0 { RaceWeekCard(race: race, week: week) }
                } else {
                    noGoalCard(p)
                }
                PageFootnote("专项计划是通用框架。有教练或运动医学专业人员时，以其评估和安排为准；有心血管疾病或其他健康问题时，先获得医生评估。")
            }
            .navigationTitle("专项运动").calmStyle()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if snap.race != nil {
                    ToolbarItem(placement: .primaryAction) { Button("目标设置") { editGoal = true } }
                }
            }
            .sheet(isPresented: $editGoal) { RaceGoalSheet(profile: p) }
            .sheet(isPresented: $addLactate) { CalmNavigationStack { VitalLogForm(kind: .lactate).navigationTitle("记录乳酸测试") } }
        }
    }

    private func enable() {
        guard let p = profiles.first else { return }
        p.setModule(.marathon, enabled: true)
        DataHub.regenerateWeekPlan(in: ctx)
        try? ctx.save()
    }

    private func noGoalCard(_ p: UserProfile) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.block) {
            HStack(spacing: Theme.Space.block) {
                HeroIcon(icon: "flag.checkered", color: Theme.activity)
                VStack(alignment: .leading, spacing: Theme.Space.tight) {
                    Text("设定一个赛事目标").font(.title3.weight(.semibold))
                    Text("填写比赛日期、目标成绩和当前跑量，Pulse 会评估可行性并分阶段安排训练。")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
            Button {
                if p.raceDate == nil { p.raceDate = p.targetDate ?? .app.adding(days: 140) }
                editGoal = true
            } label: { Label("设置目标", systemImage: "plus").frame(maxWidth: .infinity) }
                .buttonStyle(.borderedProminent).controlSize(.large)
        }
        .cardSurface()
    }

    // MARK: This week

    private func thisWeekCard(_ week: MarathonWeek, _ snap: ProfileSnapshot, enabled: Bool) -> some View {
        let ws = Date.app.weekStart
        let planned = enabled ? items.filter { $0.weekStart == ws && $0.kind.isTraining } : []
        let preview = enabled ? [] : week.sessions.filter { $0.kind.isTraining }
        let km = sessions.filter { $0.type == .run && $0.start >= ws }.compactMap(\.distanceKm).reduce(0, +)
        return VStack(alignment: .leading, spacing: Theme.Space.block) {
            CardTitle(title: enabled ? "本周 · \(week.phase.label)" : "开启后的本周安排 · \(week.phase.label)") {
                if enabled {
                    Text("\(planned.filter { $0.status == .done || $0.status == .partial }.count)/\(planned.count) 次")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.tight) {
                Text(km.oneDecimal).font(.system(.title, design: .rounded).weight(.semibold)).monospacedDigit()
                Text("/ \(Int(week.weeklyKm)) km").font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                Text("长距离 \(Int(week.longRunKm)) km").font(.subheadline).foregroundStyle(.secondary)
            }
            ProgressBar(value: km / max(1, week.weeklyKm), color: Theme.activity, height: 6).accessibilityHidden(true)
            Text(week.phase.focus).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ForEach(week.warnings, id: \.self) { StatusLabel(.attention($0)).font(.subheadline) }
            if !planned.isEmpty {
                Divider()
                ForEach(planned) { item in
                    HStack(spacing: Theme.Space.block) {
                        IconTile(icon: item.kind.icon, color: Theme.activity)
                        VStack(alignment: .leading, spacing: Theme.Space.hairline) {
                            Text(item.title).font(.body)
                            Text("\(Weekday.name(item.day.weekday)) · \(item.minutes) 分钟 · \(item.intensity.label)")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: Theme.Space.tight)
                        StatusLabel(text: item.status.label, icon: item.status.icon, color: Theme.planStatus(item.status), secondaryText: true)
                            .labelStyle(.iconOnly).font(.title3)
                            .accessibilityLabel(item.status.label)
                    }
                    .frame(minHeight: Theme.Size.tap)
                    .accessibilityElement(children: .combine)
                }
            }
            if !preview.isEmpty {
                Divider()
                ForEach(Array(preview.enumerated()), id: \.offset) { _, s in
                    HStack(spacing: Theme.Space.block) {
                        IconTile(icon: s.kind.icon, color: Theme.activity)
                        VStack(alignment: .leading, spacing: Theme.Space.hairline) {
                            Text(s.title).font(.body)
                            Text("\(Weekday.name(s.weekday)) · \(s.minutes) 分钟 · \(s.intensity.label)").font(.footnote).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(minHeight: Theme.Size.tap)
                    .accessibilityElement(children: .combine)
                }
            }
            if snap.cardiacLimited {
                StatusLabel(.attention("你记录了心血管相关情况：较高强度内容需医生确认后再进行。")).font(.subheadline)
            }
        }
        .cardSurface()
    }

    // MARK: Load & recovery

    @ViewBuilder
    private func loadSection(_ workouts: [WorkoutPoint], week: MarathonWeek) -> some View {
        let load = TrainingLoad.status(workouts)
        let easy = sessions.filter { $0.type == .run && ($0.rpe ?? 5) <= 4 && $0.avgHR != nil && ($0.distanceKm ?? 0) > 0 && $0.start > Date.app.adding(days: -56) }
        let longest = sessions.filter { $0.type == .run && $0.start > Date.app.adding(days: -28) }.compactMap(\.distanceKm).max()
        MetricGrid {
            HealthMetricCard(title: "负荷比", icon: "gauge.with.dots.needle.50percent", color: Theme.activity,
                             value: load.ratio.map { String(format: "%.2f", $0) } ?? "—",
                             status: load.zone == .optimal ? .good(load.zone.label) : (load.zone == .caution || load.zone == .high ? .attention(load.zone.label) : .neutral(load.zone.label)))
            HealthMetricCard(title: "最长距离", icon: "road.lanes", color: Theme.activity, time: "近 4 周",
                             value: longest.map { $0.oneDecimal } ?? "—", unit: "km",
                             status: longest.map { $0 >= week.longRunKm - 1 ? .good("达到本周长距离") : .neutral("本周目标 \(Int(week.longRunKm)) km") } ?? .neutral("还没有跑步记录"))
            efficiencyCard(easy)
            rhrCard
        }
        // Said once under the grid, so the first card is not taller than its neighbours.
        Text("负荷比 = 近 7 天 ÷ 近 4 周平均，适宜 0.8–1.3。").font(.footnote).foregroundStyle(.secondary)
        VStack(alignment: .leading, spacing: Theme.Space.block) {
            CardTitle("近 8 周跑量")
            Chart {
                ForEach(load.weeks) { w in
                    BarMark(x: .value("周", w.weekStart, unit: .weekOfYear), y: .value("km", w.km))
                        .foregroundStyle(Theme.activity).cornerRadius(4)
                }
                RuleMark(y: .value("本周目标", week.weeklyKm))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3])).foregroundStyle(Color.gray)
                    .annotation(position: .top, alignment: .leading) { Text("本周目标 \(Int(week.weeklyKm))").font(.caption2).foregroundStyle(.secondary) }
            }
            .chartXAxis { AxisMarks(values: .stride(by: .weekOfYear, count: 2)) { _ in AxisGridLine(); AxisValueLabel(format: .dateTime.month().day()) } }
            .frame(height: 140)
            .accessibilityLabel("近 8 周每周跑量")
            StatusLabel(load.zone == .high || load.zone == .caution ? .attention(load.message) : .neutral(load.message)).font(.subheadline)
            Text("每周跑量增长控制在约 10% 以内，每 3–4 周安排一次减量周。").font(.footnote).foregroundStyle(.secondary)
        }
        .cardSurface()
    }

    /// Resting heart rate as a recovery signal: a sustained rise during a build phase means ease off.
    private var rhrCard: some View {
        let t = Analytics(profile: profiles.first, medications: meds, records: records, sessions: []).trend
        let status: MetricStatus = {
            if case .rise(let d) = t.sustained { return .attention("持续高于平时 \(d.oneDecimal)，减少强度") }
            guard let a7 = t.avg7, let a28 = t.avg28 else { return .neutral("数据积累中") }
            return a7 - a28 >= 2 ? .attention("近一周偏高，注意恢复") : .good("恢复良好")
        }()
        return HealthMetricCard(title: "静息心率", icon: "heart.fill", color: Theme.heartData, time: "7 日均值",
                                value: t.avg7.map { $0.noDecimal } ?? "—", unit: "bpm", status: status)
    }

    private func efficiencyCard(_ easy: [ActivitySession]) -> some View {
        let early = easy.prefix(3), late = easy.suffix(3)
        let hr0 = Stats.mean(early.compactMap(\.avgHR)), hr1 = Stats.mean(late.compactMap(\.avgHR))
        let pace0 = Stats.mean(early.map { $0.minutes / ($0.distanceKm ?? 1) }), pace1 = Stats.mean(late.map { $0.minutes / ($0.distanceKm ?? 1) })
        let status: MetricStatus = {
            guard easy.count >= 6, let a = hr0, let b = hr1, let pa = pace0, let pb = pace1 else { return .neutral("需要 6 次带心率的轻松跑") }
            if b <= a - 2 || pb <= pa - 0.1 { return .good("同等强度更省力") }
            if b >= a + 3 && pb >= pa { return .attention("轻松跑心率偏高，注意恢复") }
            return .neutral("与 8 周前相近")
        }()
        return HealthMetricCard(title: "有氧效率", icon: "waveform.path.ecg", color: Theme.heartData, time: "轻松跑",
                                value: hr1.map { $0.noDecimal } ?? "—", unit: "bpm", status: status) {
            if let pa = pace0, let pb = pace1, easy.count >= 6 {
                Text("配速 \(MarathonPlanner.paceText(pa)) → \(MarathonPlanner.paceText(pb))").font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Fuelling

    private func fuelCard(_ p: UserProfile) -> some View {
        let plan = MarathonPlanner.fuelPlan(minutes: Int(fuelMinutes), carbsPerHour: p.fuelCarbsPerHour)
        let longRuns = sessions.filter { $0.type == .run && $0.minutes >= 90 }.suffix(4).reversed()
        let gels = Int((Double(plan.carbs) / 22).rounded(.up))
        return VStack(alignment: .leading, spacing: Theme.Space.block) {
            CardTitle("补给计算")
            VStack(alignment: .leading, spacing: Theme.Space.tight) {
                HStack {
                    Text("运动时长").font(.subheadline)
                    Spacer()
                    Text("\(Int(fuelMinutes)) 分钟").font(.subheadline.weight(.semibold)).monospacedDigit()
                }
                Slider(value: $fuelMinutes, in: 45...330, step: 15) { Text("运动时长") }
                    .accessibilityValue("\(Int(fuelMinutes)) 分钟")
            }
            Stepper("每小时碳水 \(p.fuelCarbsPerHour) g", value: Bindable(p).fuelCarbsPerHour, in: 20...100, step: 5)
                .font(.subheadline)
            MetricRow {
                fuelFact("碳水", "\(plan.carbs)", "g", "bolt.fill")
                fuelFact("能胶约", plan.carbs > 0 ? "\(gels)" : "0", "支", "takeoutbag.and.cup.and.straw.fill")
                fuelFact("饮水", plan.fluidHigh > 0 ? "\(plan.fluidLow)–\(plan.fluidHigh)" : "按口渴", plan.fluidHigh > 0 ? "ml" : "", "drop.fill")
            }
            Text(plan.note).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if !longRuns.isEmpty {
                Divider()
                Text("最近的长距离演练").font(.subheadline.weight(.semibold))
                ForEach(Array(longRuns)) { s in
                    HStack {
                        Text(s.start.formatted(.dateTime.month().day())).font(.subheadline).foregroundStyle(.secondary).frame(width: 64, alignment: .leading)
                        Text("\((s.distanceKm ?? 0).oneDecimal) km · \(Int(s.minutes)) 分钟").font(.subheadline).monospacedDigit()
                        Spacer()
                        StatusLabel(s.carbsG.map { .good("补给 \(Int($0)) g") } ?? .attention("未记录补给")).font(.footnote)
                    }
                    .frame(minHeight: 32)
                }
                Text("在「记录运动」中填写补给量，比赛日只使用训练中试过的补给。").font(.footnote).foregroundStyle(.secondary)
            }
        }
        .cardSurface()
    }

    private func fuelFact(_ label: String, _ value: String, _ unit: String, _ icon: String) -> some View {
        MetricTile(label: label, value: value, unit: unit, icon: icon)
            .accessibilityElement(children: .combine)
    }

    // MARK: Lactate (professional context)

    private func lactateCard(_ p: UserProfile) -> some View {
        let all = vitals.filter { $0.kind == .lactate }
        let lastDay = all.last.map { $0.time.startOfDay }
        let test = all.filter { $0.time.startOfDay == lastDay }
        let stages = LactateAnalyzer.stages(test.map(\.point), pulses: test.map(\.pulse), notes: test.map(\.note))
        let result = LactateAnalyzer.analyze(stages)
        return VStack(alignment: .leading, spacing: Theme.Space.block) {
            CardTitle(title: "递增负荷测试", detail: lastDay?.formatted(.dateTime.month().day())) {
                Button { addLactate = true } label: { Label("记录", systemImage: "plus") }
                    .buttonStyle(.bordered)
            }
            if stages.count >= 2, stages.allSatisfy({ $0.hr != nil }) {
                Chart {
                    RuleMark(y: .value("4 mmol/L", 4.0))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3])).foregroundStyle(Color.gray)
                        .annotation(position: .top, alignment: .leading) { Text("4 mmol/L").font(.caption2).foregroundStyle(.secondary) }
                    ForEach(Array(stages.enumerated()), id: \.offset) { _, s in
                        LineMark(x: .value("心率", s.hr ?? 0), y: .value("乳酸", s.lactate)).foregroundStyle(Theme.activity)
                        PointMark(x: .value("心率", s.hr ?? 0), y: .value("乳酸", s.lactate)).foregroundStyle(Theme.activity)
                    }
                }
                .chartXScale(domain: ((stages.compactMap(\.hr).min() ?? 120) - 5)...((stages.compactMap(\.hr).max() ?? 170) + 8))
                .chartYScale(domain: 0...max(5, (stages.map(\.lactate).max() ?? 4) + 0.5))
                .chartXAxisLabel("心率 bpm")
                .frame(height: 150)
                .accessibilityLabel("乳酸随心率变化曲线")
            } else if stages.isEmpty {
                EmptyLine("暂无测试记录。测试需在专业人员指导下进行。")
            }
            if let r = result {
                MetricRow {
                    fuelFact("有氧阈 LT1", r.lt1HR.map { "\(Int($0))" } ?? "—", "bpm", "1.circle")
                    fuelFact("乳酸阈 LT2", r.lt2HR.map { "\(Int($0))" } ?? "—", "bpm", "2.circle")
                }
                ForEach(r.notes, id: \.self) { Text($0).font(.footnote).foregroundStyle(.secondary) }
                if let lt2 = r.lt2HR, p.thresholdHR != Int(lt2.rounded()) {
                    Button {
                        p.thresholdHR = Int(lt2.rounded())
                        DataHub.regenerateWeekPlan(in: ctx)
                    } label: { Label("采用 \(Int(lt2.rounded())) bpm 作为阈值心率", systemImage: "checkmark.circle") }
                        .buttonStyle(.bordered)
                    Text("请先与测试人员确认。采用后，心率区间与计划强度以测得的阈值为参照。").font(.footnote).foregroundStyle(.secondary)
                }
            }
            Stepper("阈值心率 \(p.thresholdHR.map { "\($0) bpm" } ?? "未设定")",
                    onIncrement: { p.thresholdHR = (p.thresholdHR ?? 155) + 1 },
                    onDecrement: { p.thresholdHR = max(100, (p.thresholdHR ?? 155) - 1) })
                .font(.subheadline)
            Text("测试条件尽量一致：相同时段、饮食与热身，前一天避免高强度训练。单次数值受测试方案影响，请与专业人员一起解读。")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .cardSurface()
    }
}

// MARK: - Race hero

struct RaceHeroCard: View {
    let profile: UserProfile
    let race: RaceInfo
    let week: MarathonWeek
    let prediction: RacePrediction?
    var onEdit: () -> Void
    var onEnable: () -> Void

    var body: some View {
        let days = max(0, race.date.daysSince(.app))
        VStack(alignment: .leading, spacing: Theme.Space.block) {
            CardTitle(title: "赛事目标") {
                if profile.hasModule(.marathon) { Chip(text: week.phase.label, icon: "flag.checkered", color: Theme.activity) }
            }
            HStack(alignment: .center, spacing: Theme.Space.block) {
                HeroIcon(icon: "figure.run", color: Theme.activity)
                VStack(alignment: .leading, spacing: Theme.Space.tight) {
                    Text(race.name.isEmpty ? "全程马拉松" : race.name).font(.title3.weight(.semibold))
                    Text("\(race.date.formatted(.dateTime.year().month().day())) · 还有 \(days) 天")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
            HStack(spacing: 0) {
                fact("目标成绩", race.targetMinutes.map(RacePredictor.timeText) ?? "完赛")
                fact("目标配速", MarathonPlanner.paceText(week.marathonPace))
                fact("当前估计", prediction.map { RacePredictor.timeText($0.minutes) } ?? "—")
            }
            StatusLabel(feasibility).font(.subheadline)
            if !profile.hasModule(.marathon) {
                Button(action: onEnable) { Label("开启专项计划", systemImage: "flag.checkered").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                Text("开启后，每周计划将按阶段安排长距离、强度课与力量训练。").font(.footnote).foregroundStyle(.secondary)
            }
        }
        .cardSurface()
    }

    private var feasibility: MetricStatus {
        guard let target = race.targetMinutes else { return .neutral("以安全完赛为目标") }
        guard let pr = prediction else { return .neutral("记录几次 5 km 以上的跑步后，可以评估目标是否合适") }
        let weeks = week.weeksToRace
        if Double(target) >= Double(pr.minutes) * 0.97 { return .good("按当前能力，目标较为稳妥") }
        if Double(target) >= Double(pr.minutes) * (weeks >= 12 ? 0.9 : 0.94) {
            return .neutral("还需提升约 \(pr.minutes - target) 分钟，按计划训练有机会达成")
        }
        return .attention("目标比当前估计快 \(pr.minutes - target) 分钟，可以考虑先以完赛为目标")
    }

    private func fact(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.tight) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.headline).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Paces & zones

struct PaceCard: View {
    let week: MarathonWeek
    let targetMinutes: Int?
    @State private var showSplits = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.item) {
            CardTitle("训练配速")
            paceRow("轻松跑 / 长距离", week.easyPace, "能完整说话，占跑量的大部分", Intensity.easy)
            Divider().padding(.leading, Theme.Size.iconTile + Theme.Space.block)
            paceRow("马拉松配速", week.marathonPace, "专项期的配速跑与比赛日", Intensity.moderate)
            Divider().padding(.leading, Theme.Size.iconTile + Theme.Space.block)
            paceRow("阈值配速", week.thresholdPace, "约可持续 1 小时的强度", Intensity.hard)
            if let t = targetMinutes {
                DisclosureGroup("比赛日分段时间（匀速）", isExpanded: $showSplits) {
                    VStack(spacing: Theme.Space.item) {
                        ForEach(RacePredictor.splits(targetMinutes: t), id: \.km) { s in
                            FactRow(label: s.km == 21.0975 ? "半程" : (s.km == 42.195 ? "终点" : "\(Int(s.km)) km"),
                                    value: RacePredictor.clockText(s.minutes))
                        }
                    }
                    .padding(.top, Theme.Space.item)
                }
                .font(.subheadline)
                .padding(.top, Theme.Space.tight)
            }
        }
        .cardSurface()
    }

    private func paceRow(_ title: String, _ pace: Double, _ text: String, _ i: Intensity) -> some View {
        HStack(spacing: Theme.Space.block) {
            IconTile(icon: "speedometer", color: Theme.intensity(i))
            VStack(alignment: .leading, spacing: Theme.Space.hairline) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(text).font(.footnote).foregroundStyle(.secondary)
            }
            Spacer()
            Text(MarathonPlanner.paceText(pace)).font(.body.weight(.semibold)).monospacedDigit()
        }
        .frame(minHeight: Theme.Size.tap)
        .accessibilityElement(children: .combine)
    }
}

struct HRZonesCard: View {
    let profile: ProfileSnapshot

    var body: some View {
        let (zones, basis) = HRZones.zones(profile: profile)
        let maxHigh = Double(zones.map(\.high).max() ?? 200)
        VStack(alignment: .leading, spacing: Theme.Space.block) {
            CardTitle("心率区间")
            ForEach(zones) { z in
                HStack(spacing: Theme.Space.block) {
                    Text("\(z.index)").font(.footnote.weight(.bold)).foregroundStyle(.primary)
                        .frame(width: Theme.Size.iconTile, height: Theme.Size.iconTile)
                        .background(Theme.subtle, in: Circle())
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: Theme.Space.tight) {
                        HStack {
                            Text(z.name).font(.subheadline.weight(.semibold))
                            if z.aboveCap { StatusLabel(.attention("超出医生给出的上限")).font(.caption) }
                            Spacer()
                            Text("\(z.low)–\(z.high) bpm").font(.subheadline).monospacedDigit().foregroundStyle(.secondary)
                        }
                        GeometryReader { geo in
                            Capsule().fill(Theme.heartData.opacity(z.aboveCap ? 0.15 : 0.35 + 0.13 * Double(z.index)))
                                .frame(width: geo.size.width * Double(z.high) / maxHigh)
                        }
                        .frame(height: 6)
                        Text(z.purpose).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("区间 \(z.index) \(z.name)，\(z.low) 到 \(z.high) 次每分，\(z.purpose)")
            }
            Text(basis).font(.footnote).foregroundStyle(.secondary)
            AgentAskButton(title: "训练时手表和心率带怎么用", question: "马拉松训练时手表和心率带怎么用更准？")
        }
        .cardSurface()
    }
}

// MARK: - Race week

struct RaceWeekCard: View {
    let race: RaceInfo
    let week: MarathonWeek

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.block) {
            CardTitle("比赛日准备")
            IconTextRow(icon: "bed.double.fill", color: Theme.sleep, title: "赛前两晚睡好",
                        text: "比赛前一晚紧张睡不好很常见，前两晚的睡眠更重要。")
            IconTextRow(icon: "fork.knife", color: Theme.nutrition, title: "赛前 1–2 天增加碳水",
                        text: "以熟悉、易消化的主食为主，不尝试新食物；赛前 3 小时吃早餐。")
            IconTextRow(icon: "bolt.fill", color: Theme.nutrition, title: "按演练补给",
                        text: "每小时约 \(race.fuelCarbsPerHour) g 碳水，从第 30–45 分钟开始，少量多次补水。")
            IconTextRow(icon: "speedometer", color: Theme.activity, title: "前半程不冲",
                        text: "前 10 km 控制在目标配速 \(MarathonPlanner.paceText(week.marathonPace)) 或稍慢。")
            IconTextRow(icon: "exclamationmark.triangle.fill", color: .red, title: "身体信号优先",
                        text: "出现胸痛、头晕、意识模糊或异常心悸时立即停止，并向医疗点求助。")
        }
        .cardSurface()
    }
}

// MARK: - Goal editor

struct RaceGoalSheet: View {
    @Environment(\.modelContext) private var ctx
    @Environment(\.dismiss) private var dismiss
    @Bindable var profile: UserProfile

    var body: some View {
        CalmNavigationStack {
            Form {
                Section("赛事") {
                    TextField("赛事名称", text: $profile.raceName)
                    DatePicker("比赛日期", selection: Binding(get: { profile.raceDate ?? .app.adding(days: 140) }, set: { profile.raceDate = $0 }),
                               in: Date.app..., displayedComponents: .date)
                    Toggle("设定目标成绩", isOn: Binding(get: { profile.raceTargetMinutes != nil }, set: { profile.raceTargetMinutes = $0 ? 300 : nil }))
                    if let t = profile.raceTargetMinutes {
                        Stepper("目标 \(RacePredictor.timeText(t))", onIncrement: { profile.raceTargetMinutes = t + 5 },
                                onDecrement: { profile.raceTargetMinutes = max(150, t - 5) })
                    }
                }
                Section {
                    Stepper("当前周跑量 \(Int(profile.currentWeeklyKm)) km", value: $profile.currentWeeklyKm, in: 0...150, step: 2)
                    Stepper("近期最长跑 \(Int(profile.longestRecentRunKm)) km", value: $profile.longestRecentRunKm, in: 0...42, step: 1)
                } header: { Text("当前基础") } footer: {
                    Text("计划会从当前跑量出发，每周增长不超过约 10%，并定期安排减量周。")
                }
            }
            .navigationTitle("赛事目标")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        if profile.raceDate == nil { profile.raceDate = .app.adding(days: 140) }
                        DataHub.regenerateWeekPlan(in: ctx)
                        try? ctx.save()
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }
}
