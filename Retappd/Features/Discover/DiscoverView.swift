import SwiftUI
import CoreLocation

struct DiscoverView: View {
    let model: DiscoverModel
    @Environment(LocationProvider.self) private var location
    @State private var query = ""
    @State private var checkInBeer: BeerLite?

    var body: some View {
        List {
            if query.trimmingCharacters(in: .whitespaces).isEmpty {
                nearbyContent
            } else {
                searchContent
            }
        }
        .listStyle(.insetGrouped)
        .contentMargins(.top, 4, for: .scrollContent)
        .scrollDismissesKeyboard(.immediately)
        .safeAreaInset(edge: .top, spacing: 0) {
            SearchField(text: $query, prompt: "Beers or venues")
                .padding(.horizontal)
                .padding(.vertical, 6)
                .background(.bar)
        }
        .toolbar(.hidden, for: .navigationBar)
        .task(id: query) { await model.search(query) }
        .task { await model.refreshIfStale(location: location.location) }
        .refreshable { await model.update(location: location.location, force: true) }
        .navigationDestination(for: Venue.self) { VenueDetailView(venue: $0) }
        .sheet(item: $checkInBeer) { CheckInSheet(beer: $0, venue: model.here.first) }
    }

    // MARK: Nearby

    @ViewBuilder private var nearbyContent: some View {
        if location.isDenied {
            Section {
                Label("Location access is off. Turn it on in Settings to see venues near you, or search above.",
                      systemImage: "location.slash")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }

        if !model.here.isEmpty {
            Section("You're probably at") {
                ForEach(model.here) { v in
                    NavigationLink(value: v) { HereCard(venue: v, origin: model.origin) }
                }
            }
        }

        if !model.friendsNearby.isEmpty {
            Section("Friends drinking nearby") {
                ForEach(model.friendsNearby) { a in
                    NavigationLink(value: a.venue) { FriendActivityRow(activity: a) }
                }
            }
        }

        if !model.nearby.isEmpty {
            Section("Nearby") {
                ForEach(model.nearby) { v in
                    NavigationLink(value: v) { VenueRow(venue: v, origin: model.origin) }
                }
            }
        } else if model.isLoading {
            Section { ProgressView().frame(maxWidth: .infinity) }
        } else if let e = model.error {
            Section { ErrorRow(message: e) { Task { await model.update(location: location.location, force: true) } } }
        } else if model.origin == nil && !location.isDenied {
            Section { Label("Finding your location…", systemImage: "location").foregroundStyle(.secondary) }
        }

        if !model.recent.isEmpty {
            Section("Your recent venues") {
                ForEach(model.recent) { v in
                    NavigationLink(value: v) { VenueRow(venue: v, origin: model.origin) }
                }
            }
        }
    }

    // MARK: Search

    @ViewBuilder private var searchContent: some View {
        // Venues whose name contains every query word go above beers (only a few, so beers
        // stay visible); everything else follows the beers.
        let direct = model.venueResults.filter { LocalIndex.matches(query: query, text: $0.name) }.prefix(4)
        let directIds = Set(direct.map(\.id))
        let rest = model.venueResults.filter { !directIds.contains($0.id) }

        if !direct.isEmpty {
            Section("Venues") {
                ForEach(direct) { v in
                    NavigationLink(value: v) { VenueRow(venue: v, origin: model.origin) }
                }
            }
        }

        Section {
            if model.beerResults.isEmpty {
                Text(model.isSearching ? "Searching…" : "No beers found").foregroundStyle(.secondary)
            }
            ForEach(model.beerResults.prefix(20)) { b in
                Button { checkInBeer = b } label: { BeerRow(beer: b) }
                    .buttonStyle(.plain)
            }
        } header: {
            HStack { Text("Beers"); if model.isSearching { ProgressView().controlSize(.mini) } }
        }

        if !rest.isEmpty {
            Section(direct.isEmpty ? "Venues" : "More venues") {
                ForEach(rest.prefix(15)) { v in
                    NavigationLink(value: v) { VenueRow(venue: v, origin: model.origin) }
                }
            }
        }
    }
}

// MARK: - Search field

/// A compact search bar that doesn't need a navigation bar (which `.searchable` does).
struct SearchField: View {
    @Binding var text: String
    let prompt: String
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(prompt, text: $text)
                    .focused($focused)
                    .submitLabel(.search)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                if !text.isEmpty {
                    Button("Clear", systemImage: "xmark.circle.fill") { text = "" }
                        .labelStyle(.iconOnly).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 38)
            .background(Color(.tertiarySystemFill), in: Capsule())

            if focused || !text.isEmpty {
                Button("Cancel") { text = ""; focused = false }
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.2), value: focused || !text.isEmpty)
    }
}

// MARK: - Rows

struct HereCard: View {
    let venue: Venue
    let origin: CLLocation?

    var body: some View {
        HStack(spacing: 12) {
            VenueIcon(venue: venue, size: 52)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(venue.name).font(.headline)
                    VerifiedBadge()
                }
                Text(venue.subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                Text("See what's on tap").font(.caption.weight(.semibold)).foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 6)
    }
}

struct VenueRow: View {
    let venue: Venue
    let origin: CLLocation?

    var body: some View {
        HStack(spacing: 12) {
            VenueIcon(venue: venue, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(venue.name).font(.body).lineLimit(1)
                    if venue.isVerified { VerifiedBadge() }
                }
                if !venue.subtitle.isEmpty {
                    Text(venue.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if let d = venue.distance(from: origin) ?? venue.reportedDistance {
                Text(Distance.string(d)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
    }
}

struct FriendActivityRow: View {
    let activity: FriendActivity

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(activity.venue.name).font(.headline).lineLimit(1)
                if activity.venue.isVerified { VerifiedBadge() }
                Spacer()
                if let d = activity.distance {
                    Text(Distance.string(d)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            ForEach(activity.checkins.prefix(3)) { c in
                HStack(spacing: 8) {
                    CachedImage(url: c.user?.avatar, maxPixel: 60).frame(width: 22, height: 22).clipShape(Circle())
                    (Text(c.user?.displayName ?? "").bold() + Text(" · \(c.beer?.name ?? "")"))
                        .font(.caption).lineLimit(1)
                    Spacer(minLength: 4)
                    if let d = c.createdAt {
                        Text(RelativeTime.string(d)).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
}

struct BeerRow: View {
    let beer: BeerLite
    var detail: String? = nil
    /// The venue's own number for this beer (tap or menu number), shown prominently.
    var number: String? = nil

    var body: some View {
        HStack(spacing: 12) {
            if let number {
                Text(number)
                    .font(.headline.monospacedDigit())
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(.orange, in: RoundedRectangle(cornerRadius: 8))
                    .accessibilityLabel("Number \(number)")
            }
            CachedImage(url: beer.label, maxPixel: 120)
                .frame(width: 40, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(beer.name).font(.body.weight(.medium)).lineLimit(1)
                    if beer.hasHad == true {
                        Image(systemName: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
                            .accessibilityLabel("Had before")
                    }
                }
                Text(beer.brewery).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                let meta = [beer.style, beer.abv.map { "\($0.formatted(.number.precision(.fractionLength(0...1))))%" }, detail]
                    .compactMap { $0 }.joined(separator: " · ")
                if !meta.isEmpty {
                    Text(meta).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if let r = beer.rating, r > 0 {
                Text(r.formatted(.number.precision(.fractionLength(2))))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
    }
}

struct VenueIcon: View {
    let venue: Venue
    let size: CGFloat

    var body: some View {
        CachedImage(url: venue.icon, maxPixel: size * 3) {
            ZStack {
                Color.orange.opacity(0.15)
                Image(systemName: "mappin").foregroundStyle(.orange)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size / 4))
    }
}

struct VerifiedBadge: View {
    var body: some View {
        Image(systemName: "checkmark.seal.fill")
            .font(.caption)
            .foregroundStyle(.blue)
            .accessibilityLabel("Verified venue")
    }
}

enum Distance {
    static func string(_ metres: Double) -> String {
        let m = Measurement(value: metres, unit: UnitLength.meters)
        if metres < 1000 {
            return m.formatted(.measurement(width: .abbreviated, usage: .road, numberFormatStyle: .number.precision(.fractionLength(0))))
        }
        return m.formatted(.measurement(width: .abbreviated, usage: .road, numberFormatStyle: .number.precision(.fractionLength(0...1))))
    }
}
