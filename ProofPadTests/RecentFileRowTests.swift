import XCTest
@testable import ProofPad

final class RecentFileRowTests: XCTestCase {
    func testMouseClickOpensRepresentedURL() {
        let url = URL(fileURLWithPath: "/tmp/recent-row.pdf")
        var openedURL: URL?
        let row = RecentFileRow(url: url) { openedURL = $0 }

        row.openFromMouseClick()

        XCTAssertEqual(openedURL, url)
    }

    func testTwentyRecentRowsOpenTheirOwnURLs() {
        var openedURLs: [URL] = []
        let rows = (1...20).map { index in
            let url = URL(fileURLWithPath: String(format: "/tmp/recent-row-%02d.pdf", index))
            return RecentFileRow(url: url) { openedURLs.append($0) }
        }

        rows.forEach { $0.openFromMouseClick() }

        XCTAssertEqual(openedURLs, (1...20).map {
            URL(fileURLWithPath: String(format: "/tmp/recent-row-%02d.pdf", $0))
        })
    }
}
