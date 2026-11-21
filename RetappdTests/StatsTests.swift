import XCTest
@testable import Retappd

final class StatsTests: XCTestCase {
    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Australia/Sydney")!
        return c
    }()
    private func day(_ y: Int, _ m: Int, _ d: Int) -> Date { cal.date(from: DateComponents(year: y, month: m, day: d))! }

    func testWeekPeriodAndStepBack() {
        let today = day(2026, 11, 18).addingTimeInterval(3600 * 5)
        let p = StatsPeriod.make(.week, today: today, calendar: cal)
        XCTAssertEqual(p.start, day(2026, 11, 12))
        XCTAssertEqual(p.end, day(2026, 11, 18))
        XCTAssertEqual(p.buckets(calendar: cal).count, 7)
        let back = StatsPeriod.make(.week, offset: 1, today: today, calendar: cal)
        XCTAssertEqual(back.start, day(2026, 11, 5))
        XCTAssertEqual(back.end, day(2026, 11, 11))
        XCTAssertEqual(StatsPeriod.apiDate(back.start, calendar: cal), "2026-11-05")
    }

    func testMonthPeriodClampsShortMonths() {
        let p = StatsPeriod.make(.month, today: day(2026, 3, 31), calendar: cal)
        XCTAssertEqual(p.start, day(2026, 3, 1))
        let back = StatsPeriod.make(.month, offset: 1, today: day(2026, 3, 31), calendar: cal)
        XCTAssertEqual(back.end, day(2026, 2, 28))
        XCTAssertEqual(back.start, day(2026, 1, 29))
        let two = StatsPeriod.make(.month, offset: 2, today: day(2026, 3, 31), calendar: cal)
        XCTAssertEqual(two.end, day(2026, 1, 28))
        XCTAssertEqual(two.start, day(2025, 12, 29))
        let three = StatsPeriod.make(.month, offset: 3, today: day(2026, 3, 31), calendar: cal)
        XCTAssertEqual(three.end, day(2025, 12, 28))
        XCTAssertEqual(three.start, day(2025, 11, 29))
    }

    func testMonthStepsNeverOverlapOrSkipDays() {
        for today in [day(2026, 3, 31), day(2026, 5, 31), day(2026, 1, 30), day(2024, 3, 31), day(2026, 8, 31)] {
            var previous = StatsPeriod.make(.month, offset: 0, today: today, calendar: cal)
            for n in 1...6 {
                let p = StatsPeriod.make(.month, offset: n, today: today, calendar: cal)
                XCTAssertEqual(cal.date(byAdding: .day, value: 1, to: p.end), previous.start, "offset \(n) from \(today)")
                previous = p
            }
        }
    }

    func testSingleYearCaptionIsJustTheYear() {
        let p = StatsPeriod.make(.all, today: day(2026, 11, 18), firstCheckin: day(2026, 3, 1), calendar: cal)
        XCTAssertEqual(p.caption(calendar: cal), "2026")
    }

    func testDayCount() {
        XCTAssertEqual(StatsPeriod.make(.week, today: day(2026, 11, 18), calendar: cal).dayCount(calendar: cal), 7)
        XCTAssertEqual(StatsPeriod.make(.month, today: day(2026, 3, 31), calendar: cal).dayCount(calendar: cal), 31)
    }

    func testYearBucketsAreCalendarMonths() {
        let p = StatsPeriod.make(.year, today: day(2026, 11, 18), calendar: cal)
        XCTAssertEqual(p.start, day(2025, 12, 1))
        let b = p.buckets(calendar: cal)
        XCTAssertEqual(b.count, 12)
        XCTAssertEqual(b.last?.start, day(2026, 11, 1))
        XCTAssertEqual(b.last?.end, day(2026, 11, 18))
        XCTAssertEqual(b.first?.end, day(2025, 12, 31))
        let back = StatsPeriod.make(.year, offset: 1, today: day(2026, 11, 18), calendar: cal)
        XCTAssertEqual(back.end, day(2025, 11, 30))
        XCTAssertEqual(back.buckets(calendar: cal).count, 12)
    }

    func testAllBucketsByYearFromFirstCheckin() {
        let p = StatsPeriod.make(.all, today: day(2026, 11, 18), firstCheckin: day(2013, 6, 23), calendar: cal)
        let b = p.buckets(calendar: cal)
        XCTAssertEqual(b.count, 14)
        XCTAssertEqual(b.first?.start, day(2013, 6, 23))
        XCTAssertEqual(b.first?.anchor, day(2013, 1, 1))
        XCTAssertEqual(b.last?.end, day(2026, 11, 18))
        XCTAssertEqual(p.caption(calendar: cal), "2013 – 2026")
    }

    func testDailyDistinctBeers() throws {
        func checkin(_ id: Int, _ bid: Int, _ date: String) throws -> Checkin {
            try JSONDecoder().decode(Checkin.self, from: Data("""
            {"checkin_id": \(id), "created_at": "\(date)", "beer": {"bid": \(bid), "beer_name": "B"}}
            """.utf8))
        }
        let cs = [try checkin(1, 5, "Tue, 17 Nov 2026 10:00:00 +1100"), try checkin(2, 5, "Tue, 17 Nov 2026 18:00:00 +1100"),
                  try checkin(3, 6, "Tue, 17 Nov 2026 19:00:00 +1100"), try checkin(4, 5, "Wed, 18 Nov 2026 09:00:00 +1100")]
        let counts = StatsBucketing.dailyCounts(cs, calendar: cal)
        XCTAssertEqual(counts[day(2026, 11, 17)]?.beers, [5, 6])
        XCTAssertEqual(counts[day(2026, 11, 17)]?.checkins, 3)
        let p = StatsPeriod.make(.week, today: day(2026, 11, 18), calendar: cal)
        let pts = StatsBucketing.points(buckets: p.buckets(calendar: cal), counts: counts, from: p.start)
        XCTAssertEqual(pts.map(\.beers), [0, 0, 0, 0, 0, 2, 1])
    }

    func testDecodesStatsResponse() throws {
        let json = """
        {"meta":{"code":200},"response":{"stats":{"age":7,"start_date":"2026-06-27 14:00:00","gmt_offset":"10",
         "first_checkin_date":"Sun, 23 Jun 2013 12:17:37 +0000","distinct_beers":8,"total_checkins":14,
         "average_checkins_per_day":"2","total_venues":3,"new_venues":1,"new_venues_perc":50,"new_beers":8,"new_beers_perc":57,
         "top_beers":{"beers":{"count":1,"items":[{"total_count":3,
           "beer":{"bid":5,"beer_name":"Amber","beer_style":"Ale"},"brewery":{"brewery_id":9,"brewery_name":"Brew Co"}}]}}}}}
        """
        let s = try UntappdAPI.decode(UserStatsResponse.self, from: Data(json.utf8)).stats
        XCTAssertEqual(s.distinctBeers, 8)
        XCTAssertEqual(s.totalCheckins, 14)
        XCTAssertEqual(s.averageCheckinsPerDay, 2)
        XCTAssertEqual(s.newVenuesPercent, 50)
        XCTAssertNotNil(s.firstCheckinDate)
        XCTAssertEqual(s.topBeers.first?.beer.brewery, "Brew Co")
        XCTAssertEqual(s.topBeers.first?.count, 3)
    }

    // MARK: Custom periods

    func testCustomGranularityByLength() {
        let today = day(2026, 11, 18)
        func g(_ s: Date, _ e: Date) -> StatsPeriod.Granularity {
            StatsPeriod.custom(start: s, end: e, today: today, calendar: cal).granularity
        }
        XCTAssertEqual(g(day(2026, 11, 18), day(2026, 11, 18)), .day)  // one day
        XCTAssertEqual(g(day(2026, 9, 18), day(2026, 11, 18)), .day)   // exactly 62 days
        XCTAssertEqual(g(day(2026, 9, 17), day(2026, 11, 18)), .month) // 63 days
        XCTAssertEqual(g(day(2023, 11, 19), day(2026, 11, 18)), .month) // 1096 days
        XCTAssertEqual(g(day(2023, 11, 18), day(2026, 11, 18)), .year)  // 1097 days
    }

    func testCustomClampsToTodayAndFirstCheckin() {
        let today = day(2026, 11, 18)
        let future = StatsPeriod.custom(start: day(2026, 11, 10), end: day(2026, 12, 25), today: today, calendar: cal)
        XCTAssertEqual(future.end, today)
        let allInFuture = StatsPeriod.custom(start: day(2026, 12, 1), end: day(2026, 12, 25), today: today, calendar: cal)
        XCTAssertEqual(allInFuture.start, today)
        XCTAssertEqual(allInFuture.end, today)
        let early = StatsPeriod.custom(start: day(2012, 1, 1), end: day(2014, 1, 1), today: today,
                                       firstCheckin: day(2013, 6, 23), calendar: cal)
        XCTAssertEqual(early.start, day(2013, 6, 23))
        let reversed = StatsPeriod.custom(start: day(2026, 11, 10), end: day(2026, 11, 2), today: today, calendar: cal)
        XCTAssertEqual(reversed.start, reversed.end)  // end is never before start
    }

    /// A range starting mid-month at month granularity clips its first and last bucket to the
    /// range, so days outside it are never counted and no day falls in two buckets.
    func testCustomMonthBucketsAreClippedToTheRange() {
        let p = StatsPeriod.custom(start: day(2026, 3, 10), end: day(2026, 6, 20), today: day(2026, 11, 18), calendar: cal)
        XCTAssertEqual(p.granularity, .month)
        let b = p.buckets(calendar: cal)
        XCTAssertEqual(b.count, 4)
        XCTAssertEqual(b.first?.start, day(2026, 3, 10))
        XCTAssertEqual(b.first?.end, day(2026, 3, 31))
        XCTAssertEqual(b.first?.anchor, day(2026, 3, 1))  // drawn at its month, requested clipped
        XCTAssertEqual(b.last?.start, day(2026, 6, 1))
        XCTAssertEqual(b.last?.end, day(2026, 6, 20))
        XCTAssertEqual(b.map { $0.start }.count, Set(b.map { $0.start }).count)
        for (a, n) in zip(b, b.dropFirst()) { XCTAssertEqual(cal.date(byAdding: .day, value: 1, to: a.end), n.start) }
    }

    func testCustomYearBucketsAreClipped() {
        let p = StatsPeriod.custom(start: day(2019, 8, 5), end: day(2026, 2, 3), today: day(2026, 11, 18), calendar: cal)
        XCTAssertEqual(p.granularity, .year)
        let b = p.buckets(calendar: cal)
        XCTAssertEqual(b.count, 8)
        XCTAssertEqual(b.first?.start, day(2019, 8, 5))
        XCTAssertEqual(b.first?.end, day(2019, 12, 31))
        XCTAssertEqual(b.last?.end, day(2026, 2, 3))
    }

    func testCacheKeys() {
        let today = day(2026, 11, 18)
        let a = StatsPeriod.custom(start: day(2026, 11, 1), end: day(2026, 11, 10), today: today, calendar: cal)
        let same = StatsPeriod.custom(start: day(2026, 11, 1), end: day(2026, 11, 10), today: today, calendar: cal)
        let other = StatsPeriod.custom(start: day(2026, 11, 1), end: day(2026, 11, 11), today: today, calendar: cal)
        XCTAssertEqual(a.cacheKey(calendar: cal), "custom/2026-11-01/2026-11-10")
        XCTAssertEqual(a.cacheKey(calendar: cal), same.cacheKey(calendar: cal))
        XCTAssertNotEqual(a.cacheKey(calendar: cal), other.cacheKey(calendar: cal))
        XCTAssertEqual(StatsPeriod.make(.week, offset: 2, today: today, calendar: cal).cacheKey(calendar: cal), "1W/2")
        XCTAssertEqual(StatsPeriod.make(.all, today: today, calendar: cal).cacheKey(calendar: cal), "All/0")
    }

    func testDayCaptionsShowTheYearOutsideThisYear() {
        let today = day(2026, 11, 18)
        let thisYear = StatsPeriod.custom(start: day(2026, 11, 1), end: day(2026, 11, 10), today: today, calendar: cal)
        XCTAssertFalse(thisYear.caption(today: today, calendar: cal).contains("2026"))
        let across = StatsPeriod.custom(start: day(2025, 12, 20), end: day(2026, 1, 10), today: today, calendar: cal)
        let c = across.caption(today: today, calendar: cal)
        XCTAssertTrue(c.contains("2025") && c.contains("2026"), c)
        let old = StatsPeriod.custom(start: day(2024, 11, 12), end: day(2024, 11, 18), today: today, calendar: cal)
        XCTAssertTrue(old.caption(today: today, calendar: cal).contains("2024"))
    }

    func testAllClampsFutureFirstCheckin() {
        let today = day(2026, 11, 18)
        let future = day(2026, 11, 20)
        let p = StatsPeriod.make(.all, today: today, firstCheckin: future, calendar: cal)
        XCTAssertEqual(p.start, today)
        XCTAssertEqual(p.end, today)
        XCTAssertGreaterThanOrEqual(p.dayCount(calendar: cal), 1)
        XCTAssertEqual(p.dayCount(calendar: cal), 1)
        XCTAssertFalse(p.buckets(calendar: cal).isEmpty)
        XCTAssertEqual(p.buckets(calendar: cal).count, 1)
    }

    func testCustomCaptionsAlwaysShowDayPrecision() {
        let today = day(2026, 11, 18)
        let monthsSameYear = StatsPeriod.custom(start: day(2026, 3, 10), end: day(2026, 6, 20), today: today, calendar: cal)
        XCTAssertEqual(monthsSameYear.granularity, .month)
        let c1 = monthsSameYear.caption(today: today, calendar: cal)
        XCTAssertTrue(c1.contains("10") && c1.contains("20"), c1)
        XCTAssertFalse(c1.contains("2026"), c1)

        let monthsCrossYear = StatsPeriod.custom(start: day(2025, 3, 10), end: day(2026, 6, 20), today: today, calendar: cal)
        XCTAssertEqual(monthsCrossYear.granularity, .month)
        let c2 = monthsCrossYear.caption(today: today, calendar: cal)
        XCTAssertTrue(c2.contains("10") && c2.contains("20") && c2.contains("2025") && c2.contains("2026"), c2)

        let years = StatsPeriod.custom(start: day(2019, 8, 5), end: day(2026, 2, 3), today: today, calendar: cal)
        XCTAssertEqual(years.granularity, .year)
        let c3 = years.caption(today: today, calendar: cal)
        XCTAssertTrue(c3.contains("5") && c3.contains("3") && c3.contains("2019") && c3.contains("2026"), c3)
    }
}
