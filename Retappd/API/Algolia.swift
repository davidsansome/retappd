import Foundation

/// Untappd's public Algolia beer index. Fast, and outside Untappd's rate limits.
enum Algolia {
    static let appID = "9WBO4RQ3HO"
    static let apiKey = "1d347324d67ec472bb7132c66aead485"

    static func cacheKey(beerQuery q: String) -> String { "algolia beer \(LocalIndex.normalize(q))" }

    static func searchBeers(_ query: String, hits: Int = 30) async throws -> Data {
        var comps = URLComponents(string: "https://\(appID)-dsn.algolia.net/1/indexes/beer")!
        comps.queryItems = [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "hitsPerPage", value: "\(hits)"),
            URLQueryItem(name: "attributesToRetrieve",
                         value: "bid,beer_name,brewery_id,brewery_name,type_name,beer_abv,rating_score,rating_count,beer_label,brewery_label,popularity"),
            URLQueryItem(name: "attributesToHighlight", value: ""),
        ]
        var req = URLRequest(url: comps.url!)
        req.setValue(appID, forHTTPHeaderField: "X-Algolia-Application-Id")
        req.setValue(apiKey, forHTTPHeaderField: "X-Algolia-API-Key")
        let (data, resp) = try await UntappdAPI.shared.session.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw APIError.http(status) }
        return data
    }
}
