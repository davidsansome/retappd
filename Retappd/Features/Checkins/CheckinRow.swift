import SwiftUI

/// A checkin in the feed or on a profile: a card with who and where, the beer and its rating,
/// the comment, the photo edge to edge, and the toasts.
struct CheckinRow<MenuItems: View>: View {
    let checkin: Checkin
    /// Shows the user's avatar and name; off on a profile, where it's always the same person.
    var showUser = true
    /// Items for the overflow menu at the top right; the menu is hidden when this is nil.
    var menu: (() -> MenuItems)?
    /// Shows a Toast button at the end of the toasts row when set.
    var toast: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                header
                beer
                if let comment = checkin.comment {
                    Text(comment).font(.body).lineLimit(4)
                }
            }
            .padding(14)

            if let p = checkin.photo, let url = p.medium ?? p.large ?? p.small {
                // Full card width, 4:3, cropped from Untappd's square photo.
                Taproom.glassInside
                    .aspectRatio(4 / 3, contentMode: .fit)
                    .overlay { CachedImage(url: url, maxPixel: 1000).aspectRatio(contentMode: .fill) }
                    .clipped()
                    .accessibilityLabel("Photo")
            }

            if hasFooter {
                footer
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .overlay(alignment: .top) {
                        if checkin.photo == nil { Rectangle().fill(Taproom.border).frame(height: 1) }
                    }
            }
        }
        .foregroundStyle(Taproom.ink)
        .background(Taproom.card)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Taproom.border))
    }

    /// Who, where and when, with the overflow menu.
    private var header: some View {
        HStack(spacing: 10) {
            if showUser { Avatar(url: checkin.user?.avatar, size: 32) }
            whoWhereWhen
                .font(.subheadline)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let menu {
                Menu(content: menu) {
                    Image(systemName: "ellipsis")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Taproom.muted)
                        .frame(width: 44, height: 32)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("More")
                .padding(.trailing, -12)  // line the dots up with the content's trailing edge
            }
        }
    }

    private var whoWhereWhen: Text {
        var t = Text("")
        if showUser, let u = checkin.user { t = Text(u.shortName).fontWeight(.semibold) }
        var rest: [String] = []
        if let v = checkin.venue { rest.append((showUser ? "at " : "") + v.name) }
        if let d = checkin.createdAt { rest.append(RelativeTime.string(d)) }
        let tail = rest.joined(separator: " · ")
        if tail.isEmpty { return t }
        return t + Text(showUser && checkin.user != nil ? " " + tail : tail).foregroundStyle(Taproom.muted)
    }

    /// The beer, with the rating as the card's hero on the right.
    private var beer: some View {
        HStack(alignment: .center, spacing: 12) {
            if checkin.photo == nil {
                BeerLabel(beer: checkin.beer?.label, brewery: checkin.brewery?.label, size: 56)
            }
            VStack(alignment: .leading, spacing: 2) {
                if let b = checkin.brewery?.name {
                    Text(b).font(.footnote).foregroundStyle(Taproom.muted).lineLimit(1)
                }
                Text(checkin.beer?.name ?? "Unknown beer")
                    .font(.system(size: 22, weight: .heavy))
                    .tracking(-0.4)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                let meta = [checkin.beer?.style,
                            checkin.beer?.abv.map { "\($0.formatted(.number.precision(.fractionLength(0...1))))%" },
                            checkin.servingType].compactMap { $0 }.joined(separator: " · ")
                if !meta.isEmpty {
                    Text(meta).font(.caption).foregroundStyle(Taproom.muted).lineLimit(2).padding(.top, 1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let r = checkin.rating { TaproomRating(rating: r, size: 30) }
        }
    }

    private var hasFooter: Bool {
        checkin.toastCount > 0 || checkin.commentCount > 0 || !checkin.taggedFriends.isEmpty || toast != nil
    }

    /// Who they were with, then the toasts with the Toast button. With no toasts yet, the Toast
    /// button sits beside the friends instead of on a row of its own.
    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if checkin.toastCount > 0 {
                if !checkin.taggedFriends.isEmpty { withFriends }
                HStack(alignment: .center, spacing: 10) {
                    ToastChips(checkin: checkin)
                    Spacer(minLength: 0)
                    actions
                }
            } else {
                HStack(alignment: .center, spacing: 10) {
                    if !checkin.taggedFriends.isEmpty { withFriends }
                    Spacer(minLength: 0)
                    actions
                }
            }
        }
    }

    private var withFriends: some View {
        Label("with " + checkin.taggedFriends.map(\.shortName).formatted(.list(type: .and)),
              systemImage: "person.2.fill")
            .font(.caption).foregroundStyle(Taproom.muted).lineLimit(2)
            .labelStyle(TightLabel())
    }

    /// The comment count and the Toast button, at the right of the footer.
    @ViewBuilder private var actions: some View {
        if checkin.commentCount > 0 {
            Label("\(checkin.commentCount)", systemImage: "bubble.right")
                .font(.caption).foregroundStyle(Taproom.muted).labelStyle(TightLabel())
                .accessibilityLabel("\(checkin.commentCount) comments")
        }
        if let toast { ToastButton(checkin: checkin, toast: toast) }
    }
}

extension CheckinRow where MenuItems == EmptyView {
    init(checkin: Checkin, showUser: Bool = true) {
        self.init(checkin: checkin, showUser: showUser, menu: nil, toast: nil)
    }
}

/// What a checkin's overflow (and context) menu offers: checking in the beer, and editing or
/// deleting the checkin when it's the user's own.
struct CheckinMenuItems: View {
    let checkin: Checkin
    let isMine: Bool
    let checkIn: (BeerLite) -> Void
    let edit: () -> Void
    let delete: () -> Void

    /// Whether there's anything to show at all.
    static func hasItems(_ c: Checkin, isMine: Bool) -> Bool { isMine || c.beerLite != nil }

    var body: some View {
        if let b = checkin.beerLite {
            Button("Check in this beer", systemImage: "plus.circle") { checkIn(b) }
        }
        if isMine {
            Divider()
            Button("Edit checkin", systemImage: "pencil", action: edit)
            Button("Delete checkin", systemImage: "trash", role: .destructive, action: delete)
        }
    }
}

/// Every toaster's avatar, wrapping onto new lines; no names.
struct ToastChips: View {
    let checkin: Checkin
    var size: CGFloat = 24

    var body: some View {
        FlowLayout(spacing: 4) {
            Image("toast").resizable().scaledToFit()
                .frame(width: size * 0.8, height: size * 0.8).frame(height: size)
                .foregroundStyle(Taproom.muted)
            ForEach(checkin.toasters) { u in
                Avatar(url: u.avatar, size: size)
                    .accessibilityLabel(u.displayName)
            }
            let hidden = checkin.toastCount - checkin.toasters.count
            if hidden > 0 {
                Text("+\(hidden)")
                    .font(.caption2.weight(.semibold)).foregroundStyle(Taproom.muted)
                    .frame(minWidth: size, minHeight: size)
                    .background(Taproom.glassInside, in: Capsule())
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(checkin.toastCount) toasts")
    }
}

struct Avatar: View {
    let url: URL?
    let size: CGFloat

    var body: some View {
        CachedImage(url: url, maxPixel: size * 3) {
            ZStack {
                Taproom.glassInside
                Image(systemName: "person.fill").font(.system(size: size * 0.45)).foregroundStyle(Taproom.glassRim)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }
}

/// Lays children out left to right, wrapping to new rows.
struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width.map { min($0, width) } ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for i in row.indices {
                let size = subviews[i].sizeThatFits(.unspecified)
                subviews[i].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: .unspecified)
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for i in subviews.indices {
            let size = subviews[i].sizeThatFits(.unspecified)
            let needed = rows[rows.count - 1].indices.isEmpty ? size.width : rows[rows.count - 1].width + spacing + size.width
            if needed > width, !rows[rows.count - 1].indices.isEmpty {
                rows.append(Row())
            }
            var r = rows[rows.count - 1]
            r.width = r.indices.isEmpty ? size.width : r.width + spacing + size.width
            r.height = max(r.height, size.height)
            r.indices.append(i)
            rows[rows.count - 1] = r
        }
        return rows
    }
}

struct PhotoViewer: View {
    let url: URL
    let placeholder: URL
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            CachedImage(url: url, maxPixel: 2000) {
                CachedImage(url: placeholder, maxPixel: 1000) { ProgressView().tint(.white) }
            }
            .aspectRatio(contentMode: .fit)
        }
        .overlay(alignment: .topTrailing) {
            Button("Close", systemImage: "xmark.circle.fill") { dismiss() }
                .labelStyle(.iconOnly).font(.title).foregroundStyle(.white.opacity(0.8)).padding()
        }
        .onTapGesture { dismiss() }
    }
}

/// Icon for a serving style, drawn amber by default; a generic glass for styles without one.
struct ServingIcon: View {
    let name: String
    var color: Color = Taproom.amber
    @ScaledMetric private var size: CGFloat

    init(name: String, size: CGFloat, color: Color = Taproom.amber) {
        self.name = name
        self.color = color
        _size = ScaledMetric(wrappedValue: size)
    }

    static func assetName(for name: String) -> String? {
        let key = name.lowercased().filter(\.isLetter)
        let known: Set = ["draft", "bottle", "can", "cask", "crowler", "growler", "taster",
                          "nitro", "box", "sidepull", "tank", "slushie"]
        return known.contains(key) ? "serving-\(key)" : nil
    }

    var body: some View {
        Group {
            if let asset = Self.assetName(for: name) {
                Image(asset).resizable().scaledToFit()
            } else {
                Image(systemName: "wineglass").resizable().scaledToFit()
            }
        }
        .frame(width: size, height: size)
        .foregroundStyle(color)
        .accessibilityHidden(true)
    }
}

struct TightLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) { configuration.icon; configuration.title }
    }
}

enum RelativeTime {
    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f
    }()

    /// "16 minutes ago" within the last day, otherwise an absolute date and time.
    static func string(_ date: Date, now: Date = .now) -> String {
        let age = now.timeIntervalSince(date)
        if age < 60 { return "just now" }
        if age < 86_400 { return relative.localizedString(for: date, relativeTo: now) }
        let sameYear = Calendar.current.isDate(date, equalTo: now, toGranularity: .year)
        return date.formatted(sameYear
            ? .dateTime.day().month(.abbreviated).hour().minute()
            : .dateTime.day().month(.abbreviated).year().hour().minute())
    }
}
