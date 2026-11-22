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
    @State private var containerWidth: CGFloat = 0
    @State private var selectedVenue: Venue?
    @State private var connectivity = Connectivity.shared
    /// The search last saved for later, so its card can say so.
    @State private var savedQuery: String?
    /// A saved check-in being finished.
    @State private var finishing: Finishing?
    /// A saved search whose beer is being looked for: the next beer tapped finishes it.
    @State private var finding: PendingCheckin?

    private struct Finishing: Identifiable {
        var item: PendingCheckin
        var beer: BeerLite
        var id: UUID { item.id }
    }

    private var isSplit: Bool { containerWidth >= .twoColumnThreshold }

    var body: some View {
        Group {
            if isSplit {
                HStack(spacing: 0) {
                    listColumn
                        .frame(width: min(380, max(320, containerWidth * 0.38)))
                    Rectangle().fill(Taproom.border).frame(width: 1).ignoresSafeArea(edges: .vertical)
                    detailColumn
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                listColumn
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { containerWidth = $0 }
        .taproomScreen()
        .toolbar(.hidden, for: .navigationBar)
        .task(id: SearchKey(query: query, offline: connectivity.offlineMode)) { await model.search(query) }
        .onChange(of: connectivity.offlineMode) { _, offline in
            // Back online by the user's choice: fetch what's around again.
            if !offline { Task { await model.update(location: location.location, force: true) } }
        }
        .task { await model.refreshIfStale(location: location.location) }
        // Venues, and the checkins and people on their pages.
        .modifier(CheckinDestinations(enabled: true, me: model.me))
        .checkInPresentation(item: $checkInBeer) { CheckInSheet(beer: $0, venue: model.here.first) }
        .checkInPresentation(item: $finishing) { CheckInSheet(pending: $0.item, beer: $0.beer) }
        .onChange(of: finishing == nil) { _, closed in
            // Back from finishing a saved search: stop looking for it if it was posted.
            if closed, let f = finding, !PendingCheckins.shared.items.contains(where: { $0.id == f.id }) {
                finding = nil
                query = ""
            }
        }
        .sheet(isPresented: $scanning, onDismiss: {
            // Open the check-in once the scanner has gone, as only one modal shows at a time.
            if let b = scannedBeer { scannedBeer = nil; checkInBeer = b }
        }) {
            BarcodeSearchSheet { scannedBeer = $0 }
        }
        .onAppear(perform: handleScanRequest)
        .onChange(of: scanRequests) { handleScanRequest() }
        .onChange(of: defaultSplitVenue?.id, initial: true) {
            if selectedVenue == nil { selectedVenue = defaultSplitVenue }
        }
    }

    private var defaultSplitVenue: Venue? {
        model.here.first ?? model.nearby.first ?? model.recent.first
    }

    private var listColumn: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Taproom.sectionSpacing) {
                connectionNotice
                if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    nearbyContent
                } else {
                    searchContent
                }
            }
            .padding(.horizontal, Taproom.margin)
            .padding(.top, 8)
            .padding(.bottom, 16)
            .frame(maxWidth: isSplit ? .infinity : .readableContentWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.immediately)
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    TaproomOfflineSwitch()
                }
                TaproomSearchField(text: $query, prompt: "Beers or venues", focusRequests: searchRequests)
            }
                .frame(maxWidth: isSplit ? .infinity : .readableContentWidth)
                .padding(.horizontal, Taproom.margin)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity)
                .background(Taproom.background)
        }
        .refreshable { await model.update(location: location.location, force: true) }
    }

    @ViewBuilder private var detailColumn: some View {
        if let venue = selectedVenue ?? defaultSplitVenue {
            VenueDetailView(venue: venue)
                .id(venue.id)
        } else {
            VStack(spacing: 10) {
                Image(systemName: "mappin.and.ellipse")
                    .font(.system(size: 36, weight: .medium))
                    .foregroundStyle(Taproom.muted)
                Text("Select a venue")
                    .font(.headline)
                    .foregroundStyle(Taproom.ink)
                Text("Pick a nearby place or search for a venue to see its menu and recent check-ins.")
                    .font(.subheadline)
                    .foregroundStyle(Taproom.muted)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 300)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Taproom.background)
        }
    }

    private struct SearchKey: Equatable {
        var query: String
        var offline: Bool
    }

    /// The offline banner, or the offer to go offline when a search is taking too long.
    @ViewBuilder private var connectionNotice: some View {
        if let f = finding {
            TaproomNotice(systemImage: "bookmark.fill", title: "Finding “\(f.query ?? "")”",
                          message: "Pick the beer to finish the check-in you saved \(f.savedAt.formatted(.relative(presentation: .named))).") {
                Button("Stop looking") { finding = nil }
                    .buttonStyle(TaproomOutlineButton())
            }
        }
        if connectivity.offlineMode {
            TaproomNotice(systemImage: "clock.arrow.circlepath", title: "Offline mode is on",
                          message: "Search shows beers and venues this phone already knows. Turn it off at the top when you have a good connection.")
        } else if model.isSlow {
            TaproomNotice(systemImage: "wifi.exclamationmark", title: "The connection is slow",
                          message: "Untappd hasn't answered yet. Go offline to search what's on this phone. It stays offline until you switch it back.") {
                HStack(spacing: 8) {
                    Button("Keep waiting") { model.dismissSlow() }
                        .buttonStyle(TaproomOutlineButton())
                    Button("Go offline") { connectivity.offlineMode = true }
                        .buttonStyle(TaproomPrimaryButton(compact: true))
                }
            }
        }
    }

    private func handleScanRequest() {
        guard scanRequests > handledScans else { return }
        handledScans = scanRequests
        scanning = true
    }

    // MARK: Nearby

    @ViewBuilder private var nearbyContent: some View {
        ToCheckInSection(
            onCheckIn: { item in if let b = item.beer { finishing = Finishing(item: item, beer: b) } },
            onFind: { item in
                finding = item
                query = item.query ?? ""
            })

        if location.isDenied {
            Label("Location access is off. Turn it on in Settings to see venues near you, or search above.",
                  systemImage: "location.slash")
                .font(.callout).foregroundStyle(Taproom.muted)
        }

        if let here = model.here.first {
            venueLink(here) { HereCard(venue: here, origin: model.origin) }
                .buttonStyle(CardLinkStyle())
            if model.here.count > 1 {
                TaproomSection("Or maybe") { venueRows(Array(model.here.dropFirst())) }
            }
        }

        if !model.friendsNearby.isEmpty {
            TaproomSection("Friends drinking nearby") {
                VStack(spacing: 0) {
                    ForEach(model.friendsNearby) { a in
                        venueLink(a.venue) { FriendActivityRow(activity: a) }
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
        } else if let e = model.error, !connectivity.offlineMode {
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
                let selected = isSplit && (selectedVenue ?? defaultSplitVenue)?.id == v.id
                venueLink(v) {
                    VenueRow(venue: v, origin: model.origin)
                        .padding(.horizontal, selected ? 8 : 0)
                        .background(selected ? Taproom.glassInside : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(TaproomRowStyle())
                .taproomRowDivider()
            }
        }
    }

    @ViewBuilder
    private func venueLink<Label: View>(_ venue: Venue, @ViewBuilder label: () -> Label) -> some View {
        if isSplit {
            Button { selectedVenue = venue } label: { label() }
        } else {
            NavigationLink(value: venue) { label() }
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
                    Button {
                        if let f = finding { finishing = Finishing(item: f, beer: b) } else { checkInBeer = b }
                    } label: { BeerRow(beer: b) }
                        .buttonStyle(TaproomRowStyle())
                        .taproomRowDivider()
                        .accessibilityHint("Checks in this beer")
                }
            }
        }

        if !rest.isEmpty {
            TaproomSection(direct.isEmpty ? "Venues" : "More venues") { venueRows(rest.prefix(15)) }
        }

        if connectivity.offlineMode || model.isSlow {
            TaproomSection("Not here?") { saveSearchCard }
        }
    }

    /// Offline (or stuck): keep the search, the time and roughly where you are, to finish later.
    @ViewBuilder private var saveSearchCard: some View {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let saved = savedQuery == q
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(saved ? "Saved “\(q)” for later" : "Save “\(q)” for later")
                    .font(.headline)
                Text(saved
                     ? "It's in your list to check in once you're back online."
                     : "We'll keep the search, the time and roughly where you are, and remind you once you're back online.")
                    .font(.footnote).foregroundStyle(Taproom.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !saved {
                Button {
                    var item = PendingCheckin(username: "", savedAt: .now, query: q)
                    item.setLocation(location.location)
                    if PendingCheckins.shared.add(item) != nil {
                        savedQuery = q
                    }
                } label: {
                    Label("Save for later", systemImage: "bookmark")
                }
                .buttonStyle(TaproomOutlineButton())
                .sensoryFeedback(.success, trigger: savedQuery)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Taproom.glassRim, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])))
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
