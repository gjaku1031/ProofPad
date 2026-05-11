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

    func testTrailingDataRejected() {
        var data = StrokeCodec.encode(PageStrokes(pageIndex: 0))
        data.append(0xff)
        XCTAssertThrowsError(try StrokeCodec.decode(data))
    }

    func testInvalidWidthRejected() {
        let page = PageStrokes(pageIndex: 0)
        page.add(Stroke(color: .systemRed, width: .nan))

        XCTAssertThrowsError(try StrokeCodec.decode(StrokeCodec.encode(page)))
    }

    func testDecodeDoesNotPostChangeNotifications() throws {
        let page = PageStrokes(pageIndex: 0)
        let stroke = Stroke(color: .systemRed, width: 2)
        stroke.append(StrokePoint(x: 1, y: 2, t: 3))
        page.add(stroke)
        let data = StrokeCodec.encode(page)

        var notificationCount = 0
        let observer = NotificationCenter.default.addObserver(
            forName: PageStrokes.didChangeNotification,
            object: nil,
            queue: nil
        ) { _ in
            notificationCount += 1
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        _ = try StrokeCodec.decode(data)

        XCTAssertEqual(notificationCount, 0)
    }
}
