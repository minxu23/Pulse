import SwiftUI
import SwiftData
import Charts

// MARK: - Events banner

struct EventsBanner: View {
    let events: [HealthEvent]
    var body: some View {
        let top = events[0]
        let color = Theme.severity(top.severity)
        NavigationLink { HealthEventsView() } label: {
            HStack(spacing: 12) {
                Image(systemName: top.severity.icon).font(.title3).foregroundStyle(color)
                VStack(alignment: .leading, spacing: 2) {
                    Text(events.count == 1 ? top.title : "\(events.count) 项需要关注：\(top.title)")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(.primary).multilineTextAlignment(.leading)
                    Text("\(top.severity.label) · 点击查看处理建议并记录跟进").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }
            .padding(14)
            .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(color.opacity(0.3)))
        }
        .buttonStyle(.plain)
    }
}

struct ReadinessDetailView: View {
    let result: ReadinessResult
    let analytics: Analytics

    var body: some View {
        let color = Theme.readiness(result.score == nil ? nil : result.level)
        ScreenScroll {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 18) {
                    ScoreRing(progress: Double(result.score ?? 0) / 100, color: color, lineWidth: 10) {
                        Text(result.score.map(String.init) ?? "—")
                            .font(.system(.title, design: .rounded).weight(.bold)).monospacedDigit()
                            .lineLimit(1).minimumScaleFactor(0.5).padding(.horizontal, 10)
                    }
                    .frame(width: 88, height: 88)
                    .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 6) {
                        if result.score != nil {
                            StatusLabel(text: result.level.label, icon: "circle.fill", color: color)
                                .font(.title3.weight(.semibold)).imageScale(.small)
                        } else {
                            Text("待评估").font(.title3.weight(.semibold))
                        }
                        Text(result.confidence.label).font(.subheadline).foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
                Text(result.recommendation).font(.body).fixedSize(horizontal: false, vertical: true)
                ForEach(result.overrides, id: \.self) { StatusLabel(text: $0, icon: "exclamationmark.triangle.fill", color: .orange).font(.subheadline) }
                ForEach(result.notes, id: \.self) { StatusLabel(text: $0, icon: "info.circle.fill", color: .gray, secondaryText: true).font(.subheadline) }
            }
            .cardSurface()

            SectionTitle(title: "各项依据", subtitle: "与你自己近 4 周比较")
            VStack(spacing: 0) {
                ForEach(result.factors) { f in
                    factorRow(f)
                    if f.id != result.factors.last?.id { Divider().padding(.leading, 44) }
                }
            }
            .cardSurface()

            VStack(alignment: .leading, spacing: 10) {
                CardTitle("准备度与活力度")
                IconTextRow(icon: "gauge.with.dots.needle.50percent", color: .secondary, title: "身体准备度",
                            text: "回答「今天适合安排多少」，依据昨夜睡眠、夜间身体指标、近期负荷和醒后感受。")
                IconTextRow(icon: "bolt.heart.fill", color: Theme.activity, title: "身体活力度",
                            text: "回答「今天实际活动了多少」，依据步数与活动时间。两者一起用于调整当天计划。")
            }
            .cardSurface()
            PageFootnote("缺少的项目不计入总分，并会降低判断的把握程度。")
        }
        .navigationTitle("准备度依据")
        .navigationBarTitleDisplayMode(.inline)
        .calmStyle()
    }

    private func factorRow(_ f: ReadinessFactor) -> some View {
        let status: MetricStatus = !f.available ? .neutral("未计入") :
            (f.impact == .positive ? .good("支持今天的安排") : (f.impact == .negative ? .attention("拉低了准备度") : .neutral("影响不大")))
        return HStack(alignment: .top, spacing: 12) {
            IconTile(icon: f.icon, color: .secondary)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(f.name).font(.subheadline.weight(.semibold))
                    Spacer()
                    Text(f.value).font(.subheadline).monospacedDigit().foregroundStyle(.secondary)
                }
                if let s = f.score {
                    ProgressBar(value: s / 100, color: f.impact == .negative ? .orange : (f.impact == .positive ? .green : .gray), height: 6)
                        .accessibilityHidden(true)
                }
                StatusLabel(status).font(.footnote)
                Text(f.detail).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text("权重 \(Int(f.weight * 100))%").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }
}
