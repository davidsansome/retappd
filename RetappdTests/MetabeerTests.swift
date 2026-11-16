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
}
