import PDFKit
import XCTest
@testable import ProofPad

final class BlankPDFTemplateTests: XCTestCase {

    func testAllBlankTemplatesCreateSingleA4Page() throws {
        for template in BlankPDFTemplate.allCases {
            let pdf = try BlankPDFTemplateFactory.makePDFDocument(template: template)
            let bounds = try XCTUnwrap(pdf.page(at: 0)?.bounds(for: .mediaBox))

            XCTAssertEqual(pdf.pageCount, 1, template.title)
            XCTAssertEqual(bounds.width, BlankPDFTemplateFactory.a4PageBounds.width, accuracy: 0.1, template.title)
            XCTAssertEqual(bounds.height, BlankPDFTemplateFactory.a4PageBounds.height, accuracy: 0.1, template.title)
        }
    }

    func testConfiguringBlankPDFPreparesUntitledEditableDocument() throws {
        let document = PDFInkDocument()

        try document.configureBlankPDF(template: .mathNote)

        XCTAssertEqual(document.pageCount, 1)
        XCTAssertEqual(document.displayName, BlankPDFTemplate.mathNote.displayName)
        XCTAssertEqual(document.fileType, "com.adobe.pdf")
        XCTAssertNil(document.fileURL)
    }
}
