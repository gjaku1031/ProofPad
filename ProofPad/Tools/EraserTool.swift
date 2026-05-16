import Cocoa

// MARK: - EraserTool
//
// 획 단위(stroke eraser) 지우개. 드래그 경로에 닿은 stroke를 통째로 삭제 (부분 지우기 X).
//
// === 핵심 동작 ===
//   - 드래그 sample 사이를 보간한 여러 점에 대해 hit-test → 빠른 드래그도 stroke 누락 안 함.
//   - erasedThisDrag(Set<UUID>)로 같은 stroke가 같은 드래그에서 두 번 처리되지 않게 차단.
//   - undo는 드래그 단위로 그룹핑(beginEraseUndoGroup/end…) → ⌘Z 한 번에 전체 drag 복원.
//
// 반경(radius)은 페이지 좌표 기준. 줌에 독립적이라 시각적 두께도 zoom 따라감.
final class EraserTool: Tool {
    var radius: CGFloat = 12   // 페이지 좌표 기준 반지름

    private var erasedThisDrag: Set<UUID> = []
    private var lastPoint: CGPoint?

    func mouseDown(at pagePoint: CGPoint, event: NSEvent, canvas: StrokeCanvasView) {
        erasedThisDrag.removeAll()
        lastPoint = pagePoint
        canvas.beginEraseUndoGroup()
        canvas.updateEraserIndicator(at: pagePoint, radius: radius, immediate: true)
        eraseAt(pagePoint, canvas: canvas)
    }

    func mouseDragged(to pagePoint: CGPoint, event: NSEvent, canvas: StrokeCanvasView) {
        // 빠른 드래그에서 sample 사이가 멀어 stroke를 누락하지 않도록 보간한 점들로 검사.
        if let prev = lastPoint {
            let dx = pagePoint.x - prev.x
            let dy = pagePoint.y - prev.y
            let dist = (dx * dx + dy * dy).squareRoot()
            let step = max(radius / 2, 2)
            let count = max(Int((dist / step).rounded(.up)), 1)
            for i in 1...count {
                let t = CGFloat(i) / CGFloat(count)
                let p = CGPoint(x: prev.x + dx * t, y: prev.y + dy * t)
                eraseAt(p, canvas: canvas)
            }
        } else {
            eraseAt(pagePoint, canvas: canvas)
        }
        lastPoint = pagePoint
        canvas.updateEraserIndicator(at: pagePoint, radius: radius)
    }

    func mouseUp(at pagePoint: CGPoint, event: NSEvent, canvas: StrokeCanvasView) {
        canvas.updateEraserIndicator(at: pagePoint, radius: radius, immediate: true)
        eraseAt(pagePoint, canvas: canvas)
        canvas.endEraseUndoGroup()
        canvas.clearEraserIndicator(immediate: true)
        erasedThisDrag.removeAll()
        lastPoint = nil
    }

    private func eraseAt(_ point: CGPoint, canvas: StrokeCanvasView) {
        let hits = EraserHitTester.hits(in: canvas.pageStrokes, center: point, radius: radius)
        let new = hits.filter { !erasedThisDrag.contains($0) }
        guard !new.isEmpty else { return }
        for id in new {
            erasedThisDrag.insert(id)
            canvas.removeStroke(id: id)
        }
    }
}
