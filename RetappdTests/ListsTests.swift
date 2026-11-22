import XCTest
@testable import Retappd

final class ListsTests: XCTestCase {
    // MARK: - Decoding

    func testDecodeUserListsResponse() throws {
        let json = """
        {
          "meta": {"code": 200},
          "response": {
            "cached": false,
            "offset": 0,
            "limit": 25,
            "total_list_count": 2,
            "count": 2,
            "items": [
              {
                "list_id": 336725,
                "list_name": "Cellar",
                "list_description": "Aging stouts",
                "total_item_count": 11,
                "list_image": {
                  "count": 1,
                  "items": [
                    {"beer_label": "https://assets.untappd.com/site/beer_logos/beer-1_sm.jpeg"}
                  ]
                },
                "is_wish_list": false,
                "is_public": 0,
                "is_in_list": false,
                "updated_at": "Sat, 21 Nov 2026 12:53:59 +0000"
              },
              {
                "list_id": 1582622,
                "list_name": "Wish List",
                "list_description": null,
                "total_item_count": 3,
                "list_image": {
                  "count": 2,
                  "items": [
                    {"beer_label": "https://assets.untappd.com/site/assets/images/temp/badge-beer-default.png"},
                    {"beer_label": "https://assets.untappd.com/site/beer_logos/beer-4475229_c55c6_sm.jpeg"}
                  ]
                },
                "is_wish_list": true,
                "is_public": 1,
                "is_in_list": true,
                "updated_at": "Sun, 15 Nov 2026 01:06:28 +0000"
              }
            ],
            "pagination": {"next_url": "", "max_id": ""}
          }
        }
        """
        let decoded = try UntappdAPI.decode(UserListsResponse.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.totalCount, 2)
        XCTAssertEqual(decoded.items.count, 2)
        XCTAssertNil(decoded.nextURL)

        let cellar = decoded.items[0]
        XCTAssertEqual(cellar.id, 336725)
        XCTAssertEqual(cellar.name, "Cellar")
        XCTAssertEqual(cellar.description, "Aging stouts")
        XCTAssertEqual(cellar.totalItemCount, 11)
        XCTAssertFalse(cellar.isWishList)
        XCTAssertFalse(cellar.isPublic)
        XCTAssertEqual(cellar.isInList, false)
        XCTAssertEqual(cellar.previewLabels.count, 1)

        let wish = decoded.items[1]
        XCTAssertEqual(wish.id, 1582622)
        XCTAssertEqual(wish.name, "Wish List")
        XCTAssertNil(wish.description)
        XCTAssertEqual(wish.totalItemCount, 3)
        XCTAssertTrue(wish.isWishList)
        XCTAssertTrue(wish.isPublic)
        XCTAssertEqual(wish.isInList, true)
        XCTAssertEqual(wish.previewLabels.count, 2)

        let sorted = ListsOrder.sorted(decoded.items)
        XCTAssertEqual(sorted.map(\.id), [1582622, 336725])
    }

    func testDecodeCustomListDetailAndEnhancedItem() throws {
        let json = """
        {
          "meta": {"code": 200},
          "response": {
            "total_count": 2,
            "list": {
              "list_id": 11024053,
              "list_name": "Test list",
              "is_public": 0,
              "is_owner": true,
              "is_wish_list": false,
              "total_item_count": 2,
              "owner": {"user_name": "sampleuser"}
            },
            "count": 2,
            "items": [
              {
                "created_at": "Sat, 21 Nov 2026 12:53:59 +0000",
                "item_id": 5826548,
                "list_item_id": 81539691,
                "item_type": "beer",
                "beer": {
                  "bid": 5826548,
                  "beer_name": "American Amber",
                  "beer_label": "https://assets.untappd.com/site/beer_logos/beer-5826548_a3664_sm.jpeg",
                  "beer_abv": 5.0,
                  "beer_style": "Red Ale - American Amber / Red",
                  "rating_score": 3.546,
                  "rating_count": 369,
                  "has_had": true
                },
                "brewery": {
                  "brewery_id": 559450,
                  "brewery_name": "Chuck and Son's Brewing Co.",
                  "brewery_label": "https://assets.untappd.com/site/brewery_logos/brewery-559450_1d5c5.jpeg"
                },
                "notes": "Keep cold",
                "quantity": 2,
                "container": {"container_id": "3", "container_name": "Can"},
                "purchase_price": "8.50"
              },
              {
                "item_id": 999,
                "list_item_id": 81539692,
                "item_type": "venue"
              }
            ],
            "pagination": {"next_url": "https://api.untappd.com/v4/custom_lists/view/11024053?offset=25", "max_id": ""}
          }
        }
        """
        let decoded = try UntappdAPI.decode(CustomListDetailResponse.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.totalCount, 2)
        XCTAssertEqual(decoded.list?.id, 11024053)
        XCTAssertEqual(decoded.list?.isOwner, true)
        XCTAssertEqual(decoded.list?.ownerUsername, "sampleuser")
        XCTAssertNotNil(decoded.nextURL)
        XCTAssertEqual(decoded.items.count, 2)

        let first = decoded.items[0]
        XCTAssertEqual(first.listItemId, 81539691)
        XCTAssertEqual(first.beer?.bid, 5826548)
        XCTAssertEqual(first.beer?.name, "American Amber")
        XCTAssertEqual(first.beer?.brewery, "Chuck and Son's Brewing Co.")
        XCTAssertEqual(first.beer?.hasHad, true)
        XCTAssertEqual(first.beer?.rating ?? 0, 3.546, accuracy: 0.001)
        XCTAssertEqual(first.detailSummary, "Qty 2 · Can · Keep cold")
        XCTAssertEqual(first.purchasePrice, "8.50")

        let second = decoded.items[1]
        XCTAssertEqual(second.itemType, "venue")
        XCTAssertNil(second.beer)
    }

    func testDecodeMutationAndSubscribeResponses() throws {
        let addJSON = #"{"meta":{"code":200},"response":{"result":"success","item_id":5826548,"list_item_id":79657752}}"#
        let add = try UntappdAPI.decode(AddListItemResponse.self, from: Data(addJSON.utf8))
        XCTAssertTrue(add.isSuccess)
        XCTAssertEqual(add.itemId, 5826548)
        XCTAssertEqual(add.listItemId, 79657752)

        let removeJSON = #"{"meta":{"code":200},"response":{"result":"success","item_id":5826548}}"#
        let remove = try UntappdAPI.decode(RemoveListItemResponse.self, from: Data(removeJSON.utf8))
        XCTAssertTrue(remove.isSuccess)
        XCTAssertEqual(remove.itemId, 5826548)

        let wishJSON = #"{"meta":{"code":200},"response":{"result":"success","action":"add"}}"#
        let wish = try UntappdAPI.decode(WishlistMutationResponse.self, from: Data(wishJSON.utf8))
        XCTAssertTrue(wish.isSuccess)
        XCTAssertEqual(wish.action, "add")

        let subJSON = #"{"meta":{"code":200},"response":{"result":"success","mode":"on","count":2,"items":[75313,4475229]}}"#
        let sub = try UntappdAPI.decode(SubscribeWishResponse.self, from: Data(subJSON.utf8))
        XCTAssertTrue(sub.isSubscribed)
        XCTAssertEqual(sub.items, [75313, 4475229])

        let beerSubsJSON = """
        {
          "meta": {"code": 200},
          "response": {
            "wish_list_subscribe_status": true,
            "count": 1,
            "items": [
              {
                "has_had": true,
                "beer": {"bid": 3242260, "beer_name": "Endless Ending", "beer_abv": 15.5},
                "brewery": {"brewery_id": 13756, "brewery_name": "Anchorage Brewing Company"}
              }
            ]
          }
        }
        """
        let beerSubs = try UntappdAPI.decode(BeerSubscribesResponse.self, from: Data(beerSubsJSON.utf8))
        XCTAssertTrue(beerSubs.wishListSubscribeStatus)
        XCTAssertEqual(beerSubs.count, 1)
        XCTAssertEqual(beerSubs.items.first?.bid, 3242260)
        XCTAssertEqual(beerSubs.items.first?.hasHad, true)
    }

    func testAPIRequestShapes() {
        let ul = APIRequest.userLists("alice", bid: 42, offset: 25)
        XCTAssertEqual(ul.method, .get)
        XCTAssertEqual(ul.path, "/v4/custom_lists/userlists/alice")
        XCTAssertEqual(ul.query["bid"], "42")
        XCTAssertEqual(ul.query["offset"], "25")

        let detail = APIRequest.customListDetail(99, offset: 50)
        XCTAssertEqual(detail.method, .get)
        XCTAssertEqual(detail.path, "/v4/custom_lists/view/99")
        XCTAssertEqual(detail.query["offset"], "50")

        let add = APIRequest.addBeerToList(99, bid: 42)
        XCTAssertEqual(add.method, .post)
        XCTAssertEqual(add.path, "/v4/custom_lists/additemenhanced/99")
        XCTAssertEqual(add.form?["item_id"], "42")
        XCTAssertEqual(add.form?["item_type"], "beer")

        let rem = APIRequest.removeBeerFromList(99, bid: 42)
        XCTAssertEqual(rem.method, .post)
        XCTAssertEqual(rem.path, "/v4/custom_lists/removeitem/99")
        XCTAssertEqual(rem.form?["bid"], "42")

        let sub = APIRequest.subscribeWishlist(true)
        XCTAssertEqual(sub.method, .post)
        XCTAssertEqual(sub.path, "/v4/beer/subscribewish")
        XCTAssertEqual(sub.form?["toggle_option"], "on")
    }

    // MARK: - ViewModel State Transitions

    @MainActor
    func testUserListsModelLoadsSortsAndPaginates() async {
        let mock = MockListService()
        mock.userListsPages[0] = UserListsResponse(
            items: [
                CustomList(id: 10, name: "Cellar", totalItemCount: 4, isWishList: false),
                CustomList(id: 1, name: "Wish List", totalItemCount: 2, isWishList: true),
            ],
            totalCount: 3,
            offset: 0,
            nextURL: "https://api.untappd.com/next"
        )
        mock.userListsPages[2] = UserListsResponse(
            items: [
                CustomList(id: 20, name: "Summer Beers", totalItemCount: 7, isWishList: false),
            ],
            totalCount: 3,
            offset: 2,
            nextURL: nil
        )

        let model = UserListsModel(username: "alice", service: mock)
        await model.loadIfNeeded()
        XCTAssertEqual(model.lists.map(\.id), [1, 10])
        XCTAssertTrue(model.hasMore)
        XCTAssertNil(model.error)

        await model.loadMore()
        XCTAssertEqual(model.lists.map(\.id), [1, 10, 20])
        XCTAssertFalse(model.hasMore)
    }

    @MainActor
    func testBeerListsSheetModelTogglesAndRollsBackOnError() async {
        let mock = MockListService()
        let beer = BeerLite(bid: 555, name: "Test IPA", brewery: "Test Brew")
        mock.userListsPages[0] = UserListsResponse(items: [
            CustomList(id: 1, name: "Wish List", totalItemCount: 2, isWishList: true, isInList: false),
            CustomList(id: 2, name: "Cellar", totalItemCount: 5, isWishList: false, isInList: true),
        ])

        let model = BeerListsSheetModel(beer: beer, username: "alice", service: mock)
        await model.load()
        XCTAssertEqual(model.isInWishlist, false)
        XCTAssertTrue(model.isInAnyList)

        // Add to Wish List -> calls addToWishlist
        let added = await model.toggle(model.lists[0])
        XCTAssertTrue(added)
        XCTAssertEqual(model.isInWishlist, true)
        XCTAssertEqual(model.lists[0].totalItemCount, 3)
        XCTAssertEqual(mock.calls, ["addToWishlist(555)", "invalidate(alice,555,1)"])

        // Fail removing from Cellar -> rolls back membership & count
        mock.failNextMutation = true
        let removed = await model.toggle(model.lists[1])
        XCTAssertFalse(removed)
        XCTAssertEqual(model.lists[1].isInList, true)
        XCTAssertEqual(model.lists[1].totalItemCount, 5)
        XCTAssertNotNil(model.mutationError)

        // Succeed removing from Cellar
        mock.failNextMutation = false
        let removed2 = await model.toggle(model.lists[1])
        XCTAssertTrue(removed2)
        XCTAssertEqual(model.lists[1].isInList, false)
        XCTAssertEqual(model.lists[1].totalItemCount, 4)
        XCTAssertNil(model.mutationError)
    }

    @MainActor
    func testCustomListDetailModelRemoveAndRollback() async {
        let mock = MockListService()
        let list = CustomList(id: 2, name: "Cellar", totalItemCount: 2, isWishList: false, isOwner: true)
        let beer1 = BeerLite(bid: 100, name: "Stout", brewery: "Brew A")
        let beer2 = BeerLite(bid: 200, name: "Pilsner", brewery: "Brew B")
        let item1 = CustomListItem(listItemId: 1001, itemId: 100, beer: beer1)
        let item2 = CustomListItem(listItemId: 1002, itemId: 200, beer: beer2)
        mock.detailPages[0] = CustomListDetailResponse(list: list, totalCount: 2, items: [item1, item2])

        let model = CustomListDetailModel(list: list, ownerUsername: "alice", service: mock)
        await model.loadIfNeeded()
        XCTAssertEqual(model.beerItems.map(\.itemId), [100, 200])

        // Fail removal -> item restored
        mock.failNextMutation = true
        let failed = await model.remove(item1)
        XCTAssertFalse(failed)
        XCTAssertEqual(model.beerItems.map(\.itemId), [100, 200])
        XCTAssertEqual(model.totalCount, 2)
        XCTAssertNotNil(model.actionError)

        // Succeed removal -> item removed and count decremented
        mock.failNextMutation = false
        let ok = await model.remove(item1)
        XCTAssertTrue(ok)
        XCTAssertEqual(model.beerItems.map(\.itemId), [200])
        XCTAssertEqual(model.totalCount, 1)
        XCTAssertEqual(mock.calls.last, "invalidate(alice,100,2)")
    }

    @MainActor
    func testConcurrentRemovalRollbackDoesNotClobberSiblingRemoval() async {
        let mock = MockListService()
        let list = CustomList(id: 2, name: "Cellar", totalItemCount: 3, isWishList: false, isOwner: true)
        let item1 = CustomListItem(listItemId: 1001, itemId: 100, beer: BeerLite(bid: 100, name: "Stout", brewery: "A"))
        let item2 = CustomListItem(listItemId: 1002, itemId: 200, beer: BeerLite(bid: 200, name: "IPA", brewery: "B"))
        let item3 = CustomListItem(listItemId: 1003, itemId: 300, beer: BeerLite(bid: 300, name: "Lager", brewery: "C"))
        mock.detailPages[0] = CustomListDetailResponse(list: list, totalCount: 3, items: [item1, item2, item3])
        mock.failBids = [100]
        mock.delayBids = [100: 80_000_000] // 80ms so item2 finishes removing before item1 fails

        let model = CustomListDetailModel(list: list, ownerUsername: "alice", service: mock)
        await model.loadIfNeeded()

        async let r1 = model.remove(item1)
        async let r2 = model.remove(item2)
        let (ok1, ok2) = await (r1, r2)

        XCTAssertFalse(ok1)
        XCTAssertTrue(ok2)
        // item1 restored, item2 stays removed, item3 untouched
        XCTAssertEqual(model.beerItems.map(\.itemId), [100, 300])
        XCTAssertEqual(model.totalCount, 2)
        XCTAssertEqual(model.list.totalItemCount, 2)
    }

    @MainActor
    func testMutationsPostListsChangedNotificationAndUseConsistentSheetLimit() async {
        let mock = MockListService()
        let beer = BeerLite(bid: 555, name: "Test IPA", brewery: "Test Brew")
        mock.userListsPages[0] = UserListsResponse(items: [
            CustomList(id: 1, name: "Wish List", totalItemCount: 0, isWishList: true, isInList: false),
        ])

        var receivedListIDs: [Int] = []
        let token = NotificationCenter.default.addObserver(
            forName: .listsChanged, object: nil, queue: .main
        ) { note in
            if let id = note.userInfo?["listId"] as? Int { receivedListIDs.append(id) }
        }
        defer { NotificationCenter.default.removeObserver(token) }

        let model = BeerListsSheetModel(beer: beer, username: "alice", service: mock)
        await model.load()
        XCTAssertEqual(mock.lastUserListsLimit, ListsPageLimit.beerSheet)

        let ok = await model.toggle(model.lists[0])
        XCTAssertTrue(ok)
        XCTAssertEqual(receivedListIDs, [1])
        XCTAssertEqual(
            APIRequest.userLists("alice", bid: 555, limit: ListsPageLimit.beerSheet).cacheKey,
            APIRequest.userLists("alice", bid: 555, offset: 0, limit: 50).cacheKey
        )
    }
}

private final class MockListService: ListService, @unchecked Sendable {
    var userListsPages: [Int: UserListsResponse] = [:]
    var detailPages: [Int: CustomListDetailResponse] = [:]
    var failNextMutation = false
    var failBids: Set<Int> = []
    var delayBids: [Int: UInt64] = [:]
    var lastUserListsLimit: Int?
    var calls: [String] = []

    func fetchUserLists(username: String, bid: Int?, offset: Int, limit: Int,
                        onCached: (@MainActor @Sendable (UserListsResponse) -> Void)?) async throws -> UserListsResponse {
        lastUserListsLimit = limit
        guard let page = userListsPages[offset] else {
            return UserListsResponse(items: [], totalCount: 0, offset: offset, nextURL: nil)
        }
        return page
    }

    func fetchListDetail(listId: Int, offset: Int, limit: Int,
                         onCached: (@MainActor @Sendable (CustomListDetailResponse) -> Void)?) async throws -> CustomListDetailResponse {
        guard let page = detailPages[offset] else {
            return CustomListDetailResponse(items: [])
        }
        return page
    }

    func addToWishlist(bid: Int) async throws -> WishlistMutationResponse {
        if let ns = delayBids[bid] { try? await Task.sleep(nanoseconds: ns) }
        if failNextMutation || failBids.contains(bid) { throw APIError.server(code: 500, detail: "Server error") }
        calls.append("addToWishlist(\(bid))")
        return try UntappdAPI.decode(WishlistMutationResponse.self, from: Data(#"{"meta":{"code":200},"response":{"result":"success","action":"add"}}"#.utf8))
    }

    func removeFromWishlist(bid: Int) async throws -> WishlistMutationResponse {
        if let ns = delayBids[bid] { try? await Task.sleep(nanoseconds: ns) }
        if failNextMutation || failBids.contains(bid) { throw APIError.server(code: 500, detail: "Server error") }
        calls.append("removeFromWishlist(\(bid))")
        return try UntappdAPI.decode(WishlistMutationResponse.self, from: Data(#"{"meta":{"code":200},"response":{"result":"success","action":"remove"}}"#.utf8))
    }

    func addBeer(bid: Int, toList listId: Int) async throws -> AddListItemResponse {
        if let ns = delayBids[bid] { try? await Task.sleep(nanoseconds: ns) }
        if failNextMutation || failBids.contains(bid) { throw APIError.server(code: 500, detail: "Server error") }
        calls.append("addBeer(\(bid),\(listId))")
        return try UntappdAPI.decode(AddListItemResponse.self, from: Data(#"{"meta":{"code":200},"response":{"result":"success","item_id":1,"list_item_id":2}}"#.utf8))
    }

    func removeBeer(bid: Int, fromList listId: Int) async throws -> RemoveListItemResponse {
        if let ns = delayBids[bid] { try? await Task.sleep(nanoseconds: ns) }
        if failNextMutation || failBids.contains(bid) { throw APIError.server(code: 500, detail: "Server error") }
        calls.append("removeBeer(\(bid),\(listId))")
        return try UntappdAPI.decode(RemoveListItemResponse.self, from: Data(#"{"meta":{"code":200},"response":{"result":"success","item_id":1}}"#.utf8))
    }

    func invalidateCaches(username: String?, bid: Int?, listId: Int?) async {
        calls.append("invalidate(\(username ?? "nil"),\(bid.map(String.init) ?? "nil"),\(listId.map(String.init) ?? "nil"))")
    }
}
