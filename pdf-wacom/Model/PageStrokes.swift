import Foundation

// MARK: - PageStrokes
//
// 한 PDF 페이지의 stroke들. 디스크의 strokes/page-XXXX.bin 한 파일에 대응.
//
// === 인바리언트 ===
//   - strokes는 추가 순서 = 그리기 순서. 인덱스는 안정적이지 않음 (remove 시 shift됨) — 식별은 stroke.id.
//   - pageIndex는 fixed (init 후 변경 X). PDFDocument의 페이지 index와 일치.
//
// === 공간 인덱스 ===
//   Step 5 시점에 BBoxGrid 등 공간 인덱스 추가 예정. 현재는 linear scan으로 충분 (페이지당 stroke 수가 작음).
final class PageStrokes {
    let pageIndex: Int
    private(set) var strokes: [Stroke] = []

    init(pageIndex: Int) {
        self.pageIndex = pageIndex
    }

    func add(_ stroke: Stroke) {
        strokes.append(stroke)
    }

    @discardableResult
    func remove(id: UUID) -> Stroke? {
        guard let idx = strokes.firstIndex(where: { $0.id == id }) else { return nil }
        return strokes.remove(at: idx)
    }
}
