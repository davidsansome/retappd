import XCTest
import CoreImage
@testable import Retappd

final class FriendQRCodeTests: XCTestCase {
    func testCanonicalNamecardURL() {
        XCTAssertEqual(FriendQRCode.url(forUserID: 123456).absoluteString,
                       "https://untappd.com/qr/namecard/123456")
    }

    func testRenderedQRCodeRoundTripsThroughCoreImageDetector() throws {
        let url = FriendQRCode.url(forUserID: 123456)
        let image = try XCTUnwrap(FriendQRCode.renderQRCode(for: url))
        let cgImage = try XCTUnwrap(image.cgImage)

        let detector = try XCTUnwrap(CIDetector(ofType: CIDetectorTypeQRCode, context: nil,
                                                options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]))
        let features = detector.features(in: CIImage(cgImage: cgImage))
        let payloads = features.compactMap { ($0 as? CIQRCodeFeature)?.messageString }
        XCTAssertEqual(payloads, ["https://untappd.com/qr/namecard/123456"])
    }

    func testParsesValidUntappdQRPayloads() {
        XCTAssertEqual(FriendQRCode.parse("https://untappd.com/qr/namecard/123456"), .userID(123456))
        XCTAssertEqual(FriendQRCode.parse("  http://www.untappd.com/qr/namecard/123456/  "), .userID(123456))
        XCTAssertEqual(FriendQRCode.parse("https://UNTAPPD.COM/qr/namecard/123456?v=2"), .userID(123456))
        XCTAssertEqual(FriendQRCode.parse("https://untappd.com/user/sampleuser"), .username("sampleuser"))
        XCTAssertEqual(FriendQRCode.parse("https://www.untappd.com/user/HopLover_/"), .username("HopLover_"))
        XCTAssertEqual(FriendQRCode.parse("untappd://user/sampleuser/0"), .username("sampleuser"))
    }

    func testRejectsNonFriendQRPayloads() {
        XCTAssertNil(FriendQRCode.parse(""))
        XCTAssertNil(FriendQRCode.parse("not a url"))
        XCTAssertNil(FriendQRCode.parse("https://example.com/qr/namecard/123456"))
        XCTAssertNil(FriendQRCode.parse("https://untappd.com/qr/namecard/0"))
        XCTAssertNil(FriendQRCode.parse("https://untappd.com/qr/namecard/-42"))
        XCTAssertNil(FriendQRCode.parse("https://untappd.com/qr/namecard/abc"))
        XCTAssertNil(FriendQRCode.parse("https://untappd.com/b/some-beer/12345"))
        XCTAssertNil(FriendQRCode.parse("untappd://beer/12345"))
    }

    func testExtractsUsernameFromNamecardHTML() {
        let html = """
        <div class="beer-detail">
            <a href="/user/sampleuser" class="a-btn">Continue</a>
        </div>
        <script>
            var pageType = "user";
            var id = "sampleuser";
        </script>
        """
        XCTAssertEqual(FriendQRCode.extractUsername(fromNamecardHTML: html), "sampleuser")

        let scriptOnly = #"var pageType = "user"; var id = "HopLover_";"#
        XCTAssertEqual(FriendQRCode.extractUsername(fromNamecardHTML: scriptOnly), "HopLover_")

        XCTAssertNil(FriendQRCode.extractUsername(fromNamecardHTML: "<html><body>Nothing here</body></html>"))
    }

    private func makeProfile(id: Int, username: String, relationship: String = "none") throws -> UserInfo.Profile {
        try UntappdAPI.decode(UserInfo.self, from: Data("""
        {"meta":{"code":200},"response":{"user":{"uid":\(id),"user_name":"\(username)","relationship":"\(relationship)"}}}
        """.utf8)).user!
    }

    func testResolveUserIDVerifiesReturnedProfileMatchesUID() async throws {
        let expected = try makeProfile(id: 123456, username: "sampleuser")
        let resolved = try await FriendQRCode.resolve(
            .userID(123456),
            fetchNamecardHTML: { url in
                XCTAssertEqual(url.absoluteString, "https://untappd.com/qr/namecard/123456")
                return #"<a href="/user/sampleuser">Continue</a>"#
            },
            fetchUserInfo: { name in
                XCTAssertEqual(name, "sampleuser")
                return expected
            }
        )
        XCTAssertEqual(resolved?.id, 123456)
        XCTAssertEqual(resolved?.userName, "sampleuser")
    }

    func testResolveUnknownUserIDRejectsYouFallback() async throws {
        // Untappd's /qr/namecard/<unknown> falls back to /user/You, a real account whose uid won't
        // match the requested one; the uid check must reject it.
        let youProfile = try makeProfile(id: 1002, username: "You")
        let resolved = try await FriendQRCode.resolve(
            .userID(9_999_999_999),
            fetchNamecardHTML: { _ in #"<a href="/user/You">Continue</a>"# },
            fetchUserInfo: { _ in youProfile }
        )
        XCTAssertNil(resolved)
    }

    func testResolveUsernameSkipsNamecardHTMLFetch() async throws {
        let expected = try makeProfile(id: 42, username: "alice")
        let resolved = try await FriendQRCode.resolve(
            .username("alice"),
            fetchNamecardHTML: { _ in
                XCTFail("Should not fetch namecard HTML for a username target")
                return ""
            },
            fetchUserInfo: { name in
                XCTAssertEqual(name, "alice")
                return expected
            }
        )
        XCTAssertEqual(resolved?.id, 42)
    }
}
