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
        List {
            if q.isEmpty {
                Section { row(nil) }
                let recentIds = Set(options.recentVenues.map(\.id))
                if !options.recentVenues.isEmpty {
                    Section("Recent") { ForEach(options.recentVenues) { row($0) } }
                }
                Section("Nearby") {
                    ForEach(discover.checkInVenues.filter { !recentIds.contains($0.id) }) { row($0) }
                    if discover.checkInVenues.count <= 1 {
                        Text(location.location == nil ? "Waiting for your location…" : "Nothing nearby yet.")
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                Section {
                    ForEach(results) { row($0) }
                    if searching && results.isEmpty {
                        ProgressView().frame(maxWidth: .infinity)
                    } else if !searching && results.isEmpty {
                        Text("No venues found.").foregroundStyle(.secondary)
                    }
                }
            }
        }
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search venues")
        .navigationTitle("Venue")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: q) { await search(q) }
    }

    private func row(_ v: Venue?) -> some View {
        let on = selection?.id == v?.id
        return Button {
            selection = v
            dismiss()
        } label: {
            HStack {
                if let v {
                    VenueRow(venue: v, origin: location.location)
                } else {
                    Label("No venue", systemImage: "mappin.slash")
                }
                if on {
                    Image(systemName: "checkmark").foregroundStyle(.orange).fontWeight(.semibold)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
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
