import XCTest
@testable import Retappd

final class PendingRemindersTests: XCTestCase {
    private var london: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/London")!
        return c
    }()

    private func date(_ s: String) -> Date {
        let f = ISO8601DateFormatter()
        return f.date(from: s)!
    }

    func testNextMorning() {
        // Saved just after midnight: the same morning.
        XCTAssertEqual(PendingReminders.nextMorning(after: date("2026-11-22T00:31:00Z"), calendar: london),
                       date("2026-11-22T10:00:00Z"))
        // Saved in the evening: the next morning.
        XCTAssertEqual(PendingReminders.nextMorning(after: date("2026-11-21T21:40:00Z"), calendar: london),
                       date("2026-11-22T10:00:00Z"))
        // Saved at 9 AM: less than 3 hours to go, so the day after.
        XCTAssertEqual(PendingReminders.nextMorning(after: date("2026-11-22T09:00:00Z"), calendar: london),
                       date("2026-11-23T10:00:00Z"))
    }

    func testContentRoutesToTheList() {
        let c = PendingReminders.content(count: 3, online: true)
        XCTAssertEqual(c.body, "You have 3 beers to check in. Tap to finish them.")
        XCTAssertEqual(NotificationRoute(userInfo: c.userInfo), .pendingCheckins)
        XCTAssertTrue(PendingReminders.content(count: 1, online: false).body.contains("1 beer saved"))
    }
}
