import XCTest
@testable import Retappd

final class LoginLayoutTests: XCTestCase {
    func testUnmeasuredViewportUsesSensibleDefault() {
        let zero = LoginLayoutMetrics.metrics(forViewportHeight: 0, isAccessibilitySize: false)
        let negative = LoginLayoutMetrics.metrics(forViewportHeight: -40, isAccessibilitySize: false)
        let nan = LoginLayoutMetrics.metrics(forViewportHeight: .nan, isAccessibilitySize: false)
        let expected = LoginLayoutMetrics.metrics(
            forViewportHeight: LoginLayoutMetrics.defaultViewportHeight,
            isAccessibilitySize: false
        )

        XCTAssertEqual(zero, expected)
        XCTAssertEqual(negative, expected)
        XCTAssertEqual(nan, expected)
        XCTAssertEqual(zero.tier, .generous)
        XCTAssertGreaterThanOrEqual(zero.glassHeight, 120)
        XCTAssertGreaterThanOrEqual(zero.fieldMinHeight, 44)
        XCTAssertTrue(zero.showSubtitle)
    }

    func testIPhoneSEWithKeyboardOpenUsesCompactTier() {
        let viewport: CGFloat = 220
        let m = LoginLayoutMetrics.metrics(forViewportHeight: viewport, isAccessibilitySize: false)

        XCTAssertEqual(m.tier, .compact)
        XCTAssertEqual(m.glassHeight, 58)
        XCTAssertEqual(m.titleSize, 28)
        XCTAssertEqual(m.topPadding, 4)
        XCTAssertEqual(m.sectionSpacing, 8)
        XCTAssertEqual(m.fieldMinHeight, 44)
        XCTAssertFalse(m.showSubtitle)
        XCTAssertLessThanOrEqual(m.estimatedContentHeight, viewport)
    }

    func testIPhoneSEWithoutKeyboardUsesGenerousTier() {
        let viewport: CGFloat = 520
        let m = LoginLayoutMetrics.metrics(forViewportHeight: viewport, isAccessibilitySize: false)

        XCTAssertEqual(m.tier, .generous)
        XCTAssertEqual(m.glassHeight, 520 * 0.28, accuracy: 0.01)
        XCTAssertEqual(m.titleSize, 46)
        XCTAssertEqual(m.topPadding, 16)
        XCTAssertEqual(m.sectionSpacing, Taproom.sectionSpacing)
        XCTAssertEqual(m.fieldMinHeight, 50)
        XCTAssertTrue(m.showSubtitle)
        XCTAssertLessThanOrEqual(m.estimatedContentHeight, viewport)
    }

    func testIPhone15WithKeyboardOpenFitsCompletelyAboveTheFold() {
        let viewport: CGFloat = 340
        let m = LoginLayoutMetrics.metrics(forViewportHeight: viewport, isAccessibilitySize: false)

        XCTAssertEqual(m.tier, .medium)
        XCTAssertEqual(m.glassHeight, 340 * 0.24, accuracy: 0.01)
        XCTAssertEqual(m.titleSize, 34, accuracy: 0.01)
        XCTAssertEqual(m.topPadding, 6)
        XCTAssertEqual(m.sectionSpacing, 10)
        XCTAssertEqual(m.fieldMinHeight, 44)
        XCTAssertFalse(m.showSubtitle)
        XCTAssertLessThan(m.estimatedContentHeight, 300)
        XCTAssertLessThanOrEqual(m.estimatedContentHeight, viewport)
    }

    func testIPhone15WithoutKeyboardUsesGenerousTier() {
        let viewport: CGFloat = 650
        let m = LoginLayoutMetrics.metrics(forViewportHeight: viewport, isAccessibilitySize: false)

        XCTAssertEqual(m.tier, .generous)
        XCTAssertEqual(m.glassHeight, 170)
        XCTAssertEqual(m.titleSize, 46)
        XCTAssertEqual(m.fieldMinHeight, 50)
        XCTAssertTrue(m.showSubtitle)
        XCTAssertLessThanOrEqual(m.estimatedContentHeight, viewport)
    }

    func testIPhone18ProWithKeyboardOpenFitsAboveTheFoldWithSubtitle() {
        let viewport: CGFloat = 370
        let m = LoginLayoutMetrics.metrics(forViewportHeight: viewport, isAccessibilitySize: false)

        XCTAssertEqual(m.tier, .medium)
        XCTAssertEqual(m.glassHeight, 370 * 0.24, accuracy: 0.01)
        XCTAssertEqual(m.titleSize, 37, accuracy: 0.01)
        XCTAssertEqual(m.fieldMinHeight, 44)
        XCTAssertTrue(m.showSubtitle)
        XCTAssertLessThan(m.estimatedContentHeight, 300)
        XCTAssertLessThanOrEqual(m.estimatedContentHeight, viewport)
    }

    func testIPhone18ProWithoutKeyboardUsesGenerousTier() {
        let viewport: CGFloat = 700
        let m = LoginLayoutMetrics.metrics(forViewportHeight: viewport, isAccessibilitySize: false)

        XCTAssertEqual(m.tier, .generous)
        XCTAssertEqual(m.glassHeight, 170)
        XCTAssertEqual(m.fieldMinHeight, 50)
        XCTAssertTrue(m.showSubtitle)
        XCTAssertLessThanOrEqual(m.estimatedContentHeight, viewport)
    }

    func testIPadUsesGenerousTierWithCappedGlass() {
        let viewport: CGFloat = 900
        let m = LoginLayoutMetrics.metrics(forViewportHeight: viewport, isAccessibilitySize: false)

        XCTAssertEqual(m.tier, .generous)
        XCTAssertEqual(m.glassHeight, 170)
        XCTAssertEqual(m.titleSize, 46)
        XCTAssertEqual(m.fieldMinHeight, 50)
        XCTAssertTrue(m.showSubtitle)
        XCTAssertLessThanOrEqual(m.estimatedContentHeight, viewport)
    }

    func testAccessibilitySizeCapsGlassAndPreservesMinimumTouchTarget() {
        for height: CGFloat in [0, 220, 340, 370, 520, 650, 900] {
            let m = LoginLayoutMetrics.metrics(forViewportHeight: height, isAccessibilitySize: true)
            XCTAssertLessThanOrEqual(
                m.glassHeight,
                LoginLayoutMetrics.accessibilityMaxGlassHeight,
                "Expected capped glass height at viewport \(height)"
            )
            XCTAssertGreaterThanOrEqual(
                m.fieldMinHeight,
                44,
                "Expected >= 44pt touch target at viewport \(height)"
            )
        }
    }

    func testTierAndSubtitleBoundaries() {
        XCTAssertEqual(LoginLayoutMetrics.metrics(forViewportHeight: 299, isAccessibilitySize: false).tier, .compact)
        XCTAssertEqual(LoginLayoutMetrics.metrics(forViewportHeight: 300, isAccessibilitySize: false).tier, .medium)
        XCTAssertFalse(LoginLayoutMetrics.metrics(forViewportHeight: 359, isAccessibilitySize: false).showSubtitle)
        XCTAssertTrue(LoginLayoutMetrics.metrics(forViewportHeight: 360, isAccessibilitySize: false).showSubtitle)
        XCTAssertEqual(LoginLayoutMetrics.metrics(forViewportHeight: 499, isAccessibilitySize: false).tier, .medium)
        XCTAssertEqual(LoginLayoutMetrics.metrics(forViewportHeight: 500, isAccessibilitySize: false).tier, .generous)
    }
}
