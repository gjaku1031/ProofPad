import Cocoa
import PDFKit
import XCTest
@testable import pdf_wacom

final class PDFInkAnnotationCodecTests: XCTestCase {

    func testStrokeRoundTripsThroughOwnedInkAnnotation() throws {
        let stroke = makeStroke()
        let annotation = try XCTUnwrap(PDFInkAnnotationCodec.annotation(
            from: stroke,
            pageBounds: CGRect(x: 0, y: 0, width: 612, height: 792)
        ))

        let decoded = try XCTUnwrap(PDFInkAnnotationCodec.stroke(from: annotation))

        XCTAssertEqual(decoded.id, stroke.id)
        XCTAssertEqual(Float(decoded.width), Float(stroke.width), accuracy: 0.001)
        XCTAssertEqual(decoded.inkFeel, stroke.inkFeel)
        XCTAssertEqual(decoded.points, stroke.points)
        XCTAssertEqual(decoded.createdAt.timeIntervalSince1970,
                       stroke.createdAt.timeIntervalSince1970,
                       accuracy: 0.001)
    }

    func testUnknownInkAnnotationIsNotImportedAsEditableStroke() {
        let annotation = PDFAnnotation(bounds: CGRect(x: 0, y: 0, width: 612, height: 792),
                                       forType: .ink,
                                       withProperties: nil)

        XCTAssertNil(PDFInkAnnotationCodec.stroke(from: annotation))
    }

    func testInstallAndRemoveAnnotationsDoesNotLeavePageDirtyInMemory() throws {
        let pdf = try makePDFDocument(pageCount: 1)
        let pageStrokes = PageStrokes(pageIndex: 0)
        pageStrokes.add(makeStroke())

        let installed = PDFInkAnnotationCodec.installAnnotations(for: [pageStrokes], into: pdf)
        XCTAssertEqual(pdf.page(at: 0)?.annotations.count, 1)

        PDFInkAnnotationCodec.removeAnnotations(installed)
        XCTAssertEqual(pdf.page(at: 0)?.annotations.count, 0)
    }

    private func makeStroke() -> Stroke {
        let stroke = Stroke(
            id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            color: .systemRed,
            width: 2.5,
            inkFeel: InkFeelSettings.Snapshot(stabilization: 0.7,
                                              pressureResponse: 1.2,
                                              speedThinning: 0.8,
                                              pressureStability: 0.4,
                                              latencyLead: 0.6),
            createdAt: Date(timeIntervalSince1970: 1234.5)
        )
        stroke.append(StrokePoint(x: 10, y: 20, t: 0))
        stroke.append(StrokePoint(x: 30, y: 45, t: 16))
        stroke.append(StrokePoint(x: 50, y: 60, t: 32))
        return stroke
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
