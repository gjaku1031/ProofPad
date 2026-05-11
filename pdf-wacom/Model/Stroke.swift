import Cocoa

// MARK: - Stroke
//
// 한 획. mouseDown → mouseDragged…* → mouseUp 사이의 점 시퀀스 + 색·두께 메타.
//
// === 인바리언트 ===
//   - points는 항상 시간순 (append만 가능, 중간 삽입/삭제 없음)
//   - 좌표는 PDF 페이지 좌표 (좌하단 원점, y-up). 단위 = PDF point.
//   - bbox는 압력 기반 최대 렌더 폭까지 padding — Eraser hit-test가 stroke 두께를 고려할 수 있게.
//   - bbox 계산이 append에 inline돼 있어서 매 append마다 O(1) 갱신. 별도 invalidate 필요 없음.
//
// === PDF 저장 ===
//   PDFInkAnnotationCodec이 Stroke를 PDFAnnotation(.ink)으로 변환해 PDF 안에 저장한다.
//
// === Identity ===
//   id는 UUID. PageStrokes에서 stroke 제거 / Undo 등록 시 키로 사용.
final class Stroke {
    let id: UUID
    var color: NSColor
    var width: CGFloat
    let createdAt: Date
    private(set) var points: [StrokePoint] = []
    private(set) var bbox: CGRect = .null

    init(id: UUID = UUID(), color: NSColor, width: CGFloat, createdAt: Date = Date()) {
        self.id = id
        self.color = color
        self.width = width
        self.createdAt = createdAt
    }

    func append(_ point: StrokePoint) {
        points.append(point)
        let p = CGPoint(x: CGFloat(point.x), y: CGFloat(point.y))
        let r = max(width * 0.65, 0.5)
        let pointBox = CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)
        bbox = bbox.isNull ? pointBox : bbox.union(pointBox)
    }
}
