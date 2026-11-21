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

    /// Enabled by default in markets Metabeer tracks (Australia and the UK), off elsewhere.
    static var defaultEnabled: Bool {
        let region = Locale.current.region?.identifier
        return region == "AU" || region == "GB"
    }

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? defaultEnabled
    }

    static var market: MetabeerMarket {
        UserDefaults.standard.string(forKey: marketKey).flatMap(MetabeerMarket.init(rawValue:)) ?? .local
    }
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
    /// In-stock offers from Metabeer.
    var offers: [MetabeerOffer]

    /// Offers sorted cheapest per can or bottle first, with deterministic tie-breakers.
    var sortedOffers: [MetabeerOffer] {
        offers.sorted { a, b in
            if a.unitPrice != b.unitPrice { return a.unitPrice < b.unitPrice }
            if a.price != b.price { return a.price < b.price }
            let shopOrder = a.shop.localizedCaseInsensitiveCompare(b.shop)
            if shopOrder != .orderedSame { return shopOrder == .orderedAscending }
            return a.listingId < b.listingId
        }
    }

    /// The cheapest single can or bottle.
    var cheapestEach: Decimal? { offers.map(\.unitPrice).min() }

    var shopCount: Int { Set(offers.map(\.shopSlug)).count }

    func money(_ amount: Decimal) -> String { amount.formatted(.currency(code: currency)) }
}

extension URL {
    var isHTTP: Bool {
        guard let scheme = scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }
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

    typealias Fetcher = @Sendable (URL) async throws -> (Data, Int)

    private struct InFlight {
        let id: UUID
        let task: Task<MetabeerOffers, Error>
    }

    private let fetcher: Fetcher
    private let now: @Sendable () -> Date
    private let maxAge: TimeInterval
    private let maxCacheEntries: Int
    private var cache: [URL: (at: Date, offers: MetabeerOffers)] = [:]
    private var inFlight: [URL: InFlight] = [:]

    init(fetch: Fetcher? = nil,
         now: @escaping @Sendable () -> Date = { Date() },
         maxAge: TimeInterval = 10 * 60,
         maxCacheEntries: Int = 200) {
        if let fetch {
            self.fetcher = fetch
        } else {
            let c = URLSessionConfiguration.ephemeral
            c.timeoutIntervalForRequest = 15
            c.httpAdditionalHeaders = ["User-Agent": "Retappd/\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1")"]
            let session = URLSession(configuration: c)
            self.fetcher = { url in
                let (data, resp) = try await session.data(from: url)
                let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
                return (data, status)
            }
        }
        self.now = now
        self.maxAge = maxAge
        self.maxCacheEntries = maxCacheEntries
    }

    static func decode(_ data: Data) throws -> MetabeerOffers {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return try d.decode(MetabeerOffers.self, from: data)
    }

    func offers(beerID: Int, market: MetabeerMarket, force: Bool = false) async throws -> MetabeerOffers {
        let url = Self.base(market).appending(path: "api/v1/beers/\(beerID)/offers")
        let current = now()
        if !force, let hit = cache[url], current.timeIntervalSince(hit.at) < maxAge {
            return hit.offers
        }
        if !force, let running = inFlight[url] {
            return try await running.task.value
        }

        let id = UUID()
        let fetch = fetcher
        let task = Task<MetabeerOffers, Error> {
            let (data, status) = try await fetch(url)
            guard status == 200 else { throw APIError.http(status) }
            return try Self.decode(data)
        }
        inFlight[url] = InFlight(id: id, task: task)

        do {
            let offers = try await task.value
            if inFlight[url]?.id == id { inFlight[url] = nil }
            store(offers, for: url, at: now())
            return offers
        } catch {
            if inFlight[url]?.id == id { inFlight[url] = nil }
            throw error
        }
    }

    func clearCache() {
        cache.removeAll()
    }

    private func store(_ offers: MetabeerOffers, for url: URL, at timestamp: Date) {
        // Evict expired entries first, then oldest entries if still over the cap.
        cache = cache.filter { timestamp.timeIntervalSince($0.value.at) < maxAge }
        cache[url] = (timestamp, offers)
        if cache.count > maxCacheEntries {
            let excess = cache.count - maxCacheEntries
            let oldest = cache.sorted { $0.value.at < $1.value.at }.prefix(excess)
            for (key, _) in oldest { cache.removeValue(forKey: key) }
        }
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
