import SwiftUI
import CoreLocation

struct DiscoverView: View {
    let model: DiscoverModel
    /// Bumped by the tab bar's Search and Scan buttons.
    var searchRequests = 0
    var scanRequests = 0
    @Environment(LocationProvider.self) private var location
    @State private var query = ""
    @State private var checkInBeer: BeerLite?
    @State private var scanning = false
    @State private var scannedBeer: BeerLite?
    @State private var handledScans = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Taproom.sectionSpacing) {
                if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    nearbyContent
                } else {
                    searchContent
                }
            }
            .padding(.horizontal, Taproom.margin)
            .padding(.top, 8)
            .padding(.bottom, 16)
            .frame(maxWidth: .readableContentWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.immediately)
        .taproomScreen()
        .safeAreaInset(edge: .top, spacing: 0) {
            TaproomSearchField(text: $query, prompt: "Beers or venues", focusRequests: searchRequests)
                .frame(maxWidth: .readableContentWidth)
                .padding(.horizontal, Taproom.margin)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity)
                .background(Taproom.background)
        }
        .toolbar(.hidden, for: .navigationBar)
        .task(id: query) { await model.search(query) }
        .task { await model.refreshIfStale(location: location.location) }
        .refreshable { await model.update(location: location.location, force: true) }
        // Venues, and the checkins and people on their pages.
        .modifier(CheckinDestinations(enabled: true, me: model.me))
        .fullScreenCover(item: $checkInBeer) { CheckInSheet(beer: $0, venue: model.here.first) }
        .sheet(isPresented: $scanning, onDismiss: {
            // Open the check-in once the scanner has gone, as only one modal shows at a time.
            if let b = scannedBeer { scannedBeer = nil; checkInBeer = b }
        }) {
            BarcodeSearchSheet { scannedBeer = $0 }
        }
        .onAppear(perform: handleScanRequest)
        .onChange(of: scanRequests) { handleScanRequest() }
    }

    private func handleScanRequest() {
        guard scanRequests > handledScans else { return }
        handledScans = scanRequests
        scanning = true
    }

    // MARK: Nearby

    @ViewBuilder private var nearbyContent: some View {
        if location.isDenied {
            Label("Location access is off. Turn it on in Settings to see venues near you, or search above.",
                  systemImage: "location.slash")
                .font(.callout).foregroundStyle(Taproom.muted)
        }

        if let here = model.here.first {
            NavigationLink(value: here) { HereCard(venue: here, origin: model.origin) }
                .buttonStyle(CardLinkStyle())
            if model.here.count > 1 {
                TaproomSection("Or maybe") { venueRows(Array(model.here.dropFirst())) }
            }
        }

        if !model.friendsNearby.isEmpty {
            TaproomSection("Friends drinking nearby") {
                VStack(spacing: 0) {
                    ForEach(model.friendsNearby) { a in
                        NavigationLink(value: a.venue) { FriendActivityRow(activity: a) }
                            .buttonStyle(TaproomRowStyle())
                            .taproomRowDivider()
                    }
                }
            }
        }

        if !model.nearby.isEmpty {
            TaproomSection("Nearby") { venueRows(model.nearby) }
        } else if model.isLoading {
            ProgressView().frame(maxWidth: .infinity).padding(.vertical, 24)
        } else if let e = model.error {
            ErrorRow(message: e) { Task { await model.update(location: location.location, force: true) } }
        } else if model.origin == nil && !location.isDenied {
            Label("Finding your location…", systemImage: "location").foregroundStyle(Taproom.muted)
                .frame(maxWidth: .infinity, alignment: .leading)
        }

        if !model.recent.isEmpty {
            TaproomSection("Your recent venues") { venueRows(model.recent) }
        }
    }

    private func venueRows<C: RandomAccessCollection>(_ venues: C) -> some View where C.Element == Venue {
        VStack(spacing: 0) {
            ForEach(venues) { v in
                NavigationLink(value: v) { VenueRow(venue: v, origin: model.origin) }
                    .buttonStyle(TaproomRowStyle())
                    .taproomRowDivider()
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
            TaproomSection("Venues") { venueRows(direct) }
        }

        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("Beers").font(Taproom.sectionLabel)
                if model.isSearching { ProgressView().controlSize(.mini) }
            }
            if model.beerResults.isEmpty {
                Text(model.isSearching ? "Searching…" : "No beers found").foregroundStyle(Taproom.muted)
            }
            VStack(spacing: 0) {
                ForEach(model.beerResults.prefix(20)) { b in
                    Button { checkInBeer = b } label: { BeerRow(beer: b) }
                        .buttonStyle(TaproomRowStyle())
                        .taproomRowDivider()
                        .accessibilityHint("Checks in this beer")
                }
            }
        }

        if !rest.isEmpty {
            TaproomSection(direct.isEmpty ? "Venues" : "More venues") { venueRows(rest.prefix(15)) }
        }
    }
}

// MARK: - Rows

/// The venue you're probably at, as Discover's hero: a card that opens its menu.
struct HereCard: View {
    let venue: Venue
    let origin: CLLocation?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("You're probably at").font(Taproom.sectionLabel).foregroundStyle(Taproom.muted)
            HStack(spacing: 12) {
                VenueIcon(venue: venue, size: 56)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(venue.name).font(.system(size: 24, weight: .heavy)).tracking(-0.4).lineLimit(2)
                        if venue.isVerified { VerifiedBadge() }
                    }
                    let sub = [venue.subtitle.isEmpty ? nil : venue.subtitle,
                               (venue.distance(from: origin) ?? venue.reportedDistance).map(Distance.string)]
                        .compactMap { $0 }.joined(separator: " · ")
                    if !sub.isEmpty {
                        Text(sub).font(.subheadline).foregroundStyle(Taproom.muted).lineLimit(1)
                    }
                }
            }
            Text("See what's on tap")
                .font(.headline)
                .foregroundStyle(Taproom.background)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(Taproom.ink, in: RoundedRectangle(cornerRadius: 12))
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(Taproom.ink)
        .taproomCard()
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens what's on tap")
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
                    Text(venue.subtitle).font(.footnote).foregroundStyle(Taproom.muted).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if let d = venue.distance(from: origin) ?? venue.reportedDistance {
                Text(Distance.string(d)).font(.footnote.monospacedDigit()).foregroundStyle(Taproom.muted)
            }
        }
        .foregroundStyle(Taproom.ink)
        .padding(.vertical, 6)
        .frame(minHeight: 56)
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
                    Text(Distance.string(d)).font(.footnote.monospacedDigit()).foregroundStyle(Taproom.muted)
                }
            }
            ForEach(activity.checkins.prefix(3)) { c in
                HStack(spacing: 8) {
                    Avatar(url: c.user?.avatar, size: 22)
                    (Text(c.user?.shortName ?? "").bold() + Text(" · \(c.beer?.name ?? "")"))
                        .font(.caption).lineLimit(1)
                    Spacer(minLength: 4)
                    if let d = c.createdAt {
                        Text(RelativeTime.string(d)).font(.caption2).foregroundStyle(Taproom.muted).lineLimit(1)
                    }
                }
            }
        }
        .foregroundStyle(Taproom.ink)
        .padding(.vertical, 10)
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
                    .foregroundStyle(Taproom.background)
                    .frame(width: 34, height: 34)
                    .background(Taproom.ink, in: RoundedRectangle(cornerRadius: 8))
                    .accessibilityLabel("Number \(number)")
            }
            BeerLabel(beer: beer.label, brewery: beer.breweryLabel, size: 44, cornerRadius: 8)
                .overlay(alignment: .topTrailing) {
                    if HadBeers.shared.has(beer) { HadCorner(size: 18) }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text(beer.name).font(.body.weight(.semibold)).lineLimit(1)
                let meta = [beer.brewery, beer.style, beer.abv.map { "\($0.formatted(.number.precision(.fractionLength(0...1))))%" }, detail]
                    .compactMap { $0 }.joined(separator: " · ")
                Text(meta).font(.footnote).foregroundStyle(Taproom.muted).lineLimit(2)
            }
            Spacer(minLength: 4)
            if let r = beer.rating, r > 0 {
                Text(r.formatted(.number.precision(.fractionLength(2))))
                    .font(.headline.weight(.heavy).monospacedDigit())
                    .accessibilityLabel("Average \(r.formatted(.number.precision(.fractionLength(2)))) out of 5")
            }
        }
        .foregroundStyle(Taproom.ink)
        .padding(.vertical, 8)
        .frame(minHeight: 60)
        .contentShape(Rectangle())
    }
}

struct VenueIcon: View {
    let venue: Venue
    let size: CGFloat

    var body: some View {
        CachedImage(url: venue.icon, maxPixel: size * 3) {
            ZStack {
                Taproom.glassInside
                Image(systemName: "mappin").foregroundStyle(Taproom.amber)
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
            .foregroundStyle(Taproom.muted)
            .accessibilityLabel("Verified venue")
    }
}

enum Distance {
    static func string(_ metres: Double) -> String {
        let m = Measurement(value: metres, unit: UnitLength.meters)
        if Locale.current.measurementSystem == .metric && metres < 1000 {
            return m.formatted(.measurement(width: .abbreviated, usage: .road, numberFormatStyle: .number.precision(.fractionLength(0))))
        }
        return m.formatted(.measurement(width: .abbreviated, usage: .road, numberFormatStyle: .number.precision(.fractionLength(0...1))))
    }
}
