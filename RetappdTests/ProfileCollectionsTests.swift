import XCTest
@testable import Retappd

final class ProfileCollectionsTests: XCTestCase {

    // MARK: - APIRequest builders

    func testUserBeersRequestParams() {
        let req = APIRequest.userBeers("alice", query: "ipa", sort: "highest_rated_you", offset: 25, timezoneOffset: "10")
        XCTAssertEqual(req.method, .get)
        XCTAssertEqual(req.path, "/v4/user/beers/alice")
        XCTAssertEqual(req.query["q"], "ipa")
        XCTAssertEqual(req.query["sort"], "highest_rated_you")
        XCTAssertEqual(req.query["offset"], "25")
        XCTAssertEqual(req.query["timezoneOffset"], "10")
        XCTAssertEqual(req.query["brewery_id"], "")
        XCTAssertEqual(req.query["type_id"], "")

        let firstPage = APIRequest.userBeers("alice", timezoneOffset: "10")
        XCTAssertNil(firstPage.query["offset"])
        XCTAssertEqual(firstPage.query["sort"], "date")
    }

    func testUserBadgesRequestParams() {
        let idx = APIRequest.userBadgesIndex("alice", limit: 3)
        XCTAssertEqual(idx.path, "/v4/user/badges/alice")
        XCTAssertEqual(idx.query["method"], "index")
        XCTAssertEqual(idx.query["mode"], "v2")
        XCTAssertEqual(idx.query["limit"], "3")

        let full = APIRequest.userBadges("alice", segment: .localBadges, sort: "badge_name", offset: 50, limit: 25)
        XCTAssertEqual(full.path, "/v4/user/badges/alice")
        XCTAssertEqual(full.query["method"], "full")
        XCTAssertEqual(full.query["mode"], "v2")
        XCTAssertEqual(full.query["segment"], "local_badges")
        XCTAssertEqual(full.query["sort"], "badge_name")
        XCTAssertEqual(full.query["offset"], "50")
        XCTAssertEqual(full.query["limit"], "25")
    }

    func testUserVenuesRequestParams() {
        let req = APIRequest.userVenues("alice", sort: "highest_checkin", verifiedOnly: true, offset: 25)
        XCTAssertEqual(req.path, "/v4/user/venues/alice")
        XCTAssertEqual(req.query["categories"], "1")
        XCTAssertEqual(req.query["sort"], "highest_checkin")
        XCTAssertEqual(req.query["verifiedVenueOnly"], "true")
        XCTAssertEqual(req.query["offset"], "25")

        let firstPage = APIRequest.userVenues("alice")
        XCTAssertNil(firstPage.query["offset"])
        XCTAssertEqual(firstPage.query["verifiedVenueOnly"], "false")
    }

    // MARK: - Decoding

    func testDecodeUserBeersPage() throws {
        let json = """
        {
          "meta": { "code": 200 },
          "response": {
            "total_count": 42,
            "sort_key": "date",
            "sort_name": "Date (New to Old)",
            "beers": {
              "count": 2,
              "items": [
                {
                  "first_checkin_id": 1001,
                  "first_created_at": "Sat, 04 Jul 2026 17:03:39 +1000",
                  "recent_checkin_id": 1005,
                  "recent_created_at": "Sun, 05 Jul 2026 12:00:00 +1000",
                  "rating_score": 4.5,
                  "user_auth_rating_score": 4.25,
                  "count": 3,
                  "beer": {
                    "bid": 555,
                    "beer_name": "Hoppy Trail",
                    "beer_label": "https://assets.untappd.com/beer555.jpg",
                    "beer_abv": 6.4,
                    "beer_style": "IPA - American",
                    "rating_score": 3.92,
                    "rating_count": 1200
                  },
                  "brewery": {
                    "brewery_id": 77,
                    "brewery_name": "Trail Brewing",
                    "brewery_label": "https://assets.untappd.com/brew77.jpg"
                  }
                },
                {
                  "first_checkin_id": 1002,
                  "rating_score": 0,
                  "count": 1,
                  "beer": {
                    "bid": 556,
                    "beer_name": "Unrated Lager",
                    "beer_abv": 4.8,
                    "beer_style": "Lager - Pale",
                    "rating_score": 0
                  },
                  "brewery": {
                    "brewery_id": 78,
                    "brewery_name": "Quiet Brewery"
                  }
                }
              ]
            },
            "sorting_options": [
              { "sort_key": "date", "sort_name": "Date (New to Old)" },
              { "sort_key": "highest_rated_you", "sort_name": "Highest Rated (You)" }
            ],
            "pagination": {
              "next_url": "https://api.untappd.com/v4/user/beers/alice?offset=25",
              "offset": 25,
              "max_id": false
            }
          }
        }
        """

        let page = try UntappdAPI.decode(UserBeersPage.self, from: Data(json.utf8))
        XCTAssertEqual(page.totalCount, 42)
        XCTAssertEqual(page.sortKey, "date")
        XCTAssertEqual(page.sortingOptions.count, 2)
        XCTAssertTrue(page.pagination.hasMore)
        XCTAssertEqual(page.pagination.nextOffset, 25)
        XCTAssertEqual(page.items.count, 2)

        let first = page.items[0]
        XCTAssertEqual(first.id, 555)
        XCTAssertEqual(first.beer.name, "Hoppy Trail")
        XCTAssertEqual(first.brewery?.name, "Trail Brewing")
        XCTAssertEqual(first.userRating, 4.5)
        XCTAssertEqual(first.authUserRating, 4.25)
        XCTAssertEqual(first.globalRating, 3.92)
        XCTAssertEqual(first.globalRatingCount, 1200)
        XCTAssertEqual(first.checkinCount, 3)
        XCTAssertNotNil(first.recentCreatedAt)
        XCTAssertEqual(first.beerLite.bid, 555)
        XCTAssertEqual(first.beerLite.rating, 3.92)
        XCTAssertEqual(first.beerLite.breweryId, 77)

        let second = page.items[1]
        XCTAssertNil(second.userRating)
        XCTAssertNil(second.globalRating)
        XCTAssertEqual(second.checkinCount, 1)
    }

    func testDecodeUserBadgesIndexAndFullPage() throws {
        let indexJSON = """
        {
          "meta": { "code": 200 },
          "response": {
            "stats": {
              "local_badges": { "total_user_count": 4 },
              "beer": { "total_count": 1000, "total_user_count": 120 },
              "venue": { "total_count": 500, "total_user_count": 30 },
              "special": { "total_count": 300, "total_user_count": 15 }
            },
            "method": "index",
            "beer": {
              "count": 1,
              "items": [
                {
                  "user_badge_id": 9001,
                  "badge_id": 1018,
                  "checkin_id": 5555,
                  "badge_name": "Hey Honey (Level 32)",
                  "badge_description": "Honey beer lover",
                  "media": {
                    "badge_image_sm": "https://assets.untappd.com/b_sm.png",
                    "badge_image_md": "https://assets.untappd.com/b_md.png",
                    "badge_image_lg": "https://assets.untappd.com/b_lg.png"
                  },
                  "earned_at": "Sat, 04 Jul 2026 17:03:39 +0000",
                  "is_level": true,
                  "has_badge": true,
                  "level_status": 32
                }
              ]
            }
          }
        }
        """

        let index = try UntappdAPI.decode(UserBadgesIndex.self, from: Data(indexJSON.utf8))
        XCTAssertEqual(index.totalEarned, 169)
        XCTAssertEqual(index.stats[.beer]?.userCount, 120)
        XCTAssertEqual(index.stats[.localBadges]?.userCount, 4)
        XCTAssertEqual(index.previews[.beer]?.count, 1)

        let badge = try XCTUnwrap(index.previews[.beer]?.first)
        XCTAssertEqual(badge.id, 9001)
        XCTAssertEqual(badge.badgeId, 1018)
        XCTAssertEqual(badge.baseName, "Hey Honey")
        XCTAssertEqual(badge.level, 32)
        XCTAssertTrue(badge.hasBadge)
        XCTAssertEqual(badge.image?.absoluteString, "https://assets.untappd.com/b_md.png")
        XCTAssertEqual(badge.largeImage?.absoluteString, "https://assets.untappd.com/b_lg.png")

        let asCheckin = badge.asCheckinBadge
        XCTAssertEqual(asCheckin.badgeId, 1018)
        XCTAssertEqual(asCheckin.userBadgeId, 9001)
        XCTAssertEqual(asCheckin.name, "Hey Honey (Level 32)")

        let fullJSON = """
        {
          "meta": { "code": 200 },
          "response": {
            "segment": "venue",
            "sort": "unlocked",
            "offset": 0,
            "limit": 25,
            "badges": {
              "count": 2,
              "items": [
                {
                  "user_badge_id": 9100,
                  "badge_id": 2368,
                  "badge_name": "Brew Traveler (Level 12)",
                  "media": { "badge_image_md": "https://assets.untappd.com/bt.png" },
                  "earned_at": "Sat, 04 Jul 2026 17:03:39 +0000",
                  "has_badge": true
                },
                {
                  "badge_id": 9999,
                  "badge_name": "Locked Badge",
                  "has_badge": false
                }
              ]
            },
            "sorting_options": [
              { "sort_key": "unlocked", "sort_name": "Unlocked (Recent)" },
              { "sort_key": "badge_name", "sort_name": "Badge Name (A-Z)" }
            ]
          }
        }
        """

        let full = try UntappdAPI.decode(UserBadgesPage.self, from: Data(fullJSON.utf8))
        XCTAssertEqual(full.segment, .venue)
        XCTAssertEqual(full.items.count, 2)
        XCTAssertEqual(full.items[0].level, 12) // parsed from name when level_status is absent
        XCTAssertFalse(full.items[1].hasBadge)
        XCTAssertEqual(full.items[1].id, 9999)
        XCTAssertEqual(full.sortingOptions.count, 2)
    }

    func testDecodeUserVenuesPage() throws {
        let json = """
        {
          "meta": { "code": 200 },
          "response": {
            "total_count": 15,
            "sort_key": "date",
            "sort_name": "Date (New to Old)",
            "venues": {
              "count": 1,
              "items": [
                {
                  "recent_visit": "Sat, 27 Jun 2026 10:51:00 +0000",
                  "first_visit": "Mon, 01 Jan 2024 10:00:00 +0000",
                  "recent_checkin_id": 8888,
                  "total_count": 7,
                  "venue": {
                    "venue_id": 17058,
                    "venue_name": "The Local Taphouse",
                    "primary_category": "Beer Bar",
                    "is_verified": 1,
                    "location": {
                      "venue_address": "184 Carlisle St",
                      "venue_city": "St Kilda East",
                      "venue_state": "VIC",
                      "lat": -37.868,
                      "lng": 144.992
                    },
                    "venue_icon": {
                      "md": "https://assets.untappd.com/v17058.png"
                    }
                  }
                }
              ]
            },
            "sorting_options": [
              { "sort_key": "date", "sort_name": "Date (New to Old)" },
              { "sort_key": "highest_checkin", "sort_name": "Check-ins (Most to Least)" }
            ],
            "pagination": {
              "next_url": "",
              "offset": 25
            }
          }
        }
        """

        let page = try UntappdAPI.decode(UserVenuesPage.self, from: Data(json.utf8))
        XCTAssertEqual(page.totalCount, 15)
        XCTAssertFalse(page.pagination.hasMore)
        XCTAssertEqual(page.sortingOptions.count, 2)
        XCTAssertEqual(page.items.count, 1)

        let item = page.items[0]
        XCTAssertEqual(item.venue.venueId, 17058)
        XCTAssertEqual(item.venue.name, "The Local Taphouse")
        XCTAssertTrue(item.venue.isVerified)
        XCTAssertEqual(item.visitCount, 7)
        XCTAssertNotNil(item.recentVisit)
    }

    // MARK: - ViewModel pagination & filtering

    @MainActor
    func testUserBeersModelPaginationSortAndSearch() async {
        final class Recorder: @unchecked Sendable {
            var calls: [(query: String, sort: String, offset: Int)] = []
        }
        let recorder = Recorder()

        let beer1 = makeBeerItem(bid: 1, name: "First IPA")
        let beer2 = makeBeerItem(bid: 2, name: "Second Stout")
        let beer3 = makeBeerItem(bid: 3, name: "Third Lager")

        let model = UserBeersModel(username: "alice") { _, query, sort, offset in
            recorder.calls.append((query, sort, offset))
            if offset == 0 {
                return UserBeersPage(
                    totalCount: 3,
                    items: [beer1, beer2],
                    pagination: CollectionPagination(nextURL: "https://api.untappd.com/next", nextOffset: 2)
                )
            } else {
                // Include duplicate beer2 to test deduplication across pages
                return UserBeersPage(
                    totalCount: 3,
                    items: [beer2, beer3],
                    pagination: CollectionPagination(nextURL: "", nextOffset: nil)
                )
            }
        }

        await model.load()
        XCTAssertEqual(model.items.map(\.id), [1, 2])
        XCTAssertEqual(model.totalCount, 3)
        XCTAssertTrue(model.hasMore)

        await model.loadMore()
        XCTAssertEqual(model.items.map(\.id), [1, 2, 3])
        XCTAssertFalse(model.hasMore)

        await model.selectSort("highest_rated_you")
        XCTAssertEqual(model.sortKey, "highest_rated_you")
        XCTAssertEqual(model.items.map(\.id), [1, 2])
        XCTAssertEqual(recorder.calls.last?.sort, "highest_rated_you")
        XCTAssertEqual(recorder.calls.last?.offset, 0)

        model.query = "  ipa  "
        await model.reload()
        XCTAssertEqual(recorder.calls.last?.query, "ipa")
    }

    @MainActor
    func testUserBadgesModelSegmentsAndPagination() async {
        let b1 = UserBadgeItem(userBadgeId: 10, badgeId: 1, name: "Badge One")
        let b2 = UserBadgeItem(userBadgeId: 11, badgeId: 2, name: "Badge Two")
        let fullPage = (0..<UserBadgesModel.pageSize).map { i in
            UserBadgeItem(userBadgeId: 100 + i, badgeId: 100 + i, name: "Beer Badge \(i)")
        }

        let model = UserBadgesModel(
            username: "alice",
            indexFetcher: { _ in
                UserBadgesIndex(stats: [
                    .beer: .init(userCount: 30, totalCount: 500),
                    .venue: .init(userCount: 5, totalCount: 100),
                ])
            },
            pageFetcher: { _, segment, _, offset, _ in
                if segment == .beer {
                    if offset == 0 {
                        return UserBadgesPage(segment: .beer, offset: 0, items: fullPage)
                    } else {
                        return UserBadgesPage(segment: .beer, offset: offset, items: [b1])
                    }
                } else {
                    return UserBadgesPage(segment: segment, offset: 0, items: [b2])
                }
            }
        )

        await model.load()
        XCTAssertEqual(model.totalEarned, 35)
        XCTAssertEqual(model.count(for: .beer), 30)
        XCTAssertEqual(model.items.count, UserBadgesModel.pageSize)
        XCTAssertTrue(model.hasMore)

        await model.loadMore()
        XCTAssertEqual(model.items.count, UserBadgesModel.pageSize + 1)
        XCTAssertFalse(model.hasMore)

        await model.selectSegment(.venue)
        XCTAssertEqual(model.segment, .venue)
        XCTAssertEqual(model.items.map(\.id), [11])
        XCTAssertFalse(model.hasMore)
    }

    @MainActor
    func testUserVenuesModelVerifiedToggleAndPagination() async {
        final class Recorder: @unchecked Sendable {
            var calls: [(sort: String, verifiedOnly: Bool, offset: Int)] = []
        }
        let recorder = Recorder()

        let v1 = UserVenueItem(venue: Venue(venueId: 1, name: "Pub One", isVerified: true), visitCount: 5)
        let v2 = UserVenueItem(venue: Venue(venueId: 2, name: "Pub Two", isVerified: false), visitCount: 2)

        let model = UserVenuesModel(username: "alice") { _, sort, verifiedOnly, offset in
            recorder.calls.append((sort, verifiedOnly, offset))
            if verifiedOnly {
                return UserVenuesPage(totalCount: 1, items: [v1], pagination: CollectionPagination(nextURL: ""))
            }
            if offset == 0 {
                return UserVenuesPage(
                    totalCount: 2,
                    items: [v1],
                    pagination: CollectionPagination(nextURL: "https://api.untappd.com/v?offset=1", nextOffset: 1)
                )
            }
            return UserVenuesPage(totalCount: 2, items: [v2], pagination: CollectionPagination(nextURL: ""))
        }

        await model.load()
        XCTAssertEqual(model.items.map(\.id), ["u1"])
        XCTAssertTrue(model.hasMore)

        await model.loadMore()
        XCTAssertEqual(model.items.map(\.id), ["u1", "u2"])
        XCTAssertFalse(model.hasMore)

        await model.toggleVerifiedOnly()
        XCTAssertTrue(model.verifiedOnly)
        XCTAssertEqual(model.items.map(\.id), ["u1"])
        XCTAssertEqual(recorder.calls.last?.verifiedOnly, true)
    }

    // MARK: - Helpers

    private func makeBeerItem(bid: Int, name: String) -> UserBeerItem {
        let json = """
        {
          "rating_score": 4.0,
          "count": 2,
          "beer": { "bid": \(bid), "beer_name": "\(name)", "rating_score": 3.8 }
        }
        """
        return try! JSONDecoder().decode(UserBeerItem.self, from: Data(json.utf8))
    }
}
