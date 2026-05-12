import CoreGraphics

enum Geometry {

    /// 점 p와 선분 (a, b) 사이의 최소 거리.
    static func distance(from p: CGPoint, toSegmentFrom a: CGPoint, to b: CGPoint) -> CGFloat {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let lenSq = dx * dx + dy * dy
        if lenSq == 0 {
            let ex = p.x - a.x, ey = p.y - a.y
            return (ex * ex + ey * ey).squareRoot()
        }
        let t = ((p.x - a.x) * dx + (p.y - a.y) * dy) / lenSq
        let clampedT = max(0, min(1, t))
        let cx = a.x + clampedT * dx
        let cy = a.y + clampedT * dy
        let ex = p.x - cx, ey = p.y - cy
        return (ex * ex + ey * ey).squareRoot()
    }

    /// 원(중심 c, 반지름 r)이 선분 (a, b)와 교차하는가.
    static func circleIntersectsSegment(center c: CGPoint, radius r: CGFloat,
                                        from a: CGPoint, to b: CGPoint) -> Bool {
        return distance(from: c, toSegmentFrom: a, to: b) <= r
    }
}
