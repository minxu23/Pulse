import SwiftUI
import SwiftData
import Charts

/// 基线报告 (三阶段计划): the health portrait, how the user moves, what needs attention and why, and the
/// recommended pack.
struct BaselineReportView: View {
    let result: BaselineResult
    let profile: ProfileSnapshot
    /// Offered while the report can still lead to a pack (not when reopening a frozen one).
    var onChoose: (() -> Void)? = nil

    var body: some View {
        let r = result.report
        ScreenScroll {
            summaryCard(r)
            if onChoose != nil { recommendationCard(r) }
            ForEach(r.redFlags, id: \.self) { Callout(kind: .urgent, title: "先就医", text: $0) }
            ForEach(r.cautions, id: \.self) { Callout(kind: .caution, text: $0) }

            SectionTitle(title: "健康画像", subtitle: "和同龄同性别的人比")
            ForEach(r.cards) { AbilityCardView(card: $0) }

            DisclosureGroup("行为习惯与运动记录") {
                HabitsCard(habits: r.habits, age: profile.age)
            }
            .cardSurface()

            if !result.concerns.isEmpty {
                SectionTitle(title: "需要关注")
                ConcernsCard(concerns: result.concerns)
            }

            if onChoose == nil { recommendationCard(r) }

            PageFootnote("这份报告不是诊断。排名参考的人群和数据误差写在每一项下面；手表和体脂秤的数值是估算，看变化趋势比看单次更有意义。")
        }
        .safeAreaInset(edge: .bottom) {
            if let onChoose {
                Button("查看推荐方案", action: onChoose).buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity, minHeight: Theme.Size.tap).padding(Theme.Space.block).background(.bar)
            }
        }
        .navigationTitle("基线报告")
        .navigationBarTitleDisplayMode(.inline)
        .calmStyle()
    }

    private func summaryCard(_ r: BaselineReport) -> some View {
        Card {
            VStack(alignment: .leading, spacing: Theme.Space.tight) {
                Text(Self.range(r.window)).font(Theme.TypeScale.body).foregroundStyle(.secondary)
                Text(result.summaryLine).font(Theme.TypeScale.body).fixedSize(horizontal: false, vertical: true)
            }
            if !r.completeness.isReady {
                Callout(kind: .limitation, text: "还缺：" + r.completeness.missing.map { "\($0.label)（\($0.hint)）" }.joined(separator: "；") + "。缺的项目写「数据不足」，不做猜测。")
            }
        }
    }

    private func recommendationCard(_ r: BaselineReport) -> some View {
        let rec = result.recommendation.recommended
        let target = ProgramPacks.target(for: rec.pack, report: r, profile: profile)
        return Card {
            HStack(alignment: .top, spacing: Theme.Space.block) {
                IconTile(icon: rec.pack.icon, color: rec.pack.color)
                VStack(alignment: .leading, spacing: Theme.Space.hairline) {
                    Text(rec.pack.title).font(Theme.TypeScale.title)
                    Text(rec.reason).font(Theme.TypeScale.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            FactRow(label: "主靶点", value: target.title)
            if result.recommendation.doctorFirst {
                Callout(kind: .caution, text: "上面有需要先就医的情况。医生确认之前，方案只做基础层：步行、拉伸和作息。")
            }
            if let onChoose {
                Button("选择方案", action: onChoose).buttonStyle(.borderedProminent)
            }
        }
    }

    static func range(_ w: DateInterval) -> String {
        let f = Date.FormatStyle().month().day()
        let last = w.end.adding(days: -1)
        return "\(w.start.formatted(f)) – \(last.formatted(f)) · \(max(1, w.end.daysSince(w.start))) 天"
    }
}

// MARK: - Portrait

struct AbilityCardView: View {
    let card: AbilityCard

    var body: some View {
        Card {
            CardHeader(title: card.ability.title, subtitle: card.summary, icon: card.ability.icon, color: Self.color(card.ability)) {
                if let v = card.verdict { VerdictChip(verdict: v) }
            }
            ForEach(Array(card.metrics.enumerated()), id: \.element.id) { i, m in
                if i > 0 { Divider() }
                MetricLine(metric: m)
            }
        }
    }

    static func color(_ a: Ability) -> Color {
        switch a {
        case .heart: Theme.heartData
        case .fitness: Theme.activity
        case .metabolic: Theme.body
        case .sleep: Theme.sleep
        }
    }
}

struct VerdictChip: View {
    let verdict: Verdict
    var body: some View {
        Chip(text: verdict.label, color: Self.color(verdict))
    }
    static func color(_ v: Verdict) -> Color {
        switch v {
        case .good: Theme.good
        case .fair: .secondary
        case .attention: Theme.warning
        case .urgent: Theme.critical
        }
    }
}

private struct MetricLine: View {
    let metric: BaselineMetric

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.tight) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.item) {
                Text(metric.title).font(Theme.TypeScale.body.weight(.semibold))
                if metric.quality == .estimated { Text("估算").font(Theme.TypeScale.body).foregroundStyle(.secondary) }
                Spacer(minLength: Theme.Space.item)
                Text(metric.valueText).font(Theme.TypeScale.body.weight(.semibold)).monospacedDigit()
                    .foregroundStyle(metric.quality == .missing ? .secondary : .primary)
            }
            if let rank = metric.rank { RankBar(rank: rank) }
            Text(metric.detail).font(Theme.TypeScale.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let note = metric.note {
                DisclosureGroup("数据来源与参考") {
                    Text(note).font(Theme.TypeScale.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// Six segments as wide as the share of people in each band, from 后 10% on the left to 前 10% on the right.
struct RankBar: View {
    let rank: PeerRank
    private static let widths: [RankBand: CGFloat] = [.bottom10: 10, .bottom25: 15, .lowerMid: 25, .upperMid: 25, .top25: 15, .top10: 10]

    var body: some View {
        VStack(spacing: Theme.Space.hairline) {
            GeometryReader { geo in
                HStack(spacing: Theme.Space.hairline) {
                    ForEach(RankBand.allCases, id: \.self) { b in
                        Capsule()
                            .fill(b == rank.band ? Color.primary : Theme.subtle)
                            .frame(width: max(2, (geo.size.width - 10) * Self.widths[b]! / 100))
                    }
                }
            }
            .frame(height: 6)
            HStack {
                Text("靠后")
                Spacer()
                Text(rank.band.label).foregroundStyle(.primary)
                Spacer()
                Text("靠前")
            }
            .font(Theme.TypeScale.body).foregroundStyle(.secondary)
        }
        .padding(.vertical, Theme.Space.tight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("同龄同性别：\(rank.band.label)")
    }
}

// MARK: - Habits

private struct HabitsCard: View {
    let habits: HabitProfile
    let age: Int

    var body: some View {
        let h = habits
        Card {
            if let steps = h.stepsMean {
                FactRow(label: "日均步数", value: "\(Int(steps.rounded())) 步")
                if let wd = h.weekdaySteps, let we = h.weekendSteps {
                    FactRow(label: "工作日 / 周末", value: "\(Int(wd.rounded())) / \(Int(we.rounded())) 步")
                }
                if let stand = h.standHours { FactRow(label: "每天起身活动的小时数", value: "约 \(Int(stand.rounded())) 小时") }
            }
            if h.hourly.count == 24 {
                VStack(alignment: .leading, spacing: Theme.Space.item) {
                    Text("一天里什么时候在走").font(Theme.TypeScale.body.weight(.semibold))
                    Chart {
                        ForEach(0..<24, id: \.self) { hour in
                            BarMark(x: .value("时", hour), y: .value("步数", h.hourly[hour]))
                                .foregroundStyle(h.peakHours.contains(hour) ? Theme.activity : Theme.activity.opacity(0.35))
                        }
                    }.pulseChartAxes()
                    .chartXAxis { AxisMarks(values: [0, 6, 12, 18, 23]) { v in AxisValueLabel { Text("\(v.as(Int.self) ?? 0) 时") }.font(Theme.TypeScale.body) } }
                    .chartYAxis(.hidden)
                    .frame(height: 90)
                    .accessibilityLabel("走得最多的时段：" + h.peakHours.map { "\($0) 点" }.joined(separator: "、"))
                }
            }
            Divider()
            if h.sessions > 0 {
                if let slot = h.mainSlot { FactRow(label: "常运动的时段", value: slot.label) }
                FactRow(label: "饭后 2 小时内开始的运动", value: h.afterMeal.map { "\($0) 次" + (h.mealsFromGlucose ? "（按血糖推算的饭点）" : "") } ?? "没有饭点记录")
            }
            FactRow(label: "中高强度运动", value: "每周约 \(Int(h.guidelineMinutes)) 分钟")
            if !h.sports.isEmpty {
                Text("运动项目和运动中的心率").font(Theme.TypeScale.body.weight(.semibold)).padding(.top, Theme.Space.tight)
                ForEach(h.sports.prefix(4)) { SportLine(sport: $0, habits: h) }
            } else {
                Text("近 4 周没有记录到运动。").font(Theme.TypeScale.body).foregroundStyle(.secondary)
            }
            Divider()
            lifestyle(h)
        }
    }

    @ViewBuilder private func lifestyle(_ h: HabitProfile) -> some View {
        if let bed = h.bedtimeMean { FactRow(label: "平均入睡", value: CauseInference.clock(bed)) }
        if let shift = h.weekendShift, abs(shift) >= 30 { FactRow(label: "周末比平时", value: shift > 0 ? "晚睡约 \(Int(shift.rounded())) 分钟" : "早睡约 \(Int(-shift.rounded())) 分钟") }
        FactRow(label: "饮酒", value: h.alcoholPerWeek > 0 ? "每周约 \(h.alcoholPerWeek.shortDecimal) 份" : "没有记录")
        if h.lateCaffeineDays > 0 { FactRow(label: "下午以后喝咖啡或茶", value: "\(h.lateCaffeineDays) 天") }
        if h.lateMealDays > 0 { FactRow(label: "晚饭吃得晚", value: "\(h.lateMealDays) 天") }
    }
}

private struct SportLine: View {
    let sport: SportHabit
    let habits: HabitProfile

    var body: some View {
        let s = sport
        HStack(alignment: .top, spacing: Theme.Space.block) {
            IconTile(icon: s.type.icon, color: Theme.activity)
            VStack(alignment: .leading, spacing: Theme.Space.hairline) {
                Text("\(s.type.label) · 每周约 \(s.perWeek.shortDecimal) 次，每次 \(Int(s.minutes)) 分钟").font(Theme.TypeScale.body.weight(.semibold))
                Text(Self.line(s, habits)).font(Theme.TypeScale.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    static func line(_ s: SportHabit, _ h: HabitProfile) -> String {
        var parts: [String] = []
        var when = s.slot.map { "多在\($0.label)" } ?? ""
        if !s.weekdays.isEmpty { when += (when.isEmpty ? "常在" : "，常在") + s.weekdays.map(Weekday.name).joined(separator: "、") }
        if !when.isEmpty { parts.append(when) }
        if let r = s.reserveShare {
            var t = "平均心率在心率储备的 \(Int((r * 100).rounded()))%，对你来说是\(s.intensity.label)"
            if let v = s.vigorousShare, v >= 0.1 { t += "，\(Int((v * 100).rounded()))% 的时间在高强度区间" }
            parts.append(t)
        } else {
            parts.append("按运动项目和感觉估算是\(s.intensity.label)")
        }
        if let rec = s.recovery { parts.append("运动后 1 分钟心率降 \(Int(rec)) 次") }
        return parts.joined(separator: "；")
    }
}

// MARK: - Concerns

private struct ConcernsCard: View {
    let concerns: [Concern]

    var body: some View {
        Card {
            Text("下面列的是可能有关的原因，按有没有数据支持排序，不是诊断。").font(Theme.TypeScale.body).foregroundStyle(.secondary)
            ForEach(Array(concerns.enumerated()), id: \.element.id) { i, c in
                if i > 0 { Divider() }
                VStack(alignment: .leading, spacing: Theme.Space.item) {
                    Text(c.title).font(Theme.TypeScale.body.weight(.semibold))
                    ForEach(Array(c.causes.enumerated()), id: \.offset) { _, cause in
                        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.item) {
                            Chip(text: cause.evidence.label, color: cause.evidence == .doctor ? Theme.warning : .secondary)
                            Text(cause.text).font(Theme.TypeScale.body).fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                    }
                }
            }
        }
    }
}
