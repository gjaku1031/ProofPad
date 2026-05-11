import Cocoa
import Metal
import QuartzCore
import CoreVideo

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

    // MARK: - Frame pacing (CVDisplayLink)
    //
    // mouseDragged는 Wacom 펜에서 125Hz, 마우스 coalesced에서도 60Hz+로 들어온다.
    // 매 mouseDragged마다 present()를 부르면 WindowServer / 합성기가 그 frequency로 commit을 받게 되어
    // 백프레셔 → cursor display lag, gpuDone 사이 44ms 갭 같은 증상이 발생한다 (이전 profiling으로 확인).
    //
    // 해결: present를 디스플레이 refresh rate (60Hz)에 맞춰 rate-limit.
    //   - mouseDragged 핫패스는 setNeedsPresent() 플래그만 set
    //   - CVDisplayLink가 vsync에 콜백 → main 큐로 dispatch → 플래그 있으면 1회 present
    //   - mouseDown / commitStroke / erase / undo / layout 등 one-shot 액션은 presentNow() 즉시
    //
    // 동일 패턴이 PencilKit / Procreate / Figma 등 저지연 드로잉 앱의 표준 구조.
    private var displayLink: CVDisplayLink?
    /// main thread에서만 read/write. CVDisplayLink 콜백은 DispatchQueue.main.async로 메인에 옴.
    private var presentScheduled = false

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
        // OPAQUE — PDF를 같은 Metal pass에서 그리므로 sibling PDF layer와의 alpha 합성 불필요.
        // WindowServer 합성기는 우리 layer를 단순 카피만 하면 됨 (blend 0).
        // 이게 cursor lag / mid-stroke hitch의 근본 원인이었음.
        metalLiveLayer.isOpaque = true
        metalLiveLayer.framebufferOnly = true
        // unified Metal에선 sibling CALayer가 변하지 않으므로 CATransaction 동기 불필요.
        // false로 두면 cmd.present + commit로 즉시 큐잉만 하고 main 스레드 안 block (이전 true +
        // waitUntilScheduled 패턴이 GPU 바쁠 때 매 present마다 main을 잠깐씩 stall시켜 이벤트 backup 유발).
        metalLiveLayer.presentsWithTransaction = false
        metalLiveLayer.maximumDrawableCount = 3
        // CVDisplayLink가 이미 vsync에 맞춰 present를 보내므로 displaySync 추가 wait이 중복.
        // true일 때: drawable이 *다음* vsync에 표시 → +16.67ms latency.
        // false + DL pacing: 이번 vsync에 즉시 scan-out. tearing risk는 DL timing이 vsync에 align되어 낮음.
        metalLiveLayer.displaySyncEnabled = false
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

    deinit {
        stopDisplayLink()
    }

    // MARK: - Window attachment lifecycle (display link)

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            startDisplayLink()
        } else {
            stopDisplayLink()
        }
    }

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
        presentNow()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateMetalDrawableSize()
        rebuildBakedFromModel()
        if inProgressStroke != nil {
            redrawLiveStrokeFromModel()
        }
        presentNow()
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
        Signposts.signposter.emitEvent("mouseDown")
        // 드로잉 중 시스템 커서 숨김. macOS의 cursor 표시 자체가 ink 렌더보다 한 박자 늦게 따라가는
        // 경향이 있어 사용자가 "잉크가 펜을 못 따라잡는다"고 인식. ink 자체가 펜 위치 표시자.
        // mouseUp에서 반드시 unhide. NSCursor.hide()/unhide()는 카운터식이라 짝 맞아야 함.
        NSCursor.hide()
        let p = pagePoint(for: event)
        let tool = toolController.tool(forModifierFlags: event.modifierFlags)
        activeTool = tool
        tool.mouseDown(at: p, event: event, canvas: self)
    }

    override func mouseDragged(with event: NSEvent) {
        guard activeTool != nil else { return }
        let state = Signposts.signposter.beginInterval("mouseDragged")
        defer { Signposts.signposter.endInterval("mouseDragged", state) }
        let p = pagePoint(for: event)
        activeTool?.mouseDragged(to: p, event: event, canvas: self)
    }

    override func mouseUp(with event: NSEvent) {
        guard activeTool != nil else {
            // activeTool nil이어도 hide/unhide 카운터 안 어긋나게 paired unhide 안 함 (애초에 hide 안 했음).
            return
        }
        Signposts.signposter.emitEvent("mouseUp")
        let p = pagePoint(for: event)
        activeTool?.mouseUp(at: p, event: event, canvas: self)
        activeTool = nil
        NSCursor.unhide()
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
        // mouseDown 직후 첫 점은 즉시 보여줘야 펜이 닿은 느낌. rate-limit 안 함.
        presentNow()
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
        // 핫패스 — 매 mouseDragged마다 present 하면 WindowServer가 백프레셔. CVDisplayLink가 vsync에 1회만.
        setNeedsPresent()
    }

    func commitStroke(_ stroke: Stroke) {
        let state = Signposts.signposter.beginInterval("commit")
        defer { Signposts.signposter.endInterval("commit", state) }
        inProgressStroke = nil
        // 모델/baked/live를 1 trip에 처리해서 present 1회로 끝낸다.
        // 이전엔 addStroke가 present한 뒤 deferred async로 endLive + 또 present (2회). 시각 동일하므로 1회로 통합.
        pageStrokes.add(stroke)
        appendStrokeToBaked(stroke)
        metalRenderer?.endLiveStroke()
        presentNow()
        window?.undoManager?.setActionName("Drawing")
        window?.undoManager?.registerUndo(withTarget: self) { canvas in
            canvas.removeStrokeRecordingUndo(stroke)
        }
        onChange?()
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
        let state = Signposts.signposter.beginInterval("rebuildBaked")
        defer { Signposts.signposter.endInterval("rebuildBaked", state) }
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

    /// PDFPageBackgroundView가 raster 완료 시 호출. PDF 비트맵을 Metal renderer에 텍스처로 전달.
    /// 호출 후 곧바로 present해서 새 PDF 이미지를 화면에 반영.
    func setPDFImage(_ image: CGImage) {
        metalRenderer?.setPDFTexture(from: image)
        presentNow()
    }

    /// 한 stroke를 baked buffer 끝에 append (incremental). rebuildBakedFromModel과 달리 O(stroke 점수).
    /// add 경로(commit, redo)에서만 호출. remove / resize는 여전히 full rebuild.
    private func appendStrokeToBaked(_ stroke: Stroke) {
        guard let renderer = metalRenderer else { return }
        let viewPoints: [SIMD2<Float>] = stroke.points.map { p in
            let v = viewPoint(forPagePoint: CGPoint(x: CGFloat(p.x), y: CGFloat(p.y)))
            return SIMD2<Float>(Float(v.x), Float(v.y))
        }
        let recipe = MetalStrokeRenderer.BakedRecipe(
            points: viewPoints,
            color: colorVector(for: stroke.color),
            halfWidth: Float(stroke.width) * 0.5
        )
        renderer.appendBaked(recipe)
    }

    private func colorVector(for color: NSColor) -> SIMD4<Float> {
        let c = color.usingColorSpace(.deviceRGB) ?? color
        return SIMD4<Float>(Float(c.redComponent),
                            Float(c.greenComponent),
                            Float(c.blueComponent),
                            Float(c.alphaComponent))
    }

    // MARK: - Present (rate-limited via CVDisplayLink)

    /// One-shot 액션용. 즉시 present.
    private func presentNow() {
        presentScheduled = false
        metalRenderer?.draw(in: metalLiveLayer, viewportPoints: bounds.size)
    }

    /// 핫패스용 (mouseDragged). 플래그만 set, 실제 present는 다음 vsync에 displayLink 콜백이 처리.
    private func setNeedsPresent() {
        presentScheduled = true
    }

    private func startDisplayLink() {
        guard displayLink == nil else { return }
        var link: CVDisplayLink?
        let createResult = CVDisplayLinkCreateWithActiveCGDisplays(&link)
        guard createResult == kCVReturnSuccess, let link else { return }

        let opaque = Unmanaged.passUnretained(self).toOpaque()
        CVDisplayLinkSetOutputCallback(link, { (_, _, _, _, _, context) -> CVReturn in
            guard let context else { return kCVReturnSuccess }
            let view = Unmanaged<StrokeCanvasView>.fromOpaque(context).takeUnretainedValue()
            // DL 스레드 → main으로 hop. 캡처한 view가 main 블록 실행까지 살아있음을 보장하려고
            // weak으로 잡는다. stopDisplayLink가 deinit/viewWillMove에서 먼저 stop을 보장하므로
            // 일반적으로는 view가 살아있지만 race 안전 차원.
            DispatchQueue.main.async { [weak view] in
                view?.displayLinkFired()
            }
            return kCVReturnSuccess
        }, opaque)
        CVDisplayLinkStart(link)
        self.displayLink = link
    }

    private func stopDisplayLink() {
        guard let link = displayLink else { return }
        // displayLink을 먼저 nil — 재진입/중복 stop 방어. CVDisplayLinkStop은 sync로 in-flight 콜백 완료까지 대기.
        self.displayLink = nil
        CVDisplayLinkStop(link)
    }

    /// Main thread, dispatched from CVDisplayLink callback.
    private func displayLinkFired() {
        guard presentScheduled else { return }
        presentNow()
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

    /// Redo path (removeStrokeRecordingUndo가 등록한 redo가 호출). 새 stroke를 incremental append.
    /// 초기 commit은 commitStroke가 직접 처리 — 거기서 endLiveStroke까지 같이 묶기 위해.
    private func addStrokeRecordingUndo(_ stroke: Stroke) {
        pageStrokes.add(stroke)
        appendStrokeToBaked(stroke)
        presentNow()
        window?.undoManager?.registerUndo(withTarget: self) { canvas in
            canvas.removeStrokeRecordingUndo(stroke)
        }
        onChange?()
    }

    private func removeStrokeRecordingUndo(_ stroke: Stroke) {
        pageStrokes.remove(id: stroke.id)
        // remove는 buffer 중간에 구멍을 내야 해서 incremental compact가 복잡. 전체 rebuild가 단순하고
        // erase / undo는 mouseDragged만큼 빈번하지 않으므로 cost 허용.
        rebuildBakedFromModel()
        presentNow()
        window?.undoManager?.registerUndo(withTarget: self) { canvas in
            canvas.addStrokeRecordingUndo(stroke)
        }
        onChange?()
    }
}
