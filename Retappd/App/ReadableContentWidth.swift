import SwiftUI

extension CGFloat {
    /// Widest a single column of rows or photos gets on large screens.
    static let readableContentWidth: CGFloat = 700
    /// Widest a two-column layout (feed grid, statistics, detail splits) gets on large screens.
    static let wideContentWidth: CGFloat = 1080
    /// Minimum container width before switching to a two-column iPad layout.
    static let twoColumnThreshold: CGFloat = 800
}

extension View {
    /// Keeps a List or ScrollView's content in a centred column no wider than `maxWidth`, so rows and
    /// full-width photos don't stretch across an iPad in landscape. No effect on narrower screens.
    func readableContentWidth(_ maxWidth: CGFloat = .readableContentWidth) -> some View {
        modifier(ReadableContentWidth(maxWidth: maxWidth))
    }
}

private struct ReadableContentWidth: ViewModifier {
    let maxWidth: CGFloat
    @State private var width: CGFloat = 0

    func body(content: Content) -> some View {
        content
            // nil keeps the system's default margins when there's no excess width.
            .contentMargins(.horizontal, width > maxWidth ? (width - maxWidth) / 2 : nil, for: .scrollContent)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }
}
