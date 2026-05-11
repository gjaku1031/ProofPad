import Cocoa
import Metal
import QuartzCore

// MARK: - StrokeCanvasView (unified Metal)
//
// 한 PDF 페이지 위에 얹히는 캔버스 NSView. 펜 stroke의 입력 수신·좌표 변환·렌더링·undo 등록을 담당.
//
// === 좌표계 (중요) ===
//   PDF 페이지 좌표:    원점 좌하단, y-up. 단위는 PDF point. 페이지 mediaBox에 한정.
//   StrokeCanvasView 좌표: 원점 좌하단, y-up. isFlipped=false. (PageView는 isFlipped=true지만 캔버스는 의도적으로 다름.)
//   Stroke 저장 좌표:   페이지 좌표. 줌·뷰 크기 변경에 독립적이라 모델이 안 깨짐.
//
//   변환:
//     event.locationInWindow ──convert──▶ view 좌표 ──scale──▶ 페이지 좌표 (저장)
//     페이지 좌표 ──scale──▶ view 좌표 ──Metal NDC── (렌더링)
//
// === 렌더링 구조 (Unified Metal) ===
//   metalLiveLayer (CAMetalLayer)
//     └── MetalStrokeRenderer가 baked + live를 한 render pass에서 다 그림.
//         baked는 4x MSAA로, live도 같은 pass에서 동일 AA로 → mouseUp 시 시각 점프 없음.
//
//   이전 (Phase A): bakedLayer (CAShapeLayer × N) + metalLiveLayer 분리. live(Metal AA) → baked(Quartz AA)
//                  swap에서 edge 품질 변하는 시각 jump가 보였음.
//
// === 입력 정책 ===
//   - mouseDown 시점에 한 번 펜 여부 판정 (TabletEventRouter). 이후 mouseDragged는 activeTool만 체크.
//   - mouseDown 시점 modifier로 도구 결정: ⌃ hold면 지우개, 그 외엔 PenSettings 따름.
//
// === Baked rebuild 트리거 ===
//   - mouseUp (commitStroke): 새 stroke 추가됨
//   - removeStroke (eraser, undo): stroke 제거됨
//   - undo/redo callback (addStrokeRecordingUndo): 다시 추가
//   - layout (bounds size 변경): viewport 변환 결과가 달라짐
//   - viewDidChangeBackingProperties: scale 변경, MSAA texture도 재생성
final class StrokeCanvasView: NSView {

    let pageStrokes: PageStrokes
    let pageBounds: CGRect            // PDF page mediaBox
    private let toolController: ToolController
    var onChange: (() -> Void)?

    private let metalLiveLayer = CAMetalLayer()
    private var metalRenderer: MetalStrokeRenderer?
    private var inProgressStroke: Stroke?
    private var activeTool: Tool?
    private var lastLaidOutSize: CGSize = .zero

    override var isFlipped: Bool { false }
    override var acceptsFirstResponder: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    init(pageBounds: CGRect, pageStrokes: PageStrokes, toolController: ToolController) {
        self.pageBounds = pageBounds
        self.pageStrokes = pageStrokes
        self.toolController = toolController
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true

        let renderer = MetalStrokeRenderer()
        self.metalRenderer = renderer
        metalLiveLayer.device = renderer?.device
        metalLiveLayer.pixelFormat = .bgra8Unorm
        metalLiveLayer.isOpaque = false                     // 투명 합성 → PDF 배경 비침
        metalLiveLayer.framebufferOnly = true
        // CATransaction과 동기로 present — sibling CALayer 변경과 atomic 합성, mid-frame inconsistency 방지.
        metalLiveLayer.presentsWithTransaction = true
        metalLiveLayer.maximumDrawableCount = 3
        metalLiveLayer.displaySyncEnabled = true
        metalLiveLayer.allowsNextDrawableTimeout = true
        layer?.addSublayer(metalLiveLayer)
        metalLiveLayer.actions = [
            "position": NSNull(),
            "bounds": NSNull(),
            "contents": NSNull(),
            "hidden": NSNull(),
        ]
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layout() {
        super.layout()
        let size = bounds.size
        guard size != lastLaidOutSize else { return }
        lastLaidOutSize = size

        metalLiveLayer.frame = bounds
        updateMetalDrawableSize()
        rebuildBakedFromModel()
        if inProgressStroke != nil {
            redrawLiveStrokeFromModel()
        }
        // viewport 바뀌었으면 바로 present해 이전 stale 이미지 안 보이게.
        presentLive()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateMetalDrawableSize()
        rebuildBakedFromModel()
        if inProgressStroke != nil {
            redrawLiveStrokeFromModel()
        }
        presentLive()
    }

    private func updateMetalDrawableSize() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        metalLiveLayer.contentsScale = scale
        let w = max(bounds.width * scale, 1)
        let h = max(bounds.height * scale, 1)
        metalLiveLayer.drawableSize = CGSize(width: w, height: h)
    }

    // MARK: - Input dispatch

    override func mouseDown(with event: NSEvent) {
        guard TabletEventRouter.decide(event) == .pen else { return }
        let p = pagePoint(for: event)
        let tool = toolController.tool(forModifierFlags: event.modifierFlags)
        activeTool = tool
        tool.mouseDown(at: p, event: event, canvas: self)
    }

    override func mouseDragged(with event: NSEvent) {
        guard activeTool != nil else { return }
        let p = pagePoint(for: event)
        activeTool?.mouseDragged(to: p, event: event, canvas: self)
    }

    override func mouseUp(with event: NSEvent) {
        guard activeTool != nil else { return }
        let p = pagePoint(for: event)
        activeTool?.mouseUp(at: p, event: event, canvas: self)
        activeTool = nil
    }

    // MARK: - Coord transforms (view ↔ page)

    private func pagePoint(for event: NSEvent) -> CGPoint {
        let viewPoint = convert(event.locationInWindow, from: nil)
        return pagePoint(forViewPoint: viewPoint)
    }

    private func pagePoint(forViewPoint v: CGPoint) -> CGPoint {
        let sx = pageBounds.width / max(bounds.width, 1)
        let sy = pageBounds.height / max(bounds.height, 1)
        return CGPoint(x: v.x * sx, y: v.y * sy)
    }

    private func viewPoint(forPagePoint p: CGPoint) -> CGPoint {
        let sx = bounds.width / max(pageBounds.width, 1)
        let sy = bounds.height / max(pageBounds.height, 1)
        return CGPoint(x: p.x * sx, y: p.y * sy)
    }

    // MARK: - Stroke API (Tools가 호출)

    func beginInProgressStroke(_ stroke: Stroke) {
        inProgressStroke = stroke
        let scale = window?.backingScaleFactor ?? 2.0
        metalRenderer?.beginLiveStroke(color: stroke.color, width: stroke.width, scale: scale)
        for p in stroke.points {
            let v = viewPoint(forPagePoint: CGPoint(x: CGFloat(p.x), y: CGFloat(p.y)))
            metalRenderer?.appendLivePoint(v)
        }
        presentLive()
    }

    func updateInProgressStroke(_ stroke: Stroke) {
        guard let renderer = metalRenderer else { return }
        let already = renderer.livePoints.count
        let count = stroke.points.count
        guard count > already else { return }
        for i in already..<count {
            let p = stroke.points[i]
            let v = viewPoint(forPagePoint: CGPoint(x: CGFloat(p.x), y: CGFloat(p.y)))
            renderer.appendLivePoint(v)
        }
        presentLive()
    }

    func commitStroke(_ stroke: Stroke) {
        inProgressStroke = nil
        addStrokeRecordingUndo(stroke, actionName: "Drawing")
        // baked에 합쳐졌으므로 live는 비운다. defer로 baked rebuild가 먼저 frame에 반영되게.
        DispatchQueue.main.async { [weak self] in
            self?.metalRenderer?.endLiveStroke()
            self?.presentLive()
        }
    }

    /// inProgressStroke의 모든 점을 view 좌표로 다시 변환해 Metal renderer에 채우고 redraw.
    /// bounds/scale 변경 시 사용.
    private func redrawLiveStrokeFromModel() {
        guard let s = inProgressStroke, let renderer = metalRenderer else { return }
        let scale = window?.backingScaleFactor ?? 2.0
        renderer.beginLiveStroke(color: s.color, width: s.width, scale: scale)
        for p in s.points {
            let v = viewPoint(forPagePoint: CGPoint(x: CGFloat(p.x), y: CGFloat(p.y)))
            renderer.appendLivePoint(v)
        }
    }

    /// pageStrokes 전체를 view 좌표 BakedRecipe 배열로 변환해 renderer에 전달.
    /// O(N stroke × M point) — stroke add/remove/resize 때만 호출되므로 빈도 낮음.
    private func rebuildBakedFromModel() {
        guard let renderer = metalRenderer else { return }
        let recipes: [MetalStrokeRenderer.BakedRecipe] = pageStrokes.strokes.map { stroke in
            let viewPoints: [SIMD2<Float>] = stroke.points.map { p in
                let v = viewPoint(forPagePoint: CGPoint(x: CGFloat(p.x), y: CGFloat(p.y)))
                return SIMD2<Float>(Float(v.x), Float(v.y))
            }
            return MetalStrokeRenderer.BakedRecipe(
                points: viewPoints,
                color: colorVector(for: stroke.color),
                halfWidth: Float(stroke.width) * 0.5
            )
        }
        renderer.rebuildBaked(recipes)
    }

    private func colorVector(for color: NSColor) -> SIMD4<Float> {
        let c = color.usingColorSpace(.deviceRGB) ?? color
        return SIMD4<Float>(Float(c.redComponent),
                            Float(c.greenComponent),
                            Float(c.blueComponent),
                            Float(c.alphaComponent))
    }

    private func presentLive() {
        metalRenderer?.draw(in: metalLiveLayer, viewportPoints: bounds.size)
    }

    func removeStroke(id: UUID) {
        guard let stroke = pageStrokes.strokes.first(where: { $0.id == id }) else { return }
        removeStrokeRecordingUndo(stroke)
    }

    // MARK: - Undo grouping helpers (Eraser drag 동안 한 묶음)

    func beginEraseUndoGroup() {
        let um = window?.undoManager
        um?.beginUndoGrouping()
        um?.setActionName("Erase")
    }

    func endEraseUndoGroup() {
        window?.undoManager?.endUndoGrouping()
    }

    // MARK: - Add / Remove with undo

    private func addStrokeRecordingUndo(_ stroke: Stroke, actionName: String? = nil) {
        pageStrokes.add(stroke)
        rebuildBakedFromModel()
        presentLive()
        if let name = actionName {
            window?.undoManager?.setActionName(name)
        }
        window?.undoManager?.registerUndo(withTarget: self) { canvas in
            canvas.removeStrokeRecordingUndo(stroke)
        }
        onChange?()
    }

    private func removeStrokeRecordingUndo(_ stroke: Stroke) {
        pageStrokes.remove(id: stroke.id)
        rebuildBakedFromModel()
        presentLive()
        window?.undoManager?.registerUndo(withTarget: self) { canvas in
            canvas.addStrokeRecordingUndo(stroke)
        }
        onChange?()
    }
}
