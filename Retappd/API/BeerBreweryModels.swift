import Foundation

/// `/v4/beer/info/{bid}`: one beer in full. The docs in untappd-private-api show only some of
/// its 43 keys; the rest here (`has_had`, the brewery's `location`) are read defensively and may
/// be missing. `stats.user_count` is taken to be the signed-in user's own checkins of the beer,
/// as in the public API.
struct BeerInfo: Decodable {
    var bid: Int
    var name: String
    var label: URL?
    var labelHD: URL?
    var style: String?
    var abv: Double?
    var ibu: Int?
    var description: String?
    var rating: Double?
    var ratingCount: Int?
    var brewery: BreweryRef?
    var breweryType: String?
    var city: String?
    var state: String?
    var stats: Stats?
    /// The signed-in user's own rating (`auth_rating`), nil if they haven't rated it.
    var yourRating: Double?
    var hasHad: Bool
    var isInWishlist: Bool?
    var isInProduction: Bool?

    struct Stats: Hashable {
        var total: Int?
        var thisMonth: Int?
        var people: Int?
        var yours: Int?
    }

    var lite: BeerLite {
        BeerLite(bid: bid, name: name, brewery: brewery?.name ?? "", style: style, abv: abv,
                 label: label, rating: (rating ?? 0) > 0 ? rating : nil, ratingCount: ratingCount, hasHad: hasHad,
                 breweryLabel: brewery?.label, breweryId: brewery.flatMap { $0.id > 0 ? $0.id : nil })
    }

    init(from decoder: Decoder) throws {
        let root = try decoder.container(keyedBy: AnyKey.self)
        guard let c = root.nested("beer"), let bid = c.int("bid") else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "no beer"))
        }
        self.bid = bid
        name = c.string("beer_name") ?? ""
        label = c.text("beer_label").flatMap(URL.init(string:))
        labelHD = c.text("beer_label_hd").flatMap(URL.init(string:))
        style = c.text("beer_style")
        abv = c.double("beer_abv")
        ibu = c.int("beer_ibu")
        description = c.text("beer_description")
        rating = c.double("rating_score")
        ratingCount = c.int("rating_count")
        brewery = c.obj("brewery")
        breweryType = c.nested("brewery")?.text("brewery_type")
        let loc = c.nested("brewery")?.nested("location")
        city = loc?.text("brewery_city")
        state = loc?.text("brewery_state")
        stats = c.nested("stats").map {
            Stats(total: $0.int("total_count"), thisMonth: $0.int("monthly_count"),
                  people: $0.int("total_user_count"), yours: $0.int("user_count"))
        }
        yourRating = c.double("auth_rating").flatMap { $0 > 0 ? $0 : nil }
        hasHad = c.bool("has_had") ?? ((stats?.yours ?? 0) > 0 || yourRating != nil)
        isInWishlist = c.bool("wish_list")
        isInProduction = c.bool("is_in_production")
    }
}

/// `/v4/brewery/info/{id}`. Only some of the brewery's 26 keys are shown in the docs; these are
/// the ones its OpenAPI schema lists.
struct BreweryInfo: Decodable {
    var id: Int
    var name: String
    var label: URL?
    var labelHD: URL?
    var country: String?
    var type: String?
    var address: String?
    var city: String?
    var state: String?
    var description: String?
    var rating: Double?
    var ratingCount: Int?
    var beerCount: Int?
    var website: URL?
    var twitter: URL?
    var facebook: URL?
    var instagram: URL?
    var stats: Stats?
    /// The user's average rating across this brewery's beers (`user_average_rating`).
    var yourAverage: Double?

    struct Stats: Hashable {
        var total: Int?
        var people: Int?
        var thisMonth: Int?
        var yours: Int?
    }

    /// "Sydney, NSW, Australia", without empty parts.
    var locality: String {
        [city, state, country].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
    }

    init(from decoder: Decoder) throws {
        let root = try decoder.container(keyedBy: AnyKey.self)
        guard let c = root.nested("brewery"), let id = c.int("brewery_id") else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "no brewery"))
        }
        self.id = id
        name = c.string("brewery_name") ?? ""
        label = c.text("brewery_label").flatMap(URL.init(string:))
        labelHD = c.text("brewery_label_hd").flatMap(URL.init(string:))
        country = c.text("country_name")
        type = c.text("brewery_type")
        let loc = c.nested("location")
        address = loc?.text("brewery_address")
        city = loc?.text("brewery_city")
        state = loc?.text("brewery_state")
        description = c.text("brewery_description")
        let r = c.nested("rating")
        rating = r?.double("rating_score").flatMap { $0 > 0 ? $0 : nil }
        ratingCount = r?.int("count")
        beerCount = c.int("beer_count")
        let contact = c.nested("contact")
        website = contact?.text("url").flatMap(VenueInfo.websiteURL)
        twitter = Self.social(contact?.text("twitter"), host: "x.com")
        facebook = Self.social(contact?.text("facebook"), host: "facebook.com")
        instagram = Self.social(contact?.text("instagram"), host: "instagram.com")
        stats = c.nested("stats").map {
            Stats(total: $0.int("total_count"), people: $0.int("unique_count"),
                  thisMonth: $0.int("monthly_count"), yours: $0.int("user_count"))
        }
        yourAverage = c.double("user_average_rating").flatMap { $0 > 0 ? $0 : nil }
    }

    /// A social account as a link. Handles arrive bare ("BathtubBrewingAU"); anything that
    /// already looks like a URL is kept. What the app sends in these fields hasn't been checked
    /// beyond the docs' examples.
    static func social(_ value: String?, host: String) -> URL? {
        guard var v = value?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty else { return nil }
        if v.lowercased().hasPrefix("http") { return URL(string: v) }
        if v.hasPrefix("@") { v.removeFirst() }
        if v.contains("/") || v.lowercased().contains(host) { return URL(string: "https://\(v)") }
        return URL(string: "https://\(host)/\(v)")
    }
}

/// `/v4/brewery/beer_list/{id}`: a brewery's beers, in the order asked for (most popular first).
/// The docs' sample has the first 25 of `total_count` 46; whether more come by `offset` isn't
/// captured, so the page copes with a server that ignores it.
struct BreweryBeerList: Decodable {
    var beers: [BeerLite]
    var total: Int?

    private struct Item: Decodable {
        var beer: BeerLite?
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: AnyKey.self)
            guard let b: BeerRef = c.obj("beer"), b.bid != 0 else { beer = nil; return }
            var lite = BeerLite(beer: b, brewery: c.obj("brewery"))
            let n = c.nested("beer")
            lite.rating = n?.double("rating_score").flatMap { $0 > 0 ? $0 : nil }
            lite.ratingCount = n?.int("rating_count")
            lite.hasHad = c.bool("has_had") ?? b.hasHad
            beer = lite
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        beers = c.items("beers", Item.self).compactMap(\.beer)
        total = c.int("total_count_filtered") ?? c.int("total_count")
    }
}
