import XCTest
@testable import Retappd

final class DecodingTests: XCTestCase {
    func testStockLabelsCountAsMissing() {
        let stock = URL(string: "https://assets.untappd.com/site/assets/images/temp/badge-beer-default.png")!
        let brewery = URL(string: "https://assets.untappd.com/site/assets/images/temp/badge-brewery-default.png")!
        let real = URL(string: "https://assets.untappd.com/site/beer_logos/beer-8676_379f5_sm.jpeg")!
        XCTAssertTrue(BeerLabel.isPlaceholder(stock))
        XCTAssertTrue(BeerLabel.isPlaceholder(brewery))
        XCTAssertFalse(BeerLabel.isPlaceholder(real))
    }

    func testBeerLiteKeepsBreweryLogo() throws {
        let json = """
        {"bid": 5, "beer_name": "Amber", "beer_label": "https://x/badge-beer-default.png"}
        """
        let beer = try JSONDecoder().decode(BeerRef.self, from: Data(json.utf8))
        let brewery = try JSONDecoder().decode(BreweryRef.self, from: Data("""
        {"brewery_id": 9, "brewery_name": "Brew Co", "brewery_label": "https://x/brewery-9.jpeg"}
        """.utf8))
        XCTAssertEqual(BeerLite(beer: beer, brewery: brewery).breweryLabel?.lastPathComponent, "brewery-9.jpeg")
    }

    func testCheckinWithEmptyVenueAndExtras() throws {
        let json = """
        {"meta":{"code":200},"response":{"checkins":{"count":1,"items":[{
          "checkin_id": 1583373288, "created_at": "Sun, 05 Jul 2026 08:19:11 +0000",
          "rating_score": 3.8, "checkin_comment": "",
          "user": {"uid": 1, "user_name": "a", "first_name": "Ann", "last_name": "B", "relationship": "friends"},
          "beer": {"bid": 5, "beer_name": "Amber", "beer_abv": 5.5, "beer_label": "https://x/y.jpg"},
          "brewery": {"brewery_id": 9, "brewery_name": "Brew Co"},
          "venue": [],
          "toasts": {"total_count": 2, "count": 1, "auth_toast": true, "items": [{"user": {"uid": 2, "user_name": "t"}}]},
          "media": {"count": 1, "items": [{"photo_id": 1, "photo": {"photo_img_md": "https://x/p.jpg"}}]},
          "friend_tags": {"count": 1, "items": [{"user": {"uid": 3, "user_name": "f"}}]}
        }]},"pagination":{"max_id": 1583369796}}}
        """
        let page = try UntappdAPI.decode(CheckinPage.self, from: Data(json.utf8))
        XCTAssertEqual(page.nextMaxId, 1583369796)
        let c = try XCTUnwrap(page.checkins.first)
        XCTAssertNil(c.venue)
        XCTAssertNil(c.comment)
        XCTAssertEqual(c.rating, 3.8)
        XCTAssertEqual(c.user?.displayName, "Ann B")
        XCTAssertEqual(c.beer?.abv, 5.5)
        XCTAssertEqual(c.toastCount, 2)
        XCTAssertTrue(c.youToasted)
        XCTAssertEqual(c.toasters.map(\.userName), ["t"])
        XCTAssertEqual(c.taggedFriends.map(\.userName), ["f"])
        XCTAssertEqual(c.photo?.medium?.absoluteString, "https://x/p.jpg")
        XCTAssertNotNil(c.createdAt)
    }

    func testCheckinRetailVenue() throws {
        let json = """
        {"meta":{"code":200},"response":{"checkins":{"count":3,"items":[
          {"checkin_id": 1, "venue": [], "retail_venue": {"venue_id": 6154402, "venue_name": "Beer Barrel",
           "primary_category": "Retail", "foursquare": {"foursquare_id": "58fd2d34d7627e28e69cec9d"}}},
          {"checkin_id": 2, "venue": [], "retail_venue": []},
          {"checkin_id": 3, "venue": []}
        ]}}}
        """
        let c = try UntappdAPI.decode(CheckinPage.self, from: Data(json.utf8)).checkins
        XCTAssertEqual(c[0].retailVenue?.name, "Beer Barrel")
        XCTAssertEqual(c[0].retailVenue?.foursquareId, "58fd2d34d7627e28e69cec9d")
        XCTAssertTrue(c[0].retailVenueKnown)
        XCTAssertNil(c[1].retailVenue)
        XCTAssertTrue(c[1].retailVenueKnown)
        XCTAssertNil(c[2].retailVenue)
        XCTAssertFalse(c[2].retailVenueKnown)
    }

    /// Untappd removes a checkin's shop when an edit leaves `purchase_foursquare_id` out.
    func testEditCheckinAlwaysSendsShop() throws {
        let json = """
        {"meta":{"code":200},"response":{"checkins":{"count":1,"items":[{"checkin_id": 7, "venue": []}]}}}
        """
        let c = try XCTUnwrap(UntappdAPI.decode(CheckinPage.self, from: Data(json.utf8)).checkins.first)
        let keep = APIRequest.editCheckin(c, rating: 3, shout: "", containerId: nil, purchaseFoursquareId: "abc")
        XCTAssertEqual(keep.form?["purchase_foursquare_id"], "abc")
        let clear = APIRequest.editCheckin(c, rating: 3, shout: "", containerId: nil, purchaseFoursquareId: nil)
        XCTAssertEqual(clear.form?["purchase_foursquare_id"], "")
        let add = APIRequest.checkin(beer: 1, foursquareId: nil, lat: nil, lng: nil, rating: 0, shout: "",
                                     purchaseFoursquareId: "abc")
        XCTAssertEqual(add.form?["purchase_foursquare_id"], "abc")
        XCTAssertNil(add.form?["foursquare_id"])
    }

    func testVenueAroundAndRoundTrip() throws {
        let json = """
        {"meta":{"code":200},"response":{"location":{"lat":-33.86,"lng":151.2},
         "recent":{"count":1,"items":[{"venue_id":107565,"venue_name":"Hotel","is_custom_venue":false,"distance":0.339,
           "is_verified":true,"foursquare":{"foursquare_id":"abc"},"location":{"lat":-33.87,"lng":151.21}}]},
         "foursquare":{"count":1,"items":[{"foursquare":{"foursquare_id":"def"},"venue_name":"Wings",
           "categories":{"count":1,"items":[{"category_name":"Wings Joint","is_primary":true}]},
           "location":{"venue_address":"2 Chapel St","lat":-33.876,"lng":151.216},"distance":0.777}]}}}
        """
        let r = try UntappdAPI.decode(VenueAround.self, from: Data(json.utf8))
        XCTAssertEqual(r.recent.first?.venueId, 107565)
        XCTAssertEqual(r.recent.first?.isVerified, true)
        XCTAssertEqual(r.nearby.first?.foursquareId, "def")
        XCTAssertEqual(r.nearby.first?.category, "Wings Joint")
        XCTAssertNil(r.nearby.first?.venueId)

        let encoded = try JSONEncoder().encode(r.recent[0])
        let back = try JSONDecoder().decode(Venue.self, from: encoded)
        XCTAssertEqual(back.venueId, 107565)
        XCTAssertEqual(back.foursquareId, "abc")
        XCTAssertEqual(back.lat, -33.87)
    }

    func testVenueMap() throws {
        let json = """
        {"meta":{"code":200},"response":{"bounds":{"ne":[-33.8,151.3],"sw":[-33.9,151.1]},
         "venues":{"count":1,"items":[{"popularity_score":488,"distance":0.339,
           "venue":{"venue_id":107565,"venue_name":"Hotel Sweeneys","primary_category":"Dining and Drinking",
             "is_verified":true,"foursquare":{"foursquare_id":"abc"},"location":{"lat":-33.87,"lng":151.21}}}]}}}
        """
        let m = try UntappdAPI.decode(VenueMap.self, from: Data(json.utf8))
        let v = try XCTUnwrap(m.venues.first)
        XCTAssertEqual(v.venueId, 107565)
        XCTAssertEqual(v.popularity, 488)
        XCTAssertEqual(v.reportedDistance ?? 0, 339, accuracy: 0.01)
        XCTAssertTrue(v.looksLikeDrinkingPlace)
        XCTAssertEqual(m.centerLat ?? 0, -33.85, accuracy: 1e-9)
    }

    func testVenueInfoTapNumbers() throws {
        let json = """
        {"meta":{"code":200},"response":{"venue":{"venue_id":1,"venue_name":"V","recently_added":{"count":2,"items":[
          {"tap_number":"7","beer":{"bid":10,"beer_name":"A","rating_score":3.9},"brewery":{"brewery_name":"B"}},
          {"tap_number":"0","beer":{"bid":11,"beer_name":"C"},"brewery":{"brewery_name":"D"}}]}}}}
        """
        let info = try UntappdAPI.decode(VenueInfo.self, from: Data(json.utf8))
        XCTAssertEqual(info.onTap.map(\.tapNumber), ["7", nil])
        XCTAssertEqual(info.onTap.first?.beer?.rating, 3.9)
        XCTAssertEqual(info.onTap.first?.beer?.brewery, "B")
    }

    func testMenuItemsWithStringNumbers() throws {
        let json = """
        {"meta":{"code":200},"response":{"sections":[{"section_id":1,"menu_name":"Tap List","section_name":"On Tap",
          "items":[{"id":10,"untappd_id":42,"name":"IPA","brewery":"B","abv":"6.5","rating":"3.91","tap_number":"4"}]}]}}
        """
        let m = try UntappdAPI.decode(MenuSections.self, from: Data(json.utf8))
        let item = try XCTUnwrap(m.sections.first?.items.first)
        XCTAssertEqual(item.beer?.bid, 42)
        XCTAssertEqual(item.beer?.abv, 6.5)
        XCTAssertEqual(item.beer?.rating, 3.91)
        XCTAssertEqual(item.tapNumber, "4")
        XCTAssertEqual(m.sections.first?.title(), "Tap List · On Tap")
        XCTAssertEqual(m.sections.first?.title(venueName: "Tap List"), "On Tap")
    }

    func testServerErrorEnvelope() throws {
        let json = #"{"meta":{"code":500,"error_detail":"Invalid credentials","error_type":"invalid_param"},"response":[]}"#
        XCTAssertThrowsError(try UntappdAPI.decode(XAuthResponse.self, from: Data(json.utf8)))
    }

    func testRelativeTime() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(RelativeTime.string(now.addingTimeInterval(-16 * 60), now: now), "16 minutes ago")
        XCTAssertFalse(RelativeTime.string(now.addingTimeInterval(-2 * 86_400), now: now).contains("ago"))
    }

    func testLocalIndexSearch() async {
        let idx = LocalIndex(url: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        await idx.add(beers: [
            BeerLite(bid: 1, name: "Pliny the Elder", brewery: "Russian River", popularity: 100),
            BeerLite(bid: 2, name: "Elder Ale", brewery: "Other"),
        ])
        let r = await idx.searchBeers("pli eld")
        XCTAssertEqual(r.map(\.bid), [1])
        let r2 = await idx.searchBeers("russian")
        XCTAssertEqual(r2.map(\.bid), [1])
    }

    @MainActor
    func testCheckInVenuesIncludesAtHomeFirst() {
        let model = DiscoverModel(username: "me")
        XCTAssertEqual(model.checkInVenues.first, .atHome)
        XCTAssertEqual(model.checkInVenues.first?.foursquareId, "5e7b4d99c91df60008e8b168")
    }

    func testShortName() {
        func u(_ f: String?, _ l: String?) -> User { User(id: 1, userName: "jc99", firstName: f, lastName: l, avatar: nil) }
        XCTAssertEqual(u("Jamie", "Curtis").shortName, "Jamie C")
        XCTAssertEqual(u("Jamie", nil).shortName, "Jamie")
        XCTAssertEqual(u("Jamie", " ").shortName, "Jamie")
        XCTAssertEqual(u(nil, "Curtis").shortName, "Curtis")
        XCTAssertEqual(u(nil, nil).shortName, "jc99")
    }

    func testCommentListAndEditedComment() throws {
        let added = """
        {"meta":{"code":200},"response":{"result":"success","comments":{"total_count":2,"count":2,"items":[
          {"user":{"uid":1,"user_name":"a"},"checkin_id":5,"comment_id":10,"comment_owner":false,"comment_editor":false,
           "comment":"Hi","created_at":"Sat, 14 Nov 2026 05:39:49 +0000"},
          {"user":{"uid":2,"user_name":"me"},"checkin_id":5,"comment_id":11,"comment_owner":true,"comment_editor":true,
           "comment":"Test"}]}}}
        """
        let list = try UntappdAPI.decode(CommentList.self, from: Data(added.utf8))
        XCTAssertEqual(list.totalCount, 2)
        XCTAssertEqual(list.comments.map(\.id), [10, 11])
        XCTAssertEqual(list.comments[0].canDelete, false)
        XCTAssertEqual(list.comments[1].canEdit, true)
        XCTAssertNotNil(list.comments[0].createdAt)

        let deleted = """
        {"meta":{"code":200},"response":{"result":"success","comments":{"total_count":0,"count":0,"items":[]}}}
        """
        XCTAssertEqual(try UntappdAPI.decode(CommentList.self, from: Data(deleted.utf8)).comments.count, 0)

        let edited = """
        {"meta":{"code":200},"response":{"result":"success","comment":{"user":{"uid":2,"user_name":"me"},
          "checkin_id":5,"comment_id":11,"comment_owner":true,"comment_editor":true,"comment":"Test 2"}}}
        """
        let e = try UntappdAPI.decode(EditedComment.self, from: Data(edited.utf8))
        XCTAssertEqual(e.comment?.text, "Test 2")
        XCTAssertEqual(e.comment?.id, 11)
    }

    func testAccountSettingsRatingBump() throws {
        let on = #"{"meta":{"code":200},"response":{"user":{"uid":1,"user_name":"a","rating_bump":1}}}"#
        XCTAssertTrue(try UntappdAPI.decode(AccountSettings.self, from: Data(on.utf8)).ratingBump)
        let off = #"{"meta":{"code":200},"response":{"user":{"uid":1,"user_name":"a","rating_bump":0}}}"#
        XCTAssertFalse(try UntappdAPI.decode(AccountSettings.self, from: Data(off.utf8)).ratingBump)
    }

    func testCheckinAddPhotoUpload() throws {
        let json = """
        {"meta":{"code":200},"response":{"result":"success","checkin_id":1614085178,
         "photo_upload":{"url":"https://untappd.s3.amazonaws.com/photos/x_raw.jpg?x-amz-acl=public-read&X-Amz-Expires=120",
           "destination_url":"https://untappd.s3.amazonaws.com/photos/x_raw.jpg"}}}
        """
        let r = try UntappdAPI.decode(CheckinAddResponse.self, from: Data(json.utf8))
        XCTAssertEqual(r.checkinId, 1614085178)
        XCTAssertEqual(r.photoUploadURL?.query?.contains("X-Amz-Expires=120"), true)
        XCTAssertEqual(r.photoDestinationURL?.absoluteString, "https://untappd.s3.amazonaws.com/photos/x_raw.jpg")
    }

    func testPhotoUploadCompleteRequest() throws {
        let dest = URL(string: "https://untappd.s3.amazonaws.com/photos/x_raw.jpg")!
        let r = APIRequest.photoUploadComplete(checkinId: 1614085178, destination: dest)
        XCTAssertEqual(r.method, .post)
        XCTAssertEqual(r.path, "/v4/photo/uploadComplete")
        XCTAssertEqual(r.form, ["checkin_id": "1614085178", "destination_url": dest.absoluteString])
    }

    func testBarcodeMatchesShapes() throws {
        let blocks = """
        {"meta":{"code":200},"response":{"count":3,
         "verified":{"count":1,"items":[{"beer":{"bid":2,"beer_name":"Two"},"brewery":{"brewery_id":9,"brewery_name":"Brew Co"}}]},
         "unverified":[{"beer":{"bid":1,"beer_name":"One","brewery":{"brewery_id":8,"brewery_name":"Nested"}}},
                       {"beer":{"bid":2,"beer_name":"Two"}}]}}
        """
        let m = try UntappdAPI.decode(BarcodeMatches.self, from: Data(blocks.utf8))
        XCTAssertEqual(m.beers.map(\.bid), [2, 1])
        XCTAssertEqual(m.beers.map(\.brewery), ["Brew Co", "Nested"])

        let items = #"{"meta":{"code":200},"response":{"items":[{"beer":{"bid":5,"beer_name":"Five"}}]}}"#
        XCTAssertEqual(try UntappdAPI.decode(BarcodeMatches.self, from: Data(items.utf8)).beers.map(\.bid), [5])

        let none = #"{"meta":{"code":200},"response":{"count":0,"verified":[],"unverified":[]}}"#
        XCTAssertEqual(try UntappdAPI.decode(BarcodeMatches.self, from: Data(none.utf8)).beers, [])
    }

    func testBarcodeMatchesCaptured() throws {
        // As Untappd answered for a Corona Extra bottle (trimmed).
        let json = """
        {"meta":{"code":200},"response":{"barcode":"75032715","barcode_stripped":"075032715","count":1,
         "items":[{"beer":{"bid":5848,"beer_name":"Corona Extra","beer_abv":4.5,"beer_style":"Lager - Mexican",
                           "rating_score":3.163,"rating_count":706999,"has_had":true},
                   "brewery":{"brewery_id":618,"brewery_name":"Grupo Modelo","country_name":"Mexico"}}],
         "unverified":{"enabled":false,"count":0,"items":[]}}}
        """
        let b = try XCTUnwrap(UntappdAPI.decode(BarcodeMatches.self, from: Data(json.utf8)).beers.first)
        XCTAssertEqual(b.bid, 5848)
        XCTAssertEqual(b.brewery, "Grupo Modelo")
        XCTAssertEqual(b.style, "Lager - Mexican")
        XCTAssertEqual(b.rating, 3.163)
        XCTAssertEqual(b.hasHad, true)
    }

    func testBarcodeCandidates() {
        XCTAssertEqual(BarcodeLookup.candidates("0853993007033"), ["0853993007033", "853993007033"])
        XCTAssertEqual(BarcodeLookup.candidates("853993007033"), ["0853993007033", "853993007033"])
        XCTAssertEqual(BarcodeLookup.candidates("9300617003168"), ["9300617003168"])
        XCTAssertEqual(BarcodeLookup.candidates(" 5 056412 031946 "), ["5056412031946"])
        XCTAssertEqual(BarcodeLookup.candidates("abc"), [])
    }

    func testUserBeerRating() throws {
        func rating(_ body: String) throws -> Double? {
            try UntappdAPI.decode(UserBeerRating.self, from: Data(#"{"meta":{"code":200},"response":\#(body)}"#.utf8)).rating
        }
        XCTAssertNil(try rating(#"{"rating_score": 0}"#))
        XCTAssertNil(try rating("{}"))
        XCTAssertEqual(try rating(#"{"rating_score": 3.75}"#), 3.75)
        XCTAssertEqual(try rating(#"{"rating_score": "4.2"}"#), 4.2)
    }
}
