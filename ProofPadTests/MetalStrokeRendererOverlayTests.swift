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

    func testEraserIndicatorProducesAndClearsRingGeometry() throws {
        let renderer = try XCTUnwrap(MetalStrokeRenderer())

        renderer.setEraserIndicator(center: SIMD2<Float>(50, 50), radius: 24)

        XCTAssertGreaterThan(renderer.eraserIndicatorVertexCountForTesting(), 0)

        renderer.clearEraserIndicator()

        XCTAssertEqual(renderer.eraserIndicatorVertexCountForTesting(), 0)
    }
}
