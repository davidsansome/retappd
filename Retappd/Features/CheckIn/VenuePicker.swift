import SwiftUI

/// The full venue list behind the check-in screen's "…" chips: where you are and nearby places,
/// plus a search of Untappd's venues around you. As a shop picker (`kind: .shop`) it lists where
/// you've bought beer before and nearby shops instead.
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
                    TaproomSection("Nearby") {
                        let others = nearby.filter { !recentIds.contains($0.id) }
                        rows(others)
                        if others.isEmpty || (kind == .drink && nearby.count <= 1) {
                            Text(emptyNearbyText).foregroundStyle(Taproom.muted)
                        }
                    }
                } else {
                    rows(results)
                    if searching && results.isEmpty {
                        ProgressView().frame(maxWidth: .infinity).padding(.vertical, 24)
                    } else if !searching && results.isEmpty {
                        Text(kind == .shop ? "No shops found." : "No venues found.").foregroundStyle(Taproom.muted)
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
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                    prompt: kind == .shop ? "Search shops" : "Search venues")
        .navigationTitle(kind == .shop ? "Where did you buy it?" : "Where are you?")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Taproom.background, for: .navigationBar)
        .task(id: q) { await search(q) }
        .task(id: location.location == nil) { if kind == .shop { await loadShops() } }
    }

    /// Fills the shop picker's lists. Untappd's nearby list is every kind of place, often with no
    /// shops at all in a city centre, so shop-like places go first rather than being the only ones.
    private func loadShops() async {
        guard !loadedShops, let loc = location.location else { return }
        let req = APIRequest.retailVenuesAround(lat: loc.coordinate.latitude, lng: loc.coordinate.longitude)
        guard let r = try? await cacheThenNetwork(req, as: VenueAround.self, onCached: { applyShops($0) }) else {
            loadedShops = true
            return
        }
        applyShops(r)
        loadedShops = true
    }

    private func applyShops(_ r: VenueAround) {
        recentShops = r.recent.filter { $0.foursquareId != nil }
        let places = r.nearby.filter { $0.foursquareId != nil && !$0.isCustom }
        nearbyShops = places.filter(\.looksLikeShop) + places.filter { !$0.looksLikeShop }
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
                        VenueRow(venue: v, origin: location.location)
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
        try? await Task.sleep(for: .milliseconds(250))  // debounce while typing
        guard !Task.isCancelled else { return }
        searching = true
        defer { searching = false }
        let req = APIRequest.venuesAround(lat: loc.coordinate.latitude, lng: loc.coordinate.longitude, query: q)
        guard let r = try? await UntappdAPI.shared.fetch(req, as: VenueAround.self), !Task.isCancelled else { return }
        let remote = (r.recent.filter { LocalIndex.matches(query: q, text: $0.name) } + r.nearby)
            .filter { $0.foursquareId != nil && !$0.isCustom }
        let keys = Set(remote.map { $0.foursquareId ?? $0.id })
        results = remote + local.filter { !keys.contains($0.foursquareId ?? $0.id) }
        await LocalIndex.shared.add(venues: remote)
    }

    /// Searches nearby places for the shop picker. A search isn't narrowed to shops: the query
    /// already says what the user is after.
    private func searchShops(_ q: String) async {
        let mine = recent.filter { LocalIndex.matches(query: q, text: $0.name) }
        results = mine
        guard let loc = location.location else { return }
        try? await Task.sleep(for: .milliseconds(250))  // debounce while typing
        guard !Task.isCancelled else { return }
        searching = true
        defer { searching = false }
        let req = APIRequest.retailVenuesAround(lat: loc.coordinate.latitude, lng: loc.coordinate.longitude, query: q)
        guard let r = try? await UntappdAPI.shared.fetch(req, as: VenueAround.self), !Task.isCancelled else { return }
        let remote = r.nearby.filter { $0.foursquareId != nil && !$0.isCustom }
        let keys = Set(mine.map { $0.foursquareId ?? $0.id })
        results = mine + remote.filter { !keys.contains($0.foursquareId ?? $0.id) }
    }
}
