import XCTest
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
}
