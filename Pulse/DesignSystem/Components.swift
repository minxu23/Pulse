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

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.item) {
            Text(title).font(.headline).accessibilityAddTraits(.isHeader)
            if let detail { Text(detail).font(.footnote).foregroundStyle(.secondary) }
            Spacer(minLength: Theme.Space.item)
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
    var valueFont: Font = .system(.title, design: .rounded).weight(.semibold)
    @ViewBuilder var footer: Footer

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.item) {
            HStack(spacing: Theme.Space.iconGap) {
                Image(systemName: icon).font(.subheadline.weight(.semibold)).imageScale(.small).foregroundStyle(color)
                Text(title).font(.subheadline.weight(.semibold))
                Spacer(minLength: Theme.Space.tight)
                if let time { Text(time).font(.footnote).foregroundStyle(.secondary) }
            }
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.tight) {
                Text(value).font(valueFont).monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.6)
                if !unit.isEmpty { Text(unit).font(.subheadline).foregroundStyle(.secondary) }
            }
            if let s = status {
                StatusLabel(s).font(.footnote).lineLimit(2)
            }
            footer
        }
        .padding(Theme.Space.cardPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

extension HealthMetricCard where Footer == EmptyView {
    init(title: String, icon: String, color: Color, time: String? = nil, value: String, unit: String = "",
         status: MetricStatus? = nil, valueFont: Font = .system(.title, design: .rounded).weight(.semibold)) {
        self.init(title: title, icon: icon, color: color, time: time, value: value, unit: unit, status: status,
                  valueFont: valueFont) { EmptyView() }
    }
}

/// Two equal columns for metric cards, spaced like cards in a stack.
struct MetricGrid<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        let gap = Theme.Space.cardGap
        LazyVGrid(columns: [GridItem(.flexible(), spacing: gap), GridItem(.flexible(), spacing: gap)], spacing: gap) {
            content
        }
    }
}

struct SectionTitle: View {
    let title: String
    var subtitle: String? = nil
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.item) {
            Text(title).font(.title3.bold())
            if let subtitle { Text(subtitle).font(.subheadline).foregroundStyle(.secondary) }
            Spacer()
        }
        .padding(.horizontal, Theme.Space.tight)
        // In a card stack: a section gap above, and the title sits closer to its own cards than cards to each other.
        .padding(.top, Theme.Space.section - Theme.Space.cardGap)
        .padding(.bottom, -Theme.Space.tight)
        .accessibilityAddTraits(.isHeader)
    }
}

/// Explanatory footnote at the end of a page.
struct PageFootnote: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.footnote).foregroundStyle(.secondary)
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

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Space.block) {
            IconTile(icon: icon, color: color)
            VStack(alignment: .leading, spacing: Theme.Space.hairline) {
                if !title.isEmpty { Text(title).font(.subheadline.weight(.semibold)) }
                if !text.isEmpty {
                    Text(text).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
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
        Image(systemName: icon).font(size > 34 ? .title3.weight(.semibold) : .body.weight(.semibold)).foregroundStyle(color)
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
            .font(.title2.weight(.semibold)).foregroundStyle(.white)
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
                Text(title).font(.body).foregroundStyle(.primary)
                if let detail { Text(detail).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: Theme.Space.item)
            if let value { Text(value).font(.subheadline).foregroundStyle(.secondary).monospacedDigit() }
            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
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
            Text(label).font(.subheadline).foregroundStyle(.secondary)
            Spacer(minLength: Theme.Space.block)
            Text(value).font(.subheadline.weight(.medium)).monospacedDigit().multilineTextAlignment(.trailing)
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
                    .font(.title3).foregroundStyle(done ? Color.green : Color.secondary)
                    .frame(width: Self.glyphColumn)
                VStack(alignment: .leading, spacing: Theme.Space.hairline) {
                    Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(done ? .secondary : .primary)
                    Text(detail).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.leading)
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

    var body: some View {
        HStack(spacing: Theme.Space.item) {
            ForEach(items) { item in
                Button(action: item.action) {
                    VStack(spacing: Theme.Space.tight) {
                        Image(systemName: item.icon).font(.body)
                        Text(item.title).font(.caption).lineLimit(1).minimumScaleFactor(0.8)
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
        Text(text).font(.subheadline).foregroundStyle(.secondary)
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
