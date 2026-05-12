import Cocoa
import PDFKit

// MARK: - PageView
//
// PDF 페이지 1장 단위의 컨테이너 NSView. PDF + stroke를 그리는 자식 StrokeCanvasView를 호스팅.
//
// 자식:
//   PDFPageBackgroundView   — PDF raster trigger 전용 (isHidden=true).
//                             결과 CGImage를 콜백으로 StrokeCanvasView에 넘김.
//   StrokeCanvasView        — opaque Metal layer (PDF + stroke 단일 pass)
//
// 시각:
//   layer.shadow* — 페이지 외곽 subtle drop shadow. 종이가 회색 배경에서 "떠있다"는 인상.
//   ⚠️ shadowPath 필수 — 안 주면 매 프레임 alpha mask로부터 그림자 동적 계산.
//      layout()에서 bounds rect로 설정해 perf 비용 0에 가깝게.
//   metalLiveLayer가 opaque로 PageView bounds 전체를 덮으므로 그림자는 EDGE에만 보임.
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

        // 페이지 외곽 그림자 — 회색 배경에서 종이가 살짝 떠 보이는 시각 효과.
        // shadowPath는 layout()에서 갱신 — 매 frame compositor 비용 회피.
        layer?.shadowOpacity = 0.18
        layer?.shadowRadius = 10
        layer?.shadowOffset = NSSize(width: 0, height: -3)
        layer?.shadowColor = NSColor.black.cgColor

        addSubview(backgroundView)
        addSubview(canvasView)
        canvasView.onChange = onChange
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func setRenderingEnabled(_ enabled: Bool) {
        backgroundView.isRasteringEnabled = enabled
        canvasView.isRenderingEnabled = enabled
    }

    override func layout() {
        super.layout()
        backgroundView.frame = bounds
        canvasView.frame = bounds
        // bounds 기반 shadow 정적 path — perf 핵심. 매 frame alpha-mask shadow 계산 회피.
        layer?.shadowPath = CGPath(rect: bounds, transform: nil)
    }
}
