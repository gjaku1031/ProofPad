import Cocoa
import PDFKit

// MARK: - Spread (model)
//
// 한 펼침면의 페이지 페어. leftPage/rightPage 중 하나가 nil이면 그 자리가 비어있다는 뜻.
//   - coverIsSinglePage=true: 첫 spread는 (nil, page0)으로 표지를 우측 단독에 둠 → 책 표지 효과.
//   - pagesPerSpread=1: 모든 spread는 (page_i, nil) — 한 페이지씩 단독 표시.
struct Spread {
    let leftPage: PDFPage?
    let rightPage: PDFPage?

    /// PDFDocument를 페이지 배치 정책에 따라 spread 배열로 변환.
    /// - pagesPerSpread: 1 또는 2. 1이면 leftPage 자리에 페이지를 두는 방식.
    /// - coverIsSinglePage: pagesPerSpread=2일 때만 의미. 첫 페이지를 우측 단독으로.
    static func pair(_ document: PDFDocument,
                     coverIsSinglePage: Bool,
                     pagesPerSpread: Int = 2) -> [Spread] {
        var result: [Spread] = []
        let count = document.pageCount
        guard count > 0 else { return result }

        if pagesPerSpread <= 1 {
            // 한 페이지씩 단독 — 좌측 자리에 페이지를 둔다.
            for i in 0..<count {
                result.append(Spread(leftPage: document.page(at: i), rightPage: nil))
            }
            return result
        }

        var i = 0
        if coverIsSinglePage {
            result.append(Spread(leftPage: nil, rightPage: document.page(at: 0)))
            i = 1
        }
        while i < count {
            let left = document.page(at: i)
            let right = i + 1 < count ? document.page(at: i + 1) : nil
            result.append(Spread(leftPage: left, rightPage: right))
            i += 2
        }
        return result
    }
}

// MARK: - SpreadView
//
// 한 펼침면을 시각적으로 그리는 NSView. SpreadStripView가 위에서 아래로 쌓는 단위.
//
// isFlipped = true (y-down) — 펼침면 내부에서 좌·우 자리 배치를 자연스럽게 하기 위함.
//                              (자식 StrokeCanvasView는 별도로 y-up. 좌표 변환은 NSView가 자동 처리.)
//
// 자식 페이지 자리 두 개를 보유 (왼쪽/오른쪽). pagesAcross=1이면 좌측 자리에 페이지를 두고
// 그 페이지가 view 전체 폭을 차지 — 단일 페이지 모드.
final class SpreadView: NSView {
    let leftPageView: PageView?
    let rightPageView: PageView?
    var pageGap: CGFloat = 8 {
        didSet { needsLayout = true }
    }
    /// 1이면 한 페이지가 전체 너비를 차지. 2면 좌우로 절반씩.
    var pagesAcross: Int = 2 {
        didSet { needsLayout = true }
    }

    override var isFlipped: Bool { true }

    init(spread: Spread,
         document: PDFInkDocument,
         toolController: ToolController,
         onChange: @escaping () -> Void) {
        self.leftPageView = spread.leftPage.map { page in
            let idx = page.document?.index(for: page) ?? 0
            return PageView(
                page: page,
                pageIndex: idx,
                pageStrokes: document.strokes(forPage: idx),
                toolController: toolController,
                onChange: onChange
            )
        }
        self.rightPageView = spread.rightPage.map { page in
            let idx = page.document?.index(for: page) ?? 0
            return PageView(
                page: page,
                pageIndex: idx,
                pageStrokes: document.strokes(forPage: idx),
                toolController: toolController,
                onChange: onChange
            )
        }
        super.init(frame: .zero)
        if let l = leftPageView { addSubview(l) }
        if let r = rightPageView { addSubview(r) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func setRenderingEnabled(_ enabled: Bool) {
        leftPageView?.setRenderingEnabled(enabled)
        rightPageView?.setRenderingEnabled(enabled)
    }

    func primaryPageIndex(near point: CGPoint) -> Int? {
        let pageViews = [leftPageView, rightPageView].compactMap { $0 }
        guard !pageViews.isEmpty else { return nil }
        if let hit = pageViews.first(where: { $0.frame.contains(point) }) {
            return hit.pageIndex
        }
        return pageViews.min { a, b in
            abs(a.frame.midX - point.x) < abs(b.frame.midX - point.x)
        }?.pageIndex
    }

    override func layout() {
        super.layout()
        if pagesAcross <= 1 {
            // 단일 페이지 모드: 한 페이지가 전체 너비를 사용.
            let single = leftPageView ?? rightPageView
            single?.frame = NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height)
            return
        }
        let halfWidth = max(0, (bounds.width - pageGap) / 2)
        leftPageView?.frame = NSRect(x: 0, y: 0, width: halfWidth, height: bounds.height)
        rightPageView?.frame = NSRect(
            x: halfWidth + pageGap,
            y: 0,
            width: halfWidth,
            height: bounds.height
        )
    }
}
