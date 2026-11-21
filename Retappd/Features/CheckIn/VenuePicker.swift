import CoreLocation
import SwiftUI

/// The full venue list behind the check-in screen's "…" chips: where you are and nearby places,
/// plus a search of Untappd's venues around you. As a shop picker (`kind: .shop`) it lists where
/// you've bought beer before and nearby shops instead, and a second field, "Near…", moves the
/// search to a named place (the server geocodes it).
struct VenuePicker: View {
    enum Kind { case drink, shop }

    @Binding var selection: Venue?
    var kind: Kind = .drink
    @Environment(\.dismiss) private var dismiss
    @Environment(LocationProvider.self) private var location
    @Environment(DiscoverModel.self) private var discover
    @State private var options = CheckInOptions.shared
    @State private var query = ""
    @State private var results: [Venue] = []
    @State private var searching = false
    /// Nearby shops and the account's recent ones from `/venue/aroundretail`, for `.shop`.
    @State private var nearbyShops: [Venue] = []
    @State private var recentShops: [Venue] = []
    @State private var loadedShops = false
    /// The shop picker's "Near…" text, and what the server made of it.
    @State private var place = ""
    @State private var resolved: ResolvedPlace?

    struct ResolvedPlace: Equatable {
        var query: String
        var name: String?
        var found: Bool
    }

    /// What reloads the shop lists: a different search, a different place, or the first location fix.
    private struct ShopQuery: Hashable {
        var text: String
        var place: String?
        var hasLocation: Bool
    }

    /// The place to search near instead of the device, for the shop picker.
    private var activePlace: String? { kind == .shop ? ShopPlace.normalized(place) : nil }

    private var placeNotFound: Bool {
        guard let p = activePlace, let r = resolved, r.query == p else { return false }
        return !r.found
    }

    /// The server's name for the place ("Melbourne VIC, Australia"), or what was typed.
    private var placeLabel: String {
        guard let p = activePlace else { return "" }
        if let r = resolved, r.query == p, let n = r.name { return n }
        return p
    }

    /// Where distances are measured from: the device, unless the search is somewhere else (the
    /// rows then show the server's distance from that place).
    private var distanceOrigin: CLLocation? { activePlace == nil ? location.location : nil }

    private var searchCoordinate: (lat: Double, lng: Double)? {
        ShopPlace.coordinate(device: location.location?.coordinate, place: activePlace)
    }

    private var recent: [Venue] {
        guard kind == .shop else { return options.recentVenues }
        var out = options.recentShops
        for v in recentShops where !out.contains(where: { $0.id == v.id }) { out.append(v) }
        return out
    }

    private var nearby: [Venue] {
        kind == .shop ? nearbyShops : discover.checkInVenues
    }

    private var emptyNearbyText: String {
        if activePlace != nil { return loadedShops ? "No shops found there. Try searching." : "Finding shops…" }
        if location.location == nil { return "Waiting for your location…" }
        if kind == .shop { return loadedShops ? "Nothing nearby. Try searching." : "Finding shops…" }
        return "Nothing nearby yet."
    }

    var body: some View {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        ScrollView {
            VStack(alignment: .leading, spacing: Taproom.sectionSpacing) {
                if q.isEmpty {
                    Button { pick(nil) } label: {
                        Label(kind == .shop ? "No shop" : "No venue", systemImage: kind == .shop ? "bag" : "mappin.slash")
                    }
                    .buttonStyle(TaproomChip(on: selection == nil, dashed: selection != nil))
                    .accessibilityAddTraits(selection == nil ? .isSelected : [])
                    let recent = recent
                    let recentIds = Set(recent.map(\.id))
                    if !recent.isEmpty {
                        TaproomSection("Recent") { rows(recent) }
                    }
                    placeSection(activePlace == nil ? "Nearby" : "Near \(placeLabel)") {
                        let others = ShopPlace.sortedByDistance(nearby.filter { !recentIds.contains($0.id) },
                                                                from: distanceOrigin)
                        if placeNotFound {
                            unknownPlace
                        } else {
                            rows(others)
                            if others.isEmpty || (kind == .drink && nearby.count <= 1) {
                                Text(emptyNearbyText).foregroundStyle(Taproom.muted)
                            }
                        }
                    }
                } else {
                    placeSection(activePlace == nil ? nil : "Near \(placeLabel)") {
                        if placeNotFound {
                            unknownPlace
                        } else {
                            rows(results)
                            if searching && results.isEmpty {
                                ProgressView().frame(maxWidth: .infinity).padding(.vertical, 24)
                            } else if !searching && results.isEmpty {
                                Text(kind == .shop ? "No shops found." : "No venues found.").foregroundStyle(Taproom.muted)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Taproom.margin)
            .padding(.top, 8)
            .padding(.bottom, 16)
        }
        .scrollDismissesKeyboard(.immediately)
        .foregroundStyle(Taproom.ink)
        .background(Taproom.background)
        .navigationTitle(kind == .shop ? "Where did you buy it?" : "Where are you?")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Taproom.background, for: .navigationBar)
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 8) {
                TaproomSearchField(text: $query, prompt: kind == .shop ? "Search shops" : "Search venues")
                if kind == .shop {
                    TaproomSearchField(text: $place, prompt: "Near… (city or country)", systemImage: "location",
                                       capitalization: .words)
                }
            }
            .padding(.horizontal, Taproom.margin)
            .padding(.top, 6)
            .padding(.bottom, 8)
            .background(Taproom.background)
        }
        .task(id: ShopQuery(text: q, place: activePlace, hasLocation: location.location != nil)) { await search(q) }
        .task(id: ShopQuery(text: q.isEmpty ? "" : "searching", place: activePlace, hasLocation: location.location != nil)) {
            if kind == .shop, q.isEmpty { await loadShops() }
        }
    }

    /// A section, titled when `title` is given. While searching near a typed place it has a
    /// button to go back to near the device.
    @ViewBuilder
    private func placeSection<C: View>(_ title: String?, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                HStack(alignment: .firstTextBaseline) {
                    Text(title).font(Taproom.sectionLabel).lineLimit(2)
                    Spacer(minLength: 8)
                    if activePlace != nil {
                        Button("Near you", systemImage: "location.fill") { place = "" }
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Taproom.ink)
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                    }
                }
            }
            content()
        }
    }

    private var unknownPlace: some View {
        VStack(spacing: 6) {
            Image(systemName: "mappin.slash").font(.title2).foregroundStyle(Taproom.muted)
            Text("Couldn't find “\(activePlace ?? "")”").font(.headline)
            Text("Check the spelling, or try a bigger town, a city or a country.")
                .font(.footnote).foregroundStyle(Taproom.muted).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .accessibilityElement(children: .combine)
    }

    /// Fills the shop picker's lists, near the device or near the typed place, nearest first.
    private func loadShops() async {
        let place = activePlace
        nearbyShops = []
        loadedShops = false
        if place != nil {
            try? await Task.sleep(for: .milliseconds(400))  // debounce while typing
            guard !Task.isCancelled else { return }
        }
        guard let c = searchCoordinate else { return }
        let req = APIRequest.retailVenuesAround(lat: c.lat, lng: c.lng, location: place)
        let r = try? await cacheThenNetwork(req, as: VenueAround.self, onCached: {
            if !Task.isCancelled { applyShops($0, place: place) }
        })
        // A newer search has replaced this one: don't let it overwrite that one's results.
        guard !Task.isCancelled else { return }
        if let r { applyShops(r, place: place) }
        loadedShops = true
    }

    private func applyShops(_ r: VenueAround, place: String?) {
        // The account's recent shops don't depend on where you look, and aren't in a place search.
        if place == nil { recentShops = r.recent.filter { $0.foursquareId != nil } }
        let places = r.nearby.filter { $0.foursquareId != nil && !$0.isCustom }
        nearbyShops = ShopPlace.sortedByDistance(places, from: place == nil ? location.location : nil)
        noteResolved(r, place: place)
    }

    private func noteResolved(_ r: VenueAround, place: String?) {
        guard let place, let found = r.placeFound else { return }
        resolved = ResolvedPlace(query: place, name: r.placeName, found: found)
    }

    private func pick(_ v: Venue?) {
        selection = v
        dismiss()
    }

    private func rows(_ venues: [Venue]) -> some View {
        VStack(spacing: 0) {
            ForEach(venues) { v in
                let on = selection?.id == v.id
                Button { pick(v) } label: {
                    HStack {
                        VenueRow(venue: v, origin: distanceOrigin)
                        if on {
                            Image(systemName: "checkmark").foregroundStyle(Taproom.amber).fontWeight(.bold)
                        }
                    }
                }
                .buttonStyle(TaproomRowStyle())
                .taproomRowDivider()
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
    }

    private func search(_ q: String) async {
        guard !q.isEmpty else { results = []; return }
        if kind == .shop { return await searchShops(q) }
        let local = await LocalIndex.shared.searchVenues(q, near: location.location).filter { $0.foursquareId != nil }
        guard !Task.isCancelled else { return }
        results = local
        guard let loc = location.location else { return }
        searching = true
        defer { searching = false }
        try? await Task.sleep(for: .milliseconds(250))  // debounce while typing
        guard !Task.isCancelled else { return }
        let req = APIRequest.venuesAround(lat: loc.coordinate.latitude, lng: loc.coordinate.longitude, query: q)
        guard let r = try? await UntappdAPI.shared.fetch(req, as: VenueAround.self), !Task.isCancelled else { return }
        let remote = (r.recent.filter { LocalIndex.matches(query: q, text: $0.name) } + r.nearby)
            .filter { $0.foursquareId != nil && !$0.isCustom }
        let keys = Set(remote.map { $0.foursquareId ?? $0.id })
        results = ShopPlace.sortedByDistance(remote + local.filter { !keys.contains($0.foursquareId ?? $0.id) },
                                             from: loc)
        await LocalIndex.shared.add(venues: remote)
    }

    /// Searches nearby places for the shop picker. A search isn't narrowed to shops: the query
    /// already says what the user is after.
    private func searchShops(_ q: String) async {
        let place = activePlace
        let origin = place == nil ? location.location : nil
        // Your own recent shops only match when searching where you are.
        let mine = place == nil ? recent.filter { LocalIndex.matches(query: q, text: $0.name) } : []
        results = ShopPlace.sortedByDistance(mine, from: origin)
        guard let c = searchCoordinate else { return }
        searching = true
        defer { searching = false }
        try? await Task.sleep(for: .milliseconds(place == nil ? 250 : 400))  // debounce while typing
        guard !Task.isCancelled else { return }
        let req = APIRequest.retailVenuesAround(lat: c.lat, lng: c.lng, query: q, location: place)
        guard let r = try? await UntappdAPI.shared.fetch(req, as: VenueAround.self), !Task.isCancelled else { return }
        noteResolved(r, place: place)
        let remote = r.nearby.filter { $0.foursquareId != nil && !$0.isCustom }
        let keys = Set(mine.map { $0.foursquareId ?? $0.id })
        results = ShopPlace.sortedByDistance(mine + remote.filter { !keys.contains($0.foursquareId ?? $0.id) },
                                             from: origin)
    }
}

/// The shop picker's "Near…" field.
enum ShopPlace {
    /// Where to point `lat`/`lng` when there's no device fix but a place was typed. The server
    /// insists on the pair (and treats 0,0 as missing) but ignores it once it has geocoded `location`.
    static let placeholderCoordinate = (lat: 1.0, lng: 1.0)

    /// The text trimmed and with runs of spaces collapsed, or nil when there's nothing to search for.
    static func normalized(_ text: String?) -> String? {
        guard let text else { return nil }
        let words = text.split(whereSeparator: \.isWhitespace)
        return words.isEmpty ? nil : words.joined(separator: " ")
    }

    /// The `lat`/`lng` to send: the device's, else a placeholder when searching near a place, else
    /// nothing (there's no search to make).
    static func coordinate(device: CLLocationCoordinate2D?, place: String?) -> (lat: Double, lng: Double)? {
        if let device { return (device.latitude, device.longitude) }
        return place == nil ? nil : placeholderCoordinate
    }

    /// Sorts venues nearest first, measuring from `origin` when given or falling back to the
    /// distance the server reported. Venues with a known distance come before ones without.
    static func sortedByDistance(_ venues: [Venue], from origin: CLLocation? = nil) -> [Venue] {
        func dist(_ v: Venue) -> Double { v.distance(from: origin) ?? v.reportedDistance ?? .infinity }
        return venues.sorted { dist($0) < dist($1) }
    }
}
