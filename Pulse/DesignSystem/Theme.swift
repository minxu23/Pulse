import SwiftUI

/// Colour system (Apple HIG):
/// - Interaction uses one tint, system blue: navigation and tab bars, buttons, links, selection.
/// - Data uses Apple Health's category conventions, so heart data is red, activity orange, and so on.
/// - Status (good / attention / urgent) is always paired with a glyph and text, never colour alone.
/// - Text is .primary / .secondary. Orange, green, teal, cyan, mint and yellow fall below 3:1 on white,
///   so they colour icons and chart marks only, never text.
/// All values are system colours, which adapt to dark mode and Increase Contrast.
enum Theme {
    static let accent = Color.blue

    // Apple Health category colours
    static let heartData = Color.red        // 心脏：静息心率、心率、HRV、血压
    static let activity = Color.orange      // 活动：步数、运动、训练
    static let nutrition = Color.green      // 营养：饮食、饮水、咖啡因、补给
    static let sleep = Color.teal           // 睡眠
    static let respiratory = Color.cyan     // 呼吸：血氧、呼吸频率、睡眠呼吸
    static let mind = Color.mint            // 心理健康：压力、放松
    static let body = Color.purple          // 身体测量：体重、体温
    static let glucose = Color.indigo       // 血糖（Health 中属“其他数据”）
    static let labs = Color.brown           // 化验结果

    // Status
    static let good = Color.green
    static let warning = Color.orange
    static let critical = Color.red

    static let card = Color(.secondarySystemGroupedBackground)
    static let page = Color(.systemGroupedBackground)
    static let subtle = Color(.tertiarySystemFill)

    static func readiness(_ level: ReadinessLevel?) -> Color {
        switch level {
        case .high: .green
        case .moderate: .yellow
        case .low: .orange
        case .rest: .red
        case nil: .gray
        }
    }
    static func severity(_ s: Severity) -> Color {
        switch s {
        case .info: .gray
        case .verify: .yellow
        case .consult: .orange
        case .urgent: .red
        }
    }
    static func intensity(_ i: Intensity) -> Color {
        switch i {
        case .rest: .gray
        case .easy: .green
        case .moderate: .orange
        case .hard: .red
        }
    }
    static func progress(_ s: ProgressDimension.Status) -> Color {
        switch s {
        case .improved: .green
        case .stable: .gray
        case .needsWork: .orange
        case .insufficient: .gray
        }
    }
    static func habit(_ v: HabitAdherence.Verdict) -> Color {
        switch v {
        case .sustained: .green
        case .partial: .orange
        case .struggling: .red
        case .noData: .gray
        }
    }
    static func planStatus(_ s: PlanStatus) -> Color {
        switch s {
        case .planned: .secondary
        case .done: .green
        case .partial: .orange
        case .skipped: .gray
        }
    }
}

// MARK: - Layout scale

/// One scale of spacings, corners and sizes for every page. Space grows with the distance between
/// things — lines of one text block < a glyph and its text < items of one group < blocks in a card
/// < cards < sections — so a group always sits tighter than the space around it.
extension Theme {
    enum Space {
        /// Lines of one text block: a title and its detail line.
        static let hairline: CGFloat = 2
        /// A label and its value, a number and its unit.
        static let tight: CGFloat = 4
        /// An inline glyph and its text (every icon + text pair).
        static let iconGap: CGFloat = 6
        /// Rows, chips and tiles of one group.
        static let item: CGFloat = 8
        /// Blocks inside a card; an icon tile and its text; padding inside a nested tile.
        static let block: CGFloat = 12
        /// Padding inside a card.
        static let cardPadding: CGFloat = 16
        /// Between cards, in a stack or a grid.
        static let cardGap: CGFloat = 16
        /// Page side margins, the same on every page, list and sheet.
        static let gutter: CGFloat = 16
        /// Between groups of cards: the space above a section title.
        static let section: CGFloat = 28
    }

    enum Radius {
        /// Every panel at page level: cards, tiles, banners.
        static let panel: CGFloat = 20
        /// Anything inside a panel: metric tiles, callouts, fields, selectable cells.
        static let inner: CGFloat = 12
        /// Chat bubbles.
        static let bubble: CGFloat = 18
        /// Legend swatches and other small marks.
        static let mark: CGFloat = 4
        /// Icon tiles keep one proportion at every size.
        static func tile(_ side: CGFloat) -> CGFloat { side / 4 }
    }

    enum Size {
        /// Minimum tap target (HIG): every button, link and tappable row.
        static let tap: CGFloat = 44
        /// Label height inside a `.bordered` button: with the style's own padding the button reaches `tap`.
        static let borderedLabel: CGFloat = 32
        /// Icon tile in rows and card headers.
        static let iconTile: CGFloat = 32
        /// Icon tile on page-level tiles (今日 全天安排, 专项管理).
        static let tileIcon: CGFloat = 40
        /// Filled tile on hero cards.
        static let hero: CGFloat = 56
    }
}

/// Glyph and text on one line: the glyph slightly smaller than the text, the same gap everywhere.
struct InlineLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.iconGap) {
            configuration.icon.imageScale(.small)
            configuration.title
        }
    }
}

extension LabelStyle where Self == InlineLabelStyle {
    static var inline: InlineLabelStyle { InlineLabelStyle() }
}

extension View {
    /// The same side margins for every scrolling page, list and form.
    func pageMargins() -> some View {
        contentMargins(.horizontal, Theme.Space.gutter, for: .scrollContent)
    }
}

/// Side by side, or one above the other at accessibility text sizes: there two or three things in a
/// row leave each a few characters wide and break words apart. Default sizes look the same as an HStack.
struct AdaptiveStack<Content: View>: View {
    var alignment: VerticalAlignment = .center
    var spacing: CGFloat? = nil
    /// Spacing when stacked; the row's spacing when nil.
    var stackedSpacing: CGFloat? = nil
    @ViewBuilder var content: Content
    @Environment(\.dynamicTypeSize) private var size

    var body: some View {
        let layout = size.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: stackedSpacing ?? spacing))
            : AnyLayout(HStackLayout(alignment: alignment, spacing: spacing))
        layout { content }
    }
}

/// Something on the left and a trailing item pushed to the right edge; at accessibility text sizes the
/// trailing item goes underneath instead of squeezing the left side into a narrow column.
struct AdaptiveRow<Leading: View, Trailing: View>: View {
    var alignment: VerticalAlignment = .center
    var spacing: CGFloat? = nil
    var stackedSpacing: CGFloat = Theme.Space.tight
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing
    @Environment(\.dynamicTypeSize) private var size

    var body: some View {
        if size.isAccessibilitySize {
            VStack(alignment: .leading, spacing: stackedSpacing) {
                leading
                trailing
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            HStack(alignment: alignment, spacing: spacing) {
                leading
                Spacer(minLength: spacing)
                trailing
            }
        }
    }
}

// MARK: - Calm colour mode for secondary pages

private struct CalmColorsKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    /// Secondary pages use a restrained palette: neutral icons and labels, blue for interaction,
    /// category colours only on data marks, and status colours only where they carry meaning.
    var calmColors: Bool {
        get { self[CalmColorsKey.self] }
        set { self[CalmColorsKey.self] = newValue }
    }
}

extension View {
    func calmStyle() -> some View { environment(\.calmColors, true) }
}

/// Navigation stack for sheets: everything presented inside uses the calm palette and, like every
/// page in Pulse, a small title (pages pushed inside inherit it).
struct CalmNavigationStack<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        NavigationStack { content.navigationBarTitleDisplayMode(.inline) }.calmStyle()
    }
}

extension Theme {
    /// Colours that carry meaning and stay coloured in calm mode.
    static let meaningful: [Color] = [.green, .orange, .red, .yellow, accent, .accentColor]

    /// In calm mode, category colours on icons and chips fall back to a neutral tone.
    static func tone(_ color: Color, calm: Bool, fallback: Color = .secondary) -> Color {
        guard calm, !meaningful.contains(color) else { return color }
        return fallback
    }
}

// MARK: - Containers

struct Card<Content: View>: View {
    var padding: CGFloat = Theme.Space.cardPadding
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.block) { content }
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous))
    }
}

struct CardHeader<Trailing: View>: View {
    let title: String
    var subtitle: String? = nil
    let icon: String
    var color: Color = .secondary
    /// A disclosure chevron stays at the right edge at every size.
    var keepsTrailingBeside = false
    @ViewBuilder var trailing: Trailing
    @Environment(\.calmColors) private var calm
    @Environment(\.dynamicTypeSize) private var size

    var body: some View {
        let heading = HStack(alignment: .center, spacing: Theme.Space.block) {
            IconTile(icon: icon, color: calm ? .secondary : color)
            VStack(alignment: .leading, spacing: Theme.Space.hairline) {
                Text(title).font(.headline)
                if let subtitle { Text(subtitle).font(.footnote).foregroundStyle(.secondary) }
            }
        }
        // At accessibility sizes the badge or button goes under the title instead of squeezing it.
        if size.isAccessibilitySize && !keepsTrailingBeside {
            VStack(alignment: .leading, spacing: Theme.Space.item) {
                heading
                trailing
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            HStack(alignment: .center, spacing: Theme.Space.block) {
                heading
                Spacer(minLength: Theme.Space.item)
                trailing
            }
        }
    }
}

extension CardHeader where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil, icon: String, color: Color = .secondary) {
        self.init(title: title, subtitle: subtitle, icon: icon, color: color) { EmptyView() }
    }
}

struct ScreenScroll<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        ScrollView {
            VStack(spacing: Theme.Space.cardGap) { content }
                .padding(.vertical, Theme.Space.block)
                .labelStyle(.inline)
        }
        .pageMargins()
        .background(Theme.page)
    }
}

// MARK: - Data display

struct ScoreRing<Center: View>: View {
    let progress: Double
    var color: Color
    var lineWidth: CGFloat = 10
    @ViewBuilder var center: Center
    var body: some View {
        ZStack {
            Circle().stroke(color.opacity(0.15), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.001, min(1, progress)))
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.6), value: progress)
            center
        }
    }
}

struct MetricTile: View {
    let label: String
    let value: String
    var unit: String = ""
    var icon: String
    var color: Color = .secondary
    var footnote: String? = nil
    @Environment(\.calmColors) private var calm
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.tight) {
            HStack(spacing: Theme.Space.iconGap) {
                Image(systemName: icon).imageScale(.small).foregroundStyle(Theme.tone(color, calm: calm))
                Text(label).foregroundStyle(.secondary)
            }
            .font(.caption)
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.tight) {
                Text(value).font(.title3.weight(.semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
                if !unit.isEmpty { Text(unit).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
            // One line, so a footnote never makes one tile taller than its neighbours.
            if let footnote { Text(footnote).font(.caption).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(Theme.Space.block)
        .background(Theme.subtle.opacity(0.6), in: RoundedRectangle(cornerRadius: Theme.Radius.inner, style: .continuous))
    }
}

/// Tiles side by side, all as tall as the tallest and aligned at the top; one per line at accessibility
/// text sizes, where three in a row would be a few characters wide.
struct MetricRow<Content: View>: View {
    @ViewBuilder var content: Content
    @Environment(\.dynamicTypeSize) private var size
    var body: some View {
        if size.isAccessibilitySize {
            VStack(spacing: Theme.Space.item) { content }
        } else {
            HStack(alignment: .top, spacing: Theme.Space.item) { content }.fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct Chip: View {
    let text: String
    var icon: String? = nil
    var color: Color = .secondary
    var filled = false
    @Environment(\.calmColors) private var calm
    var body: some View {
        let c = Theme.tone(color, calm: calm)
        let neutral = c == .secondary
        HStack(spacing: Theme.Space.iconGap) {
            if let icon { Image(systemName: icon).font(.caption2.weight(.semibold)).foregroundStyle(c) }
            Text(text).font(.caption.weight(filled ? .semibold : .medium)).lineLimit(1)
                .foregroundStyle(neutral ? Color.secondary : Color.primary)
        }
        .padding(.horizontal, Theme.Space.item)
        .padding(.vertical, Theme.Space.tight)
        .background(c.opacity(filled ? 0.24 : 0.12), in: Capsule())
    }
}

struct Callout: View {
    enum Kind { case info, caution, limitation, urgent, insight
        var color: Color {
            switch self {
            case .info: .gray
            case .caution: .orange
            case .limitation: .gray
            case .urgent: .red
            case .insight: .yellow
            }
        }
        var icon: String {
            switch self {
            case .info: "info.circle.fill"
            case .caution: "exclamationmark.triangle.fill"
            case .limitation: "exclamationmark.circle"
            case .urgent: "cross.case.fill"
            case .insight: "lightbulb.fill"
            }
        }
    }
    var kind: Kind = .info
    var title: String? = nil
    let text: String
    @Environment(\.calmColors) private var calm
    var body: some View {
        // In calm mode only caution and urgent keep their colour.
        let color = calm && ![.caution, .urgent].contains(kind) ? Color.secondary : kind.color
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.iconGap) {
            Image(systemName: kind.icon).foregroundStyle(color).font(.subheadline).imageScale(.small)
            VStack(alignment: .leading, spacing: Theme.Space.hairline) {
                if let title { Text(title).font(.subheadline.weight(.semibold)) }
                Text(text).font(.subheadline).foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(Theme.Space.block)
        .background(color.opacity(calm && color == .secondary ? 0.08 : 0.09), in: RoundedRectangle(cornerRadius: Theme.Radius.inner, style: .continuous))
    }
}

/// Status text that stays readable: the glyph carries the colour (and the shape tells the state),
/// the words stay primary or secondary for contrast.
struct StatusLabel: View {
    let text: String
    let icon: String
    var color: Color
    var secondaryText = false
    var body: some View {
        Label {
            Text(text).foregroundStyle(secondaryText ? Color.secondary : Color.primary)
        } icon: {
            Image(systemName: icon).foregroundStyle(color)
        }
    }
}

struct BulletText: View {
    let text: String
    var color: Color = .secondary
    @Environment(\.calmColors) private var calm
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.item) {
            Circle().fill(Theme.tone(color, calm: calm)).frame(width: 5, height: 5).offset(y: -2)
            Text(text).font(.subheadline).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct ProgressBar: View {
    let value: Double
    var color: Color = .gray
    var height: CGFloat = 8
    var body: some View {
        let c = color
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(c.opacity(0.15))
                Capsule().fill(c).frame(width: max(height, geo.size.width * min(1, max(0, value))))
            }
        }
        .frame(height: height)
    }
}

struct Disclaimer: View {
    var text = "Pulse 帮助你记录与理解自己的健康数据，不提供医疗诊断。出现胸痛、晕厥、严重气短等情况请立即拨打 120。"
    var body: some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.vertical, Theme.Space.item)
    }
}

struct EmptyHint: View {
    let icon: String
    let text: String
    var body: some View {
        VStack(spacing: Theme.Space.item) {
            Image(systemName: icon).font(.title2).foregroundStyle(.secondary)
            Text(text).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.Space.cardPadding)
    }
}

// MARK: - Inputs

/// Compact 1…n rating with captions at both ends.
struct RatingPicker: View {
    @Binding var value: Int?
    var range: ClosedRange<Int> = 1...5
    var lowLabel: String = ""
    var highLabel: String = ""
    var labels: [String]? = nil

    var body: some View {
        let color = Theme.accent
        VStack(alignment: .leading, spacing: Theme.Space.tight) {
            HStack(spacing: Theme.Space.item) {
                ForEach(Array(range), id: \.self) { v in
                    let selected = value == v
                    Button {
                        value = selected ? nil : v
                    } label: {
                        Text(labels.map { $0[v - range.lowerBound] } ?? "\(v)")
                            .font(.subheadline.weight(selected ? .semibold : .regular))
                            .frame(maxWidth: .infinity, minHeight: Theme.Size.tap)
                            .foregroundStyle(selected ? Color.white : Color.primary)
                            .background(selected ? color : Theme.subtle, in: RoundedRectangle(cornerRadius: Theme.Radius.inner, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
            if !lowLabel.isEmpty || !highLabel.isEmpty {
                HStack {
                    Text(lowLabel)
                    Spacer()
                    Text(highLabel)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }
}

/// Simple wrapping layout for chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = Theme.Space.item
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, widest: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x + size.width > maxW, x > 0 { y += rowH + spacing; x = 0; rowH = 0 }
            x += size.width + spacing
            rowH = max(rowH, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: min(widest, maxW), height: y + rowH)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX { y += rowH + spacing; x = bounds.minX; rowH = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowH = max(rowH, size.height)
        }
    }
}

struct ToggleChip: View {
    let text: String
    var icon: String? = nil
    @Binding var isOn: Bool
    var body: some View {
        Button { isOn.toggle() } label: {
            Chip(text: text, icon: isOn ? "checkmark" : icon, color: isOn ? Theme.accent : .secondary, filled: isOn)
                .frame(minHeight: Theme.Size.tap)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

extension View {
    func cardButtonStyle() -> some View { buttonStyle(.plain) }
}

extension Binding where Value == Double? {
    /// Bridges an optional Double to a text field string.
    func text(decimals: Int = 0) -> Binding<String> {
        Binding<String>(
            get: { wrappedValue.map { decimals == 0 ? String(Int($0)) : String(format: "%.\(decimals)f", $0) } ?? "" },
            set: { wrappedValue = Double($0.replacingOccurrences(of: ",", with: ".")) })
    }
}
