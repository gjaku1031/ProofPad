import Cocoa
import PDFKit

enum PDFImageExporter {
    enum ExportError: LocalizedError {
        case pageUnavailable(Int)
        case pngEncodingFailed(Int)
        case writeFailed(URL)

        var errorDescription: String? {
            switch self {
            case .pageUnavailable(let index):
                return "\(index + 1)페이지를 이미지로 만들 수 없습니다."
            case .pngEncodingFailed(let index):
                return "\(index + 1)페이지 PNG 인코딩에 실패했습니다."
            case .writeFailed(let url):
                return "\(url.lastPathComponent)을 쓸 수 없습니다."
            }
        }
    }

    static func exportAllPages(of pdf: PDFDocument,
                               to folderURL: URL,
                               baseName: String,
                               scale: CGFloat = 2) throws {
        guard pdf.pageCount > 0 else { return }
        for index in 0..<pdf.pageCount {
            guard let data = pngData(forPageAt: index, in: pdf, scale: scale) else {
                throw ExportError.pngEncodingFailed(index)
            }
            let url = folderURL.appendingPathComponent("\(baseName)-page-\(String(format: "%04d", index + 1)).png")
            do {
                try data.write(to: url, options: .atomic)
            } catch {
                throw ExportError.writeFailed(url)
            }
        }
    }

    static func pngData(forPageAt index: Int,
                        in pdf: PDFDocument,
                        scale: CGFloat = 2) -> Data? {
        guard let page = pdf.page(at: index) else { return nil }
        let bounds = page.bounds(for: .mediaBox)
        let pixelSize = NSSize(width: max(bounds.width * scale, 1),
                               height: max(bounds.height * scale, 1))
        let image = page.thumbnail(of: pixelSize, for: .mediaBox)
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}
