import XCTest
@testable import Retappd

final class PhotoViewerTests: XCTestCase {
    // MARK: - Zoom Rect

    func testZoomRectCenteredAtScale() {
        let rect = PhotoViewerZoom.zoomRect(
            scale: 2.5,
            center: CGPoint(x: 200, y: 150),
            in: CGSize(width: 400, height: 800)
        )
        XCTAssertEqual(rect.width, 160, accuracy: 0.001)
        XCTAssertEqual(rect.height, 320, accuracy: 0.001)
        XCTAssertEqual(rect.midX, 200, accuracy: 0.001)
        XCTAssertEqual(rect.midY, 150, accuracy: 0.001)
    }

    func testZoomRectOffCenter() {
        let rect = PhotoViewerZoom.zoomRect(
            scale: 2.0,
            center: CGPoint(x: 50, y: 75),
            in: CGSize(width: 300, height: 600)
        )
        XCTAssertEqual(rect.origin.x, -25, accuracy: 0.001)
        XCTAssertEqual(rect.origin.y, -75, accuracy: 0.001)
        XCTAssertEqual(rect.width, 150, accuracy: 0.001)
        XCTAssertEqual(rect.height, 300, accuracy: 0.001)
    }

    func testZoomRectInvalidInputsReturnZero() {
        XCTAssertEqual(PhotoViewerZoom.zoomRect(scale: 0, center: .zero, in: CGSize(width: 100, height: 100)), .zero)
        XCTAssertEqual(PhotoViewerZoom.zoomRect(scale: -2, center: .zero, in: CGSize(width: 100, height: 100)), .zero)
        XCTAssertEqual(PhotoViewerZoom.zoomRect(scale: 2, center: .zero, in: CGSize(width: 0, height: 100)), .zero)
    }

    // MARK: - Aspect Fit Size

    func testAspectFitLandscapeInPortrait() {
        let fitted = PhotoViewerZoom.aspectFitSize(
            imageSize: CGSize(width: 1600, height: 800),
            in: CGSize(width: 400, height: 800)
        )
        XCTAssertEqual(fitted.width, 400, accuracy: 0.001)
        XCTAssertEqual(fitted.height, 200, accuracy: 0.001)
    }

    func testAspectFitPortraitInLandscape() {
        let fitted = PhotoViewerZoom.aspectFitSize(
            imageSize: CGSize(width: 600, height: 1200),
            in: CGSize(width: 800, height: 400)
        )
        XCTAssertEqual(fitted.width, 200, accuracy: 0.001)
        XCTAssertEqual(fitted.height, 400, accuracy: 0.001)
    }

    func testAspectFitSquareInPortrait() {
        let fitted = PhotoViewerZoom.aspectFitSize(
            imageSize: CGSize(width: 1000, height: 1000),
            in: CGSize(width: 393, height: 852)
        )
        XCTAssertEqual(fitted.width, 393, accuracy: 0.001)
        XCTAssertEqual(fitted.height, 393, accuracy: 0.001)
    }

    func testAspectFitZeroDimensionsReturnZero() {
        XCTAssertEqual(PhotoViewerZoom.aspectFitSize(imageSize: .zero, in: CGSize(width: 400, height: 800)), .zero)
        XCTAssertEqual(PhotoViewerZoom.aspectFitSize(imageSize: CGSize(width: 100, height: 100), in: .zero), .zero)
    }

    // MARK: - Swipe-to-Dismiss Progress & Thresholds

    func testDismissProgress() {
        XCTAssertEqual(PhotoViewerZoom.dismissProgress(translationY: 0, maxDistance: 300), 0, accuracy: 0.001)
        XCTAssertEqual(PhotoViewerZoom.dismissProgress(translationY: -50, maxDistance: 300), 0, accuracy: 0.001)
        XCTAssertEqual(PhotoViewerZoom.dismissProgress(translationY: 150, maxDistance: 300), 0.5, accuracy: 0.001)
        XCTAssertEqual(PhotoViewerZoom.dismissProgress(translationY: 450, maxDistance: 300), 1.0, accuracy: 0.001)
        XCTAssertEqual(PhotoViewerZoom.dismissProgress(translationY: 100, maxDistance: 0), 0, accuracy: 0.001)
    }

    func testShouldDismissThresholds() {
        // Below both distance and velocity thresholds
        XCTAssertFalse(PhotoViewerZoom.shouldDismiss(translationY: 80, velocityY: 200))
        // Exactly at distance threshold (requires > 110)
        XCTAssertFalse(PhotoViewerZoom.shouldDismiss(translationY: 110, velocityY: 0))
        // Over distance threshold even with zero velocity
        XCTAssertTrue(PhotoViewerZoom.shouldDismiss(translationY: 111, velocityY: 0))
        // Fast downward flick with small drag
        XCTAssertTrue(PhotoViewerZoom.shouldDismiss(translationY: 20, velocityY: 750))
        // Upward drag does not dismiss
        XCTAssertFalse(PhotoViewerZoom.shouldDismiss(translationY: -150, velocityY: -900))
        XCTAssertFalse(PhotoViewerZoom.shouldDismiss(translationY: 0, velocityY: 900))
    }

    // MARK: - UserInfo.Profile Avatar Decoding

    func testUserInfoProfileDecodesHDAndThumbAvatars() throws {
        let json = """
        {
          "uid": 42,
          "user_name": "hophead",
          "first_name": "Alex",
          "last_name": "P",
          "user_avatar": "https://assets.untappd.com/profile/abc_100x100.jpg",
          "user_avatar_hd": "https://assets.untappd.com/profile/abc_hd.jpg"
        }
        """
        let profile = try JSONDecoder().decode(UserInfo.Profile.self, from: Data(json.utf8))
        XCTAssertEqual(profile.avatar?.absoluteString, "https://assets.untappd.com/profile/abc_hd.jpg")
        XCTAssertEqual(profile.avatarThumb?.absoluteString, "https://assets.untappd.com/profile/abc_100x100.jpg")
    }

    func testUserInfoProfileFallsBackToThumbWhenHDMissing() throws {
        let json = """
        {
          "uid": 42,
          "user_name": "hophead",
          "user_avatar": "https://assets.untappd.com/profile/abc_100x100.jpg"
        }
        """
        let profile = try JSONDecoder().decode(UserInfo.Profile.self, from: Data(json.utf8))
        XCTAssertEqual(profile.avatar?.absoluteString, "https://assets.untappd.com/profile/abc_100x100.jpg")
        XCTAssertEqual(profile.avatarThumb?.absoluteString, "https://assets.untappd.com/profile/abc_100x100.jpg")
    }
}
