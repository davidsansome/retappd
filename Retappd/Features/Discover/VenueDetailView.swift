import SwiftUI

@Observable @MainActor
final class VenueModel {
    private(set) var venue: Venue
    private(set) var sections: [MenuSections.Section] = []
    private(set) var recentBeers: [(beer: BeerLite, checkin: Checkin)] = []
    private(set) var loadingMenu = false
    private(set) var loadingRecent = false
    private(set) var error: String?
    /// Tap numbers by beer id, from /venue/info (the menu endpoint doesn't include them).
    private(set) var tapNumbers: [Int: String] = [:]
    private var loaded = false

    /// The number to badge a menu item with: its tap number if the venue sets them, otherwise
    /// its position in the menu section.
    func number(for item: MenuSections.Item) -> String? {
        if let bid = item.beer?.bid, let t = tapNumbers[bid] { return t }
        if let t = item.tapNumber { return t }
        return tapNumbers.isEmpty ? item.position.map { "\($0 + 1)" } : nil
    }

    init(venue: Venue) { self.venue = venue }

    func load(force: Bool = false) async {
        guard force || !loaded else { return }
        loaded = true
        venue = await LocalIndex.shared.resolve(venue)
        guard let id = venue.venueId else { return }
        async let m: Void = loadMenu(id)
        async let r: Void = loadRecent(id)
        _ = await (m, r)
    }

    private func loadMenu(_ id: Int) async {
        loadingMenu = true
        defer { loadingMenu = false }
        do {
            let r = try await cacheThenNetwork(.venueMenu(id), as: MenuSections.self) { sections = nonEmpty($0) }
            sections = nonEmpty(r)
            let beers = r.sections.flatMap { $0.items.compactMap(\.beer) }
            await LocalIndex.shared.add(beers: beers)
        } catch {
            // Unverified venues have no menu; that's expected.
            if venue.isVerified && sections.isEmpty { self.error = error.localizedDescription }
        }
    }

    private func loadTapNumbers(_ id: Int) async {
        let apply = { (info: VenueInfo) in
            var map: [Int: String] = [:]
            for i in info.onTap { if let bid = i.beer?.bid, let t = i.tapNumber { map[bid] = t } }
            self.tapNumbers = map
        }
        if let info = try? await cacheThenNetwork(.venueInfo(id), as: VenueInfo.self, onCached: apply) {
            apply(info)
        }
    }

    private func nonEmpty(_ m: MenuSections) -> [MenuSections.Section] {
        m.sections.filter { s in s.items.contains { $0.beer != nil } }
    }

    private func loadRecent(_ id: Int) async {
        loadingRecent = true
        defer { loadingRecent = false }
        let apply = { (p: CheckinPage) in self.recentBeers = Self.uniqueBeers(p.checkins) }
        do {
            let p = try await cacheThenNetwork(.venueCheckins(id), as: CheckinPage.self, onCached: apply)
            apply(p)
            await LocalIndex.shared.add(checkins: p.checkins)
        } catch {
            if let p = try? await cacheThenNetwork(.venueCheckins(id, friendsOnly: true), as: CheckinPage.self, onCached: apply) {
                apply(p)
            }
        }
    }

    private static func uniqueBeers(_ cs: [Checkin]) -> [(beer: BeerLite, checkin: Checkin)] {
        var seen = Set<Int>()
        return cs.compactMap { c in
            guard let b = c.beerLite, seen.insert(b.bid).inserted else { return nil }
            return (b, c)
        }
    }
}

struct VenueDetailView: View {
    @State private var model: VenueModel
    @State private var filter = ""
    @State private var checkInBeer: BeerLite?

    init(venue: Venue) { _model = State(initialValue: VenueModel(venue: venue)) }

    var body: some View {
        List {
            Section {
                HStack(spacing: 12) {
                    VenueIcon(venue: model.venue, size: 56)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 4) {
                            Text(model.venue.name).font(.title3.bold())
                            if model.venue.isVerified { VerifiedBadge() }
                        }
                        if !model.venue.subtitle.isEmpty {
                            Text(model.venue.subtitle).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                }
            }

            ForEach(model.sections) { s in
                let items = s.items.filter { i in i.beer.map(matches) ?? false }
                if !items.isEmpty {
                    Section(s.title(venueName: model.venue.name)) {
                        ForEach(items) { i in
                            if let b = i.beer {
                                // Menu numbers hidden until we know where the real tap numbers come from.
                                Button { checkInBeer = b } label: { BeerRow(beer: b) }
                                    .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            if model.loadingMenu && model.sections.isEmpty {
                Section("Menu") { ProgressView().frame(maxWidth: .infinity) }
            }

            let recent = model.recentBeers.filter { matches($0.beer) }
            if !recent.isEmpty {
                Section("Recently checked in here") {
                    ForEach(recent, id: \.beer.bid) { r in
                        Button { checkInBeer = r.beer } label: {
                            BeerRow(beer: r.beer, detail: r.checkin.createdAt.map { RelativeTime.string($0) })
                        }
                        .buttonStyle(.plain)
                    }
                }
            } else if model.loadingRecent && model.sections.isEmpty {
                Section("Recently checked in here") { ProgressView().frame(maxWidth: .infinity) }
            }

            if model.venue.venueId == nil {
                Section {
                    Text("Untappd hasn't recorded beers here yet. Search for a beer to check in.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            } else if !model.loadingMenu && !model.loadingRecent && model.sections.isEmpty && model.recentBeers.isEmpty {
                Section { Text(model.error ?? "No beers listed here yet.").font(.callout).foregroundStyle(.secondary) }
            }
        }
        .navigationTitle(model.venue.name)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $filter, prompt: "Filter beers")
        .task { await model.load() }
        .refreshable { await model.load(force: true) }
        .fullScreenCover(item: $checkInBeer) { CheckInSheet(beer: $0, venue: model.venue) }
    }

    private func matches(_ b: BeerLite) -> Bool {
        filter.isEmpty || LocalIndex.matches(query: filter, text: "\(b.name) \(b.brewery) \(b.style ?? "")")
    }
}
