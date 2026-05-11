import Cocoa
import PDFKit

// MARK: - PDFInkDocument
//
// Preview replacement 방향의 PDF-first NSDocument.
//
// === 저장 모델 ===
//   - canonical file은 PDF 자체다. 별도 노트 패키지나 stroke sidecar를 만들지 않는다.
//   - 앱에서 작성한 ink는 저장 시 PDFAnnotation(.ink)으로 PDF에 들어간다.
//   - 편집 중에는 앱 작성 annotation을 PDFPage에서 제거하고 PageStrokes 런타임 모델로 들고 있다.
//     그래야 PDFPage.draw 결과와 Metal stroke overlay가 이중으로 그려지지 않는다.
//
// === 호환성 정책 ===
//   - 앱이 만든 PDFAnnotation은 custom annotation key에 stroke payload를 넣어 정확히 round-trip한다.
//   - 외부/Preview annotation은 PDF 안에 그대로 남겨 PDFPage.draw 배경으로 표시한다.
//   - 이전 별도 노트 패키지 포맷은 지원하지 않는다.
@objc(PDFInkDocument)
final class PDFInkDocument: NSDocument {
    static let editStateDidChangeNotification = Notification.Name("PDFInkDocument.editStateDidChange")

    private(set) var pdfDocument: PDFDocument?

    /// 페이지 인덱스 -> 앱에서 편집 가능한 ink strokes.
    private var pageStrokesMap: [Int: PageStrokes] = [:]

    /// PDF 자체에 저장하지 않는 view preference. 기본은 시험지 채점에 맞춘 두 페이지 보기.
    private(set) var coverIsSinglePage: Bool = false
    private(set) var pagesPerSpread: Int = 2

    override class var autosavesInPlace: Bool { true }

    override func updateChangeCount(_ change: NSDocument.ChangeType) {
        super.updateChangeCount(change)
        NotificationCenter.default.post(name: Self.editStateDidChangeNotification, object: self)
    }

    override class var readableTypes: [String] {
        ["com.adobe.pdf"]
    }

    override class var writableTypes: [String] {
        ["com.adobe.pdf"]
    }

    override func writableTypes(for saveOperation: NSDocument.SaveOperationType) -> [String] {
        ["com.adobe.pdf"]
    }

    override func fileNameExtension(forType typeName: String,
                                    saveOperation: NSDocument.SaveOperationType) -> String? {
        typeName == "com.adobe.pdf" ? "pdf" : nil
    }

    func strokes(forPage index: Int) -> PageStrokes {
        if let s = pageStrokesMap[index] { return s }
        let new = PageStrokes(pageIndex: index)
        pageStrokesMap[index] = new
        return new
    }

    /// side effect 없이 lookup만. export 등 read-only 흐름에서 사용.
    func strokesIfExists(forPage index: Int) -> PageStrokes? {
        pageStrokesMap[index]
    }

    var allPageStrokes: [PageStrokes] {
        Array(pageStrokesMap.values).sorted { $0.pageIndex < $1.pageIndex }
    }

    var effectivePagesPerSpread: Int {
        pagesPerSpread == 1 ? 1 : 2
    }

    func setCoverIsSinglePage(_ value: Bool) {
        guard coverIsSinglePage != value else { return }
        coverIsSinglePage = value
    }

    func setPagesPerSpread(_ value: Int) {
        let normalized = value == 1 ? 1 : 2
        guard effectivePagesPerSpread != normalized else { return }
        pagesPerSpread = normalized
    }

    // MARK: - Window

    override func makeWindowControllers() {
        // 자체 NSWindowController/NSWindow는 만들지 않는다.
        // 모든 도큐먼트는 TabHostWindowController.shared의 단일 윈도우에 호스팅된다.
        TabHostWindowController.shared.add(document: self)
    }

    override var windowForSheet: NSWindow? {
        TabHostWindowController.shared.window
    }

    override var displayName: String! {
        get {
            if let url = fileURL {
                return (url.lastPathComponent as NSString).deletingPathExtension
            }
            return super.displayName ?? "Untitled"
        }
        set { /* derived */ }
    }

    // MARK: - Read / Write

    override func read(from data: Data, ofType typeName: String) throws {
        guard typeName == "com.adobe.pdf" else {
            throw Self.unsupportedTypeError()
        }
        guard let pdf = PDFDocument(data: data) else {
            throw Self.corruptFileError("PDF를 열 수 없습니다.")
        }

        self.pdfDocument = pdf
        self.pageStrokesMap = Self.extractEditableInk(from: pdf)
    }

    override func data(ofType typeName: String) throws -> Data {
        guard typeName == "com.adobe.pdf" else {
            throw Self.unsupportedTypeError()
        }
        guard let pdf = pdfDocument else {
            throw Self.writeError("저장할 PDF가 없습니다.")
        }

        let inserted = PDFInkAnnotationCodec.installAnnotations(for: allPageStrokes, into: pdf)
        defer { PDFInkAnnotationCodec.removeAnnotations(inserted) }

        guard let data = pdf.dataRepresentation() else {
            throw Self.writeError("PDF 데이터를 만들 수 없습니다.")
        }
        return data
    }

    private static func extractEditableInk(from pdf: PDFDocument) -> [Int: PageStrokes] {
        var result: [Int: PageStrokes] = [:]

        for pageIndex in 0..<pdf.pageCount {
            guard let page = pdf.page(at: pageIndex) else { continue }
            for annotation in page.annotations {
                guard let stroke = PDFInkAnnotationCodec.stroke(from: annotation) else { continue }
                let pageStrokes = result[pageIndex] ?? PageStrokes(pageIndex: pageIndex)
                pageStrokes.add(stroke, notify: false)
                result[pageIndex] = pageStrokes
                page.removeAnnotation(annotation)
            }
        }

        return result
    }

    private static func unsupportedTypeError() -> NSError {
        NSError(domain: NSCocoaErrorDomain,
                code: NSFileWriteUnsupportedSchemeError,
                userInfo: [NSLocalizedDescriptionKey: "지원하지 않는 파일 형식입니다."])
    }

    private static func corruptFileError(_ description: String) -> NSError {
        NSError(domain: NSCocoaErrorDomain,
                code: NSFileReadCorruptFileError,
                userInfo: [NSLocalizedDescriptionKey: description])
    }

    private static func writeError(_ description: String) -> NSError {
        NSError(domain: NSCocoaErrorDomain,
                code: NSFileWriteUnknownError,
                userInfo: [NSLocalizedDescriptionKey: description])
    }
}
