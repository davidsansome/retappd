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
        // Any value but "follow" reads as a friend request ("request" is what the server sends).
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

    // Sample from probing the live API on 2026-11-18: a private, non-friend account.
    func testPersonRequestResponseIsAFriendRequest() throws {
        let r = try UntappdAPI.decode(FriendRequestResult.self, from: Data("""
        {"meta":{"code":200},"response":{"result":"success","request_type":"request","friendship_type":"friend",
         "target_user":{"uid":13425056,"user_name":"retappd-test-2","is_private":1,"contact":[]}}}
        """.utf8))
        XCTAssertFalse(r.isFollow)
        XCTAssertEqual(r.requestType, "request")
        XCTAssertEqual(r.confirmation, "Friend request sent")
    }

    func testRemoveAndAcceptRequestsArePostsToTheUserId() {
        let remove = APIRequest.removeFriend(42)
        XCTAssertEqual(remove.method, .post)
        XCTAssertEqual(remove.path, "/v4/friend/remove/42")
        let accept = APIRequest.acceptFriendRequest(7)
        XCTAssertEqual(accept.method, .post)
        XCTAssertEqual(accept.path, "/v4/friend/accept/7")
        let req = UntappdAPI.shared.urlRequest(remove)
        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertNil(req.httpBody.flatMap { $0.isEmpty ? nil : $0 })
    }

    func testDecodesRemoveResponse() throws {
        let r = try UntappdAPI.decode(FriendActionResult.self, from: Data("""
        {"meta":{"code":200},"response":{"result":"success"}}
        """.utf8))
        XCTAssertEqual(r.result, "success")
    }

    @MainActor
    func testRemoveFriendTakesThemOutOfEveryListAndClearsCaches() async throws {
        let all = (1...3).map { makeFriend($0) }
        var removed: [Int] = []
        var cleared = 0
        let store = CheckInOptions(
            cachedPage: { _, _ in throw FriendPager.CacheMiss() },
            networkPage: { offset, limit in FriendPage(friends: Array(all.dropFirst(offset).prefix(limit)), found: 3) },
            sendRemoval: { removed.append($0) },
            clearFriendCaches: { cleared += 1 }
        )
        await store.reloadFriends()

        try await store.removeFriend(all[1])

        XCTAssertEqual(removed, [2])
        XCTAssertEqual(store.friendships.map(\.id), [1, 3])
        XCTAssertEqual(store.friends.map(\.id), [1, 3])
        XCTAssertFalse(store.allFriends.contains { $0.id == 2 })
        XCTAssertEqual(store.friendRemovals, 1)
        XCTAssertEqual(cleared, 1)
    }

    @MainActor
    func testFailedRemovalPutsTheFriendBackInPlace() async {
        let all = (1...3).map { makeFriend($0) }
        var cleared = 0
        let store = CheckInOptions(
            cachedPage: { _, _ in throw FriendPager.CacheMiss() },
            networkPage: { offset, limit in FriendPage(friends: Array(all.dropFirst(offset).prefix(limit)), found: 3) },
            sendRemoval: { _ in throw APIError.http(500) },
            clearFriendCaches: { cleared += 1 }
        )
        await store.reloadFriends()

        do {
            try await store.removeFriend(all[1])
            XCTFail("expected the removal to fail")
        } catch {}

        XCTAssertEqual(store.friendships.map(\.id), [1, 2, 3])
        XCTAssertEqual(store.friends.map(\.id), [1, 2, 3])
        XCTAssertEqual(store.friendRemovals, 0)
        XCTAssertEqual(cleared, 0)
    }

    func testPendingRelationshipsCannotBeRequestedAgain() throws {
        func profile(_ rel: String) throws -> UserInfo.Profile {
            try UntappdAPI.decode(UserInfo.self, from: Data("""
            {"meta":{"code":200},"response":{"user":{"uid":9,"relationship":"\(rel)","user_name":"x"}}}
            """.utf8)).user!
        }
        XCTAssertEqual(Friends.status(of: try profile("pending_them"), me: "me", friendIDs: []), .requestSent)
        XCTAssertEqual(Friends.status(of: try profile("pending_you"), me: "me", friendIDs: []), .requestReceived)
        XCTAssertFalse(Friends.Status.requestSent.message.isEmpty)
        XCTAssertFalse(Friends.Status.requestReceived.message.isEmpty)
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

    // MARK: - Removal races

    /// Lets a test hold an async call until it says so, then release it or make it fail.
    @MainActor
    private final class Gate {
        private var waiter: CheckedContinuation<Void, Error>?
        var isWaiting: Bool { waiter != nil }

        func wait() async throws {
            try await withCheckedThrowingContinuation { waiter = $0 }
        }
        func release() { waiter?.resume(); waiter = nil }
        func fail() { waiter?.resume(throwing: APIError.http(500)); waiter = nil }
        func untilWaiting() async {
            for _ in 0..<2000 where !isWaiting { await Task.yield() }
        }
    }

    @MainActor
    private func loadedStore(
        _ friends: [Friend], recent: [User] = [],
        network: FriendPager.Fetch? = nil,
        sendRemoval: @escaping (Int) async throws -> Void = { _ in },
        cleared: @escaping () -> Void = {}
    ) async -> CheckInOptions {
        let store = CheckInOptions(
            recentlyTagged: recent,
            cachedPage: { _, _ in throw FriendPager.CacheMiss() },
            networkPage: network ?? { offset, limit in
                FriendPage(friends: Array(friends.dropFirst(offset).prefix(limit)), found: friends.count)
            },
            sendRemoval: sendRemoval,
            clearFriendCaches: { cleared() }
        )
        await store.reloadFriends()
        return store
    }

    @MainActor
    func testFailedRemovalDoesNotBringBackAnotherFriendToTagging() async throws {
        let all = (1...3).map { makeFriend($0) }
        let gate = Gate()
        let store = await loadedStore(all, recent: [all[0].user, all[1].user], sendRemoval: { id in
            if id == 1 { try await gate.wait() }
        })

        let a = Task { try await store.removeFriend(all[0]) }  // fails later
        await gate.untilWaiting()
        try await store.removeFriend(all[1])  // succeeds meanwhile
        gate.fail()
        _ = try? await a.value

        XCTAssertEqual(store.friendships.map(\.id), [1, 3])
        XCTAssertEqual(store.recentlyTagged.map(\.id), [1])
        XCTAssertFalse(store.allFriends.contains { $0.id == 2 })
        XCTAssertFalse(store.orderedFriends.contains { $0.id == 2 })
        XCTAssertFalse(store.suggestedFriends().contains { $0.id == 2 })
    }

    @MainActor
    func testSuggestedFriendsAreRecentlyTaggedThenNearbyThenTheRest() async throws {
        let all = (1...12).map { makeFriend($0) }
        let u = all.map(\.user)
        let store = await loadedStore(all, recent: [u[2], u[0]])

        // Nearby: one also recently tagged (shown once, as recent), a duplicate, then others.
        let nearby = [u[0], u[6], u[6], u[4]]
        XCTAssertEqual(store.suggestedFriends(limit: 5, nearby: nearby).map(\.id), [3, 1, 7, 5, 10])
        // Nobody nearby: topped up alphabetically, as before.
        XCTAssertEqual(store.suggestedFriends(limit: 3).map(\.id), [3, 1, 10])
        // Up to `limit` of each.
        let many = Array(u[3...10])
        XCTAssertEqual(store.suggestedFriends(limit: 2, nearby: many).map(\.id), [3, 1, 4, 5])

        try await store.removeFriend(all[6])
        XCTAssertFalse(store.suggestedFriends(nearby: nearby).contains { $0.id == 7 })
    }

    @MainActor
    func testLoadStartedBeforeARemovalCannotBringTheFriendBack() async throws {
        let all = (1...3).map { makeFriend($0) }
        let gate = Gate()
        var gateNext = false
        let store = await loadedStore(all, network: { offset, limit in
            if gateNext { try await gate.wait() }
            return FriendPage(friends: Array(all.dropFirst(offset).prefix(limit)), found: 3)  // stale: still lists 2
        })

        gateNext = true
        let load = Task { await store.reloadFriends() }
        await gate.untilWaiting()
        try await store.removeFriend(all[1])
        gate.release()
        await load.value

        XCTAssertEqual(store.friendships.map(\.id), [1, 3])
        XCTAssertEqual(store.friends.map(\.id), [1, 3])
    }

    @MainActor
    func testLoadThatStartedAfterARemovalClearsTheTombstone() async throws {
        var server = (1...3).map { makeFriend($0) }
        let store = await loadedStore(server, network: { offset, limit in
            FriendPage(friends: Array(server.dropFirst(offset).prefix(limit)), found: server.count)
        })
        try await store.removeFriend(server[1])
        server.remove(at: 1)
        await store.reloadFriends()
        XCTAssertEqual(store.friendships.map(\.id), [1, 3])

        // They can be friends again (a new request accepted); nothing keeps hiding them.
        server.insert(makeFriend(2), at: 0)
        await store.reloadFriends()
        XCTAssertEqual(store.friendships.map(\.id), [2, 1, 3])
    }

    @MainActor
    func testLoadStraddlingARemovalClearsCachesAgain() async throws {
        let all = (1...3).map { makeFriend($0) }
        let gate = Gate()
        var gateNext = false
        var cleared = 0
        let store = await loadedStore(all, network: { offset, limit in
            if gateNext { try await gate.wait() }
            return FriendPage(friends: Array(all.dropFirst(offset).prefix(limit)), found: 3)
        }, cleared: { cleared += 1 })

        gateNext = true
        let load = Task { await store.reloadFriends() }
        await gate.untilWaiting()
        try await store.removeFriend(all[1])
        XCTAssertEqual(cleared, 1)
        gate.release()
        await load.value

        XCTAssertEqual(cleared, 2)  // pages the load cached may predate the removal
    }

    @MainActor
    func testFailedRemovalAfterTheListChangedRestoresThemNextToTheirNeighbour() async throws {
        let all = (1...3).map { makeFriend($0) }
        var server = all
        let gate = Gate()
        let store = await loadedStore(all, network: { offset, limit in
            FriendPage(friends: Array(server.dropFirst(offset).prefix(limit)), found: server.count)
        }, sendRemoval: { _ in try await gate.wait() })

        let removal = Task { try await store.removeFriend(all[1]) }
        await gate.untilWaiting()
        server.insert(makeFriend(99), at: 0)  // a new friend arrives while the call is out
        await store.reloadFriends()
        XCTAssertEqual(store.friendships.map(\.id), [99, 1, 3])
        gate.fail()
        _ = try? await removal.value

        XCTAssertEqual(store.friendships.map(\.id), [99, 1, 2, 3])
        XCTAssertEqual(store.friends.map(\.id), [99, 1, 2, 3])
    }

    func testProfileCountIsNotOverwrittenByAStaleFetch() {
        // A fetch began with 0 removals and answers 5 after one friend was removed.
        XCTAssertEqual(ProfileFriendCount.adjusted(5, changeAtStart: 0, changeNow: -1), 4)
        // One that began after the removal already reflects it.
        XCTAssertEqual(ProfileFriendCount.adjusted(4, changeAtStart: -1, changeNow: -1), 4)
        XCTAssertEqual(ProfileFriendCount.adjusted(0, changeAtStart: 0, changeNow: -2), 0)
        XCTAssertNil(ProfileFriendCount.adjusted(nil, changeAtStart: 0, changeNow: -1))
    }

    func testClearCachesWalksTheCachedPagesAndDropsRecentlyTagged() async throws {
        func page(_ ids: [Int]) -> Data {
            let items = ids.map { #"{"created_at":"Sat, 04 Jul 2026 05:10:03 +0000","user":{"uid":\#($0),"user_name":"u\#($0)"}}"# }
            return Data(#"{"meta":{"code":200},"response":{"found":3,"items":[\#(items.joined(separator: ","))]}}"#.utf8)
        }
        let cache = ResponseCache.shared
        let keys = [APIRequest.friends(offset: 0), .friends(offset: 2), .recentlyTagged].map(\.cacheKey)
        await cache.store(page([1, 2]), for: keys[0])
        await cache.store(page([3]), for: keys[1])  // offsets advance by what each page held
        await cache.store(Data(#"{"meta":{"code":200},"response":{"items":[]}}"#.utf8), for: keys[2])

        await FriendPager.clearCaches()

        for key in keys {
            let data = await cache.data(for: key)
            XCTAssertNil(data, key)
        }
    }

    @MainActor
    func testResetForSignOutClearsStateAndIgnoresInFlightLoad() async throws {
        let all = (1...3).map { makeFriend($0) }
        let request = makeFriend(99)
        let gate = Gate()
        var gateNext = false

        let store = CheckInOptions(
            recentlyTagged: [all[0].user],
            cachedPage: { _, _ in throw FriendPager.CacheMiss() },
            networkPage: { offset, limit in
                if gateNext { try await gate.wait() }
                return FriendPage(friends: Array(all.dropFirst(offset).prefix(limit)), found: all.count)
            },
            sendRemoval: { _ in },
            clearFriendCaches: {},
            fetchRequests: { _ in [request] },
            sendAnswer: { _, _ in },
            clearRequestsCache: {}
        )

        await store.reloadFriends()
        await store.loadRequests()
        try await store.removeFriend(all[1])
        XCTAssertEqual(store.friends.count, 2)
        XCTAssertEqual(store.requests.count, 1)
        XCTAssertEqual(store.friendRemovals, 1)
        XCTAssertEqual(store.friendCountChange, -1)

        // Start a reload that stays in flight across sign-out.
        gateNext = true
        let inFlight = Task { await store.reloadFriends() }
        await gate.untilWaiting()

        store.resetForSignOut()

        XCTAssertTrue(store.friends.isEmpty)
        XCTAssertTrue(store.friendships.isEmpty)
        XCTAssertTrue(store.recentlyTagged.isEmpty)
        XCTAssertTrue(store.recentVenues.isEmpty)
        XCTAssertTrue(store.recentShops.isEmpty)
        XCTAssertTrue(store.requests.isEmpty)
        XCTAssertNil(store.friendsError)
        XCTAssertEqual(store.friendRemovals, 0)
        XCTAssertEqual(store.friendCountChange, 0)
        XCTAssertFalse(store.loadingFriends)

        // Even when the cancelled/stale load finishes, it must not leak old friends back in.
        gate.release()
        await inFlight.value

        XCTAssertTrue(store.friends.isEmpty)
        XCTAssertTrue(store.friendships.isEmpty)
        XCTAssertNil(store.friendsError)

        // A new account signing in can load friends again.
        gateNext = false
        await store.reloadFriends()
        XCTAssertEqual(store.friends.map(\.id), [1, 2, 3])
    }
}
