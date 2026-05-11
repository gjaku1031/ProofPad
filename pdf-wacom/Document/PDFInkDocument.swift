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
    private var untitledDisplayName: String?

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

    var pageCount: Int {
        pdfDocument?.pageCount ?? 0
    }

    func configureBlankPDF(template: BlankPDFTemplate, pageCount: Int = 1) throws {
        try configureGeneratedPDF(BlankPDFTemplateFactory.makePDFDocument(template: template, pageCount: pageCount),
                                  displayName: template.displayName)
    }

    func configureGeneratedPDF(_ pdf: PDFDocument, displayName: String) throws {
        guard pdf.pageCount > 0 else { throw Self.writeError("빈 PDF는 만들 수 없습니다.") }
        pageStrokesMap = [:]
        pdfDocument = pdf
        fileURL = nil
        fileType = "com.adobe.pdf"
        untitledDisplayName = displayName
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

    // MARK: - PDF page editing

    func appendPages(from other: PDFDocument) throws {
        guard let pdf = pdfDocument else { throw Self.writeError("편집할 PDF가 없습니다.") }
        guard other.pageCount > 0 else { return }
        for index in 0..<other.pageCount {
            guard let page = other.page(at: index)?.copy() as? PDFPage else { continue }
            pdf.insert(page, at: pdf.pageCount)
        }
        updateChangeCount(.changeDone)
    }

    func appendImagesAsPages(from imageURLs: [URL]) throws {
        guard let pdf = pdfDocument else { throw Self.writeError("편집할 PDF가 없습니다.") }
        for url in imageURLs {
            guard let image = NSImage(contentsOf: url),
                  let page = PDFPage(image: image) else {
                throw Self.corruptFileError("\(url.lastPathComponent)을 PDF 페이지로 변환할 수 없습니다.")
            }
            pdf.insert(page, at: pdf.pageCount)
        }
        updateChangeCount(.changeDone)
    }

    func deletePage(at pageIndex: Int) throws {
        guard let pdf = pdfDocument else { throw Self.writeError("편집할 PDF가 없습니다.") }
        guard pdf.pageCount > 1 else {
            throw Self.writeError("마지막 페이지는 삭제할 수 없습니다.")
        }
        guard pageIndex >= 0, pageIndex < pdf.pageCount else {
            throw Self.writeError("삭제할 페이지가 없습니다.")
        }
        pdf.removePage(at: pageIndex)
        pageStrokesMap = Self.reindexStrokesAfterDeletingPage(pageIndex, pageStrokesMap)
        updateChangeCount(.changeDone)
    }

    func duplicatePage(at pageIndex: Int) throws {
        guard let pdf = pdfDocument else { throw Self.writeError("편집할 PDF가 없습니다.") }
        guard pageIndex >= 0, pageIndex < pdf.pageCount else {
            throw Self.writeError("복제할 페이지가 없습니다.")
        }
        guard let copiedPage = pdf.page(at: pageIndex)?.copy() as? PDFPage else {
            throw Self.writeError("페이지를 복제할 수 없습니다.")
        }

        let insertionIndex = pageIndex + 1
        pdf.insert(copiedPage, at: insertionIndex)
        pageStrokesMap = Self.reindexStrokesAfterInsertingPage(after: pageIndex, pageStrokesMap)
        updateChangeCount(.changeDone)
    }

    func singlePagePDFData(pageIndex: Int) throws -> Data {
        guard let pdf = pdfDocument else { throw Self.writeError("내보낼 PDF가 없습니다.") }
        guard let page = pdf.page(at: pageIndex)?.copy() as? PDFPage else {
            throw Self.writeError("내보낼 페이지가 없습니다.")
        }
        if let pageStrokes = strokesIfExists(forPage: pageIndex) {
            let pageBounds = page.bounds(for: .mediaBox)
            for stroke in pageStrokes.strokes {
                if let annotation = PDFInkAnnotationCodec.annotation(from: stroke, pageBounds: pageBounds) {
                    page.addAnnotation(annotation)
                }
            }
        }
        let out = PDFDocument()
        out.insert(page, at: 0)
        guard let data = out.dataRepresentation() else {
            throw Self.writeError("페이지 PDF 데이터를 만들 수 없습니다.")
        }
        return data
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
            if let untitledDisplayName {
                return untitledDisplayName
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
        self.untitledDisplayName = nil
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

    private static func reindexStrokesAfterDeletingPage(_ deletedIndex: Int,
                                                        _ old: [Int: PageStrokes]) -> [Int: PageStrokes] {
        var result: [Int: PageStrokes] = [:]
        for (pageIndex, pageStrokes) in old {
            if pageIndex < deletedIndex {
                result[pageIndex] = pageStrokes
            } else if pageIndex > deletedIndex {
                let shifted = PageStrokes(pageIndex: pageIndex - 1)
                for stroke in pageStrokes.strokes {
                    shifted.add(stroke, notify: false)
                }
                result[pageIndex - 1] = shifted
            }
        }
        return result
    }

    private static func reindexStrokesAfterInsertingPage(after sourceIndex: Int,
                                                         _ old: [Int: PageStrokes]) -> [Int: PageStrokes] {
        var result: [Int: PageStrokes] = [:]
        let insertionIndex = sourceIndex + 1

        for (pageIndex, pageStrokes) in old {
            let newIndex = pageIndex >= insertionIndex ? pageIndex + 1 : pageIndex
            let shifted = PageStrokes(pageIndex: newIndex)
            for stroke in pageStrokes.strokes {
                shifted.add(stroke, notify: false)
            }
            result[newIndex] = shifted
        }

        if let sourceStrokes = old[sourceIndex] {
            let duplicated = PageStrokes(pageIndex: insertionIndex)
            for stroke in sourceStrokes.strokes {
                duplicated.add(stroke.duplicated(), notify: false)
            }
            result[insertionIndex] = duplicated
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
