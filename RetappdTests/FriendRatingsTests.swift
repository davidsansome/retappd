import XCTest
@testable import Retappd

@MainActor
final class FriendRatingsTests: XCTestCase {
    private let beer = BeerLite(bid: 42, name: "Pacific Ale", brewery: "Stone & Wood")

    /// Untappd's date format for a day in November 2026, with the right weekday.
    private static func date(day: Int) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return f.string(from: Date(timeIntervalSince1970: 1_793_491_200 + Double(day - 1) * 86_400))
    }

    private func checkinJSON(id: Int, uid: Int, rating: Double = 0, day: Int, venue: String? = nil) -> String {
        let venueJSON = venue.map {
            #"{"venue_id": \#(id), "venue_name": "\#($0)", "location": {"venue_city": "Melbourne"}}"#
        } ?? "[]"
        return """
        {"checkin_id": \(id), "rating_score": \(rating),
         "created_at": "\(Self.date(day: day))",
         "user": {"uid": \(uid), "user_name": "user\(uid)", "first_name": "User", "last_name": "\(uid)"},
         "beer": {"bid": 42, "beer_name": "Pacific Ale"},
         "venue": \(venueJSON)}
        """
    }

    private func page(_ checkins: [String], maxId: Int?, score: Double? = nil, count: Int? = nil) throws -> CheckinPage {
        let pagination = maxId.map { #""pagination": {"max_id": \#($0)},"# } ?? ""
        let rating = score.map { #""rating": {"rating_score": \#($0), "rating_count": \#(count ?? 0)},"# } ?? ""
        let json = """
        {"meta":{"code":200},"response":{\(pagination)\(rating)
          "checkins": {"count": \(checkins.count), "items": [\(checkins.joined(separator: ","))]}}}
        """
        return try UntappdAPI.decode(CheckinPage.self, from: Data(json.utf8))
    }

    func testGroupsByFriendNewestFirstAndAveragesRatings() throws {
        let p = try page([
            checkinJSON(id: 5, uid: 1, rating: 4, day: 20, venue: "The Local"),
            checkinJSON(id: 4, uid: 2, rating: 3.5, day: 18),
            checkinJSON(id: 3, uid: 1, rating: 3, day: 10, venue: "Melbourne Taphouse"),
            checkinJSON(id: 2, uid: 1, day: 5),
            checkinJSON(id: 1, uid: 3, day: 1),
        ], maxId: nil)
        let friends = FriendRatingsModel.group(p.checkins)
        XCTAssertEqual(friends.map(\.id), [1, 2, 3])
        XCTAssertEqual(friends[0].checkins.map(\.id), [5, 3, 2])
        XCTAssertEqual(friends[0].rating ?? 0, 3.5, accuracy: 0.0001, "Unrated check-ins don't count towards the average")
        XCTAssertEqual(friends[0].ratedCount, 2)
        XCTAssertEqual(friends[1].rating ?? 0, 3.5, accuracy: 0.0001)
        XCTAssertNil(friends[2].rating)
        XCTAssertEqual(friends[0].checkins.first?.venue?.city, "Melbourne")
    }

    func testLeavesOutTheSignedInUser() throws {
        let p = try page([checkinJSON(id: 2, uid: 9, rating: 4, day: 2), checkinJSON(id: 1, uid: 1, rating: 3, day: 1)], maxId: nil)
        XCTAssertEqual(FriendRatingsModel.group(p.checkins, excluding: 9).map(\.id), [1])
    }

    func testLoadsEveryPage() async throws {
        let pages: [Int?: CheckinPage] = [
            nil: try page([checkinJSON(id: 30, uid: 1, rating: 4, day: 20), checkinJSON(id: 20, uid: 2, rating: 3, day: 15)],
                          maxId: 20, score: 3.6, count: 3),
            20: try page([checkinJSON(id: 10, uid: 1, rating: 3, day: 3)], maxId: 10),
            10: try page([], maxId: nil),
        ]
        var asked: [Int?] = []
        let model = FriendRatingsModel(beer: beer) { maxId, _ in
            asked.append(maxId)
            return pages[maxId]!
        }
        await model.load()
        XCTAssertEqual(asked, [nil, 20, 10])
        XCTAssertEqual(model.friends.map(\.id), [1, 2])
        XCTAssertEqual(model.friends[0].checkins.map(\.id), [30, 10])
        XCTAssertEqual(model.ratingScore ?? 0, 3.6, accuracy: 0.0001)
        XCTAssertEqual(model.ratingCount, 3)
        XCTAssertTrue(model.loaded)
        XCTAssertFalse(model.isLoading)
        XCTAssertFalse(model.truncated)
        XCTAssertNil(model.error)
    }

    func testStopsAfterMaxPages() async throws {
        var calls = 0
        let model = FriendRatingsModel(beer: beer) { maxId, _ in
            calls += 1
            let id = maxId ?? 10_000
            return try self.page([self.checkinJSON(id: id, uid: id, rating: 3, day: 1)], maxId: id - 1)
        }
        await model.load()
        XCTAssertEqual(calls, FriendRatingsModel.maxPages)
        XCTAssertTrue(model.truncated)
        XCTAssertEqual(model.friends.count, FriendRatingsModel.maxPages)
    }

    func testShowsAnErrorWhenTheFirstPageFails() async {
        struct Boom: LocalizedError { var errorDescription: String? { "Boom" } }
        let model = FriendRatingsModel(beer: beer) { _, _ in throw Boom() }
        await model.load()
        XCTAssertEqual(model.error, "Boom")
        XCTAssertTrue(model.friends.isEmpty)
        XCTAssertTrue(model.loaded)
    }
}
