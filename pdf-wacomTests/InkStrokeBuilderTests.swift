import XCTest
@testable import pdf_wacom

final class InkStrokeBuilderTests: XCTestCase {

    func testBuilderSmoothsSlowCoordinateJitter() {
        var builder = InkStrokeBuilder(baseWidth: 2)
        _ = builder.begin(at: CGPoint(x: 0, y: 0), time: 0, pressure: 0.5)

        let points = builder.append(to: CGPoint(x: 2, y: 10), time: 100, pressure: 0.5)

        XCTAssertFalse(points.isEmpty)
        XCTAssertLessThan(CGFloat(points.last!.y), 5)
    }

    func testBuilderSmoothsPressureChanges() {
        var builder = InkStrokeBuilder(baseWidth: 2)
        _ = builder.begin(at: CGPoint(x: 0, y: 0), time: 0, pressure: 0.1)

        let points = builder.append(to: CGPoint(x: 8, y: 0), time: 20, pressure: 1.0)

        XCTAssertFalse(points.isEmpty)
        XCTAssertLessThan(points.last!.pressure, 1.0)
        XCTAssertGreaterThan(points.last!.pressure, 0.1)
    }

    func testBuilderFillsLongEventGaps() {
        var builder = InkStrokeBuilder(baseWidth: 2)
        _ = builder.begin(at: CGPoint(x: 0, y: 0), time: 0, pressure: 0.5)

        let points = builder.append(to: CGPoint(x: 30, y: 0), time: 16, pressure: 0.5)

        XCTAssertGreaterThan(points.count, 1)
        for pair in zip(points, points.dropFirst()) {
            let dx = CGFloat(pair.0.x - pair.1.x)
            let dy = CGFloat(pair.0.y - pair.1.y)
            XCTAssertLessThanOrEqual(hypot(dx, dy), 4.1)
        }
    }
}

final class InkStrokeDynamicsTests: XCTestCase {

    func testPressureIncreasesRenderedWidth() {
        let light = StrokePoint(x: 0, y: 0, t: 0, pressure: 0.15)
        let heavy = StrokePoint(x: 1, y: 0, t: 16, pressure: 1.0)

        let lightWidth = InkStrokeDynamics.halfWidth(baseWidth: 2,
                                                     viewScale: 1,
                                                     point: light,
                                                     previous: nil)
        let heavyWidth = InkStrokeDynamics.halfWidth(baseWidth: 2,
                                                     viewScale: 1,
                                                     point: heavy,
                                                     previous: light)

        XCTAssertGreaterThan(heavyWidth, lightWidth)
    }

    func testFastStrokesRenderThinnerThanSlowStrokes() {
        let previous = StrokePoint(x: 0, y: 0, t: 0, pressure: 0.7)
        let slow = StrokePoint(x: 2, y: 0, t: 100, pressure: 0.7)
        let fast = StrokePoint(x: 40, y: 0, t: 16, pressure: 0.7)

        let slowWidth = InkStrokeDynamics.halfWidth(baseWidth: 3,
                                                    viewScale: 1,
                                                    point: slow,
                                                    previous: previous)
        let fastWidth = InkStrokeDynamics.halfWidth(baseWidth: 3,
                                                    viewScale: 1,
                                                    point: fast,
                                                    previous: previous)

        XCTAssertLessThan(fastWidth, slowWidth)
    }

    func testZoomScaleAffectsRenderedWidth() {
        let point = StrokePoint(x: 0, y: 0, t: 0, pressure: 0.7)

        let normal = InkStrokeDynamics.halfWidth(baseWidth: 2,
                                                 viewScale: 1,
                                                 point: point,
                                                 previous: nil)
        let zoomed = InkStrokeDynamics.halfWidth(baseWidth: 2,
                                                 viewScale: 2,
                                                 point: point,
                                                 previous: nil)

        XCTAssertEqual(zoomed, normal * 2, accuracy: 0.01)
    }
}

final class StrokePointCodableTests: XCTestCase {

    func testDecodingOldStrokePointPayloadUsesDefaultPressure() throws {
        let data = #"{"x":10,"y":20,"t":30}"#.data(using: .utf8)!

        let point = try JSONDecoder().decode(StrokePoint.self, from: data)

        XCTAssertEqual(point.pressure, StrokePoint.defaultPressure)
    }

    func testDecodingClampsInvalidPressure() throws {
        let data = #"{"x":10,"y":20,"t":30,"pressure":4}"#.data(using: .utf8)!

        let point = try JSONDecoder().decode(StrokePoint.self, from: data)

        XCTAssertEqual(point.pressure, 1)
    }
}
