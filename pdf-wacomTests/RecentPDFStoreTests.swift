import XCTest
@testable import pdf_wacom

final class RecentPDFStoreTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var tempDirectory: URL!

    override func setUp() {
        super.setUp()
        suiteName = "RecentPDFStoreTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecentPDFStoreTests-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDirectory)
        defaults.removePersistentDomain(forName: suiteName)
        tempDirectory = nil
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testKeepsMostRecentTwentyPDFs() {
        let store = makeStore()

        for index in 0..<25 {
            store.noteOpened(makePDF(named: "doc-\(index).pdf"))
        }

        let urls = store.recentURLs(includeSystemRecents: false)
        XCTAssertEqual(urls.count, 20)
        XCTAssertEqual(urls.first?.lastPathComponent, "doc-24.pdf")
        XCTAssertEqual(urls.last?.lastPathComponent, "doc-5.pdf")
    }

    func testDuplicateMovesToFrontWithoutGrowingList() {
        let store = makeStore()
        let first = makePDF(named: "first.pdf")
        let second = makePDF(named: "second.pdf")

        store.noteOpened(first)
        store.noteOpened(second)
        store.noteOpened(first)

        let urls = store.recentURLs(includeSystemRecents: false)
        XCTAssertEqual(urls.map(\.lastPathComponent), ["first.pdf", "second.pdf"])
    }

    func testIgnoresNonPDFs() {
        let store = makeStore()

        store.noteOpened(makeFile(named: "image.png"))
        store.noteOpened(makePDF(named: "doc.pdf"))

        XCTAssertEqual(store.recentURLs(includeSystemRecents: false).map(\.lastPathComponent), ["doc.pdf"])
    }

    func testHidesMissingFiles() {
        let store = makeStore()
        let pdf = makePDF(named: "gone.pdf")

        store.noteOpened(pdf)
        try? FileManager.default.removeItem(at: pdf)

        XCTAssertTrue(store.recentURLs(includeSystemRecents: false).isEmpty)
    }

    private func makeStore() -> RecentPDFStore {
        RecentPDFStore(defaults: defaults,
                       defaultsKey: "RecentPDFStoreTests.urls",
                       mirrorsToSystemRecents: false,
                       systemRecentURLsProvider: { [] })
    }

    private func makePDF(named name: String) -> URL {
        makeFile(named: name)
    }

    private func makeFile(named name: String) -> URL {
        let url = tempDirectory.appendingPathComponent(name)
        _ = FileManager.default.createFile(atPath: url.path, contents: Data(), attributes: nil)
        return url
    }
}
