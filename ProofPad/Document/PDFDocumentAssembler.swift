import Cocoa
import PDFKit

enum PDFDocumentAssembler {
    static func mergePDFs(at urls: [URL]) throws -> PDFDocument {
        guard !urls.isEmpty else { throw writeError("합칠 PDF를 선택하지 않았습니다.") }

        let output = PDFDocument()
        for url in urls {
            guard let input = PDFDocument(url: url) else {
                throw corruptFileError("\(url.lastPathComponent)을 열 수 없습니다.")
            }
            for index in 0..<input.pageCount {
                guard let page = input.page(at: index)?.copy() as? PDFPage else { continue }
                output.insert(page, at: output.pageCount)
            }
        }

        guard output.pageCount > 0 else {
            throw writeError("선택한 PDF에서 페이지를 가져올 수 없습니다.")
        }
        return output
    }

    static func imagesAsPDF(at urls: [URL]) throws -> PDFDocument {
        guard !urls.isEmpty else { throw writeError("PDF로 만들 이미지를 선택하지 않았습니다.") }

        let output = PDFDocument()
        for url in urls {
            guard let image = NSImage(contentsOf: url),
                  let page = PDFPage(image: image) else {
                throw corruptFileError("\(url.lastPathComponent)을 PDF 페이지로 변환할 수 없습니다.")
            }
            output.insert(page, at: output.pageCount)
        }
        return output
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
