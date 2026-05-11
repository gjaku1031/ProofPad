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
//   2: 좌우 두 페이지가 펼침면으로 (책 모드). 표지 단독 옵션은 manifest.coverIsSinglePage.
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

    var spreadGap: CGFloat = 24 { didSet { needsLayout = true } }
    var pageGap: CGFloat = 8 { didSet { needsLayout = true } }
    var horizontalMargin: CGFloat = 16 { didSet { needsLayout = true } }
    var topMargin: CGFloat = 16 { didSet { needsLayout = true } }
    var bottomMargin: CGFloat = 16 { didSet { needsLayout = true } }

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

    private func applyAutoresizingForZoomMode() {
        autoresizingMask = isFitWidth ? [.width] : []
    }

    func setSpreads(_ list: [Spread],
                    document: NoteDocument,
                    toolController: ToolController,
                    onChange: @escaping () -> Void) {
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

    private func containsPage(_ spread: Spread, pageIndex: Int) -> Bool {
        if let l = spread.leftPage, l.document?.index(for: l) == pageIndex { return true }
        if let r = spread.rightPage, r.document?.index(for: r) == pageIndex { return true }
        return false
    }

    // MARK: - Layout

    override func layout() {
        super.layout()
        guard let referenceSpread = spreadViews.first?.spread else { return }
        let referencePage = referenceSpread.leftPage ?? referenceSpread.rightPage
        let pagePtSize = referencePage?.bounds(for: .mediaBox).size
            ?? NSSize(width: 612, height: 792)
        let pageAspect = pagePtSize.height / max(pagePtSize.width, 1)

        let clipSize = enclosingScrollView?.contentView.bounds.size ?? bounds.size

        // perPageWidth = 한 페이지 view 너비 (포인트). 단일/펼침에서 동일한 의미.
        let isSingle = pagesPerSpread <= 1
        let perPageWidth: CGFloat
        switch zoomMode {
        case .fitWidth:
            let availWidth = max(0, clipSize.width - horizontalMargin * 2)
            perPageWidth = isSingle ? availWidth : max(0, (availWidth - pageGap) / 2)
        case .fitHeight:
            let availHeight = max(0, clipSize.height - topMargin - bottomMargin)
            perPageWidth = availHeight / max(pageAspect, 0.001)
        case .fitPage:
            let availWidth = max(0, clipSize.width - horizontalMargin * 2)
            let fwPer = isSingle ? availWidth : max(0, (availWidth - pageGap) / 2)
            let availHeight = max(0, clipSize.height - topMargin - bottomMargin)
            let fhPer = availHeight / max(pageAspect, 0.001)
            perPageWidth = min(fwPer, fhPer)
        case .custom(let scale):
            perPageWidth = pagePtSize.width * scale
        }

        let pageHeight = perPageWidth * pageAspect
        let spreadWidth = isSingle ? perPageWidth : (perPageWidth * 2 + pageGap)
        let totalContentWidth = spreadWidth + horizontalMargin * 2

        // documentView의 width는 max(clip, content)로 두어 가운데 정렬 가능.
        let docWidth = max(clipSize.width, totalContentWidth)
        let xOffset = (docWidth - spreadWidth) / 2

        var y: CGFloat = topMargin
        for (_, view) in spreadViews {
            view.pageGap = pageGap
            view.frame = NSRect(x: xOffset, y: y, width: spreadWidth, height: pageHeight)
            y += pageHeight + spreadGap
        }
        let totalHeight = max(y - spreadGap + bottomMargin, 0)

        if abs(frame.width - docWidth) > 0.5 || abs(frame.height - totalHeight) > 0.5 {
            setFrameSize(NSSize(width: docWidth, height: totalHeight))
        }
    }

    // MARK: - Pinch zoom

    override func magnify(with event: NSEvent) {
        // event.magnification: -1...+1 정도. 누적해서 custom scale 변경.
        let currentScale = currentEffectiveScale()
        let newScale = (currentScale * (1 + event.magnification))
            .clampedTo(min: 0.25, max: 8.0)
        zoomMode = .custom(newScale)
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
        zoomMode = .custom(s)
    }
}

private extension CGFloat {
    func clampedTo(min lo: CGFloat, max hi: CGFloat) -> CGFloat {
        Swift.max(lo, Swift.min(hi, self))
    }
}
