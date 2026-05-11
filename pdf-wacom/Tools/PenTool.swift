import Cocoa
import CoreFoundation

// MARK: - PenTool
//
// 펜으로 stroke를 그리는 Tool. 한 인스턴스가 ToolController에 공유되어 활성 stroke를 보유.
//
// 흐름:
//   mouseDown   PenSettings에서 현재 색·두께 읽어 Stroke 새로 만들고 시작점 append.
//               canvas.beginInProgressStroke로 Metal renderer 초기화.
//   mouseDragged 점 append + canvas.updateInProgressStroke (incremental geometry).
//   mouseUp     마지막 점 append + canvas.commitStroke (baked CAShapeLayer로 전환).
//
// 시간 t는 Float ms 단위, mouseDown 시점 = 0. (분석/리플레이 용도.)
final class PenTool: Tool {
    private var current: Stroke?
    private var startTime: CFAbsoluteTime = 0

    func mouseDown(at pagePoint: CGPoint, event: NSEvent, canvas: StrokeCanvasView) {
        let stroke = Stroke(color: PenSettings.shared.currentColor,
                            width: PenSettings.shared.currentWidth)
        startTime = CFAbsoluteTimeGetCurrent()
        stroke.append(StrokePoint(x: Float(pagePoint.x), y: Float(pagePoint.y), t: 0))
        current = stroke
        canvas.beginInProgressStroke(stroke)
    }

    func mouseDragged(to pagePoint: CGPoint, event: NSEvent, canvas: StrokeCanvasView) {
        guard let stroke = current else { return }
        // 위치 변동 없는 sample 차단.
        // Wacom 드라이버는 종종 pressure-only event (위치 그대로, 압력만 갱신)를 섞어 보낸다.
        // 우리는 압력을 안 쓰니까 그런 sample은 무시해야 함 — 안 그러면 같은 좌표에 cap geometry(36 vertex)를
        // 매번 추가해 GPU 일감만 늘어남.
        if let last = stroke.points.last {
            let dx = CGFloat(last.x) - pagePoint.x
            let dy = CGFloat(last.y) - pagePoint.y
            if dx * dx + dy * dy < 0.0025 { return }   // < 0.05 page-pt
        }
        // Date() 할당 회피 — 매 이벤트마다 NSDate 객체 만들지 않고 CF 직접 사용.
        let t = Float((CFAbsoluteTimeGetCurrent() - startTime) * 1000)
        stroke.append(StrokePoint(x: Float(pagePoint.x), y: Float(pagePoint.y), t: t))
        canvas.updateInProgressStroke(stroke)
    }

    func mouseUp(at pagePoint: CGPoint, event: NSEvent, canvas: StrokeCanvasView) {
        guard let stroke = current else { return }
        let t = Float((CFAbsoluteTimeGetCurrent() - startTime) * 1000)
        stroke.append(StrokePoint(x: Float(pagePoint.x), y: Float(pagePoint.y), t: t))
        canvas.commitStroke(stroke)
        current = nil
    }
}
