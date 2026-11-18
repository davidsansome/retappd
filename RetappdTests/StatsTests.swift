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
}
