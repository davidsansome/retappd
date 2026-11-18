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
}
