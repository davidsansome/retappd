import XCTest
@testable import Retappd

final class BeerNavigationTests: XCTestCase {
    private let sampleBeer = BeerLite(
        bid: 1001,
        name: "Hazy Pale",
        brewery: "Taproom Brewing",
        style: "Pale Ale",
        abv: 5.4
    )

    private let otherBeer = BeerLite(
        bid: 1002,
        name: "Dark Lager",
        brewery: "Taproom Brewing",
        style: "Schwarzbier",
        abv: 4.9
    )

    private let venueA = Venue(
        venueId: 2001,
        name: "The Local Tap",
        isVerified: true
    )

    private let venueB = Venue(
        venueId: 2002,
        name: "Corner Bar",
        isVerified: false
    )

    func testBeerRouteDefaultsVenueToNil() {
        let implicitNil = BeerBreweryRoute.beer(sampleBeer)
        let explicitNil = BeerBreweryRoute.beer(sampleBeer, venue: nil)

        XCTAssertEqual(implicitNil, explicitNil)
        if case .beer(let beer, let venue) = implicitNil {
            XCTAssertEqual(beer, sampleBeer)
            XCTAssertNil(venue)
        } else {
            XCTFail("Expected .beer route")
        }
    }

    func testBeerRouteCarriesVenueAndDistinguishesInHashableAndEquatable() {
        let withoutVenue = BeerBreweryRoute.beer(sampleBeer)
        let withVenueA = BeerBreweryRoute.beer(sampleBeer, venue: venueA)
        let withVenueADup = BeerBreweryRoute.beer(sampleBeer, venue: venueA)
        let withVenueB = BeerBreweryRoute.beer(sampleBeer, venue: venueB)
        let differentBeerSameVenue = BeerBreweryRoute.beer(otherBeer, venue: venueA)

        XCTAssertEqual(withVenueA, withVenueADup)
        XCTAssertEqual(withVenueA.hashValue, withVenueADup.hashValue)
        XCTAssertNotEqual(withoutVenue, withVenueA)
        XCTAssertNotEqual(withVenueA, withVenueB)
        XCTAssertNotEqual(withVenueA, differentBeerSameVenue)

        let uniqueRoutes: Set<BeerBreweryRoute> = [
            withoutVenue,
            withVenueA,
            withVenueADup,
            withVenueB,
            differentBeerSameVenue,
        ]
        XCTAssertEqual(uniqueRoutes.count, 4)

        if case .beer(let beer, let venue) = withVenueA {
            XCTAssertEqual(beer, sampleBeer)
            XCTAssertEqual(venue, venueA)
        } else {
            XCTFail("Expected .beer route with venue")
        }
    }

    @MainActor
    func testBeerViewStoresOptionalVenue() {
        let defaultView = BeerView(beer: sampleBeer)
        XCTAssertNil(defaultView.venue)

        let venueView = BeerView(beer: sampleBeer, venue: venueA)
        XCTAssertEqual(venueView.venue, venueA)
    }
}
