import XCTest
@testable import Retappd

final class MetabeerTests: XCTestCase {
    /// The shape of /api/v1/beers/{id}/offers, as metabeer-v2's tests/test_web.py checks it.
    private let json = """
    {"beer_id": 42, "market": "au", "currency": "AUD",
     "metabeer_url": "https://metabeer.com.au/beer/42",
     "offers": [
      {"listing_id": 1, "shop": "The Beer Barrel", "shop_slug": "the-beer-barrel",
       "shop_metabeer_url": "https://metabeer.com.au/retailer/the-beer-barrel", "product_url": "https://x/a",
       "title": "Range - Sticky Icky", "price": "12.30", "pack_size": 1, "unit_price": "12.30", "volume_ml": 500,
       "container": "can", "price_per_litre": "24.60"},
      {"listing_id": 2, "shop": "Kicks Brewing", "shop_slug": "kicks-brewing",
       "shop_metabeer_url": "https://metabeer.com.au/retailer/kicks-brewing", "product_url": "https://x/k",
       "title": "Sticky Icky 4pk", "price": "36.00", "pack_size": 4, "unit_price": "9.00", "volume_ml": null,
       "container": null, "price_per_litre": null}
     ]}
    """

    func testDecodesOffers() throws {
        let r = try Metabeer.decode(Data(json.utf8))
        XCTAssertEqual(r.beerId, 42)
        XCTAssertEqual(r.metabeerUrl?.absoluteString, "https://metabeer.com.au/beer/42")
        XCTAssertEqual(r.offers.count, 2)
        XCTAssertEqual(r.offers[0].price, Decimal(string: "12.30"))  // exact, not through a Double
        XCTAssertEqual(r.offers[1].unitPrice, 9)
        XCTAssertNil(r.offers[1].volumeMl)
        XCTAssertEqual(r.cheapestEach, 9)
        XCTAssertEqual(r.shopCount, 2)
    }

    func testUnknownBeerHasNoOffers() throws {
        let r = try Metabeer.decode(Data("""
        {"beer_id": 999, "market": "uk", "currency": "GBP", "metabeer_url": null, "offers": []}
        """.utf8))
        XCTAssertNil(r.metabeerUrl)
        XCTAssertNil(r.cheapestEach)
    }

    func testPackDescription() throws {
        let offers = try Metabeer.decode(Data(json.utf8)).offers
        XCTAssertEqual(offers[0].packDescription, "500 ml can")
        XCTAssertEqual(offers[1].packDescription, "4-pack")
    }

    func testSortedOffersCheapestEachFirst() throws {
        let r = try Metabeer.decode(Data(json.utf8))
        // Input has $12.30 before $9.00; sortedOffers puts $9.00 first.
        XCTAssertEqual(r.sortedOffers.map(\.listingId), [2, 1])
    }

    func testSingleShopMultiplePacksCount() throws {
        let multiPack = """
        {"beer_id": 2932404, "market": "au", "currency": "AUD",
         "metabeer_url": "https://metabeer.com.au/beer/2932404",
         "offers": [
          {"listing_id": 10, "shop": "Freestyle Brewing", "shop_slug": "freestyle-brewing",
           "shop_metabeer_url": "https://metabeer.com.au/retailer/freestyle-brewing", "product_url": "https://x/1",
           "title": "Double Dhuy", "price": "13.00", "pack_size": 1, "unit_price": "13.00", "volume_ml": 500,
           "container": null, "price_per_litre": "26.00"},
          {"listing_id": 11, "shop": "Freestyle Brewing", "shop_slug": "freestyle-brewing",
           "shop_metabeer_url": "https://metabeer.com.au/retailer/freestyle-brewing", "product_url": "https://x/8",
           "title": "Double Dhuy 8 Pack", "price": "94.00", "pack_size": 8, "unit_price": "11.75", "volume_ml": 500,
           "container": null, "price_per_litre": "23.50"}
         ]}
        """
        let r = try Metabeer.decode(Data(multiPack.utf8))
        XCTAssertEqual(r.shopCount, 1)
        XCTAssertEqual(r.cheapestEach, Decimal(string: "11.75"))
        XCTAssertEqual(r.sortedOffers.map(\.listingId), [11, 10])
        XCTAssertEqual(r.sortedOffers[0].packDescription, "8 × 500 ml")
        XCTAssertEqual(r.sortedOffers[1].packDescription, "500 ml")
    }

    func testURLIsHTTP() {
        XCTAssertTrue(URL(string: "https://metabeer.com.au/beer/42")!.isHTTP)
        XCTAssertTrue(URL(string: "http://example.com")!.isHTTP)
        XCTAssertFalse(URL(string: "javascript:alert(1)")!.isHTTP)
        XCTAssertFalse(URL(string: "file:///etc/passwd")!.isHTTP)
    }

    func testCacheHitExpiryAndForceRefresh() async throws {
        let clock = LockedBox(Date(timeIntervalSince1970: 1_000))
        let calls = LockedBox(0)
        let payload = Data(json.utf8)

        let client = Metabeer(
            fetch: { _ in
                calls.withValue { $0 += 1 }
                return (payload, 200)
            },
            now: { clock.value },
            maxAge: 60
        )

        _ = try await client.offers(beerID: 42, market: .au)
        _ = try await client.offers(beerID: 42, market: .au)
        XCTAssertEqual(calls.value, 1, "Second request within TTL should hit cache")

        // Force refresh bypasses cache.
        _ = try await client.offers(beerID: 42, market: .au, force: true)
        XCTAssertEqual(calls.value, 2)

        // Advance past TTL -> refetches.
        clock.withValue { $0 = $0.addingTimeInterval(61) }
        _ = try await client.offers(beerID: 42, market: .au)
        XCTAssertEqual(calls.value, 3)
    }

    func testMarketsUseSeparateHostsAndCacheEntries() async throws {
        let requestedURLs = LockedBox<[URL]>([])
        let payload = Data(json.utf8)

        let client = Metabeer(fetch: { url in
            requestedURLs.withValue { $0.append(url) }
            return (payload, 200)
        })

        _ = try await client.offers(beerID: 42, market: .au)
        _ = try await client.offers(beerID: 42, market: .uk)

        XCTAssertEqual(requestedURLs.value.count, 2)
        XCTAssertEqual(requestedURLs.value[0].host(), "metabeer.com.au")
        XCTAssertEqual(requestedURLs.value[1].host(), "metabeer.co.uk")
    }

    func testInFlightDeduplication() async throws {
        let calls = LockedBox(0)
        let payload = Data(json.utf8)

        let client = Metabeer(fetch: { _ in
            calls.withValue { $0 += 1 }
            try await Task.sleep(for: .milliseconds(80))
            return (payload, 200)
        })

        async let first = client.offers(beerID: 42, market: .au)
        async let second = client.offers(beerID: 42, market: .au)
        let (a, b) = try await (first, second)

        XCTAssertEqual(a.beerId, 42)
        XCTAssertEqual(b.beerId, 42)
        XCTAssertEqual(calls.value, 1, "Concurrent requests for the same beer and market should share one fetch")
    }

    func testCacheEvictsOldestWhenOverCap() async throws {
        let clock = LockedBox(Date(timeIntervalSince1970: 1_000))
        let calls = LockedBox(0)
        let payload = Data(json.utf8)

        let client = Metabeer(
            fetch: { _ in
                calls.withValue { $0 += 1 }
                return (payload, 200)
            },
            now: { clock.value },
            maxAge: 600,
            maxCacheEntries: 2
        )

        _ = try await client.offers(beerID: 1, market: .au)
        clock.withValue { $0 = $0.addingTimeInterval(1) }
        _ = try await client.offers(beerID: 2, market: .au)
        clock.withValue { $0 = $0.addingTimeInterval(1) }
        _ = try await client.offers(beerID: 3, market: .au)
        XCTAssertEqual(calls.value, 3)

        // Beer 2 and 3 should still be cached; beer 1 should have been evicted.
        _ = try await client.offers(beerID: 2, market: .au)
        _ = try await client.offers(beerID: 3, market: .au)
        XCTAssertEqual(calls.value, 3)

        _ = try await client.offers(beerID: 1, market: .au)
        XCTAssertEqual(calls.value, 4)
    }

    func testNon200ThrowsAndIsNotCached() async {
        let calls = LockedBox(0)
        let client = Metabeer(fetch: { _ in
            calls.withValue { $0 += 1 }
            return (Data(), 503)
        })

        do {
            _ = try await client.offers(beerID: 42, market: .au)
            XCTFail("Expected HTTP error")
        } catch let APIError.http(code) {
            XCTAssertEqual(code, 503)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        _ = try? await client.offers(beerID: 42, market: .au)
        XCTAssertEqual(calls.value, 2)
    }
}

private final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: T

    init(_ value: T) { storage = value }

    var value: T {
        lock.withLock { storage }
    }

    func withValue<R>(_ body: (inout T) -> R) -> R {
        lock.withLock { body(&storage) }
    }
}
