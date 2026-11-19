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
            HStack(spacing: Theme.Space.block) {
                Image(systemName: top.severity.icon).font(Theme.TypeScale.title).foregroundStyle(color)
                VStack(alignment: .leading, spacing: Theme.Space.hairline) {
                    Text(events.count == 1 ? top.title : "\(events.count) 项需要关注：\(top.title)")
                        .font(Theme.TypeScale.body.weight(.semibold)).foregroundStyle(.primary).multilineTextAlignment(.leading)
                    Text("\(top.severity.label) · 点击查看处理建议并记录跟进").font(Theme.TypeScale.body).foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: Theme.Space.item)
                Image(systemName: "chevron.right").font(Theme.TypeScale.body.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding(Theme.Space.cardPadding)
            .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous).stroke(color.opacity(0.3)))
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
            VStack(alignment: .leading, spacing: Theme.Space.block) {
                HStack(spacing: Theme.Space.block) {
                    ScoreRing(progress: Double(result.score ?? 0) / 100, color: color, lineWidth: 10) {
                        Text(result.score.map(String.init) ?? "—")
                            .font(Theme.TypeScale.title.weight(.bold)).monospacedDigit()
                            .lineLimit(1).padding(.horizontal, 10)
                    }
                    .frame(width: 88, height: 88)
                    .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: Theme.Space.tight) {
                        if result.score != nil {
                            StatusLabel(text: result.level.label, icon: "circle.fill", color: color)
                                .font(Theme.TypeScale.title.weight(.semibold)).imageScale(.small)
                        } else {
                            Text("待评估").font(Theme.TypeScale.title.weight(.semibold))
                        }
                        Text(result.confidence.label).font(Theme.TypeScale.body).foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
                Text(result.recommendation).font(Theme.TypeScale.body).fixedSize(horizontal: false, vertical: true)
                ForEach(result.overrides, id: \.self) { StatusLabel(text: $0, icon: "exclamationmark.triangle.fill", color: .orange).font(Theme.TypeScale.body) }
                ForEach(result.notes, id: \.self) { StatusLabel(text: $0, icon: "info.circle.fill", color: .gray, secondaryText: true).font(Theme.TypeScale.body) }
            }
            .cardSurface()

            SectionTitle(title: "各项依据", subtitle: "与你自己近 4 周比较")
            VStack(spacing: 0) {
                ForEach(result.factors) { f in
                    factorRow(f)
                    if f.id != result.factors.last?.id { Divider().padding(.leading, Theme.Size.iconTile + Theme.Space.block) }
                }
            }
            .cardSurface()

            PageFootnote("准备度看今天适合安排多少，活力度看今天实际动了多少。缺少的项目不计分，判断的把握会低一些。")
        }
        .navigationTitle("准备度依据")
        .navigationBarTitleDisplayMode(.inline)
        .calmStyle()
    }

    private func factorRow(_ f: ReadinessFactor) -> some View {
        // The bar's colour already says a factor helps; words only when it is missing or pulls the score down.
        let status: MetricStatus? = !f.available ? .neutral("未计入") : (f.impact == .negative ? .attention("拉低了准备度") : nil)
        return HStack(alignment: .top, spacing: Theme.Space.block) {
            IconTile(icon: f.icon, color: .secondary)
            VStack(alignment: .leading, spacing: Theme.Space.tight) {
                HStack(alignment: .firstTextBaseline, spacing: Theme.Space.item) {
                    Text(f.name).font(Theme.TypeScale.body.weight(.semibold))
                    Text("占 \(Int(f.weight * 100))%").font(Theme.TypeScale.body).foregroundStyle(.secondary)
                    Spacer()
                    Text(f.value).font(Theme.TypeScale.body).monospacedDigit().foregroundStyle(.secondary)
                }
                if let s = f.score {
                    ProgressBar(value: s / 100, color: f.impact == .negative ? .orange : (f.impact == .positive ? .green : .gray), height: 6)
                        .accessibilityHidden(true)
                }
                if let status { StatusLabel(status).font(Theme.TypeScale.body) }
                Text(f.detail.withoutOrphan).font(Theme.TypeScale.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, Theme.Space.item)
        .accessibilityElement(children: .combine)
    }
}
