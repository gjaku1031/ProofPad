import Cocoa

// 지우개 끝의 위치/이동 경로에 대해 어떤 stroke가 hit되는지 판정한다.
// 1차 필터: stroke의 bbox와 지우개 원이 겹치는지.
// 2차 필터: stroke의 인접 점쌍이 만드는 선분에 원이 닿는지.
enum EraserHitTester {

    /// 페이지 안에서 지우개 원에 닿는 stroke id들을 반환.
    static func hits(in page: PageStrokes,
                     center: CGPoint,
                     radius: CGFloat) -> [UUID] {
        let probe = CGRect(
            x: center.x - radius,
            y: center.y - radius,
            width: radius * 2,
            height: radius * 2
        )
        var ids: [UUID] = []
        for stroke in page.strokes {
            // bbox는 stroke의 두께 절반 padding 포함되어 있음. 지우개 반경만큼 더 padding.
            let inflated = stroke.bbox.insetBy(dx: -radius, dy: -radius)
            guard !stroke.bbox.isNull, inflated.intersects(probe) else { continue }
            if intersectsAnySegment(of: stroke, center: center, radius: radius) {
                ids.append(stroke.id)
            }
        }
        return ids
    }

    private static func intersectsAnySegment(of stroke: Stroke,
                                             center c: CGPoint,
                                             radius r: CGFloat) -> Bool {
        guard !stroke.points.isEmpty else { return false }
        let effectiveRadius = r + stroke.width / 2
        if stroke.points.count == 1 {
            let p = stroke.points[0]
            let dx = c.x - CGFloat(p.x), dy = c.y - CGFloat(p.y)
            return (dx * dx + dy * dy).squareRoot() <= effectiveRadius
        }
        for i in 0..<(stroke.points.count - 1) {
            let p0 = stroke.points[i]
            let p1 = stroke.points[i + 1]
            let a = CGPoint(x: CGFloat(p0.x), y: CGFloat(p0.y))
            let b = CGPoint(x: CGFloat(p1.x), y: CGFloat(p1.y))
            if Geometry.circleIntersectsSegment(center: c, radius: effectiveRadius, from: a, to: b) {
                return true
            }
        }
        return false
    }
}
