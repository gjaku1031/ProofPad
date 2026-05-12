import Cocoa

// MARK: - InkStrokeBuilder
//
// Wacom tablet events arrive as raw samples: sometimes unevenly spaced, sometimes pressure-only,
// and occasionally with small coordinate jitter. This builder turns those samples into the page-space
// points that become a Stroke:
//   - adaptive one-pole smoothing: slower handwriting is smoothed more, fast strokes keep direction.
//   - pressure smoothing: avoids visible width flicker from noisy tablet pressure.
//   - bounded resampling: avoids duplicate points while filling long event gaps.
struct InkStrokeBuilder {
    private let baseWidth: CGFloat
    private let feel: InkFeelSettings.Snapshot
    private var lastRawPoint: CGPoint?
    private var lastRawTime: Float = 0
    private var smoothedPoint: CGPoint?
    private var smoothedPressure: Float = StrokePoint.defaultPressure
    private var lastEmittedPoint: StrokePoint?

    init(baseWidth: CGFloat, feel: InkFeelSettings.Snapshot = .appDefault) {
        self.baseWidth = max(baseWidth, 0.5)
        self.feel = feel.sanitized
    }

    mutating func begin(at pagePoint: CGPoint, time: Float, pressure: Float) -> StrokePoint {
        let p = InkStrokeDynamics.normalizedPressure(pressure)
        lastRawPoint = pagePoint
        lastRawTime = time
        smoothedPoint = pagePoint
        smoothedPressure = p

        let point = makePoint(pagePoint, time: time, pressure: p)
        lastEmittedPoint = point
        return point
    }

    mutating func append(to rawPoint: CGPoint, time: Float, pressure: Float) -> [StrokePoint] {
        guard let previousRaw = lastRawPoint,
              let previousSmoothed = smoothedPoint else {
            return [begin(at: rawPoint, time: time, pressure: pressure)]
        }

        let dtMS = max(time - lastRawTime, 1)
        let rawDistance = distance(previousRaw, rawPoint)
        let speed = rawDistance / CGFloat(dtMS) * 1_000
        let alpha = smoothingAlpha(forSpeed: speed)
        let target = CGPoint(
            x: previousSmoothed.x + (rawPoint.x - previousSmoothed.x) * alpha,
            y: previousSmoothed.y + (rawPoint.y - previousSmoothed.y) * alpha
        )

        let nextPressure = InkStrokeDynamics.normalizedPressure(pressure, fallback: smoothedPressure)
        smoothedPressure += (nextPressure - smoothedPressure) * Float(feel.pressureAlpha)

        lastRawPoint = rawPoint
        lastRawTime = time
        smoothedPoint = target

        return emitPoints(to: target, time: time, pressure: smoothedPressure)
    }

    mutating func finish(at rawPoint: CGPoint, time: Float, pressure: Float) -> [StrokePoint] {
        var points = append(to: rawPoint, time: time, pressure: pressure)
        guard let last = lastEmittedPoint else { return points }

        let endpointDistance = distance(CGPoint(x: CGFloat(last.x), y: CGFloat(last.y)), rawPoint)
        let anchorThreshold = max(0.35, min(baseWidth * 0.35, 1.0))
        guard endpointDistance >= anchorThreshold else { return points }

        let finalPressure = InkStrokeDynamics.normalizedPressure(pressure, fallback: smoothedPressure)
        let finalPoint = makePoint(rawPoint, time: time, pressure: finalPressure)
        lastEmittedPoint = finalPoint
        points.append(finalPoint)
        return points
    }

    private mutating func emitPoints(to target: CGPoint, time: Float, pressure: Float) -> [StrokePoint] {
        guard let last = lastEmittedPoint else {
            let point = makePoint(target, time: time, pressure: pressure)
            lastEmittedPoint = point
            return [point]
        }

        let start = CGPoint(x: CGFloat(last.x), y: CGFloat(last.y))
        let d = distance(start, target)
        let minDistance = max(0.18, min(baseWidth * 0.18, 0.55))
        guard d >= minDistance else { return [] }

        let maxSegment = max(2.2, min(baseWidth * 1.25, 4.0))
        let segmentCount = max(1, Int(ceil(d / maxSegment)))

        var result: [StrokePoint] = []
        result.reserveCapacity(segmentCount)
        for i in 1...segmentCount {
            let f = CGFloat(i) / CGFloat(segmentCount)
            let p = CGPoint(
                x: start.x + (target.x - start.x) * f,
                y: start.y + (target.y - start.y) * f
            )
            let pointTime = last.t + (time - last.t) * Float(f)
            let pointPressure = last.pressure + (pressure - last.pressure) * Float(f)
            result.append(makePoint(p, time: pointTime, pressure: pointPressure))
        }

        lastEmittedPoint = result.last
        return result
    }

    private func makePoint(_ pagePoint: CGPoint, time: Float, pressure: Float) -> StrokePoint {
        StrokePoint(x: Float(pagePoint.x),
                    y: Float(pagePoint.y),
                    t: time,
                    pressure: pressure)
    }

    private func smoothingAlpha(forSpeed speed: CGFloat) -> CGFloat {
        let normalized = min(max((speed - 80) / 900, 0), 1)
        let s = CGFloat(feel.sanitized.stabilization)
        let minAlpha = piecewise(defaultValue: 0.32, lowValue: 0.68, highValue: 0.16, t: s)
        let maxAlpha = piecewise(defaultValue: 0.78, lowValue: 0.92, highValue: 0.62, t: s)
        return minAlpha + normalized * (maxAlpha - minAlpha)
    }

    private func piecewise(defaultValue: CGFloat,
                           lowValue: CGFloat,
                           highValue: CGFloat,
                           t: CGFloat) -> CGFloat {
        if t <= 0.5 {
            let f = t / 0.5
            return lowValue + (defaultValue - lowValue) * f
        }
        let f = (t - 0.5) / 0.5
        return defaultValue + (highValue - defaultValue) * f
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }
}

// MARK: - InkStrokeDynamics
//
// Converts stored point metadata into a display half-width. The canonical stroke width stays in PDF
// page units; viewScale maps it to the current zoom level.
enum InkStrokeDynamics {
    static func normalizedPressure(_ pressure: Float,
                                   fallback: Float = StrokePoint.defaultPressure) -> Float {
        guard pressure.isFinite else { return normalizedFallback(fallback) }
        if pressure <= 0 { return normalizedFallback(fallback) }
        return min(max(pressure, 0), 1)
    }

    static func halfWidth(baseWidth: CGFloat,
                          viewScale: CGFloat,
                          point: StrokePoint,
                          previous: StrokePoint?,
                          feel: InkFeelSettings.Snapshot = .appDefault) -> Float {
        let feel = feel.sanitized
        let pressure = CGFloat(normalizedPressure(point.pressure))
        let defaultPressureFactor = 0.58 + 0.60 * CGFloat(pow(Double(pressure), 0.72))
        let pressureFactor = 1.0 + (defaultPressureFactor - 1.0) * CGFloat(feel.pressureResponse)
        let speedFactor = widthSpeedFactor(point: point, previous: previous, feel: feel)
        let width = max(baseWidth * viewScale * pressureFactor * speedFactor, 0.6)
        return Float(width * 0.5)
    }

    private static func widthSpeedFactor(point: StrokePoint,
                                         previous: StrokePoint?,
                                         feel: InkFeelSettings.Snapshot) -> CGFloat {
        guard let previous else { return 1.0 }
        let dtMS = max(CGFloat(point.t - previous.t), 1)
        let dx = CGFloat(point.x - previous.x)
        let dy = CGFloat(point.y - previous.y)
        let speed = hypot(dx, dy) / dtMS * 1_000
        let normalized = min(max(speed / 2_200, 0), 1)
        let defaultFactor = 1.06 - normalized * 0.22
        return 1.0 + (defaultFactor - 1.0) * CGFloat(feel.speedThinning)
    }

    private static func normalizedFallback(_ fallback: Float) -> Float {
        guard fallback.isFinite else { return StrokePoint.defaultPressure }
        return min(max(fallback, 0), 1)
    }
}
