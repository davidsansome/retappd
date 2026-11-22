import Foundation
import Observation

enum TopListsTab: Hashable {
    case beers
    case breweries
    case trending
}

enum TrendingCategory: String, CaseIterable, Hashable, Identifiable {
    case craft
    case macro
    case venues

    var id: String { rawValue }

    var title: String {
        switch self {
        case .craft: "Craft"
        case .macro: "Macro"
        case .venues: "Venues"
        }
    }
}

struct TopBeersFilter: Equatable, Hashable {
    var style: TopListStyle? = nil
    var country: TopListCountry? = nil
    var inProduction: Bool = false
    var haventHad: Bool = false

    var isActive: Bool {
        style != nil || country != nil || inProduction || haventHad
    }

    var hasServerFilter: Bool {
        style != nil || country != nil || inProduction
    }
}

struct TopBreweriesFilter: Equatable, Hashable {
    var breweryType: TopListBreweryType? = nil
    var country: TopListCountry? = nil

    var isActive: Bool {
        breweryType != nil || country != nil
    }
}

struct RankedTopBeer: Identifiable, Hashable {
    let rank: Int
    let item: TopRatedBeerItem
    var id: Int { item.id }
}

@MainActor @Observable
final class GlobalTopListsModel {
    typealias BeersLoader = @MainActor (_ request: APIRequest, _ onCached: @escaping (TopRatedBeersResponse) -> Void) async throws -> TopRatedBeersResponse
    typealias BreweriesLoader = @MainActor (_ request: APIRequest, _ onCached: @escaping (TopRatedBreweriesResponse) -> Void) async throws -> TopRatedBreweriesResponse
    typealias TrendingBeersLoader = @MainActor (_ request: APIRequest, _ onCached: @escaping (TrendingBeersResponse) -> Void) async throws -> TrendingBeersResponse
    typealias TrendingVenuesLoader = @MainActor (_ request: APIRequest, _ onCached: @escaping (TrendingVenuesResponse) -> Void) async throws -> TrendingVenuesResponse
    typealias HasHadChecker = @MainActor (BeerLite) -> Bool

    var selectedTab: TopListsTab = .beers
    var trendingCategory: TrendingCategory = .craft

    // MARK: Beers state
    private(set) var beers: [TopRatedBeerItem] = []
    private(set) var styles: [TopListStyle] = []
    private(set) var countries: [TopListCountry] = []
    private(set) var beersFilter = TopBeersFilter()
    private(set) var isLoadingBeers = false
    private(set) var beersLoaded = false
    private(set) var beersError: String?

    // MARK: Breweries state
    private(set) var breweries: [TopRatedBrewery] = []
    private(set) var breweryTypes: [TopListBreweryType] = []
    private(set) var breweriesFilter = TopBreweriesFilter()
    private(set) var isLoadingBreweries = false
    private(set) var breweriesLoaded = false
    private(set) var breweriesError: String?

    // MARK: Trending state
    private(set) var trendingCraft: [TrendingBeerItem] = []
    private(set) var trendingMacro: [TrendingBeerItem] = []
    private(set) var isLoadingTrendingBeers = false
    private(set) var trendingBeersLoaded = false
    private(set) var trendingBeersError: String?

    private(set) var trendingVenues: [TrendingVenueItem] = []
    private(set) var isLoadingTrendingVenues = false
    private(set) var trendingVenuesLoaded = false
    private(set) var trendingVenuesError: String?

    @ObservationIgnored private let beersLoader: BeersLoader
    @ObservationIgnored private let breweriesLoader: BreweriesLoader
    @ObservationIgnored private let trendingBeersLoader: TrendingBeersLoader
    @ObservationIgnored private let trendingVenuesLoader: TrendingVenuesLoader
    @ObservationIgnored private let hasHad: HasHadChecker

    @ObservationIgnored private var beersGeneration = 0
    @ObservationIgnored private var breweriesGeneration = 0
    @ObservationIgnored private var trendingBeersGeneration = 0
    @ObservationIgnored private var trendingVenuesGeneration = 0

    init(
        beersLoader: @escaping BeersLoader = { req, onCached in
            try await cacheThenNetwork(req, as: TopRatedBeersResponse.self, onCached: onCached)
        },
        breweriesLoader: @escaping BreweriesLoader = { req, onCached in
            try await cacheThenNetwork(req, as: TopRatedBreweriesResponse.self, onCached: onCached)
        },
        trendingBeersLoader: @escaping TrendingBeersLoader = { req, onCached in
            try await cacheThenNetwork(req, as: TrendingBeersResponse.self, onCached: onCached)
        },
        trendingVenuesLoader: @escaping TrendingVenuesLoader = { req, onCached in
            try await cacheThenNetwork(req, as: TrendingVenuesResponse.self, onCached: onCached)
        },
        hasHad: @escaping HasHadChecker = { HadBeers.shared.has($0) }
    ) {
        self.beersLoader = beersLoader
        self.breweriesLoader = breweriesLoader
        self.trendingBeersLoader = trendingBeersLoader
        self.trendingVenuesLoader = trendingVenuesLoader
        self.hasHad = hasHad
    }

    // MARK: Derived

    /// Top beers with their original 1-based global rank, applying the local "Haven't had" filter.
    var visibleBeers: [RankedTopBeer] {
        beers.enumerated().compactMap { index, item in
            if beersFilter.haventHad && hasHad(item.beer) {
                return nil
            }
            return RankedTopBeer(rank: index + 1, item: item)
        }
    }

    var activeTrendingBeers: [TrendingBeerItem] {
        switch trendingCategory {
        case .craft: trendingCraft
        case .macro: trendingMacro
        case .venues: []
        }
    }

    // MARK: Loading

    func loadCurrentTab(force: Bool = false) async {
        switch selectedTab {
        case .beers:
            await loadBeers(force: force)
        case .breweries:
            await loadBreweries(force: force)
        case .trending:
            await loadTrending(force: force)
        }
    }

    func loadBeers(force: Bool = false) async {
        if !force && (beersLoaded || isLoadingBeers) { return }
        beersGeneration += 1
        let gen = beersGeneration
        let request = APIRequest.topRatedBeers(
            styleId: beersFilter.style?.id,
            countryId: beersFilter.country?.id,
            inProduction: beersFilter.inProduction,
            includeStyles: styles.isEmpty,
            includeCountries: countries.isEmpty
        )
        isLoadingBeers = true
        beersError = nil
        do {
            let response = try await beersLoader(request) { [weak self] cached in
                guard let self, self.beersGeneration == gen else { return }
                self.applyBeersResponse(cached)
            }
            guard beersGeneration == gen else { return }
            applyBeersResponse(response)
            beersLoaded = true
            isLoadingBeers = false
        } catch {
            guard beersGeneration == gen else { return }
            isLoadingBeers = false
            if !error.isCancellation { beersError = error.localizedDescription }
        }
    }

    func loadBreweries(force: Bool = false) async {
        if !force && (breweriesLoaded || isLoadingBreweries) { return }
        breweriesGeneration += 1
        let gen = breweriesGeneration
        let request = APIRequest.topRatedBreweries(
            countryId: breweriesFilter.country?.id,
            breweryTypeId: breweriesFilter.breweryType?.id,
            includeCountries: countries.isEmpty
        )
        isLoadingBreweries = true
        breweriesError = nil
        do {
            let response = try await breweriesLoader(request) { [weak self] cached in
                guard let self, self.breweriesGeneration == gen else { return }
                self.applyBreweriesResponse(cached)
            }
            guard breweriesGeneration == gen else { return }
            applyBreweriesResponse(response)
            breweriesLoaded = true
            isLoadingBreweries = false
        } catch {
            guard breweriesGeneration == gen else { return }
            isLoadingBreweries = false
            if !error.isCancellation { breweriesError = error.localizedDescription }
        }
    }

    func loadTrending(force: Bool = false) async {
        switch trendingCategory {
        case .craft, .macro:
            await loadTrendingBeers(force: force)
        case .venues:
            await loadTrendingVenues(force: force)
        }
    }

    private func loadTrendingBeers(force: Bool) async {
        if !force && (trendingBeersLoaded || isLoadingTrendingBeers) { return }
        trendingBeersGeneration += 1
        let gen = trendingBeersGeneration
        isLoadingTrendingBeers = true
        trendingBeersError = nil
        do {
            let response = try await trendingBeersLoader(.trendingBeersGlobal) { [weak self] cached in
                guard let self, self.trendingBeersGeneration == gen else { return }
                self.trendingCraft = Self.deduplicated(cached.micro)
                self.trendingMacro = Self.deduplicated(cached.macro)
            }
            guard trendingBeersGeneration == gen else { return }
            trendingCraft = Self.deduplicated(response.micro)
            trendingMacro = Self.deduplicated(response.macro)
            trendingBeersLoaded = true
            isLoadingTrendingBeers = false
        } catch {
            guard trendingBeersGeneration == gen else { return }
            isLoadingTrendingBeers = false
            if !error.isCancellation { trendingBeersError = error.localizedDescription }
        }
    }

    private func loadTrendingVenues(force: Bool) async {
        if !force && (trendingVenuesLoaded || isLoadingTrendingVenues) { return }
        trendingVenuesGeneration += 1
        let gen = trendingVenuesGeneration
        isLoadingTrendingVenues = true
        trendingVenuesError = nil
        do {
            let response = try await trendingVenuesLoader(.trendingVenuesGlobal) { [weak self] cached in
                guard let self, self.trendingVenuesGeneration == gen else { return }
                self.trendingVenues = Self.deduplicated(cached.items)
            }
            guard trendingVenuesGeneration == gen else { return }
            trendingVenues = Self.deduplicated(response.items)
            trendingVenuesLoaded = true
            isLoadingTrendingVenues = false
        } catch {
            guard trendingVenuesGeneration == gen else { return }
            isLoadingTrendingVenues = false
            if !error.isCancellation { trendingVenuesError = error.localizedDescription }
        }
    }

    // MARK: Beers Filters

    func setBeerStyle(_ style: TopListStyle?) async {
        guard beersFilter.style != style else { return }
        beersFilter.style = style
        await loadBeers(force: true)
    }

    func setBeerCountry(_ country: TopListCountry?) async {
        guard beersFilter.country != country else { return }
        beersFilter.country = country
        await loadBeers(force: true)
    }

    func toggleInProduction() async {
        beersFilter.inProduction.toggle()
        await loadBeers(force: true)
    }

    func toggleHaventHad() {
        beersFilter.haventHad.toggle()
    }

    func resetBeersFilters() async {
        guard beersFilter.isActive else { return }
        let needsReload = beersFilter.hasServerFilter
        beersFilter = TopBeersFilter()
        if needsReload {
            await loadBeers(force: true)
        }
    }

    // MARK: Breweries Filters

    func setBreweryType(_ type: TopListBreweryType?) async {
        guard breweriesFilter.breweryType != type else { return }
        breweriesFilter.breweryType = type
        await loadBreweries(force: true)
    }

    func setBreweryCountry(_ country: TopListCountry?) async {
        guard breweriesFilter.country != country else { return }
        breweriesFilter.country = country
        await loadBreweries(force: true)
    }

    func resetBreweriesFilters() async {
        guard breweriesFilter.isActive else { return }
        breweriesFilter = TopBreweriesFilter()
        await loadBreweries(force: true)
    }

    // MARK: Helpers

    private func applyBeersResponse(_ response: TopRatedBeersResponse) {
        beers = Self.deduplicated(response.beers)
        if !response.styles.isEmpty { styles = Self.deduplicated(response.styles) }
        if !response.countries.isEmpty { countries = Self.deduplicated(response.countries) }
    }

    private func applyBreweriesResponse(_ response: TopRatedBreweriesResponse) {
        breweries = Self.deduplicated(response.breweries)
        if !response.breweryTypes.isEmpty { breweryTypes = Self.deduplicated(response.breweryTypes) }
        if !response.countries.isEmpty { countries = Self.deduplicated(response.countries) }
    }

    private static func deduplicated<T: Identifiable>(_ items: [T]) -> [T] {
        var seen = Set<T.ID>()
        return items.filter { seen.insert($0.id).inserted }
    }
}
