import SwiftUI

/// Client-side sort orders for a venue's digital menu. (`POST /v4/menus/sections` only captured an
/// empty `sort` value in `untappd-private-api`, so sorting is applied locally.)
enum VenueMenuSort: String, CaseIterable, Identifiable, Sendable {
    case menuOrder = ""
    case highestRated = "highest_rated"
    case nameAsc = "beer_name_asc"
    case abvDesc = "abv_desc"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .menuOrder: "Menu Order"
        case .highestRated: "Highest Rated"
        case .nameAsc: "Name (A to Z)"
        case .abvDesc: "ABV (High to Low)"
        }
    }

    func sort(_ items: [MenuSections.Item]) -> [MenuSections.Item] {
        switch self {
        case .menuOrder:
            return items
        case .highestRated:
            return items.sorted { a, b in
                let ra = a.beer?.rating ?? -1
                let rb = b.beer?.rating ?? -1
                if ra != rb { return ra > rb }
                return (a.beer?.name ?? "").localizedCaseInsensitiveCompare(b.beer?.name ?? "") == .orderedAscending
            }
        case .nameAsc:
            return items.sorted { a, b in
                (a.beer?.name ?? "").localizedCaseInsensitiveCompare(b.beer?.name ?? "") == .orderedAscending
            }
        case .abvDesc:
            return items.sorted { a, b in
                let aa = a.beer?.abv ?? -1
                let ab = b.beer?.abv ?? -1
                if aa != ab { return aa > ab }
                return (a.beer?.name ?? "").localizedCaseInsensitiveCompare(b.beer?.name ?? "") == .orderedAscending
            }
        }
    }
}

/// Active search, filter, and sort state for a venue's digital menu.
struct VenueMenuFilter: Equatable, Sendable {
    var query: String = ""
    var hasNotHadBefore: Bool = false
    var sort: VenueMenuSort = .menuOrder
    var style: String? = nil

    var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    var isActive: Bool {
        !trimmedQuery.isEmpty || hasNotHadBefore || sort != .menuOrder || style != nil
    }

    /// True when criteria can be sent to `POST /v4/menus/sections` to narrow a truncated menu.
    var hasServerFilter: Bool {
        !trimmedQuery.isEmpty || hasNotHadBefore || style != nil
    }

    func request(venueId: Int, limit: Int = 100) -> APIRequest {
        .venueMenu(
            venueId,
            limit: limit,
            query: trimmedQuery,
            hasNotHadBefore: hasNotHadBefore,
            styles: style.map { [$0] } ?? []
        )
    }
}

@Observable @MainActor
final class VenueModel {
    private(set) var venue: Venue
    private(set) var sections: [MenuSections.Section] = []
    /// Server-filtered sections when the unfiltered menu has a truncated section (>limit items).
    private(set) var filteredServerSections: [MenuSections.Section]?
    private(set) var menuFilters: VenueMenuFilters?
    private(set) var filter = VenueMenuFilter()
    private(set) var loadingMenu = false
    private(set) var loadingFilteredMenu = false
    /// Whether the menu request has finished (with or without a menu).
    private(set) var menuLoaded = false
    private(set) var menuError: String?
    /// Stats, website and country, from /venue/info.
    private(set) var info: VenueInfo?
    /// Checkins here by everyone, and by the user's friends. Nil until the venue's Untappd id is known.
    private(set) var everyone: CheckinListModel?
    private(set) var friends: CheckinListModel?
    /// When each beer was last checked in here, cached from `everyone?.items`.
    private(set) var lastCheckinByBeer: [Int: Date] = [:]
    private var firstLoad: Task<Void, Never>?
    private var filterGeneration = 0
    @ObservationIgnored private let fetchMenuOverride: (@Sendable (APIRequest) async throws -> MenuSections)?
    @ObservationIgnored private let fetchMenuFiltersOverride: (@Sendable (APIRequest) async throws -> VenueMenuFilters)?

    init(
        venue: Venue,
        fetchMenu: (@Sendable (APIRequest) async throws -> MenuSections)? = nil,
        fetchMenuFilters: (@Sendable (APIRequest) async throws -> VenueMenuFilters)? = nil
    ) {
        self.venue = venue
        self.fetchMenuOverride = fetchMenu
        self.fetchMenuFiltersOverride = fetchMenuFilters
        makeLists()
    }

    var hasTruncatedSection: Bool {
        sections.contains(where: \.isTruncated)
    }

    /// Styles available on this venue's menu, from `/v4/menus/filters` or derived from the loaded items.
    var availableStyles: [VenueMenuFilters.FilterOption] {
        if let styles = menuFilters?.styles, !styles.isEmpty { return styles }
        var counts: [String: Int] = [:]
        for section in sections {
            for item in section.items {
                if let style = item.beer?.style, !style.isEmpty {
                    counts[style, default: 0] += 1
                }
            }
        }
        return counts
            .map { VenueMenuFilters.FilterOption(name: $0.key, count: $0.value) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func filteredItems(
        in section: MenuSections.Section,
        hasHad: ((BeerLite) -> Bool)? = nil
    ) -> [MenuSections.Item] {
        let checkHad = hasHad ?? { HadBeers.shared.has($0) }
        let q = filter.trimmedQuery
        let matched = section.items.filter { item in
            guard let beer = item.beer else { return false }
            if filter.hasNotHadBefore && checkHad(beer) { return false }
            if let style = filter.style,
               beer.style?.caseInsensitiveCompare(style) != .orderedSame {
                return false
            }
            if !q.isEmpty && !LocalIndex.matches(query: q, text: "\(beer.name) \(beer.brewery) \(beer.style ?? "")") {
                return false
            }
            return true
        }
        return filter.sort.sort(matched)
    }

    func filteredSections(
        hasHad: ((BeerLite) -> Bool)? = nil
    ) -> [(MenuSections.Section, [MenuSections.Item])] {
        let source = filteredServerSections ?? sections
        return source.compactMap { s in
            let items = filteredItems(in: s, hasHad: hasHad)
            return items.isEmpty ? nil : (s, items)
        }
    }

    func setSearchQuery(_ query: String) {
        filter.query = query
        if !filter.hasServerFilter {
            filterGeneration += 1
            filteredServerSections = nil
            loadingFilteredMenu = false
        }
    }

    func toggleHasNotHadBefore() async {
        var next = filter
        next.hasNotHadBefore.toggle()
        await applyFilter(next)
    }

    func setSort(_ sort: VenueMenuSort) {
        filter.sort = sort
    }

    func setStyle(_ style: String?) async {
        guard filter.style != style else { return }
        var next = filter
        next.style = style
        await applyFilter(next)
    }

    func resetFilters() async {
        let fresh = VenueMenuFilter()
        guard filter != fresh || filteredServerSections != nil else { return }
        await applyFilter(fresh)
    }

    func applyFilter(_ next: VenueMenuFilter) async {
        filter = next
        await syncServerFilterIfNeeded()
    }

    /// Queries `POST /v4/menus/sections` with active filters when any section was truncated.
    func syncServerFilterIfNeeded() async {
        filterGeneration += 1
        let gen = filterGeneration
        guard hasTruncatedSection, filter.hasServerFilter, let id = venue.venueId else {
            filteredServerSections = nil
            loadingFilteredMenu = false
            return
        }
        let req = filter.request(venueId: id)
        loadingFilteredMenu = true
        defer {
            if gen == filterGeneration { loadingFilteredMenu = false }
        }
        do {
            let r: MenuSections
            if let override = fetchMenuOverride {
                r = try await override(req)
            } else {
                r = try await UntappdAPI.shared.fetch(req, as: MenuSections.self)
            }
            guard gen == filterGeneration else { return }
            filteredServerSections = nonEmpty(r)
        } catch {
            // Fall back to client-side filtering of already-loaded sections on error.
            guard gen == filterGeneration else { return }
            if !error.isCancellation { filteredServerSections = nil }
        }
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
        if fetchMenuOverride == nil {
            venue = await LocalIndex.shared.resolve(venue)
        }
        makeLists()
        guard let id = venue.venueId else { return }
        async let m: Void = loadMenu(id)
        async let f: Void = loadMenuFilters(id)
        async let i: Void = loadInfo(id)
        async let c: Void = loadCheckins(force: force)
        _ = await (m, f, i, c)
    }

    /// Loads everyone's checkins straight away, for the hero's "last check-in" and the menu's
    /// times; friends' wait until their chip is picked, unless they're already showing.
    private func loadCheckins(force: Bool) async {
        guard fetchMenuOverride == nil else { return }
        guard let everyone, let friends else { return }
        if force {
            await everyone.refresh()
            if !friends.items.isEmpty { await friends.refresh() }
        } else {
            await everyone.loadIfNeeded()
        }
        updateLastCheckinByBeer()
    }

    private func makeLists() {
        guard everyone == nil, let id = venue.venueId else { return }
        everyone = CheckinListModel(source: .venue(id, friendsOnly: false))
        friends = CheckinListModel(source: .venue(id, friendsOnly: true))
    }

    /// When the most recent checkin here was made, as far as the loaded checkins tell.
    var lastCheckin: Date? { everyone?.items.first?.createdAt }

    /// Recomputes `lastCheckinByBeer` from the loaded checkins.
    func updateLastCheckinByBeer() {
        var out: [Int: Date] = [:]
        for c in everyone?.items ?? [] {
            guard let bid = c.beer?.bid, let d = c.createdAt else { continue }
            if out[bid].map({ d > $0 }) ?? true { out[bid] = d }
        }
        lastCheckinByBeer = out
    }

    /// Opens the venue in Google Maps (the app if installed, else the web): by name and address
    /// when there is one, which finds the place itself, else by coordinates.
    var mapsURL: URL? {
        ExternalLinks.mapsURL(name: venue.name, address: venue.address, city: venue.city,
                              state: venue.state, country: info?.country,
                              lat: venue.coordinate?.coordinate.latitude,
                              lng: venue.coordinate?.coordinate.longitude)
    }

    private func loadMenu(_ id: Int) async {
        loadingMenu = true
        defer { loadingMenu = false; menuLoaded = true }
        do {
            let r: MenuSections
            if let override = fetchMenuOverride {
                r = try await override(.venueMenu(id))
            } else {
                r = try await cacheThenNetwork(.venueMenu(id), as: MenuSections.self) { sections = nonEmpty($0) }
            }
            sections = nonEmpty(r)
            menuError = nil
            let beers = r.sections.flatMap { $0.items.compactMap(\.beer) }
            if fetchMenuOverride == nil {
                await LocalIndex.shared.add(beers: beers)
            }
            if hasTruncatedSection && filter.hasServerFilter {
                await syncServerFilterIfNeeded()
            }
        } catch {
            // Unverified venues have no menu; that's expected.
            if !error.isCancellation, venue.isVerified && sections.isEmpty { menuError = error.localizedDescription }
        }
    }

    private func loadMenuFilters(_ id: Int) async {
        let req = APIRequest.venueMenuFilters(id)
        if let override = fetchMenuFiltersOverride {
            if let f = try? await override(req) { menuFilters = f }
            return
        }
        guard fetchMenuOverride == nil else { return }
        if let f = try? await cacheThenNetwork(req, as: VenueMenuFilters.self, onCached: { self.menuFilters = $0 }) {
            menuFilters = f
        }
    }

    private func loadInfo(_ id: Int) async {
        guard fetchMenuOverride == nil else { return }
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
    @State private var searchText = ""
    @State private var checkInBeer: BeerLite?
    /// The tab the user picked; until then, the menu if there is one, else checkins.
    @State private var pickedTab: VenueTab?
    /// The menu section shown; defaults to the first.
    @State private var pickedSection: Int?
    @State private var who = Who.everyone
    /// Tags this page's links, so its rows only show as selected for checkins it opened itself.
    @State private var listID = UUID()
    @State private var containerWidth: CGFloat = 0

    enum VenueTab: Hashable { case menu, checkins }
    enum Who: Hashable { case everyone, friends }

    init(venue: Venue) { _model = State(initialValue: VenueModel(venue: venue)) }

    private var isTwoColumn: Bool { containerWidth >= .twoColumnThreshold }

    var body: some View {
        ScrollView {
            Group {
                if isTwoColumn {
                    HStack(alignment: .top, spacing: 24) {
                        VStack(alignment: .leading, spacing: Taproom.sectionSpacing) {
                            hero
                            stats
                            whereCard
                        }
                        .frame(minWidth: 300, maxWidth: 400, alignment: .leading)

                        LazyVStack(alignment: .leading, spacing: Taproom.sectionSpacing, pinnedViews: [.sectionHeaders]) {
                            venueBody
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    LazyVStack(alignment: .leading, spacing: Taproom.sectionSpacing, pinnedViews: [.sectionHeaders]) {
                        hero
                        stats
                        whereCard
                        venueBody
                    }
                }
            }
            .padding(.horizontal, Taproom.margin)
            .padding(.top, 8)
            .padding(.bottom, 16)
            .frame(maxWidth: isTwoColumn ? .wideContentWidth : .readableContentWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { containerWidth = $0 }
        .scrollDismissesKeyboard(.immediately)
        .taproomScreen()
        .taproomScrollTitle(model.venue.name, threshold: 110)
        .toolbarBackground(Taproom.background, for: .navigationBar)
        .task { await model.load() }
        .task(id: searchText) {
            let previousTrimmed = model.filter.trimmedQuery
            model.setSearchQuery(searchText)
            let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed != previousTrimmed, model.hasTruncatedSection, model.filter.hasServerFilter else {
                return
            }
            if !trimmed.isEmpty {
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
            }
            await model.syncServerFilterIfNeeded()
        }
        .refreshable { await model.load(force: true) }
        .onChange(of: model.everyone?.items) { model.updateLastCheckinByBeer() }
        .checkInPresentation(item: $checkInBeer) { CheckInSheet(beer: $0, venue: model.venue) }
    }

    @ViewBuilder private var venueBody: some View {
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
                            Text(ExternalLinks.displayHost(website)).lineLimit(1)
                        }
                        .accessibilityHint("Opens the venue's website")
                    }
                }
                .taproomCard()
            }
        }
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
                    let count = model.filteredItems(in: s).count
                    Button { pickedSection = s.id } label: {
                        HStack(spacing: 5) {
                            // Just the section's own name on a chip ("Beers on Tap"), not the menu's too.
                            Text(s.name ?? s.title(venueName: model.venue.name)).lineLimit(1)
                            Text("\(count)")
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

    private var menuFilterBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            TaproomSearchField(text: $searchText, prompt: "Filter beers", fieldIdentifier: "venue.menu.search")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    Button {
                        Task { await model.toggleHasNotHadBefore() }
                    } label: {
                        HStack(spacing: 5) {
                            if model.filter.hasNotHadBefore {
                                Image(systemName: "checkmark").font(.caption.weight(.bold))
                            }
                            Text("Haven't had")
                        }
                    }
                    .buttonStyle(TaproomChip(on: model.filter.hasNotHadBefore))
                    .accessibilityAddTraits(model.filter.hasNotHadBefore ? .isSelected : [])
                    .accessibilityIdentifier("venue.menu.haventHad")

                    Menu {
                        ForEach(VenueMenuSort.allCases) { option in
                            Button {
                                model.setSort(option)
                            } label: {
                                if model.filter.sort == option {
                                    Label(option.title, systemImage: "checkmark")
                                } else {
                                    Text(option.title)
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "arrow.up.arrow.down").font(.caption.weight(.semibold))
                            Text(model.filter.sort.title).lineLimit(1)
                            Image(systemName: "chevron.down").font(.caption2.weight(.bold))
                        }
                        .taproomChipLabel(on: model.filter.sort != .menuOrder)
                    }
                    .accessibilityLabel("Sort menu, \(model.filter.sort.title)")
                    .accessibilityIdentifier("venue.menu.sort")

                    let styles = model.availableStyles
                    if !styles.isEmpty {
                        Menu {
                            Button {
                                Task { await model.setStyle(nil) }
                            } label: {
                                if model.filter.style == nil {
                                    Label("All styles", systemImage: "checkmark")
                                } else {
                                    Text("All styles")
                                }
                            }
                            Divider()
                            ForEach(styles) { style in
                                Button {
                                    Task { await model.setStyle(style.name) }
                                } label: {
                                    let title = style.count > 0 ? "\(style.name) (\(style.count))" : style.name
                                    if model.filter.style == style.name {
                                        Label(title, systemImage: "checkmark")
                                    } else {
                                        Text(title)
                                    }
                                }
                            }
                        } label: {
                            HStack(spacing: 5) {
                                Text(model.filter.style ?? "Style").lineLimit(1)
                                Image(systemName: "chevron.down").font(.caption2.weight(.bold))
                            }
                            .taproomChipLabel(on: model.filter.style != nil)
                        }
                        .accessibilityLabel(model.filter.style.map { "Style, \($0)" } ?? "Filter by style")
                        .accessibilityIdentifier("venue.menu.style")
                    }

                    if model.filter.isActive {
                        Button {
                            searchText = ""
                            Task { await model.resetFilters() }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "xmark").font(.caption.weight(.bold))
                                Text("Clear")
                            }
                        }
                        .buttonStyle(TaproomChip(on: false, dashed: true))
                        .accessibilityIdentifier("venue.menu.clearFiltersChip")
                    }
                }
            }
            .scrollClipDisabled()
            .sensoryFeedback(.selection, trigger: model.filter)
        }
    }

    @ViewBuilder private var menuContent: some View {
        let last = model.lastCheckinByBeer
        if model.sections.isEmpty {
            if model.loadingMenu {
                ProgressView().frame(maxWidth: .infinity).padding(.vertical, 24)
            } else {
                Text(model.menuError ?? "This venue hasn't put its menu on Untappd. See what people have had here under Check-ins.")
                    .font(.callout).foregroundStyle(Taproom.muted)
            }
        } else {
            menuFilterBar
            if !model.filter.trimmedQuery.isEmpty || model.filteredServerSections != nil {
                let matches = model.filteredSections()
                if matches.isEmpty {
                    if model.loadingFilteredMenu {
                        ProgressView().frame(maxWidth: .infinity).padding(.vertical, 24)
                    } else {
                        TaproomEmptyFilterView(clearButtonIdentifier: "venue.menu.clearFilters") {
                            searchText = ""
                            Task { await model.resetFilters() }
                        }
                    }
                } else {
                    VStack(alignment: .leading, spacing: Taproom.sectionSpacing) {
                        ForEach(matches, id: \.0.id) { s, items in
                            TaproomSection(s.title(venueName: model.venue.name)) { beerRows(items, last: last) }
                        }
                    }
                    .opacity(model.loadingFilteredMenu ? 0.5 : 1)
                    .animation(.easeInOut(duration: 0.15), value: model.loadingFilteredMenu)
                }
            } else if let s = currentSection {
                let items = model.filteredItems(in: s)
                if items.isEmpty && model.filter.isActive {
                    TaproomEmptyFilterView(clearButtonIdentifier: "venue.menu.clearFilters") {
                        searchText = ""
                        Task { await model.resetFilters() }
                    }
                } else {
                    beerRows(items, last: last)
                }
            }
        }
    }

    private func beerRows(_ items: [MenuSections.Item], last: [Int: Date]) -> some View {
        let rows = items.enumerated().compactMap { offset, item -> (id: Int, beer: BeerLite)? in
            guard let beer = item.beer else { return nil }
            return (item.id != 0 ? item.id : -(offset + 1), beer)
        }
        return VStack(spacing: 0) {
            // Menu numbers hidden until we know where the real tap numbers come from.
            ForEach(rows, id: \.id) { _, b in
                Button { checkInBeer = b } label: {
                    BeerRow(beer: b, detail: last[b.bid].map { "here \(RelativeTime.short($0))" })
                }
                .buttonStyle(TaproomRowStyle())
                .taproomRowDivider()
                .accessibilityHint("Checks in this beer")
            }
        }
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
