import SwiftUI

// The "Taproom" design language: warm, calm and tactile, like a craft-beer bar menu rather
// than stock iOS grouped lists. See DESIGN.md for how to use it. The check-in screen
// (CheckInSheet) is the reference implementation.

/// The Taproom palette and metrics. Every colour has a light and a dark value.
enum Taproom {
    static let background = dynamic(0xFBF8F3, 0x17130E)
    static let card = dynamic(0xFFFFFF, 0x241E17)
    static let border = dynamic(0xE7DDCE, 0x3A3128)
    static let ink = dynamic(0x2B2118, 0xF4ECDF)
    static let muted = dynamic(0x6F6252, 0xB0A38F)
    static let amber = rgb(0xE9A23B)
    /// Text and icons drawn on amber.
    static let onAmber = rgb(0x2B2118)
    /// "You've had this beer": a leaf green that sits with the warm palette, lighter in dark mode.
    static let had = dynamic(0x3B8449, 0x5CAE6B)
    /// The tick drawn on `had`.
    static let onHad = dynamic(0xFFFFFF, 0x0F2414)
    /// Destructive actions (delete, remove friend): a warm crimson that fits the palette.
    static let destructive = dynamic(0xC93B2B, 0xE85D4A)
    static let glassRim = dynamic(0xCDBFA8, 0x5A4C3C)
    static let glassInside = dynamic(0xF1EADF, 0x211B14)
    static let foam = dynamic(0xFFFDF7, 0xF6EBD3)

    /// Side margin for screen content.
    static let margin: CGFloat = 16
    /// Space between sections on a screen.
    static let sectionSpacing: CGFloat = 18
    /// Small bold label above a section ("Serving", "Where").
    static let sectionLabel = Font.footnote.weight(.bold)

    private static func uiColor(_ hex: UInt32) -> UIColor {
        UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }

    private static func rgb(_ hex: UInt32) -> Color { Color(uiColor(hex)) }

    private static func dynamic(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(UIColor { $0.userInterfaceStyle == .dark ? uiColor(dark) : uiColor(light) })
    }
}


/// A titled block of content: a small bold label, then the content.
struct TaproomSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(Taproom.sectionLabel)
            content
        }
    }
}

/// A small amber capsule with a count: something is waiting (friend requests on the Me tab's
/// Friends stat). Amber with `onAmber` text, like a selected chip.
struct TaproomCountBadge: View {
    let count: Int

    var body: some View {
        Text(count.formatted())
            .font(.system(size: 12, weight: .heavy).monospacedDigit())
            .foregroundStyle(Taproom.onAmber)
            .padding(.horizontal, 6)
            .frame(minWidth: 20, minHeight: 20)
            .background(Taproom.amber, in: Capsule())
            .accessibilityHidden(true)  // the link's hint says how many are waiting
    }
}

/// A capsule chip for picking from a few options; amber when selected. `dashed` is for an
/// "add" chip (e.g. "+ Tag friends").
struct TaproomChip: ButtonStyle {
    var on: Bool
    var leading: CGFloat = 12
    var dashed = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .taproomChipLabel(on: on, leading: leading, dashed: dashed)
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

extension View {
    /// Capsule chip styling matching `TaproomChip`, for `Menu` labels (e.g. Sort and Style pickers)
    /// where SwiftUI ignores a `ButtonStyle` on the outer menu.
    func taproomChipLabel(on: Bool, leading: CGFloat = 12, trailing: CGFloat = 12, dashed: Bool = false) -> some View {
        font(.subheadline.weight(.medium))
            .foregroundStyle(on ? Taproom.onAmber : Taproom.ink)
            .padding(.leading, leading)
            .padding(.trailing, trailing)
            .frame(minHeight: 34)
            .background(on ? Taproom.amber : dashed ? Color.clear : Taproom.card, in: Capsule())
            .overlay {
                Capsule().strokeBorder(on ? Taproom.amber : dashed ? Taproom.muted : Taproom.border,
                                       style: StrokeStyle(lineWidth: 1, dash: dashed ? [4, 3] : []))
            }
            .contentShape(Capsule())
    }
}

/// Empty state shown when search or filter chips hide every item in a list, with a "Clear filters" action.
struct TaproomEmptyFilterView: View {
    var title = "No matching beers"
    var message = "Try adjusting your search or filters."
    var clearButtonIdentifier: String? = nil
    let onClear: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .font(.title2)
                .foregroundStyle(Taproom.muted)
                .accessibilityHidden(true)
            Text(title)
                .font(.headline)
            Text(message)
                .font(.callout)
                .foregroundStyle(Taproom.muted)
                .multilineTextAlignment(.center)
            Button("Clear filters", action: onClear)
                .buttonStyle(TaproomOutlineButton())
                .frame(maxWidth: 220)
                .padding(.top, 4)
                .accessibilityIdentifier(clearButtonIdentifier ?? "")
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }
}

/// A secondary button: rounded, outlined, filling its share of a row.
struct TaproomOutlineButton: ButtonStyle {
    /// False sizes it to its label plus side padding, like `TaproomPrimaryButton(fullWidth: false)`,
    /// for a button at the end of a row.
    var fullWidth = true
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let color = configuration.role == .destructive ? Taproom.destructive : Taproom.ink
        configuration.label
            .labelStyle(TightLabel())
            .font(.subheadline.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, fullWidth ? 0 : 20)
            .frame(maxWidth: fullWidth ? .infinity : nil, minHeight: 44)
            .background(Taproom.card, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Taproom.border))
            .opacity(!isEnabled ? 0.4 : configuration.isPressed ? 0.7 : 1)
    }
}

/// Marks a subview of a `TaproomButtonRow` as fixed at its own width (e.g. an icon-only button)
/// instead of taking a share of the row's spare width.
private struct FixedInButtonRowKey: LayoutValueKey {
    static let defaultValue = false
}

extension View {
    /// In a `TaproomButtonRow`, keeps this view at its own width.
    func fixedInButtonRow() -> some View { layoutValue(key: FixedInButtonRowKey.self, value: true) }
}

/// A row of `TaproomOutlineButton`s that fills the available width, sharing the spare width
/// equally between the flexible buttons: each is its label's natural width plus the same extra
/// amount, so every button has equal padding either side of its label whatever the label's
/// length. Give labels a small horizontal padding for the minimum. Buttons marked
/// `.fixedInButtonRow()` keep their own width. If the labels don't fit (large Dynamic Type),
/// the flexible buttons shrink in proportion to their natural widths; callers should give each
/// label an icon-only fallback (e.g. with `ViewThatFits`, as the check-in photo row does).
struct TaproomButtonRow: Layout {
    var spacing: CGFloat = 8

    private func widths(_ subviews: Subviews, in total: CGFloat) -> [CGFloat] {
        let ideals = subviews.map { $0.sizeThatFits(.unspecified).width }
        let fixed = subviews.map { $0[FixedInButtonRowKey.self] }
        let gaps = spacing * CGFloat(max(subviews.count - 1, 0))
        let fixedTotal = zip(ideals, fixed).reduce(0) { $0 + ($1.1 ? $1.0 : 0) }
        let flexIdeal = zip(ideals, fixed).reduce(0) { $0 + ($1.1 ? 0 : $1.0) }
        let flexCount = fixed.filter { !$0 }.count
        let room = total - gaps - fixedTotal
        guard flexCount > 0 else { return ideals }
        let extra = (room - flexIdeal) / CGFloat(flexCount)
        return zip(ideals, fixed).map { ideal, isFixed in
            if isFixed { return ideal }
            if extra >= 0 { return ideal + extra }
            return max(0, room) * ideal / max(flexIdeal, 1)
        }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let natural = subviews.reduce(0) { $0 + $1.sizeThatFits(.unspecified).width }
            + spacing * CGFloat(max(subviews.count - 1, 0))
        // No proposal, or an infinite one: use the natural width rather than an infinite one.
        let total = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? natural
        let ws = widths(subviews, in: total)
        let height = zip(subviews, ws).map { $0.sizeThatFits(.init(width: $1, height: nil)).height }.max() ?? 0
        return CGSize(width: total, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let ws = widths(subviews, in: bounds.width)
        var x = bounds.minX
        for (view, w) in zip(subviews, ws) {
            view.place(at: CGPoint(x: x, y: bounds.minY), anchor: .topLeading,
                       proposal: .init(width: w, height: bounds.height))
            x += w + spacing
        }
    }
}

/// The screen's one main action: full width, dark ink with light text. `fullWidth: false` sizes
/// it to its label, for the tab bar's action. `compact` is a 44pt, 12pt-cornered version that
/// sits beside `TaproomOutlineButton`s (Accept beside Reject).
struct TaproomPrimaryButton: ButtonStyle {
    var fullWidth = true
    var compact = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let radius: CGFloat = compact ? 12 : 16
        configuration.label
            .labelStyle(TightLabel())
            .font(compact ? .subheadline.weight(.semibold) : .headline)
            .padding(.horizontal, fullWidth ? 0 : 20)
            .frame(maxWidth: fullWidth ? .infinity : nil, minHeight: compact ? 44 : 54)
            .foregroundStyle(Taproom.background)
            .tint(Taproom.background)
            .background(Taproom.ink, in: RoundedRectangle(cornerRadius: radius))
            .opacity(!isEnabled ? 0.4 : configuration.isPressed ? 0.8 : 1)
            .contentShape(RoundedRectangle(cornerRadius: radius))
    }
}

/// A label with its icon after the title, for small hints ("Slide the glass up or down →").
struct TaproomTrailingIconLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) { configuration.title; configuration.icon.imageScale(.small) }
    }
}

/// Text that opens another page (a beer's name, its brewery): it keeps the look of the text
/// around it, with a small muted chevron after the last line to say it's a link. Put it in a
/// `NavigationLink` with `TaproomLinkStyle`. `chevronSize` is in points at the default text
/// size and grows with Dynamic Type; match it to about 60% of the text's size.
struct TaproomLinkLabel: View {
    let title: String
    var font: Font
    var chevronSize: CGFloat
    var tracking: CGFloat
    var lineLimit: Int?
    var minimumScaleFactor: CGFloat
    var showsChevron: Bool
    @ScaledMetric private var scaledChevron: CGFloat

    init(_ title: String, font: Font = .subheadline, chevronSize: CGFloat = 10, tracking: CGFloat = 0,
         lineLimit: Int? = 1, minimumScaleFactor: CGFloat = 1, showsChevron: Bool = true) {
        self.title = title
        self.font = font
        self.chevronSize = chevronSize
        self.tracking = tracking
        self.lineLimit = lineLimit
        self.minimumScaleFactor = minimumScaleFactor
        self.showsChevron = showsChevron
        _scaledChevron = ScaledMetric(wrappedValue: chevronSize)
    }

    var body: some View {
        HStack(alignment: .lastTextBaseline, spacing: 4) {
            Text(title)
                .font(font)
                .tracking(tracking)
                .lineLimit(lineLimit)
                .minimumScaleFactor(minimumScaleFactor)
                .multilineTextAlignment(.leading)
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: scaledChevron, weight: .bold))
                    .foregroundStyle(Taproom.muted)
                    .fixedSize()
                    .accessibilityHidden(true)
            }
        }
    }
}

/// The button style for a `TaproomLinkLabel`: no chrome, dims while pressed, and the touch
/// target reaches `extend` points above and below the text without moving anything, so a single
/// line is easier to hit. Neighbouring links meet halfway.
struct TaproomLinkStyle: ButtonStyle {
    var extend: CGFloat = 10

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.55 : 1)
            .padding(.vertical, extend)
            .contentShape(Rectangle())
            .padding(.vertical, -extend)
    }
}

extension View {
    /// A white (dark: deep brown) card with a thin warm border.
    func taproomCard(cornerRadius: CGFloat = 16) -> some View {
        background(Taproom.card, in: RoundedRectangle(cornerRadius: cornerRadius))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius).stroke(Taproom.border))
    }

    /// Pins content (normally a TaproomPrimaryButton) in a bar at the bottom of the screen; use
    /// inside `.safeAreaInset(edge: .bottom)`. Constrains the content to `.readableContentWidth`
    /// on wide screens while keeping the background bar edge to edge.
    func taproomBottomBar() -> some View {
        padding(.horizontal, Taproom.margin)
            .padding(.vertical, 8)
            .frame(maxWidth: .readableContentWidth)
            .frame(maxWidth: .infinity)
            .background(Taproom.background, ignoresSafeAreaEdges: [.bottom, .horizontal])
    }

    /// The screen background and ink colour, and amber as the tint.
    func taproomScreen() -> some View {
        foregroundStyle(Taproom.ink)
            .background(Taproom.background)
            .tint(Taproom.amber)
    }
}

/// "Offline" beside a switch for the user's offline mode (`Connectivity.offlineMode`), amber
/// when on like the Settings toggles. Only the user turns it off. Sits at the top right of a
/// screen that searches or checks in (Discover, the check-in screen).
struct TaproomOfflineSwitch: View {
    @State private var connectivity = Connectivity.shared

    var body: some View {
        Toggle(isOn: $connectivity.offlineMode) {
            Text("Offline")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(connectivity.offlineMode ? Taproom.ink : Taproom.muted)
        }
        .toggleStyle(.switch)
        .tint(Taproom.amber)
        .fixedSize()
        .frame(minHeight: 44)
        .accessibilityLabel("Offline mode")
        .accessibilityHint("While it's on, nothing is sent to Untappd")
        .sensoryFeedback(.selection, trigger: connectivity.offlineMode)
    }
}

/// A card that tells you something about the app's state: an amber icon, a bold title and a
/// muted message, with optional buttons under it. The offline banner and the slow-connection
/// prompt on Discover.
struct TaproomNotice<Actions: View>: View {
    let systemImage: String
    let title: String
    let message: String
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: systemImage)
                    .foregroundStyle(Taproom.amber)
                    .font(.body.weight(.semibold))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.subheadline.weight(.semibold))
                    Text(message).font(.footnote).foregroundStyle(Taproom.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            actions
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .taproomCard()
        .accessibilityElement(children: .contain)
    }
}

extension TaproomNotice where Actions == EmptyView {
    init(systemImage: String, title: String, message: String) {
        self.init(systemImage: systemImage, title: title, message: message) { EmptyView() }
    }
}

/// A pint glass filled to a rating, for showing (not setting) a score. `GlassRating` is the
/// draggable one on the check-in screen.
struct FilledGlass: View {
    let rating: Double
    var lineWidth: CGFloat = 1.5
    /// Draws a band of foam on top of the beer; worth it on bigger glasses only.
    var foam = false

    var body: some View {
        GeometryReader { geo in
            let level = geo.size.height * CGFloat(min(max(rating, 0), 5) / 5 * 0.93)
            ZStack(alignment: .bottom) {
                PintShape().fill(Taproom.glassInside)
                VStack(spacing: 0) {
                    if foam && rating > 0 { Rectangle().fill(Taproom.foam).frame(height: geo.size.height * 0.06) }
                    Rectangle().fill(Taproom.amber).frame(height: level)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .clipShape(PintShape())
                PintShape().stroke(Taproom.glassRim, lineWidth: lineWidth)
            }
        }
        .aspectRatio(0.72, contentMode: .fit)
        .accessibilityHidden(true)
    }
}

/// A checkin's rating: the number in heavy type beside a small glass filled to match.
struct TaproomRating: View {
    let rating: Double
    var size: CGFloat = 34

    var body: some View {
        HStack(alignment: .lastTextBaseline, spacing: size * 0.16) {
            Text(rating.formatted(.number.precision(.fractionLength(2))))
                .font(.system(size: size, weight: .heavy).monospacedDigit())
                .tracking(-size * 0.03)
            FilledGlass(rating: rating, lineWidth: size > 40 ? 2 : 1.5)
                .frame(height: size * 0.8)
                .alignmentGuide(.lastTextBaseline) { $0[.bottom] }
        }
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Rated \(rating.formatted(.number.precision(.fractionLength(0...2)))) out of 5")
    }
}

/// A full-width tappable row in a list laid out on the page (venues, beers, settings). Shows a
/// warm highlight while pressed.
struct TaproomRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(configuration.isPressed ? Taproom.glassInside : Color.clear)
    }
}

extension View {
    /// A 1pt warm line under a row in a list laid out on the page.
    func taproomRowDivider() -> some View {
        overlay(alignment: .bottom) { Rectangle().fill(Taproom.border).frame(height: 1) }
    }
}

/// A card of a few headline counts side by side ("Check-ins 1,204", "People 310"), for the top
/// of a detail page. Counts that are nil are left out; draws nothing if none are left unless
/// `isLoading` is true, in which case all titles are shown with redacted placeholder values so
/// the card reserves its final height from frame zero.
struct TaproomStatsCard: View {
    let stats: [(title: String, value: Int?)]
    var isLoading = false

    private var shown: [(title: String, value: Int)] { stats.compactMap { s in s.value.map { (s.title, $0) } } }

    static func compact(_ n: Int) -> String {
        n < 10_000 ? n.formatted() : n.formatted(.number.notation(.compactName).precision(.fractionLength(0...1)))
    }

    var body: some View {
        if !shown.isEmpty {
            card(items: shown.map { ($0.title, Self.compact($0.value), false) })
        } else if isLoading && !stats.isEmpty {
            card(items: stats.map { ($0.title, "12.4K", true) })
        }
    }

    private func card(items: [(title: String, text: String, placeholder: Bool)]) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                VStack(spacing: 2) {
                    Text(item.text)
                        .font(.system(size: 22, weight: .heavy).monospacedDigit())
                        .tracking(-0.5)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .redacted(reason: item.placeholder ? .placeholder : [])
                    Text(item.title).font(.caption).foregroundStyle(Taproom.muted).lineLimit(1)
                }
                .frame(maxWidth: .infinity)
                .overlay(alignment: .leading) {
                    if i > 0 { Rectangle().fill(Taproom.border).frame(width: 1) }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(item.placeholder ? "\(item.title): loading" : "\(item.title): \(item.text)")
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 4)
        .taproomCard()
    }
}

/// A row in a card that opens a web page or Maps: an amber icon, the content, and a muted hint
/// with an outward arrow ("Website ↗"). Stack several in a `.taproomCard()` with a hairline
/// between them.
struct TaproomLinkRow<Label: View>: View {
    let url: URL
    let icon: String
    let hint: String
    @ViewBuilder var label: Label
    @Environment(\.openURL) private var openURL

    var body: some View {
        Button { openURL(url) } label: {
            HStack(spacing: 12) {
                Image(systemName: icon).foregroundStyle(Taproom.amber).frame(width: 20)
                label.frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 3) {
                    Text(hint)
                    Image(systemName: "arrow.up.right").imageScale(.small)
                }
                .font(.caption).foregroundStyle(Taproom.muted)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(minHeight: 48)
        }
        .buttonStyle(TaproomRowStyle())
    }
}

/// A search field on the page: a card with a magnifying glass, an optional trailing accessory
/// (e.g. Discover's barcode scan button), and a Cancel button while it's in use. `focusRequests`
/// focuses it each time it goes up (e.g. from the tab bar's Search).
struct TaproomSearchField<Trailing: View>: View {
    @Binding var text: String
    let prompt: String
    var focusRequests = 0
    /// The leading icon, e.g. `location` for a "where" field.
    var systemImage = "magnifyingglass"
    var capitalization: TextInputAutocapitalization = .never
    var fieldIdentifier: String? = nil
    let trailing: Trailing
    @FocusState private var focused: Bool
    @State private var handledRequests = 0

    init(
        text: Binding<String>,
        prompt: String,
        focusRequests: Int = 0,
        systemImage: String = "magnifyingglass",
        capitalization: TextInputAutocapitalization = .never,
        fieldIdentifier: String? = nil,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self._text = text
        self.prompt = prompt
        self.focusRequests = focusRequests
        self.systemImage = systemImage
        self.capitalization = capitalization
        self.fieldIdentifier = fieldIdentifier
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: systemImage).foregroundStyle(Taproom.muted)
                TextField(prompt, text: $text, prompt: Text(prompt).foregroundStyle(Taproom.muted))
                    .focused($focused)
                    .submitLabel(.search)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(capitalization)
                    .accessibilityIdentifier(fieldIdentifier ?? "")
                if !text.isEmpty {
                    Button("Clear", systemImage: "xmark.circle.fill") { text = "" }
                        .labelStyle(.iconOnly).foregroundStyle(Taproom.muted)
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 44)
            .background(Taproom.card, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(focused ? Taproom.amber : Taproom.border))
            .contentShape(RoundedRectangle(cornerRadius: 16))
            .onTapGesture { focused = true }

            if focused || !text.isEmpty {
                Button("Cancel") { text = ""; focused = false }
                    .font(.body.weight(.medium))
                    .foregroundStyle(Taproom.ink)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            } else {
                trailing
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.2), value: focused || !text.isEmpty)
        .task(id: focusRequests) {
            guard focusRequests > handledRequests else { return }
            handledRequests = focusRequests
            // Wait for the tab switch to settle, or the keyboard doesn't come up.
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            focused = true
        }
    }
}

extension TaproomSearchField where Trailing == EmptyView {
    init(
        text: Binding<String>,
        prompt: String,
        focusRequests: Int = 0,
        systemImage: String = "magnifyingglass",
        capitalization: TextInputAutocapitalization = .never,
        fieldIdentifier: String? = nil
    ) {
        self.init(
            text: text,
            prompt: prompt,
            focusRequests: focusRequests,
            systemImage: systemImage,
            capitalization: capitalization,
            fieldIdentifier: fieldIdentifier
        ) {
            EmptyView()
        }
    }
}

/// A square icon-only button matching `TaproomSearchField`'s height (44pt) and rounded card
/// geometry, for an action placed beside a search field (e.g. Discover's barcode scanner).
struct TaproomSearchAccessoryButton: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Taproom.ink)
            .frame(width: 44, height: 44)
            .background(Taproom.card, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Taproom.border))
            .contentShape(RoundedRectangle(cornerRadius: 16))
            .opacity(!isEnabled ? 0.4 : configuration.isPressed ? 0.7 : 1)
    }
}

/// One tab in a `TaproomTabBar`.
struct TaproomTab<Value: Hashable>: Identifiable {
    let value: Value
    let title: String
    let systemImage: String
    var id: Value { value }
}

/// How much of `TaproomTabBar` is squeezed to fit: the action drops its title first, then the
/// tabs drop theirs too. Read by `TaproomBarAction` and the tab buttons.
private enum TabBarFit: Int { case full, iconAction, iconsOnly }

private extension EnvironmentValues {
    @Entry var tabBarFit: TabBarFit = .full
}

/// The dark context action for a `TaproomTabBar`: icon and title, or just the icon when the bar
/// has no room for the title (large Dynamic Type). The title never wraps, and stays as the
/// accessibility label. Always at least 54pt tall and wide.
struct TaproomBarAction: View {
    let title: LocalizedStringKey
    let systemImage: String
    let action: () -> Void
    @Environment(\.tabBarFit) private var fit

    var body: some View {
        Button(action: action) {
            if fit == .full {
                Label(title, systemImage: systemImage).lineLimit(1).fixedSize(horizontal: true, vertical: false)
            } else {
                Image(systemName: systemImage).frame(minWidth: 34)
            }
        }
        .buttonStyle(TaproomPrimaryButton(fullWidth: false))
        .accessibilityLabel(Text(title))
    }
}

/// Determines whether a UIKit keyboard notification represents a visible on-screen keyboard
/// overlapping the app window (ignoring zero-height, off-screen, non-local, or no-responder
/// notifications that UIKit can emit during rotation or window-size transitions).
enum TaproomKeyboard {
    static func isVisible(
        endFrame: CGRect?,
        in windowBounds: CGRect,
        isLocal: Bool?,
        hasFirstResponder: Bool = true
    ) -> Bool {
        if isLocal == false || !hasFirstResponder { return false }
        guard let endFrame, !endFrame.isNull, !endFrame.isEmpty, endFrame.height > 0, !windowBounds.isEmpty else {
            return false
        }
        let overlap = endFrame.intersection(windowBounds)
        return !overlap.isNull && overlap.height > 1
    }

    @MainActor
    static func isVisible(for notification: Notification) -> Bool {
        let userInfo = notification.userInfo
        let isLocal = userInfo?[UIResponder.keyboardIsLocalUserInfoKey] as? Bool
        let rawEndFrame = userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect
        guard let rawEndFrame, let window = activeKeyWindow else { return false }
        let localEndFrame = window.convert(rawEndFrame, from: nil)
        return isVisible(
            endFrame: localEndFrame,
            in: window.bounds,
            isLocal: isLocal,
            hasFirstResponder: window.hasFirstResponder
        )
    }

    @MainActor
    private static var activeKeyWindow: UIWindow? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let active = scenes.filter { $0.activationState == .foregroundActive || $0.activationState == .foregroundInactive }
        return active.flatMap(\.windows).first(where: \.isKeyWindow)
            ?? scenes.flatMap(\.windows).first(where: \.isKeyWindow)
    }
}

private extension UIView {
    var hasFirstResponder: Bool {
        if isFirstResponder { return true }
        return subviews.contains(where: \.hasFirstResponder)
    }
}

/// The app's bottom bar: the tabs on the left and one context action (Search, Scan…) as a dark
/// button on the right, within thumb reach. It belongs at the bottom of each tab's root screen,
/// so it slides away with the root when something is pushed, and it steps aside for the keyboard.
/// Put a `TaproomBarAction` in `action`. When the text is too large for everything to fit on one
/// line, the action drops to its icon alone, then the tabs do too; nothing wraps or clips.
struct TaproomTabBar<Value: Hashable, Action: View>: View {
    let tabs: [TaproomTab<Value>]
    let selection: Value
    let select: (Value) -> Void
    @ViewBuilder var action: Action
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var keyboardShown = false

    var body: some View {
        Group {
            if !keyboardShown {
                if horizontalSizeClass == .regular {
                    floatingBar
                } else {
                    compactBar
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { notification in
            keyboardShown = TaproomKeyboard.isVisible(for: notification)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { notification in
            keyboardShown = TaproomKeyboard.isVisible(for: notification)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidChangeFrameNotification)) { notification in
            keyboardShown = TaproomKeyboard.isVisible(for: notification)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            keyboardShown = false
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidHideNotification)) { _ in
            keyboardShown = false
        }
    }

    /// On iPad / regular width: a centered floating pill, clear of the window resize grabber.
    private var floatingBar: some View {
        let shape = RoundedRectangle(cornerRadius: 24, style: .continuous)
        return ViewThatFits(in: .horizontal) {
            row(.full)
            row(.iconAction)
            row(.iconsOnly)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(maxWidth: 520)
        .background {
            shape.fill(.ultraThinMaterial)
                .overlay(shape.fill(Taproom.background.opacity(0.65)))
        }
        .overlay { shape.strokeBorder(Taproom.border, lineWidth: 1) }
        .shadow(color: .black.opacity(0.08), radius: 14, y: 4)
        .padding(.horizontal, Taproom.margin)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity)
    }

    private var compactBar: some View {
        ViewThatFits(in: .horizontal) {
            row(.full)
            row(.iconAction)
            row(.iconsOnly)
        }
        .padding(.horizontal, Taproom.margin)
        .padding(.top, 8)
        .padding(.bottom, 2)
        // Frosted glass, like the system bars: the page scrolls on underneath it, blurred,
        // with a wash of the page colour so it stays warm. Both the backdrop and top rule
        // extend across bottom and horizontal safe areas (e.g. a trailing navigation rail)
        // while the interactive buttons stay inside the safe area.
        .background {
            Rectangle().fill(.ultraThinMaterial)
                .overlay(Taproom.background.opacity(0.55))
                .overlay(alignment: .top) {
                    Rectangle().fill(Taproom.border.opacity(0.6)).frame(height: 0.5)
                }
                .ignoresSafeArea(edges: [.bottom, .horizontal])
        }
    }

    private func row(_ fit: TabBarFit) -> some View {
        HStack(spacing: 4) {
            ForEach(tabs) { tab in
                let on = tab.value == selection
                Button { select(tab.value) } label: {
                    VStack(spacing: 2) {
                        Image(systemName: tab.systemImage).font(.system(size: 20, weight: .medium))
                            .frame(height: 24)
                        if fit != .iconsOnly {
                            Text(tab.title).font(.caption2.weight(.semibold))
                                .lineLimit(1).fixedSize(horizontal: true, vertical: false)
                        }
                    }
                    .frame(minWidth: 56, minHeight: 50)
                    .padding(.horizontal, 2)
                    .foregroundStyle(on ? Taproom.ink : Taproom.muted)
                    .background(on ? Taproom.glassInside : .clear, in: RoundedRectangle(cornerRadius: 14))
                    .contentShape(RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(tab.title))
                .accessibilityAddTraits(on ? .isSelected : [])
            }
            Spacer(minLength: 8)
            action.environment(\.tabBarFit, fit)
        }
        // Match TaproomPrimaryButton's default height so the bar doesn't jump when action is empty.
        .frame(minHeight: 54)
    }
}

/// A segmented control for choosing one value from a short row (a statistics range: 1W / 1M /
/// 1Y / All). A bordered card with the selected segment filled amber. Each segment is 44pt tall.
struct TaproomSegmented<Value: Hashable>: View {
    let options: [(value: Value, title: String)]
    @Binding var selection: Value
    var accessibilityID: ((Value) -> String)? = nil

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.value) { option in
                let on = option.value == selection
                Button {
                    withAnimation(.interactiveSpring(response: 0.25, dampingFraction: 0.85)) { selection = option.value }
                } label: {
                    Text(option.title)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(on ? Taproom.onAmber : Taproom.ink)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(on ? Taproom.amber : Color.clear, in: RoundedRectangle(cornerRadius: 10))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
                .optionalAccessibilityID(accessibilityID?(option.value))
            }
        }
        .padding(2)
        .background(Taproom.card, in: RoundedRectangle(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(Taproom.border, lineWidth: 1) }
        .sensoryFeedback(.selection, trigger: selection)
    }
}

/// A label on the left and a value on the right, for a table of figures inside a `.taproomCard()`.
/// Put a 1pt `Taproom.border` line between rows.
struct TaproomStatRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label).foregroundStyle(Taproom.muted)
            Spacer(minLength: 8)
            Text(value).font(.body.weight(.heavy).monospacedDigit())
        }
        .font(.body)
        .padding(.horizontal, 14)
        .frame(minHeight: 44)
        .accessibilityElement(children: .combine)
    }
}

/// Tabs splitting one page into views of different things (a venue's Menu and Check-ins): equal
/// full-width tabs with an icon and a heavy label, the selected one in ink over a 3pt ink
/// underline, all on a hairline that runs edge to edge. Chips go under it to narrow the
/// selected tab further. Lay it out inside the page's side margins; the hairline bleeds past them.
struct TaproomPageTabs<Value: Hashable>: View {
    let tabs: [TaproomTab<Value>]
    @Binding var selection: Value
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        HStack(spacing: 0) {
            ForEach(tabs) { tab in
                let on = tab.value == selection
                Button {
                    withAnimation(.interactiveSpring(response: 0.25, dampingFraction: 0.85)) { selection = tab.value }
                } label: {
                    Label(tab.title, systemImage: tab.systemImage)
                        .labelStyle(TightLabel())
                        .font(.body.weight(.heavy))
                        .tracking(-0.2)
                        .lineLimit(1)
                        .foregroundStyle(on ? Taproom.ink : Taproom.muted)
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .overlay(alignment: .bottom) {
                            if on { Rectangle().fill(Taproom.ink).frame(height: 3) }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .background(alignment: .bottom) {
            Rectangle().fill(Taproom.border).frame(height: 1)
                .padding(.horizontal, horizontalSizeClass == .regular ? 0 : -Taproom.margin)
        }
        .sensoryFeedback(.selection, trigger: selection)
    }
}

/// A beer's label: its own if it has one, else its brewery's logo, else a muted beer-mug
/// placeholder. Untappd's stock "no label" badges count as having none. When an HD URL is given,
/// the lower-res URL of the same artwork stays visible while the HD image loads.
struct BeerLabel: View {
    let beer: URL?
    var beerHD: URL? = nil
    let brewery: URL?
    var breweryHD: URL? = nil
    var size: CGFloat
    var cornerRadius: CGFloat = 12

    /// Untappd's generic pictures for a beer or brewery without one
    /// (`…/site/assets/images/temp/badge-beer-default.png`, `badge-brewery-default.png`).
    static func isPlaceholder(_ url: URL) -> Bool {
        url.lastPathComponent.hasPrefix("badge-") && url.lastPathComponent.contains("default")
    }

    private static func real(_ url: URL?) -> URL? {
        url.flatMap { isPlaceholder($0) ? nil : $0 }
    }

    static func resolve(beer: URL?, beerHD: URL? = nil, brewery: URL?, breweryHD: URL? = nil) -> (url: URL, fallback: URL?)? {
        if let hd = real(beerHD) {
            let low = real(beer)
            return (hd, low == hd ? nil : low)
        }
        if let low = real(beer) { return (low, nil) }
        if let hd = real(breweryHD) {
            let low = real(brewery)
            return (hd, low == hd ? nil : low)
        }
        if let low = real(brewery) { return (low, nil) }
        return nil
    }

    var body: some View {
        let resolved = Self.resolve(beer: beer, beerHD: beerHD, brewery: brewery, breweryHD: breweryHD)
        Group {
            if let resolved {
                // A warm blank while it loads, rather than flashing the placeholder.
                CachedImage(url: resolved.url, maxPixel: size * 3) {
                    if let fallback = resolved.fallback {
                        CachedImage(url: fallback, maxPixel: size * 3)
                    } else {
                        Taproom.glassInside
                    }
                }
            } else {
                BeerLabelPlaceholder(cornerRadius: cornerRadius)
            }
        }
            .aspectRatio(contentMode: .fill)
            .frame(width: size, height: size)
            .background(Taproom.card)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            .accessibilityHidden(true)
    }

}

/// A warm, muted beer-mug silhouette shown when neither a beer nor its brewery has artwork.
private struct BeerLabelPlaceholder: View {
    var cornerRadius: CGFloat

    var body: some View {
        Canvas { context, size in
            let s = min(size.width, size.height) / 64
            let dx = (size.width - 64 * s) / 2
            let dy = (size.height - 64 * s) / 2
            func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                CGPoint(x: dx + x * s, y: dy + y * s)
            }

            // Soft foam crown sitting flush on top of the mug rim (y = 21). Combine the three
            // puffs into one Path so overlapping circles don't compound opacity.
            var foamContext = context
            foamContext.clip(to: Path(CGRect(x: dx + 14.5 * s, y: dy, width: 23 * s, height: 21 * s)))
            var foam = Path()
            for (cx, cy, r) in [(19.5, 20.8, 5.0), (26.3, 18.8, 5.8), (32.7, 20.8, 4.8)] as [(CGFloat, CGFloat, CGFloat)] {
                let rect = CGRect(x: dx + (cx - r) * s, y: dy + (cy - r) * s, width: r * 2 * s, height: r * 2 * s)
                foam.addEllipse(in: rect)
            }
            foamContext.fill(foam, with: .color(Taproom.glassRim.opacity(0.55)))

            // Handle on the right side of the mug.
            var handle = Path()
            handle.move(to: pt(37.5, 26))
            handle.addArc(tangent1End: pt(47.5, 26), tangent2End: pt(47.5, 35), radius: 5 * s)
            handle.addArc(tangent1End: pt(47.5, 44), tangent2End: pt(37.5, 44), radius: 5 * s)
            handle.addLine(to: pt(37.5, 44))
            context.stroke(
                handle,
                with: .color(Taproom.glassRim),
                style: StrokeStyle(lineWidth: 4.2 * s, lineCap: .round, lineJoin: .round)
            )

            // Mug body.
            let bodyRect = CGRect(x: dx + 14.5 * s, y: dy + 21 * s, width: 23 * s, height: 30 * s)
            context.fill(
                Path(roundedRect: bodyRect, cornerRadius: 4 * s),
                with: .color(Taproom.glassRim)
            )
        }
        .background(Taproom.glassInside)
        // A subtle border keeps the muted placeholder distinct against `Taproom.card` surfaces.
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius)
                .strokeBorder(Taproom.border, lineWidth: 1)
        }
    }
}

/// A green corner with a tick, on a card or beer label for a beer the signed-in user has had.
/// Square, so the owner clips it to its own rounded corner.
struct HadCorner: View {
    var size: CGFloat = 28

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Path { p in
                p.move(to: .zero)
                p.addLine(to: CGPoint(x: size, y: 0))
                p.addLine(to: CGPoint(x: size, y: size))
                p.closeSubpath()
            }
            .fill(Taproom.had)
            Image(systemName: "checkmark")
                .font(.system(size: size * 0.3, weight: .heavy))
                .foregroundStyle(Taproom.onHad)
                .padding(.top, size * 0.12).padding(.trailing, size * 0.12)
        }
        .frame(width: size, height: size)
        .accessibilityElement()
        .accessibilityLabel("You've had this beer")
    }
}

/// Helpers for building and formatting external links (Google Maps, websites).
enum ExternalLinks {
    /// Opens a place in Google Maps (the app if installed, else the web): by name and address
    /// when any address part is present, else by coordinates.
    static func mapsURL(name: String, address: String? = nil, city: String? = nil,
                        state: String? = nil, country: String? = nil,
                        lat: Double? = nil, lng: Double? = nil) -> URL? {
        let addressParts = [address, city, state, country].compactMap { $0 }.filter { !$0.isEmpty }
        let query: String
        if !addressParts.isEmpty {
            query = ([name] + addressParts).filter { !$0.isEmpty }.joined(separator: ", ")
        } else if let lat, let lng, lat != 0 || lng != 0 {
            query = "\(lat),\(lng)"
        } else {
            return nil
        }
        var u = URLComponents(string: "https://www.google.com/maps/search/")!
        u.queryItems = [URLQueryItem(name: "api", value: "1"), URLQueryItem(name: "query", value: query)]
        return u.url
    }

    /// "coppertap.com.au/menu" for a website, without the scheme or a leading "www.".
    static func displayHost(_ url: URL) -> String {
        var s = url.absoluteString
        for p in ["https://", "http://"] where s.lowercased().hasPrefix(p) { s.removeFirst(p.count) }
        if s.lowercased().hasPrefix("www.") { s.removeFirst(4) }
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }
}

/// One or two rating columns side by side ("Everyone" beside "You" or "Your average"),
/// with an optional full-width footer row underneath (e.g. "Friends" on a beer page).
struct TaproomRatingCard: View {
    struct Column {
        let title: String
        let rating: Double?
        var empty: String = "No ratings"
        var caption: String? = nil
        var isLoading: Bool = false
        var isCaptionLoading: Bool = false
        var accessibilityID: String? = nil
    }

    let leading: Column
    var trailing: Column? = nil
    var footer: Column? = nil
    /// A `NavigationLink` value for the footer row. When set, the whole row opens it, with a
    /// chevron on the right (the beer page's Friends row opens the friends' ratings page).
    var footerLink: (any Hashable)? = nil

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                column(leading)
                if let trailing {
                    Rectangle().fill(Taproom.border).frame(width: 1)
                    column(trailing)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            if let footer {
                Rectangle().fill(Taproom.border).frame(height: 1)
                if let footerLink {
                    linkedFooterRow(footer, value: footerLink)
                } else {
                    footerRow(footer)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .taproomCard()
        .accessibilityElement(children: .contain)
    }

    private func column(_ c: Column) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(c.title).font(.caption.weight(.semibold)).foregroundStyle(Taproom.muted)
            if c.isLoading {
                HStack(alignment: .lastTextBaseline, spacing: 34 * 0.16) {
                    Text("3.80")
                        .font(.system(size: 34, weight: .heavy).monospacedDigit())
                        .tracking(-34 * 0.03)
                        .redacted(reason: .placeholder)
                    FilledGlass(rating: 0, lineWidth: 1.5)
                        .frame(height: 34 * 0.8)
                        .alignmentGuide(.lastTextBaseline) { $0[.bottom] }
                }
                .fixedSize()
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(c.title): loading")
            } else if let rating = c.rating, rating > 0 {
                TaproomRating(rating: rating, size: 34)
            } else {
                Text(c.empty).font(.system(size: 22, weight: .heavy)).tracking(-0.4).foregroundStyle(Taproom.muted)
                    .frame(minHeight: 34, alignment: .leading)
                    .accessibilityLabel("\(c.title): \(c.empty)")
            }
            if let caption = c.caption {
                Text(caption).font(.caption).foregroundStyle(Taproom.muted)
                    .redacted(reason: (c.isLoading || c.isCaptionLoading) ? .placeholder : [])
                    .accessibilityHidden(c.isLoading || c.isCaptionLoading)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .optionalAccessibilityID(c.accessibilityID)
    }

    /// The footer row as a link. Takes the value's concrete type so `NavigationLink(value:)`
    /// pushes it as that type, matching the stack's `navigationDestination(for:)`.
    private func linkedFooterRow<V: Hashable>(_ c: Column, value: V) -> AnyView {
        AnyView(
            NavigationLink(value: value) { footerRow(c, showsChevron: true) }
                .buttonStyle(TaproomRowStyle())
                .accessibilityAddTraits(.isLink)
        )
    }

    private func footerRow(_ c: Column, showsChevron: Bool = false) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(c.title).font(.caption.weight(.semibold)).foregroundStyle(Taproom.muted)
                if let caption = c.caption {
                    Text(caption).font(.caption).foregroundStyle(Taproom.muted)
                        .redacted(reason: (c.isLoading || c.isCaptionLoading) ? .placeholder : [])
                        .accessibilityHidden(c.isLoading || c.isCaptionLoading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if c.isLoading {
                HStack(alignment: .lastTextBaseline, spacing: 26 * 0.16) {
                    Text("3.80")
                        .font(.system(size: 26, weight: .heavy).monospacedDigit())
                        .tracking(-26 * 0.03)
                        .redacted(reason: .placeholder)
                    FilledGlass(rating: 0, lineWidth: 1.5)
                        .frame(height: 26 * 0.8)
                        .alignmentGuide(.lastTextBaseline) { $0[.bottom] }
                }
                .fixedSize()
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(c.title): loading")
            } else if let rating = c.rating, rating > 0 {
                TaproomRating(rating: rating, size: 26)
            } else {
                Text(c.empty).font(.system(size: 18, weight: .heavy)).tracking(-0.3).foregroundStyle(Taproom.muted)
                    .accessibilityLabel("\(c.title): \(c.empty)")
            }
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .bold)).foregroundStyle(Taproom.glassRim)
                    .accessibilityHidden(true)
            }
        }
        .foregroundStyle(Taproom.ink)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
        .optionalAccessibilityID(c.accessibilityID)
    }
}

private extension View {
    @ViewBuilder func optionalAccessibilityID(_ id: String?) -> some View {
        if let id { accessibilityIdentifier(id) } else { self }
    }
}

private struct ScrollNavigationTitleModifier: ViewModifier {
    let title: String
    let threshold: CGFloat
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .onScrollGeometryChange(for: Bool.self) { $0.contentOffset.y + $0.contentInsets.top > threshold } action: { _, hidden in
                withAnimation(.easeInOut(duration: 0.15)) { shown = hidden }
            }
            .navigationTitle(shown ? title : "")
            .navigationBarTitleDisplayMode(.inline)
    }
}

extension View {
    /// Shows `title` in the inline navigation bar once a scroll view has scrolled past its hero.
    func taproomScrollTitle(_ title: String, threshold: CGFloat = 90) -> some View {
        modifier(ScrollNavigationTitleModifier(title: title, threshold: threshold))
    }
}
