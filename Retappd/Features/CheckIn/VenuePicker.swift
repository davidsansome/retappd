import SwiftUI

/// The full venue list behind the check-in screen's "…" chip: where you are and nearby places,
/// plus a search of Untappd's venues around you.
struct VenuePicker: View {
    @Binding var selection: Venue?
    @Environment(\.dismiss) private var dismiss
    @Environment(LocationProvider.self) private var location
    @Environment(DiscoverModel.self) private var discover
    @State private var options = CheckInOptions.shared
    @State private var query = ""
    @State private var results: [Venue] = []
    @State private var searching = false

    var body: some View {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        ScrollView {
            VStack(alignment: .leading, spacing: Taproom.sectionSpacing) {
                if q.isEmpty {
                    Button { pick(nil) } label: {
                        Label("No venue", systemImage: "mappin.slash")
                    }
                    .buttonStyle(TaproomChip(on: selection == nil, dashed: selection != nil))
                    .accessibilityAddTraits(selection == nil ? .isSelected : [])
                    let recentIds = Set(options.recentVenues.map(\.id))
                    if !options.recentVenues.isEmpty {
                        TaproomSection("Recent") { rows(options.recentVenues) }
                    }
                    TaproomSection("Nearby") {
                        rows(discover.checkInVenues.filter { !recentIds.contains($0.id) })
                        if discover.checkInVenues.count <= 1 {
                            Text(location.location == nil ? "Waiting for your location…" : "Nothing nearby yet.")
                                .foregroundStyle(Taproom.muted)
                        }
                    }
                } else {
                    rows(results)
                    if searching && results.isEmpty {
                        ProgressView().frame(maxWidth: .infinity).padding(.vertical, 24)
                    } else if !searching && results.isEmpty {
                        Text("No venues found.").foregroundStyle(Taproom.muted)
                    }
                }
            }
            .padding(.horizontal, Taproom.margin)
            .padding(.top, 8)
            .padding(.bottom, 16)
        }
        .scrollDismissesKeyboard(.immediately)
        .foregroundStyle(Taproom.ink)
        .background(Taproom.background)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search venues")
        .navigationTitle("Where are you?")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Taproom.background, for: .navigationBar)
        .task(id: q) { await search(q) }
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
}
