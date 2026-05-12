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

    func testHomeToolsContainsCheckForUpdatesButton() {
        let viewController = HomeViewController()
        var didCheck = false
        viewController.onCheckForUpdates = {
            didCheck = true
        }

        _ = viewController.view
        let button = findButton(titled: "Check for Updates...", in: viewController.view)

        XCTAssertNotNil(button)
        button?.performClick(nil)
        XCTAssertTrue(didCheck)
    }

    private func findButton(titled title: String, in view: NSView) -> NSButton? {
        if let button = view as? NSButton, button.title == title {
            return button
        }
        for subview in view.subviews {
            if let match = findButton(titled: title, in: subview) {
                return match
            }
        }
        return nil
    }
}
