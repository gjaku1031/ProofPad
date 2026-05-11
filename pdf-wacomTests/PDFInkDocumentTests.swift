import Cocoa
import PDFKit
import XCTest
@testable import pdf_wacom

final class PDFInkDocumentTests: XCTestCase {

    func testPDFDocumentSavesOwnedInkAnnotationsAndReopensThemAsEditableStrokes() throws {
        let document = PDFInkDocument()
        try document.read(from: makePDFData(pageCount: 1), ofType: "com.adobe.pdf")

        let stroke = makeStroke()
        document.strokes(forPage: 0).add(stroke)

        let savedData = try document.data(ofType: "com.adobe.pdf")
        let reopened = PDFInkDocument()
        try reopened.read(from: savedData, ofType: "com.adobe.pdf")

        let reopenedStrokeIDs = reopened.strokesIfExists(forPage: 0)?.strokes.map(\.id)
        XCTAssertEqual(reopenedStrokeIDs, [stroke.id])
    }

    func testSavingDoesNotLeaveOwnedAnnotationsInstalledInEditingPDF() throws {
        let document = PDFInkDocument()
        try document.read(from: makePDFData(pageCount: 1), ofType: "com.adobe.pdf")
        document.strokes(forPage: 0).add(makeStroke())

        _ = try document.data(ofType: "com.adobe.pdf")

        XCTAssertEqual(document.pdfDocument?.page(at: 0)?.annotations.count, 0)
    }

    func testUnknownAnnotationsRemainInPDFDocument() throws {
        let pdf = try makePDFDocument(pageCount: 1)
        let annotation = PDFAnnotation(bounds: CGRect(x: 10, y: 10, width: 40, height: 20),
                                       forType: .highlight,
                                       withProperties: nil)
        pdf.page(at: 0)?.addAnnotation(annotation)
        let data = try XCTUnwrap(pdf.dataRepresentation())

        let document = PDFInkDocument()
        try document.read(from: data, ofType: "com.adobe.pdf")

        XCTAssertNil(document.strokesIfExists(forPage: 0))
        XCTAssertEqual(document.pdfDocument?.page(at: 0)?.annotations.count, 1)
    }

    func testPageLayoutPreferenceDoesNotDirtyPDFDocument() throws {
        let document = PDFInkDocument()
        try document.read(from: makePDFData(pageCount: 1), ofType: "com.adobe.pdf")

        document.setPagesPerSpread(1)
        document.setCoverIsSinglePage(true)

        XCTAssertFalse(document.isDocumentEdited)
    }

    private func makeStroke() -> Stroke {
        let stroke = Stroke(
            id: UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!,
            color: .systemRed,
            width: 3,
            createdAt: Date(timeIntervalSince1970: 4567.8)
        )
        stroke.append(StrokePoint(x: 100, y: 200, t: 0))
        stroke.append(StrokePoint(x: 110, y: 205, t: 8))
        return stroke
    }

    private func makePDFData(pageCount: Int) throws -> Data {
        try XCTUnwrap(makePDFDocument(pageCount: pageCount).dataRepresentation())
    }

    private func makePDFDocument(pageCount: Int) throws -> PDFDocument {
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
        return try XCTUnwrap(PDFDocument(data: data as Data))
    }
}
