import XCTest
@testable import pdf_wacom

final class StrokeCodecTests: XCTestCase {

    func testEmptyPageRoundTrip() throws {
        let original = PageStrokes(pageIndex: 7)
        let data = StrokeCodec.encode(original)
        let decoded = try StrokeCodec.decode(data)
        XCTAssertEqual(decoded.pageIndex, 7)
        XCTAssertEqual(decoded.strokes.count, 0)
    }

    func testRandomRoundTrip() throws {
        var rng = SystemRandomNumberGenerator()
        let original = PageStrokes(pageIndex: 42)
        for _ in 0..<10 {
            let stroke = Stroke(color: .systemRed, width: CGFloat.random(in: 1...5, using: &rng))
            let n = Int.random(in: 5...200, using: &rng)
            for _ in 0..<n {
                stroke.append(StrokePoint(
                    x: Float.random(in: 0...612, using: &rng),
                    y: Float.random(in: 0...792, using: &rng),
                    t: Float.random(in: 0...10000, using: &rng)
                ))
            }
            original.add(stroke)
        }

        let data = StrokeCodec.encode(original)
        let decoded = try StrokeCodec.decode(data)

        XCTAssertEqual(decoded.pageIndex, original.pageIndex)
        XCTAssertEqual(decoded.strokes.count, original.strokes.count)
        for (o, d) in zip(original.strokes, decoded.strokes) {
            XCTAssertEqual(o.id, d.id)
            XCTAssertEqual(Float(o.width), Float(d.width), accuracy: 1e-5)
            XCTAssertEqual(o.points.count, d.points.count)
            for (op, dp) in zip(o.points, d.points) {
                XCTAssertEqual(op.x, dp.x, accuracy: 1e-5)
                XCTAssertEqual(op.y, dp.y, accuracy: 1e-5)
                XCTAssertEqual(op.t, dp.t, accuracy: 1e-5)
            }
        }
    }

    func testBadMagicRejected() {
        var data = StrokeCodec.encode(PageStrokes(pageIndex: 0))
        data[0] = 0x00
        XCTAssertThrowsError(try StrokeCodec.decode(data))
    }

    func testTruncatedRejected() {
        let data = StrokeCodec.encode(PageStrokes(pageIndex: 0))
        XCTAssertThrowsError(try StrokeCodec.decode(data.prefix(2)))
    }
}
