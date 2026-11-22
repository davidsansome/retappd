import Foundation

// MARK: - Filter Options

/// A beer style returned by `GET /v4/beer/top_rated?styles=true`.
struct TopListStyle: Decodable, Hashable, Identifiable {
    var id: Int
    var name: String
    var slug: String?

    init(id: Int, name: String, slug: String? = nil) {
        self.id = id
        self.name = name
        self.slug = slug
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        guard let id = c.int("type_id"), let name = c.text("type_name") else {
            throw APIError.decoding
        }
        self.id = id
        self.name = name
        self.slug = c.text("type_name_slug")
    }
}

/// A country returned by `GET /v4/beer/top_rated?countries=true` or `GET /v4/brewery/top_rated?countries=true`.
struct TopListCountry: Decodable, Hashable, Identifiable {
    var id: Int
    var name: String
    var slug: String?

    init(id: Int, name: String, slug: String? = nil) {
        self.id = id
        self.name = name
        self.slug = slug
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        guard let id = c.int("country_id"), let name = c.text("country_name") else {
            throw APIError.decoding
        }
        self.id = id
        self.name = name
        self.slug = c.text("country_name_slug")
    }
}

/// A brewery type returned by `GET /v4/brewery/top_rated`.
/// Note: `brewery_type` query param requires numeric `id` (not `slug`).
struct TopListBreweryType: Decodable, Hashable, Identifiable {
    var id: Int
    var name: String
    var slug: String?

    init(id: Int, name: String, slug: String? = nil) {
        self.id = id
        self.name = name
        self.slug = slug
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        guard let id = c.int("brewery_type_id"),
              let name = c.text("brewery_type_name_plain") ?? c.text("brewery_type_name") else {
            throw APIError.decoding
        }
        self.id = id
        self.name = name
        self.slug = c.text("brewery_type_slug")
    }
}

// MARK: - Top Rated Beers

/// `GET /v4/beer/top_rated`
struct TopRatedBeersResponse: Decodable {
    var beers: [TopRatedBeerItem]
    var styles: [TopListStyle]
    var countries: [TopListCountry]

    init(beers: [TopRatedBeerItem] = [], styles: [TopListStyle] = [], countries: [TopListCountry] = []) {
        self.beers = beers
        self.styles = styles
        self.countries = countries
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        beers = c.items("beers")
        styles = c.items("styles")
        countries = c.items("countries")
    }
}

struct TopRatedBeerItem: Decodable, Hashable, Identifiable {
    var beer: BeerLite
    var hasHad: Bool
    var isInProduction: Bool?

    var id: Int { beer.bid }

    init(beer: BeerLite, hasHad: Bool = false, isInProduction: Bool? = nil) {
        self.beer = beer
        self.hasHad = hasHad
        self.isInProduction = isInProduction
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        guard let b = c.obj("beer", BeerRef.self), b.bid > 0 else {
            throw APIError.decoding
        }
        let beerNode = c.nested("beer")
        let brewery = c.obj("brewery", BreweryRef.self)
        let had = c.bool("has_had") ?? b.hasHad ?? false
        var lite = BeerLite(beer: b, brewery: brewery)
        lite.rating = beerNode?.double("rating_score").flatMap { $0 > 0 ? $0 : nil }
        lite.ratingCount = beerNode?.int("rating_count")
        lite.hasHad = had
        self.beer = lite
        self.hasHad = had
        self.isInProduction = beerNode?.bool("is_in_production")
    }
}

// MARK: - Top Rated Breweries

/// `GET /v4/brewery/top_rated`
struct TopRatedBreweriesResponse: Decodable {
    var breweries: [TopRatedBrewery]
    var breweryTypes: [TopListBreweryType]
    var countries: [TopListCountry]

    init(
        breweries: [TopRatedBrewery] = [],
        breweryTypes: [TopListBreweryType] = [],
        countries: [TopListCountry] = []
    ) {
        self.breweries = breweries
        self.breweryTypes = breweryTypes
        self.countries = countries
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        breweries = c.items("breweries")
        breweryTypes = c.items("brewery_types")
        countries = c.items("countries")
    }
}

struct TopRatedBrewery: Decodable, Hashable, Identifiable {
    var id: Int
    var name: String
    var type: String?
    var label: URL?
    var country: String?
    var city: String?
    var state: String?
    var rating: Double?
    var ratingCount: Int?
    var beerCount: Int?

    var locality: String {
        [city, state, country].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
    }

    var subtitle: String {
        let beersText = beerCount.flatMap { $0 > 0 ? "\($0.formatted()) \($0 == 1 ? "beer" : "beers")" : nil }
        return [type, locality.isEmpty ? nil : locality, beersText]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    init(
        id: Int,
        name: String,
        type: String? = nil,
        label: URL? = nil,
        country: String? = nil,
        city: String? = nil,
        state: String? = nil,
        rating: Double? = nil,
        ratingCount: Int? = nil,
        beerCount: Int? = nil
    ) {
        self.id = id
        self.name = name
        self.type = type
        self.label = label
        self.country = country
        self.city = city
        self.state = state
        self.rating = rating
        self.ratingCount = ratingCount
        self.beerCount = beerCount
    }

    init(from decoder: Decoder) throws {
        let root = try decoder.container(keyedBy: AnyKey.self)
        let c = root.nested("brewery") ?? root
        guard let id = c.int("brewery_id"), id > 0 else {
            throw APIError.decoding
        }
        self.id = id
        self.name = c.text("brewery_name") ?? ""
        self.type = c.text("brewery_type")
        self.label = c.url("brewery_label")
        self.country = c.text("country_name")
        let loc = c.nested("location")
        self.city = loc?.text("brewery_city")
        self.state = loc?.text("brewery_state")
        self.rating = c.double("rating_score").flatMap { $0 > 0 ? $0 : nil }
        self.ratingCount = c.int("rating_count")
        self.beerCount = c.int("beer_count")
    }
}

// MARK: - Trending Beers

/// `GET /v4/beer/trending` (global when `type=local` is omitted).
struct TrendingBeersResponse: Decodable {
    var micro: [TrendingBeerItem]
    var macro: [TrendingBeerItem]

    init(micro: [TrendingBeerItem] = [], macro: [TrendingBeerItem] = []) {
        self.micro = micro
        self.macro = macro
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        micro = c.items("micro")
        macro = c.items("macro")
    }
}

struct TrendingBeerItem: Decodable, Hashable, Identifiable {
    var beer: BeerLite
    var totalCount: Int
    var yourCount: Int

    var id: Int { beer.bid }

    init(beer: BeerLite, totalCount: Int, yourCount: Int = 0) {
        self.beer = beer
        self.totalCount = totalCount
        self.yourCount = yourCount
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        guard let b = c.obj("beer", BeerRef.self), b.bid > 0 else {
            throw APIError.decoding
        }
        let beerNode = c.nested("beer")
        let brewery = c.obj("brewery", BreweryRef.self)
        var lite = BeerLite(beer: b, brewery: brewery)
        lite.rating = beerNode?.double("rating_score").flatMap { $0 > 0 ? $0 : nil }
        lite.ratingCount = beerNode?.int("rating_count")
        let yourCount = c.int("your_count") ?? 0
        if lite.hasHad == nil && yourCount > 0 { lite.hasHad = true }
        self.beer = lite
        self.totalCount = c.int("total_count") ?? 0
        self.yourCount = yourCount
    }
}

// MARK: - Trending Venues

/// `GET /v4/venue/trending?type=global`
struct TrendingVenuesResponse: Decodable {
    var items: [TrendingVenueItem]

    init(items: [TrendingVenueItem] = []) {
        self.items = items
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        let direct: [TrendingVenueItem] = c.list("items")
        items = direct.isEmpty ? c.items("venues") : direct
    }
}

struct TrendingVenueItem: Decodable, Hashable, Identifiable {
    var venue: Venue
    var totalUsers: Int
    var yourCount: Int

    var id: String { venue.id }

    init(venue: Venue, totalUsers: Int, yourCount: Int = 0) {
        self.venue = venue
        self.totalUsers = totalUsers
        self.yourCount = yourCount
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        guard let venue = c.obj("venue", Venue.self) else {
            throw APIError.decoding
        }
        self.venue = venue
        self.totalUsers = c.int("total_users") ?? 0
        self.yourCount = c.int("your_count") ?? 0
    }
}
