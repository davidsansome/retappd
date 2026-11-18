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

    func testVenueInfoStatsAndWebsite() throws {
        let json = """
        {"meta":{"code":200},"response":{"venue":{"venue_id":17058,"venue_name":"Union Hotel Newtown",
         "stats":{"total_count":48210,"user_count":3,"total_user_count":21900,"monthly_count":1200,"weekly_count":312},
         "location":{"venue_address":"576 King St","venue_city":"Newtown","venue_state":"NSW","venue_country":"Australia","lat":-33.9,"lng":151.18},
         "contact":{"twitter":"","venue_url":"www.example.com.au","facebook":""}}}}
        """
        let info = try UntappdAPI.decode(VenueInfo.self, from: Data(json.utf8))
        XCTAssertEqual(info.stats?.total, 48210)
        XCTAssertEqual(info.stats?.people, 21900)
        XCTAssertEqual(info.stats?.yours, 3)
        XCTAssertEqual(info.stats?.thisWeek, 312)
        XCTAssertEqual(info.country, "Australia")
        XCTAssertEqual(info.website?.absoluteString, "https://www.example.com.au")
        XCTAssertEqual(info.venue?.address, "576 King St")
    }

    func testVenueWebsiteIgnoresJunk() {
        XCTAssertNil(VenueInfo.websiteURL(""))
        XCTAssertNil(VenueInfo.websiteURL("  "))
        XCTAssertNil(VenueInfo.websiteURL("n/a"))
        XCTAssertEqual(VenueInfo.websiteURL("http://a.com/x")?.absoluteString, "http://a.com/x")
    }

    func testShortRelativeTimeAndBuckets() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let now = cal.date(from: DateComponents(year: 2026, month: 11, day: 16, hour: 20))!
        func ago(_ s: TimeInterval) -> Date { now.addingTimeInterval(-s) }
        XCTAssertEqual(RelativeTime.short(ago(30), now: now, calendar: cal), "now")
        XCTAssertEqual(RelativeTime.short(ago(12 * 60), now: now, calendar: cal), "12m")
        XCTAssertEqual(RelativeTime.short(ago(5 * 3600), now: now, calendar: cal), "5h")
        XCTAssertEqual(RelativeTime.short(ago(24 * 3600), now: now, calendar: cal), "Yesterday")
        XCTAssertEqual(RelativeTime.short(ago(3 * 86_400), now: now, calendar: cal), "3d")
        XCTAssertEqual(RelativeTime.Bucket(ago(10 * 60), now: now, calendar: cal), .lastHour)
        XCTAssertEqual(RelativeTime.Bucket(ago(5 * 3600), now: now, calendar: cal), .today)
        XCTAssertEqual(RelativeTime.Bucket(ago(3 * 86_400), now: now, calendar: cal), .thisWeek)
        XCTAssertEqual(RelativeTime.Bucket(ago(30 * 86_400), now: now, calendar: cal), .earlier)
    }

    func testVenueCheckinsPaging() {
        let r = APIRequest.venueCheckins(17058, friendsOnly: true, maxId: 99)
        XCTAssertEqual(r.path, "/v4/venue/checkins/17058")
        XCTAssertEqual(r.query["type"], "friends")
        XCTAssertEqual(r.query["max_id"], "99")
    }

    // MARK: Beer and brewery pages. Fields the docs truncate are filled in from the OpenAPI schema.

    func testBeerInfo() throws {
        let json = """
        {"meta":{"code":200},"response":{"beer":{
          "bid": 5826548, "beer_name": "American Amber",
          "beer_label": "https://assets.untappd.com/site/beer_logos/beer-5826548_a3664_sm.jpeg",
          "beer_label_hd": "https://assets.untappd.com/site/beer_logos_hd/beer-5826548_a8a56_hd.jpeg",
          "beer_abv": 5, "beer_ibu": 37, "beer_description": "An easy red.",
          "beer_style": "Amber Ale - American", "is_in_production": 1,
          "rating_count": 4021, "rating_score": 3.62,
          "stats": {"total_count": 9000, "monthly_count": 120, "total_user_count": 3100, "user_count": 3},
          "auth_rating": 3.75, "wish_list": false,
          "brewery": {"brewery_id": 5130, "brewery_name": "Chuck and Son's Brewing Co",
            "brewery_label": "https://assets.untappd.com/site/brewery_logos/brewery-5130_x.jpeg",
            "country_name": "Australia", "brewery_type": "Micro Brewery",
            "location": {"brewery_city": "Sydney", "brewery_state": "NSW"}}
        }}}
        """
        let info = try UntappdAPI.decode(BeerInfo.self, from: Data(json.utf8))
        XCTAssertEqual(info.bid, 5826548)
        XCTAssertEqual(info.name, "American Amber")
        XCTAssertEqual(info.abv, 5)
        XCTAssertEqual(info.ibu, 37)
        XCTAssertEqual(info.description, "An easy red.")
        XCTAssertEqual(info.rating, 3.62)
        XCTAssertEqual(info.ratingCount, 4021)
        XCTAssertEqual(info.stats?.yours, 3)
        XCTAssertEqual(info.stats?.people, 3100)
        XCTAssertEqual(info.yourRating, 3.75)
        XCTAssertTrue(info.hasHad)
        XCTAssertEqual(info.isInWishlist, false)
        XCTAssertEqual(info.brewery?.id, 5130)
        XCTAssertEqual(info.city, "Sydney")
        XCTAssertEqual(info.lite.breweryId, 5130)
        XCTAssertEqual(info.lite.brewery, "Chuck and Son's Brewing Co")
    }

    func testBeerInfoNotHad() throws {
        let json = """
        {"response":{"beer":{"bid": 1, "beer_name": "New", "beer_abv": 4.5, "beer_ibu": 0,
          "rating_score": 0, "rating_count": 0, "stats": {"user_count": 0}, "auth_rating": 0,
          "brewery": []}}}
        """
        let info = try UntappdAPI.decode(BeerInfo.self, from: Data(json.utf8))
        XCTAssertFalse(info.hasHad)
        XCTAssertNil(info.yourRating)
        XCTAssertNil(info.brewery)
        XCTAssertNil(info.lite.rating)
    }

    func testBreweryInfo() throws {
        let json = """
        {"meta":{"code":200},"response":{"brewery":{
          "brewery_id": 198631, "brewery_name": "Bathtub Brewing", "brewery_slug": "bathtub-brewing",
          "brewery_page_url": "/BathtubBrewingAU",
          "brewery_label": "https://assets.untappd.com/site/brewery_logos/brewery-198631_4bf10.jpeg",
          "brewery_label_hd": "", "country_name": "Australia", "beer_count": 46,
          "contact": {"twitter": "BathtubBrewing", "facebook": "https://facebook.com/bathtub", "instagram": "@bathtub", "url": "bathtub.example.com"},
          "brewery_type": "Home / Non-Commercial Brewery",
          "location": {"brewery_address": "1 Tub St", "brewery_city": "Sydney", "brewery_state": "NSW", "brewery_lat": -33.8, "brewery_lng": 151.2},
          "rating": {"count": 321, "rating_score": 3.9},
          "brewery_description": "Mead and more.",
          "stats": {"total_count": 500, "unique_count": 200, "monthly_count": 9, "weekly_count": 2, "user_count": 8},
          "user_average_rating": 4.1
        }}}
        """
        let b = try UntappdAPI.decode(BreweryInfo.self, from: Data(json.utf8))
        XCTAssertEqual(b.id, 198631)
        XCTAssertEqual(b.name, "Bathtub Brewing")
        XCTAssertNil(b.labelHD)
        XCTAssertEqual(b.type, "Home / Non-Commercial Brewery")
        XCTAssertEqual(b.locality, "Sydney, NSW, Australia")
        XCTAssertEqual(b.rating, 3.9)
        XCTAssertEqual(b.ratingCount, 321)
        XCTAssertEqual(b.beerCount, 46)
        XCTAssertEqual(b.stats?.total, 500)
        XCTAssertEqual(b.stats?.yours, 8)
        XCTAssertEqual(b.yourAverage, 4.1)
        XCTAssertEqual(b.website?.absoluteString, "https://bathtub.example.com")
        XCTAssertEqual(b.twitter?.absoluteString, "https://x.com/BathtubBrewing")
        XCTAssertEqual(b.facebook?.absoluteString, "https://facebook.com/bathtub")
        XCTAssertEqual(b.instagram?.absoluteString, "https://instagram.com/bathtub")
    }

    func testBreweryBeerList() throws {
        let json = """
        {"meta":{"code":200},"response":{"total_count_filtered": 46, "total_count": 46, "beers": {"count": 2, "items": [
          {"total_user_count": 8, "has_had": true, "total_count": 29,
           "beer": {"bid": 1719356, "beer_name": "Let's Bee Friends",
             "beer_label": "https://assets.untappd.com/site/beer_logos/beer-1719356_f0a2a_sm.jpeg",
             "beer_style": "Mead - Other", "beer_abv": 11.03, "beer_ibu": 0, "rating_score": 3.8, "rating_count": 50},
           "brewery": {"brewery_id": 198631, "brewery_name": "Bathtub Brewing",
             "brewery_label": "https://assets.untappd.com/site/brewery_logos/brewery-198631_4bf10.jpeg"},
           "friends": []},
          {"has_had": false, "beer": {"bid": 3791206, "beer_name": "Cherry Stinger", "beer_abv": 15},
           "brewery": {"brewery_id": 198631, "brewery_name": "Bathtub Brewing"}}
        ]}}}
        """
        let list = try UntappdAPI.decode(BreweryBeerList.self, from: Data(json.utf8))
        XCTAssertEqual(list.total, 46)
        XCTAssertEqual(list.beers.map(\.bid), [1719356, 3791206])
        XCTAssertEqual(list.beers[0].hasHad, true)
        XCTAssertEqual(list.beers[0].rating, 3.8)
        XCTAssertEqual(list.beers[0].breweryId, 198631)
        XCTAssertEqual(list.beers[0].brewery, "Bathtub Brewing")
        XCTAssertEqual(list.beers[1].hasHad, false)
        XCTAssertNil(list.beers[1].rating)
    }

    func testBeerAndBreweryRequests() {
        let beer = APIRequest.beerInfo(7)
        XCTAssertEqual(beer.path, "/v4/beer/info/7")
        XCTAssertEqual(beer.query["compact"], "enhanced")
        XCTAssertEqual(APIRequest.breweryBeers(3, offset: 25).query["offset"], "25")
        XCTAssertNil(APIRequest.breweryBeers(3).query["offset"])
        XCTAssertEqual(APIRequest.beerCheckins(7, maxId: 9).query["max_id"], "9")
        XCTAssertEqual(BeerBreweryRoute.brewery(of: BeerLite(bid: 1, name: "A", brewery: "B", breweryId: 4)),
                       .brewery(id: 4, name: "B"))
        XCTAssertNil(BeerBreweryRoute.brewery(of: BeerLite(bid: 1, name: "A", brewery: "B")))
    }

    func testBadgeStatus() throws {
        let json = """
        {"meta":{"code":200},"response":{"badge_statuses":{
          "48578": {"level": 495, "total": 495, "user_badge_id": 1286972644},
          "751844": null,
          "544915": {"level": 152, "total": 155, "user_badge_id": 1402818945}
        }}}
        """
        let list = try UntappdAPI.decode(BadgeStatusList.self, from: Data(json.utf8))
        XCTAssertEqual(list.statuses.count, 2)
        XCTAssertEqual(list.statuses[544915]?.level, 152)
        XCTAssertEqual(list.statuses[544915]?.total, 155)
        XCTAssertEqual(list.statuses[48578]?.userBadgeId, 1286972644)
        XCTAssertNil(list.statuses[751844])
        let q = APIRequest.badgeStatus([48578, 751844]).query
        XCTAssertEqual(q, ["badge_ids[0]": "48578", "badge_ids[1]": "751844"])
    }

    func testCheckinBadgeKeepsBothIds() throws {
        let json = """
        {"badge_id": 48578, "user_badge_id": 250328177, "badge_name": "Sweeney's Rooftop",
         "badge_description": "Thanks for enjoying a beer.",
         "badge_image": {"sm": "https://x/a_sm.jpeg", "md": "https://x/a_md.jpeg", "lg": "https://x/a_lg.jpeg"}}
        """
        let b = try JSONDecoder().decode(Checkin.Badge.self, from: Data(json.utf8))
        XCTAssertEqual(b.id, 250328177)
        XCTAssertEqual(b.badgeId, 48578)
        XCTAssertEqual(b.userBadgeId, 250328177)
        XCTAssertEqual(b.description, "Thanks for enjoying a beer.")
        XCTAssertEqual(b.image?.lastPathComponent, "a_md.jpeg")
        XCTAssertEqual(b.largeImage?.lastPathComponent, "a_lg.jpeg")
        XCTAssertNotNil(BeerBreweryRoute.badge(of: b))
    }

    func testFriendBadges() throws {
        // Shape of a live response (the test accounts' Newbie badge), plus a level entry as the
        // docs describe for level badges.
        let json = """
        {"meta":{"code":200},"response":{"count":2,"items":[
          {"created_at":"Wed, 18 Nov 2026 09:47:02 +0000","user_badge_id":1438263300,"is_levelable":false,
           "current_level":0,"user":{"first_name":"Test 2","last_name":"T","user_name":"retappd-test-2",
           "is_supporter":0,"user_avatar":"https://x/a.jpg","flair":null}},
          {"created_at":"Sat, 14 Nov 2026 14:17:57 +0000","user_badge_id":0,"is_levelable":true,
           "current_level":12,"user":{"first_name":"","last_name":"","user_name":"lev","user_avatar":""}},
          {"created_at":"Sat, 14 Nov 2026 14:17:57 +0000","user_badge_id":1,"current_level":3,"user":null}
        ],"is_parent":false}}
        """
        let list = try UntappdAPI.decode(FriendBadgeList.self, from: Data(json.utf8))
        XCTAssertEqual(list.count, 2)
        XCTAssertFalse(list.isParent)
        XCTAssertEqual(list.items.map(\.user.userName), ["retappd-test-2", "lev"])
        XCTAssertNil(list.items[0].level)
        XCTAssertEqual(list.items[0].userBadgeId, 1438263300)
        XCTAssertNotNil(list.items[0].earnedAt)
        XCTAssertEqual(list.items[0].user.displayName, "Test 2 T")
        XCTAssertEqual(list.items[1].level, 12)
        XCTAssertNil(list.items[1].userBadgeId)
        XCTAssertEqual(list.items[1].user.displayName, "lev")

        XCTAssertEqual(APIRequest.friendsBadges(1).path, "/v4/badges/friends_badges/1")
        XCTAssertEqual(APIRequest.friendsBadges(1).query, ["limit": "15", "q": "", "sort": "level"])
        XCTAssertEqual(APIRequest.friendsBadges(1, offset: 15).query["offset"], "15")
    }

    func testBadgeNameLevel() {
        XCTAssertEqual(BadgeName.level(of: "The Backpacker (Level 28)"), 28)
        XCTAssertEqual(BadgeName.base(of: "The Backpacker (Level 28)"), "The Backpacker")
        XCTAssertNil(BadgeName.level(of: "Newbie"))
        XCTAssertEqual(BadgeName.base(of: "Newbie"), "Newbie")
        XCTAssertEqual(BadgeName.base(of: "(Level 3)"), "(Level 3)")
        XCTAssertNil(BadgeName.level(of: "Level (Level 3) Up"))
    }
}
