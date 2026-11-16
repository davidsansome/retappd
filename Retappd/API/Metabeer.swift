import Foundation

/// Metabeer crawls beer shops, matches their listings to Untappd beers and tracks prices and stock.
/// Each market is its own site. Its JSON API (`/api/v1`, in the metabeer-v2 repository's
/// `web/__init__.py`) is public and takes Untappd beer IDs.
enum MetabeerMarket: String, CaseIterable, Identifiable, Sendable {
    case au, uk

    var id: String { rawValue }
    var name: String { self == .au ? "Australia" : "UK" }
    var site: URL { URL(string: self == .au ? "https://metabeer.com.au" : "https://metabeer.co.uk")! }

    /// The phone's region's market: the UK there, Australia everywhere else.
    static var local: MetabeerMarket { Locale.current.region?.identifier == "GB" ? .uk : .au }
}

/// UserDefaults keys for the shop price settings, read with `@AppStorage`.
enum MetabeerSettings {
    static let enabledKey = "metabeer.enabled"
    static let marketKey = "metabeer.market"
    /// Debug builds only: a server to use instead of the market's site, as a launch argument
    /// (`-metabeer.baseURL http://127.0.0.1:8000`).
    static let baseURLKey = "metabeer.baseURL"
}

/// `GET /api/v1/beers/{id}/offers`: every shop with a beer in stock. Money arrives as decimal
/// strings in `currency`. There's no shipping: people fill an order to make up for it, so shops
/// compare on the price of one can or bottle.
struct MetabeerOffers: Decodable, Sendable {
    var beerId: Int
    var market: String
    var currency: String
    /// The beer's page on Metabeer; nil when Metabeer has never seen the beer.
    var metabeerUrl: URL?
    /// Cheapest per can or bottle first.
    var offers: [MetabeerOffer]

    /// The cheapest single can or bottle.
    var cheapestEach: Decimal? { offers.map(\.unitPrice).min() }

    var shopCount: Int { Set(offers.map(\.shopSlug)).count }

    func money(_ amount: Decimal) -> String { amount.formatted(.currency(code: currency)) }
}

struct MetabeerOffer: Decodable, Identifiable, Sendable {
    var listingId: Int
    var shop: String
    var shopSlug: String
    var shopMetabeerUrl: URL
    var productUrl: URL
    /// The shop's own name for the product.
    var title: String
    var price: Decimal
    var packSize: Int
    var unitPrice: Decimal
    var volumeMl: Int?
    var container: String?
    var pricePerLitre: Decimal?

    var id: Int { listingId }

    enum CodingKeys: String, CodingKey {
        case listingId, shop, shopSlug, shopMetabeerUrl, productUrl, title, price, packSize, unitPrice,
             volumeMl, container, pricePerLitre
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        listingId = try c.decode(Int.self, forKey: .listingId)
        shop = try c.decode(String.self, forKey: .shop)
        shopSlug = try c.decode(String.self, forKey: .shopSlug)
        shopMetabeerUrl = try c.decode(URL.self, forKey: .shopMetabeerUrl)
        productUrl = try c.decode(URL.self, forKey: .productUrl)
        title = try c.decode(String.self, forKey: .title)
        price = try c.money(.price)
        packSize = try c.decode(Int.self, forKey: .packSize)
        unitPrice = try c.money(.unitPrice)
        volumeMl = try c.decodeIfPresent(Int.self, forKey: .volumeMl)
        container = try c.decodeIfPresent(String.self, forKey: .container)
        pricePerLitre = try c.moneyIfPresent(.pricePerLitre)
    }

    /// "4 × 375 ml cans", "500 ml bottle", "6-pack".
    var packDescription: String? {
        let size = volumeMl.map { "\($0) ml" }
        if packSize > 1 {
            let each = [size, container.map { "\($0)s" }].compactMap { $0 }.joined(separator: " ")
            return each.isEmpty ? "\(packSize)-pack" : "\(packSize) × \(each)"
        }
        let one = [size, container].compactMap { $0 }.joined(separator: " ")
        return one.isEmpty ? nil : one
    }
}

private extension KeyedDecodingContainer {
    /// Money is a decimal string ("12.00"), so it isn't rounded through a Double.
    func money(_ key: Key) throws -> Decimal {
        let s = try decode(String.self, forKey: key)
        guard let d = Decimal(string: s, locale: Locale(identifier: "en_US_POSIX")) else {
            throw DecodingError.dataCorruptedError(forKey: key, in: self, debugDescription: "not a decimal: \(s)")
        }
        return d
    }

    func moneyIfPresent(_ key: Key) throws -> Decimal? {
        try decodeNil(forKey: key) ? nil : money(key)
    }
}

/// Fetches from Metabeer, keeping answers for a few minutes so going back and forth between
/// screens doesn't ask again. Prices change at most a few times a day.
actor Metabeer {
    static let shared = Metabeer()

    private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 15
        c.httpAdditionalHeaders = ["User-Agent": "Retappd/\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1")"]
        return URLSession(configuration: c)
    }()
    private var cache: [URL: (at: Date, offers: MetabeerOffers)] = [:]
    private static let maxAge: TimeInterval = 10 * 60

    static func decode(_ data: Data) throws -> MetabeerOffers {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return try d.decode(MetabeerOffers.self, from: data)
    }

    func offers(beerID: Int, market: MetabeerMarket) async throws -> MetabeerOffers {
        let url = Self.base(market).appending(path: "api/v1/beers/\(beerID)/offers")
        if let hit = cache[url], Date().timeIntervalSince(hit.at) < Self.maxAge { return hit.offers }

        let (data, resp) = try await session.data(from: url)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw APIError.http(status) }
        let offers = try Self.decode(data)
        cache[url] = (Date(), offers)
        return offers
    }

    private static func base(_ market: MetabeerMarket) -> URL {
        #if DEBUG
        if let s = UserDefaults.standard.string(forKey: MetabeerSettings.baseURLKey), let url = URL(string: s) {
            return url
        }
        #endif
        return market.site
    }
}
