import XCTest
@testable import Retappd

final class FriendRequestTests: XCTestCase {
    // MARK: - Requests and decoding

    func testPendingAndRejectRequests() {
        let pending = APIRequest.pendingFriendRequests
        XCTAssertEqual(pending.method, .get)
        XCTAssertEqual(pending.path, "/v4/user/pending")
        let reject = APIRequest.rejectFriendRequest(13425055)
        XCTAssertEqual(reject.method, .post)
        XCTAssertEqual(reject.path, "/v4/friend/reject/13425055")
        let req = UntappdAPI.shared.urlRequest(reject)
        XCTAssertEqual(req.httpMethod, "POST")
    }

    // Sample from the live API, 2026-11-19.
    func testDecodesPendingList() throws {
        let list = try UntappdAPI.decode(PendingRequestList.self, from: Data("""
        {"meta":{"code":200},"response":{"count":1,"items":[{"created_at":"Wed, 18 Nov 2026 13:54:38 +0000",
         "user":{"uid":13425055,"user_name":"retappd-test-1","first_name":"Retappd","last_name":"One",
                 "user_avatar":"https://x/a.jpg","location":"","bio":"","is_supporter":0,"flair":null}}]}}
        """.utf8))
        XCTAssertEqual(list.requests.count, 1)
        XCTAssertEqual(list.requests[0].id, 13425055)
        XCTAssertEqual(list.requests[0].user.userName, "retappd-test-1")
        XCTAssertNil(list.requests[0].location)
        XCTAssertNotNil(list.requests[0].createdAt)
    }

    func testDecodesRejectResponse() throws {
        let r = try UntappdAPI.decode(FriendRequestResult.self, from: Data("""
        {"meta":{"code":200},"response":{"result":"success","request_type":"reject","friendship_type":"friend",
         "target_user":{"uid":13425055,"user_name":"retappd-test-1"}}}
        """.utf8))
        XCTAssertEqual(r.requestType, "reject")
        XCTAssertEqual(r.friendshipType, "friend")
    }

    // MARK: - Add sheet

    private func profile(_ rel: String) throws -> UserInfo.Profile {
        try UntappdAPI.decode(UserInfo.self, from: Data("""
        {"meta":{"code":200},"response":{"user":{"uid":9,"relationship":"\(rel)","user_name":"x"}}}
        """.utf8)).user!
    }

    func testIgnoreAndPendingYouOfferAccept() throws {
        let ignored = Friends.status(of: try profile("ignore"), me: "me", friendIDs: [])
        XCTAssertEqual(ignored, .requestRejected)
        XCTAssertEqual(ignored.message, "You rejected their friend request.")
        XCTAssertTrue(ignored.canAccept)
        let received = Friends.status(of: try profile("pending_you"), me: "me", friendIDs: [])
        XCTAssertEqual(received, .requestReceived)
        XCTAssertTrue(received.canAccept)
        XCTAssertFalse(Friends.Status.requestSent.canAccept)
        XCTAssertFalse(Friends.Status.canAdd.canAccept)
        // Once accepted they are in the friends list, whatever the stale relationship says.
        XCTAssertEqual(Friends.status(of: try profile("ignore"), me: "me", friendIDs: [9]), .friends)
    }

    func testPendingApprovalErrorIsFriendly() {
        let e = APIError.server(code: 500, detail: "This request is pending the user's approval.")
        XCTAssertEqual(Friends.sendErrorMessage(e), "Your request is still waiting for them.")
        XCTAssertEqual(Friends.sendErrorMessage(APIError.server(code: 500, detail: "Nope.")), "Nope.")
        XCTAssertEqual(Friends.sendErrorMessage(APIError.http(500)), APIError.http(500).localizedDescription)
    }

    // MARK: - Store

    @MainActor
    private final class Gate {
        private var waiter: CheckedContinuation<Void, Error>?
        var isWaiting: Bool { waiter != nil }
        func wait() async throws { try await withCheckedThrowingContinuation { waiter = $0 } }
        func release() { waiter?.resume(); waiter = nil }
        func fail() { waiter?.resume(throwing: APIError.http(500)); waiter = nil }
        func untilWaiting() async { for _ in 0..<2000 where !isWaiting { await Task.yield() } }
    }

    private func person(_ id: Int) -> Friend {
        Friend(user: User(id: id, userName: "user\(id)", firstName: "First\(id)", lastName: "Last\(id)", avatar: nil),
               createdAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(id)))
    }

    /// A store whose server has `friends` and `pending`, loaded once. `answer` handles accept and
    /// reject calls; `network` overrides the friends pages and `pendingFetch` the requests load.
    @MainActor
    private func loadedStore(
        friends: [Friend] = [], pending: [Friend],
        network: FriendPager.Fetch? = nil,
        pendingFetch: CheckInOptions.RequestsFetch? = nil,
        answer: @escaping (Int, CheckInOptions.RequestAnswer) async throws -> Void = { _, _ in },
        removal: @escaping (Int) async throws -> Void = { _ in },
        cleared: @escaping () -> Void = {}
    ) async -> CheckInOptions {
        let store = CheckInOptions(
            cachedPage: { _, _ in throw FriendPager.CacheMiss() },
            networkPage: network ?? { offset, limit in
                FriendPage(friends: Array(friends.dropFirst(offset).prefix(limit)), found: friends.count)
            },
            sendRemoval: removal,
            clearFriendCaches: { cleared() },
            fetchRequests: pendingFetch ?? { _ in pending },
            sendAnswer: answer,
            clearRequestsCache: {}
        )
        await store.reloadFriends()
        await store.loadRequests()
        return store
    }

    @MainActor
    func testLoadsRequests() async {
        let store = await loadedStore(pending: [person(1), person(2)])
        XCTAssertEqual(store.requests.map(\.id), [1, 2])
    }

    @MainActor
    func testAcceptMakesThemAFriendAtOnceAndForTagging() async throws {
        var answered: [Int] = []
        var cleared = 0
        let store = await loadedStore(
            friends: [person(10), person(11)], pending: [person(1), person(2)],
            answer: { id, kind in XCTAssertEqual(kind, .accept); answered.append(id) },
            cleared: { cleared += 1 })

        try await store.acceptRequest(person(1))

        XCTAssertEqual(answered, [1])
        XCTAssertEqual(store.requests.map(\.id), [2])
        XCTAssertEqual(store.friendships.first?.id, 1)  // newest friendship leads
        XCTAssertEqual(Set(store.friendships.map(\.id)), [1, 10, 11])
        XCTAssertTrue(store.friends.contains { $0.id == 1 })
        XCTAssertTrue(store.allFriends.contains { $0.id == 1 })
        XCTAssertEqual(store.friendCountChange, 1)
        XCTAssertEqual(store.friendRemovals, 0)
        XCTAssertEqual(cleared, 1)
    }

    @MainActor
    func testAcceptIsVisibleWhileTheCallIsInFlight() async throws {
        let gate = Gate()
        let store = await loadedStore(friends: [person(10)], pending: [person(1)], answer: { _, _ in try await gate.wait() })
        let accept = Task { try await store.acceptRequest(person(1)) }
        await gate.untilWaiting()
        XCTAssertTrue(store.requests.isEmpty)
        XCTAssertEqual(store.friendships.map(\.id), [1, 10])
        gate.release()
        try await accept.value
    }

    @MainActor
    func testRejectTakesTheRequestAwayWithoutAddingAFriend() async throws {
        var kinds: [CheckInOptions.RequestAnswer] = []
        let store = await loadedStore(friends: [person(10)], pending: [person(1), person(2)],
                                      answer: { _, k in kinds.append(k) })
        try await store.rejectRequest(person(1))
        XCTAssertEqual(kinds, [.reject])
        XCTAssertEqual(store.requests.map(\.id), [2])
        XCTAssertEqual(store.friendships.map(\.id), [10])
        XCTAssertEqual(store.friendCountChange, 0)
    }

    @MainActor
    func testFailedRejectRestoresOnlyThatRequest() async throws {
        let gate = Gate()
        let store = await loadedStore(pending: [person(1), person(2), person(3)], answer: { id, _ in
            if id == 1 { try await gate.wait() }
        })
        let failing = Task { try await store.rejectRequest(person(1)) }
        await gate.untilWaiting()
        try await store.rejectRequest(person(2))  // succeeds meanwhile
        XCTAssertEqual(store.requests.map(\.id), [3])
        gate.fail()
        do { try await failing.value; XCTFail("expected a failure") } catch {}

        XCTAssertEqual(store.requests.map(\.id), [1, 3])  // 1 back in place; 2 stays gone
    }

    @MainActor
    func testFailedAcceptRestoresTheRequestAndRemovesTheFriend() async {
        var cleared = 0
        let store = await loadedStore(
            friends: [person(10)], pending: [person(1), person(2)],
            answer: { _, _ in throw APIError.http(500) }, cleared: { cleared += 1 })
        do { try await store.acceptRequest(person(1)); XCTFail("expected a failure") } catch {}
        XCTAssertEqual(store.requests.map(\.id), [1, 2])
        XCTAssertEqual(store.friendships.map(\.id), [10])
        XCTAssertFalse(store.allFriends.contains { $0.id == 1 })
        XCTAssertEqual(store.friendCountChange, 0)
        XCTAssertEqual(cleared, 0)
    }

    @MainActor
    func testPendingLoadStartedBeforeAnAnswerCannotBringTheRequestBack() async throws {
        let gate = Gate()
        var stale = false
        let store = await loadedStore(pending: [person(1), person(2)], pendingFetch: { _ in
            if stale { try await gate.wait() }
            return [self.person(1), self.person(2)]  // stale: still lists 1
        })
        stale = true
        let load = Task { await store.loadRequests() }
        await gate.untilWaiting()
        try await store.rejectRequest(person(1))
        gate.release()
        await load.value
        XCTAssertEqual(store.requests.map(\.id), [2])

        // A load that starts afterwards trusts the server again (they might ask again).
        stale = false
        await store.loadRequests()
        XCTAssertEqual(store.requests.map(\.id), [1, 2])
    }

    @MainActor
    func testCachedRequestsAreFilteredToo() async throws {
        let gate = Gate()
        var gated = false
        let store = await loadedStore(pending: [person(1)], pendingFetch: { onCached in
            if gated { try await gate.wait() }
            onCached([self.person(1)])
            return [self.person(1)]
        })
        gated = true
        let load = Task { await store.loadRequests() }
        await gate.untilWaiting()
        try await store.acceptRequest(person(1))
        gate.release()
        await load.value
        XCTAssertTrue(store.requests.isEmpty)
    }

    @MainActor
    func testFriendsLoadStartedBeforeAnAcceptKeepsTheNewFriend() async throws {
        let gate = Gate()
        var gateNext = false
        let server = [person(10), person(11)]
        let store = await loadedStore(friends: server, pending: [person(1)], network: { offset, limit in
            if gateNext { try await gate.wait() }
            return FriendPage(friends: Array(server.dropFirst(offset).prefix(limit)), found: 2)  // stale: no 1
        })
        gateNext = true
        let load = Task { await store.reloadFriends() }
        await gate.untilWaiting()
        try await store.acceptRequest(person(1))
        gate.release()
        await load.value

        XCTAssertEqual(Set(store.friendships.map(\.id)), [1, 10, 11])
        XCTAssertEqual(Set(store.friends.map(\.id)), [1, 10, 11])

        // Once a load that started after the accept lists them, the server's copy takes over.
        gateNext = false
        await store.reloadFriends()
        XCTAssertEqual(Set(store.friendships.map(\.id)), [10, 11])
    }

    @MainActor
    func testFailedAcceptKeepsAnEarlierRemovalHidden() async throws {
        let gate = Gate()
        var gateNext = false
        let server = [person(10), person(11)]
        let store = await loadedStore(
            friends: server, pending: [],
            network: { offset, limit in
                if gateNext { try await gate.wait() }
                return FriendPage(friends: Array(server.dropFirst(offset).prefix(limit)), found: 2)  // stale: still lists 11
            },
            answer: { _, _ in throw APIError.http(500) })
        gateNext = true
        let load = Task { await store.reloadFriends() }
        await gate.untilWaiting()
        try await store.removeFriend(person(11))
        do { try await store.acceptRequest(person(11)); XCTFail("expected a failure") } catch {}
        gate.release()
        await load.value
        XCTAssertEqual(store.friendships.map(\.id), [10])
    }

    @MainActor
    func testFriendsLoadDuringAFailedAcceptDoesNotKeepTheGhostFriend() async throws {
        let acceptGate = Gate()
        let pageGate = Gate()
        var gateNext = false
        let store = await loadedStore(
            friends: [person(10)], pending: [person(1)],
            network: { offset, _ in
                if gateNext {
                    if offset == 0 {
                        try await pageGate.wait()
                        return FriendPage(friends: [self.person(10)], found: 2)
                    }
                    throw APIError.http(500)  // the load ends incomplete
                }
                return FriendPage(friends: [self.person(10)], found: 1)
            },
            answer: { _, _ in try await acceptGate.wait() })
        let accept = Task { try await store.acceptRequest(person(1)) }
        await acceptGate.untilWaiting()
        gateNext = true
        let load = Task { await store.reloadFriends() }  // starts while 1 is optimistically a friend
        await pageGate.untilWaiting()
        acceptGate.fail()
        _ = try? await accept.value
        pageGate.release()
        await load.value
        XCTAssertFalse(store.friendships.contains { $0.id == 1 })
        XCTAssertFalse(store.friends.contains { $0.id == 1 })
    }

    @MainActor
    func testAcceptingSomeoneNotInTheRequestsListStillAddsThem() async throws {
        // As from the add-friend sheet after a reject: the request isn't in /user/pending.
        let store = await loadedStore(friends: [person(10)], pending: [])
        try await store.acceptRequest(person(5))
        XCTAssertEqual(store.friendships.map(\.id), [5, 10])
    }

    func testProfileCountGoesUpOnAccept() {
        XCTAssertEqual(ProfileFriendCount.adjusted(5, changeAtStart: 0, changeNow: 1), 6)
        XCTAssertEqual(ProfileFriendCount.adjusted(5, changeAtStart: 0, changeNow: -1), 4)
        XCTAssertEqual(ProfileFriendCount.adjusted(6, changeAtStart: 1, changeNow: 1), 6)
        XCTAssertEqual(ProfileFriendCount.adjusted(0, changeAtStart: 0, changeNow: -2), 0)
        XCTAssertNil(ProfileFriendCount.adjusted(nil, changeAtStart: 0, changeNow: 1))
    }
}
