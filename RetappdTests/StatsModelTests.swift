import XCTest
@testable import Retappd

@MainActor
final class StatsModelTests: XCTestCase {
    private func stats(beers: Int) throws -> UserStats {
        try JSONDecoder().decode(UserStats.self, from: Data("""
        {"distinct_beers": \(beers), "total_checkins": \(beers), "first_checkin_date": "Sun, 23 Jun 2013 12:17:37 +0000"}
        """.utf8))
    }

    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var used = false
        func take() -> Bool { lock.withLock { defer { used = true }; return !used } }
    }

    /// Short ranges (a week or a day) answer at once with 3 beers; long ones (a year, or a month
    /// bucket) answer slowly with 9, and keep answering after being cancelled. A stale long load
    /// that wrote anything would therefore show 9s or a different point count.
    private func model(delay: Duration = .milliseconds(400), failOneMonth: Bool = false) throws -> StatsModel {
        let short = try stats(beers: 3), long = try stats(beers: 9)
        let empty = try JSONDecoder().decode(CheckinPage.self, from: Data(#"{"checkins": {"count": 0, "items": []}}"#.utf8))
        let once = Once()
        return StatsModel(source: StatsSource(
            stats: { start, end, _ in
                let span = end.timeIntervalSince(start)
                guard span > 20 * 86_400 else { return short }
                // Ignores cancellation: awaiting a detached task's value doesn't propagate it.
                await Task.detached { try? await Task.sleep(for: delay) }.value
                if failOneMonth, span < 32 * 86_400, once.take() { throw URLError(.notConnectedToInternet) }
                return long
            },
            checkins: { _ in empty }))
    }

    func testWeekLoadsFromCheckinsAndStats() async throws {
        let m = try model()
        m.load()
        await m.waitUntilIdle()
        XCTAssertEqual(m.points.count, 7)
        XCTAssertEqual(m.stats?.distinctBeers, 3)
        XCTAssertFalse(m.isLoading)
    }

    /// Switching 1W -> 1Y -> 1W while the 1Y load is still running must leave the 1W chart alone.
    func testCancelledLoadDoesNotOverwriteNewerOne() async throws {
        let m = try model()
        m.load()
        await m.waitUntilIdle()
        m.select(.year)
        m.select(.week)  // a cache hit, shown at once
        XCTAssertEqual(m.points.count, 7)
        try await Task.sleep(for: .seconds(1.5))  // long enough for the stale 1Y load to wind down
        XCTAssertEqual(m.range, .week)
        XCTAssertEqual(m.points.count, 7)
        XCTAssertEqual(m.period.granularity, .day)
        XCTAssertEqual(m.stats?.distinctBeers, 3)
        XCTAssertFalse(m.isLoading)
        XCTAssertNil(m.error)
    }

    func testPartialFailureShowsWhatLoadedAndIsNotCached() async throws {
        let m = try model(delay: .milliseconds(50), failOneMonth: true)
        m.select(.year)
        await m.waitUntilIdle()
        XCTAssertEqual(m.points.count, 11)
        XCTAssertNotNil(m.error)
        XCTAssertFalse(m.isLoading)
        m.select(.week)
        await m.waitUntilIdle()
        m.select(.year)  // not a cache hit: loads again, and this time every bucket answers
        XCTAssertTrue(m.isLoading)
        await m.waitUntilIdle()
        XCTAssertEqual(m.points.count, 12)
        XCTAssertNil(m.error)
    }

    func testAllLoadsYearBucketsFromFirstCheckin() async throws {
        let m = try model()
        m.select(.all)
        await m.waitUntilIdle()
        XCTAssertEqual(m.period.granularity, .year)
        XCTAssertEqual(m.stats?.distinctBeers, 9)
        XCTAssertGreaterThanOrEqual(m.points.count, 13)
        XCTAssertFalse(m.isLoading)
    }

    func testSwitchingAwayFromAllWhileLoadingKeepsNewSelection() async throws {
        let m = try model(delay: .milliseconds(300))
        m.select(.all)  // its first call is slow
        m.select(.week)
        await m.waitUntilIdle()
        try await Task.sleep(for: .seconds(1))
        XCTAssertEqual(m.range, .week)
        XCTAssertEqual(m.period.granularity, .day)
        XCTAssertEqual(m.points.count, 7)
    }
}
