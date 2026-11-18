import XCTest
@testable import Retappd

final class FriendsTests: XCTestCase {
    // Shaped like the sample in docs/API.md for GET /v4/user/friends (the docs truncate each user,
    // so the names here are made up).
    private let json = """
    {"meta":{"code":200},"response":{"found":3,"count":3,"items":[
      {"friendship_hash":"a","created_at":"Sat, 04 Jul 2026 05:10:03 +0000","mutual_friends":{"count":0,"items":[]},
       "user":{"uid":6825036,"user_name":"Jackdup_","location":"Sydney","bio":"","is_supporter":0,
               "first_name":"Jack","last_name":"Dup","relationship":"friends","user_avatar":"https://x/a.jpg"}},
      {"friendship_hash":"b","created_at":"Sun, 05 Jul 2026 00:36:37 +0000","mutual_friends":{"count":0,"items":[]},
       "user":{"uid":6974987,"user_name":"adam_shaw_1519","location":"","bio":"",
               "first_name":"Adam","last_name":"Shaw","relationship":"friends"}},
      {"friendship_hash":"c","created_at":"Mon, 01 Jun 2026 10:00:00 +0000",
       "user":{"uid":7,"user_name":"zed","first_name":"Zoë","last_name":""}}
    ],"pagination":{"next_url":"https://api.untappd.com/v4/user/friends/sampleuser?utv=4.0.0&limit=10&offset=10","offset":10,"max_id":false}}}
    """

    private func page() throws -> FriendPage {
        try UntappdAPI.decode(FriendPage.self, from: Data(json.utf8))
    }

    func testDecodesFriendsPage() throws {
        let p = try page()
        XCTAssertEqual(p.found, 3)
        XCTAssertEqual(p.friends.count, 3)
        XCTAssertEqual(p.friends[0].user.userName, "Jackdup_")
        XCTAssertEqual(p.friends[0].location, "Sydney")
        XCTAssertNil(p.friends[1].location)  // empty string
        XCTAssertNotNil(p.friends[0].createdAt)
        XCTAssertEqual(p.friends[2].user.displayName, "Zoë")
    }

    func testSortsNewestFriendshipFirst() throws {
        let names = Friend.sortedByRecent(try page().friends).map(\.user.userName)
        XCTAssertEqual(names, ["adam_shaw_1519", "Jackdup_", "zed"])
    }

    func testUndatedFriendsSortLast() throws {
        var friends = try page().friends
        friends.append(Friend(user: User(id: 1, userName: "nodate", firstName: nil, lastName: nil, avatar: nil)))
        XCTAssertEqual(Friend.sortedByRecent(friends).last?.user.userName, "nodate")
    }

    func testFilterMatchesUsernameFirstAndLastName() throws {
        let friends = try page().friends
        XCTAssertEqual(Friend.filter(friends, matching: "").count, 3)
        XCTAssertEqual(Friend.filter(friends, matching: "SHAW").map(\.user.userName), ["adam_shaw_1519"])
        XCTAssertEqual(Friend.filter(friends, matching: "jack").map(\.user.userName), ["Jackdup_"])
        XCTAssertEqual(Friend.filter(friends, matching: "dup").map(\.user.userName), ["Jackdup_"])
        XCTAssertEqual(Friend.filter(friends, matching: "adam sh").map(\.user.userName), ["adam_shaw_1519"])
        XCTAssertEqual(Friend.filter(friends, matching: "zoe").map(\.user.userName), ["zed"])  // accents ignored
        XCTAssertEqual(Friend.filter(friends, matching: "@jackdup").map(\.user.userName), ["Jackdup_"])
        XCTAssertTrue(Friend.filter(friends, matching: "nobody").isEmpty)
        XCTAssertEqual(User.filter(friends.map(\.user), matching: "dup").map(\.userName), ["Jackdup_"])
    }

    // MARK: - FriendPager & CheckInOptions

    private func makeFriend(_ id: Int, name: String? = nil) -> Friend {
        let n = name ?? "user\(id)"
        return Friend(user: User(id: id, userName: n, firstName: "First\(id)", lastName: "Last\(id)", avatar: nil))
    }

    @MainActor
    func testPagerFetchesMultiplePagesAndStopsAtFound() async {
        // Server caps each page at 25 items even if asked for 50, with found = 60 across 3 pages.
        let all = (1...60).map { makeFriend($0) }
        var offsets: [Int] = []
        var progressCounts: [Int] = []

        let result = await FriendPager.fetchAll(pageSize: 50, fetch: { offset, _ in
            offsets.append(offset)
            let slice = Array(all.dropFirst(offset).prefix(25))
            return FriendPage(friends: slice, found: 60)
        }, onProgress: { partial in
            progressCounts.append(partial.count)
        })

        XCTAssertTrue(result.isComplete)
        XCTAssertNil(result.error)
        XCTAssertEqual(result.found, 60)
        XCTAssertEqual(result.friends.map(\.id), Array(1...60))
        XCTAssertEqual(offsets, [0, 25, 50])
        XCTAssertEqual(progressCounts, [25, 50, 60])
    }

    @MainActor
    func testPagerStopsOnEmptyPageWhenFoundIsMissingOrHigh() async {
        let all = (1...30).map { makeFriend($0) }
        var offsets: [Int] = []

        let result = await FriendPager.fetchAll(pageSize: 25, fetch: { offset, limit in
            offsets.append(offset)
            let slice = Array(all.dropFirst(offset).prefix(limit))
            return FriendPage(friends: slice, found: nil)
        })

        XCTAssertTrue(result.isComplete)
        XCTAssertEqual(result.friends.map(\.id), Array(1...30))
        XCTAssertEqual(offsets, [0, 25, 30])
    }

    @MainActor
    func testPagerStopsWhenPageContainsOnlyDuplicates() async {
        let stuck = (1...5).map { makeFriend($0) }
        var calls = 0

        let result = await FriendPager.fetchAll(pageSize: 25, fetch: { _, _ in
            calls += 1
            return FriendPage(friends: stuck, found: 100)
        })

        XCTAssertTrue(result.isComplete)
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(result.friends.map(\.id), Array(1...5))
    }

    @MainActor
    func testPagerReturnsPartialFriendsOnMidFlightError() async {
        let all = (1...50).map { makeFriend($0) }

        let result = await FriendPager.fetchAll(pageSize: 25, fetch: { offset, limit in
            if offset > 0 { throw APIError.http(503) }
            return FriendPage(friends: Array(all.prefix(limit)), found: 50)
        })

        XCTAssertFalse(result.isComplete)
        XCTAssertNotNil(result.error)
        XCTAssertEqual(result.friends.map(\.id), Array(1...25))
    }

    @MainActor
    func testStorePreservesCachedFriendsWhenLaterNetworkPageFails() async {
        let cachedAll = (1...40).map { makeFriend($0) }
        // Page 1 on the network has a brand-new friend (id 99) plus 1..24; page 2 fails.
        let networkPage1 = [makeFriend(99)] + (1...24).map { makeFriend($0) }

        let store = CheckInOptions(
            cachedPage: { offset, limit in
                let slice = Array(cachedAll.dropFirst(offset).prefix(limit))
                if slice.isEmpty { throw FriendPager.CacheMiss() }
                return FriendPage(friends: slice, found: 40)
            },
            networkPage: { offset, _ in
                if offset == 0 { return FriendPage(friends: networkPage1, found: 41) }
                throw APIError.http(500)
            }
        )

        await store.reloadFriends()

        // Must keep all 40 cached friends AND include the new friend from page 1 (41 total).
        XCTAssertEqual(store.friends.count, 41)
        XCTAssertTrue(store.friends.contains { $0.id == 99 })
        XCTAssertTrue(store.friends.contains { $0.id == 40 })
        XCTAssertNil(store.friendsError)
    }

    @MainActor
    func testStorePreservesCachedFriendsWhenFirstNetworkPageFails() async {
        let cachedAll = (1...30).map { makeFriend($0) }

        let store = CheckInOptions(
            cachedPage: { offset, limit in
                let slice = Array(cachedAll.dropFirst(offset).prefix(limit))
                if slice.isEmpty { throw FriendPager.CacheMiss() }
                return FriendPage(friends: slice, found: 30)
            },
            networkPage: { _, _ in
                throw APIError.http(500)
            }
        )

        await store.reloadFriends()

        XCTAssertEqual(store.friends.map(\.id), Array(1...30))
        XCTAssertNil(store.friendsError)
    }

    @MainActor
    func testStoreReplacesCachedListWhenFullMultiPageFetchCompletes() async {
        let cachedAll = (1...30).map { makeFriend($0) }
        // Friend 30 was unfriended; network now has 1...29 across two pages.
        let freshAll = (1...29).map { makeFriend($0) }

        let store = CheckInOptions(
            cachedPage: { offset, limit in
                let slice = Array(cachedAll.dropFirst(offset).prefix(limit))
                if slice.isEmpty { throw FriendPager.CacheMiss() }
                return FriendPage(friends: slice, found: 30)
            },
            networkPage: { offset, limit in
                let slice = Array(freshAll.dropFirst(offset).prefix(limit))
                return FriendPage(friends: slice, found: 29)
            }
        )

        await store.reloadFriends()

        XCTAssertEqual(store.friends.map(\.id), Array(1...29))
    }

    // Sample from docs/API.md for POST /v4/friend/request/{id}.
    func testFollowResponseIsWordedAsFollowing() throws {
        let json = """
        {"meta":{"code":200},"response":{"result":"success","request_type":"follow","friendship_type":"follow",
         "target_user":{"uid":8867567,"user_name":"KicksBrewing","first_name":"Jane","last_name":"Doe"}}}
        """
        let r = try UntappdAPI.decode(FriendRequestResult.self, from: Data(json.utf8))
        XCTAssertTrue(r.isFollow)
        XCTAssertEqual(r.confirmation, "Following")
    }

    func testNonFollowResponseIsAFriendRequest() throws {
        // Only "follow" was captured; the friend value here is an assumption.
        let r = try UntappdAPI.decode(FriendRequestResult.self, from: Data("""
        {"meta":{"code":200},"response":{"result":"success","request_type":"friend"}}
        """.utf8))
        XCTAssertEqual(r.confirmation, "Friend request sent")
    }

    func testSendRequestIsAPostToTheUserId() {
        let r = APIRequest.sendFriendRequest(42)
        XCTAssertEqual(r.method, .post)
        XCTAssertEqual(r.path, "/v4/friend/request/42")
    }

    func testUsernameNormalizing() {
        XCTAssertEqual(Friends.normalized("  @Jackdup_ "), "Jackdup_")
        XCTAssertNil(Friends.normalized("   "))
        XCTAssertNil(Friends.normalized("a/b"))
        XCTAssertNil(Friends.normalized("two words"))
    }

    func testAddStatus() throws {
        func profile(_ name: String, id: Int, rel: String?) throws -> UserInfo.Profile {
            let r = rel.map { "\"relationship\":\"\($0)\"," } ?? ""
            let info = try UntappdAPI.decode(UserInfo.self, from: Data("""
            {"meta":{"code":200},"response":{"user":{"uid":\(id),\(r)"user_name":"\(name)"}}}
            """.utf8))
            return info.user!
        }
        let ids: Set<Int> = [2]
        XCTAssertEqual(Friends.status(of: try profile("Me", id: 1, rel: nil), me: "me", friendIDs: ids), .you)
        XCTAssertEqual(Friends.status(of: try profile("a", id: 2, rel: nil), me: "me", friendIDs: ids), .friends)
        XCTAssertEqual(Friends.status(of: try profile("b", id: 3, rel: "friends"), me: "me", friendIDs: ids), .friends)
        XCTAssertEqual(Friends.status(of: try profile("c", id: 4, rel: "follow"), me: "me", friendIDs: ids), .following)
        XCTAssertEqual(Friends.status(of: try profile("d", id: 5, rel: "none"), me: "me", friendIDs: ids), .canAdd)
    }

    func testNotFoundErrors() {
        XCTAssertTrue(Friends.isNotFound(.server(code: 404, detail: nil)))
        XCTAssertTrue(Friends.isNotFound(.http(404)))
        XCTAssertFalse(Friends.isNotFound(.http(500)))
        XCTAssertFalse(Friends.isNotFound(.unauthorized))
    }
}
