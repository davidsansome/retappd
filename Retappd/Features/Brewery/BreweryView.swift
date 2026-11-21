import SwiftUI

/// Active search, filter, and sort state for a brewery's beer list.
struct BreweryBeerFilter: Equatable, Sendable {
    var query: String = ""
    var hasNotHadBefore: Bool = false
    var sortKey: String = BreweryBeerList.SortOption.defaultKey
    var styleId: Int? = nil

    var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    var isActive: Bool {
        !trimmedQuery.isEmpty || hasNotHadBefore || sortKey != BreweryBeerList.SortOption.defaultKey || styleId != nil
    }

    func request(breweryId: Int, offset: Int = 0) -> APIRequest {
        .breweryBeers(
            breweryId,
            offset: offset,
            query: trimmedQuery,
            hasNotHadBefore: hasNotHadBefore,
            sort: sortKey,
            styleId: styleId
        )
    }
}

@Observable @MainActor
final class BreweryModel {
    let brewery: BreweryPreview
    private(set) var info: BreweryInfo?
    private(set) var beers: [BeerLite] = []
    /// How many beers match the current filter, as the beer list reports it.
    private(set) var totalBeers: Int?
    private(set) var loadingBeers = false
    private(set) var loadingMoreBeers = false
    private(set) var beersError: String?
    private(set) var loadError: String?
    /// True once the initial `brewery/info` request has settled (or failed).
    private(set) var infoLoaded = false
    /// Active search, "haven't had", sort, and style filters.
    private(set) var filter = BreweryBeerFilter()
    /// Styles available at this brewery, populated from the unfiltered beer list response.
    private(set) var availableStyles: [BreweryBeerList.StyleOption] = []
    /// Sort options supported by the server (falls back to `SortOption.defaults` before first load).
    private(set) var sortingOptions: [BreweryBeerList.SortOption] = BreweryBeerList.SortOption.defaults
    /// Set once a page of beers adds nothing new, so "Show more" stops (the endpoint's paging
    /// isn't captured in the docs).
    private var beersExhausted = false
    /// Bumped on every filter reload so stale responses from earlier requests are ignored.
    private var beersGeneration = 0
    let checkins: CheckinListModel
    private var firstLoad: Task<Void, Never>?
    @ObservationIgnored private let fetchBeersOverride: (@Sendable (APIRequest) async throws -> BreweryBeerList)?

    init(
        brewery: BreweryPreview,
        fetchBeers: (@Sendable (APIRequest) async throws -> BreweryBeerList)? = nil
    ) {
        self.brewery = brewery
        self.fetchBeersOverride = fetchBeers
        checkins = CheckinListModel(source: .brewery(brewery.id))
    }

    var isLoadingInfo: Bool { info == nil && !infoLoaded }
    var name: String { info?.name ?? brewery.name }
    var label: URL? { info?.label ?? brewery.label }

    var activeSortName: String {
        sortingOptions.first { $0.key == filter.sortKey }?.name
            ?? BreweryBeerList.SortOption.defaults.first { $0.key == filter.sortKey }?.name
            ?? "Sort"
    }

    var activeStyleName: String? {
        guard let id = filter.styleId else { return nil }
        return availableStyles.first { $0.id == id }?.name
    }

    var hasMoreBeers: Bool {
        guard !beersExhausted, !beers.isEmpty else { return false }
        return beers.count < (totalBeers ?? beers.count)
    }

    func load(force: Bool = false) async {
        if force {
            await fetch(force: true)
            return
        }
        if firstLoad == nil { firstLoad = Task { await fetch(force: false) } }
        await firstLoad?.value
    }

    func setSearchQuery(_ query: String) async {
        var next = filter
        next.query = query
        guard next.trimmedQuery != filter.trimmedQuery else {
            filter.query = query
            return
        }
        await applyFilter(next)
    }

    func toggleHasNotHadBefore() async {
        var next = filter
        next.hasNotHadBefore.toggle()
        await applyFilter(next)
    }

    func setSortKey(_ key: String) async {
        guard filter.sortKey != key else { return }
        var next = filter
        next.sortKey = key
        await applyFilter(next)
    }

    func setStyleId(_ id: Int?) async {
        guard filter.styleId != id else { return }
        var next = filter
        next.styleId = id
        await applyFilter(next)
    }

    func resetFilters() async {
        let fresh = BreweryBeerFilter()
        guard filter != fresh else { return }
        await applyFilter(fresh)
    }

    func applyFilter(_ next: BreweryBeerFilter) async {
        filter = next
        beersExhausted = false
        await loadFirstBeers(force: true)
    }

    private func fetch(force: Bool) async {
        async let i: Void = loadInfo()
        async let b: Void = loadFirstBeers(force: force)
        _ = await (i, b)
    }

    private func loadInfo() async {
        let apply = { (i: BreweryInfo) in self.info = i }
        defer { infoLoaded = true }
        do {
            apply(try await cacheThenNetwork(.breweryInfo(brewery.id), as: BreweryInfo.self, onCached: apply))
            loadError = nil
        } catch {
            if !error.isCancellation { loadError = error.localizedDescription }
        }
    }

    private func applyBeerListMetadata(_ list: BreweryBeerList, for usedFilter: BreweryBeerFilter) {
        if !list.sortingOptions.isEmpty {
            sortingOptions = list.sortingOptions
        }
        if !list.styles.isEmpty && (availableStyles.isEmpty || usedFilter.styleId == nil) {
            availableStyles = list.styles
        }
    }

    private func loadFirstBeers(force: Bool) async {
        beersGeneration += 1
        let gen = beersGeneration
        let activeFilter = filter
        let request = activeFilter.request(breweryId: brewery.id, offset: 0)
        loadingBeers = true
        loadingMoreBeers = false
        defer {
            if gen == beersGeneration { loadingBeers = false }
        }
        do {
            let l: BreweryBeerList
            if let override = fetchBeersOverride {
                l = try await override(request)
            } else if !activeFilter.isActive {
                let applyCached = { (cached: BreweryBeerList) in
                    guard gen == self.beersGeneration else { return }
                    if self.beers.isEmpty || force {
                        self.beers = cached.beers
                        self.totalBeers = cached.total
                        self.applyBeerListMetadata(cached, for: activeFilter)
                    }
                }
                l = try await cacheThenNetwork(request, as: BreweryBeerList.self, onCached: applyCached)
            } else {
                l = try await UntappdAPI.shared.fetch(request, as: BreweryBeerList.self)
            }
            guard gen == beersGeneration else { return }
            beers = l.beers
            totalBeers = l.total
            beersExhausted = false
            beersError = nil
            applyBeerListMetadata(l, for: activeFilter)
            Task.detached(priority: .utility) { await LocalIndex.shared.add(beers: l.beers) }
        } catch {
            guard gen == beersGeneration else { return }
            if !error.isCancellation { beersError = error.localizedDescription }
        }
    }

    func loadMoreBeers() async {
        guard !loadingBeers, !loadingMoreBeers, hasMoreBeers else { return }
        let gen = beersGeneration
        let request = filter.request(breweryId: brewery.id, offset: beers.count)
        loadingMoreBeers = true
        defer {
            if gen == beersGeneration { loadingMoreBeers = false }
        }
        do {
            let l: BreweryBeerList
            if let override = fetchBeersOverride {
                l = try await override(request)
            } else {
                l = try await UntappdAPI.shared.fetch(request, as: BreweryBeerList.self)
            }
            guard gen == beersGeneration else { return }
            let known = Set(beers.map(\.bid))
            let new = l.beers.filter { !known.contains($0.bid) }
            if new.isEmpty { beersExhausted = true }
            beers += new
            beersError = nil
            Task.detached(priority: .utility) { await LocalIndex.shared.add(beers: new) }
        } catch {
            guard gen == beersGeneration else { return }
            if !error.isCancellation { beersError = error.localizedDescription }
        }
    }
}

/// A brewery's page: who they are, how to find them, their beers and recent check-ins.
struct BreweryView: View {
    @State private var model: BreweryModel
    @State private var tab = Tab.beers
    @State private var searchText = ""
    /// Tags this page's links, so its rows only show as selected for checkins it opened itself.
    @State private var listID = UUID()
    @State private var containerWidth: CGFloat = 0

    enum Tab: Hashable { case beers, checkins }

    init(brewery: BreweryPreview) { _model = State(initialValue: BreweryModel(brewery: brewery)) }

    private var isTwoColumn: Bool { containerWidth >= .twoColumnThreshold }

    var body: some View {
        ScrollView {
            Group {
                if isTwoColumn {
                    HStack(alignment: .top, spacing: 24) {
                        VStack(alignment: .leading, spacing: Taproom.sectionSpacing) {
                            summaryContent
                        }
                        .frame(minWidth: 300, maxWidth: 400, alignment: .leading)

                        LazyVStack(alignment: .leading, spacing: Taproom.sectionSpacing, pinnedViews: [.sectionHeaders]) {
                            tabsSection
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    LazyVStack(alignment: .leading, spacing: Taproom.sectionSpacing, pinnedViews: [.sectionHeaders]) {
                        summaryContent
                        if model.isLoadingInfo {
                            ProgressView().frame(maxWidth: .infinity).padding(.vertical, 32)
                        } else {
                            tabsSection
                        }
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
        .scrollDismissesKeyboard(.interactively)
        .taproomScreen()
        .taproomScrollTitle(model.name)
        .toolbarBackground(Taproom.background, for: .navigationBar)
        .task { await model.load() }
        .task { await model.checkins.loadIfNeeded() }
        .task(id: searchText) {
            let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed != model.filter.trimmedQuery else { return }
            if !trimmed.isEmpty {
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
            }
            await model.setSearchQuery(searchText)
        }
        .refreshable {
            async let details: Void = model.load(force: true)
            async let checkins: Void = model.checkins.refresh()
            _ = await (details, checkins)
        }
    }

    @ViewBuilder private var summaryContent: some View {
        hero
        ratings
        TaproomStatsCard(stats: [("Beers", model.info?.beerCount), ("Check-ins", model.info?.stats?.total),
                                 ("People", model.info?.stats?.people), ("Yours", model.info?.stats?.yours)],
                         isLoading: model.isLoadingInfo)
        if let d = model.info?.description {
            TaproomSection("About") { ExpandableText(text: d) }
        }
        links
        if let e = model.loadError, model.info == nil {
            ErrorRow(message: e) { Task { await model.load(force: true) } }
        }
    }

    private var tabsSection: some View {
        Section {
            switch tab {
            case .beers: beersContent
            case .checkins:
                GroupedCheckinList(model: model.checkins, listID: listID,
                                   emptyText: "No one has checked in a beer from here yet.")
            }
        } header: {
            TaproomPageTabs(tabs: [
                TaproomTab(value: Tab.beers, title: "Beers", systemImage: "list.bullet"),
                TaproomTab(value: Tab.checkins, title: "Check-ins", systemImage: "person.2"),
            ], selection: $tab)
            .padding(.bottom, 10)
            .background { Taproom.background.padding(.horizontal, -Taproom.margin) }
        }
    }

    // MARK: Header

    private var heroSubtitle: String {
        [model.info?.type, model.info?.locality]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    private var hero: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.name)
                    .font(.system(size: 30, weight: .heavy))
                    .tracking(-0.6)
                    .lineLimit(3)
                    .minimumScaleFactor(0.7)
                    .textSelection(.enabled)
                    .accessibilityAddTraits(.isHeader)
                let subtitle = heroSubtitle
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(Taproom.muted)
                        .padding(.top, 2)
                } else if model.isLoadingInfo {
                    Text("Micro Brewery · City, Country")
                        .font(.footnote)
                        .foregroundStyle(Taproom.muted)
                        .padding(.top, 2)
                        .redacted(reason: .placeholder)
                        .accessibilityHidden(true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            BeerLabel(beer: nil, brewery: model.label, breweryHD: model.info?.labelHD, size: 72, cornerRadius: 18)
        }
    }

    @ViewBuilder private var ratings: some View {
        if let r = model.info?.rating, r > 0 {
            TaproomRatingCard(
                leading: .init(title: "Everyone", rating: r,
                               caption: model.info?.ratingCount.map { "\($0.formatted()) ratings" }),
                trailing: model.info?.yourAverage.flatMap { $0 > 0 ? $0 : nil }.map {
                    .init(title: "Your average", rating: $0, caption: "across the beers you've had")
                }
            )
        } else if model.isLoadingInfo {
            TaproomRatingCard(
                leading: .init(title: "Everyone", rating: nil, caption: "10,000 ratings", isLoading: true)
            )
        }
    }

    // MARK: Links

    private struct Link: Identifiable {
        var id: String { hint }
        let url: URL
        let icon: String
        let hint: String
        let text: String
    }

    private var linkItems: [Link] {
        guard let i = model.info else { return [] }
        var out: [Link] = []
        if let u = i.website { out.append(Link(url: u, icon: "globe", hint: "Website", text: ExternalLinks.displayHost(u))) }
        if let u = i.instagram { out.append(Link(url: u, icon: "camera", hint: "Instagram", text: Self.handle(u))) }
        if let u = i.twitter { out.append(Link(url: u, icon: "at", hint: "X", text: Self.handle(u))) }
        if let u = i.facebook { out.append(Link(url: u, icon: "person.2", hint: "Facebook", text: Self.handle(u))) }
        if let u = mapsURL { out.append(Link(url: u, icon: "mappin.and.ellipse", hint: "Google Maps",
                                             text: [i.address, i.locality].compactMap { $0 }.filter { !$0.isEmpty }.first ?? "Show on the map")) }
        return out
    }

    private var mapsURL: URL? {
        guard let i = model.info else { return nil }
        return ExternalLinks.mapsURL(name: i.name, address: i.address, city: i.city, state: i.state, country: i.country)
    }

    /// "@handle" from the last part of a social link, or the bare host if there's no path.
    private static func handle(_ url: URL) -> String {
        guard let last = url.pathComponents.last(where: { $0 != "/" && !$0.isEmpty }) else {
            return ExternalLinks.displayHost(url)
        }
        return last.hasPrefix("@") ? last : "@\(last)"
    }

    @ViewBuilder private var links: some View {
        let items = linkItems
        if !items.isEmpty {
            TaproomSection("Find them") {
                VStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { i, l in
                        if i > 0 { Rectangle().fill(Taproom.border).frame(height: 1).padding(.leading, 46) }
                        TaproomLinkRow(url: l.url, icon: l.icon, hint: l.hint) { Text(l.text).lineLimit(1) }
                            .accessibilityHint("Opens \(l.hint)")
                    }
                }
                .taproomCard()
            }
        }
    }

    // MARK: Beers

    private var beersFilterBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            TaproomSearchField(text: $searchText, prompt: "Search beers", fieldIdentifier: "brewery.beers.search")
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
                    .accessibilityIdentifier("brewery.beers.haventHad")

                    Menu {
                        ForEach(model.sortingOptions) { option in
                            Button {
                                Task { await model.setSortKey(option.key) }
                            } label: {
                                if model.filter.sortKey == option.key {
                                    Label(option.name, systemImage: "checkmark")
                                } else {
                                    Text(option.name)
                                }
                            }
                        }
                    } label: {
                        let nonDefault = model.filter.sortKey != BreweryBeerList.SortOption.defaultKey
                        HStack(spacing: 5) {
                            Image(systemName: "arrow.up.arrow.down").font(.caption.weight(.semibold))
                            Text(model.activeSortName).lineLimit(1)
                            Image(systemName: "chevron.down").font(.caption2.weight(.bold))
                        }
                        .taproomChipLabel(on: nonDefault)
                    }
                    .accessibilityLabel("Sort beers, \(model.activeSortName)")
                    .accessibilityIdentifier("brewery.beers.sort")

                    if !model.availableStyles.isEmpty {
                        Menu {
                            Button {
                                Task { await model.setStyleId(nil) }
                            } label: {
                                if model.filter.styleId == nil {
                                    Label("All styles", systemImage: "checkmark")
                                } else {
                                    Text("All styles")
                                }
                            }
                            Divider()
                            ForEach(model.availableStyles) { style in
                                Button {
                                    Task { await model.setStyleId(style.id) }
                                } label: {
                                    let title = style.count > 0 ? "\(style.name) (\(style.count))" : style.name
                                    if model.filter.styleId == style.id {
                                        Label(title, systemImage: "checkmark")
                                    } else {
                                        Text(title)
                                    }
                                }
                            }
                        } label: {
                            HStack(spacing: 5) {
                                Text(model.activeStyleName ?? "Style").lineLimit(1)
                                Image(systemName: "chevron.down").font(.caption2.weight(.bold))
                            }
                            .taproomChipLabel(on: model.filter.styleId != nil)
                        }
                        .accessibilityLabel(model.activeStyleName.map { "Style, \($0)" } ?? "Filter by style")
                        .accessibilityIdentifier("brewery.beers.style")
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
                        .accessibilityIdentifier("brewery.beers.clearFiltersChip")
                    }
                }
            }
            .scrollClipDisabled()
            .sensoryFeedback(.selection, trigger: model.filter)
        }
        .padding(.bottom, 8)
    }

    @ViewBuilder private var beersContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            beersFilterBar
            if model.loadingBeers && model.beers.isEmpty {
                ProgressView().frame(maxWidth: .infinity).padding(.vertical, 24)
            } else if let e = model.beersError, model.beers.isEmpty {
                ErrorRow(message: e) {
                    Task { await model.load(force: true) }
                }
                .padding(.top, 12)
            } else if model.beers.isEmpty {
                if model.filter.isActive {
                    TaproomEmptyFilterView(clearButtonIdentifier: "brewery.beers.clearFilters") {
                        searchText = ""
                        Task { await model.resetFilters() }
                    }
                } else {
                    Text("No beers listed for this brewery.").font(.callout).foregroundStyle(Taproom.muted)
                }
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(model.beers) { b in
                        NavigationLink(value: BeerBreweryRoute.beer(b)) { BeerRow(beer: b) }
                            .buttonStyle(TaproomRowStyle())
                            .taproomRowDivider()
                    }
                }
                .opacity(model.loadingBeers ? 0.5 : 1)
                .animation(.easeInOut(duration: 0.15), value: model.loadingBeers)

                if model.loadingMoreBeers {
                    ProgressView().frame(maxWidth: .infinity).padding(.vertical, 16)
                } else if let e = model.beersError {
                    ErrorRow(message: e) {
                        Task { await model.loadMoreBeers() }
                    }
                    .padding(.top, 12)
                } else if model.hasMoreBeers {
                    let left = (model.totalBeers ?? 0) - model.beers.count
                    Button { Task { await model.loadMoreBeers() } } label: {
                        Text(left > 0 ? "Show \(left.formatted()) more" : "Show more").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(TaproomOutlineButton())
                    .padding(.top, 14)
                }
            }
        }
    }
}
