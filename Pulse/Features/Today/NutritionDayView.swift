import SwiftUI
import SwiftData
import Charts

/// 饮食与指标：结论在前（今天吃喝得怎么样、需要注意什么、直接记录），依据在后（饮食记录、
/// 带有测量背景的身体指标、照护事项）。卡片结构与晨起评估、运动页一致。
struct NutritionDayView: View {
    let data: TodayData
    @Binding var sheet: TodaySheet?

    var body: some View {
        let p = data.p
        let glucose = data.todayVitals.filter { $0.kind == .glucose }
        let cgm = glucose.count >= 24
        let showGlucose = p.hasDiabetes || !glucose.isEmpty

        IntakeHeroCard(data: data, onLog: { sheet = .log($0) })
        if p.tracksNutrients { KidneyDietCard(data: data, onLog: { sheet = .log($0) }) }
        if KidneySigns.relevant(p) { KidneySignsCard(data: data, onLog: { sheet = .log($0) }) }
        MealsCard(meals: data.todayMeals, fuelTip: fuelTip, onLog: { sheet = .log($0) })

        SectionTitle(title: "身体指标", subtitle: "结合测量时间、活动和饮食")
        MetricGrid {
            bpCard
            if showGlucose { glucoseCard(glucose, cgm: cgm) }
            rhrCard
            fourthCard(showGlucose: showGlucose)
        }
        if cgm { GlucoseDayCard(points: glucose, meals: data.todayMeals, sessions: data.todaySessions, profile: p) }
        ReadingsCard(readings: data.todayVitals.filter { $0.kind != .glucose || !cgm },
                     sessions: data.todaySessions, meals: data.todayMeals, onLog: { sheet = .log($0) })

        if p.modules.contains(.cardioCare) || p.modules.contains(.diabetesCare) || data.openTasks.contains(where: { $0.area == .kidney && $0.due != nil }) {
            CareTodayCard(profile: p, record: data.record, readings: data.recentVitals, tasks: data.openTasks)
        }

        PageFootnote("饮食只需记录整体情况，不需要精确计算。指标会与测量时的活动、饮食和用药背景一起解读；读数异常时请先按建议复测。")
    }

    // MARK: Fuelling tip for today's training

    private var fuelTip: (title: String, text: String)? {
        guard let t = data.trainings.first(where: { $0.status == .planned }) else { return nil }
        if t.minutes >= 75 {
            let fuel = MarathonPlanner.fuelPlan(minutes: t.minutes, carbsPerHour: data.p.race?.fuelCarbsPerHour ?? 45)
            return ("「\(t.title)」的补给",
                    "运动前 1–3 小时吃些易消化的碳水；运动中约 \(fuel.carbs) g 碳水、\(fuel.fluidLow)–\(fuel.fluidHigh) ml 水；结束后补充蛋白质与碳水。")
        }
        return ("「\(t.title)」", "运动前不必额外进食；结束后 1–2 小时内正常进餐即可。")
    }

    // MARK: Indicator cards

    private var bpCard: some View {
        let p = data.p
        let bp = data.todayVitals.last { $0.kind == .bloodPressure }
        let status: MetricStatus = {
            guard let v = bp else { return .neutral(p.hasCardiac ? "建议晨起、睡前各测 1 次" : "今日未测量") }
            let over = v.value > Double(p.bpTargetSys) || (v.value2 ?? 0) > Double(p.bpTargetDia)
            if v.value >= 180 || (v.value2 ?? 0) >= 120 { return .urgent("显著升高，请静坐后复测") }
            return over ? .attention("高于目标 \(p.bpTargetSys)/\(p.bpTargetDia)") : .good("在目标范围内")
        }()
        return HealthMetricCard(title: "血压", icon: "heart.text.square.fill", color: Theme.heartData,
                                time: bp.map { Clock.text($0.time.minutesOfDay) },
                                value: bp.map { "\(Int($0.value))/\(Int($0.value2 ?? 0))" } ?? "—", unit: "mmHg", status: status) {
            if bp == nil {
                Button { sheet = .log(.bloodPressure) } label: { Label("测量", systemImage: "plus") }
                    .buttonStyle(.bordered)
            }
        }
    }

    private func glucoseCard(_ g: [VitalPoint], cgm: Bool) -> some View {
        let p = data.p
        let last = g.last
        let status: MetricStatus = {
            guard let v = last else { return .neutral("今日未记录") }
            if v.value < p.glucoseLow { return .urgent("低于 \(p.glucoseLow.oneDecimal)，请按照护计划处理") }
            if v.value > p.glucoseHigh { return .attention("高于目标上限 \(p.glucoseHigh.oneDecimal)") }
            return .good("在目标范围内")
        }()
        return HealthMetricCard(title: cgm ? "当前血糖" : "血糖", icon: "drop.fill", color: Theme.glucose,
                                time: last.map { Clock.text($0.time.minutesOfDay) },
                                value: last.map { $0.value.oneDecimal } ?? "—", unit: "mmol/L", status: status) {
            if cgm {
                let inRange = Double(g.filter { $0.value >= p.glucoseLow && $0.value <= p.glucoseHigh }.count) / Double(g.count)
                Text("今日范围内 \(Int(inRange * 100))%").font(.footnote).foregroundStyle(.secondary)
            } else if last == nil {
                Button { sheet = .log(.glucose) } label: { Label("记录", systemImage: "plus") }
                    .buttonStyle(.bordered)
            }
        }
    }

    private var rhrCard: some View {
        let d = data.analytics.today
        let norm = Stats.mean(data.analytics.history.suffix(28).filter { $0.rhrSource == d?.rhrSource }.compactMap(\.rhr))
        let status: MetricStatus = {
            guard let r = d?.rhr else { return .neutral("今晨暂无数据") }
            guard let n = norm else { return .neutral("参照建立中") }
            let diff = r - n
            if diff >= 4 { return .attention("比平时高 \(diff.noDecimal)") }
            if diff <= -2 { return .good("比平时低 \(abs(diff).noDecimal)") }
            return .neutral("与平时相近")
        }()
        return HealthMetricCard(title: "静息心率", icon: "heart.fill", color: Theme.heartData, time: "今晨",
                                value: d?.rhr.map { $0.noDecimal } ?? "—", unit: "bpm", status: status)
    }

    @ViewBuilder
    private func fourthCard(showGlucose: Bool) -> some View {
        let weight = data.recentVitals.last { $0.kind == .weight }
        if let w = weight {
            let prev = data.recentVitals.first { $0.kind == .weight && $0.time < w.time.adding(days: -5) }
            let gain = data.p.watchesWeight ? CardioAnalyzer.rapidWeightGain(data.recentVitals, now: data.now) : nil
            let status: MetricStatus = gain.map { .attention("3 天内增加 \($0.oneDecimal) kg，请联系医生") } ?? prev.map { pv in
                let d = w.value - pv.value
                return .neutral(abs(d) < 0.3 ? "与上次相近" : "较上次 \(d > 0 ? "+" : "")\(d.oneDecimal) kg")
            } ?? .neutral("最近一次")
            HealthMetricCard(title: "体重", icon: "scalemass.fill", color: Theme.body,
                             time: w.time.isSameDay(.app) ? Clock.text(w.time.minutesOfDay) : w.time.formatted(.dateTime.month().day()),
                             value: w.value.oneDecimal, unit: "kg", status: status)
        } else if !showGlucose || data.analytics.today?.hrv != nil {
            let d = data.analytics.today
            HealthMetricCard(title: "心率变异性", icon: "waveform.path.ecg", color: Theme.heartData, time: "今晨",
                             value: d?.hrv.map { $0.noDecimal } ?? "—", unit: "ms",
                             status: d?.hrv == nil ? .neutral("暂无数据") : .neutral("恢复的参考信号"))
        }
    }
}

// MARK: - Kidney diet

/// 盐、蛋白质、钾和磷: today's four lines against the doctor's amounts, and the last 7 days.
struct KidneyDietCard: View {
    let data: TodayData
    var onLog: (QuickLogKind) -> Void

    var body: some View {
        let p = data.p
        let today = data.analytics.today ?? DayData(day: data.day)
        let lines = KidneyDiet.lines(today, profile: p)
        VStack(alignment: .leading, spacing: Theme.Space.block) {
            CardTitle("盐、蛋白质、钾和磷")
            if lines.isEmpty {
                Text("记下今天吃了几个鸡蛋、几两肉、几碗饭，和吃过的高盐、高钾、高磷食物，Pulse 估算蛋白质和钾、磷，按医生给的量帮你对照。")
                    .font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(alignment: .leading, spacing: Theme.Space.item) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, l in
                        StatusLabel(l.metric).font(.subheadline).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if let w = KidneyDiet.week(data.analytics.days, profile: p, now: data.now), w.days >= 2 {
                Text("近 7 天记录了 \(w.days) 天：偏咸 \(w.saltyDays) 天\(w.proteinAvgG.map { "，蛋白质平均约 \(Int($0)) g" } ?? "")，高钾食物平均每天 \(w.potassiumPerDay.oneDecimal) 份（约 \(Int(w.potassiumMgPerDay)) mg 钾）。")
                    .font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Button { onLog(.diet) } label: {
                Label(lines.isEmpty ? "记录今天的饮食" : "修改今天的记录", systemImage: "square.and.pencil").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered).controlSize(.large)
        }
        .cardSurface()
    }
}

// MARK: - Swelling and urine

/// 水肿与尿量: today's record and the last two weeks; on dialysis, the session days and the weight
/// gained since the last one.
struct KidneySignsCard: View {
    let data: TodayData
    var onLog: (QuickLogKind) -> Void

    var body: some View {
        let p = data.p
        let today = data.analytics.today ?? DayData(day: data.day)
        let lines = KidneySigns.lines(today)
        VStack(alignment: .leading, spacing: Theme.Space.block) {
            CardTitle("水肿与尿量", detail: p.onHemodialysis ? "血液透析 · \(Dialysis.schedule(p))" : (p.onPeritoneal ? "腹膜透析" : nil))
            if p.onPeritoneal {
                Text("每天称体重、留意尿量；透出液浑浊、肚子疼或发烧，立即联系腹透中心。")
                    .font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if p.onHemodialysis {
                VStack(alignment: .leading, spacing: Theme.Space.item) {
                    if let next = Dialysis.next(from: data.now, p) {
                        StatusLabel(.neutral(next.isSameDay(data.now) ? "今天透析，今天不安排训练" : "下次透析：\(next.formatted(.dateTime.month().day().weekday(.wide)))"))
                    }
                    if let g = Dialysis.gain(data.recentVitals, profile: p, now: data.now) {
                        let text = "体重 \(g.latest.value.oneDecimal) kg，比\(g.against)多 \(g.kg.oneDecimal) kg" + (g.percent.map { "（\(Int($0.rounded()))%）" } ?? "")
                        StatusLabel(Dialysis.tooMuch(g) ? .attention(text) : .neutral(text))
                    } else if p.dryWeightKg == nil {
                        Text("在「我的 › 健康状况与用药」填上医生定的干体重，Pulse 帮你看两次透析之间体重涨了多少。")
                            .font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .font(.subheadline)
            }
            if lines.isEmpty {
                Text("按一按脚踝、留意尿量和泡沫，记下来能看出变化；连续两天明显水肿或尿变少，Pulse 会提醒你联系医生。")
                    .font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(alignment: .leading, spacing: Theme.Space.item) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, l in
                        StatusLabel(l.metric).font(.subheadline).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if let s = KidneySigns.summary(data.analytics.days, now: data.now), s.days >= 2 {
                Text(s.text + "。" + (s.foamyDays >= 3 ? "泡沫尿常有的话，复查时查一下尿白蛋白/肌酐比。" : ""))
                    .font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Button { onLog(.kidneySigns) } label: {
                Label(lines.isEmpty ? "记录今天的水肿与尿量" : "修改今天的记录", systemImage: "square.and.pencil").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered).controlSize(.large)
        }
        .cardSurface()
    }
}

extension NutrientLine {
    var metric: MetricStatus {
        switch tone {
        case .good: .good(text)
        case .attention: .attention(text)
        case .neutral: .neutral(text)
        }
    }
}

// MARK: - Intake hero

struct IntakeHeroCard: View {
    let data: TodayData
    var onLog: (QuickLogKind) -> Void

    var body: some View {
        let p = data.p
        let water = data.record?.waterMl ?? 0
        VStack(alignment: .leading, spacing: Theme.Space.block) {
            CardTitle("今天的饮食与饮水")
            HStack(spacing: Theme.Space.block) {
                ScoreRing(progress: Double(water) / Double(max(1, p.waterTargetMl)),
                          color: p.fluidLimited && water > p.waterTargetMl ? .orange : Theme.nutrition, lineWidth: 10) {
                    VStack(spacing: 0) {
                        Text("\(water)").font(.system(.title3, design: .rounded).weight(.bold)).monospacedDigit()
                            .lineLimit(1).minimumScaleFactor(0.7)
                        Text("ml").font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 10)
                }
                .frame(width: 88, height: 88)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("饮水 \(water) 毫升，\(p.fluidLimited ? "上限" : "目标") \(p.waterTargetMl) 毫升")
                VStack(alignment: .leading, spacing: Theme.Space.item) {
                    ForEach(Array(statuses.enumerated()), id: \.offset) { _, s in
                        StatusLabel(s).font(.subheadline).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            AdaptiveStack(spacing: Theme.Space.item) {
                Button {
                    data.record?.waterMl += 250
                } label: { Label("饮水 250 ml", systemImage: "plus").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(data.record == nil)
                Button { onLog(.diet) } label: { Label("记录饮食", systemImage: "fork.knife").frame(maxWidth: .infinity) }
                    .buttonStyle(.bordered).controlSize(.large)
            }
        }
        .cardSurface()
    }

    /// Water, diet, caffeine and alcohol, each as one readable status line.
    private var statuses: [MetricStatus] {
        let p = data.p
        let r = data.record
        var out: [MetricStatus] = []
        let water = r?.waterMl ?? 0
        let ratio = Double(water) / Double(max(1, p.waterTargetMl))
        // 限水: the target is a maximum, so only nearing or passing it is worth a word.
        if p.fluidLimited {
            if water > p.waterTargetMl { out.append(.attention("已超过限水上限 \(p.waterTargetMl) ml")) }
            else if ratio >= 0.9 { out.append(.attention("接近限水上限，还剩 \(p.waterTargetMl - water) ml")) }
            else { out.append(.neutral("限水上限 \(p.waterTargetMl) ml，还剩 \(p.waterTargetMl - water) ml")) }
        } else if ratio >= 1 { out.append(.good("饮水达到 \(p.waterTargetMl) ml")) }
        else if data.now.hour >= 15 && ratio < 0.5 { out.append(.attention("饮水偏少，目标 \(p.waterTargetMl) ml")) }
        else { out.append(.neutral("饮水目标 \(p.waterTargetMl) ml")) }

        let meals = data.todayMeals.count
        if r?.lateMeal == true { out.append(.attention("晚餐较晚，可能影响夜间心率")) }
        else if let q = r?.dietQuality {
            let label = ["不太理想", "一般", "比较均衡"][max(0, min(2, q - 1))]
            out.append(q >= 3 ? .good("饮食\(label)\(meals > 0 ? " · \(meals) 餐" : "")") : (q == 1 ? .attention("饮食\(label)") : .neutral("饮食\(label)\(meals > 0 ? " · \(meals) 餐" : "")")))
        } else {
            out.append(.neutral(meals > 0 ? "已记录 \(meals) 餐" : "还没有饮食记录"))
        }

        let cups = r?.caffeineCups ?? 0
        if cups == 0 { out.append(.good("今天没有咖啡因")) }
        else if let h = r?.lastCaffeineHour, h >= p.caffeineCutoffHour { out.append(.attention("\(h):00 后仍有咖啡因，可能影响入睡")) }
        else { out.append(.good("咖啡因 \(cups) 杯 · \(p.caffeineCutoffHour):00 前结束")) }

        let units = r?.alcoholUnits ?? 0
        if units > 0 {
            let week = data.analytics.days.filter { $0.day >= data.day.weekStart }.map(\.alcoholUnits).reduce(0, +)
            let line = "饮酒 \(units.oneDecimal) 单位 · 本周 \(week.oneDecimal)/\(p.weeklyAlcoholLimit.noDecimal)"
            out.append(week > p.weeklyAlcoholLimit ? .attention(line) : .neutral(line))
        }
        return out
    }
}

// MARK: - Meals

struct MealsCard: View {
    let meals: [MealLog]
    let fuelTip: (title: String, text: String)?
    var onLog: (QuickLogKind) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.item) {
            CardTitle(title: "饮食记录") {
                Button { onLog(.diet) } label: { Label("记录", systemImage: "plus") }
                    .buttonStyle(.bordered)
            }
            if meals.isEmpty {
                EmptyLine("还没有记录。简单记下整体情况即可，例如「午餐比较均衡」。")
            }
            ForEach(meals) { m in
                HStack(spacing: Theme.Space.block) {
                    IconTile(icon: m.kind.icon, color: Theme.nutrition)
                    VStack(alignment: .leading, spacing: Theme.Space.hairline) {
                        Text(m.kind.label).font(.body)
                        Text([Clock.text(m.time.minutesOfDay), m.note].filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Spacer(minLength: Theme.Space.tight)
                    if let c = m.carbsG {
                        Text("\(Int(c)) g 碳水").font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                .frame(minHeight: Theme.Size.tap)
                .accessibilityElement(children: .combine)
            }
            if let tip = fuelTip {
                Divider()
                IconTextRow(icon: "bolt.heart.fill", color: Theme.nutrition, title: tip.title, text: tip.text)
            }
            LogActionBar(items: [
                .init(title: "饮水", icon: "drop", action: { onLog(.water) }),
                .init(title: "咖啡因", icon: "cup.and.saucer", action: { onLog(.caffeine) }),
                .init(title: "饮酒", icon: "wineglass", action: { onLog(.alcohol) }),
                .init(title: "压力", icon: "brain.head.profile", action: { onLog(.stress) }),
            ])
            // The logging shortcuts are their own block below the rows.
            .padding(.top, Theme.Space.block - Theme.Space.item)
        }
        .cardSurface()
    }
}

// MARK: - Glucose today (CGM)

struct GlucoseDayCard: View {
    let points: [VitalPoint]
    let meals: [MealLog]
    let sessions: [ActivitySession]
    let profile: ProfileSnapshot

    var body: some View {
        let p = profile
        let inRange = Double(points.filter { $0.value >= p.glucoseLow && $0.value <= p.glucoseHigh }.count) / Double(max(1, points.count))
        let lows = points.filter { $0.value < p.glucoseLow }.count
        let status: MetricStatus = lows > 0 ? .attention("有 \(lows * 15) 分钟左右低于 \(p.glucoseLow.oneDecimal)")
            : (inRange >= 0.7 ? .good("目标范围内 \(Int(inRange * 100))%") : .attention("目标范围内 \(Int(inRange * 100))%，低于 70%"))
        HealthMetricCard(title: "今天的血糖", icon: "drop.fill", color: Theme.glucose, time: "CGM",
                         value: "\((points.map(\.value).min() ?? 0).oneDecimal)–\((points.map(\.value).max() ?? 0).oneDecimal)",
                         unit: "mmol/L", status: status) {
            Chart {
                GlucoseRangeMarks(low: p.glucoseLow, high: p.glucoseHigh)
                ForEach(sessions) { s in
                    RectangleMark(xStart: .value("开始", s.start), xEnd: .value("结束", s.start.addingTimeInterval(s.minutes * 60)))
                        .foregroundStyle(Theme.activity.opacity(0.18))
                        .annotation(position: .top) { Image(systemName: "figure.run").font(.caption2).foregroundStyle(Theme.activity) }
                }
                ForEach(Array(points.enumerated()), id: \.offset) { _, v in
                    LineMark(x: .value("时间", v.time), y: .value("mmol/L", v.value))
                        .foregroundStyle(Theme.glucose).interpolationMethod(.monotone)
                }
                ForEach(meals) { m in
                    RuleMark(x: .value("进餐", m.time)).foregroundStyle(Color.gray.opacity(0.6))
                        .annotation(position: .top) { Image(systemName: "fork.knife").font(.caption2).foregroundStyle(Color.gray) }
                }
            }
            .chartYScale(domain: 2.5...max(11, (points.map(\.value).max() ?? 8) + 1))
            .chartXAxis { AxisMarks(values: .stride(by: .hour, count: 3)) { _ in AxisGridLine(); AxisValueLabel(format: .dateTime.hour()) } }
            .chartYAxis { AxisMarks(position: .trailing, values: [4, 7, 10]) }
            .padding(.top, Theme.Space.block)
            .frame(height: 140)
            .accessibilityLabel("今天的血糖曲线")
            .accessibilityValue("目标范围内 \(Int(inRange * 100))%")
            Text("虚线之间为目标范围 · 灰色竖线为进餐 · 跑步图标为运动").font(.footnote).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Spot readings with context

struct ReadingsCard: View {
    let readings: [VitalPoint]
    let sessions: [ActivitySession]
    let meals: [MealLog]
    var onLog: (QuickLogKind) -> Void

    var body: some View {
        let list = readings.sorted { $0.time > $1.time }
        VStack(alignment: .leading, spacing: Theme.Space.item) {
            CardTitle(title: "测量记录") {
                NavigationLink { VitalsHistoryView() } label: {
                    Text("全部").font(.subheadline)
                        .frame(minWidth: Theme.Size.tap, minHeight: Theme.Size.tap, alignment: .trailing).contentShape(Rectangle())
                }
            }
            if list.isEmpty { EmptyLine("今天还没有测量记录。") }
            ForEach(Array(list.prefix(6).enumerated()), id: \.offset) { i, v in
                HStack(spacing: Theme.Space.block) {
                    IconTile(icon: v.kind.icon, color: v.kind == .glucose ? Theme.glucose : (v.kind == .weight ? Theme.body : Theme.heartData))
                    VStack(alignment: .leading, spacing: Theme.Space.hairline) {
                        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.tight) {
                            Text(v.kind.label).font(.body)
                            Text(valueText(v)).font(.body.weight(.semibold)).monospacedDigit()
                            Text(v.kind.unit).font(.footnote).foregroundStyle(.secondary)
                        }
                        Text("\(Clock.text(v.time.minutesOfDay)) · \(context(for: v))").font(.footnote).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .frame(minHeight: Theme.Size.tap)
                .accessibilityElement(children: .combine)
                if i < min(list.count, 6) - 1 { Divider().padding(.leading, Theme.Size.iconTile + Theme.Space.block) }
            }
            LogActionBar(items: [
                .init(title: "血压", icon: "heart.text.square", action: { onLog(.bloodPressure) }),
                .init(title: "血糖", icon: "drop", action: { onLog(.glucose) }),
                .init(title: "其他指标", icon: "waveform.path.ecg", action: { onLog(.vital) }),
                .init(title: "症状", icon: "person.fill.questionmark", action: { onLog(.symptom) }),
            ])
            // The logging shortcuts are their own block below the rows.
            .padding(.top, Theme.Space.block - Theme.Space.item)
        }
        .cardSurface()
    }

    private func valueText(_ v: VitalPoint) -> String {
        switch v.kind {
        case .bloodPressure: "\(Int(v.value))/\(Int(v.value2 ?? 0))"
        case .glucose, .lactate, .temperature, .weight: v.value.oneDecimal
        default: "\(Int(v.value))"
        }
    }

    /// What happened just before a reading: exercise, a meal, or the stated context.
    private func context(for v: VitalPoint) -> String {
        if let s = sessions.last(where: { $0.start <= v.time && v.time.timeIntervalSince($0.start.addingTimeInterval($0.minutes * 60)) < 2 * 3600 }) {
            let after = v.time.timeIntervalSince(s.start.addingTimeInterval(s.minutes * 60)) / 60
            return after < 0 ? "\(s.type.label)中" : "\(s.type.label)后 \(Int(after)) 分钟"
        }
        if let m = meals.last(where: { $0.time <= v.time && v.time.timeIntervalSince($0.time) < 3 * 3600 }) {
            return "\(m.kind.label)后 \(String(format: "%.1f", v.time.timeIntervalSince(m.time) / 3600)) 小时"
        }
        return v.context.label
    }
}

// MARK: - Care modules

struct CareTodayCard: View {
    let profile: ProfileSnapshot
    let record: DailyRecord?
    let readings: [VitalPoint]
    let tasks: [CareTask]

    var body: some View {
        let today = DayClock.logicalToday(.app, DayClock.current)
        VStack(alignment: .leading, spacing: Theme.Space.item) {
            CardTitle("照护事项", detail: "与你的照护计划保持一致")
            if profile.modules.contains(.cardioCare) {
                let bpToday = readings.filter { $0.kind == .bloodPressure && $0.time >= today }.count
                NavigationLink { CardioCareView() } label: {
                    NavRowLabel(icon: "heart.text.square.fill", color: Theme.heartData, title: "心血管健康",
                                detail: "今日血压 \(bpToday) 次 · 建议晨起、睡前各 1 次")
                }
                .buttonStyle(.plain)
                if let r = record {
                    Picker("今天是否按时服药", selection: Binding(get: { r.medsTaken }, set: { r.medsTaken = $0 })) {
                        Text("服药未记录").tag(Bool?.none)
                        Text("已按时服药").tag(Bool?.some(true))
                        Text("有漏服").tag(Bool?.some(false))
                    }
                    .pickerStyle(.segmented)
                    .padding(.leading, Theme.Size.iconTile + Theme.Space.block)
                }
            }
            if profile.modules.contains(.diabetesCare) {
                let g = readings.filter { $0.kind == .glucose && $0.time >= today }
                let inRange = g.isEmpty ? nil : Double(g.filter { $0.value >= profile.glucoseLow && $0.value <= profile.glucoseHigh }.count) / Double(g.count)
                if profile.modules.contains(.cardioCare) { Divider().padding(.leading, Theme.Size.iconTile + Theme.Space.block) }
                NavigationLink { DiabetesCareView() } label: {
                    NavRowLabel(icon: "drop.fill", color: Theme.glucose, title: "血糖管理",
                                detail: inRange.map { "今日目标范围内 \(Int($0 * 100))%" } ?? "今天还没有血糖数据")
                }
                .buttonStyle(.plain)
            }
            if let next = tasks.first(where: { $0.due != nil && [.cardio, .diabetes, .kidney, .sleep].contains($0.area) }) {
                if profile.modules.contains(.cardioCare) || profile.modules.contains(.diabetesCare) {
                    Divider().padding(.leading, Theme.Size.iconTile + Theme.Space.block)
                }
                let overdue = next.due! < .app
                let row = IconTextRow(icon: "calendar.badge.clock", color: overdue ? .orange : .secondary, title: next.title,
                                      text: "\(overdue ? "已到期" : "日期") \(next.due!.formatted(.dateTime.month().day()))")
                // A lab recheck opens 化验结果, where its schedule and date are.
                if LabRecheck.groups(inTitle: next.title).isEmpty { row } else {
                    NavigationLink { LabResultsView() } label: { row.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle()) }
                        .buttonStyle(.plain)
                }
            }
        }
        .cardSurface()
    }
}
