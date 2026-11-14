import SwiftUI

struct CheckinRow: View {
    let checkin: Checkin
    /// Shows the user's name; the avatar is always shown.
    var showUser = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Only the who/when/where header sits beside the photo; the rest uses the full width.
            HStack(alignment: .center, spacing: 12) {
                Avatar(url: checkin.user?.avatar, size: 40)

                HStack(alignment: .top, spacing: 6) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            if showUser, let u = checkin.user {
                                Text(u.shortName).font(.subheadline.weight(.semibold)).lineLimit(1)
                            }
                            if let d = checkin.createdAt {
                                Text(RelativeTime.string(d)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    .layoutPriority(1)
                            }
                        }

                        if let v = checkin.venue {
                            Label(v.name, systemImage: "mappin.circle.fill")
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                .labelStyle(TightLabel())
                        }
                    }

                    Spacer(minLength: 4)

                    if checkin.rating != nil || checkin.servingType != nil {
                        VStack(alignment: .trailing, spacing: 4) {
                            if let r = checkin.rating { RatingView(rating: r) }
                            if let s = checkin.servingType { ServingChip(name: s) }
                        }
                        .fixedSize(horizontal: true, vertical: false)
                    }
                }
            }

            HStack(alignment: .center, spacing: 12) {
                CachedImage(url: checkin.beer?.label, maxPixel: 160)
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 48, height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: 10))

                VStack(alignment: .leading, spacing: 2) {
                    Text(checkin.beer?.name ?? "Unknown beer").font(.headline).lineLimit(2)

                    if let b = checkin.brewery?.name {
                        Text(b).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }

            if let comment = checkin.comment {
                Text(comment).font(.callout).lineLimit(3)
            }

            if let p = checkin.photo, let url = p.medium ?? p.large ?? p.small {
                // Full row width, 4:3, cropped from Untappd's square photo.
                Color(.secondarySystemFill)
                    .aspectRatio(4 / 3, contentMode: .fit)
                    .overlay { CachedImage(url: url, maxPixel: 1000).aspectRatio(contentMode: .fill) }
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }

            if !checkin.taggedFriends.isEmpty {
                Label("with " + checkin.taggedFriends.map(\.shortName).formatted(.list(type: .and)),
                      systemImage: "person.2.fill")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    .labelStyle(TightLabel())
            }

            if checkin.toastCount > 0 || checkin.commentCount > 0 {
                HStack(alignment: .top, spacing: 10) {
                    if checkin.toastCount > 0 { ToastChips(checkin: checkin) }
                    Spacer(minLength: 0)
                    if checkin.commentCount > 0 {
                        Label("\(checkin.commentCount)", systemImage: "bubble.right")
                            .font(.caption).foregroundStyle(.secondary).labelStyle(TightLabel())
                    }
                }
            }
        }
        .padding(.vertical, 6)
    }
}

/// Every toaster's avatar, wrapping onto new lines; no names.
struct ToastChips: View {
    let checkin: Checkin
    var size: CGFloat = 24

    var body: some View {
        FlowLayout(spacing: 4) {
            Text("🍻").font(.system(size: size * 0.7)).frame(height: size)
            ForEach(checkin.toasters) { u in
                Avatar(url: u.avatar, size: size)
                    .accessibilityLabel(u.displayName)
            }
            let hidden = checkin.toastCount - checkin.toasters.count
            if hidden > 0 {
                Text("+\(hidden)")
                    .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    .frame(minWidth: size, minHeight: size)
                    .background(Color(.secondarySystemFill), in: Capsule())
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
                Color(.secondarySystemFill)
                Image(systemName: "person.fill").font(.system(size: size * 0.45)).foregroundStyle(.secondary)
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

struct RatingView: View {
    let rating: Double

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "star.fill").font(.caption2).foregroundStyle(.orange)
            Text(rating.formatted(.number.precision(.fractionLength(2))))
                .font(.caption.weight(.semibold).monospacedDigit())
        }
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(.orange.opacity(0.12), in: Capsule())
        .accessibilityLabel("Rated \(rating) out of 5")
    }
}

/// The serving style ("Draft", "Can"…) as a chip matching `RatingView`.
struct ServingChip: View {
    let name: String

    var body: some View {
        HStack(spacing: 3) {
            ServingIcon(name: name, size: 13)
            Text(name).font(.caption.weight(.semibold)).lineLimit(1)
        }
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(.orange.opacity(0.12), in: Capsule())
        .accessibilityElement(children: .combine)
    }
}

/// Icon for a serving style, drawn orange; a generic glass for styles without one.
struct ServingIcon: View {
    let name: String
    @ScaledMetric private var size: CGFloat

    init(name: String, size: CGFloat) {
        self.name = name
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
        .foregroundStyle(.orange)
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
