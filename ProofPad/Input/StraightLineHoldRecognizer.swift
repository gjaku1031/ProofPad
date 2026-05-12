import CoreGraphics
import Foundation

// MARK: - StraightLineHoldRecognizer
//
// Notability류 line hold: 충분히 곧은 획을 긋고 끝점에서 잠깐 멈추면 stroke를 직선으로 snap한다.
// snap 이후에는 펜을 떼기 전까지 시작점은 고정하고 끝점만 현재 펜 위치를 따라간다.
struct StraightLineHoldRecognizer {
    private(set) var isSnapped = false

    private var samples: [StrokePoint] = []
    private var stationaryAnchor: StrokePoint?
    private var stationaryStartTime: Float = 0

    private let minimumLength: CGFloat = 28
    private let holdDurationMS: Float = 420
    private let stationaryRadius: CGFloat = 2.2

    mutating func begin(_ point: StrokePoint) {
        samples = [point]
        stationaryAnchor = point
        stationaryStartTime = point.t
        isSnapped = false
    }

    mutating func append(_ point: StrokePoint) -> [StrokePoint]? {
        guard let first = samples.first else {
            begin(point)
            return nil
        }
        samples.append(point)

        if isSnapped {
            return linePoints(from: first, to: point)
        }

        updateStationaryState(with: point)
        return snapAfterHoldIfReady(now: point.t)
    }

    mutating func finish(_ point: StrokePoint) -> [StrokePoint]? {
        guard let first = samples.first, isSnapped else { return nil }
        samples.append(point)
        return linePoints(from: first, to: point)
    }

    func holdCheckDelayMS(now: Float) -> Float? {
        guard !isSnapped,
              let first = samples.first,
              let current = samples.last,
              isEligibleLine(from: first, to: current) else { return nil }
        return max(holdDurationMS - (now - stationaryStartTime), 0)
    }

    mutating func snapAfterHoldIfReady(now: Float) -> [StrokePoint]? {
        guard let first = samples.first,
              let current = samples.last,
              isEligibleLine(from: first, to: current),
              now - stationaryStartTime >= holdDurationMS else { return nil }
        isSnapped = true
        return linePoints(from: first, to: current)
    }

    private mutating func updateStationaryState(with point: StrokePoint) {
        guard let anchor = stationaryAnchor else {
            stationaryAnchor = point
            stationaryStartTime = point.t
            return
        }
        if distance(anchor, point) > stationaryRadius {
            stationaryAnchor = point
            stationaryStartTime = point.t
        }
    }

    private func isEligibleLine(from first: StrokePoint, to current: StrokePoint) -> Bool {
        let length = distance(first, current)
        guard length >= minimumLength, samples.count >= 4 else { return false }

        let tolerance = max(1.8, min(length * 0.04, 6.0))
        for sample in samples {
            if perpendicularDistance(sample, from: first, to: current) > tolerance {
                return false
            }
        }
        return true
    }

    private func linePoints(from first: StrokePoint, to current: StrokePoint) -> [StrokePoint] {
        [
            StrokePoint(x: first.x, y: first.y, t: first.t, pressure: first.pressure),
            StrokePoint(x: current.x, y: current.y, t: current.t, pressure: current.pressure)
        ]
    }

    private func perpendicularDistance(_ p: StrokePoint, from a: StrokePoint, to b: StrokePoint) -> CGFloat {
        let ax = CGFloat(a.x)
        let ay = CGFloat(a.y)
        let bx = CGFloat(b.x)
        let by = CGFloat(b.y)
        let px = CGFloat(p.x)
        let py = CGFloat(p.y)
        let dx = bx - ax
        let dy = by - ay
        let denom = hypot(dx, dy)
        guard denom > 0.001 else { return hypot(px - ax, py - ay) }
        return abs(dy * px - dx * py + bx * ay - by * ax) / denom
    }

    private func distance(_ a: StrokePoint, _ b: StrokePoint) -> CGFloat {
        hypot(CGFloat(a.x - b.x), CGFloat(a.y - b.y))
    }
}
