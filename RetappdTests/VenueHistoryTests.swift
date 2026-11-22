import CoreLocation
import XCTest
@testable import Retappd

@MainActor
final class VenueHistoryTests: XCTestCase {
    // Shaped like the sample for GET /v4/user/venues/{username} in docs/API.md.
    func testDecodesPage() throws {
        let d = Data("""
        {"meta":{"code":200},"response":{"total_count":1014,"is_search":false,"venues":{"count":1,"items":[{
          "recent_visit":"Sat, 27 Jun 2026 10:51:00 +0000","recent_checkin_id":1581209939,
          "first_visit":"Sat, 27 Jun 2026 10:51:00 +0000","first_checkin_id":1581209939,
          "gmt_offset":10,"total_count":3,
          "venue":{"venue_id":12,"venue_name":"The Parcel Yard","primary_category":"Pub",
            "location":{"venue_address":"King's Cross","venue_city":"London","lat":51.5318,"lng":-0.1243},
            "is_verified":1}
        }]},"pagination":{"offset":25,"max_id":false}}}
        """.utf8)
        let p = try UntappdAPI.decode(UserVenuesPage.self, from: d)
        XCTAssertEqual(p.totalCount, 1014)
        let item = try XCTUnwrap(p.items.first)
        XCTAssertEqual(item.venue.venueId, 12)
        XCTAssertEqual(item.venue.name, "The Parcel Yard")
        XCTAssertEqual(item.venue.lat ?? 0, 51.5318, accuracy: 0.0001)
        XCTAssertEqual(item.visitCount, 3)
        XCTAssertEqual(item.recentCheckinId, 1581209939)
        XCTAssertNotNil(item.recentVisit)
    }

    func testRequestMatchesCapturedQuery() {
        let r = APIRequest.userVenues("ann", offset: 50)
        XCTAssertEqual(r.path, "/v4/user/venues/ann")
        XCTAssertEqual(r.query, ["categories": "1", "sort": "date", "verifiedVenueOnly": "false", "offset": "50"])
        XCTAssertNil(APIRequest.userVenues("ann").query["offset"])
    }

    // MARK: Store

    private func tempURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString).json")
    }

    private func venue(_ id: Int, lat: Double = 51.5, lng: Double = -0.12, name: String? = nil) -> Venue {
        Venue(venueId: id, name: name ?? "Venue \(id)", lat: lat, lng: lng)
    }

    private func item(_ id: Int, checkin: Int, visits: Int = 1, lat: Double = 51.5, lng: Double = -0.12) -> UserVenueItem {
        UserVenueItem(venue: venue(id, lat: lat, lng: lng), visitCount: visits, recentCheckinId: checkin)
    }

    /// Serves `pages` by offset and counts the requests.
    final class FakeServer: @unchecked Sendable {
        var pages: [[UserVenueItem]]
        var requests: [Int] = []
        var failAtOffset: Int?
        init(_ pages: [[UserVenueItem]]) { self.pages = pages }
        var total: Int { pages.map(\.count).reduce(0, +) }
        func page(at offset: Int) throws -> UserVenuesPage {
            requests.append(offset)
            if offset == failAtOffset { throw URLError(.timedOut) }
            var start = 0
            for p in pages {
                if start == offset { return UserVenuesPage(totalCount: total, items: p) }
                start += p.count
            }
            return UserVenuesPage(totalCount: total, items: [])
        }
    }

    private func store(_ server: FakeServer, url: URL, user: @escaping () -> String? = { "ann" }) -> VenueHistory {
        VenueHistory(url: url, currentUser: user,
                     fetchPage: { _, offset in try server.page(at: offset) },
                     pause: {}, index: LocalIndex(url: tempURL("index")))
    }

    func testFirstSyncReadsEveryPage() async {
        let server = FakeServer([[item(1, checkin: 100), item(2, checkin: 99)], [item(3, checkin: 98)]])
        let h = store(server, url: tempURL("vh"))
        await h.refresh()
        XCTAssertEqual(server.requests, [0, 2])
        XCTAssertEqual(Set(h.entries.keys), [1, 2, 3])
        XCTAssertTrue(h.isComplete)
    }

    func testLaterSyncStopsAtFirstUnchangedVenue() async {
        let server = FakeServer([[item(1, checkin: 100), item(2, checkin: 99)], [item(3, checkin: 98)]])
        let h = store(server, url: tempURL("vh"))
        await h.refresh()
        // A new check-in at venue 4, then venue 1 again further down the list.
        server.pages = [[item(4, checkin: 102), item(1, checkin: 101, visits: 2)], [item(2, checkin: 99), item(3, checkin: 98)]]
        server.requests = []
        await h.refresh(force: true)
        XCTAssertEqual(server.requests, [0, 2])  // stops on venue 2, unchanged
        XCTAssertEqual(Set(h.entries.keys), [1, 2, 3, 4])
        XCTAssertEqual(h.entries[1]?.visits, 2)
    }

    func testFailedFirstSyncKeepsWhatItReadAndRetries() async {
        let server = FakeServer([[item(1, checkin: 100)], [item(2, checkin: 99)]])
        server.failAtOffset = 1
        let h = store(server, url: tempURL("vh"))
        await h.refresh()
        XCTAssertEqual(Set(h.entries.keys), [1])
        XCTAssertFalse(h.isComplete)
        server.failAtOffset = nil
        await h.refresh()  // not throttled: the last sync didn't finish
        XCTAssertEqual(Set(h.entries.keys), [1, 2])
        XCTAssertTrue(h.isComplete)
    }

    func testRecentSyncIsThrottled() async {
        let server = FakeServer([[item(1, checkin: 100)]])
        let h = store(server, url: tempURL("vh"))
        await h.refresh()
        server.requests = []
        await h.refresh()
        XCTAssertEqual(server.requests, [])
    }

    func testPersistsPerUser() async {
        let url = tempURL("vh")
        let server = FakeServer([[item(1, checkin: 100)]])
        await store(server, url: url).refresh()
        XCTAssertEqual(Set(store(server, url: url).entries.keys), [1])
        XCTAssertTrue(store(server, url: url, user: { "bob" }).entries.isEmpty)
    }

    func testClearForgetsEverything() async {
        let url = tempURL("vh")
        let server = FakeServer([[item(1, checkin: 100)]])
        let h = store(server, url: url)
        await h.refresh()
        h.clear()
        XCTAssertTrue(h.entries.isEmpty)
        XCTAssertFalse(h.isComplete)
        XCTAssertTrue(store(server, url: url).entries.isEmpty)
    }

    func testRecordAddsAVisit() async {
        let server = FakeServer([[item(1, checkin: 100)]])
        let h = store(server, url: tempURL("vh"))
        await h.refresh()
        h.record(Venue(venueId: 1, foursquareId: "fsq1", name: "Venue 1"), checkinId: 200)
        h.record(venue(5), checkinId: 201)
        h.record(Venue.atHome, checkinId: 202)
        XCTAssertEqual(h.entries[1]?.visits, 2)
        XCTAssertEqual(h.entries[1]?.venue.foursquareId, "fsq1")
        XCTAssertEqual(h.entries[1]?.venue.lat, 51.5)  // kept from the sync
        XCTAssertEqual(h.entries[5]?.visits, 1)
        XCTAssertNil(h.entries[Venue.atHome.venueId!])
    }

    func testNearbyIsNearestFirstThenMostVisited() async {
        // Each 0.001° of latitude is about 111 m.
        let server = FakeServer([[
            item(1, checkin: 105, visits: 1, lat: 51.5000, lng: 0),   // here
            item(2, checkin: 104, visits: 9, lat: 51.5002, lng: 0),   // ~22 m: about as close, more visits
            item(3, checkin: 103, visits: 50, lat: 51.5050, lng: 0),  // ~556 m
            item(4, checkin: 102, visits: 1, lat: 51.5300, lng: 0),   // ~3.3 km: too far
        ]])
        let h = store(server, url: tempURL("vh"))
        await h.refresh()
        let here = CLLocation(latitude: 51.5, longitude: 0)
        XCTAssertEqual(h.nearby(here).compactMap(\.venueId), [2, 1, 3])
        XCTAssertEqual(h.nearby(here, limit: 1).compactMap(\.venueId), [2])
    }

    func testFillsFoursquareIdFromLocalIndex() async {
        let index = LocalIndex(url: tempURL("index"))
        await index.add(venues: [Venue(venueId: 1, foursquareId: "fsq1", name: "Venue 1")])
        let server = FakeServer([[item(1, checkin: 100)]])
        let h = VenueHistory(url: tempURL("vh"), currentUser: { "ann" },
                             fetchPage: { _, offset in try server.page(at: offset) }, pause: {}, index: index)
        await h.refresh()
        XCTAssertEqual(h.entries[1]?.venue.foursquareId, "fsq1")
    }
}
