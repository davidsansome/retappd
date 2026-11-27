import XCTest
@testable import Retappd

private func user(_ id: Int, _ first: String, _ last: String) -> User {
    User(id: id, userName: first.lowercased(), firstName: first, lastName: last, avatar: nil)
}

private func item(_ kind: NotificationItem.Kind, checkin: Int = 1, count: Int? = nil, own: Bool = true,
                  at: Date? = nil, beer: String? = "Late Nights III") -> NotificationItem {
    NotificationItem(kind: kind, checkinID: checkin, isOwnCheckin: own, createdAt: at, count: count,
                     users: [user(1, "Jamie", "Smith"), user(2, "Pat", "Lee"), user(3, "Sam", "Fox")].prefix(max(1, min(count ?? 1, 3))).map { $0 },
                     beerName: beer)
}

final class NotificationTextTests: XCTestCase {
    func testOnePersonPerType() {
        XCTAssertEqual(item(.toast).sentence, "Jamie S toasted your Late Nights III")
        XCTAssertEqual(item(.comment).sentence, "Jamie S commented on your Late Nights III")
        XCTAssertEqual(item(.comment, own: false).sentence, "Jamie S commented on Late Nights III")
        XCTAssertEqual(item(.tagged, own: false).sentence, "Jamie S tagged you in Late Nights III")
        XCTAssertEqual(item(.mentioned, own: false).sentence, "Jamie S mentioned you in a comment on Late Nights III")
        XCTAssertEqual(item(.other("promo")).sentence, "Jamie S sent you a notification about Late Nights III")
    }

    func testCounts() {
        XCTAssertEqual(item(.toast, count: 2).actors, "Jamie S and 1 other")
        XCTAssertEqual(item(.toast, count: 3).sentence, "Jamie S and 2 others toasted your Late Nights III")
        // `count` can exceed the users listed.
        let many = NotificationItem(kind: .toast, checkinID: 1, count: 1200, users: [user(1, "Jamie", "Smith")], beerName: "X")
        XCTAssertEqual(many.actors, "Jamie S and 1,199 others")
    }

    func testEmptyUsersFallsBackToSomeone() {
        let empty = NotificationItem(kind: .toast, checkinID: 1, users: [], beerName: "Late Nights III")
        XCTAssertEqual(empty.actors, "Someone")
        XCTAssertEqual(empty.sentence, "Someone toasted your Late Nights III")
        let many = NotificationItem(kind: .toast, checkinID: 1, count: 3, users: [], beerName: "Late Nights III")
        XCTAssertEqual(many.actors, "Someone and 2 others")
    }

    func testMissingBeerName() {
        XCTAssertEqual(item(.toast, beer: nil).sentence, "Jamie S toasted your check-in")
        XCTAssertEqual(item(.comment, beer: nil).sentence, "Jamie S commented on your check-in")
        XCTAssertEqual(item(.comment, own: false, beer: nil).sentence, "Jamie S commented on a check-in")
        XCTAssertEqual(item(.tagged, own: false, beer: nil).sentence, "Jamie S tagged you in a check-in")
        XCTAssertEqual(item(.mentioned, own: false, beer: nil).sentence, "Jamie S mentioned you in a comment")
        XCTAssertEqual(item(.other("promo"), beer: nil).sentence, "Jamie S sent you a notification")
    }

    func testKindsFromRawTypes() {
        XCTAssertEqual(NotificationItem.Kind(raw: "checkinFriendTag"), .tagged)
        XCTAssertEqual(NotificationItem.Kind(raw: "checkinTag"), .tagged)
        XCTAssertEqual(NotificationItem.Kind(raw: "commentTag"), .mentioned)
        XCTAssertEqual(NotificationItem.Kind(raw: "weird"), .other("weird"))
    }

    // Shape from API.md (GET /v4/notifications, 2026-11-19).
    func testDecodesPage() throws {
        let page = try UntappdAPI.decode(NotificationPage.self, from: Data("""
        {"meta":{"code":200},"response":{"version":2,"notifications":{"count":2,"items":[
         {"checkin_id":1616173919,"checkin_owner":true,"created_at":"Thu, 19 Nov 2026 12:46:09 +0000",
          "notification_type":"toast","count":2,"users":[
            {"created_at":"Thu, 19 Nov 2026 12:46:09 +0000","checkin_owner":false,
             "user":{"uid":1000002,"user_name":"samplefriend","first_name":"Jane","last_name":"Doe","user_avatar":"https://x/a.jpg"}}],
          "meta":{"beer":{"bid":6755412,"beer_name":"Late Nights III","beer_label":"https://x/l.jpeg"},
                  "brewery":{"brewery_id":392009,"brewery_name":"Range Brewing"}}},
         {"checkin_id":5,"notification_type":"toast","users":[]}]},
         "pagination":{"next_url":"https://api.untappd.com/v4/notifications?offset=25","offset":25,"max_id":false}}}
        """.utf8))
        XCTAssertEqual(page.items.count, 1)  // the one with no users is dropped
        XCTAssertEqual(page.rawCount, 2)
        XCTAssertTrue(page.hasMore)
        XCTAssertEqual(page.items[0].sentence, "Jane D and 1 other toasted your Late Nights III")
        XCTAssertEqual(page.items[0].id, "toast-1616173919")
        XCTAssertEqual(page.items[0].beerLabel?.absoluteString, "https://x/l.jpeg")
        XCTAssertNotNil(page.items[0].createdAt)
    }

    func testLastPageHasNoMore() throws {
        let page = try UntappdAPI.decode(NotificationPage.self, from: Data("""
        {"meta":{"code":200},"response":{"notifications":{"count":0,"items":[]},"pagination":{"next_url":"","max_id":""}}}
        """.utf8))
        XCTAssertFalse(page.hasMore)
    }

    func testRequestAsTheOfficialAppAsksForIt() {
        let r = APIRequest.notifications(offset: 25)
        XCTAssertEqual(r.path, "/v4/notifications")
        XCTAssertEqual(r.query["offset"], "25")
        XCTAssertEqual(r.query["limit"], "25")
        XCTAssertEqual(r.query["version"], "2")
        XCTAssertEqual(r.query["is_news"], "false")
    }

    func testEnvelopeCounts() throws {
        let e = try JSONDecoder().decode(Envelope<NotificationPage>.self, from: Data("""
        {"meta":{"code":200},"notifications":{"type":"notifications","unread_count":
         {"comments":1,"toasts":2,"friends":3,"messages":0,"venues":0,"others":4,"news":9},"unified_count":10},
         "response":{}}
        """.utf8))
        XCTAssertEqual(e.notifications, UnreadCounts(comments: 1, toasts: 2, friends: 3, others: 4))
        XCTAssertEqual(e.notifications?.activity, 7)  // friend requests aren't activity
    }
}

@MainActor
final class NotificationUnreadTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let d = UserDefaults(suiteName: "NotificationUnreadTests-\(UUID().uuidString)")!
        return d
    }
    private func unread(_ d: UserDefaults, username: String = "me", delivered: [Date] = [],
                        now: Date = Date(timeIntervalSince1970: 1000)) -> NotificationUnread {
        NotificationUnread(username: username, defaults: d, loadRequests: { [] }, sequence: { self.seq },
                           deliveredPushDates: { delivered }, now: { now }, notificationCenter: NotificationCenter())
    }
    private var seq = 0
    private func request(_ id: Int, at: Date?) -> Friend { Friend(user: user(id, "A", "B"), createdAt: at) }

    func testNewerThanLastSeenIsNew() {
        let seen = Date(timeIntervalSince1970: 1000)
        XCTAssertTrue(item(.toast, at: Date(timeIntervalSince1970: 1001)).isNew(since: seen))
        XCTAssertFalse(item(.toast, at: seen).isNew(since: seen))
        XCTAssertFalse(item(.toast, at: Date(timeIntervalSince1970: 5)).isNew(since: seen))
        // Nothing seen yet, or no date: nothing is highlighted.
        XCTAssertFalse(item(.toast, at: .now).isNew(since: nil))
        XCTAssertFalse(item(.toast, at: nil).isNew(since: seen))
    }

    func testDotFromEnvelopeDeliveredPushOrUnseenRequests() async {
        let d = defaults()
        var u = unread(d)
        XCTAssertFalse(u.hasUnread)
        u.ingest(UnreadCounts(comments: 1, toasts: 1, friends: 5, others: 0), startedAt: 1)
        XCTAssertEqual(u.count, 2)  // friends come from the pending list, not the envelope
        XCTAssertTrue(u.hasUnread)

        u = unread(defaults(), delivered: [Date(timeIntervalSince1970: 500)])
        await u.refresh()
        XCTAssertTrue(u.hasUnread)
        XCTAssertEqual(u.count, 0)  // a dot without a number

        u = unread(defaults())
        u.setRequests([request(1, at: Date(timeIntervalSince1970: 100))])
        XCTAssertEqual(u.count, 1)
        XCTAssertTrue(u.hasUnread)
    }

    func testMarkSeenClearsEverythingAndKeepsSeenRequestsQuiet() {
        let u = unread(defaults())
        u.ingest(UnreadCounts(comments: 2), startedAt: 1)
        u.setRequests([request(1, at: Date(timeIntervalSince1970: 100))])
        u.markSeen(newest: Date(timeIntervalSince1970: 500))
        XCTAssertFalse(u.hasUnread)
        XCTAssertEqual(u.lastSeen, Date(timeIntervalSince1970: 500))
        // A request that arrives afterwards lights it again.
        u.setRequests([request(1, at: Date(timeIntervalSince1970: 100)), request(2, at: Date(timeIntervalSince1970: 600))])
        XCTAssertEqual(u.unseenRequests, 1)
    }

    func testMarkSeenPersistsPerUsernameAndOnlyMovesForward() {
        let d = defaults()
        let a = unread(d, username: "Alice")
        a.markSeen(newest: Date(timeIntervalSince1970: 900))
        a.markSeen(newest: Date(timeIntervalSince1970: 100))
        XCTAssertEqual(a.lastSeen, Date(timeIntervalSince1970: 900))
        XCTAssertEqual(unread(d, username: "alice").lastSeen, Date(timeIntervalSince1970: 900))
        XCTAssertNil(unread(d, username: "bob").lastSeen)
    }

    func testStaleCountsAreDropped() {
        let u = unread(defaults())
        // Requests 1 and 2 started; the list was read after both (sequence 2) and marked seen.
        seq = 2
        u.markSeen(newest: nil)
        // Request 2 finishes late with the counts from before the clear: dropped.
        u.ingest(UnreadCounts(toasts: 3), startedAt: 2)
        XCTAssertFalse(u.hasUnread)
        // A request that started after the clear is believed.
        u.ingest(UnreadCounts(toasts: 1), startedAt: 3)
        XCTAssertEqual(u.activity, 1)
        // A slower, older one finishing after it doesn't overwrite it.
        u.ingest(UnreadCounts(toasts: 0), startedAt: 2)
        u.ingest(UnreadCounts(toasts: 0), startedAt: 3)
        XCTAssertEqual(u.activity, 1)
        u.ingest(UnreadCounts(toasts: 0), startedAt: 4)
        XCTAssertEqual(u.activity, 0)
    }

    func testFailedRequestLoadKeepsWhatWeHad() async {
        var fail = false
        let u = NotificationUnread(username: "me", defaults: defaults(),
                                   loadRequests: { if fail { throw APIError.http(500) }; return [Friend(user: user(1, "A", "B"))] },
                                   sequence: { 0 }, deliveredPushDates: { [] }, notificationCenter: NotificationCenter())
        await u.refresh()
        XCTAssertEqual(u.requests.count, 1)
        fail = true
        await u.refresh()
        XCTAssertEqual(u.requests.count, 1)
    }

    func testMarkSeenKeepsAlreadyDeliveredPushesQuietAndNewerOnesLightBell() async {
        var delivered = [Date(timeIntervalSince1970: 800)]
        var clock = Date(timeIntervalSince1970: 900)
        let d = defaults()
        let u = NotificationUnread(username: "me", defaults: d, loadRequests: { [] }, sequence: { 0 },
                                   deliveredPushDates: { delivered }, now: { clock },
                                   notificationCenter: NotificationCenter())
        await u.refresh()
        XCTAssertTrue(u.hasUnread)

        u.markSeen(newest: Date(timeIntervalSince1970: 750))
        XCTAssertFalse(u.hasUnread)

        // Delivered notifications stay in Notification Centre, so refresh sees the same date again.
        await u.refresh()
        XCTAssertFalse(u.hasUnread)

        // A newer push delivered later lights the bell again.
        clock = Date(timeIntervalSince1970: 1100)
        delivered.append(Date(timeIntervalSince1970: 1050))
        await u.refresh()
        XCTAssertTrue(u.hasUnread)
    }

    func testMarkedSeenAtPersistsAcrossInstances() async {
        let d = defaults()
        let delivered = [Date(timeIntervalSince1970: 800)]
        let first = NotificationUnread(username: "me", defaults: d, loadRequests: { [] }, sequence: { 0 },
                                       deliveredPushDates: { delivered },
                                       now: { Date(timeIntervalSince1970: 900) },
                                       notificationCenter: NotificationCenter())
        await first.refresh()
        XCTAssertTrue(first.hasUnread)
        first.markSeen(newest: Date(timeIntervalSince1970: 750))

        // A fresh instance on the same UserDefaults keeps pushes before the stored cutoff quiet.
        let second = NotificationUnread(username: "me", defaults: d, loadRequests: { [] }, sequence: { 0 },
                                        deliveredPushDates: { delivered },
                                        now: { Date(timeIntervalSince1970: 1200) },
                                        notificationCenter: NotificationCenter())
        await second.refresh()
        XCTAssertFalse(second.hasUnread)
    }

    func testUpgradeWithLastSeenButNoMarkedSeenAtBaselinesToNow() async {
        let d = defaults()
        d.set(700.0, forKey: NotificationUnread.key("me"))
        // Push delivered at 750 (after item created_at 700, before upgrade at 1000) stays quiet.
        let u = NotificationUnread(username: "me", defaults: d, loadRequests: { [] }, sequence: { 0 },
                                   deliveredPushDates: { [Date(timeIntervalSince1970: 750)] },
                                   now: { Date(timeIntervalSince1970: 1000) },
                                   notificationCenter: NotificationCenter())
        await u.refresh()
        XCTAssertFalse(u.hasUnread)
    }

    func testInFlightRefreshWithPreMarkSeenPushDoesNotReLightBell() async {
        var releaseDelivered: CheckedContinuation<[Date], Never>?
        let u = NotificationUnread(username: "me", defaults: defaults(), loadRequests: { [] }, sequence: { 0 },
                                   deliveredPushDates: {
                                       await withCheckedContinuation { releaseDelivered = $0 }
                                   },
                                   now: { Date(timeIntervalSince1970: 1000) },
                                   notificationCenter: NotificationCenter())
        let refresh = Task { await u.refresh() }
        while releaseDelivered == nil { await Task.yield() }

        u.markSeen(newest: nil)
        releaseDelivered?.resume(returning: [Date(timeIntervalSince1970: 950)])
        await refresh.value
        XCTAssertFalse(u.hasUnread)
    }

    func testDatelessRequestNotPermanentlyUnseenAfterMarkSeen() {
        let u = unread(defaults())
        u.setRequests([request(1, at: nil)])
        XCTAssertEqual(u.unseenRequests, 1)
        u.markSeen(newest: Date(timeIntervalSince1970: 500))
        XCTAssertEqual(u.unseenRequests, 0)
        XCTAssertFalse(u.hasUnread)
    }

    func testForegroundPushLightsUnreadWithoutDeliveredNotification() async {
        let center = NotificationCenter()
        let u = NotificationUnread(username: "me", defaults: defaults(), loadRequests: { [] }, sequence: { 0 },
                                   deliveredPushDates: { [] }, notificationCenter: center)
        XCTAssertFalse(u.hasUnread)
        center.post(name: .foregroundPushReceived, object: nil)
        for _ in 0..<200 where !u.hasUnread { await Task.yield() }
        XCTAssertTrue(u.hasUnread)
        u.markSeen(newest: nil)
        XCTAssertFalse(u.hasUnread)
    }
}

@MainActor
final class NotificationsModelTests: XCTestCase {
    /// A fake server of `total` items that records every request.
    private final class Server {
        var calls: [(offset: Int, limit: Int)] = []
        var total: Int
        var failNext = false
        var gate: CheckedContinuation<Void, Never>?
        var hold = false
        init(total: Int) { self.total = total }

        func page(_ offset: Int, _ limit: Int) async throws -> NotificationPage {
            calls.append((offset, limit))
            if hold { await withCheckedContinuation { gate = $0 } }
            if failNext { failNext = false; throw APIError.http(500) }
            let ids = offset..<min(offset + limit, total)
            let items = ids.map { item(.toast, checkin: $0, at: Date(timeIntervalSince1970: Double(10_000 - $0))) }
            return NotificationPage(items: items, hasMore: ids.count == limit)
        }
    }

    private func model(_ s: Server) -> NotificationsModel { NotificationsModel { try await s.page($0, $1) } }

    func testAppearingEarlyRowsDoesNotPage() async {
        let s = Server(total: 100)
        let m = model(s)
        await m.refresh()
        XCTAssertEqual(m.items.count, 25)
        for it in m.items.prefix(15) { m.onAppear(it) }
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(s.calls.count, 1)
    }

    func testNearTheEndPagesOnceEvenIfManyRowsAppearWhileLoading() async {
        let s = Server(total: 100)
        let m = model(s)
        await m.refresh()
        s.hold = true
        // A burst of appear callbacks, as a non-lazy stack would deliver.
        for it in m.items.suffix(5) { m.onAppear(it) }
        for it in m.items.suffix(5) { m.onAppear(it) }
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(s.calls.count, 2)
        XCTAssertEqual(s.calls[1].offset, 25)
        s.hold = false
        s.gate?.resume()
        while m.isLoadingMore { await Task.yield() }
        XCTAssertEqual(m.items.count, 50)
        XCTAssertEqual(s.calls.count, 2)
    }

    func testStopsAtTheEnd() async {
        let s = Server(total: 30)
        let m = model(s)
        await m.refresh()
        await m.loadMore()
        XCTAssertEqual(m.items.count, 30)
        XCTAssertTrue(m.reachedEnd)
        await m.loadMore()
        m.onAppear(m.items.last!)
        await Task.yield()
        XCTAssertEqual(s.calls.count, 2)
    }

    func testFailureDoesNotRetryOnItsOwn() async {
        let s = Server(total: 100)
        let m = model(s)
        await m.refresh()
        s.failNext = true
        await m.loadMore()
        XCTAssertNotNil(m.moreError)
        m.onAppear(m.items.last!)
        await Task.yield()
        XCTAssertEqual(s.calls.count, 2)  // scrolling alone doesn't retry
        await m.loadMore()  // Retry does
        XCTAssertEqual(m.items.count, 50)
        XCTAssertNil(m.moreError)
    }

    func testRepeatedItemsAreDroppedWhenPaging() async {
        // An item with fresh activity moves to the top, so offset paging can show it twice.
        let m = NotificationsModel { offset, _ in
            let ids = offset == 0 ? Array(0..<25) : Array(24..<40)
            return NotificationPage(items: ids.map { item(.toast, checkin: $0) }, hasMore: offset == 0)
        }
        await m.refresh()
        await m.loadMore()
        XCTAssertEqual(m.items.count, 40)
        XCTAssertEqual(Set(m.items.map(\.id)).count, 40)
    }

    func testRefreshReplacesAndFailureKeepsTheList() async {
        let s = Server(total: 10)
        let m = model(s)
        let first = await m.refresh()
        XCTAssertTrue(first)
        s.total = 3
        await m.refresh()
        XCTAssertEqual(m.items.count, 3)
        s.failNext = true
        let ok = await m.refresh()
        XCTAssertFalse(ok)  // so the screen doesn't mark anything seen
        XCTAssertEqual(m.items.count, 3)
        XCTAssertNotNil(m.error)
    }

    func testLoadMoreIgnoresURLErrorCancelled() async {
        let m = NotificationsModel { offset, limit in
            if offset > 0 { throw URLError(.cancelled) }
            let items = (0..<limit).map { item(.toast, checkin: $0) }
            return NotificationPage(items: items, hasMore: true)
        }
        await m.refresh()
        await m.loadMore()
        XCTAssertNil(m.moreError)
        XCTAssertFalse(m.isLoadingMore)
    }

    func testRefreshResetsLoadingMoreAndStaleLoadMoreDoesNotClobberState() async {
        var page2Continuations: [CheckedContinuation<NotificationPage, Error>] = []
        let m = NotificationsModel { offset, limit in
            if offset == 0 {
                let items = (0..<limit).map { item(.toast, checkin: $0) }
                return NotificationPage(items: items, hasMore: true)
            }
            return try await withCheckedThrowingContinuation { page2Continuations.append($0) }
        }
        await m.refresh()
        XCTAssertEqual(m.items.count, 25)

        // Start a slow loadMore() from generation 1.
        let stale = Task { await m.loadMore() }
        while page2Continuations.isEmpty { await Task.yield() }
        XCTAssertTrue(m.isLoadingMore)

        // Refresh starts generation 2 and resets isLoadingMore so pagination isn't blocked.
        let refreshed = await m.refresh()
        XCTAssertTrue(refreshed)
        XCTAssertFalse(m.isLoadingMore)

        // Start a new loadMore() in generation 2.
        let fresh = Task { await m.loadMore() }
        while page2Continuations.count < 2 { await Task.yield() }
        XCTAssertTrue(m.isLoadingMore)

        // Stale loadMore() finishes: its result is dropped and it must not clear isLoadingMore.
        let stalePage = NotificationPage(items: (100..<125).map { item(.toast, checkin: $0) }, hasMore: true)
        page2Continuations[0].resume(returning: stalePage)
        await stale.value
        XCTAssertTrue(m.isLoadingMore)
        XCTAssertEqual(m.items.count, 25)

        // Fresh loadMore() finishes and appends normally.
        let freshPage = NotificationPage(items: (25..<50).map { item(.toast, checkin: $0) }, hasMore: false)
        page2Continuations[1].resume(returning: freshPage)
        await fresh.value
        XCTAssertFalse(m.isLoadingMore)
        XCTAssertEqual(m.items.count, 50)
    }
}
