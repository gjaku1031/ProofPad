import Cocoa
import XCTest
@testable import ProofPad

final class UpdateMenuTests: XCTestCase {
    func testAppMenuContainsCheckForUpdatesItem() {
        let updateTarget = NSObject()
        let menu = MainMenuBuilder.build(updateController: updateTarget)
        let appMenu = menu.items.first?.submenu

        let item = appMenu?.items.first {
            $0.title == "Check for Updates…"
        }

        XCTAssertEqual(item?.action, Selector(("checkForUpdates:")))
        XCTAssertTrue(item?.target === updateTarget)
    }
}
