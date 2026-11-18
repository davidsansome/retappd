import XCTest
@testable import Retappd

final class HadBeersTests: XCTestCase {
    // Shaped like the sample for GET /v4/user/user_beer_list?mode=v3 in docs/API.md (bids shortened).
    // `lists` is base64 in the sample; `bids` is plain text.
    private func json(bids: String) -> Data {
        Data("""
        {"meta":{"code":200},"response":{"base64":true,"bids_count":5,"bids":"\(bids)",
         "lists_count":2,"lists":"NDUwNywyMTk5MQ==","es_enabled":true,"bids_limit":1}}
        """.utf8)
    }

    func testDecodesPlainBids() throws {
        let l = try UntappdAPI.decode(UserBeerList.self, from: json(bids: "145448,1425,366973,37235,421462"))
        XCTAssertEqual(l.bids, [145448, 1425, 366973, 37235, 421462])
        XCTAssertEqual(l.count, 5)
        XCTAssertFalse(l.wasBase64)
    }

    func testDecodesBase64Bids() throws {
        let encoded = Data("145448,1425,366973,37235,421462".utf8).base64EncodedString()
        let l = try UntappdAPI.decode(UserBeerList.self, from: json(bids: encoded))
        XCTAssertEqual(l.bids, [145448, 1425, 366973, 37235, 421462])
        XCTAssertTrue(l.wasBase64)
    }

    func testDecodesUnpaddedBase64AndEmpty() throws {
        let encoded = Data("1,22".utf8).base64EncodedString().replacingOccurrences(of: "=", with: "")
        XCTAssertEqual(try UntappdAPI.decode(UserBeerList.self, from: json(bids: encoded)).bids, [1, 22])
        XCTAssertEqual(try UntappdAPI.decode(UserBeerList.self, from: json(bids: "")).bids, [])
    }

    /// What the live server sent for a one-beer account: plain text with a leading comma.
    func testDecodesLiveLeadingComma() throws {
        let l = try UntappdAPI.decode(UserBeerList.self, from: json(bids: ",6755412"))
        XCTAssertEqual(l.bids, [6755412])
    }

    func testRejectsGarbage() {
        XCTAssertThrowsError(try UntappdAPI.decode(UserBeerList.self, from: json(bids: "not*ids!")))
    }

    func testMissingBidsKeyIsRejected() {
        let d = Data(#"{"meta":{"code":200},"response":{"base64":true,"bids_count":10639}}"#.utf8)
        XCTAssertThrowsError(try UntappdAPI.decode(UserBeerList.self, from: d))
        let n = Data(#"{"meta":{"code":200},"response":{"bids":null,"bids_count":3}}"#.utf8)
        XCTAssertThrowsError(try UntappdAPI.decode(UserBeerList.self, from: n))
    }

    // MARK: Store

    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("had-\(UUID().uuidString).json")
    }

    @MainActor private func store(_ url: URL, user: String = "alice",
                                  list: UserBeerList) -> HadBeers {
        HadBeers(url: url, currentUser: { user }, fetchList: { list })
    }

    @MainActor func testFallsBackUntilLoadedThenAuthoritative() async {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let s = store(url, list: UserBeerList(bids: [1, 2, 3], count: 3))
        XCTAssertTrue(s.has(5, fallback: true))
        XCTAssertFalse(s.has(5, fallback: nil))
        s.add(7)
        XCTAssertTrue(s.has(7))
        await s.refresh(force: true)
        XCTAssertTrue(s.isAuthoritative)
        XCTAssertFalse(s.has(7))
        XCTAssertTrue(s.has(1))
        XCTAssertFalse(s.has(5, fallback: true))
    }

    @MainActor func testEmptyListWithPositiveCountIsRejected() async {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let s = store(url, list: UserBeerList(bids: [1, 2], count: 2))
        await s.refresh(force: true)
        XCTAssertEqual(s.ids, [1, 2])
        // A second store sharing the state: empty list but a positive count must not wipe it.
        let bad = HadBeers(url: url, currentUser: { "alice" }, fetchList: { UserBeerList(bids: [], count: 10639) })
        XCTAssertEqual(bad.ids, [1, 2])
        await bad.refresh(force: true)
        XCTAssertEqual(bad.ids, [1, 2])
        XCTAssertTrue(bad.isAuthoritative)
        // An unauthoritative store stays that way too.
        let fresh = store(tempURL(), list: UserBeerList(bids: [], count: 5))
        await fresh.refresh(force: true)
        XCTAssertFalse(fresh.isAuthoritative)
        XCTAssertTrue(fresh.ids.isEmpty)
        // A genuine empty account (count 0) is accepted.
        let none = store(tempURL(), list: UserBeerList(bids: [], count: 0))
        await none.refresh(force: true)
        XCTAssertTrue(none.isAuthoritative)
    }

    @MainActor func testShortListStaysNonAuthoritative() async {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let s = store(url, list: UserBeerList(bids: [1, 2, 3], count: 10))
        await s.refresh(force: true)
        XCTAssertFalse(s.isAuthoritative)
        XCTAssertEqual(s.ids, [1, 2, 3])
        XCTAssertTrue(s.has(1))
        XCTAssertTrue(s.has(9, fallback: true))  // still falls back
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        // Within tolerance (live server counted one extra) is fine.
        let ok = store(tempURL(), list: UserBeerList(bids: [1], count: 2))
        await ok.refresh(force: true)
        XCTAssertTrue(ok.isAuthoritative)
    }

    @MainActor func testSnapshotOfAnotherUserIsIgnored() async {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let a = store(url, user: "alice", list: UserBeerList(bids: [1, 2], count: 2))
        await a.refresh(force: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let again = HadBeers(url: url, currentUser: { "alice" }, fetchList: { UserBeerList(bids: []) })
        XCTAssertEqual(again.ids, [1, 2])
        XCTAssertTrue(again.isAuthoritative)
        let bob = HadBeers(url: url, currentUser: { "bob" }, fetchList: { UserBeerList(bids: []) })
        XCTAssertTrue(bob.ids.isEmpty)
        XCTAssertFalse(bob.isAuthoritative)
    }

    @MainActor func testClearDuringFetchLeavesStoreEmpty() async {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let gate = AsyncStream<Void>.makeStream()
        let s = HadBeers(url: url, currentUser: { "alice" }, fetchList: {
            for await _ in gate.stream { break }
            return UserBeerList(bids: [1, 2, 3], count: 3)
        })
        let refreshing = Task { await s.refresh(force: true) }
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(50))
        s.clear()
        gate.continuation.yield()
        await refreshing.value
        XCTAssertTrue(s.ids.isEmpty)
        XCTAssertFalse(s.isAuthoritative)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    // MARK: Review fixes

    private struct Boom: Error {}

    /// Who's signed in, changeable mid-test and readable from the fetch closure.
    private final class Session: @unchecked Sendable { var user: String? = "alice" }

    /// Fix 1: a failed fetch keeps every tick.
    @MainActor func testFailedFetchKeepsTicks() async {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        await store(url, list: UserBeerList(bids: [1, 2], count: 2)).refresh(force: true)
        let failing = HadBeers(url: url, currentUser: { "alice" }, fetchList: { throw Boom() })
        await failing.refresh(force: true)
        XCTAssertEqual(failing.ids, [1, 2])
        XCTAssertTrue(failing.isAuthoritative)
        let reloaded = HadBeers(url: url, currentUser: { "alice" }, fetchList: { throw Boom() })
        XCTAssertEqual(reloaded.ids, [1, 2])
    }

    /// Fix 1: an empty list with no count at all is as suspect as one with a positive count.
    @MainActor func testEmptyListWithoutCountIsRejected() async {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        await store(url, list: UserBeerList(bids: [1, 2], count: 2)).refresh(force: true)
        let s = store(url, list: UserBeerList(bids: []))
        await s.refresh(force: true)
        XCTAssertEqual(s.ids, [1, 2])
    }

    /// Fix 2: a short list on an authoritative store adds ticks but removes none.
    @MainActor func testPartialListOnlyAdds() async {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        await store(url, list: UserBeerList(bids: [1, 2, 3, 4, 5], count: 5)).refresh(force: true)
        let s = store(url, list: UserBeerList(bids: [1, 9], count: 6))
        await s.refresh(force: true)
        XCTAssertEqual(s.ids, [1, 2, 3, 4, 5, 9])
        XCTAssertTrue(s.isAuthoritative)
        // Persisted as the superset.
        let reloaded = store(url, list: UserBeerList(bids: []))
        XCTAssertEqual(reloaded.ids, [1, 2, 3, 4, 5, 9])
    }

    /// Fix 2: without `bids_count` there's no telling the list is complete, so it only adds.
    @MainActor func testListWithoutCountOnlyAdds() async {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        await store(url, list: UserBeerList(bids: [1, 2, 3], count: 3)).refresh(force: true)
        let s = store(url, list: UserBeerList(bids: [3, 4]))
        await s.refresh(force: true)
        XCTAssertEqual(s.ids, [1, 2, 3, 4])
        let fresh = store(tempURL(), list: UserBeerList(bids: [3, 4]))
        await fresh.refresh(force: true)
        XCTAssertFalse(fresh.isAuthoritative)
        XCTAssertTrue(fresh.has(8, fallback: true))
    }

    /// Fix 3: a sync that finishes after a switch to another account (even without `clear()`) is dropped.
    @MainActor func testFetchFinishingAfterAccountSwitchIsDropped() async {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let session = Session()
        let gate = AsyncStream<Void>.makeStream()
        let s = HadBeers(url: url, currentUser: { session.user }, fetchList: {
            for await _ in gate.stream { break }
            return UserBeerList(bids: [1, 2, 3], count: 3)
        })
        let refreshing = Task { await s.refresh(force: true) }
        try? await Task.sleep(for: .milliseconds(50))
        session.user = "bob"
        gate.continuation.yield()
        await refreshing.value
        XCTAssertTrue(s.ids.isEmpty)
        XCTAssertFalse(s.isAuthoritative)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    /// Fix 3: sign out and straight back in to another account mid-sync: the old result is dropped
    /// and the new account's own sync still runs and lands.
    @MainActor func testSignOutAndInMidFetchKeepsOnlyNewAccount() async {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let session = Session()
        let gate = AsyncStream<Void>.makeStream()
        let s = HadBeers(url: url, currentUser: { session.user }, fetchList: {
            if session.user == "alice" {
                for await _ in gate.stream { break }
                return UserBeerList(bids: [1, 2, 3], count: 3)
            }
            return UserBeerList(bids: [7], count: 1)
        })
        let aliceSync = Task { await s.refresh(force: true) }
        try? await Task.sleep(for: .milliseconds(50))
        s.clear()
        session.user = "bob"
        await s.refresh(force: true)
        XCTAssertEqual(s.ids, [7])
        gate.continuation.yield()
        await aliceSync.value
        XCTAssertEqual(s.ids, [7])
        XCTAssertTrue(s.isAuthoritative)
    }

    /// Signed out: nothing is fetched.
    @MainActor func testNoFetchWhenSignedOut() async {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let s = HadBeers(url: url, currentUser: { nil }, fetchList: {
            XCTFail("fetched while signed out")
            return UserBeerList(bids: [1], count: 1)
        })
        await s.refresh(force: true)
        XCTAssertTrue(s.ids.isEmpty)
    }

    /// Fix 4: signing out empties the had-list at once, not in a later task.
    @MainActor func testSignOutClearsHadListImmediately() {
        HadBeers.shared.add(424242)
        XCTAssertTrue(HadBeers.shared.has(424242))
        AuthStore().signOut()
        XCTAssertFalse(HadBeers.shared.has(424242))
        XCTAssertTrue(HadBeers.shared.ids.isEmpty)
        XCTAssertFalse(HadBeers.shared.isAuthoritative)
    }
}
