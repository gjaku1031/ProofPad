import XCTest
@testable import pdf_wacom

final class EraserHitTestTests: XCTestCase {

    private func makePage(_ stroke: Stroke) -> PageStrokes {
        let page = PageStrokes(pageIndex: 0)
        page.add(stroke)
        return page
    }

    private func makeStroke(points: [(Float, Float)], width: CGFloat = 2) -> Stroke {
        let s = Stroke(color: .systemRed, width: width)
        for (x, y) in points {
            s.append(StrokePoint(x: x, y: y, t: 0))
        }
        return s
    }

    func testHitsExactlyOnLine() {
        let s = makeStroke(points: [(100, 100), (200, 100)])
        let page = makePage(s)
        let hits = EraserHitTester.hits(in: page, center: CGPoint(x: 150, y: 100), radius: 5)
        XCTAssertEqual(hits, [s.id])
    }

    func testMissOutsideRadius() {
        let s = makeStroke(points: [(100, 100), (200, 100)])
        let page = makePage(s)
        let hits = EraserHitTester.hits(in: page, center: CGPoint(x: 150, y: 200), radius: 5)
        XCTAssertEqual(hits, [])
    }

    func testEdgeOfRadius() {
        let s = makeStroke(points: [(100, 100), (200, 100)])
        let page = makePage(s)
        // 거리 정확히 10, 반경 11 → 히트
        let hit = EraserHitTester.hits(in: page, center: CGPoint(x: 150, y: 110), radius: 11)
        XCTAssertEqual(hit, [s.id])
        // 거리 정확히 10, 반경 8 → 미스 (stroke width / 2 = 1 추가됐어도 9 < 10)
        let miss = EraserHitTester.hits(in: page, center: CGPoint(x: 150, y: 110), radius: 8)
        XCTAssertEqual(miss, [])
    }

    func testNearEndpoint() {
        let s = makeStroke(points: [(100, 100), (200, 100)])
        let page = makePage(s)
        // 시작점 근처
        let hit1 = EraserHitTester.hits(in: page, center: CGPoint(x: 95, y: 100), radius: 6)
        XCTAssertEqual(hit1, [s.id])
        // 끝점 근처
        let hit2 = EraserHitTester.hits(in: page, center: CGPoint(x: 205, y: 100), radius: 6)
        XCTAssertEqual(hit2, [s.id])
        // 시작점에서 너무 멀리
        let miss = EraserHitTester.hits(in: page, center: CGPoint(x: 50, y: 100), radius: 5)
        XCTAssertEqual(miss, [])
    }

    func testSinglePointStroke() {
        let s = makeStroke(points: [(100, 100)])
        let page = makePage(s)
        let hit = EraserHitTester.hits(in: page, center: CGPoint(x: 102, y: 100), radius: 5)
        XCTAssertEqual(hit, [s.id])
        let miss = EraserHitTester.hits(in: page, center: CGPoint(x: 200, y: 100), radius: 5)
        XCTAssertEqual(miss, [])
    }

    func testMultipleStrokesOnlyHitOverlapping() {
        let s1 = makeStroke(points: [(0, 0), (50, 0)])
        let s2 = makeStroke(points: [(100, 100), (150, 100)])
        let s3 = makeStroke(points: [(200, 200), (250, 200)])
        let page = PageStrokes(pageIndex: 0)
        page.add(s1); page.add(s2); page.add(s3)
        let hits = EraserHitTester.hits(in: page, center: CGPoint(x: 125, y: 100), radius: 5)
        XCTAssertEqual(hits, [s2.id])
    }

    func testThickerStrokeWidens() {
        // stroke width 20이면 반쪽 두께 10. eraser radius 1로도 거리 10까지는 히트.
        let s = makeStroke(points: [(100, 100), (200, 100)], width: 20)
        let page = makePage(s)
        let hit = EraserHitTester.hits(in: page, center: CGPoint(x: 150, y: 109), radius: 1)
        XCTAssertEqual(hit, [s.id])
    }
}
