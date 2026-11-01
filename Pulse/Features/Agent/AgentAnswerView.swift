import SwiftUI

// One Health Agent answer, in the parts `AgentAnswerLayout` reads from it: a status tag and the
// verdict in bold, the numbers it stands on (tiles, a small chart), explanations, lists under their
// own titles with a glyph per line, and the line about when to see a doctor in a box of its own.

struct AgentAnswerView: View {
    let text: String
    let reply: AgentReply?
    let context: AgentContext
    /// The cards shown under the answer; what a plan card shows is not repeated in the text.
    var cards: [AgentUIBlock] = []
    @ScaledMetric(relativeTo: .body) private var lineGap = Theme.Space.readingLine

    var body: some View {
        let sections = AgentAnswerLayout.sections(of: text, reply: reply, cards: cards)
        let hasVerdict: Bool = { if case .verdict? = sections.first { true } else { false } }()
        VStack(alignment: .leading, spacing: Theme.Space.block) {
            if let s = reply?.status { AgentStatusTag(status: s) }
            if !hasVerdict, let f = reply?.figure { AgentFigureView(figure: f, context: context) }
            ForEach(Array(sections.enumerated()), id: \.offset) { _, section in
                switch section {
                case .verdict(let t):
                    Text(Self.styled(t, highlight: false)).font(.headline).fixedSize(horizontal: false, vertical: true)
                    if let f = reply?.figure { AgentFigureView(figure: f, context: context) }
                case .paragraph(let t):
                    // The figure already shows a paragraph that only lists its numbers.
                    if reply?.figure.map({ AgentAnswerLayout.restates(t, figure: $0) }) != true {
                        Text(Self.styled(t)).font(.body).fixedSize(horizontal: false, vertical: true)
                    }
                case .note(let t):
                    Text(Self.styled(t, highlight: false)).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                case .list(let title, let style, let items):
                    AnswerList(title: title, style: style, items: items)
                case .safety(let t):
                    Callout(kind: t.contains("120") ? .urgent : .caution, title: Self.safetyTitle(t), text: t)
                }
            }
        }
        .lineSpacing(lineGap)
        .textSelection(.enabled)
    }

    /// What the safety box is about, in a few words.
    static func safetyTitle(_ t: String) -> String {
        if t.contains("120") { return "这些情况马上拨打 120" }
        if ["医生", "就医", "医院", "门诊", "透析中心"].contains(where: { t.contains($0) }) { return "什么时候去看医生" }
        return "特别注意"
    }

    /// Inline Markdown (bold from a language model), line breaks kept, measured values in bold.
    static func styled(_ s: String, highlight: Bool = true) -> AttributedString {
        var a = (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
        guard highlight else { return a }
        let plain = String(a.characters)
        for r in AgentAnswerLayout.highlights(in: plain) {
            let lo = a.characters.index(a.startIndex, offsetBy: plain.distance(from: plain.startIndex, to: r.lowerBound))
            let hi = a.characters.index(a.startIndex, offsetBy: plain.distance(from: plain.startIndex, to: r.upperBound))
            a[lo..<hi].inlinePresentationIntent = .stronglyEmphasized
        }
        return a
    }
}

/// The tag over the verdict: a glyph that carries the colour and shape, and readable words.
struct AgentStatusTag: View {
    let status: AgentStatus

    var body: some View {
        HStack(spacing: Theme.Space.iconGap) {
            Image(systemName: status.tone.icon).foregroundStyle(status.tone.color).imageScale(.small)
            Text(status.label).foregroundStyle(.primary)
        }
        .font(.subheadline.weight(.semibold))
        .padding(.horizontal, Theme.Space.item)
        .padding(.vertical, Theme.Space.tight)
        .background(status.tone.color.opacity(0.12), in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("结论：\(status.label)")
    }
}

extension AgentStatus.Tone {
    var color: Color {
        switch self {
        case .good: Theme.good
        case .attention: Theme.warning
        case .urgent: Theme.critical
        }
    }
    var icon: String {
        switch self {
        case .good: "checkmark.circle.fill"
        case .attention: "exclamationmark.circle.fill"
        case .urgent: "exclamationmark.triangle.fill"
        }
    }
}

// MARK: - Lists

private struct AnswerList: View {
    let title: String?
    let style: AgentAnswerLayout.ListStyle
    let items: [AgentAnswerLayout.Item]
    @Environment(\.dynamicTypeSize) private var size

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.item) {
            if let title {
                Label(title, systemImage: style == .findings ? "magnifyingglass" : "checklist")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                    .accessibilityAddTraits(.isHeader)
            }
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .top, spacing: Theme.Space.block) {
                    // Decorative: at accessibility sizes the words get the whole line.
                    if !size.isAccessibilitySize { IconTile(icon: item.icon) }
                    Text(line(item)).font(.body).fixedSize(horizontal: false, vertical: true)
                        // Level with the middle of the tile when the line is short.
                        .frame(minHeight: size.isAccessibilitySize ? nil : Theme.Size.iconTile, alignment: .leading)
                    Spacer(minLength: 0)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    private func line(_ item: AgentAnswerLayout.Item) -> AttributedString {
        var text = AgentAnswerView.styled(item.text)
        if let label = item.label {
            var head = AttributedString(label + "：")
            head.inlinePresentationIntent = .stronglyEmphasized
            text = head + text
        }
        return text
    }
}

// MARK: - Figures

/// The numbers behind an answer: tiles side by side, then the range bar or the chart.
struct AgentFigureView: View {
    let figure: AgentFigure
    let context: AgentContext
    /// Grows with the axis labels, so they keep apart at large text sizes.
    @ScaledMetric(relativeTo: .caption) private var chartHeight: CGFloat = 110

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.block) {
            MetricRow {
                ForEach(Array(figure.tiles.enumerated()), id: \.offset) { _, t in FigureTile(tile: t) }
            }
            if !figure.parts.isEmpty { RangeBar(parts: figure.parts) }
            if let m = figure.chart {
                AgentMetricChart(metric: m, days: m.clampDays(figure.days), context: context, height: chartHeight)
            }
        }
    }
}

private struct FigureTile: View {
    let tile: AgentFigure.Tile

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.tight) {
            HStack(spacing: Theme.Space.iconGap) {
                if let tone = tile.tone { Image(systemName: tone.icon).foregroundStyle(tone.color).imageScale(.small) }
                Text(tile.label).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
            }
            .font(.caption)
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.tight) {
                Text(tile.value).font(.title3.weight(.semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
                if !tile.unit.isEmpty { Text(tile.unit).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
            if let note = tile.note { Text(note).font(.caption).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(Theme.Space.block)
        .background(Theme.subtle.opacity(0.6), in: RoundedRectangle(cornerRadius: Theme.Radius.inner, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([tile.label, tile.value + tile.unit, tile.note, tile.tone.map { $0 == .good ? "正常" : "需要留意" }]
            .compactMap { $0 }.joined(separator: "，"))
    }
}

/// A bar that adds up to 100% — time below, in and above the glucose range — with its legend.
private struct RangeBar: View {
    let parts: [AgentFigure.Part]

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.item) {
            GeometryReader { geo in
                let total = max(parts.map(\.share).reduce(0, +), 0.0001)
                HStack(spacing: Theme.Space.hairline) {
                    ForEach(Array(parts.enumerated()), id: \.offset) { _, p in
                        // A small share keeps a sliver, so it is still seen.
                        Rectangle().fill(p.tone.color)
                            .frame(width: p.share > 0 ? max(4, (geo.size.width - Theme.Space.hairline * CGFloat(parts.count - 1)) * p.share / total) : 0)
                    }
                }
                .clipShape(Capsule())
            }
            .frame(height: 12)
            HStack(spacing: Theme.Space.block) {
                ForEach(Array(parts.enumerated()), id: \.offset) { _, p in
                    HStack(spacing: Theme.Space.tight) {
                        Image(systemName: p.tone.icon).foregroundStyle(p.tone.color).imageScale(.small)
                        Text("\(p.label) \(Self.percent(p.share))").foregroundStyle(.secondary).monospacedDigit()
                    }
                }
            }
            .font(.footnote)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(parts.map { "\($0.label) \(Self.percent($0.share))" }.joined(separator: "，"))
    }

    static func percent(_ v: Double) -> String {
        v < 0.1 ? String(format: "%.1f%%", v * 100) : "\(Int((v * 100).rounded()))%"
    }
}
