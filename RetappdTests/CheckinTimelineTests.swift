import XCTest
@testable import Retappd

final class CheckinTimelineTests: XCTestCase {
    private static let format: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return f
    }()

    private func checkins(_ ages: [(id: Int, secondsAgo: TimeInterval?)], now: Date) throws -> [Checkin] {
        let items = ages.map { a -> String in
            let created = a.secondsAgo.map { "\"created_at\":\"\(Self.format.string(from: now.addingTimeInterval(-$0)))\"," } ?? ""
            return "{\(created)\"checkin_id\":\(a.id)}"
        }
        let json = "{\"meta\":{\"code\":200},\"response\":{\"checkins\":{\"count\":\(items.count),\"items\":[\(items.joined(separator: ","))]}}}"
        return try UntappdAPI.decode(CheckinPage.self, from: Data(json.utf8)).checkins
    }

    @MainActor func testGroupsRowsUnderOneHeaderPerBucket() throws {
        let now = Date()
        let items = try checkins([(5, 60), (4, 120), (3, 3 * 86_400), (2, 30 * 86_400), (1, nil)], now: now)
        XCTAssertEqual(items.count, 5)
        let entries = CheckinListModel.timeline(of: items, now: now)
        var shape: [String] = []
        for e in entries {
            switch e {
            case .header(let b, let first): shape.append("h\(b.rawValue)\(first ? "*" : "")")
            case .row(let c): shape.append("r\(c.id)")
            }
        }
        // Newest bucket first; the undated one goes with "Earlier".
        XCTAssertEqual(shape.first, "h0*")
        XCTAssertEqual(shape.filter { $0.hasPrefix("h") }.count, 3)
        XCTAssertEqual(shape.filter { $0.hasPrefix("r") }.count, 5)
        XCTAssertEqual(Set(entries.map(\.id)).count, entries.count, "ids must be unique")
    }

    @MainActor func testEmptyListHasNoHeaders() {
        XCTAssertTrue(CheckinListModel.timeline(of: []).isEmpty)
    }

    @MainActor func testRowAppearingWithNoNextPageDoesNotStartALoad() throws {
        let model = CheckinListModel(source: .venue(1, friendsOnly: false))
        let c = try checkins([(1, 60)], now: .now)[0]
        model.onAppear(c)  // not in the list, and there's no cursor
        XCTAssertFalse(model.isLoadingMore)
    }

    // MARK: - Pagination, generation guard, cancellation, and toast races

    @MainActor
    private final class Gate {
        private var waiter: CheckedContinuation<Void, Error>?
        var isWaiting: Bool { waiter != nil }

        func wait() async throws {
            try await withCheckedThrowingContinuation { waiter = $0 }
        }
        func release() { waiter?.resume(); waiter = nil }
        func fail(_ error: Error = APIError.http(500)) { waiter?.resume(throwing: error); waiter = nil }
        func untilWaiting() async {
            for _ in 0..<2000 where !isWaiting { await Task.yield() }
        }
    }

    private func pageData(ids: [Int], nextMaxId: Int?) -> Data {
        let items = ids.map { "{\"checkin_id\":\($0),\"toasts\":{\"total_count\":0,\"auth_toast\":false,\"items\":[]}}" }
        let pagination = nextMaxId.map { "\"pagination\":{\"max_id\":\($0)}" } ?? "\"pagination\":{}"
        let json = "{\"meta\":{\"code\":200},\"response\":{\(pagination),\"checkins\":{\"count\":\(items.count),\"items\":[\(items.joined(separator: ","))]}}}"
        return Data(json.utf8)
    }

    private func page(ids: [Int], nextMaxId: Int?) throws -> CheckinPage {
        try UntappdAPI.decode(CheckinPage.self, from: pageData(ids: ids, nextMaxId: nextMaxId))
    }

    @MainActor func testLoadMoreIgnoresStalePageAfterRefresh() async throws {
        let gate = Gate()
        var firstPages = [try page(ids: [10, 9], nextMaxId: 9), try page(ids: [20, 19], nextMaxId: 19)]
        let staleMoreData = pageData(ids: [8, 7], nextMaxId: 7)

        let model = CheckinListModel(
            source: .friends,
            fetchFirstPage: { _ in firstPages.removeFirst() },
            fetchMoreData: { _ in
                try await gate.wait()
                return staleMoreData
            }
        )

        await model.refresh()
        XCTAssertEqual(model.items.map(\.id), [10, 9])

        let more = Task { await model.loadMore() }
        await gate.untilWaiting()

        // A refresh starts a new generation while loadMore is still in flight.
        await model.refresh()
        XCTAssertEqual(model.items.map(\.id), [20, 19])

        gate.release()
        await more.value

        // The stale page from generation 1 must not be appended or set reachedEnd/moreError.
        XCTAssertEqual(model.items.map(\.id), [20, 19])
        XCTAssertFalse(model.reachedEnd)
        XCTAssertNil(model.moreError)
    }

    @MainActor func testLoadMoreSeparatesMoreErrorAndGatesAutoPaging() async throws {
        let firstPage = try page(ids: [10, 9], nextMaxId: 9)
        var moreCalls = 0

        let model = CheckinListModel(
            source: .friends,
            fetchFirstPage: { _ in firstPage },
            fetchMoreData: { _ in
                moreCalls += 1
                throw APIError.http(503)
            }
        )

        await model.refresh()
        XCTAssertNil(model.error)
        XCTAssertNil(model.moreError)

        await model.loadMore()
        XCTAssertEqual(moreCalls, 1)
        XCTAssertNil(model.error, "pagination error should not overwrite refresh error")
        XCTAssertNotNil(model.moreError)

        // Scrolling past the last row while moreError is set must not retry automatically.
        model.onAppear(model.items[1])
        await Task.yield()
        XCTAssertEqual(moreCalls, 1)
    }

    @MainActor func testLoadMoreIgnoresCancellationErrors() async throws {
        let firstPage = try page(ids: [10, 9], nextMaxId: 9)
        var errors: [Error] = [CancellationError(), URLError(.cancelled)]

        let model = CheckinListModel(
            source: .friends,
            fetchFirstPage: { _ in firstPage },
            fetchMoreData: { _ in throw errors.removeFirst() }
        )

        await model.refresh()
        await model.loadMore()
        XCTAssertNil(model.moreError)
        XCTAssertNil(model.error)

        await model.loadMore()
        XCTAssertNil(model.moreError)
        XCTAssertNil(model.error)
    }

    @MainActor func testToastToggleGuardsDoubleTapAndRevertsOnlyToastFields() async throws {
        let firstPage = try page(ids: [42], nextMaxId: nil)
        let gate = Gate()
        var toastCalls = 0

        let model = CheckinListModel(
            source: .friends,
            fetchFirstPage: { _ in firstPage },
            sendToastToggle: { _ in
                toastCalls += 1
                try await gate.wait()
            }
        )
        model.me = User(id: 7, userName: "tester", firstName: "Test", lastName: "User", avatar: nil)

        await model.refresh()
        let original = model.items[0]
        XCTAssertFalse(original.youToasted)
        XCTAssertEqual(original.toastCount, 0)

        let firstTap = Task { await model.toggleToast(original) }
        await gate.untilWaiting()

        // Optimistically toasted.
        XCTAssertTrue(model.items[0].youToasted)
        XCTAssertEqual(model.items[0].toastCount, 1)
        XCTAssertEqual(model.items[0].toasters.map(\.id), [7])

        // Second rapid tap while in flight is ignored.
        await model.toggleToast(original)
        XCTAssertEqual(toastCalls, 1)
        XCTAssertTrue(model.items[0].youToasted)

        // Concurrent comment update arrives while the toast request is still out.
        var edited = model.items[0]
        edited.comment = "Updated tasting note"
        edited.commentCount = 3
        model.replace(edited)

        // Toast fails: only toast fields revert, concurrent comment update stays intact.
        gate.fail()
        await firstTap.value

        XCTAssertFalse(model.items[0].youToasted)
        XCTAssertEqual(model.items[0].toastCount, 0)
        XCTAssertTrue(model.items[0].toasters.isEmpty)
        XCTAssertEqual(model.items[0].comment, "Updated tasting note")
        XCTAssertEqual(model.items[0].commentCount, 3)
        XCTAssertNotNil(model.error)
    }

    @MainActor func testToastToggleSuccessPostsCheckinEdited() async throws {
        let firstPage = try page(ids: [55], nextMaxId: nil)
        let model = CheckinListModel(
            source: .friends,
            fetchFirstPage: { _ in firstPage },
            sendToastToggle: { _ in }
        )
        await model.refresh()

        var received: Checkin?
        let token = NotificationCenter.default.addObserver(forName: .checkinEdited, object: nil, queue: nil) { note in
            received = note.object as? Checkin
        }
        defer { NotificationCenter.default.removeObserver(token) }

        await model.toggleToast(model.items[0])

        XCTAssertEqual(received?.id, 55)
        XCTAssertEqual(received?.youToasted, true)
        XCTAssertEqual(received?.toastCount, 1)
    }
}
