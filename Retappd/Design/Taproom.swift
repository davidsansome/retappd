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

/// A capsule chip for picking from a few options; amber when selected. `dashed` is for an
/// "add" chip (e.g. "+ Tag friends").
struct TaproomChip: ButtonStyle {
    var on: Bool
    var leading: CGFloat = 12
    var dashed = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.medium))
            .foregroundStyle(on ? Taproom.onAmber : Taproom.ink)
            .padding(.leading, leading)
            .padding(.trailing, 12)
            .frame(minHeight: 34)
            .background(on ? Taproom.amber : dashed ? Color.clear : Taproom.card, in: Capsule())
            .overlay {
                Capsule().strokeBorder(on ? Taproom.amber : dashed ? Taproom.muted : Taproom.border,
                                       style: StrokeStyle(lineWidth: 1, dash: dashed ? [4, 3] : []))
            }
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(Capsule())
    }
}

/// A secondary button: rounded, outlined, filling its share of a row.
struct TaproomOutlineButton: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .labelStyle(TightLabel())
            .font(.subheadline.weight(.medium))
            .foregroundStyle(Taproom.ink)
            .frame(maxWidth: .infinity, minHeight: 44)
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
/// it to its label, for the tab bar's action.
struct TaproomPrimaryButton: ButtonStyle {
    var fullWidth = true
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .labelStyle(TightLabel())
            .font(.headline)
            .padding(.horizontal, fullWidth ? 0 : 20)
            .frame(maxWidth: fullWidth ? .infinity : nil, minHeight: 54)
            .foregroundStyle(Taproom.background)
            .background(Taproom.ink, in: RoundedRectangle(cornerRadius: 16))
            .opacity(!isEnabled ? 0.4 : configuration.isPressed ? 0.8 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 16))
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
    /// inside `.safeAreaInset(edge: .bottom)`.
    func taproomBottomBar() -> some View {
        padding(.horizontal, Taproom.margin)
            .padding(.vertical, 8)
            .background(Taproom.background)
    }

    /// The screen background and ink colour, and amber as the tint.
    func taproomScreen() -> some View {
        foregroundStyle(Taproom.ink)
            .background(Taproom.background)
            .tint(Taproom.amber)
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
/// of a detail page. Counts that are nil are left out; draws nothing if none are left.
struct TaproomStatsCard: View {
    let stats: [(title: String, value: Int?)]

    private var shown: [(title: String, value: Int)] { stats.compactMap { s in s.value.map { (s.title, $0) } } }

    static func compact(_ n: Int) -> String {
        n < 10_000 ? n.formatted() : n.formatted(.number.notation(.compactName).precision(.fractionLength(0...1)))
    }

    var body: some View {
        if !shown.isEmpty {
            HStack(spacing: 0) {
                ForEach(Array(shown.enumerated()), id: \.offset) { i, item in
                    VStack(spacing: 2) {
                        Text(Self.compact(item.value))
                            .font(.system(size: 22, weight: .heavy).monospacedDigit())
                            .tracking(-0.5)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        Text(item.title).font(.caption).foregroundStyle(Taproom.muted).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                    .overlay(alignment: .leading) {
                        if i > 0 { Rectangle().fill(Taproom.border).frame(width: 1) }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 4)
            .taproomCard()
        }
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

/// A search field on the page: a card with a magnifying glass, and a Cancel button while it's
/// in use. `focusRequests` focuses it each time it goes up (e.g. from the tab bar's Search).
struct TaproomSearchField: View {
    @Binding var text: String
    let prompt: String
    var focusRequests = 0
    @FocusState private var focused: Bool
    @State private var handledRequests = 0

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(Taproom.muted)
                TextField(prompt, text: $text, prompt: Text(prompt).foregroundStyle(Taproom.muted))
                    .focused($focused)
                    .submitLabel(.search)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
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
            }
        }
        .animation(.snappy(duration: 0.2), value: focused || !text.isEmpty)
        .onAppear(perform: handleFocusRequest)
        .onChange(of: focusRequests) { handleFocusRequest() }
    }

    private func handleFocusRequest() {
        guard focusRequests > handledRequests else { return }
        handledRequests = focusRequests
        // Wait for the tab switch to settle, or the keyboard doesn't come up.
        Task { try? await Task.sleep(for: .milliseconds(150)); focused = true }
    }
}

/// One tab in a `TaproomTabBar`.
struct TaproomTab<Value: Hashable>: Identifiable {
    let value: Value
    let title: String
    let systemImage: String
    var id: Value { value }
}

/// The app's bottom bar: the tabs on the left and one context action (Search, Scan…) as a dark
/// button on the right, within thumb reach. It belongs at the bottom of each tab's root screen,
/// so it slides away with the root when something is pushed, and it steps aside for the keyboard.
struct TaproomTabBar<Value: Hashable, Action: View>: View {
    let tabs: [TaproomTab<Value>]
    let selection: Value
    let select: (Value) -> Void
    @ViewBuilder var action: Action
    @State private var keyboardShown = false

    var body: some View {
        Group {
            if !keyboardShown {
                HStack(spacing: 4) {
                    ForEach(tabs) { tab in
                        let on = tab.value == selection
                        Button { select(tab.value) } label: {
                            VStack(spacing: 2) {
                                Image(systemName: tab.systemImage).font(.system(size: 20, weight: .medium))
                                    .frame(height: 24)
                                Text(tab.title).font(.caption2.weight(.semibold))
                            }
                            .frame(minWidth: 56, minHeight: 50)
                            .padding(.horizontal, 2)
                            .foregroundStyle(on ? Taproom.ink : Taproom.muted)
                            .background(on ? Taproom.glassInside : .clear, in: RoundedRectangle(cornerRadius: 14))
                            .contentShape(RoundedRectangle(cornerRadius: 14))
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(on ? .isSelected : [])
                    }
                    Spacer(minLength: 8)
                    action
                }
                .padding(.horizontal, Taproom.margin)
                .padding(.top, 8)
                .padding(.bottom, 2)
                // Frosted glass, like the system bars: the page scrolls on underneath it, blurred,
                // with a wash of the page colour so it stays warm.
                .background {
                    Rectangle().fill(.ultraThinMaterial)
                        .overlay(Taproom.background.opacity(0.55))
                        .ignoresSafeArea(edges: .bottom)
                }
                .overlay(alignment: .top) { Rectangle().fill(Taproom.border.opacity(0.6)).frame(height: 0.5) }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            keyboardShown = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            keyboardShown = false
        }
    }
}

/// Tabs splitting one page into views of different things (a venue's Menu and Check-ins): equal
/// full-width tabs with an icon and a heavy label, the selected one in ink over a 3pt ink
/// underline, all on a hairline that runs edge to edge. Chips go under it to narrow the
/// selected tab further. Lay it out inside the page's side margins; the hairline bleeds past them.
struct TaproomPageTabs<Value: Hashable>: View {
    let tabs: [TaproomTab<Value>]
    @Binding var selection: Value

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
            Rectangle().fill(Taproom.border).frame(height: 1).padding(.horizontal, -Taproom.margin)
        }
        .sensoryFeedback(.selection, trigger: selection)
    }
}

/// A beer's label: its own if it has one, else its brewery's logo, else the app icon. Untappd's
/// stock "no label" badges count as having none.
struct BeerLabel: View {
    let beer: URL?
    let brewery: URL?
    var size: CGFloat
    var cornerRadius: CGFloat = 12

    /// Untappd's generic pictures for a beer or brewery without one
    /// (`…/site/assets/images/temp/badge-beer-default.png`, `badge-brewery-default.png`).
    static func isPlaceholder(_ url: URL) -> Bool {
        url.lastPathComponent.hasPrefix("badge-") && url.lastPathComponent.contains("default")
    }

    private var url: URL? {
        [beer, brewery].compactMap { $0 }.first { !Self.isPlaceholder($0) }
    }

    var body: some View {
        Group {
            if let url {
                // A warm blank while it loads, rather than flashing the app icon.
                CachedImage(url: url, maxPixel: size * 3)
            } else {
                Image("LabelPlaceholder").resizable()
            }
        }
            .aspectRatio(contentMode: .fill)
            .frame(width: size, height: size)
            .background(Taproom.card)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            .accessibilityHidden(true)
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
