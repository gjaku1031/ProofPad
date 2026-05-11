import Cocoa
import PDFKit

// 페이지를 비트맵으로 한 번만 raster해 결과를 콜백으로 전달한다.
// raster는 background queue에서 수행 — UI 차단 없음. 완료 시 main에서 콜백 (CGImage).
// 사이즈 변경이 임계 이상이거나 backing scale이 바뀌면 다시 raster.
//
// === 합성기 우회 (low-latency drawing 핵심) ===
// 이전엔 이 view가 직접 layer.contents = cgImage로 PDF를 화면에 표시하고,
// 그 위에 sibling CAMetalLayer (StrokeCanvasView)가 alpha 합성되었다.
// WindowServer 합성기가 매 vsync마다 두 layer를 blend → cursor/펜 backpressure.
//
// 새 구조: 이 view는 raster만 담당하고 결과 CGImage를 콜백으로 StrokeCanvasView에 넘긴다.
// StrokeCanvasView가 MetalStrokeRenderer로 PDF + stroke를 같은 Metal pass에서 그린다.
// 이 view 자체는 isHidden=true (PageView에서 set)로 합성기 비용 0.
final class PDFPageBackgroundView: NSView {

    let page: PDFPage
    /// raster 완료 시 main에서 호출됨. StrokeCanvasView가 받아서 renderer에 업로드.
    var onImage: ((CGImage) -> Void)?
    private var cachedRasterPixelSize: CGSize = .zero
    private var cachedScale: CGFloat = 0
    private var inflightToken: UInt64 = 0
    private static var tokenCounter: UInt64 = 0

    override var isFlipped: Bool { false }

    init(page: PDFPage) {
        self.page = page
        super.init(frame: .zero)
        // wantsLayer는 NSView 사이즈 통지를 받기 위해 유지. layer.contents는 절대 안 set.
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layout() {
        super.layout()
        scheduleRasterIfNeeded()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        scheduleRasterIfNeeded(force: true)
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        scheduleRasterIfNeeded(force: true)
    }

    private func scheduleRasterIfNeeded(force: Bool = false) {
        let scale = window?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor
            ?? 2.0
        let pixelWidth = Int((bounds.width * scale).rounded())
        let pixelHeight = Int((bounds.height * scale).rounded())
        guard pixelWidth > 0, pixelHeight > 0 else { return }

        if !force {
            let widthDiff = abs(CGFloat(pixelWidth) - cachedRasterPixelSize.width)
            let heightDiff = abs(CGFloat(pixelHeight) - cachedRasterPixelSize.height)
            let threshold = max(cachedRasterPixelSize.width, 4) * 0.05
            if widthDiff < threshold, heightDiff < threshold, scale == cachedScale { return }
            if inLiveResize { return }
        }

        // background raster. 진행 중 호출이 새로 발생하면 token으로 stale 결과 무시.
        Self.tokenCounter &+= 1
        let token = Self.tokenCounter
        inflightToken = token
        let pageRef = page

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let image = Self.rasterize(page: pageRef,
                                             pixelWidth: pixelWidth,
                                             pixelHeight: pixelHeight) else { return }
            DispatchQueue.main.async {
                guard let self = self else { return }
                guard self.inflightToken == token else { return }   // stale 무시
                self.cachedRasterPixelSize = CGSize(width: pixelWidth, height: pixelHeight)
                self.cachedScale = scale
                self.onImage?(image)
            }
        }
    }

    private static func rasterize(page: PDFPage, pixelWidth: Int, pixelHeight: Int) -> CGImage? {
        let pageBounds = page.bounds(for: .mediaBox)
        guard pageBounds.width > 0, pageBounds.height > 0 else { return nil }

        let cs = CGColorSpaceCreateDeviceRGB()
        let bytesPerRow = pixelWidth * 4
        guard let ctx = CGContext(
            data: nil,
            width: pixelWidth,
            height: pixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }

        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        let sx = CGFloat(pixelWidth) / pageBounds.width
        let sy = CGFloat(pixelHeight) / pageBounds.height
        ctx.scaleBy(x: sx, y: sy)
        page.draw(with: .mediaBox, to: ctx)
        return ctx.makeImage()
    }
}
