import CoreLocation
import XCTest
@testable import Retappd

final class ShopPlaceTests: XCTestCase {
    func testRequestOmitsLocationWhenNoPlace() {
        for place in [nil, "", "   ", "\n"] as [String?] {
            let r = APIRequest.retailVenuesAround(lat: -33.86785, lng: 151.20732, location: place)
            XCTAssertNil(r.query["location"], "place \(String(describing: place))")
            XCTAssertEqual(r.query["lat"], "-33.867850")
            XCTAssertEqual(r.query["lng"], "151.207320")
        }
        XCTAssertNil(APIRequest.retailVenuesAround(lat: 1, lng: 2).query["location"])
    }

    func testRequestSendsTrimmedLocationAlongsideQuery() {
        let r = APIRequest.retailVenuesAround(lat: -33.86785, lng: 151.20732, query: "bottle", location: "  Melbourne  ")
        XCTAssertEqual(r.path, "/v4/venue/aroundretail")
        XCTAssertEqual(r.query["location"], "Melbourne")
        XCTAssertEqual(r.query["q"], "bottle")
        XCTAssertEqual(r.query["dist_pref"], "m")
    }

    func testLocationIsPartOfTheCacheKey() {
        let here = APIRequest.retailVenuesAround(lat: 1, lng: 2)
        let melbourne = APIRequest.retailVenuesAround(lat: 1, lng: 2, location: "Melbourne")
        XCTAssertNotEqual(here.cacheKey, melbourne.cacheKey)
    }

    func testNormalizedCollapsesWhitespace() {
        XCTAssertEqual(ShopPlace.normalized(" New   York\t"), "New York")
        XCTAssertEqual(ShopPlace.normalized("Tokyo"), "Tokyo")
        XCTAssertNil(ShopPlace.normalized(""))
        XCTAssertNil(ShopPlace.normalized(" \n "))
        XCTAssertNil(ShopPlace.normalized(nil))
    }

    func testCoordinatePrefersDevice() {
        let device = CLLocationCoordinate2D(latitude: -33.9, longitude: 151.2)
        let c = ShopPlace.coordinate(device: device, place: "Melbourne")
        XCTAssertEqual(c?.lat, -33.9)
        XCTAssertEqual(c?.lng, 151.2)
        XCTAssertEqual(ShopPlace.coordinate(device: device, place: nil)?.lat, -33.9)
    }

    func testCoordinateWithoutDeviceNeedsAPlace() {
        XCTAssertNil(ShopPlace.coordinate(device: nil, place: nil))
        let c = ShopPlace.coordinate(device: nil, place: "Tokyo")
        XCTAssertEqual(c?.lat, ShopPlace.placeholderCoordinate.lat)
        // The server treats 0,0 as missing, so the placeholder mustn't be it.
        XCTAssertNotEqual(c?.lat, 0)
        XCTAssertNotEqual(c?.lng, 0)
    }

    // Shaped like a real response (trimmed) from GET /v4/venue/aroundretail?location=Melbourne.
    func testDecodesGeocodedPlace() throws {
        let json = """
        {"meta":{"code":200},"response":{"auth":false,
         "location":{"lat":-33.86785,"lng":151.20732,"geocode":[{"time_taken":0.003,"cached":true,"provider":"google",
           "metadata":{"formatted_address":"Melbourne VIC, Australia","place_id":"x"},"lat":-37.8136276,"lon":144.9630576,"lng":144.9630576}]},
         "algolia":{"aroundLatLng":"-37.8136276,144.9630576","aroundRadius":250},
         "recent":{"count":0,"items":[]},"foursquare":{"count":0,"items":[]}}}
        """
        let r = try UntappdAPI.decode(VenueAround.self, from: Data(json.utf8))
        XCTAssertEqual(r.placeFound, true)
        XCTAssertEqual(r.placeName, "Melbourne VIC, Australia")
    }

    func testDecodesUnknownPlace() throws {
        let json = """
        {"meta":{"code":200},"response":{"auth":false,
         "location":{"lat":-33.86785,"lng":151.20732,"geocode":[]},
         "algolia":{"aroundLatLngViaIP":true,"aroundRadius":1000},
         "recent":{"count":0,"items":[]},"foursquare":{"count":0,"items":[]}}}
        """
        let r = try UntappdAPI.decode(VenueAround.self, from: Data(json.utf8))
        XCTAssertEqual(r.placeFound, false)
        XCTAssertNil(r.placeName)
    }

    func testNoGeocodeWithoutLocation() throws {
        let json = """
        {"meta":{"code":200},"response":{"auth":false,"location":{"lat":-33.86785,"lng":151.20732},
         "recent":{"count":0,"items":[]},"foursquare":{"count":0,"items":[]}}}
        """
        let r = try UntappdAPI.decode(VenueAround.self, from: Data(json.utf8))
        XCTAssertNil(r.placeFound)
        XCTAssertNil(r.placeName)
    }

    func testSortedByDistanceOrdersNearestFirstWithUnknownLast() {
        let venues = [
            Venue(foursquareId: "a", name: "Bottle Shop", category: "Liquor Store", reportedDistance: 21),
            Venue(foursquareId: "b", name: "No Distance"),
            Venue(foursquareId: "c", name: "Supermarket", category: "Supermarket", reportedDistance: 56),
            Venue(foursquareId: "d", name: "Corner Cafe", category: "Café", reportedDistance: 8),
            Venue(foursquareId: "e", name: "Bookshop", category: "Bookstore", reportedDistance: 18),
            Venue(foursquareId: "f", name: "Arcade", category: "Shopping", reportedDistance: 25),
            Venue(foursquareId: "g", name: "Second Unknown"),
        ]
        let sorted = ShopPlace.sortedByDistance(venues)
        XCTAssertEqual(sorted.map(\.foursquareId), ["d", "e", "a", "f", "c", "b", "g"])
    }

    func testSortedByDistanceUsesOriginWhenGiven() {
        let origin = CLLocation(latitude: -37.8136, longitude: 144.9631)
        let farByCoord = Venue(foursquareId: "far", name: "Far", lat: -37.8236, lng: 144.9631, reportedDistance: 5)
        let nearByCoord = Venue(foursquareId: "near", name: "Near", lat: -37.8137, lng: 144.9631, reportedDistance: 900)
        let serverOnly = Venue(foursquareId: "server", name: "Server", reportedDistance: 50)
        let sorted = ShopPlace.sortedByDistance([farByCoord, serverOnly, nearByCoord], from: origin)
        XCTAssertEqual(sorted.map(\.foursquareId), ["near", "server", "far"])
    }
}
