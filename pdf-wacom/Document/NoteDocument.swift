import Cocoa
import PDFKit

// MARK: - NoteDocument
//
// 한 노트(.pdfnote 패키지) 또는 import된 PDF를 표현하는 NSDocument.
//
// === 파일 포맷 (.pdfnote는 NSFileWrapper 디렉토리 패키지) ===
//   manifest.json         NoteManifest (formatVersion, page count, coverIsSinglePage, pagesPerSpread, …)
//   source.pdf            원본 PDF 바이트 (PDFKit dataRepresentation은 일부 PDF에서 lossy하므로 원본 보존)
//   strokes/
//     page-0000.bin       PageStrokes binary (StrokeCodec)
//     page-0001.bin
//     ...                 stroke가 있는 페이지만 파일 존재
//
// === Read 흐름 ===
//   .pdfnote 열기:   read(from:ofType:) → readPdfNotePackage → manifest + PDF + per-page strokes
//   .pdf import:    read(from:ofType:) → readImportedPDF → manifest 새로 생성. 직후 fileURL=nil로 untitled화
//                   (⌘S 시 원본 PDF에 덮어쓰지 않게 — 저장 대화상자가 .pdfnote 위치를 새로 묻도록.)
//
// === Write 흐름 ===
//   fileWrapper(ofType:) → makePackageFileWrapper:
//     - originalPDFData 우선 (없으면 pdfDocument.dataRepresentation)
//     - manifest의 modifiedAt 갱신
//     - 모든 non-empty PageStrokes를 page-XXXX.bin으로 직렬화
//
// === 윈도우 모델 ===
//   자체 NSWindowController를 만들지 않는다. makeWindowControllers()에서
//   TabHostWindowController.shared.add(document:) 호출만 — 모든 도큐먼트는 단일 호스트 윈도우의
//   탭으로 들어간다. (시스템 NSWindow tabbing API 사용 안 함.)
//
//   windowForSheet도 호스트 윈도우로 반환 — 저장/Open 시트가 호스트 윈도우 attach.
//
// === 자동저장 ===
//   autosavesInPlace = true. NSDocument의 표준 디바운스 사용. stroke 진행 중 updateChangeCount는
//   PenTool/EraserTool이 mouseUp 시점에만 호출하므로(stroke 중에 dirty mark 안 함) 진행 중 I/O 없음.
@objc(NoteDocument)
final class NoteDocument: NSDocument {

    private(set) var pdfDocument: PDFDocument?
    private(set) var originalPDFData: Data?
    private(set) var manifest: NoteManifest = NoteManifest.newDefault(pageCount: 0)

    /// 페이지 인덱스 → PageStrokes (lazy 생성).
    private var pageStrokesMap: [Int: PageStrokes] = [:]

    private var importedDisplayName: String?

    override class var autosavesInPlace: Bool { true }

    override class var readableTypes: [String] {
        ["com.ken.pdfnote", "com.adobe.pdf"]
    }

    override class var writableTypes: [String] {
        ["com.ken.pdfnote"]
    }

    override func writableTypes(for saveOperation: NSDocument.SaveOperationType) -> [String] {
        ["com.ken.pdfnote"]
    }

    override func fileNameExtension(forType typeName: String,
                                    saveOperation: NSDocument.SaveOperationType) -> String? {
        typeName == "com.ken.pdfnote" ? "pdfnote" : nil
    }

    func strokes(forPage index: Int) -> PageStrokes {
        if let s = pageStrokesMap[index] { return s }
        let new = PageStrokes(pageIndex: index)
        pageStrokesMap[index] = new
        return new
    }

    /// side effect 없이 lookup만. export 등 read-only 흐름에서 사용.
    func strokesIfExists(forPage index: Int) -> PageStrokes? {
        return pageStrokesMap[index]
    }

    func setCoverIsSinglePage(_ value: Bool) {
        guard manifest.coverIsSinglePage != value else { return }
        manifest.coverIsSinglePage = value
        updateChangeCount(.changeDone)
    }

    func setPagesPerSpread(_ value: Int) {
        let normalized = value == 1 ? 1 : 2
        guard manifest.effectivePagesPerSpread != normalized else { return }
        manifest.pagesPerSpread = normalized
        updateChangeCount(.changeDone)
    }

    var allPageStrokes: [PageStrokes] {
        Array(pageStrokesMap.values).sorted { $0.pageIndex < $1.pageIndex }
    }

    // MARK: - Window

    override func makeWindowControllers() {
        // 자체 NSWindowController/NSWindow는 만들지 않는다.
        // 모든 도큐먼트는 TabHostWindowController.shared의 단일 윈도우에 호스팅된다.
        TabHostWindowController.shared.add(document: self)
    }

    override var windowForSheet: NSWindow? {
        return TabHostWindowController.shared.window
    }

    override var displayName: String! {
        get {
            if let url = fileURL {
                return (url.lastPathComponent as NSString).deletingPathExtension
            }
            if let imported = importedDisplayName {
                return imported
            }
            return "Untitled"
        }
        set { /* ignored — derived */ }
    }

    // MARK: - Read

    override func read(from fileWrapper: FileWrapper, ofType typeName: String) throws {
        if typeName == "com.ken.pdfnote" {
            try readPdfNotePackage(fileWrapper)
        } else if typeName == "com.adobe.pdf" {
            try readImportedPDF(fileWrapper)
            // NSDocumentController가 fileURL/fileType을 set한 직후에 reset해 untitled로 만든다.
            // 이렇게 해야 ⌘S 시 saveAs 다이얼로그로 .pdfnote 위치를 새로 묻는다 (원본 PDF 덮어쓰기 방지).
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.fileURL = nil
                self.fileType = "com.ken.pdfnote"
                self.updateChangeCount(.changeDone)
            }
        } else {
            throw NSError(domain: NSCocoaErrorDomain,
                          code: NSFileReadCorruptFileError,
                          userInfo: [NSLocalizedDescriptionKey: "지원하지 않는 파일 형식입니다."])
        }
    }

    private func readPdfNotePackage(_ root: FileWrapper) throws {
        guard root.isDirectory, let children = root.fileWrappers else {
            throw NSError(domain: NSCocoaErrorDomain,
                          code: NSFileReadCorruptFileError,
                          userInfo: [NSLocalizedDescriptionKey: "노트 패키지 형식이 아닙니다."])
        }
        guard let manifestData = children["manifest.json"]?.regularFileContents else {
            throw NSError(domain: NSCocoaErrorDomain,
                          code: NSFileReadCorruptFileError,
                          userInfo: [NSLocalizedDescriptionKey: "manifest.json이 없습니다."])
        }
        let manifest = try JSONDecoder.iso.decode(NoteManifest.self, from: manifestData)
        guard manifest.formatVersion <= NoteManifest.currentFormatVersion else {
            throw NSError(domain: NSCocoaErrorDomain,
                          code: NSFileReadCorruptFileError,
                          userInfo: [NSLocalizedDescriptionKey: "지원하지 않는 노트 포맷 버전입니다."])
        }
        guard let pdfData = children["source.pdf"]?.regularFileContents,
              let pdf = PDFDocument(data: pdfData) else {
            throw NSError(domain: NSCocoaErrorDomain,
                          code: NSFileReadCorruptFileError,
                          userInfo: [NSLocalizedDescriptionKey: "source.pdf를 읽을 수 없습니다."])
        }
        self.manifest = manifest
        self.pdfDocument = pdf
        self.originalPDFData = pdfData
        self.pageStrokesMap = [:]

        if let strokesDir = children["strokes"], let files = strokesDir.fileWrappers {
            for (name, wrapper) in files {
                guard name.hasPrefix("page-"), name.hasSuffix(".bin") else { continue }
                guard let data = wrapper.regularFileContents else { continue }
                let ps = try StrokeCodec.decode(data)
                self.pageStrokesMap[ps.pageIndex] = ps
            }
        }
    }

    private func readImportedPDF(_ wrapper: FileWrapper) throws {
        guard let data = wrapper.regularFileContents,
              let pdf = PDFDocument(data: data) else {
            throw NSError(domain: NSCocoaErrorDomain,
                          code: NSFileReadCorruptFileError,
                          userInfo: [NSLocalizedDescriptionKey: "PDF를 열 수 없습니다."])
        }
        self.pdfDocument = pdf
        self.originalPDFData = data
        self.manifest = NoteManifest.newDefault(pageCount: pdf.pageCount)
        self.pageStrokesMap = [:]
        if let preferred = wrapper.preferredFilename {
            self.importedDisplayName = (preferred as NSString).deletingPathExtension
        }
    }

    // MARK: - Write

    override func fileWrapper(ofType typeName: String) throws -> FileWrapper {
        guard typeName == "com.ken.pdfnote" else {
            throw NSError(domain: NSCocoaErrorDomain,
                          code: NSFileWriteUnsupportedSchemeError,
                          userInfo: [NSLocalizedDescriptionKey: "이 형식으로는 저장할 수 없습니다."])
        }
        return try makePackageFileWrapper()
    }

    private func makePackageFileWrapper() throws -> FileWrapper {
        // 원본 PDF byte를 그대로 보존 (PDFKit dataRepresentation은 일부 PDF에서 lossy).
        guard let pdfData = originalPDFData ?? pdfDocument?.dataRepresentation() else {
            throw NSError(domain: NSCocoaErrorDomain,
                          code: NSFileWriteInapplicableStringEncodingError,
                          userInfo: [NSLocalizedDescriptionKey: "PDF 데이터가 없습니다."])
        }

        var manifest = self.manifest
        manifest.modifiedAt = Date()
        manifest.pageCount = pdfDocument?.pageCount ?? manifest.pageCount
        let manifestData = try JSONEncoder.iso.encode(manifest)

        var children: [String: FileWrapper] = [:]
        children["manifest.json"] = FileWrapper(regularFileWithContents: manifestData)
        children["source.pdf"] = FileWrapper(regularFileWithContents: pdfData)

        var strokeChildren: [String: FileWrapper] = [:]
        for ps in allPageStrokes where !ps.strokes.isEmpty {
            let name = String(format: "page-%04d.bin", ps.pageIndex)
            let data = StrokeCodec.encode(ps)
            strokeChildren[name] = FileWrapper(regularFileWithContents: data)
        }
        children["strokes"] = FileWrapper(directoryWithFileWrappers: strokeChildren)

        return FileWrapper(directoryWithFileWrappers: children)
    }

}

private extension JSONEncoder {
    static let iso: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()
}

private extension JSONDecoder {
    static let iso: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
