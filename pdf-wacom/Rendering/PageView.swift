import Cocoa
import PDFKit

// MARK: - PageView
//
// PDF 페이지 1장 단위의 컨테이너 NSView. 배경(PDF raster) 위에 펜 캔버스 오버레이.
//
// 자식:
//   PDFPageBackgroundView   — PDF를 백그라운드 큐에서 raster, 결과를 layer.contents에 set
//   StrokeCanvasView        — 펜 입력 + 렌더 (Metal live + CAShapeLayer baked)
//
// 시각:
//   layer.shadowOpacity / shadowRadius로 페이지 외곽 그림자.
//   ⚠️ shadowPath 필수 — 안 주면 매 프레임 alpha mask로부터 그림자 동적 계산해서
//      펜 입력 lag의 주된 원인이 된다. layout()에서 bounds rect로 설정.
//
// 좌표:
//   isFlipped = true — 부모(SpreadView)와 자연스럽게 정렬되도록.
//   자식 StrokeCanvasView는 isFlipped = false (의도적). NSView가 자동으로 좌표 변환 처리.
final class PageView: NSView {
    let page: PDFPage
    let pageIndex: Int
    let pageStrokes: PageStrokes
    private let backgroundView: PDFPageBackgroundView
    private let canvasView: StrokeCanvasView

    override var isFlipped: Bool { true }

    init(page: PDFPage,
         pageIndex: Int,
         pageStrokes: PageStrokes,
         toolController: ToolController,
         onChange: (() -> Void)? = nil) {
        self.page = page
        self.pageIndex = pageIndex
        self.pageStrokes = pageStrokes
        self.backgroundView = PDFPageBackgroundView(page: page)
        self.canvasView = StrokeCanvasView(
            pageBounds: page.bounds(for: .mediaBox),
            pageStrokes: pageStrokes,
            toolController: toolController
        )
        super.init(frame: .zero)
        wantsLayer = true
        // PDF를 별도 sibling CALayer로 표시하지 않고 StrokeCanvasView의 Metal layer가 PDF + stroke를
        // 같은 pass로 그린다 → WindowServer 합성기 PDF↔Metal alpha 합성 제거 (cursor lag 원인).
        // backgroundView는 raster 트리거만 받기 위해 view tree에 두되 isHidden=true로 합성 우회.
        backgroundView.isHidden = true
        backgroundView.onImage = { [weak canvasView = canvasView] image in
            canvasView?.setPDFImage(image)
        }
        addSubview(backgroundView)
        addSubview(canvasView)
        canvasView.onChange = onChange
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layout() {
        super.layout()
        backgroundView.frame = bounds
        canvasView.frame = bounds
    }
}
