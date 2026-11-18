import SwiftUI

@Observable @MainActor
final class VenueModel {
    private(set) var venue: Venue
    private(set) var sections: [MenuSections.Section] = []
    private(set) var loadingMenu = false
    /// Whether the menu request has finished (with or without a menu).
    private(set) var menuLoaded = false
    private(set) var menuError: String?
    /// Stats, website and country, from /venue/info.
    private(set) var info: VenueInfo?
    /// Checkins here by everyone, and by the user's friends. Nil until the venue's Untappd id is known.
    private(set) var everyone: CheckinListModel?
    private(set) var friends: CheckinListModel?
    private var firstLoad: Task<Void, Never>?

    init(venue: Venue) {
        self.venue = venue
        makeLists()
    }

    /// Loads the page. The first load runs in a task of its own, so leaving the page part way
    /// through doesn't leave it half loaded when it's shown again.
    func load(force: Bool = false) async {
        if force {
            await fetch(force: true)
            return
        }
        if firstLoad == nil { firstLoad = Task { await fetch(force: false) } }
        await firstLoad?.value
    }

    private func fetch(force: Bool) async {
        venue = await LocalIndex.shared.resolve(venue)
        makeLists()
        guard let id = venue.venueId else { return }
        async let m: Void = loadMenu(id)
        async let i: Void = loadInfo(id)
        async let c: Void = loadCheckins(force: force)
        _ = await (m, i, c)
    }

    /// Loads everyone's checkins straight away, for the hero's "last check-in" and the menu's
    /// times; friends' wait until their chip is picked, unless they're already showing.
    private func loadCheckins(force: Bool) async {
        guard let everyone, let friends else { return }
        if force {
            await everyone.refresh()
            if !friends.items.isEmpty { await friends.refresh() }
        } else {
            await everyone.loadIfNeeded()
        }
    }

    private func makeLists() {
        guard everyone == nil, let id = venue.venueId else { return }
        everyone = CheckinListModel(source: .venue(id, friendsOnly: false))
        friends = CheckinListModel(source: .venue(id, friendsOnly: true))
    }

    /// When the most recent checkin here was made, as far as the loaded checkins tell.
    var lastCheckin: Date? { everyone?.items.first?.createdAt }

    /// When each beer was last checked in here, from the loaded checkins.
    var lastCheckinByBeer: [Int: Date] {
        var out: [Int: Date] = [:]
        for c in everyone?.items ?? [] {
            guard let bid = c.beer?.bid, let d = c.createdAt else { continue }
            if out[bid].map({ d > $0 }) ?? true { out[bid] = d }
        }
        return out
    }

    /// Opens the venue in Google Maps (the app if installed, else the web): by name and address
    /// when there is one, which finds the place itself, else by coordinates.
    var mapsURL: URL? {
        let address = [venue.address, venue.city, venue.state, info?.country].compactMap { $0 }.filter { !$0.isEmpty }
        let query: String
        if !address.isEmpty {
            query = ([venue.name] + address).joined(separator: ", ")
        } else if let c = venue.coordinate {
            query = "\(c.coordinate.latitude),\(c.coordinate.longitude)"
        } else {
            return nil
        }
        var u = URLComponents(string: "https://www.google.com/maps/search/")!
        u.queryItems = [URLQueryItem(name: "api", value: "1"), URLQueryItem(name: "query", value: query)]
        return u.url
    }

    private func loadMenu(_ id: Int) async {
        loadingMenu = true
        defer { loadingMenu = false; menuLoaded = true }
        do {
            let r = try await cacheThenNetwork(.venueMenu(id), as: MenuSections.self) { sections = nonEmpty($0) }
            sections = nonEmpty(r)
            menuError = nil
            let beers = r.sections.flatMap { $0.items.compactMap(\.beer) }
            await LocalIndex.shared.add(beers: beers)
        } catch {
            // Unverified venues have no menu; that's expected.
            if venue.isVerified && sections.isEmpty { menuError = error.localizedDescription }
        }
    }

    private func loadInfo(_ id: Int) async {
        let apply = { (i: VenueInfo) in
            self.info = i
            if let v = i.venue { self.venue.merge(v) }
        }
        if let i = try? await cacheThenNetwork(.venueInfo(id), as: VenueInfo.self, onCached: apply) {
            apply(i)
        }
    }

    private func nonEmpty(_ m: MenuSections) -> [MenuSections.Section] {
        m.sections.filter { s in s.items.contains { $0.beer != nil } }
    }
}

struct VenueDetailView: View {
    @State private var model: VenueModel
    @State private var filter = ""
    @State private var checkInBeer: BeerLite?
    /// The tab the user picked; until then, the menu if there is one, else checkins.
    @State private var pickedTab: VenueTab?
    /// The menu section shown; defaults to the first.
    @State private var pickedSection: Int?
    @State private var who = Who.everyone
    /// Tags this page's links, so its rows only show as selected for checkins it opened itself.
    @State private var listID = UUID()
    /// Whether the hero has scrolled away, so the venue's name goes in the navigation bar.
    @State private var heroHidden = false

    enum VenueTab: Hashable { case menu, checkins }
    enum Who: Hashable { case everyone, friends }

    init(venue: Venue) { _model = State(initialValue: VenueModel(venue: venue)) }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Taproom.sectionSpacing, pinnedViews: [.sectionHeaders]) {
                hero
                stats
                whereCard
                if model.venue.venueId != nil {
                    Section {
                        switch tab {
                        case .menu: menuContent
                        case .checkins: checkinsContent
                        }
                    } header: {
                        tabsHeader
                    }
                } else {
                    Text("Untappd hasn't recorded beers here yet. Search for a beer to check in.")
                        .font(.callout).foregroundStyle(Taproom.muted)
                }
            }
            .padding(.horizontal, Taproom.margin)
            .padding(.top, 8)
            .padding(.bottom, 16)
            .frame(maxWidth: .readableContentWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.immediately)
        .onScrollGeometryChange(for: Bool.self) { $0.contentOffset.y + $0.contentInsets.top > 110 } action: { _, hidden in
            withAnimation(.easeInOut(duration: 0.15)) { heroHidden = hidden }
        }
        .foregroundStyle(Taproom.ink)
        .background(Taproom.background)
        .navigationTitle(heroHidden ? model.venue.name : "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Taproom.background, for: .navigationBar)
        .task { await model.load() }
        .refreshable { await model.load(force: true) }
        .fullScreenCover(item: $checkInBeer) { CheckInSheet(beer: $0, venue: model.venue) }
    }

    private var tab: VenueTab {
        if let pickedTab { return pickedTab }
        // Until the menu has loaded, assume there is one, so the tab doesn't flip under the user.
        return model.menuLoaded && model.sections.isEmpty ? .checkins : .menu
    }

    // MARK: Header

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
                if let last = model.lastCheckin {
                    HStack(spacing: 6) {
                        Circle().fill(Taproom.amber).frame(width: 8, height: 8)
                            .background(Circle().fill(Taproom.amber.opacity(0.25)).padding(-3))
                            .accessibilityHidden(true)
                        Text("Last check-in \(RelativeTime.string(last))")
                    }
                    .font(.footnote.weight(.semibold))
                    .padding(.top, 4)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VenueIcon(venue: model.venue, size: 72)
        }
    }

    @ViewBuilder private var stats: some View {
        if let s = model.info?.stats {
            TaproomStatsCard(stats: [("Check-ins", s.total), ("People", s.people), ("This month", s.thisMonth), ("Yours", s.yours)])
        }
    }

    @ViewBuilder private var whereCard: some View {
        let address = [model.venue.address].compactMap { $0 }.filter { !$0.isEmpty }.first
        let locality = [model.venue.city, model.venue.state, model.info?.country].compactMap { $0 }
            .filter { !$0.isEmpty }.joined(separator: " ")
        let maps = model.mapsURL
        let website = model.info?.website
        if maps != nil || website != nil {
            TaproomSection("Where") {
                VStack(spacing: 0) {
                    if let maps {
                        TaproomLinkRow(url: maps, icon: "mappin.and.ellipse", hint: "Google Maps") {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(address ?? (locality.isEmpty ? "Show on the map" : locality))
                                if address != nil, !locality.isEmpty {
                                    Text(locality).font(.footnote).foregroundStyle(Taproom.muted)
                                }
                            }
                        }
                        .accessibilityHint("Opens in Google Maps")
                    }
                    if maps != nil, website != nil {
                        Rectangle().fill(Taproom.border).frame(height: 1).padding(.leading, 46)
                    }
                    if let website {
                        TaproomLinkRow(url: website, icon: "globe", hint: "Website") {
                            Text(Self.displayHost(website)).lineLimit(1)
                        }
                        .accessibilityHint("Opens the venue's website")
                    }
                }
                .taproomCard()
            }
        }
    }

    /// "coppertap.com.au/menu" for a website, without the scheme or a leading "www.".
    static func displayHost(_ url: URL) -> String {
        var s = url.absoluteString
        for p in ["https://", "http://"] where s.lowercased().hasPrefix(p) { s.removeFirst(p.count) }
        if s.lowercased().hasPrefix("www.") { s.removeFirst(4) }
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }

    // MARK: Tabs

    /// The Menu / Check-ins tabs with the chips for the selected one, pinned under the
    /// navigation bar once the page scrolls up to them.
    private var tabsHeader: some View {
        VStack(alignment: .leading, spacing: 12) {
            TaproomPageTabs(tabs: [
                TaproomTab(value: VenueTab.menu, title: "Menu", systemImage: "list.bullet"),
                TaproomTab(value: VenueTab.checkins, title: "Check-ins", systemImage: "person.2"),
            ], selection: Binding(get: { tab }, set: { pickedTab = $0 }))
            switch tab {
            case .menu:
                if model.sections.count > 1 { sectionChips }
            case .checkins:
                whoChips
            }
        }
        .padding(.bottom, 10)
        .background {
            Taproom.background.padding(.horizontal, -Taproom.margin)
        }
    }

    private var currentSection: MenuSections.Section? {
        model.sections.first { $0.id == pickedSection } ?? model.sections.first
    }

    private var sectionChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(model.sections) { s in
                    let on = currentSection?.id == s.id
                    Button { pickedSection = s.id } label: {
                        HStack(spacing: 5) {
                            // Just the section's own name on a chip ("Beers on Tap"), not the menu's too.
                            Text(s.name ?? s.title(venueName: model.venue.name)).lineLimit(1)
                            Text("\(s.items.filter { $0.beer != nil }.count)")
                                .foregroundStyle(on ? Taproom.onAmber : Taproom.muted)
                        }
                    }
                    .buttonStyle(TaproomChip(on: on))
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
        }
        .scrollClipDisabled()
        .sensoryFeedback(.selection, trigger: currentSection?.id)
    }

    private var whoChips: some View {
        HStack(spacing: 6) {
            ForEach([(Who.everyone, "Everyone"), (Who.friends, "Friends")], id: \.0) { w, title in
                Button(title) { who = w }
                    .buttonStyle(TaproomChip(on: who == w))
                    .accessibilityAddTraits(who == w ? .isSelected : [])
            }
        }
        .sensoryFeedback(.selection, trigger: who)
    }

    // MARK: Menu

    @ViewBuilder private var menuContent: some View {
        TaproomSearchField(text: $filter, prompt: "Filter beers")
        let last = model.lastCheckinByBeer
        if filter.isEmpty {
            if let s = currentSection {
                beerRows(s.items.compactMap(\.beer), last: last)
            } else if model.loadingMenu {
                ProgressView().frame(maxWidth: .infinity).padding(.vertical, 24)
            } else {
                Text(model.menuError ?? "This venue hasn't put its menu on Untappd. See what people have had here under Check-ins.")
                    .font(.callout).foregroundStyle(Taproom.muted)
            }
        } else {
            let matches = model.sections.compactMap { s -> (MenuSections.Section, [BeerLite])? in
                let beers = s.items.compactMap(\.beer).filter(matches)
                return beers.isEmpty ? nil : (s, beers)
            }
            if matches.isEmpty {
                Text("No beers on the menu match “\(filter)”.").font(.callout).foregroundStyle(Taproom.muted)
            }
            ForEach(matches, id: \.0.id) { s, beers in
                TaproomSection(s.title(venueName: model.venue.name)) { beerRows(beers, last: last) }
            }
        }
    }

    private func beerRows(_ beers: [BeerLite], last: [Int: Date]) -> some View {
        VStack(spacing: 0) {
            // Menu numbers hidden until we know where the real tap numbers come from.
            ForEach(beers, id: \.bid) { b in
                Button { checkInBeer = b } label: {
                    BeerRow(beer: b, detail: last[b.bid].map { "here \(RelativeTime.short($0))" })
                }
                .buttonStyle(TaproomRowStyle())
                .taproomRowDivider()
                .accessibilityHint("Checks in this beer")
            }
        }
    }

    private func matches(_ b: BeerLite) -> Bool {
        filter.isEmpty || LocalIndex.matches(query: filter, text: "\(b.name) \(b.brewery) \(b.style ?? "")")
    }

    // MARK: Check-ins

    @ViewBuilder private var checkinsContent: some View {
        if let list = who == .everyone ? model.everyone : model.friends {
            GroupedCheckinList(model: list, listID: listID,
                             emptyText: who == .everyone ? "No one has checked in here yet."
                                 : "None of your friends have checked in here yet.")
                .id(who)
        }
    }
}

/// A venue's (or brewery's) checkins as compact rows grouped by how recent they are, loading more as the page
/// scrolls. Lives inside the venue page's own scroll view.
struct GroupedCheckinList: View {
    let model: CheckinListModel
    let listID: UUID
    let emptyText: String

    var body: some View {
        // Lazy, so a row's onAppear fires as it scrolls into view and pages load one at a time.
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(model.timeline) { entry in
                switch entry {
                case .header(let bucket, let isFirst):
                    Text(bucket.title).font(Taproom.sectionLabel)
                        .padding(.top, isFirst ? 0 : 16)
                        .accessibilityAddTraits(.isHeader)
                case .row(let c):
                    NavigationLink(value: CheckinRoute(checkin: c, listID: listID)) {
                        CompactCheckinRow(checkin: c)
                    }
                    .buttonStyle(TaproomRowStyle())
                    .taproomRowDivider()
                    .onAppear { model.onAppear(c) }
                }
            }
            footer
        }
        // Not tied to this view: switching tabs or chips mid-request would otherwise cancel it.
        .task { await Task { await model.loadIfNeeded() }.value }
    }

    @ViewBuilder private var footer: some View {
        if model.items.isEmpty && (model.isRefreshing || model.isLoadingMore) {
            ProgressView().frame(maxWidth: .infinity).padding(.vertical, 24)
        } else if let error = model.error {
            ErrorRow(message: error) { Task { await model.refresh() } }.padding(.top, 12)
        } else if model.items.isEmpty {
            Text(emptyText).font(.callout).foregroundStyle(Taproom.muted)
        } else if model.isLoadingMore {
            ProgressView().frame(maxWidth: .infinity).padding(.vertical, 16)
        }
    }
}
