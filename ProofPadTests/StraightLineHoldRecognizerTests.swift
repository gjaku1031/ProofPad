import XCTest
@testable import ProofPad

final class StraightLineHoldRecognizerTests: XCTestCase {

    func testStraightStrokeSnapsAfterEndpointHold() {
        var recognizer = StraightLineHoldRecognizer()
        recognizer.begin(StrokePoint(x: 0, y: 0, t: 0, pressure: 0.5))

        XCTAssertNil(recognizer.append(StrokePoint(x: 20, y: 0.4, t: 40, pressure: 0.5)))
        XCTAssertNil(recognizer.append(StrokePoint(x: 50, y: -0.5, t: 90, pressure: 0.5)))
        XCTAssertNil(recognizer.append(StrokePoint(x: 80, y: 0.2, t: 140, pressure: 0.5)))
        XCTAssertNil(recognizer.append(StrokePoint(x: 81, y: 0.3, t: 300, pressure: 0.5)))

        let snapped = recognizer.append(StrokePoint(x: 81.2, y: 0.2, t: 620, pressure: 0.5))

        XCTAssertTrue(recognizer.isSnapped)
        XCTAssertEqual(snapped?.count, 2)
        XCTAssertEqual(snapped?.first?.x, 0)
        XCTAssertEqual(snapped?.last?.x ?? 0, 81.2, accuracy: 0.001)
    }

    func testSnappedLineEndpointContinuesTracking() {
        var recognizer = StraightLineHoldRecognizer()
        recognizer.begin(StrokePoint(x: 0, y: 0, t: 0, pressure: 0.5))
        _ = recognizer.append(StrokePoint(x: 50, y: 0, t: 100, pressure: 0.5))
        _ = recognizer.append(StrokePoint(x: 80, y: 0, t: 160, pressure: 0.5))
        _ = recognizer.append(StrokePoint(x: 80.2, y: 0, t: 620, pressure: 0.5))

        let moved = recognizer.append(StrokePoint(x: 110, y: 20, t: 760, pressure: 0.5))

        XCTAssertEqual(moved?.count, 2)
        XCTAssertEqual(moved?.last?.x ?? 0, 110, accuracy: 0.001)
        XCTAssertEqual(moved?.last?.y ?? 0, 20, accuracy: 0.001)
    }

    func testHoldCanSnapWithoutAdditionalDragSample() {
        var recognizer = StraightLineHoldRecognizer()
        recognizer.begin(StrokePoint(x: 0, y: 0, t: 0, pressure: 0.5))
        _ = recognizer.append(StrokePoint(x: 30, y: 0.1, t: 40, pressure: 0.5))
        _ = recognizer.append(StrokePoint(x: 55, y: 0.0, t: 80, pressure: 0.5))
        _ = recognizer.append(StrokePoint(x: 80, y: 0.2, t: 100, pressure: 0.5))

        XCTAssertEqual(recognizer.holdCheckDelayMS(now: 100) ?? 0, 420, accuracy: 0.001)
        XCTAssertNil(recognizer.snapAfterHoldIfReady(now: 300))

        let snapped = recognizer.snapAfterHoldIfReady(now: 520)

        XCTAssertTrue(recognizer.isSnapped)
        XCTAssertEqual(snapped?.count, 2)
        XCTAssertEqual(snapped?.last?.x ?? 0, 80, accuracy: 0.001)
    }

    func testCurvedStrokeDoesNotSnap() {
        var recognizer = StraightLineHoldRecognizer()
        recognizer.begin(StrokePoint(x: 0, y: 0, t: 0, pressure: 0.5))
        _ = recognizer.append(StrokePoint(x: 20, y: 15, t: 40, pressure: 0.5))
        _ = recognizer.append(StrokePoint(x: 50, y: -18, t: 90, pressure: 0.5))
        _ = recognizer.append(StrokePoint(x: 80, y: 0, t: 140, pressure: 0.5))

        let snapped = recognizer.append(StrokePoint(x: 80, y: 0, t: 700, pressure: 0.5))

        XCTAssertNil(snapped)
        XCTAssertFalse(recognizer.isSnapped)
    }
}
