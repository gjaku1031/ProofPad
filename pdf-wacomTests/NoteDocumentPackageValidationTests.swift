import Cocoa
import XCTest
@testable import pdf_wacom

final class NoteDocumentPackageValidationTests: XCTestCase {

    func testValidPackageLoadsStrokePage() throws {
        let page = PageStrokes(pageIndex: 0)
        let stroke = Stroke(color: .systemRed, width: 2)
        stroke.append(StrokePoint(x: 10, y: 20, t: 0))
        page.add(stroke)

        let document = NoteDocument()
        try document.read(
            from: makePackage(strokeFiles: ["page-0000.bin": page]),
            ofType: "com.ken.pdfnote"
        )

        XCTAssertEqual(document.pdfDocument?.pageCount, 1)
        XCTAssertEqual(document.strokesIfExists(forPage: 0)?.strokes.map(\.id), [stroke.id])
    }

    func testManifestPageCountMismatchRejected() throws {
        let document = NoteDocument()

        XCTAssertThrowsError(try document.read(
            from: makePackage(manifestPageCount: 2),
            ofType: "com.ken.pdfnote"
        ))
    }

    func testStrokeFileNameMustMatchEncodedPageIndex() throws {
        let page = PageStrokes(pageIndex: 1)

        let document = NoteDocument()
        XCTAssertThrowsError(try document.read(
            from: makePackage(strokeFiles: ["page-0000.bin": page]),
            ofType: "com.ken.pdfnote"
        ))
    }

    func testStrokePageIndexMustBeInsidePDFPageRange() throws {
        let page = PageStrokes(pageIndex: 2)

        let document = NoteDocument()
        XCTAssertThrowsError(try document.read(
            from: makePackage(strokeFiles: ["page-0002.bin": page]),
            ofType: "com.ken.pdfnote"
        ))
    }

    private func makePackage(manifestPageCount: Int = 1,
                             strokeFiles: [String: PageStrokes] = [:]) throws -> FileWrapper {
        let manifest = NoteManifest.newDefault(pageCount: manifestPageCount)
        let manifestData = try makeManifestData(manifest)
        let pdfData = try makePDFData(pageCount: 1)

        let strokeWrappers = strokeFiles.mapValues { page in
            FileWrapper(regularFileWithContents: StrokeCodec.encode(page))
        }

        return FileWrapper(directoryWithFileWrappers: [
            "manifest.json": FileWrapper(regularFileWithContents: manifestData),
            "source.pdf": FileWrapper(regularFileWithContents: pdfData),
            "strokes": FileWrapper(directoryWithFileWrappers: strokeWrappers),
        ])
    }

    private func makeManifestData(_ manifest: NoteManifest) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(manifest)
    }

    private func makePDFData(pageCount: Int) throws -> Data {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let consumer = CGDataConsumer(data: data),
              let context = CGContext(consumer: consumer, mediaBox: &box, nil) else {
            throw NSError(domain: NSCocoaErrorDomain,
                          code: NSFileWriteUnknownError,
                          userInfo: nil)
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
