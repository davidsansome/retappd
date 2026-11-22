import XCTest
import UIKit
@testable import Retappd

@MainActor
final class PhotoEditorTests: XCTestCase {
    private let accuracy: CGFloat = 0.001

    // MARK: - cropFrame

    func testCropFrameScaleDefaultIsEightyPercent() {
        XCTAssertEqual(PhotoEdit.cropFrameScale, 0.8, accuracy: accuracy)
    }

    func testCropFrameLandscapeIs80PercentOfContainerWidth() {
        let container = CGSize(width: 400, height: 800)
        let imageSize = CGSize(width: 1600, height: 900)

        let frame = PhotoEdit.cropFrame(for: imageSize, in: container)

        XCTAssertEqual(frame.width, container.width * 0.8, accuracy: accuracy)
        XCTAssertEqual(frame.height, 320 * (900.0 / 1600.0), accuracy: accuracy)
        XCTAssertEqual(frame.width / frame.height, imageSize.width / imageSize.height, accuracy: accuracy)
    }

    func testCropFramePortraitIs80PercentOfContainerHeightWhenHeightLimited() {
        let container = CGSize(width: 400, height: 600)
        let imageSize = CGSize(width: 600, height: 1200)

        let frame = PhotoEdit.cropFrame(for: imageSize, in: container)

        XCTAssertEqual(frame.height, container.height * 0.8, accuracy: accuracy)
        XCTAssertEqual(frame.width, 480 * (600.0 / 1200.0), accuracy: accuracy)
        XCTAssertEqual(frame.width / frame.height, imageSize.width / imageSize.height, accuracy: accuracy)
    }

    func testCropFramePortraitIs80PercentOfContainerWidthWhenWidthLimited() {
        let container = CGSize(width: 400, height: 800)
        let imageSize = CGSize(width: 900, height: 1200)

        let frame = PhotoEdit.cropFrame(for: imageSize, in: container)

        XCTAssertEqual(frame.width, container.width * 0.8, accuracy: accuracy)
        XCTAssertEqual(frame.height, 320 * (1200.0 / 900.0), accuracy: accuracy)
        XCTAssertEqual(frame.width / frame.height, imageSize.width / imageSize.height, accuracy: accuracy)
    }

    func testCropFrameSquareIs80PercentOfLimitingAxis() {
        let portraitContainer = CGSize(width: 390, height: 844)
        let square = CGSize(width: 1000, height: 1000)

        let frame = PhotoEdit.cropFrame(for: square, in: portraitContainer)

        XCTAssertEqual(frame.width, portraitContainer.width * 0.8, accuracy: accuracy)
        XCTAssertEqual(frame.height, portraitContainer.width * 0.8, accuracy: accuracy)

        let landscapeContainer = CGSize(width: 844, height: 390)
        let landscapeFrame = PhotoEdit.cropFrame(for: square, in: landscapeContainer)

        XCTAssertEqual(landscapeFrame.width, landscapeContainer.height * 0.8, accuracy: accuracy)
        XCTAssertEqual(landscapeFrame.height, landscapeContainer.height * 0.8, accuracy: accuracy)
    }

    // MARK: - clampedOffset

    func testClampedOffsetAtZoomOneIsAlwaysZero() {
        let frame = CGSize(width: 320, height: 240)
        let clamped = PhotoEdit.clampedOffset(CGSize(width: 50, height: -80), zoom: 1, frame: frame)
        XCTAssertEqual(clamped.width, 0, accuracy: accuracy)
        XCTAssertEqual(clamped.height, 0, accuracy: accuracy)
    }

    func testClampedOffsetBelowZoomOneIsAlwaysZero() {
        let frame = CGSize(width: 320, height: 240)
        let clamped = PhotoEdit.clampedOffset(CGSize(width: 25, height: -25), zoom: 0.5, frame: frame)
        XCTAssertEqual(clamped.width, 0, accuracy: accuracy)
        XCTAssertEqual(clamped.height, 0, accuracy: accuracy)
    }

    func testClampedOffsetPreservesInBoundsAndClampsExtremes() {
        let frame = CGSize(width: 320, height: 240)
        // At zoom = 2, max offset is (160, 120).
        let inside = PhotoEdit.clampedOffset(CGSize(width: 60, height: -40), zoom: 2, frame: frame)
        XCTAssertEqual(inside.width, 60, accuracy: accuracy)
        XCTAssertEqual(inside.height, -40, accuracy: accuracy)

        let positiveExtreme = PhotoEdit.clampedOffset(CGSize(width: 500, height: 500), zoom: 2, frame: frame)
        XCTAssertEqual(positiveExtreme.width, 160, accuracy: accuracy)
        XCTAssertEqual(positiveExtreme.height, 120, accuracy: accuracy)

        let negativeExtreme = PhotoEdit.clampedOffset(CGSize(width: -500, height: -500), zoom: 2, frame: frame)
        XCTAssertEqual(negativeExtreme.width, -160, accuracy: accuracy)
        XCTAssertEqual(negativeExtreme.height, -120, accuracy: accuracy)
    }

    // MARK: - cropRect

    func testCropRectAtZoomOneCoversFullImage() {
        let imageSize = CGSize(width: 1200, height: 800)
        let container = CGSize(width: 400, height: 800)
        let frame = PhotoEdit.cropFrame(for: imageSize, in: container)

        let rect = PhotoEdit.cropRect(imageSize: imageSize, frame: frame, zoom: 1, offset: .zero)

        XCTAssertEqual(rect.origin.x, 0, accuracy: accuracy)
        XCTAssertEqual(rect.origin.y, 0, accuracy: accuracy)
        XCTAssertEqual(rect.width, 1200, accuracy: accuracy)
        XCTAssertEqual(rect.height, 800, accuracy: accuracy)
    }

    func testCropRectAtZoomTwoCentered() {
        let imageSize = CGSize(width: 1200, height: 800)
        let container = CGSize(width: 400, height: 800)
        let frame = PhotoEdit.cropFrame(for: imageSize, in: container)

        let rect = PhotoEdit.cropRect(imageSize: imageSize, frame: frame, zoom: 2, offset: .zero)

        XCTAssertEqual(rect.origin.x, 300, accuracy: accuracy)
        XCTAssertEqual(rect.origin.y, 200, accuracy: accuracy)
        XCTAssertEqual(rect.width, 600, accuracy: accuracy)
        XCTAssertEqual(rect.height, 400, accuracy: accuracy)
    }

    func testCropRectAtZoomTwoTopLeftExtreme() {
        let imageSize = CGSize(width: 1200, height: 800)
        let container = CGSize(width: 400, height: 800)
        let frame = PhotoEdit.cropFrame(for: imageSize, in: container)

        // Dragging the image down-right (+x, +y) brings the top-left of the image into the frame.
        let rect = PhotoEdit.cropRect(
            imageSize: imageSize,
            frame: frame,
            zoom: 2,
            offset: CGSize(width: frame.width, height: frame.height)
        )

        XCTAssertEqual(rect.origin.x, 0, accuracy: accuracy)
        XCTAssertEqual(rect.origin.y, 0, accuracy: accuracy)
        XCTAssertEqual(rect.width, 600, accuracy: accuracy)
        XCTAssertEqual(rect.height, 400, accuracy: accuracy)
    }

    func testCropRectAtZoomTwoBottomRightExtreme() {
        let imageSize = CGSize(width: 1200, height: 800)
        let container = CGSize(width: 400, height: 800)
        let frame = PhotoEdit.cropFrame(for: imageSize, in: container)

        // Dragging the image up-left (-x, -y) brings the bottom-right of the image into the frame.
        let rect = PhotoEdit.cropRect(
            imageSize: imageSize,
            frame: frame,
            zoom: 2,
            offset: CGSize(width: -frame.width, height: -frame.height)
        )

        XCTAssertEqual(rect.origin.x, 600, accuracy: accuracy)
        XCTAssertEqual(rect.origin.y, 400, accuracy: accuracy)
        XCTAssertEqual(rect.width, 600, accuracy: accuracy)
        XCTAssertEqual(rect.height, 400, accuracy: accuracy)
    }

    func testCropRectAfterNinetyDegreeRotation() {
        let original = makeSolidImage(size: CGSize(width: 1200, height: 600))
        let rotated = PhotoEdit.rotated(original)

        XCTAssertEqual(rotated.size.width, 600, accuracy: accuracy)
        XCTAssertEqual(rotated.size.height, 1200, accuracy: accuracy)

        let container = CGSize(width: 400, height: 800)
        let frame = PhotoEdit.cropFrame(for: rotated.size, in: container)

        XCTAssertEqual(frame.width, 320, accuracy: accuracy)
        XCTAssertEqual(frame.height, 640, accuracy: accuracy)

        let centered = PhotoEdit.cropRect(imageSize: rotated.size, frame: frame, zoom: 2, offset: .zero)
        XCTAssertEqual(centered.origin.x, 150, accuracy: accuracy)
        XCTAssertEqual(centered.origin.y, 300, accuracy: accuracy)
        XCTAssertEqual(centered.width, 300, accuracy: accuracy)
        XCTAssertEqual(centered.height, 600, accuracy: accuracy)

        let cropped = PhotoEdit.cropped(rotated, to: centered)
        XCTAssertEqual(cropped.size.width, 300, accuracy: accuracy)
        XCTAssertEqual(cropped.size.height, 600, accuracy: accuracy)
    }

    private func makeSolidImage(size: CGSize) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            UIColor.systemAmberCompat.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }
    }
}

private extension UIColor {
    static let systemAmberCompat = UIColor(red: 0.91, green: 0.64, blue: 0.23, alpha: 1)
}
