import XCTest
import SwiftUI
@testable import Retappd

final class BeerViewTests: XCTestCase {
    @MainActor
    func testBreweryLinkTapTargetIsAtLeast44ptAndFillsColumn() {
        // Hero left column on a 375pt screen: 375 - 32 (margins) - 14 (spacing) - 96 (label) = 233pt.
        let columnWidth: CGFloat = 233
        var labelSize: CGSize = .zero
        var layoutSize: CGSize = .zero

        let view = NavigationStack {
            NavigationLink(value: BeerBreweryRoute.brewery(id: 1, name: "Moo")) {
                TaproomLinkLabel("Moo", font: .subheadline, chevronSize: 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(GeometryReader { g in
                        Color.clear.onAppear { labelSize = g.size }
                    })
            }
            .buttonStyle(TaproomLinkStyle(extend: BeerView.breweryTapExtend))
            .background(GeometryReader { g in
                Color.clear.onAppear { layoutSize = g.size }
            })
            .frame(width: columnWidth, alignment: .leading)
        }

        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 375, height: 200))
        let host = UIHostingController(rootView: view)
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        let hitTargetHeight = labelSize.height + 2 * BeerView.breweryTapExtend
        XCTAssertGreaterThanOrEqual(hitTargetHeight, 44, "Brewery link hit target height should be >= 44pt, got \(hitTargetHeight)")
        XCTAssertEqual(labelSize.width, columnWidth, accuracy: 0.5, "Brewery link should span the full hero column width")
        XCTAssertEqual(layoutSize.height, labelSize.height, accuracy: 0.5, "Extended hit target should not inflate visual layout height")
    }
}
