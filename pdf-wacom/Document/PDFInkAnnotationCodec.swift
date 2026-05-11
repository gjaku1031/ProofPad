import Cocoa
import PDFKit

// MARK: - PDFInkAnnotationCodec
//
// 앱 런타임 Stroke 모델과 PDFAnnotation(.ink)을 변환한다.
// PDF가 canonical storage이므로 이 타입이 저장 호환성의 핵심 경계다.
enum PDFInkAnnotationCodec {

    struct InstalledAnnotation {
        weak var page: PDFPage?
        weak var annotation: PDFAnnotation?
    }

    fileprivate struct StoredStroke: Codable {
        var id: UUID
        var color: ColorPayload
        var width: Double
        var createdAt: Double
        var points: [StrokePoint]
    }

    fileprivate struct ColorPayload: Codable, Equatable {
        var r: Double
        var g: Double
        var b: Double
        var a: Double
    }

    private static let ownerKey = PDFAnnotationKey(rawValue: "PWOwner")
    private static let strokeDataKey = PDFAnnotationKey(rawValue: "PWStrokeData")
    private static let ownerValue = "pdf-wacom"

    static func annotation(from stroke: Stroke, pageBounds: CGRect) -> PDFAnnotation? {
        guard !stroke.points.isEmpty else { return nil }

        let annotation = PDFAnnotation(bounds: pageBounds, forType: .ink, withProperties: nil)
        annotation.color = stroke.color.usingColorSpace(.deviceRGB) ?? stroke.color
        annotation.border = {
            let border = PDFBorder()
            border.lineWidth = stroke.width
            return border
        }()

        let path = NSBezierPath()
        if let first = stroke.points.first {
            path.move(to: CGPoint(x: CGFloat(first.x), y: CGFloat(first.y)))
            for point in stroke.points.dropFirst() {
                path.line(to: CGPoint(x: CGFloat(point.x), y: CGFloat(point.y)))
            }
        }
        annotation.add(path)

        if let payload = try? JSONEncoder().encode(StoredStroke(stroke)),
           let payloadString = String(data: payload, encoding: .utf8) {
            annotation.setValue(ownerValue, forAnnotationKey: ownerKey)
            annotation.setValue(payloadString, forAnnotationKey: strokeDataKey)
        }

        return annotation
    }

    static func stroke(from annotation: PDFAnnotation) -> Stroke? {
        guard annotation.value(forAnnotationKey: ownerKey) as? String == ownerValue else { return nil }
        guard let payloadString = annotation.value(forAnnotationKey: strokeDataKey) as? String,
              let payloadData = payloadString.data(using: .utf8),
              let stored = try? JSONDecoder().decode(StoredStroke.self, from: payloadData) else {
            return nil
        }
        return stored.stroke
    }

    static func installAnnotations(for allPageStrokes: [PageStrokes],
                                   into pdf: PDFDocument) -> [InstalledAnnotation] {
        var installed: [InstalledAnnotation] = []

        for pageStrokes in allPageStrokes where !pageStrokes.strokes.isEmpty {
            guard let page = pdf.page(at: pageStrokes.pageIndex) else { continue }
            let pageBounds = page.bounds(for: .mediaBox)
            for stroke in pageStrokes.strokes {
                guard let annotation = annotation(from: stroke, pageBounds: pageBounds) else { continue }
                page.addAnnotation(annotation)
                installed.append(InstalledAnnotation(page: page, annotation: annotation))
            }
        }

        return installed
    }

    static func removeAnnotations(_ installed: [InstalledAnnotation]) {
        for entry in installed {
            guard let page = entry.page, let annotation = entry.annotation else { continue }
            page.removeAnnotation(annotation)
        }
    }
}

private extension PDFInkAnnotationCodec.StoredStroke {
    init(_ stroke: Stroke) {
        self.id = stroke.id
        self.color = PDFInkAnnotationCodec.ColorPayload(stroke.color)
        self.width = Double(stroke.width)
        self.createdAt = stroke.createdAt.timeIntervalSince1970
        self.points = stroke.points
    }

    var stroke: Stroke? {
        guard width.isFinite, width > 0, createdAt.isFinite else { return nil }
        let stroke = Stroke(
            id: id,
            color: color.nsColor,
            width: CGFloat(width),
            createdAt: Date(timeIntervalSince1970: createdAt)
        )
        for point in points {
            guard point.x.isFinite, point.y.isFinite, point.t.isFinite else { return nil }
            stroke.append(point)
        }
        return stroke
    }
}

private extension PDFInkAnnotationCodec.ColorPayload {
    init(_ color: NSColor) {
        let c = color.usingColorSpace(.deviceRGB) ?? color
        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0
        c.getRed(&r, green: &g, blue: &b, alpha: &a)
        self.r = Double(r)
        self.g = Double(g)
        self.b = Double(b)
        self.a = Double(a)
    }

    var nsColor: NSColor {
        NSColor(deviceRed: CGFloat(r),
                green: CGFloat(g),
                blue: CGFloat(b),
                alpha: CGFloat(a))
    }
}
