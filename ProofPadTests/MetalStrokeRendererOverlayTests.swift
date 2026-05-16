import Cocoa
import XCTest
@testable import ProofPad

final class MetalStrokeRendererOverlayTests: XCTestCase {

    func testLivePredictionCanBeDisabledForSnappedStraightLine() throws {
        let renderer = try XCTUnwrap(MetalStrokeRenderer())
        renderer.beginLiveStroke(color: .black, scale: 2)
        renderer.appendLiveSample(.init(position: SIMD2<Float>(20, 20), halfWidth: 2))
        renderer.appendLiveSample(.init(position: SIMD2<Float>(120, 20), halfWidth: 2))

        XCTAssertGreaterThan(renderer.predictedTailVertexCountForTesting(), 0)

        renderer.setLivePredictionEnabled(false)

        XCTAssertEqual(renderer.predictedTailVertexCountForTesting(), 0)
    }

    func testReplacingSnappedCanvasStrokeKeepsPredictionDisabledForPreview() throws {
        let canvas = StrokeCanvasView(pageBounds: CGRect(x: 0, y: 0, width: 200, height: 200),
                                      pageStrokes: PageStrokes(pageIndex: 0),
                                      toolController: ToolController())
        canvas.frame = CGRect(x: 0, y: 0, width: 200, height: 200)

        let stroke = Stroke(color: .black, width: 4)
        stroke.replacePoints([
            StrokePoint(x: 20, y: 20, t: 0, pressure: 0.5),
            StrokePoint(x: 120, y: 20, t: 100, pressure: 0.5),
        ])

        canvas.beginInProgressStroke(stroke)
        XCTAssertGreaterThan(canvas.livePredictedTailVertexCountForTesting(), 0)

        canvas.setLivePredictionEnabled(false)
        canvas.replaceInProgressStroke(stroke)

        XCTAssertEqual(canvas.livePredictedTailVertexCountForTesting(), 0)
    }

    func testEraserIndicatorProducesAndClearsRingGeometry() throws {
        let renderer = try XCTUnwrap(MetalStrokeRenderer())

        renderer.setEraserIndicator(center: SIMD2<Float>(50, 50), radius: 24)

        XCTAssertGreaterThan(renderer.eraserIndicatorVertexCountForTesting(), 0)

        renderer.clearEraserIndicator()

        XCTAssertEqual(renderer.eraserIndicatorVertexCountForTesting(), 0)
    }
}
