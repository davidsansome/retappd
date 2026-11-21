import XCTest
@testable import Retappd

@MainActor
final class BeerLabelTests: XCTestCase {
    private let beerSM = URL(string: "https://assets.untappd.com/site/beer_logos/beer-123_sm.jpeg")!
    private let beerHD = URL(string: "https://assets.untappd.com/site/beer_logos_hd/beer-123_hd.jpeg")!
    private let brewerySM = URL(string: "https://assets.untappd.com/site/brewery_logos/brewery-456_sm.jpeg")!
    private let breweryHD = URL(string: "https://assets.untappd.com/site/brewery_logos_hd/brewery-456_hd.jpeg")!
    private let beerDefault = URL(string: "https://assets.untappd.com/site/assets/images/temp/badge-beer-default.png")!
    private let breweryDefault = URL(string: "https://assets.untappd.com/site/assets/images/temp/badge-brewery-default.png")!

    func testBeerHDUsesBeerSMAsFallback() {
        let resolved = BeerLabel.resolve(beer: beerSM, beerHD: beerHD, brewery: brewerySM)
        XCTAssertEqual(resolved?.url, beerHD)
        XCTAssertEqual(resolved?.fallback, beerSM)
    }

    func testBeerWithoutHDHasNoFallback() {
        let resolved = BeerLabel.resolve(beer: beerSM, beerHD: nil, brewery: brewerySM)
        XCTAssertEqual(resolved?.url, beerSM)
        XCTAssertNil(resolved?.fallback)
    }

    func testIdenticalBeerHDAndSMHasNoFallback() {
        let resolved = BeerLabel.resolve(beer: beerSM, beerHD: beerSM, brewery: brewerySM)
        XCTAssertEqual(resolved?.url, beerSM)
        XCTAssertNil(resolved?.fallback)
    }

    func testPlaceholderBeerFallsBackToBrewery() {
        let resolved = BeerLabel.resolve(beer: beerDefault, beerHD: beerDefault, brewery: brewerySM, breweryHD: breweryHD)
        XCTAssertEqual(resolved?.url, breweryHD)
        XCTAssertEqual(resolved?.fallback, brewerySM)
    }

    func testAllPlaceholdersReturnsNil() {
        XCTAssertNil(BeerLabel.resolve(beer: beerDefault, beerHD: nil, brewery: breweryDefault))
        XCTAssertNil(BeerLabel.resolve(beer: nil, beerHD: nil, brewery: nil))
    }
}
