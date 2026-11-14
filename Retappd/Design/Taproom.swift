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

/// The screen's one main action: full width, dark ink with light text.
struct TaproomPrimaryButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .frame(maxWidth: .infinity, minHeight: 54)
            .foregroundStyle(Taproom.background)
            .background(Taproom.ink, in: RoundedRectangle(cornerRadius: 16))
            .opacity(configuration.isPressed ? 0.8 : 1)
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
