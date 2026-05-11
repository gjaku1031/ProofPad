import Cocoa
import Metal
import QuartzCore

// MARK: - StrokeCanvasView (unified Metal)
//
// 한 PDF 페이지 위에 얹히는 캔버스 NSView. 펜 stroke의 입력 수신·좌표 변환·렌더링을 담당.
// undo 등록은 PageStrokes가 맡고, 캔버스는 model 변경 알림을 받아 현재 화면을 다시 그린다.
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
//   - PageStrokes.didChangeNotification: undo/redo 또는 외부 model 변경
//   - layout (bounds size 변경): viewport 변환 결과가 달라짐
//   - viewDidChangeBackingProperties: scale 변경, MSAA texture도 재생성
final class StrokeCanvasView: NSView, DisplayLinkSubscriber {

    let pageStrokes: PageStrokes
    let pageBounds: CGRect            // PDF page mediaBox
    private let toolController: ToolController
    var onChange: (() -> Void)?

    private let metalLiveLayer = CAMetalLayer()
    private var metalRenderer: MetalStrokeRenderer?
    private var inProgressStroke: Stroke?
    private var activeTool: Tool?
    private var lastLaidOutSize: CGSize = .zero
    private var pageStrokesObserver: NSObjectProtocol?
    var isRenderingEnabled: Bool = true {
        didSet {
            guard isRenderingEnabled != oldValue else { return }
            if isRenderingEnabled {
                lastLaidOutSize = .zero
                needsLayout = true
                updateMetalDrawableSize()
                rebuildBakedFromModel()
                presentNow()
            } else {
                presentScheduled = false
            }
        }
    }

    // MARK: - Frame pacing
    //
    // mouseDragged는 Wacom 펜에서 125Hz, 마우스 coalesced에서도 60Hz+로 들어온다.
    // 매 mouseDragged마다 present()를 부르면 WindowServer / 합성기 backpressure 발생.
    //
    // 해결: DisplayLinkCoordinator.shared (앱 전체 단일 CVDisplayLink)에 subscribe.
    //   - mouseDragged 핫패스는 setNeedsPresent() 플래그만 set
    //   - vsync 콜백 → 코디네이터가 fireAll → 우리 displayLinkFired() 호출 (main thread)
    //   - presentScheduled 플래그 있으면 1회 present
    //
    // 이전엔 페이지마다 자기 CVDisplayLink가 있어 30페이지면 60Hz×30개가 main runloop를 두드렸음.
    // 지금은 1개 → 페이지 수 무관.
    /// main thread에서만 read/write.
    private var presentScheduled = false

    // MARK: - Cursor state
    //
    // 펜 모드: drag 동안 NSCursor.hide() — WindowServer 커서 lag을 시각에서 제거. 위치는 Metal synthetic ring으로 표시.
    // 지우개 모드 (⌃ hold): 시스템 NSCursor를 eraser 모양으로 보여줌 (hide 안 함) — 지우개 위치를 사용자가 명확히 인식.
    //
    // Control 플래그 변화는 flagsChanged + cursorUpdate (NSTrackingArea)에서 감지해 NSCursor 갱신.
    private var didHidePenCursor = false

    /// SF Symbol "eraser.fill"을 NSCursor로. macOS NSCursor가 SF Symbol을 직접 받지 못해 bitmap으로 렌더링.
    private static let eraserCursor: NSCursor = {
        let pointSize: CGFloat = 22
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .medium)
        guard let symbol = NSImage(systemSymbolName: "eraser.fill",
                                    accessibilityDescription: "Eraser")?
            .withSymbolConfiguration(config) else {
            return .arrow
        }
        let pad: CGFloat = 4
        let size = NSSize(width: ceil(symbol.size.width) + pad,
                          height: ceil(symbol.size.height) + pad)
        let img = NSImage(size: size, flipped: false) { _ in
            let rect = NSRect(
                x: (size.width - symbol.size.width) / 2,
                y: (size.height - symbol.size.height) / 2,
                width: symbol.size.width,
                height: symbol.size.height
            )
            symbol.draw(in: rect,
                        from: .zero,
                        operation: .sourceOver,
                        fraction: 1.0,
                        respectFlipped: true,
                        hints: nil)
            return true
        }
        return NSCursor(image: img,
                        hotSpot: NSPoint(x: size.width / 2, y: size.height / 2))
    }()

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
        unsubscribeFromPageStrokesChanges()
        DisplayLinkCoordinator.shared.unsubscribe(self)
    }

    // MARK: - Window attachment lifecycle (display link)

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            DisplayLinkCoordinator.shared.subscribe(self)
            subscribeToPageStrokesChanges()
        } else {
            unsubscribeFromPageStrokesChanges()
            DisplayLinkCoordinator.shared.unsubscribe(self)
        }
    }

    private func subscribeToPageStrokesChanges() {
        guard pageStrokesObserver == nil else { return }
        pageStrokesObserver = NotificationCenter.default.addObserver(
            forName: PageStrokes.didChangeNotification,
            object: pageStrokes,
            queue: .main
        ) { [weak self] _ in
            self?.pageStrokesDidChange()
        }
    }

    private func unsubscribeFromPageStrokesChanges() {
        guard let observer = pageStrokesObserver else { return }
        NotificationCenter.default.removeObserver(observer)
        pageStrokesObserver = nil
    }

    private func pageStrokesDidChange() {
        guard window != nil, isRenderingEnabled else { return }
        rebuildBakedFromModel()
        presentNow()
    }

    override func layout() {
        super.layout()
        let size = bounds.size
        guard size != lastLaidOutSize else { return }
        lastLaidOutSize = size

        metalLiveLayer.frame = bounds
        guard isRenderingEnabled else { return }
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
        let p = pagePoint(for: event)
        let tool = toolController.tool(forModifierFlags: event.modifierFlags)
        activeTool = tool
        let isEraser = tool is EraserTool
        // 펜 모드일 때만 시스템 커서 hide — 사용자가 ink를 펜 위치 indicator로 사용 + Metal synthetic ring.
        // 지우개 모드 (⌃ hold)는 시스템 NSCursor가 eraser 모양이라 그대로 보여줘야 함.
        if !isEraser {
            NSCursor.hide()
            didHidePenCursor = true
            metalRenderer?.renderSyntheticCursor = true
        } else {
            metalRenderer?.renderSyntheticCursor = false
        }
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
        // 펜 모드에서 hide했을 때만 paired unhide.
        if didHidePenCursor {
            NSCursor.unhide()
            didHidePenCursor = false
        }
        // synthetic cursor는 liveActive가 false면 자연스럽게 안 그려짐.
    }

    // MARK: - Cursor: Control modifier → eraser cursor

    override func flagsChanged(with event: NSEvent) {
        super.flagsChanged(with: event)
        refreshCursorForModifiers(event.modifierFlags)
    }

    override func cursorUpdate(with event: NSEvent) {
        // Tracking area의 .cursorUpdate 옵션이 트리거. 마우스가 view 영역에 들어올 때 커서 set.
        refreshCursorForModifiers(event.modifierFlags)
    }

    private func refreshCursorForModifiers(_ flags: NSEvent.ModifierFlags) {
        // 드래그 중에는 커서 갱신 안 함 — 이미 mouseDown에서 결정한 상태 유지.
        guard activeTool == nil else { return }
        if flags.contains(.control) {
            Self.eraserCursor.set()
        } else {
            NSCursor.arrow.set()
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.cursorUpdate, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
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
        pageStrokes.addRecordingUndo(stroke,
                                     undoManager: window?.undoManager,
                                     actionName: "Drawing",
                                     notify: false,
                                     onChange: onChange)
        appendStrokeToBaked(stroke)
        metalRenderer?.endLiveStroke()
        presentNow()
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
        guard isRenderingEnabled, window != nil, bounds.width > 0, bounds.height > 0 else { return }
        presentScheduled = false
        metalRenderer?.draw(in: metalLiveLayer, viewportPoints: bounds.size)
    }

    /// 핫패스용 (mouseDragged). 플래그만 set, 실제 present는 다음 vsync에 displayLink 콜백이 처리.
    private func setNeedsPresent() {
        presentScheduled = true
    }

    /// DisplayLinkCoordinator가 vsync에 호출. main thread.
    /// presentScheduled가 true일 때만 실제 present — 비활성 페이지는 0 cost.
    func displayLinkFired() {
        guard presentScheduled else { return }
        presentNow()
    }

    func removeStroke(id: UUID) {
        guard let stroke = pageStrokes.strokes.first(where: { $0.id == id }) else { return }
        pageStrokes.removeRecordingUndo(stroke,
                                        undoManager: window?.undoManager,
                                        notify: false,
                                        onChange: onChange)
        // remove는 buffer 중간에 구멍을 내야 해서 incremental compact가 복잡. 전체 rebuild가 단순하고
        // erase / undo는 mouseDragged만큼 빈번하지 않으므로 cost 허용.
        rebuildBakedFromModel()
        presentNow()
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

}
