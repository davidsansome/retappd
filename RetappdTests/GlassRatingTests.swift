import XCTest
@testable import Retappd

@MainActor
final class GlassRatingTests: XCTestCase {
    // MARK: - snap

    func testSnapQuarterSteps() {
        XCTAssertEqual(GlassRating.snap(0, step: 0.25), 0)
        XCTAssertEqual(GlassRating.snap(0.1, step: 0.25), 0)
        XCTAssertEqual(GlassRating.snap(0.13, step: 0.25), 0.25)
        XCTAssertEqual(GlassRating.snap(3.62, step: 0.25), 3.5)
        XCTAssertEqual(GlassRating.snap(3.63, step: 0.25), 3.75)
        XCTAssertEqual(GlassRating.snap(4.88, step: 0.25), 5.0)
    }

    func testSnapTenthSteps() {
        XCTAssertEqual(GlassRating.snap(0, step: 0.1), 0)
        XCTAssertEqual(GlassRating.snap(0.04, step: 0.1), 0)
        XCTAssertEqual(GlassRating.snap(0.06, step: 0.1), 0.1)
        XCTAssertEqual(GlassRating.snap(3.74, step: 0.1), 3.7)
        XCTAssertEqual(GlassRating.snap(3.75, step: 0.1), 3.8)
        XCTAssertEqual(GlassRating.snap(4.96, step: 0.1), 5.0)
    }

    func testSnapClampsOutOfRangeValues() {
        XCTAssertEqual(GlassRating.snap(-2.0, step: 0.25), 0)
        XCTAssertEqual(GlassRating.snap(-0.5, step: 0.1), 0)
        XCTAssertEqual(GlassRating.snap(5.5, step: 0.25), 5.0)
        XCTAssertEqual(GlassRating.snap(7.2, step: 0.1), 5.0)
    }

    // MARK: - format

    func testFormatQuarterStepsUsesTwoDecimals() {
        XCTAssertEqual(GlassRating.format(0, step: 0.25), "0.00")
        XCTAssertEqual(GlassRating.format(3.5, step: 0.25), "3.50")
        XCTAssertEqual(GlassRating.format(4.25, step: 0.25), "4.25")
        XCTAssertEqual(GlassRating.format(5, step: 0.25), "5.00")
    }

    func testFormatTenthStepsUsesOneDecimal() {
        XCTAssertEqual(GlassRating.format(0, step: 0.1), "0.0")
        XCTAssertEqual(GlassRating.format(3.5, step: 0.1), "3.5")
        XCTAssertEqual(GlassRating.format(4.7, step: 0.1), "4.7")
        XCTAssertEqual(GlassRating.format(5, step: 0.1), "5.0")
    }

    // MARK: - prefillTarget

    func testPrefillTargetReturnsNilForNilZeroAndNegative() {
        XCTAssertNil(GlassRating.prefillTarget(lastRating: nil, step: 0.25))
        XCTAssertNil(GlassRating.prefillTarget(lastRating: nil, step: 0.1))
        XCTAssertNil(GlassRating.prefillTarget(lastRating: 0, step: 0.25))
        XCTAssertNil(GlassRating.prefillTarget(lastRating: 0, step: 0.1))
        XCTAssertNil(GlassRating.prefillTarget(lastRating: -0.25, step: 0.25))
        XCTAssertNil(GlassRating.prefillTarget(lastRating: -1.5, step: 0.1))
    }

    func testPrefillTargetSnapsValidRatings() {
        XCTAssertEqual(GlassRating.prefillTarget(lastRating: 3.75, step: 0.25), 3.75)
        XCTAssertEqual(GlassRating.prefillTarget(lastRating: 3.7, step: 0.25), 3.75)
        XCTAssertEqual(GlassRating.prefillTarget(lastRating: 3.75, step: 0.1), 3.8)
        XCTAssertEqual(GlassRating.prefillTarget(lastRating: 4.2, step: 0.1), 4.2)
    }

    func testPrefillTargetClampsSmallPositiveRatingsToStep() {
        XCTAssertEqual(GlassRating.prefillTarget(lastRating: 0.01, step: 0.25), 0.25)
        XCTAssertEqual(GlassRating.prefillTarget(lastRating: 0.1, step: 0.25), 0.25)
        XCTAssertEqual(GlassRating.prefillTarget(lastRating: 0.01, step: 0.1), 0.1)
        XCTAssertEqual(GlassRating.prefillTarget(lastRating: 0.04, step: 0.1), 0.1)
    }

    func testPrefillTargetClampsRatingsAboveFive() {
        XCTAssertEqual(GlassRating.prefillTarget(lastRating: 5.5, step: 0.25), 5.0)
        XCTAssertEqual(GlassRating.prefillTarget(lastRating: 6.0, step: 0.1), 5.0)
    }
}
