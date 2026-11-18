import XCTest
import SwiftUI
@testable import Retappd

final class ToastPartnerTests: XCTestCase {
    func testEveryCombination() {
        for toasts in [0, 3] {
            for friends in [false, true] {
                for purchase in [false, true] {
                    let got = ToastPartner.choose(toasts: toasts, friends: friends, purchase: purchase, hasToastButton: true)
                    let want: ToastPartner = toasts > 0 ? .toasts : friends ? .friends : purchase ? .purchase : .none
                    XCTAssertEqual(got, want, "toasts \(toasts) friends \(friends) purchase \(purchase)")
                }
            }
        }
    }

    func testShopKeepsItsRowWithoutAToastButton() {
        XCTAssertEqual(ToastPartner.choose(toasts: 0, friends: false, purchase: true, hasToastButton: false), .none)
    }

    @MainActor
    func testPhotoButtonRowKeepsLabelsAndEqualPadding() {
        // Screen widths: 375 (SE/mini), 390 (14), 393 (16/17), 402 (18 Pro).
        // Hero left column width is screenWidth - 32 (margins) - 14 (spacing) - 112 (glass) = screenWidth - 158.
        for screenWidth: CGFloat in [375, 390, 393, 402] {
            let columnWidth = screenWidth - 158
            var measured: [String: CGFloat] = [:]
            let row = TaproomButtonRow(spacing: 8) {
                Button {} label: {
                    ViewThatFits(in: .horizontal) {
                        Label("Camera", systemImage: "camera").lineLimit(1)
                            .background(GeometryReader { g in Color.clear.onAppear { measured["cameraLabel"] = g.size.width } })
                            .padding(.horizontal, 4)
                        Image(systemName: "camera")
                            .background(GeometryReader { g in Color.clear.onAppear { measured["cameraIcon"] = g.size.width } })
                    }
                }
                .buttonStyle(TaproomOutlineButton())
                .background(GeometryReader { g in Color.clear.onAppear { measured["cameraBtn"] = g.size.width } })
                Button {} label: {
                    ViewThatFits(in: .horizontal) {
                        Label("Last", systemImage: "clock.arrow.circlepath").lineLimit(1)
                            .background(GeometryReader { g in Color.clear.onAppear { measured["lastLabel"] = g.size.width } })
                            .padding(.horizontal, 4)
                        Image(systemName: "clock.arrow.circlepath")
                            .background(GeometryReader { g in Color.clear.onAppear { measured["lastIcon"] = g.size.width } })
                    }
                }
                .buttonStyle(TaproomOutlineButton())
                .background(GeometryReader { g in Color.clear.onAppear { measured["lastBtn"] = g.size.width } })
                Button {} label: {
                    Image(systemName: "photo.on.rectangle")
                }
                .buttonStyle(TaproomOutlineButton())
                .frame(width: 44)
                .fixedInButtonRow()
            }
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: screenWidth, height: 200))
            let host = UIHostingController(rootView: row.frame(width: columnWidth))
            window.rootViewController = host
            window.makeKeyAndVisible()
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))

            XCTAssertNotNil(measured["cameraLabel"], "Camera label missing at \(screenWidth)pt")
            XCTAssertNotNil(measured["lastLabel"], "Last label missing at \(screenWidth)pt")
            XCTAssertNil(measured["cameraIcon"], "Camera fell back to icon at \(screenWidth)pt")
            XCTAssertNil(measured["lastIcon"], "Last fell back to icon at \(screenWidth)pt")
            if let camBtn = measured["cameraBtn"], let camLbl = measured["cameraLabel"],
               let lastBtn = measured["lastBtn"], let lastLbl = measured["lastLabel"] {
                XCTAssertEqual(camBtn - camLbl, lastBtn - lastLbl, accuracy: 0.5, "Unequal padding at \(screenWidth)pt")
            }
        }
    }
}
