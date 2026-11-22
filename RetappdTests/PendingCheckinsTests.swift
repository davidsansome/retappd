import CoreLocation
import XCTest
@testable import Retappd

@MainActor
final class PendingCheckinsTests: XCTestCase {
    private func tempDir() -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("pending-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private let beer = BeerLite(bid: 5, name: "Jaipur", brewery: "Thornbridge")

    func testAddKeepsNewestFirstAndPersists() {
        let dir = tempDir()
        let s = PendingCheckins(directory: dir, currentUser: { "ann" })
        s.add(PendingCheckin(username: "", savedAt: Date(timeIntervalSince1970: 100), query: "hazy"))
        s.add(PendingCheckin(username: "", savedAt: Date(timeIntervalSince1970: 200), beer: beer, rating: 3.75))
        XCTAssertEqual(s.items.map(\.title), ["Jaipur", "“hazy”"])
        XCTAssertEqual(s.items.first?.username, "ann")

        let reloaded = PendingCheckins(directory: dir, currentUser: { "ann" })
        XCTAssertEqual(reloaded.items.map(\.title), ["Jaipur", "“hazy”"])
        XCTAssertEqual(reloaded.items.first?.rating, 3.75)
    }

    func testOnlyTheSignedInAccountsShow() {
        let dir = tempDir()
        PendingCheckins(directory: dir, currentUser: { "ann" }).add(PendingCheckin(username: "", savedAt: .now, query: "a"))
        XCTAssertTrue(PendingCheckins(directory: dir, currentUser: { "bob" }).items.isEmpty)
        XCTAssertTrue(PendingCheckins(directory: dir, currentUser: { nil }).items.isEmpty)
        XCTAssertNil(PendingCheckins(directory: dir, currentUser: { nil }).add(PendingCheckin(username: "", savedAt: .now)))
        XCTAssertEqual(PendingCheckins(directory: dir, currentUser: { "ann" }).items.count, 1)
    }

    func testPhotoIsKeptAndRemovedWithItsCheckin() throws {
        let dir = tempDir()
        let s = PendingCheckins(directory: dir, currentUser: { "ann" })
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0x00])
        let item = try XCTUnwrap(s.add(PendingCheckin(username: "", savedAt: .now, beer: beer), photo: jpeg))
        XCTAssertTrue(item.hasPhoto)
        XCTAssertEqual(s.photo(for: item), jpeg)
        s.remove(item.id)
        XCTAssertTrue(s.items.isEmpty)
        XCTAssertNil(s.photo(for: item))
        XCTAssertTrue(PendingCheckins(directory: dir, currentUser: { "ann" }).items.isEmpty)
    }

    func testLocation() {
        var item = PendingCheckin(username: "ann", savedAt: .now)
        XCTAssertNil(item.location)
        item.setLocation(CLLocation(coordinate: .init(latitude: 51.53, longitude: -0.12), altitude: 0,
                                    horizontalAccuracy: 65, verticalAccuracy: -1, timestamp: .now))
        XCTAssertEqual(item.lat, 51.53)
        XCTAssertEqual(item.accuracy, 65)
        XCTAssertEqual(item.location?.coordinate.longitude, -0.12)
    }
}
