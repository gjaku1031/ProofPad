import XCTest
@testable import pdf_wacom

final class RecentFileRowTests: XCTestCase {
    func testPerformClickOpensRepresentedURL() {
        let url = URL(fileURLWithPath: "/tmp/recent-row.pdf")
        var openedURL: URL?
        let row = RecentFileRow(url: url) { openedURL = $0 }

        row.performClick(nil)

        XCTAssertEqual(openedURL, url)
    }
}
