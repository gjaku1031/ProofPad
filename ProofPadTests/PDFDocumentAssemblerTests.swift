import PDFKit
import XCTest
@testable import ProofPad

final class PDFDocumentAssemblerTests: XCTestCase {

    func testMergePDFsCombinesSelectedDocumentsInOrder() throws {
        let first = try makeTemporaryPDF(pageCount: 1, name: "first")
        let second = try makeTemporaryPDF(pageCount: 2, name: "second")

        let merged = try PDFDocumentAssembler.mergePDFs(at: [first, second])

        XCTAssertEqual(merged.pageCount, 3)
    }

    private func makeTemporaryPDF(pageCount: Int, name: String) throws -> URL {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let consumer = CGDataConsumer(data: data),
              let context = CGContext(consumer: consumer, mediaBox: &box, nil) else {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError)
        }
        for _ in 0..<pageCount {
            context.beginPDFPage(nil)
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(box)
            context.endPDFPage()
        }
        context.closePDF()

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + "-\(name).pdf")
        try (data as Data).write(to: url, options: .atomic)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }
}
