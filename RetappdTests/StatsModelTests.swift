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
    private func model(delay: Duration = .milliseconds(400), failOneMonth: Bool = false,
                        now: @escaping @Sendable () -> Date = { Date() }) throws -> StatsModel {
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
            checkins: { _ in empty }), now: now)
    }

    private let cal = Calendar.current
    private func day(_ y: Int, _ m: Int, _ d: Int) -> Date { cal.date(from: DateComponents(year: y, month: m, day: d, hour: 12))! }
    private var today: Date { day(2026, 11, 18) }

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

    // MARK: Custom periods

    func testCustomLoadsDaysAndTotals() async throws {
        let now = today
        let m = try model(now: { now })
        m.setCustom(start: day(2026, 11, 1), end: day(2026, 11, 10))
        XCTAssertEqual(m.range, .custom)
        await m.waitUntilIdle()
        XCTAssertEqual(m.period.granularity, .day)
        XCTAssertEqual(m.points.count, 10)
        XCTAssertEqual(m.stats?.distinctBeers, 3)
        XCTAssertNil(m.error)
    }

    /// A 1Y load still running when a custom range is chosen must not overwrite it.
    func testStalePresetLoadDoesNotOverwriteCustom() async throws {
        let now = today
        let m = try model(now: { now })
        m.select(.year)  // slow
        m.setCustom(start: day(2026, 11, 1), end: day(2026, 11, 7))
        await m.waitUntilIdle()
        try await Task.sleep(for: .seconds(1.5))
        XCTAssertEqual(m.range, .custom)
        XCTAssertEqual(m.points.count, 7)
        XCTAssertEqual(m.period.granularity, .day)
        XCTAssertEqual(m.stats?.distinctBeers, 3)
        XCTAssertFalse(m.isLoading)
    }

    /// A slow custom load (months) still running when a preset is chosen must not overwrite it.
    func testStaleCustomLoadDoesNotOverwritePreset() async throws {
        let now = today
        let m = try model(now: { now })
        m.setCustom(start: day(2026, 3, 10), end: day(2026, 11, 10))  // month buckets, slow
        m.select(.week)
        await m.waitUntilIdle()
        try await Task.sleep(for: .seconds(1.5))
        XCTAssertEqual(m.range, .week)
        XCTAssertEqual(m.points.count, 7)
        XCTAssertEqual(m.period.granularity, .day)
        XCTAssertEqual(m.stats?.distinctBeers, 3)
        XCTAssertFalse(m.isLoading)
        XCTAssertNil(m.error)
    }

    func testCustomIsCachedByItsDates() async throws {
        let now = today
        let m = try model(now: { now })
        m.setCustom(start: day(2026, 11, 1), end: day(2026, 11, 10))
        await m.waitUntilIdle()
        m.select(.week)
        await m.waitUntilIdle()
        m.setCustom(start: day(2026, 11, 1), end: day(2026, 11, 10))
        XCTAssertFalse(m.isLoading)  // a cache hit
        XCTAssertEqual(m.points.count, 10)
        m.setCustom(start: day(2026, 11, 1), end: day(2026, 11, 11))
        XCTAssertTrue(m.isLoading)  // different end: a new load
        await m.waitUntilIdle()
        XCTAssertEqual(m.points.count, 11)
    }

    func testCustomSteppingMovesByItsLengthAndStopsAtToday() async throws {
        let now = today
        let m = try model(now: { now })
        m.setCustom(start: day(2026, 11, 1), end: day(2026, 11, 10))
        XCTAssertTrue(m.canStepForward)
        m.step(1)
        XCTAssertEqual(m.period.start, cal.startOfDay(for: day(2026, 10, 22)))
        XCTAssertEqual(m.period.end, cal.startOfDay(for: day(2026, 10, 31)))
        m.step(-1)
        XCTAssertEqual(m.period.start, cal.startOfDay(for: day(2026, 11, 1)))
        m.step(-1)  // would end on the 20th: held at today, keeping 10 days
        XCTAssertEqual(m.period.end, cal.startOfDay(for: today))
        XCTAssertEqual(m.period.dayCount(calendar: cal), 10)
        XCTAssertFalse(m.canStepForward)
        m.step(-1)
        XCTAssertEqual(m.period.end, cal.startOfDay(for: today))
        XCTAssertEqual(m.range, .custom)
        await m.waitUntilIdle()
    }

    func testCustomSteppingBackStopsAtFirstCheckin() async throws {
        let now = today
        let m = try model(now: { now })
        m.setCustom(start: day(2013, 6, 25), end: day(2013, 7, 4))
        await m.waitUntilIdle()  // learns the first check-in (23 Jun 2013)
        let first = cal.startOfDay(for: try XCTUnwrap(m.firstCheckin))
        XCTAssertTrue(m.canStepBack)
        m.step(1)
        XCTAssertEqual(m.period.start, first)  // clipped, so shorter than 10 days
        XCTAssertLessThan(m.period.dayCount(calendar: cal), 10)
        XCTAssertFalse(m.canStepBack)
        let before = m.period
        m.step(1)
        XCTAssertEqual(m.period, before)
        await m.waitUntilIdle()
    }

    func testPresetButtonsLeaveCustom() async throws {
        let now = today
        let m = try model(now: { now })
        m.setCustom(start: day(2026, 11, 1), end: day(2026, 11, 10))
        await m.waitUntilIdle()
        m.select(.week)
        await m.waitUntilIdle()
        XCTAssertEqual(m.range, .week)
        XCTAssertEqual(m.period.range, .week)
        XCTAssertEqual(m.period.dayCount(calendar: cal), 7)
        m.select(.custom)  // not a button
        XCTAssertEqual(m.range, .week)
    }

    /// Stepping back clipped at the first check-in shortens the range; stepping forward again
    /// restores the length that was asked for.
    func testCustomStepLengthSurvivesClipping() async throws {
        let now = today
        let m = try model(now: { now })
        m.setCustom(start: day(2013, 6, 25), end: day(2013, 7, 4))  // 10 days
        await m.waitUntilIdle()
        m.step(1)  // clipped at the first check-in
        XCTAssertLessThan(m.period.dayCount(calendar: cal), 10)
        m.step(-1)
        XCTAssertEqual(m.period.dayCount(calendar: cal), 10)
        await m.waitUntilIdle()
    }
}
