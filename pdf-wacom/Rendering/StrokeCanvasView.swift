import Cocoa
import Metal
import QuartzCore

// MARK: - StrokeCanvasView
//
// 한 PDF 페이지 위에 얹히는 캔버스 NSView. 펜 stroke의 입력 수신·좌표 변환·렌더링·undo 등록을 담당.
//
// === 좌표계 (중요) ===
//   PDF 페이지 좌표:     원점 좌하단, y-up. 단위는 PDF point. 페이지 mediaBox에 한정.
//   StrokeCanvasView 좌표: 원점 좌하단, y-up. isFlipped=false. (PageView는 isFlipped=true지만 캔버스는 의도적으로 다름.)
//   Stroke 저장 좌표:    페이지 좌표. 줌·뷰 크기 변경에 독립적이라 모델이 안 깨짐.
//
//   변환:
//     event.locationInWindow ──convert──▶ view 좌표 ──scale──▶ 페이지 좌표 (저장)
//     페이지 좌표 ──scale──▶ view 좌표 ──Metal NDC── (렌더링)
//
// === 렌더링 구조 (Live / Baked 분리) ===
//   bakedLayer (CALayer)
//     └── CAShapeLayer × N — 완료된 stroke마다 하나. 정적이라 CA가 GPU 캐시.
//   metalLiveLayer (CAMetalLayer)
//     └── 진행중 stroke만. Metal triangle로 직접 그림.
//
//   왜 분리?
//     CAShapeLayer는 path 바뀔 때마다 vector rasterize → stroke가 길어질수록 비용 ↑.
//     핫패스(live)만 Metal로 가서 점이 늘어나도 GPU 비용 안정. baked는 변경 없으니 CA 그대로 OK.
//
// === 입력 정책 ===
//   - mouseDown 시점에 한 번 펜 여부 판정 (TabletEventRouter). 이후 mouseDragged는 activeTool만 체크.
//     Wacom 드라이버가 stroke 중간에 tabletPoint 빠진 event 섞어 보내는 경우 대응.
//   - mouseDown 시점 modifier로 도구 결정: ⌃ hold면 지우개, 그 외엔 PenSettings 따름.
//
// === Undo ===
//   add/remove 양쪽 모두 NSUndoManager에 inverse 등록. closure 내에서 다시 register하면 redo도 자동.
final class StrokeCanvasView: NSView {

    let pageStrokes: PageStrokes
    let pageBounds: CGRect            // PDF page mediaBox
    private let toolController: ToolController
    var onChange: (() -> Void)?

    private let bakedLayer = CALayer()
    private let metalLiveLayer = CAMetalLayer()
    private var metalRenderer: MetalStrokeRenderer?
    private var inProgressStroke: Stroke?
    private var activeTool: Tool?
    private var strokeLayerByID: [UUID: CAShapeLayer] = [:]
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
        layer?.addSublayer(bakedLayer)

        // Metal renderer + live layer 설정.
        let renderer = MetalStrokeRenderer()
        self.metalRenderer = renderer
        metalLiveLayer.device = renderer?.device
        metalLiveLayer.pixelFormat = .bgra8Unorm
        metalLiveLayer.isOpaque = false                     // 투명 합성 → baked 비침
        metalLiveLayer.framebufferOnly = true
        metalLiveLayer.presentsWithTransaction = false
        metalLiveLayer.maximumDrawableCount = 3
        // vsync 동기 — tearing/jitter 방지. (false면 display refresh 중간에 update 되면서 픽셀이 톡톡 튀어 보임.)
        metalLiveLayer.displaySyncEnabled = true
        metalLiveLayer.allowsNextDrawableTimeout = true
        layer?.addSublayer(metalLiveLayer)

        bakedLayer.actions = [
            "sublayers": NSNull(),
            "position": NSNull(),
            "bounds": NSNull(),
            "contents": NSNull(),
        ]
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
        // size 안 바뀌었으면 비싼 베이크 리렌더링 skip — 펜 입력 중 다른 이유로 layout()이
        // 트리거되더라도 모든 baked CAShapeLayer를 재생성하지 않게 한다.
        let size = bounds.size
        if size == lastLaidOutSize { return }
        lastLaidOutSize = size

        bakedLayer.frame = bounds
        metalLiveLayer.frame = bounds
        updateMetalDrawableSize()
        renderBakedStrokes()
        if inProgressStroke != nil {
            redrawLiveStrokeFromModel()
        }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateMetalDrawableSize()
        if inProgressStroke != nil {
            redrawLiveStrokeFromModel()
        }
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
        // pen 여부는 mouseDown 시점에만 판정. 한 번 stroke가 시작되면 그 stroke 동안의
        // dragged/up은 모두 받는다 — Wacom 드라이버가 중간에 tabletPoint 빠진 event를
        // 섞어 보내는 경우가 있어, 매번 re-filter하면 점 누락 → 글씨가 끊김.
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
        metalRenderer?.beginStroke(color: stroke.color, width: stroke.width, scale: scale)
        for p in stroke.points {
            let v = viewPoint(forPagePoint: CGPoint(x: CGFloat(p.x), y: CGFloat(p.y)))
            metalRenderer?.appendPoint(v)
        }
        presentLive()
    }

    func updateInProgressStroke(_ stroke: Stroke) {
        guard let renderer = metalRenderer else { return }
        let already = renderer.points.count
        let count = stroke.points.count
        guard count > already else { return }
        for i in already..<count {
            let p = stroke.points[i]
            let v = viewPoint(forPagePoint: CGPoint(x: CGFloat(p.x), y: CGFloat(p.y)))
            renderer.appendPoint(v)
        }
        presentLive()
    }

    func commitStroke(_ stroke: Stroke) {
        inProgressStroke = nil
        addStrokeRecordingUndo(stroke, actionName: "Drawing")
        // baked CAShapeLayer는 CATransaction commit (runloop 끝) 후에야 render server에 도달.
        // 반면 Metal present는 즉시 GPU 큐로 들어감. 그 사이 vsync가 오면 "metal 비었는데 baked
        // 아직" 상태로 한 프레임이 표시되어 stroke가 깜빡임 → 손 툭툭 치는 느낌의 원인이 될 수 있음.
        // 다음 runloop iteration으로 metal clear를 defer해 CATransaction commit이 먼저 일어나게 한다.
        DispatchQueue.main.async { [weak self] in
            self?.metalRenderer?.clear()
            self?.presentLive()
        }
    }

    /// inProgressStroke의 모든 점을 view 좌표로 다시 변환해 Metal renderer에 채우고 redraw.
    /// bounds/scale 변경 시 사용.
    private func redrawLiveStrokeFromModel() {
        guard let s = inProgressStroke, let renderer = metalRenderer else { return }
        let scale = window?.backingScaleFactor ?? 2.0
        renderer.beginStroke(color: s.color, width: s.width, scale: scale)
        for p in s.points {
            let v = viewPoint(forPagePoint: CGPoint(x: CGFloat(p.x), y: CGFloat(p.y)))
            renderer.appendPoint(v)
        }
        presentLive()
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
        addBakedStrokeLayer(stroke)
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
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        strokeLayerByID[stroke.id]?.removeFromSuperlayer()
        strokeLayerByID.removeValue(forKey: stroke.id)
        CATransaction.commit()
        window?.undoManager?.registerUndo(withTarget: self) { canvas in
            canvas.addStrokeRecordingUndo(stroke)
        }
        onChange?()
    }

    // MARK: - Baked stroke layers

    private func renderBakedStrokes() {
        bakedLayer.sublayers?.forEach { $0.removeFromSuperlayer() }
        strokeLayerByID.removeAll(keepingCapacity: true)
        for stroke in pageStrokes.strokes {
            addBakedStrokeLayer(stroke)
        }
    }

    private func addBakedStrokeLayer(_ stroke: Stroke) {
        let layer = CAShapeLayer()
        layer.actions = [
            "onOrderIn": NSNull(),
            "onOrderOut": NSNull(),
            "contents": NSNull(),
            "path": NSNull(),
            "strokeColor": NSNull(),
            "fillColor": NSNull(),
            "lineWidth": NSNull(),
            "opacity": NSNull(),
            "hidden": NSNull(),
            "position": NSNull(),
            "bounds": NSNull(),
        ]
        layer.frame = bakedLayer.bounds
        layer.path = makeCGPath(stroke)
        layer.fillColor = nil
        layer.strokeColor = stroke.color.cgColor
        layer.lineWidth = stroke.width
        layer.lineCap = .round
        layer.lineJoin = .round
        bakedLayer.addSublayer(layer)
        strokeLayerByID[stroke.id] = layer
    }

    private func makeCGPath(_ stroke: Stroke) -> CGPath {
        let path = CGMutablePath()
        guard let first = stroke.points.first else { return path }
        let firstView = viewPoint(forPagePoint: CGPoint(x: CGFloat(first.x), y: CGFloat(first.y)))
        path.move(to: firstView)
        for p in stroke.points.dropFirst() {
            let v = viewPoint(forPagePoint: CGPoint(x: CGFloat(p.x), y: CGFloat(p.y)))
            path.addLine(to: v)
        }
        return path
    }
}
