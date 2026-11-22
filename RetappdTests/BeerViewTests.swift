import XCTest
import SwiftUI
@testable import Retappd

final class BeerViewTests: XCTestCase {
    @MainActor
    func testBreweryLinkTapTargetIsAtLeast44ptAndFillsColumn() {
        // Hero left column on a 375pt screen: 375 - 32 (margins) - 14 (spacing) - 96 (label) = 233pt.
        let columnWidth: CGFloat = 233
        var labelSize: CGSize = .zero
        var layoutSize: CGSize = .zero

        let view = NavigationStack {
            NavigationLink(value: BeerBreweryRoute.brewery(id: 1, name: "Moo")) {
                TaproomLinkLabel("Moo", font: .subheadline, chevronSize: 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(GeometryReader { g in
                        Color.clear.onAppear { labelSize = g.size }
                    })
            }
            .buttonStyle(TaproomLinkStyle(extend: BeerView.breweryTapExtend))
            .background(GeometryReader { g in
                Color.clear.onAppear { layoutSize = g.size }
            })
            .frame(width: columnWidth, alignment: .leading)
        }

        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 375, height: 200))
        let host = UIHostingController(rootView: view)
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        let hitTargetHeight = labelSize.height + 2 * BeerView.breweryTapExtend
        XCTAssertGreaterThanOrEqual(hitTargetHeight, 44, "Brewery link hit target height should be >= 44pt, got \(hitTargetHeight)")
        XCTAssertEqual(labelSize.width, columnWidth, accuracy: 0.5, "Brewery link should span the full hero column width")
        XCTAssertEqual(layoutSize.height, labelSize.height, accuracy: 0.5, "Extended hit target should not inflate visual layout height")
    }

    func testBeerInfoDecodesFriendsRatings() throws {
        let json = """
        {"meta":{"code":200},"response":{"beer":{
          "bid": 5826548, "beer_name": "American Amber", "rating_score": 3.72, "rating_count": 120,
          "friends_ratings": {"rating_score": 3.505, "rating_count": 11}
        }}}
        """
        let info = try UntappdAPI.decode(BeerInfo.self, from: Data(json.utf8))
        XCTAssertEqual(info.friendsRating ?? 0, 3.505, accuracy: 0.0001)
        XCTAssertEqual(info.friendsRatingCount, 11)

        let zeroJson = """
        {"meta":{"code":200},"response":{"beer":{
          "bid": 5826548, "beer_name": "American Amber",
          "friends_ratings": {"rating_score": 0, "rating_count": 0}
        }}}
        """
        let zeroInfo = try UntappdAPI.decode(BeerInfo.self, from: Data(zeroJson.utf8))
        XCTAssertNil(zeroInfo.friendsRating)
        XCTAssertEqual(zeroInfo.friendsRatingCount, 0)

        let missingJson = """
        {"meta":{"code":200},"response":{"beer":{"bid": 5826548, "beer_name": "American Amber"}}}
        """
        let missingInfo = try UntappdAPI.decode(BeerInfo.self, from: Data(missingJson.utf8))
        XCTAssertNil(missingInfo.friendsRating)
        XCTAssertNil(missingInfo.friendsRatingCount)
    }

    func testCheckinPageDecodesAggregateRating() throws {
        let json = """
        {"meta":{"code":200},"response":{
          "rating": {"rating_score": 3.85, "rating_count": 4},
          "mode": "friends",
          "checkins": {"count": 1, "items": [{"checkin_id": 100, "rating_score": 4.0, "venue": []}]}
        }}
        """
        let page = try UntappdAPI.decode(CheckinPage.self, from: Data(json.utf8))
        XCTAssertEqual(page.ratingScore ?? 0, 3.85, accuracy: 0.0001)
        XCTAssertEqual(page.ratingCount, 4)
        XCTAssertEqual(page.checkins.map(\.id), [100])

        let zeroJson = """
        {"meta":{"code":200},"response":{
          "rating": {"rating_score": 0, "rating_count": 0},
          "checkins": {"count": 0, "items": []}
        }}
        """
        let zeroPage = try UntappdAPI.decode(CheckinPage.self, from: Data(zeroJson.utf8))
        XCTAssertNil(zeroPage.ratingScore)
        XCTAssertEqual(zeroPage.ratingCount, 0)
    }

    func testBeerCheckinSourceRequests() {
        let allReq = CheckinListModel.Source.beer(42, friendsOnly: false).request(maxId: 99)
        XCTAssertEqual(allReq.path, "/v4/beer/checkins/42")
        XCTAssertNil(allReq.query["type"])
        XCTAssertEqual(allReq.query["max_id"], "99")

        let friendsReq = CheckinListModel.Source.beer(42, friendsOnly: true).request(maxId: 99)
        XCTAssertEqual(friendsReq.path, "/v4/beer/checkins/42")
        XCTAssertEqual(friendsReq.query["type"], "friends")
        XCTAssertEqual(friendsReq.query["max_id"], "99")
    }

    @MainActor
    func testBeerModelFriendRatingsAndFeedSwitching() async throws {
        let friendsPageJSON = """
        {"meta":{"code":200},"response":{
          "rating": {"rating_score": 4.15, "rating_count": 1},
          "checkins": {"count": 1, "items": [{"checkin_id": 501, "rating_score": 4.15, "venue": []}]}
        }}
        """
        let friendsPage = try UntappdAPI.decode(CheckinPage.self, from: Data(friendsPageJSON.utf8))
        let allPageJSON = """
        {"meta":{"code":200},"response":{
          "checkins": {"count": 1, "items": [{"checkin_id": 901, "rating_score": 3.5, "venue": []}]}
        }}
        """
        let allPage = try UntappdAPI.decode(CheckinPage.self, from: Data(allPageJSON.utf8))

        var allRefreshes = 0
        var friendsRefreshes = 0
        let allList = CheckinListModel(
            source: .beer(42, friendsOnly: false),
            fetchFirstPage: { _ in allRefreshes += 1; return allPage }
        )
        let friendsList = CheckinListModel(
            source: .beer(42, friendsOnly: true),
            fetchFirstPage: { _ in friendsRefreshes += 1; return friendsPage }
        )

        let model = BeerModel(
            beer: BeerLite(bid: 42, name: "Amber", brewery: "Brew Co"),
            checkins: allList,
            friendsCheckins: friendsList
        )

        XCTAssertEqual(model.checkinScope, .all)
        XCTAssertTrue(model.activeCheckins === allList)
        XCTAssertNil(model.friendsRating)
        XCTAssertNil(model.friendsRatingCaption)

        // Refreshing while on All with no loaded friend checkins only refreshes All.
        await model.refreshCheckins()
        XCTAssertEqual(allRefreshes, 1)
        XCTAssertEqual(friendsRefreshes, 0)

        // Switch to Friends and load: falls back to friendsCheckins aggregate rating.
        model.checkinScope = .friends
        XCTAssertTrue(model.activeCheckins === friendsList)
        await model.activeCheckins.loadIfNeeded()
        XCTAssertEqual(friendsRefreshes, 1)
        XCTAssertEqual(model.friendsRating ?? 0, 4.15, accuracy: 0.0001)
        XCTAssertEqual(model.friendsRatingCount, 1)
        XCTAssertEqual(model.friendsRatingCaption, "1 rating")

        // Refreshing while on Friends refreshes both All and Friends.
        await model.refreshCheckins()
        XCTAssertEqual(allRefreshes, 2)
        XCTAssertEqual(friendsRefreshes, 2)

        // Applying BeerInfo with friends_ratings takes precedence and pluralizes caption.
        let infoJSON = """
        {"meta":{"code":200},"response":{"beer":{
          "bid": 42, "beer_name": "Amber",
          "friends_ratings": {"rating_score": 3.92, "rating_count": 7}
        }}}
        """
        let info = try UntappdAPI.decode(BeerInfo.self, from: Data(infoJSON.utf8))
        model.applyInfo(info)
        XCTAssertEqual(model.friendsRating ?? 0, 3.92, accuracy: 0.0001)
        XCTAssertEqual(model.friendsRatingCount, 7)
        XCTAssertEqual(model.friendsRatingCaption, "7 ratings")
    }
}
