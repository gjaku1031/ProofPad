import Cocoa
import PDFKit

enum BlankPDFTemplate: CaseIterable {
    case blank
    case dotGrid
    case lined
    case mathNote

    var title: String {
        switch self {
        case .blank: return "Blank A4"
        case .dotGrid: return "Dot Grid"
        case .lined: return "Lined Note"
        case .mathNote: return "Math Note"
        }
    }

    var displayName: String {
        switch self {
        case .blank: return "Untitled A4"
        case .dotGrid: return "Untitled Dot Grid"
        case .lined: return "Untitled Lined Note"
        case .mathNote: return "Untitled Math Note"
        }
    }

    var systemImageName: String {
        switch self {
        case .blank: return "doc"
        case .dotGrid: return "circle.grid.3x3"
        case .lined: return "line.3.horizontal"
        case .mathNote: return "square.split.2x1"
        }
    }
}

enum BlankPDFTemplateFactory {
    static let a4PageBounds = CGRect(x: 0, y: 0, width: 595.28, height: 841.89)

    static func makePDFDocument(template: BlankPDFTemplate, pageCount: Int = 1) throws -> PDFDocument {
        precondition(pageCount > 0)

        let data = NSMutableData()
        var mediaBox = a4PageBounds
        guard let consumer = CGDataConsumer(data: data),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw NSError(domain: NSCocoaErrorDomain,
                          code: NSFileWriteUnknownError,
                          userInfo: [NSLocalizedDescriptionKey: "빈 PDF를 만들 수 없습니다."])
        }

        for _ in 0..<pageCount {
            context.beginPDFPage(nil)
            drawPage(template: template, in: context, bounds: mediaBox)
            context.endPDFPage()
        }
        context.closePDF()

        guard let pdf = PDFDocument(data: data as Data) else {
            throw NSError(domain: NSCocoaErrorDomain,
                          code: NSFileReadCorruptFileError,
                          userInfo: [NSLocalizedDescriptionKey: "생성한 PDF를 열 수 없습니다."])
        }
        return pdf
    }

    private static func drawPage(template: BlankPDFTemplate, in context: CGContext, bounds: CGRect) {
        context.setFillColor(NSColor.white.cgColor)
        context.fill(bounds)

        switch template {
        case .blank:
            return
        case .dotGrid:
            drawDotGrid(in: context, bounds: bounds)
        case .lined:
            drawLinedPage(in: context, bounds: bounds, columns: 1)
        case .mathNote:
            drawLinedPage(in: context, bounds: bounds, columns: 2)
        }
    }

    private static func drawDotGrid(in context: CGContext, bounds: CGRect) {
        let margin: CGFloat = 42
        let spacing: CGFloat = 18
        let radius: CGFloat = 0.8
        let dotColor = NSColor(calibratedWhite: 0.70, alpha: 0.60).cgColor

        context.setFillColor(dotColor)
        var y = margin
        while y <= bounds.height - margin {
            var x = margin
            while x <= bounds.width - margin {
                context.fillEllipse(in: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2))
                x += spacing
            }
            y += spacing
        }
    }

    private static func drawLinedPage(in context: CGContext, bounds: CGRect, columns: Int) {
        let topMargin: CGFloat = 52
        let bottomMargin: CGFloat = 42
        let sideMargin: CGFloat = 44
        let lineSpacing: CGFloat = 24
        let lineColor = NSColor(calibratedWhite: 0.72, alpha: 0.55).cgColor
        let guideColor = NSColor.systemBlue.withAlphaComponent(0.18).cgColor

        context.setLineWidth(0.7)
        context.setStrokeColor(lineColor)

        var y = bottomMargin
        while y <= bounds.height - topMargin {
            if columns == 2 {
                let center = bounds.midX
                context.move(to: CGPoint(x: sideMargin, y: y))
                context.addLine(to: CGPoint(x: center - 16, y: y))
                context.move(to: CGPoint(x: center + 16, y: y))
                context.addLine(to: CGPoint(x: bounds.width - sideMargin, y: y))
            } else {
                context.move(to: CGPoint(x: sideMargin, y: y))
                context.addLine(to: CGPoint(x: bounds.width - sideMargin, y: y))
            }
            y += lineSpacing
        }
        context.strokePath()

        if columns == 2 {
            context.setStrokeColor(guideColor)
            context.setLineWidth(1)
            context.move(to: CGPoint(x: bounds.midX, y: bottomMargin - 10))
            context.addLine(to: CGPoint(x: bounds.midX, y: bounds.height - topMargin + 10))
            context.strokePath()
        }
    }
}
