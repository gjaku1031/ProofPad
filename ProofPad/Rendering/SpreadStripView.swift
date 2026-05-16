import Cocoa
import PDFKit

// MARK: - SpreadStripView
//
// NSScrollView의 documentView. 모든 펼침면을 세로로 누적해서 한 줄로 보여준다.
//
// === Zoom mode ===
//   .fitWidth     기본. clip width에 맞춰 페이지 폭 결정. 윈도우 리사이즈하면 자동 추종.
//   .fitHeight    clip height에 맞춰 페이지 높이 결정.
//   .fitPage      min(fitWidth, fitHeight).
//   .custom(s)    s = 1.0이면 actual size. 0.25 ~ 8.0 범위 (pinch zoom + ⌘+/⌘-).
//
// === pagesPerSpread ===
//   1: 한 페이지가 spread 폭 전체 차지 (한 페이지 모드).
//   2: 좌우 두 페이지가 펼침면으로 (책 모드). 표지 단독 옵션은 PDFInkDocument.coverIsSinglePage.
//
// === 스크롤 좌표 ===
//   SpreadView × N를 위에서 아래로 쌓는다 (y=topMargin부터 spreadGap 간격).
//   documentView width = max(clipWidth, contentWidth) — 페이지보다 윈도우가 넓으면 가운데 정렬 가능.
final class SpreadStripView: NSView {

    enum ZoomMode: Equatable {
        case fitWidth
        case fitHeight
        case fitPage
        case custom(CGFloat)   // 1.0 == 페이지 actual size (1pt → 1 view pt)
    }

    private(set) var spreadViews: [(spread: Spread, view: SpreadView)] = []
    private var clipBoundsObserver: NSObjectProtocol?
    private weak var observedClipView: NSClipView?

    private struct ViewportAnchor {
        let spreadIndex: Int
        let relativeX: CGFloat
        let relativeY: CGFloat
        let viewportOffset: NSPoint
    }

    private struct PageViewportAnchor {
        let pageIndex: Int
        let relativeX: CGFloat
        let relativeY: CGFloat
        let viewportOffset: NSPoint
    }

    var spreadGap: CGFloat = 36 { didSet { needsLayout = true } }
    var pageGap: CGFloat = 12 { didSet { needsLayout = true } }
    var horizontalMargin: CGFloat = 32 { didSet { needsLayout = true } }
    var topMargin: CGFloat = 32 { didSet { needsLayout = true } }
    var bottomMargin: CGFloat = 32 { didSet { needsLayout = true } }

    /// Fit height/page 모드에서는 viewport 높이의 대부분을 페이지가 채우도록 vertical 여백을 줄인다.
    /// (큰 topMargin/bottomMargin은 fit width / custom에서 호흡감을 주려는 용도라 fit 모드와 충돌.)
    private var effectiveTopMargin: CGFloat {
        switch zoomMode {
        case .fitHeight, .fitPage: return 12
        default: return topMargin
        }
    }
    private var effectiveBottomMargin: CGFloat {
        switch zoomMode {
        case .fitHeight, .fitPage: return 12
        default: return bottomMargin
        }
    }
    private var effectiveHorizontalMargin: CGFloat {
        switch zoomMode {
        case .fitWidth: return 0
        default: return horizontalMargin
        }
    }

    var zoomMode: ZoomMode = .fitWidth {
        didSet {
            applyAutoresizingForZoomMode()
            enclosingScrollView?.hasHorizontalScroller = !isFitWidth
            needsLayout = true
        }
    }

    /// 한 펼침면에 몇 페이지를 가로로 배치할지 (1 또는 2).
    var pagesPerSpread: Int = 2 {
        didSet {
            for entry in spreadViews { entry.view.pagesAcross = pagesPerSpread }
            needsLayout = true
        }
    }

    private var isFitWidth: Bool {
        if case .fitWidth = zoomMode { return true }
        return false
    }

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        applyAutoresizingForZoomMode()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    deinit {
        removeClipBoundsObserver()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        configureClipBoundsObserver()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        configureClipBoundsObserver()
        updateRenderingForVisibleRect()
    }

    private func applyAutoresizingForZoomMode() {
        autoresizingMask = isFitWidth ? [.width] : []
    }

    private func configureClipBoundsObserver() {
        guard let clipView = enclosingScrollView?.contentView else { return }
        guard observedClipView !== clipView else { return }
        removeClipBoundsObserver()
        observedClipView = clipView
        clipView.postsBoundsChangedNotifications = true
        clipBoundsObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: clipView,
            queue: .main
        ) { [weak self] _ in
            self?.updateRenderingForVisibleRect()
        }
    }

    private func removeClipBoundsObserver() {
        if let clipBoundsObserver {
            NotificationCenter.default.removeObserver(clipBoundsObserver)
        }
        clipBoundsObserver = nil
        observedClipView = nil
    }

    func setSpreads(_ list: [Spread],
                    document: PDFInkDocument,
                    toolController: ToolController,
                    onChange: @escaping () -> Void,
                    pagesPerSpread newPagesPerSpread: Int? = nil) {
        let anchor = makePageViewportAnchor()
        if let newPagesPerSpread {
            pagesPerSpread = newPagesPerSpread
        }
        spreadViews.forEach { $0.view.removeFromSuperview() }
        spreadViews = list.map { spread in
            let v = SpreadView(spread: spread,
                               document: document,
                               toolController: toolController,
                               onChange: onChange)
            v.pagesAcross = pagesPerSpread
            addSubview(v)
            return (spread, v)
        }
        needsLayout = true
        layoutSubtreeIfNeeded()
        restorePageViewportAnchor(anchor)
        updateRenderingForVisibleRect()
    }

    /// 다음 펼침면으로 (zoom 비율 유지).
    func scrollToNextSpread() {
        guard let idx = currentVisibleSpreadIndex() else { return }
        scroll(toSpreadIndex: min(idx + 1, spreadViews.count - 1))
    }

    /// 이전 펼침면으로 (zoom 비율 유지).
    func scrollToPreviousSpread() {
        guard let idx = currentVisibleSpreadIndex() else { return }
        scroll(toSpreadIndex: max(idx - 1, 0))
    }

    /// 현재 viewport 중심에 가장 가까운 spread index.
    private func currentVisibleSpreadIndex() -> Int? {
        guard !spreadViews.isEmpty else { return nil }
        guard let scroll = enclosingScrollView else { return nil }
        let centerY = scroll.contentView.bounds.midY
        // 정확히 중심 포함 spread 우선
        if let i = spreadViews.firstIndex(where: { entry in
            entry.view.frame.minY <= centerY && centerY < entry.view.frame.maxY
        }) { return i }
        // 없으면 가장 가까운 spread
        var bestIdx = 0
        var bestDist = CGFloat.greatestFiniteMagnitude
        for (i, entry) in spreadViews.enumerated() {
            let d = abs(entry.view.frame.midY - centerY)
            if d < bestDist { bestIdx = i; bestDist = d }
        }
        return bestIdx
    }

    /// spread index로 스크롤 (zoom 영향 없음 — frame 그대로 이동).
    func scroll(toSpreadIndex i: Int) {
        guard spreadViews.indices.contains(i) else { return }
        let target = spreadViews[i].view.frame
        if let scroll = enclosingScrollView {
            let newOrigin = NSPoint(x: scroll.contentView.bounds.origin.x, y: target.minY)
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.2
                ctx.allowsImplicitAnimation = true
                scroll.contentView.animator().setBoundsOrigin(newOrigin)
            } completionHandler: { [weak scroll] in
                if let scroll { scroll.reflectScrolledClipView(scroll.contentView) }
            }
        } else {
            spreadViews[i].view.scrollToVisible(spreadViews[i].view.bounds)
        }
    }

    /// 0-based page index를 포함하는 펼침면으로 스크롤한다.
    func scroll(toPageIndex pageIndex: Int) {
        guard let entry = spreadViews.first(where: { containsPage($0.spread, pageIndex: pageIndex) }) else { return }
        let target = entry.view.frame
        if let scroll = enclosingScrollView {
            let clipBounds = scroll.contentView.bounds
            let newOrigin = NSPoint(x: clipBounds.origin.x, y: target.minY)
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.25
                ctx.allowsImplicitAnimation = true
                scroll.contentView.animator().setBoundsOrigin(newOrigin)
            } completionHandler: { [weak scroll] in
                if let scroll { scroll.reflectScrolledClipView(scroll.contentView) }
            }
        } else {
            entry.view.scrollToVisible(entry.view.bounds)
        }
    }

    func currentPrimaryPageIndex() -> Int? {
        guard !spreadViews.isEmpty else { return nil }
        guard let scroll = enclosingScrollView else {
            return spreadViews.first?.view.primaryPageIndex(near: .zero)
        }
        let center = CGPoint(x: scroll.contentView.bounds.midX,
                             y: scroll.contentView.bounds.midY)
        if let entry = spreadViews.first(where: { $0.view.frame.contains(center) }) {
            let local = CGPoint(x: center.x - entry.view.frame.minX,
                                y: center.y - entry.view.frame.minY)
            return entry.view.primaryPageIndex(near: local)
        }
        guard let index = currentVisibleSpreadIndex() else { return nil }
        let view = spreadViews[index].view
        let local = CGPoint(x: center.x - view.frame.minX,
                            y: center.y - view.frame.minY)
        return view.primaryPageIndex(near: local)
    }

    private func containsPage(_ spread: Spread, pageIndex: Int) -> Bool {
        if let l = spread.leftPage, l.document?.index(for: l) == pageIndex { return true }
        if let r = spread.rightPage, r.document?.index(for: r) == pageIndex { return true }
        return false
    }

    // MARK: - Layout

    override func layout() {
        super.layout()
        guard let referenceSpread = spreadViews.first?.spread else { return }
        let pageAnchor = makePageViewportAnchor()
        let referencePage = referenceSpread.leftPage ?? referenceSpread.rightPage
        let pagePtSize = referencePage?.bounds(for: .mediaBox).size
            ?? NSSize(width: 612, height: 792)
        let pageAspect = pagePtSize.height / max(pagePtSize.width, 1)

        let clipSize = enclosingScrollView?.contentView.bounds.size ?? bounds.size

        // perPageWidth = 한 페이지 view 너비 (포인트). 단일/펼침에서 동일한 의미.
        let isSingle = pagesPerSpread <= 1
        let hMargin = effectiveHorizontalMargin
        let topM = effectiveTopMargin
        let botM = effectiveBottomMargin
        let perPageWidth: CGFloat
        switch zoomMode {
        case .fitWidth:
            let availWidth = max(0, clipSize.width - hMargin * 2)
            perPageWidth = isSingle ? availWidth : max(0, (availWidth - pageGap) / 2)
        case .fitHeight:
            let availHeight = max(0, clipSize.height - topM - botM)
            perPageWidth = availHeight / max(pageAspect, 0.001)
        case .fitPage:
            let availWidth = max(0, clipSize.width - hMargin * 2)
            let fwPer = isSingle ? availWidth : max(0, (availWidth - pageGap) / 2)
            let availHeight = max(0, clipSize.height - topM - botM)
            let fhPer = availHeight / max(pageAspect, 0.001)
            perPageWidth = min(fwPer, fhPer)
        case .custom(let scale):
            perPageWidth = pagePtSize.width * scale
        }

        let pageHeight = perPageWidth * pageAspect
        let spreadWidth = isSingle ? perPageWidth : (perPageWidth * 2 + pageGap)
        let totalContentWidth = spreadWidth + hMargin * 2

        // documentView의 width는 max(clip, content)로 두어 가운데 정렬 가능.
        let docWidth = max(clipSize.width, totalContentWidth)
        let xOffset = (docWidth - spreadWidth) / 2

        var y: CGFloat = topM
        for (_, view) in spreadViews {
            view.pageGap = pageGap
            view.frame = NSRect(x: xOffset, y: y, width: spreadWidth, height: pageHeight)
            y += pageHeight + spreadGap
        }
        let totalHeight = max(y - spreadGap + botM, 0)

        if abs(frame.width - docWidth) > 0.5 || abs(frame.height - totalHeight) > 0.5 {
            setFrameSize(NSSize(width: docWidth, height: totalHeight))
        }
        restorePageViewportAnchor(pageAnchor)
        updateRenderingForVisibleRect()
    }

    // MARK: - Pinch zoom

    override func magnify(with event: NSEvent) {
        // event.magnification: -1...+1 정도. 누적해서 custom scale 변경.
        let currentScale = currentEffectiveScale()
        let newScale = (currentScale * (1 + event.magnification))
            .clampedTo(min: 0.25, max: 8.0)
        setZoomMode(.custom(newScale), preservingEvent: event)
    }

    /// ⌘ + scroll wheel = zoom. 일반 scroll은 NSScrollView 동작.
    /// 마우스 휠(이산, delta~1)과 트랙패드(연속, delta 누적이 큼)의 스케일이 달라
    /// hasPreciseScrollingDeltas로 분기 — 한 click에 ~12% 변화 vs 누적해서 부드럽게.
    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            let delta = event.scrollingDeltaY
            guard abs(delta) > 0.001 else { return }
            let step: CGFloat
            if event.hasPreciseScrollingDeltas {
                // 트랙패드 — delta가 한 swipe에 누적 ~수십. 작은 계수로 부드럽게.
                step = (delta * 0.012).clampedTo(min: -0.4, max: 0.4)
            } else {
                // 마우스 휠 — delta ~1 per click. 10~12% per click으로 가파르게.
                step = (delta * 0.12).clampedTo(min: -0.3, max: 0.3)
            }
            let newScale = (currentEffectiveScale() * (1.0 + step))
                .clampedTo(min: 0.25, max: 8.0)
            setZoomMode(.custom(newScale), preservingEvent: event)
            return
        }
        super.scrollWheel(with: event)
    }

    private func currentEffectiveScale() -> CGFloat {
        guard let referenceSpread = spreadViews.first?.spread,
              let page = referenceSpread.leftPage ?? referenceSpread.rightPage else { return 1.0 }
        let pagePtWidth = page.bounds(for: .mediaBox).width
        let spreadW = spreadViews.first?.view.frame.width ?? 0
        let perPageW = pagesPerSpread <= 1 ? spreadW : max(0, (spreadW - pageGap) / 2)
        return perPageW / max(pagePtWidth, 1)
    }

    /// 외부(ZoomController)에서 step 줌인/아웃 시 현재 effective scale 기반으로 scale 변경.
    func zoomBy(factor: CGFloat) {
        let s = (currentEffectiveScale() * factor).clampedTo(min: 0.25, max: 8.0)
        setZoomModePreservingViewport(.custom(s))
    }

    func setZoomModePreservingViewport(_ mode: ZoomMode) {
        setZoomMode(mode, preservingEvent: nil)
    }

    private func setZoomMode(_ mode: ZoomMode, preservingEvent event: NSEvent?) {
        let anchor = makeViewportAnchor(event: event)
        zoomMode = mode
        layoutSubtreeIfNeeded()
        restoreViewportAnchor(anchor)
        updateRenderingForVisibleRect()
    }

    private func makeViewportAnchor(event: NSEvent?) -> ViewportAnchor? {
        guard let scroll = enclosingScrollView else { return nil }
        let clipBounds = scroll.contentView.bounds
        let documentPoint: NSPoint
        if let event {
            let eventPoint = convert(event.locationInWindow, from: nil)
            documentPoint = bounds.contains(eventPoint)
                ? eventPoint
                : NSPoint(x: clipBounds.midX, y: clipBounds.midY)
        } else {
            documentPoint = NSPoint(x: clipBounds.midX, y: clipBounds.midY)
        }
        guard let spreadIndex = spreadIndex(anchoring: documentPoint) else { return nil }
        let spreadFrame = spreadViews[spreadIndex].view.frame
        let relativeX = ((documentPoint.x - spreadFrame.minX) / max(spreadFrame.width, 1))
            .clampedTo(min: 0, max: 1)
        let relativeY = ((documentPoint.y - spreadFrame.minY) / max(spreadFrame.height, 1))
            .clampedTo(min: 0, max: 1)
        return ViewportAnchor(
            spreadIndex: spreadIndex,
            relativeX: relativeX,
            relativeY: relativeY,
            viewportOffset: NSPoint(x: documentPoint.x - clipBounds.minX,
                                    y: documentPoint.y - clipBounds.minY)
        )
    }

    private func spreadIndex(anchoring documentPoint: NSPoint) -> Int? {
        guard !spreadViews.isEmpty else { return nil }
        if let containing = spreadViews.firstIndex(where: { $0.view.frame.contains(documentPoint) }) {
            return containing
        }
        var bestIndex = 0
        var bestDistance = CGFloat.greatestFiniteMagnitude
        for (index, entry) in spreadViews.enumerated() {
            let frame = entry.view.frame
            let dx: CGFloat
            if documentPoint.x < frame.minX {
                dx = frame.minX - documentPoint.x
            } else if documentPoint.x > frame.maxX {
                dx = documentPoint.x - frame.maxX
            } else {
                dx = 0
            }
            let dy: CGFloat
            if documentPoint.y < frame.minY {
                dy = frame.minY - documentPoint.y
            } else if documentPoint.y > frame.maxY {
                dy = documentPoint.y - frame.maxY
            } else {
                dy = 0
            }
            let distance = dx * dx + dy * dy
            if distance < bestDistance {
                bestDistance = distance
                bestIndex = index
            }
        }
        return bestIndex
    }

    private func restoreViewportAnchor(_ anchor: ViewportAnchor?) {
        guard let anchor,
              spreadViews.indices.contains(anchor.spreadIndex),
              let scroll = enclosingScrollView else { return }
        let clipView = scroll.contentView
        let spreadFrame = spreadViews[anchor.spreadIndex].view.frame
        let anchoredDocumentPoint = NSPoint(
            x: spreadFrame.minX + spreadFrame.width * anchor.relativeX,
            y: spreadFrame.minY + spreadFrame.height * anchor.relativeY
        )
        let proposedOrigin = NSPoint(
            x: anchoredDocumentPoint.x - anchor.viewportOffset.x,
            y: anchoredDocumentPoint.y - anchor.viewportOffset.y
        )
        clipView.setBoundsOrigin(clampedScrollOrigin(proposedOrigin, clipSize: clipView.bounds.size))
        scroll.reflectScrolledClipView(clipView)
    }

    private func makePageViewportAnchor() -> PageViewportAnchor? {
        guard let scroll = enclosingScrollView, !spreadViews.isEmpty else { return nil }
        let clipBounds = scroll.contentView.bounds
        let documentPoint = NSPoint(x: clipBounds.midX, y: clipBounds.midY)
        guard let anchoredPage = pageFrame(anchoring: documentPoint) else { return nil }
        let relativeX = ((documentPoint.x - anchoredPage.frame.minX) / max(anchoredPage.frame.width, 1))
            .clampedTo(min: 0, max: 1)
        let relativeY = ((documentPoint.y - anchoredPage.frame.minY) / max(anchoredPage.frame.height, 1))
            .clampedTo(min: 0, max: 1)
        return PageViewportAnchor(
            pageIndex: anchoredPage.pageIndex,
            relativeX: relativeX,
            relativeY: relativeY,
            viewportOffset: NSPoint(x: documentPoint.x - clipBounds.minX,
                                    y: documentPoint.y - clipBounds.minY)
        )
    }

    private func restorePageViewportAnchor(_ anchor: PageViewportAnchor?) {
        guard let anchor,
              let scroll = enclosingScrollView,
              let frame = pageFrameInDocument(forPageIndex: anchor.pageIndex) else { return }
        let clipView = scroll.contentView
        let anchoredDocumentPoint = NSPoint(
            x: frame.minX + frame.width * anchor.relativeX,
            y: frame.minY + frame.height * anchor.relativeY
        )
        let proposedOrigin = NSPoint(
            x: anchoredDocumentPoint.x - anchor.viewportOffset.x,
            y: anchoredDocumentPoint.y - anchor.viewportOffset.y
        )
        clipView.setBoundsOrigin(clampedScrollOrigin(proposedOrigin, clipSize: clipView.bounds.size))
        scroll.reflectScrolledClipView(clipView)
    }

    private func pageFrame(anchoring documentPoint: NSPoint) -> (pageIndex: Int, frame: NSRect)? {
        var best: (pageIndex: Int, frame: NSRect, distance: CGFloat)?
        for entry in spreadViews {
            for pageView in [entry.view.leftPageView, entry.view.rightPageView].compactMap({ $0 }) {
                let frame = pageView.frame.offsetBy(dx: entry.view.frame.minX,
                                                    dy: entry.view.frame.minY)
                if frame.contains(documentPoint) {
                    return (pageView.pageIndex, frame)
                }
                let dx: CGFloat
                if documentPoint.x < frame.minX {
                    dx = frame.minX - documentPoint.x
                } else if documentPoint.x > frame.maxX {
                    dx = documentPoint.x - frame.maxX
                } else {
                    dx = 0
                }
                let dy: CGFloat
                if documentPoint.y < frame.minY {
                    dy = frame.minY - documentPoint.y
                } else if documentPoint.y > frame.maxY {
                    dy = documentPoint.y - frame.maxY
                } else {
                    dy = 0
                }
                let distance = dx * dx + dy * dy
                if best == nil || distance < best!.distance {
                    best = (pageView.pageIndex, frame, distance)
                }
            }
        }
        guard let best else { return nil }
        return (best.pageIndex, best.frame)
    }

    private func pageFrameInDocument(forPageIndex pageIndex: Int) -> NSRect? {
        for entry in spreadViews {
            if let pageFrame = entry.view.pageFrame(forPageIndex: pageIndex) {
                return pageFrame.offsetBy(dx: entry.view.frame.minX,
                                          dy: entry.view.frame.minY)
            }
        }
        return nil
    }

    private func clampedScrollOrigin(_ origin: NSPoint, clipSize: NSSize) -> NSPoint {
        let maxX = max(0, bounds.width - clipSize.width)
        let maxY = max(0, bounds.height - clipSize.height)
        return NSPoint(
            x: origin.x.clampedTo(min: 0, max: maxX),
            y: origin.y.clampedTo(min: 0, max: maxY)
        )
    }

    private func updateRenderingForVisibleRect() {
        guard !spreadViews.isEmpty else { return }
        guard let clipBounds = enclosingScrollView?.contentView.bounds else {
            spreadViews.forEach { $0.view.setRenderingEnabled(true) }
            return
        }
        let prefetchRect = clipBounds.insetBy(dx: -clipBounds.width * 0.5,
                                              dy: -clipBounds.height * 1.5)
        for entry in spreadViews {
            entry.view.setRenderingEnabled(entry.view.frame.intersects(prefetchRect))
        }
    }
}

private extension CGFloat {
    func clampedTo(min lo: CGFloat, max hi: CGFloat) -> CGFloat {
        Swift.max(lo, Swift.min(hi, self))
    }
}
