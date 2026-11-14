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
    /// Which list the chips show: a menu section's id, or nil for "Recently here". Defaults to
    /// the first menu section.
    @State private var shelf: Shelf?

    enum Shelf: Hashable { case section(Int), recent }

    init(venue: Venue) { _model = State(initialValue: VenueModel(venue: venue)) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Taproom.sectionSpacing) {
                hero
                if model.venue.venueId != nil {
                    TaproomSearchField(text: $filter, prompt: "Filter beers")
                }
                if filter.isEmpty {
                    if shelves.count > 1 { shelfChips }
                    shelfContent
                } else {
                    filtered
                }
                emptyState
            }
            .padding(.horizontal, Taproom.margin)
            .padding(.top, 8)
            .padding(.bottom, 16)
            .frame(maxWidth: .readableContentWidth)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.immediately)
        .foregroundStyle(Taproom.ink)
        .background(Taproom.background)
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Taproom.background, for: .navigationBar)
        .task { await model.load() }
        .refreshable { await model.load(force: true) }
        .fullScreenCover(item: $checkInBeer) { CheckInSheet(beer: $0, venue: model.venue) }
    }

    // MARK: Sections

    private var hero: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                if !model.venue.subtitle.isEmpty {
                    Text(model.venue.subtitle).font(.subheadline).foregroundStyle(Taproom.muted)
                }
                Text(model.venue.name)
                    .font(.system(size: 30, weight: .heavy))
                    .tracking(-0.6)
                    .lineLimit(3)
                    .minimumScaleFactor(0.7)
                    .accessibilityAddTraits(.isHeader)
                if model.venue.isVerified {
                    Label("Verified venue", systemImage: "checkmark.seal.fill")
                        .labelStyle(TightLabel())
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Taproom.muted)
                        .padding(.top, 4)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VenueIcon(venue: model.venue, size: 72)
        }
    }

    /// The menu's sections, then the beers checked in here recently.
    private var shelves: [(shelf: Shelf, title: String, count: Int)] {
        var out = model.sections.map { s in
            // Just the section's own name on a chip ("Beers on Tap"), not the menu's too.
            (Shelf.section(s.id), s.name ?? s.title(venueName: model.venue.name), s.items.filter { $0.beer != nil }.count)
        }
        if !model.recentBeers.isEmpty { out.append((.recent, "Recently here", 0)) }
        return out
    }

    private var currentShelf: Shelf? {
        if let shelf, shelves.contains(where: { $0.shelf == shelf }) { return shelf }
        return shelves.first?.shelf
    }

    private var shelfChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(shelves, id: \.shelf) { s in
                    let on = currentShelf == s.shelf
                    Button { shelf = s.shelf } label: {
                        HStack(spacing: 5) {
                            Text(s.title).lineLimit(1)
                            if s.count > 0 {
                                Text("\(s.count)").foregroundStyle(on ? Taproom.onAmber : Taproom.muted)
                            }
                        }
                    }
                    .buttonStyle(TaproomChip(on: on))
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
        }
        .scrollClipDisabled()
        .sensoryFeedback(.selection, trigger: currentShelf)
    }

    @ViewBuilder private var shelfContent: some View {
        switch currentShelf {
        case .section(let id):
            if let s = model.sections.first(where: { $0.id == id }) {
                beerRows(s.items.compactMap(\.beer).map { ($0, nil) })
            }
        case .recent:
            beerRows(model.recentBeers.map { ($0.beer, $0.checkin.createdAt.map { RelativeTime.string($0) }) })
        case nil:
            if model.loadingMenu || model.loadingRecent {
                ProgressView().frame(maxWidth: .infinity).padding(.vertical, 24)
            }
        }
    }

    /// Everything matching the filter, across the menu and recent checkins.
    @ViewBuilder private var filtered: some View {
        ForEach(model.sections) { s in
            let beers = s.items.compactMap(\.beer).filter(matches)
            if !beers.isEmpty {
                TaproomSection(s.title(venueName: model.venue.name)) { beerRows(beers.map { ($0, nil) }) }
            }
        }
        let recent = model.recentBeers.filter { matches($0.beer) }
        if !recent.isEmpty {
            TaproomSection("Recently here") {
                beerRows(recent.map { ($0.beer, $0.checkin.createdAt.map { RelativeTime.string($0) }) })
            }
        }
    }

    private func beerRows(_ beers: [(BeerLite, String?)]) -> some View {
        VStack(spacing: 0) {
            // Menu numbers hidden until we know where the real tap numbers come from.
            ForEach(beers, id: \.0.bid) { b, detail in
                Button { checkInBeer = b } label: { BeerRow(beer: b, detail: detail) }
                    .buttonStyle(TaproomRowStyle())
                    .taproomRowDivider()
                    .accessibilityHint("Checks in this beer")
            }
        }
    }

    @ViewBuilder private var emptyState: some View {
        if model.venue.venueId == nil {
            Text("Untappd hasn't recorded beers here yet. Search for a beer to check in.")
                .font(.callout).foregroundStyle(Taproom.muted)
        } else if !model.loadingMenu && !model.loadingRecent && model.sections.isEmpty && model.recentBeers.isEmpty {
            Text(model.error ?? "No beers listed here yet.").font(.callout).foregroundStyle(Taproom.muted)
        }
    }

    private func matches(_ b: BeerLite) -> Bool {
        filter.isEmpty || LocalIndex.matches(query: filter, text: "\(b.name) \(b.brewery) \(b.style ?? "")")
    }
}
