import Cocoa
import PDFKit

// PDF와 편집 중인 stroke를 한 장짜리 그래픽 결과로 굽는 export.
// 페이지마다 새 PDFContext를 만들고 원본 PDF 페이지를 그린 뒤 stroke path를 직접 그린다.
// 저장용 PDFAnnotation(.ink)과 달리 결과 파일에는 편집 가능한 앱 stroke payload가 남지 않는다.
enum PDFFlattenExporter {

    enum ExportError: LocalizedError {
        case noPDF
        case pageEncodingFailed(Int)
        case writeFailed

        var errorDescription: String? {
            switch self {
            case .noPDF: return "내보낼 PDF가 없습니다."
            case .pageEncodingFailed(let i): return "\(i + 1)페이지를 변환하는 데 실패했습니다."
            case .writeFailed: return "PDF 파일을 쓸 수 없습니다."
            }
        }
    }

    static func export(document: PDFInkDocument, to url: URL) throws {
        guard let srcDoc = document.pdfDocument else { throw ExportError.noPDF }
        let outDoc = PDFDocument()

        for i in 0..<srcDoc.pageCount {
            guard let srcPage = srcDoc.page(at: i) else { continue }
            let mediaBox = srcPage.bounds(for: .mediaBox)

            let pdfData = NSMutableData()
            guard let consumer = CGDataConsumer(data: pdfData) else {
                throw ExportError.pageEncodingFailed(i)
            }
            var box = mediaBox
            guard let ctx = CGContext(consumer: consumer, mediaBox: &box, nil) else {
                throw ExportError.pageEncodingFailed(i)
            }
            ctx.beginPDFPage(nil)

            // 원본 PDF 페이지
            if let cgPage = srcPage.pageRef {
                ctx.drawPDFPage(cgPage)
            }
            // stroke 위에 합치기 (페이지 좌표 그대로 — stroke 모델은 PDF 페이지 로컬 좌표)
            if let pageStrokes = document.strokesIfExists(forPage: i) {
                for stroke in pageStrokes.strokes {
                    drawStroke(stroke, in: ctx)
                }
            }

            ctx.endPDFPage()
            ctx.closePDF()

            guard let onePage = PDFDocument(data: pdfData as Data),
                  let p = onePage.page(at: 0) else {
                throw ExportError.pageEncodingFailed(i)
            }
            outDoc.insert(p, at: outDoc.pageCount)
        }

        guard outDoc.write(to: url) else { throw ExportError.writeFailed }
    }

    private static func drawStroke(_ stroke: Stroke, in ctx: CGContext) {
        guard let first = stroke.points.first else { return }
        let nsColor = stroke.color.usingColorSpace(.deviceRGB) ?? stroke.color
        ctx.saveGState()
        ctx.setStrokeColor(nsColor.cgColor)
        ctx.setFillColor(nsColor.cgColor)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)

        if stroke.points.count == 1 {
            let halfWidth = CGFloat(InkStrokeDynamics.halfWidth(baseWidth: stroke.width,
                                                                viewScale: 1,
                                                                point: first,
                                                                previous: nil))
            let center = CGPoint(x: CGFloat(first.x), y: CGFloat(first.y))
            ctx.fillEllipse(in: CGRect(x: center.x - halfWidth,
                                       y: center.y - halfWidth,
                                       width: halfWidth * 2,
                                       height: halfWidth * 2))
            ctx.restoreGState()
            return
        }

        for i in 1..<stroke.points.count {
            let previous = stroke.points[i - 1]
            let point = stroke.points[i]
            let halfWidth = InkStrokeDynamics.halfWidth(baseWidth: stroke.width,
                                                        viewScale: 1,
                                                        point: point,
                                                        previous: previous)
            ctx.setLineWidth(CGFloat(halfWidth) * 2)
            ctx.move(to: CGPoint(x: CGFloat(previous.x), y: CGFloat(previous.y)))
            ctx.addLine(to: CGPoint(x: CGFloat(point.x), y: CGFloat(point.y)))
            ctx.strokePath()
        }
        ctx.restoreGState()
    }
}
