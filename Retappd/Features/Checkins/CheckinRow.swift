import SwiftUI

/// A checkin in the feed or on a profile: a card with who and where, the beer and its rating,
/// the comment, the photo edge to edge, and the toasts.
struct CheckinRow<MenuItems: View>: View {
    let checkin: Checkin
    /// Shows the user's avatar and name; off on a profile, where it's always the same person.
    var showUser = true
    /// Marks the card's corner when the signed-in user has had this beer. Off for their own
    /// checkins, where it'd always show.
    var showHad = false
    /// Items for the overflow menu at the top right; the menu is hidden when this is nil.
    var menu: (() -> MenuItems)?
    /// Shows a Toast button at the end of the toasts row when set.
    var toast: (() -> Void)?
    /// Whether to ask before deleting this checkin. The question points at the overflow menu.
    var confirmingDelete: Binding<Bool> = .constant(false)
    var delete: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                header
                beer
                if let comment = checkin.comment {
                    // fixedSize: without it the list reserves room for lines this text doesn't show,
                    // leaving a bigger gap under the card.
                    Text(comment).font(.body).lineLimit(4).fixedSize(horizontal: false, vertical: true)
                }
                ForEach(checkin.badges) { earned($0) }
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

            // With nothing else to share a row with, the shop goes in the footer, beside Toast.
            if let shop = checkin.retailVenue, toastPartner != .purchase {
                purchasedAt(shop)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .overlay(alignment: .top) { if checkin.photo == nil { divider } }
            }

            if hasFooter {
                footer
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .overlay(alignment: .top) {
                        if checkin.photo == nil || (checkin.retailVenue != nil && toastPartner != .purchase) { divider }
                    }
            }

            if let c = latestComment {
                CommentRow(user: c.user, text: c.text, date: c.createdAt, avatarSize: 28, lineLimit: 3)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .overlay(alignment: .top) { divider }
            }
        }
        .foregroundStyle(Taproom.ink)
        .background(Taproom.card)
        .clipShape(cardShape)
        .overlay(cardShape.stroke(Taproom.border))
        // On top of the border, filling the card's square corner.
        .overlay(alignment: .topTrailing) {
            if hadCorner { HadCorner() }
        }
    }

    private var hadCorner: Bool { showHad && checkin.beer.map({ HadBeers.shared.has($0.bid, fallback: $0.hasHad) }) == true }

    /// Rounded, except for a square top-right corner under the "had it" corner.
    private var cardShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(topLeadingRadius: 16, bottomLeadingRadius: 16, bottomTrailingRadius: 16,
                               topTrailingRadius: hadCorner ? 0 : 16)
    }

    /// Who and when on the first line, where (opening the venue) on the second, with the
    /// overflow menu.
    private var header: some View {
        HStack(spacing: 10) {
            if showUser { Avatar(url: checkin.user?.avatar, size: 36) }
            VStack(alignment: .leading, spacing: 1) {
                whoWhen
                if let v = checkin.venue {
                    NavigationLink(value: v) {
                        HStack(spacing: 3) {
                            Text(v.name).lineLimit(1)
                            Image(systemName: "chevron.right").font(.caption2.weight(.semibold))
                                .foregroundStyle(Taproom.muted)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Opens the venue")
                }
            }
            .font(.subheadline)
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
                .deleteCheckinConfirmation(isPresented: confirmingDelete, delete: delete)
                .padding(.trailing, -12)  // line the dots up with the content's trailing edge
            }
        }
    }

    /// The name, then the time. A long name is shortened rather than the time.
    private var whoWhen: some View {
        HStack(spacing: 0) {
            let when = checkin.createdAt.map { RelativeTime.string($0) }
            if showUser, let u = checkin.user {
                Text(u.shortName).fontWeight(.semibold).lineLimit(1)
                if let when {
                    Text(" · " + when).foregroundStyle(Taproom.muted).lineLimit(1).fixedSize()
                }
            } else if let when {
                Text(when).foregroundStyle(Taproom.muted).lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// The beer, with the rating as the card's hero on the right and the serving style under it:
    /// name, then brewery, then style, as the official app orders them.
    private var beer: some View {
        HStack(alignment: .center, spacing: 12) {
            BeerLabel(beer: checkin.beer?.label, brewery: checkin.brewery?.label, size: 56)
            VStack(alignment: .leading, spacing: 2) {
                Text(checkin.beer?.name ?? "Unknown beer")
                    .font(.system(size: 22, weight: .heavy))
                    .tracking(-0.4)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                if let b = checkin.brewery?.name {
                    Text(b).font(.subheadline).foregroundStyle(Taproom.muted).lineLimit(1)
                }
                if let style = checkin.beer?.style {
                    Text(style).font(.caption).foregroundStyle(Taproom.muted).lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if checkin.rating != nil || checkin.servingType != nil {
                VStack(alignment: .trailing, spacing: 4) {
                    if let r = checkin.rating { TaproomRating(rating: r, size: 30) }
                    if let s = checkin.servingType {
                        HStack(spacing: 4) {
                            ServingIcon(name: s, size: 15)
                            Text(s).font(.caption).foregroundStyle(Taproom.muted).lineLimit(1)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                .fixedSize()
            }
        }
    }

    private var divider: some View { Rectangle().fill(Taproom.border).frame(height: 1) }

    /// Where the beer was bought, on a row of its own under the beer; opens the shop.
    private func purchasedAt(_ shop: Venue) -> some View {
        NavigationLink(value: shop) {
            HStack(spacing: 4) {
                Image(systemName: "bag").foregroundStyle(Taproom.amber)
                (Text("Purchased at ").foregroundStyle(Taproom.muted) + Text(shop.name).foregroundStyle(Taproom.ink))
                    .lineLimit(1)
                Image(systemName: "chevron.right").font(.caption2.weight(.semibold)).foregroundStyle(Taproom.muted)
                Spacer(minLength: 0)
            }
            .font(.caption)
            .frame(minHeight: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens the shop")
    }

    /// "Earned the Pale as the Moon (Level 98) badge", with the badge's picture.
    @ViewBuilder private func earned(_ b: Checkin.Badge) -> some View {
        let line = HStack(spacing: 8) {
            CachedImage(url: b.image, maxPixel: 72).frame(width: 22, height: 22).clipShape(Circle())
                .accessibilityHidden(true)
            (Text("Earned the ").foregroundStyle(Taproom.muted) + Text(b.name).fontWeight(.semibold)
             + Text(" badge").foregroundStyle(Taproom.muted))
                .font(.caption).lineLimit(2)
        }
        if let route = BeerBreweryRoute.badge(of: b) {
            // A link of its own inside the card's link, like the venue: it wins the tap, and the
            // rest of the card still opens the check-in.
            NavigationLink(value: route) {
                HStack(spacing: 4) {
                    line
                    Image(systemName: "chevron.right").font(.caption2.weight(.semibold)).foregroundStyle(Taproom.muted)
                }
                .frame(minHeight: 28, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens the badge")
        } else {
            line
        }
    }

    /// The newest comment, previewed under the card's toasts.
    private var latestComment: Checkin.Comment? {
        checkin.comments.max { ($0.createdAt ?? .distantPast, $0.id) < ($1.createdAt ?? .distantPast, $1.id) }
    }

    private var hasFooter: Bool {
        checkin.toastCount > 0 || checkin.commentCount > 0 || !checkin.taggedFriends.isEmpty || toast != nil
    }

    /// What shares a row with the Toast button; see `ToastPartner`.
    private var toastPartner: ToastPartner {
        ToastPartner.choose(toasts: checkin.toastCount, friends: !checkin.taggedFriends.isEmpty,
                            purchase: checkin.retailVenue != nil, hasToastButton: toast != nil)
    }

    /// The Toast button shares its row with the toasts, else the friends, else the shop (see
    /// `ToastPartner`). Friends go on their own row above the toasts.
    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch toastPartner {
            case .toasts:
                if !checkin.taggedFriends.isEmpty { withFriends }
                HStack(alignment: .center, spacing: 10) {
                    ToastChips(checkin: checkin)
                    Spacer(minLength: 0)
                    actions
                }
            case .friends:
                HStack(alignment: .center, spacing: 10) {
                    withFriends
                    Spacer(minLength: 0)
                    actions
                }
            case .purchase:
                HStack(alignment: .center, spacing: 10) {
                    if let shop = checkin.retailVenue { purchasedAt(shop) }
                    Spacer(minLength: 0)
                    actions
                }
            case .none:
                HStack(alignment: .center, spacing: 10) {
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

/// What the card's Toast button shares a row with, in order of preference: the toasts, the tagged
/// friends, the shop it was bought at. It sits alone only when the card has none of those.
enum ToastPartner: Equatable {
    case toasts, friends, purchase, none

    static func choose(toasts: Int, friends: Bool, purchase: Bool, hasToastButton: Bool) -> ToastPartner {
        if toasts > 0 { return .toasts }
        if friends { return .friends }
        // Without a Toast button (a profile) the shop keeps its own row above the footer.
        if purchase && hasToastButton { return .purchase }
        return .none
    }
}

extension CheckinRow where MenuItems == EmptyView {
    init(checkin: Checkin, showUser: Bool = true) {
        self.init(checkin: checkin, showUser: showUser, menu: nil, toast: nil)
    }
}

extension View {
    /// Asks before deleting a checkin. The system points the question at the view this is on, so
    /// put it on the button that offered the delete (the overflow menu), not on the whole screen.
    func deleteCheckinConfirmation(isPresented: Binding<Bool>, delete: @escaping () -> Void) -> some View {
        confirmationDialog("Delete this checkin?", isPresented: isPresented, titleVisibility: .visible) {
            Button("Delete", role: .destructive, action: delete)
        } message: {
            Text("This can't be undone.")
        }
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

/// A checkin as one row, for lists of many checkins at one place (a venue's): who and how long
/// ago, the beer, a thumbnail of the photo, and the rating.
struct CompactCheckinRow: View {
    let checkin: Checkin

    var body: some View {
        HStack(spacing: 12) {
            Avatar(url: checkin.user?.avatar, size: 36)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 0) {
                    Text(checkin.user?.shortName ?? "Someone").fontWeight(.semibold).lineLimit(1)
                    if let d = checkin.createdAt {
                        Text(" · " + RelativeTime.short(d)).foregroundStyle(Taproom.muted).lineLimit(1).fixedSize()
                    }
                }
                .font(.footnote)
                Text(checkin.beer?.name ?? "Unknown beer")
                    .font(.body.weight(.heavy)).tracking(-0.2).lineLimit(1)
                let meta = [checkin.brewery?.name, checkin.servingType].compactMap { $0 }.joined(separator: " · ")
                if !meta.isEmpty {
                    Text(meta).font(.footnote).foregroundStyle(Taproom.muted).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let url = checkin.photo?.small ?? checkin.photo?.medium {
                CachedImage(url: url, maxPixel: 150) { Taproom.glassInside }
                    .frame(width: 44, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .accessibilityLabel("Photo")
            }
            if let r = checkin.rating { TaproomRating(rating: r, size: 22) }
        }
        .foregroundStyle(Taproom.ink)
        .padding(.vertical, 10)
        .frame(minHeight: 56)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
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
                let proposal = fitting(subviews[i], width: bounds.width)
                let size = subviews[i].sizeThatFits(proposal)
                subviews[i].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: proposal)
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for i in subviews.indices {
            let size = subviews[i].sizeThatFits(fitting(subviews[i], width: width))
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

    /// The size to offer a subview: its ideal size, but no wider than a whole row, so a long chip
    /// (a venue with a very long name, say) truncates rather than running off the edge.
    private func fitting(_ subview: LayoutSubview, width: CGFloat) -> ProposedViewSize {
        let ideal = subview.sizeThatFits(.unspecified)
        return ideal.width > width ? ProposedViewSize(width: width, height: nil) : .unspecified
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

    /// A compact age for tight rows: "now", "12m", "5h", "Yesterday", "3d", then "14 Sep", or
    /// "Jun 2025" in an earlier year.
    static func short(_ date: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        let age = now.timeIntervalSince(date)
        if age < 60 { return "now" }
        if age < 3600 { return "\(Int(age / 60))m" }
        if calendar.isDate(date, inSameDayAs: now) { return "\(Int(age / 3600))h" }
        if let y = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: y) {
            return "Yesterday"
        }
        if age < 7 * 86_400 { return "\(max(2, Int(age / 86_400)))d" }
        let sameYear = calendar.isDate(date, equalTo: now, toGranularity: .year)
        return date.formatted(sameYear ? .dateTime.day().month(.abbreviated) : .dateTime.month(.abbreviated).year())
    }

    /// Buckets for grouping a list by how recent each item is.
    enum Bucket: Int, CaseIterable, Comparable {
        case lastHour, today, thisWeek, earlier

        var title: String {
            switch self {
            case .lastHour: "Last hour"
            case .today: "Today"
            case .thisWeek: "This week"
            case .earlier: "Earlier"
            }
        }

        init(_ date: Date, now: Date = .now, calendar: Calendar = .current) {
            let age = now.timeIntervalSince(date)
            if age < 3600 { self = .lastHour }
            else if calendar.isDate(date, inSameDayAs: now) { self = .today }
            else if age < 7 * 86_400 { self = .thisWeek }
            else { self = .earlier }
        }

        static func < (a: Bucket, b: Bucket) -> Bool { a.rawValue < b.rawValue }
    }

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
