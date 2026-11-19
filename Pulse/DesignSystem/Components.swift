import SwiftUI
import Charts

// Shared building blocks for the redesigned pages. Pages lead with the conclusion and keep the
// evidence below it; every card uses the same shape, spacing and type ramp as the Health app.

// MARK: - Status

/// One status line: the glyph carries colour and shape, the text stays readable.
struct MetricStatus {
    let text: String
    let icon: String
    let color: Color
    static func good(_ t: String) -> MetricStatus { .init(text: t, icon: "checkmark.circle.fill", color: .green) }
    static func attention(_ t: String) -> MetricStatus { .init(text: t, icon: "exclamationmark.circle.fill", color: .orange) }
    static func urgent(_ t: String) -> MetricStatus { .init(text: t, icon: "exclamationmark.triangle.fill", color: .red) }
    static func neutral(_ t: String) -> MetricStatus { .init(text: t, icon: "minus.circle.fill", color: .gray) }
}

extension StatusLabel {
    init(_ status: MetricStatus, secondaryText: Bool = true) {
        self.init(text: status.text, icon: status.icon, color: status.color, secondaryText: secondaryText)
    }
}

// MARK: - Card surfaces

extension View {
    /// The standard card surface: card padding, grouped background, panel corners.
    func cardSurface(padding: CGFloat = Theme.Space.cardPadding) -> some View {
        self.padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous))
    }
}

/// Card title row: headline text, optional secondary detail and a trailing accessory.
struct CardTitle<Trailing: View>: View {
    let title: String
    var detail: String? = nil
    @ViewBuilder var trailing: Trailing
    @Environment(\.dynamicTypeSize) private var size

    var body: some View {
        // At accessibility sizes the detail and the button go under the title.
        AdaptiveStack(alignment: .firstTextBaseline, spacing: Theme.Space.item, stackedSpacing: Theme.Space.tight) {
            Text(title).font(Theme.TypeScale.headline).accessibilityAddTraits(.isHeader)
            if let detail { Text(detail).font(Theme.TypeScale.body).foregroundStyle(.secondary) }
            if !size.isAccessibilitySize { Spacer(minLength: Theme.Space.item) }
            trailing
        }
    }
}

extension CardTitle where Trailing == EmptyView {
    init(_ title: String, detail: String? = nil) {
        self.init(title: title, detail: detail) { EmptyView() }
    }
}

/// Health-style card: category glyph and title, optional time, large value with unit, one status line.
struct HealthMetricCard<Footer: View>: View {
    let title: String
    let icon: String
    let color: Color
    var time: String? = nil
    let value: String
    var unit: String = ""
    var status: MetricStatus? = nil
    var valueFont: Font = Theme.TypeScale.title.weight(.semibold)
    @ViewBuilder var footer: Footer
    @Environment(\.dynamicTypeSize) private var size

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.item) {
            // At accessibility sizes the time goes under the title, which would otherwise be one character wide.
            if size.isAccessibilitySize {
                VStack(alignment: .leading, spacing: Theme.Space.hairline) {
                    Label { Text(title) } icon: { Image(systemName: icon).foregroundStyle(color) }
                        .font(Theme.TypeScale.body.weight(.semibold)).labelStyle(.inline)
                    if let time { Text(time).font(Theme.TypeScale.body).foregroundStyle(.secondary) }
                }
            } else {
                // In a half-width card the time or period goes under the title rather than squeezing both onto two lines.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: Theme.Space.iconGap) {
                        titleLabel
                        Spacer(minLength: Theme.Space.item)
                        if let time { Text(time).font(Theme.TypeScale.body).foregroundStyle(.secondary).lineLimit(1) }
                    }
                    VStack(alignment: .leading, spacing: Theme.Space.hairline) {
                        titleLabel
                        if let time { Text(time).font(Theme.TypeScale.body).foregroundStyle(.secondary).lineLimit(1) }
                    }
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.tight) {
                Text(value).font(valueFont).monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.6)
                if !unit.isEmpty { Text(unit).font(Theme.TypeScale.body).foregroundStyle(.secondary) }
            }
            if let s = status {
                StatusLabel(s).font(Theme.TypeScale.body).lineLimit(2)
            }
            footer
        }
        .padding(Theme.Space.cardPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private var titleLabel: some View {
        HStack(spacing: Theme.Space.iconGap) {
            Image(systemName: icon).font(Theme.TypeScale.body.weight(.semibold)).imageScale(.small).foregroundStyle(color)
            Text(title).font(Theme.TypeScale.body.weight(.semibold)).lineLimit(1)
        }
    }
}

extension HealthMetricCard where Footer == EmptyView {
    init(title: String, icon: String, color: Color, time: String? = nil, value: String, unit: String = "",
         status: MetricStatus? = nil, valueFont: Font = Theme.TypeScale.title.weight(.semibold)) {
        self.init(title: title, icon: icon, color: color, time: time, value: value, unit: unit, status: status,
                  valueFont: valueFont) { EmptyView() }
    }
}

/// Two equal columns for metric cards, spaced like cards in a stack; one column at accessibility sizes.
struct MetricGrid<Content: View>: View {
    @ViewBuilder var content: Content
    @Environment(\.dynamicTypeSize) private var size
    var body: some View {
        let gap = Theme.Space.cardGap
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: gap), count: size.isAccessibilitySize ? 1 : 2), spacing: gap) {
            content
        }
    }
}

struct SectionTitle: View {
    let title: String
    var subtitle: String? = nil
    var body: some View {
        AdaptiveStack(alignment: .firstTextBaseline, spacing: Theme.Space.item, stackedSpacing: Theme.Space.hairline) {
            Text(title).font(Theme.TypeScale.title.bold())
            if let subtitle { Text(subtitle).font(Theme.TypeScale.body).foregroundStyle(.secondary) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Theme.Space.tight)
        // In a card stack: a section gap above, and the title sits closer to its own cards than cards to each other.
        .padding(.top, Theme.Space.section - Theme.Space.cardGap)
        .padding(.bottom, -Theme.Space.tight)
        .accessibilityAddTraits(.isHeader)
    }
}

/// Short facts shown as 「A · B · C」 that wrap only between facts: a number never leaves its label
/// (「血糖 / 5.6」, 「12 小 / 时」), and no line starts or ends with a dot. Font and colour come from the caller.
struct PartsText: View {
    let parts: [String]
    var maxLines = 2

    init(_ parts: [String], maxLines: Int = 2) {
        self.parts = parts.filter { !$0.isEmpty }
        self.maxLines = maxLines
    }

    var body: some View {
        let p = parts
        if p.count < 2 {
            Text(p.first ?? "").lineLimit(maxLines)
        } else {
            // The first arrangement that fits wins: one line, then two lines with as much as possible on the first.
            ViewThatFits(in: .horizontal) {
                line(p[...])
                ForEach(Array((1..<p.count).reversed()), id: \.self) { k in
                    lines([p[..<k], p[k...]])
                }
                if maxLines > 2 {
                    // Last resort: one fact per line, and a fact longer than the line wraps.
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(p.indices, id: \.self) { Text(p[$0]) }
                    }
                }
            }
        }
    }

    private func line(_ s: ArraySlice<String>) -> some View {
        Text(s.joined(separator: " · ")).lineLimit(1)
    }

    private func lines(_ groups: [ArraySlice<String>]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(groups.indices, id: \.self) { line(groups[$0]) }
        }
    }
}

extension String {
    /// Keeps the last few characters of a paragraph together, so its last line is never one character or a lone 「。」.
    var withoutOrphan: String {
        guard count > 12 else { return self }
        let tail = suffix(5)
        guard !tail.contains("\n") else { return self }
        return dropLast(5) + tail.map { $0 == " " ? "\u{00A0}" : String($0) }.joined(separator: "\u{2060}")
    }
}

/// Explanatory footnote at the end of a page.
struct PageFootnote: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.withoutOrphan)
            .font(Theme.TypeScale.body).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Theme.Space.tight)
    }
}

// MARK: - Rows

/// Icon tile + bold title + secondary explanation; used for arrangements, tips and summaries.
struct IconTextRow: View {
    let icon: String
    let color: Color
    let title: String
    let text: String
    /// A step to act on (stop, get help): its text reads as body text, not as grey detail.
    var urgent = false

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Space.block) {
            IconTile(icon: icon, color: color)
            VStack(alignment: .leading, spacing: Theme.Space.hairline) {
                if !title.isEmpty { Text(title).font(Theme.TypeScale.body.weight(.semibold)) }
                if !text.isEmpty {
                    // Without a title the text is the row itself, so it is body text too.
                    Group {
                        // Facts joined by 「·」 (no sentence punctuation) wrap between facts, not inside 「7.7 小时」.
                        if text.contains(" · ") && !text.contains("。") && !text.contains("，") {
                            PartsText(text.components(separatedBy: " · "), maxLines: 3)
                        } else {
                            Text(text.withoutOrphan).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .font(Theme.TypeScale.body).foregroundStyle(title.isEmpty || urgent ? .primary : .secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Rounded tile holding a category glyph (32 pt in rows and card headers).
struct IconTile: View {
    let icon: String
    var color: Color = .secondary
    var size: CGFloat = Theme.Size.iconTile
    var body: some View {
        Image(systemName: icon).font(size > 34 ? Theme.TypeScale.title : Theme.TypeScale.body.weight(.semibold)).foregroundStyle(color)
            .frame(width: size, height: size)
            .background(color == .secondary ? Theme.subtle : color.opacity(0.12), in: RoundedRectangle(cornerRadius: Theme.Radius.tile(size), style: .continuous))
            .accessibilityHidden(true)
    }
}

/// Large filled tile for hero cards (category gradient, white glyph).
struct HeroIcon: View {
    let icon: String
    let color: Color
    var body: some View {
        Image(systemName: icon)
            .font(Theme.TypeScale.title.weight(.semibold)).foregroundStyle(.white)
            .frame(width: Theme.Size.hero, height: Theme.Size.hero)
            .background(color.gradient, in: RoundedRectangle(cornerRadius: Theme.Radius.tile(Theme.Size.hero), style: .continuous))
            .accessibilityHidden(true)
    }
}

/// Navigation row inside a card: icon tile, title, optional detail and value, chevron; ≥ 44 pt.
struct NavRowLabel: View {
    let icon: String
    var color: Color = .secondary
    let title: String
    var detail: String? = nil
    var value: String? = nil

    var body: some View {
        HStack(spacing: Theme.Space.block) {
            IconTile(icon: icon, color: color)
            VStack(alignment: .leading, spacing: Theme.Space.hairline) {
                Text(title).font(Theme.TypeScale.body).foregroundStyle(.primary)
                if let detail { Text(detail.withoutOrphan).font(Theme.TypeScale.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: Theme.Space.item)
            if let value { Text(value).font(Theme.TypeScale.body).foregroundStyle(.secondary).monospacedDigit() }
            Image(systemName: "chevron.right").font(Theme.TypeScale.body.weight(.semibold)).imageScale(.small).foregroundStyle(.tertiary)
        }
        .frame(minHeight: Theme.Size.tap)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// Label–value line for compact facts.
struct FactRow: View {
    let label: String
    let value: String
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(Theme.TypeScale.body).foregroundStyle(.secondary)
            Spacer(minLength: Theme.Space.block)
            Text(value).font(Theme.TypeScale.body.weight(.medium)).monospacedDigit().multilineTextAlignment(.trailing)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Tappable checklist row: circle → checkmark, title and explanation; ≥ 44 pt.
struct ChecklistRow: View {
    /// The glyph column, as wide as an icon tile so row text lines up with icon-tile rows.
    static let glyphColumn = Theme.Size.iconTile
    /// Indent for a divider under the row text.
    static let textInset = glyphColumn + Theme.Space.block
    let done: Bool
    let title: String
    let detail: String
    var toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(alignment: .top, spacing: Theme.Space.block) {
                Image(systemName: done ? "checkmark.circle.fill" : "circle")
                    .font(Theme.TypeScale.title).foregroundStyle(done ? Color.green : Color.secondary)
                    .frame(width: Self.glyphColumn)
                VStack(alignment: .leading, spacing: Theme.Space.hairline) {
                    Text(title).font(Theme.TypeScale.body.weight(.semibold)).foregroundStyle(done ? .secondary : .primary)
                    Text(detail.withoutOrphan).font(Theme.TypeScale.body).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .frame(minHeight: Theme.Size.tap)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(done ? .isSelected : [])
        .accessibilityHint(done ? "轻点取消完成" : "轻点标记完成")
    }
}

// MARK: - Logging actions

/// A row of logging shortcuts: glyph above label, at least 44 pt tall, neutral so the page stays calm.
struct LogActionBar: View {
    struct Item: Identifiable {
        var id: String { title }
        let title: String
        let icon: String
        let action: () -> Void
    }
    let items: [Item]
    @Environment(\.dynamicTypeSize) private var size

    var body: some View {
        // One row; two by two at accessibility sizes, so the labels are not cut short.
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Theme.Space.item),
                                 count: size.isAccessibilitySize ? 2 : max(1, items.count)), spacing: Theme.Space.item) {
            ForEach(items) { item in
                Button(action: item.action) {
                    VStack(spacing: Theme.Space.tight) {
                        Image(systemName: item.icon).font(Theme.TypeScale.body)
                        Text(item.title).font(Theme.TypeScale.body).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, minHeight: Theme.Size.tap + Theme.Space.item)
                    .foregroundStyle(Theme.accent)
                    .background(Theme.subtle.opacity(0.7), in: RoundedRectangle(cornerRadius: Theme.Radius.inner, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("记录\(item.title)")
            }
        }
    }
}

/// Dashed placeholder for an empty list inside a card.
struct EmptyLine: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(Theme.TypeScale.body).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, Theme.Space.item)
    }
}

// MARK: - Chart marks

/// Glucose target range as two thin dashed lines (no filled background behind the curve).
struct GlucoseRangeMarks: ChartContent {
    let low: Double
    let high: Double
    var body: some ChartContent {
        RuleMark(y: .value("目标下限", low))
            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3])).foregroundStyle(Color.gray.opacity(0.7))
        RuleMark(y: .value("目标上限", high))
            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3])).foregroundStyle(Color.gray.opacity(0.7))
    }
}
