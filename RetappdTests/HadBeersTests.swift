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

    @MainActor func testFallsBackUntilLoadedThenAuthoritative() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("had-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = HadBeers(url: url)
        XCTAssertTrue(store.has(5, fallback: true))
        XCTAssertFalse(store.has(5, fallback: nil))
        store.add(7)
        XCTAssertTrue(store.has(7))
    }
}
