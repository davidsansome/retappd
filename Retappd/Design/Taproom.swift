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
                .background(Taproom.background)
                .overlay(alignment: .top) { Rectangle().fill(Taproom.border).frame(height: 1) }
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
