import SwiftUI
import Charts

/// 晨起健康评估：结论在前（身体准备度与今日安排），依据在后（昨夜关键指标、夜间血压与血糖、
/// 睡眠呼吸、醒后感受）。卡片沿用「健康」App 的结构：类别图标与标题、大号数值与单位、一行状态。
struct MorningAssessmentView: View {
    let data: TodayData
    var onCheckIn: () -> Void
    var onLog: (QuickLogKind) -> Void
    var onStartEarly: () -> Void = {}

    var body: some View {
        let a = data.analytics
        let p = data.p
        let d = a.today
        let window = OvernightAnalyzer.nightWindow(for: a.now, today: d)
        let bp = OvernightAnalyzer.bloodPressure(data.recentVitals, morningOf: a.now, profile: p)
        let glucose = OvernightAnalyzer.glucose(data.recentVitals, window: window, profile: p)
        let breathing = OvernightAnalyzer.breathing(today: d, history: a.history, profile: p)

        let night = DayClock.isBeforeWake(data.now, data.p)
        if night { NightNoticeCard(data: data, onStartEarly: onStartEarly) }
        ReadinessHeroCard(result: data.readiness, analytics: a, checkedIn: data.record?.hasCheckIn == true, canCheckIn: !night, onCheckIn: onCheckIn)
        // The day's arrangement belongs to a day that has ended; the next one comes with the next assessment.
        if !night { ArrangementCard(guidance: data.guidance) }

        SectionTitle(title: "昨夜", subtitle: nightSubtitle(d))
        MetricGrid {
            sleepCard(d)
            rhrCard(d)
            hrvCard(d)
            oxygenCard(d)
        }
        BloodPressureNightCard(bp: bp, onLog: { onLog(.bloodPressure) })
        GlucoseNightCard(glucose: glucose, profile: p, onLog: { onLog(.glucose) })
        BreathingNightCard(breathing: breathing, day: d)

        WakeFeelingCard(record: data.record, canCheckIn: !night, onCheckIn: onCheckIn)

        PageFootnote("各项指标都与你自己近 4 周的数据比较。设备信号和自述线索用于提示关注，不能代替医疗诊断。")
    }

    private func nightSubtitle(_ d: DayData?) -> String? {
        guard let s = d?.sleepStart, let e = d?.sleepEnd else { return nil }
        return "\(Clock.text(s.minutesOfDay)) – \(Clock.text(e.minutesOfDay))"
    }

    private func impact(_ id: String) -> ReadinessFactor.Impact? {
        data.readiness.factors.first { $0.id == id && $0.available }?.impact
    }

    // MARK: Last-night metric cards

    private func sleepCard(_ d: DayData?) -> some View {
        let need = data.p.sleepNeedMinutes
        let r = data.record
        return HealthMetricCard(title: "睡眠", icon: "bed.double.fill", color: Theme.sleep,
                                value: d?.sleepMinutes.map { ($0 / 60).oneDecimal } ?? "—", unit: "小时",
                                status: d?.sleepMinutes.map { m in
                                    m >= need - 30 ? .good("达到目标 \((need / 60).oneDecimal) 小时") : .attention("少于目标 \((need / 60).oneDecimal) 小时")
                                } ?? .neutral("暂无数据")) {
            if let total = d?.sleepMinutes, total > 0 {
                SleepStagesBar(total: total, deep: d?.deepMinutes, rem: r?.remMinutes, awake: r?.awakeMinutes)
            } else {
                Button { onLog(.sleep) } label: {
                    Text("补记睡眠").frame(minHeight: Theme.Size.tap).contentShape(Rectangle())
                }
                .font(.subheadline)
            }
        }
    }

    private func rhrCard(_ d: DayData?) -> some View {
        let norm = Stats.mean(data.analytics.history.suffix(28).filter { $0.rhrSource == d?.rhrSource }.compactMap(\.rhr))
        let status: MetricStatus = {
            guard let r = d?.rhr else { return .neutral("暂无今晨数据") }
            guard let n = norm else { return .neutral("正在建立个人参照") }
            let diff = r - n
            if diff >= 4 { return .attention("比平时高 \(diff.noDecimal)") }
            if diff <= -2 { return .good("比平时低 \(abs(diff).noDecimal)") }
            return .neutral("与平时相近（\(n.noDecimal)）")
        }()
        return HealthMetricCard(title: "静息心率", icon: "heart.fill", color: Theme.heartData,
                                value: d?.rhr.map { $0.noDecimal } ?? "—", unit: "bpm", status: status) { EmptyView() }
    }

    private func hrvCard(_ d: DayData?) -> some View {
        let status: MetricStatus = {
            guard d?.hrv != nil else { return .neutral("暂无数据") }
            switch impact("hrv") {
            case .positive: return .good("在你的常见范围内")
            case .negative: return .attention("低于你的常见范围")
            case .neutral: return .neutral("略低于常见范围")
            case nil: return .neutral("参照建立中")
            }
        }()
        return HealthMetricCard(title: "心率变异性", icon: "waveform.path.ecg", color: Theme.heartData,
                                value: d?.hrv.map { $0.noDecimal } ?? "—", unit: "ms", status: status) { EmptyView() }
    }

    private func oxygenCard(_ d: DayData?) -> some View {
        let status: MetricStatus = {
            guard let s = d?.spo2Min else { return .neutral("暂无数据") }
            return s < 88 ? .attention("低于 88%") : .good("未低于 88%")
        }()
        return HealthMetricCard(title: "最低血氧", icon: "lungs.fill", color: Theme.respiratory,
                                value: d?.spo2Min.map { "\(Int($0))" } ?? "—", unit: "%", status: status) {
            if let rr = d?.respiratoryRate {
                Text("呼吸 \(rr.oneDecimal) 次/分").font(.footnote).foregroundStyle(.secondary)
            }
        }
    }
}

/// Sleep stages in the Health app's convention: deep, core, REM, awake.
struct SleepStagesBar: View {
    let total: Double
    let deep: Double?
    let rem: Double?
    let awake: Double?

    var body: some View {
        let deepM = deep ?? 0, remM = rem ?? 0, awakeM = awake ?? 0
        let core = max(0, total - deepM - remM)
        let parts: [(String, Double, Color)] = [("深睡", deepM, .indigo), ("核心", core, .blue), ("快速眼动", remM, .cyan), ("清醒", awakeM, .orange)]
        let sum = max(1, parts.map(\.1).reduce(0, +))
        VStack(alignment: .leading, spacing: Theme.Space.tight) {
            GeometryReader { geo in
                HStack(spacing: 2) {
                    ForEach(parts.filter { $0.1 > 0 }, id: \.0) { part in
                        Rectangle().fill(part.2).frame(width: max(2, (geo.size.width - 6) * part.1 / sum))
                    }
                }
            }
            .frame(height: 8)
            .clipShape(Capsule())
            if deep != nil {
                HStack(spacing: Theme.Space.item) {
                    legend("深睡", deepM, .indigo)
                    if rem != nil { legend("快速眼动", remM, .cyan) }
                }
                .font(.footnote).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.7)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("睡眠阶段：深睡 \(Int(deepM)) 分钟，快速眼动 \(Int(remM)) 分钟，清醒 \(Int(awakeM)) 分钟")
    }

    private func legend(_ name: String, _ minutes: Double, _ color: Color) -> some View {
        HStack(spacing: Theme.Space.tight) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text("\(name) \(Int(minutes)) 分")
        }
    }
}

// MARK: - Readiness hero and today's arrangement

struct ReadinessHeroCard: View {
    let result: ReadinessResult
    let analytics: Analytics
    let checkedIn: Bool
    var canCheckIn = true
    var onCheckIn: () -> Void

    var body: some View {
        let color = Theme.readiness(result.score == nil ? nil : result.level)
        VStack(alignment: .leading, spacing: Theme.Space.block) {
            HStack {
                Text("身体准备度").font(.headline)
                Spacer()
                Text(result.confidence.label).font(.footnote).foregroundStyle(.secondary)
            }
            HStack(spacing: Theme.Space.block) {
                ScoreRing(progress: Double(result.score ?? 0) / 100, color: color, lineWidth: 10) {
                    Text(result.score.map(String.init) ?? "—")
                        .font(.system(.title, design: .rounded).weight(.bold)).monospacedDigit()
                        .lineLimit(1).minimumScaleFactor(0.5).padding(.horizontal, 10)
                }
                .frame(width: 88, height: 88)
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Theme.Space.tight) {
                    if result.score != nil {
                        StatusLabel(text: result.level.label, icon: "circle.fill", color: color)
                            .font(.title3.weight(.semibold)).imageScale(.small)
                    } else {
                        Text("待评估").font(.title3.weight(.semibold))
                    }
                    Text(reason).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("身体准备度 \(result.score.map(String.init) ?? "待评估")，\(result.score == nil ? "" : result.level.label)，\(reason)")
            }
            if !checkedIn && canCheckIn {
                Button(action: onCheckIn) {
                    Label("记录醒后感受", systemImage: "sun.horizon.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            ForEach(result.overrides, id: \.self) { StatusLabel(text: $0, icon: "exclamationmark.triangle.fill", color: .orange).font(.subheadline) }
            Divider()
            NavigationLink { ReadinessDetailView(result: result, analytics: analytics) } label: {
                HStack {
                    Text("查看准备度依据").font(.body)
                    Spacer()
                    Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                }
                .frame(minHeight: Theme.Size.tap)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .cardSurface()
    }

    private var reason: String {
        guard result.score != nil else { return "结合昨夜睡眠、夜间指标和醒后感受评估今天的状态" }
        if let r = result.headline.split(separator: "：").dropFirst().first { return String(r) }
        return result.recommendation
    }
}

struct ArrangementCard: View {
    let guidance: ReadinessGuidance

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("今日安排").font(.headline).padding(.bottom, Theme.Space.tight)
            row("运动", "figure.run", Theme.activity, guidance.exercise)
            Divider().padding(.leading, Theme.Size.iconTile + Theme.Space.block)
            row("负荷", "gauge.with.dots.needle.50percent", Theme.heartData, guidance.load)
            Divider().padding(.leading, Theme.Size.iconTile + Theme.Space.block)
            row("恢复", "bed.double.fill", Theme.sleep, guidance.recovery)
        }
        .cardSurface()
    }

    private func row(_ title: String, _ icon: String, _ color: Color, _ text: String) -> some View {
        IconTextRow(icon: icon, color: color, title: title, text: text).padding(.vertical, Theme.Space.item)
    }
}

// MARK: - Overnight blood pressure

struct BloodPressureNightCard: View {
    let bp: OvernightBP
    var onLog: () -> Void

    var body: some View {
        let status: MetricStatus? = {
            if let s = bp.morningAvgSys, let d = bp.morningAvgDia, bp.morningDays >= 3 {
                let line = "近 7 天晨起平均 \(Int(s))/\(Int(d))"
                return bp.needsAttention ? .attention(line + "，值得持续关注") : .good(line)
            }
            return bp.morning == nil ? .neutral("今晨尚未测量") : nil
        }()
        HealthMetricCard(title: "夜间血压", icon: "heart.text.square.fill", color: Theme.heartData,
                         time: bp.morning.map { "今晨 \(Clock.text($0.time.minutesOfDay))" },
                         value: bp.morning.map { "\(Int($0.value))/\(Int($0.value2 ?? 0))" } ?? "—", unit: "mmHg",
                         status: status) {
            if let b = bp.bedtime, let m = bp.morning, let rise = bp.riseSys {
                HStack(spacing: Theme.Space.item) {
                    reading("昨晚睡前", b)
                    Image(systemName: "arrow.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                    reading("今晨", m)
                    Spacer()
                    Text("\(rise > 0 ? "+" : "")\(Int(rise))")
                        .font(.subheadline.weight(.semibold)).monospacedDigit()
                        .padding(.horizontal, Theme.Space.item).padding(.vertical, Theme.Space.tight)
                        .background(Theme.subtle, in: Capsule())
                        .accessibilityLabel("晨起收缩压变化 \(Int(rise)) 毫米汞柱")
                }
                .padding(.top, Theme.Space.hairline)
            }
            if bp.series.count >= 3 { chart }
            if bp.morning == nil {
                Button(action: onLog) { Label("测量晨起血压", systemImage: "plus") }
                    .buttonStyle(.bordered).controlSize(.regular)
                Text("起床后 1 小时内、排尿后、早餐和服药前，静坐 5 分钟测量。").font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private func reading(_ label: String, _ v: VitalPoint) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.tight) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text("\(Int(v.value))/\(Int(v.value2 ?? 0))").font(.subheadline.weight(.semibold)).monospacedDigit()
        }
    }

    private var chart: some View {
        let values = bp.series.map(\.value) + [bp.bedtime?.value].compactMap { $0 } + [135]
        return VStack(alignment: .leading, spacing: Theme.Space.tight) {
            Chart {
                RuleMark(y: .value("参考", 135))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3])).foregroundStyle(Color.gray.opacity(0.7))
                    .annotation(position: .top, alignment: .leading) { Text("135").font(.caption2).foregroundStyle(.secondary) }
                ForEach(Array(bp.series.enumerated()), id: \.offset) { _, v in
                    LineMark(x: .value("日期", v.time, unit: .day), y: .value("晨起收缩压", v.value))
                        .foregroundStyle(Theme.heartData).interpolationMethod(.catmullRom)
                    PointMark(x: .value("日期", v.time, unit: .day), y: .value("晨起收缩压", v.value))
                        .foregroundStyle(Theme.heartData).symbolSize(16)
                }
                if let b = bp.bedtime {
                    PointMark(x: .value("日期", b.time.startOfDay.adding(days: 1), unit: .day), y: .value("睡前", b.value))
                        .symbol(.diamond).foregroundStyle(Color.gray).symbolSize(36)
                }
            }
            .chartYScale(domain: ((values.min() ?? 110) - 6)...((values.max() ?? 140) + 6))
            .chartXAxis { AxisMarks(values: .stride(by: .day, count: 7)) { _ in AxisGridLine(); AxisValueLabel(format: .dateTime.month().day(), collisionResolution: .greedy) } }
            .chartYAxis { AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) }
            .frame(height: 120)
            .accessibilityLabel("近 14 天晨起收缩压")
            .accessibilityValue("范围 \(Int(bp.series.map(\.value).min() ?? 0)) 到 \(Int(bp.series.map(\.value).max() ?? 0))")
            Text("近 14 天晨起收缩压\(bp.bedtime != nil ? " · ◆ 昨晚睡前" : "") · 虚线 135 为家庭血压参考值")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .padding(.top, Theme.Space.tight)
    }
}

// MARK: - Overnight glucose

struct GlucoseNightCard: View {
    let glucose: OvernightGlucose
    let profile: ProfileSnapshot
    var onLog: () -> Void

    var body: some View {
        if glucose.isContinuous, let lo = glucose.min, let hi = glucose.max {
            HealthMetricCard(title: "夜间血糖", icon: "drop.fill", color: Theme.glucose,
                             time: "\(Clock.text(glucose.window.start.minutesOfDay)) – \(Clock.text(glucose.window.end.minutesOfDay))",
                             value: "\(lo.oneDecimal)–\(hi.oneDecimal)", unit: "mmol/L", status: status) {
                Chart {
                    GlucoseRangeMarks(low: profile.glucoseLow, high: profile.glucoseHigh)
                    ForEach(Array(glucose.points.enumerated()), id: \.offset) { _, v in
                        LineMark(x: .value("时间", v.time), y: .value("mmol/L", v.value))
                            .foregroundStyle(Theme.glucose).interpolationMethod(.monotone)
                    }
                }
                .chartYScale(domain: 2.5...max(11, hi + 1))
                .chartXAxis { AxisMarks(values: .stride(by: .hour, count: 2)) { _ in AxisGridLine(); AxisValueLabel(format: .dateTime.hour()) } }
                .chartYAxis { AxisMarks(position: .trailing, values: [4, 7, 10]) }
                .frame(height: 110)
                .accessibilityLabel("夜间血糖曲线")
                .accessibilityValue("范围 \(lo.oneDecimal) 到 \(hi.oneDecimal) 毫摩尔每升")
                Text("虚线之间为目标范围 \(profile.glucoseLow.oneDecimal)–\(profile.glucoseHigh.oneDecimal) mmol/L")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        } else if let f = glucose.fasting {
            HealthMetricCard(title: "空腹血糖", icon: "drop.fill", color: Theme.glucose,
                             time: "今晨 \(Clock.text(f.time.minutesOfDay))", value: f.value.oneDecimal, unit: "mmol/L",
                             status: f.value < profile.glucoseLow ? .attention("偏低，请按照护计划处理并复测") : .neutral("早餐前测量")) { EmptyView() }
        } else if profile.hasDiabetes {
            HealthMetricCard(title: "夜间血糖", icon: "drop.fill", color: Theme.glucose, value: "—", unit: "mmol/L",
                             status: .neutral("今晨尚未记录")) {
                Button(action: onLog) { Label("记录空腹血糖", systemImage: "plus") }.buttonStyle(.bordered)
                Text("佩戴 CGM 可以看到夜间完整的波动趋势。").font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private var status: MetricStatus {
        if glucose.lowAlert { return .attention("夜间约 \(glucose.minutesBelow) 分钟低于 \(profile.glucoseLow.oneDecimal)") }
        if glucose.minutesAbove >= 60 { return .attention("夜间约 \(glucose.minutesAbove) 分钟高于 \(profile.glucoseHigh.oneDecimal)") }
        if let rise = glucose.dawnRise, rise >= 1.0 { return .neutral("清晨前上升约 \(rise.oneDecimal)") }
        return .good("整体平稳 · 平均 \(glucose.mean?.oneDecimal ?? "—")")
    }
}

// MARK: - Sleep breathing

struct BreathingNightCard: View {
    let breathing: OvernightBreathing
    let day: DayData?

    var body: some View {
        let cues: [(String, Bool)] = [("打鼾", breathing.snoring), ("憋醒", breathing.gasping), ("被观察到暂停", breathing.witnessed)]
        let count = cues.filter(\.1).count
        HealthMetricCard(title: "睡眠呼吸", icon: "lungs.fill", color: Theme.respiratory,
                         value: count == 0 ? "无明显线索" : "\(count) 项线索",
                         status: breathing.needsAttention ? .attention("建议持续记录，必要时进行专业睡眠评估") : nil,
                         valueFont: .title3.weight(.semibold)) {
            HStack(spacing: Theme.Space.item) {
                ForEach(cues, id: \.0) { cue in
                    StatusLabel(text: cue.0, icon: cue.1 ? "exclamationmark.circle.fill" : "checkmark.circle", color: cue.1 ? .orange : .gray,
                                secondaryText: !cue.1)
                        .font(.footnote).lineLimit(1).minimumScaleFactor(0.8)
                        .padding(Theme.Space.item)
                        .frame(maxWidth: .infinity)
                        .background(Theme.subtle.opacity(0.7), in: RoundedRectangle(cornerRadius: Theme.Radius.inner, style: .continuous))
                }
            }
            if let dist = breathing.disturbances {
                Text("呼吸紊乱 \(dist.oneDecimal)\(breathing.disturbancesNorm.map { " · 近 30 天平均 \($0.oneDecimal)" } ?? "")")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if let h = breathing.cpapHours, let t = breathing.cpapTarget {
                StatusLabel(text: "CPAP 使用 \(h.oneDecimal) 小时（目标 \(Int(t))）", icon: h >= t ? "checkmark.circle.fill" : "exclamationmark.circle.fill",
                            color: h >= t ? .green : .orange, secondaryText: true).font(.footnote)
            }
        }
    }
}

// MARK: - Wake-up feeling

/// Before 5 am the page shows the morning that has passed; the next assessment comes after sleep.
struct NightNoticeCard: View {
    let data: TodayData
    var onStartEarly: () -> Void = {}
    var body: some View {
        let p = data.p
        let left = max(0, Int(data.window.nextWake.timeIntervalSince(data.now) / 60) - 15)
        let next = data.day.adding(days: 1)
        VStack(alignment: .leading, spacing: Theme.Space.block) {
            Label("现在\(data.now.hour < 5 ? "是凌晨" : "") \(Clock.text(data.now.minutesOfDay))", systemImage: "moon.stars.fill")
                .font(.headline)
            Text("下面是 \(data.day.formatted(.dateTime.month().day())) \(p.shift == nil ? "早上" : "起床时")的评估。\(next.formatted(.dateTime.month().day())) 的晨起评估在你睡醒后进行，到 \(Clock.text(data.window.nextWake.minutesOfDay)) 起床还能睡约 \((Double(left) / 60).oneDecimal) 小时。")
                .font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if DayClock.canStartEarly(data.now, data.p) {
                Divider()
                HStack {
                    Text("已经起床了？").font(.subheadline).foregroundStyle(.secondary)
                    Spacer()
                    Button("开始今天", action: onStartEarly).buttonStyle(.bordered).tint(Theme.accent)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
        .accessibilityElement(children: .contain)
    }
}

struct WakeFeelingCard: View {
    let record: DailyRecord?
    var canCheckIn = true
    var onCheckIn: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.block) {
            HStack {
                Label {
                    Text("醒后感受")
                } icon: {
                    Image(systemName: "face.smiling").foregroundStyle(Theme.mind)
                }
                .font(.headline)
                if let t = record?.checkInAt { Text(Clock.text(t.minutesOfDay)).font(.footnote).foregroundStyle(.secondary) }
                Spacer()
                if record?.hasCheckIn == true {
                    Button("修改", action: onCheckIn).buttonStyle(.bordered)
                }
            }
            if let r = record, r.hasCheckIn {
                HStack(spacing: 0) {
                    item("精力", r.energy.map { "\($0)/5" })
                    item("睡眠感受", r.sleepFeel.map { "\($0)/5" })
                    item("酸痛", r.soreness.map { ["无", "轻微", "明显", "严重"][min(3, $0)] })
                    item("压力", r.stress.map { "\($0)/5" })
                }
                if r.illnessSymptoms {
                    StatusLabel(text: "记录了不适症状，今天以休息为主", icon: "thermometer.medium", color: .red).font(.footnote)
                }
            } else if canCheckIn {
                Text("精力、酸痛和压力会影响今天适合的运动强度。").font(.subheadline).foregroundStyle(.secondary)
                Button(action: onCheckIn) {
                    Label("记录醒后感受", systemImage: "sun.horizon.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
            } else {
                Text("这一天早上没有记录。下一次醒后感受在你睡醒后记录。").font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .cardSurface()
    }

    private func item(_ label: String, _ value: String?) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.tight) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value ?? "—").font(.headline).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
