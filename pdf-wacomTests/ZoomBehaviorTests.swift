import Cocoa
import PDFKit
import XCTest
@testable import pdf_wacom

final class ZoomBehaviorTests: XCTestCase {

    func testZoomKeepsCurrentPageNearViewportCenter() throws {
        let document = PDFInkDocument()
        try document.read(from: makePDFData(pageCount: 100), ofType: "com.adobe.pdf")
        let pdf = try XCTUnwrap(document.pdfDocument)

        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
        scrollView.hasVerticalScroller = true
        let stripView = SpreadStripView(frame: NSRect(x: 0, y: 0, width: 900, height: 100))
        stripView.pagesPerSpread = 1
        scrollView.documentView = stripView
        stripView.setSpreads(
            Spread.pair(pdf, coverIsSinglePage: false, pagesPerSpread: 1),
            document: document,
            toolController: ToolController(),
            onChange: {}
        )
        scrollView.layoutSubtreeIfNeeded()
        stripView.layoutSubtreeIfNeeded()

        scrollView.contentView.setBoundsOrigin(NSPoint(
            x: 0,
            y: stripView.spreadViews[79].view.frame.minY
        ))
        scrollView.reflectScrolledClipView(scrollView.contentView)

        XCTAssertEqual(centeredSpreadIndex(in: stripView, scrollView: scrollView), 79)

        stripView.zoomBy(factor: 1.25)

        XCTAssertEqual(centeredSpreadIndex(in: stripView, scrollView: scrollView), 79)
    }

    private func centeredSpreadIndex(in stripView: SpreadStripView,
                                     scrollView: NSScrollView) -> Int? {
        let centerY = scrollView.contentView.bounds.midY
        return stripView.spreadViews.firstIndex { entry in
            entry.view.frame.minY <= centerY && centerY < entry.view.frame.maxY
        }
    }

    private func makePDFData(pageCount: Int) throws -> Data {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let consumer = CGDataConsumer(data: data),
              let context = CGContext(consumer: consumer, mediaBox: &box, nil) else {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError)
        }
        for _ in 0..<pageCount {
            context.beginPDFPage(nil)
            context.setFillColor(NSColor.white.cgColor)
            context.fill(box)
            context.endPDFPage()
        }
        context.closePDF()
        return data as Data
    }
}
