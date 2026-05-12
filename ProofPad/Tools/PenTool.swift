import Cocoa

// MARK: - PenTool
//
// 펜으로 stroke를 그리는 Tool. 한 인스턴스가 ToolController에 공유되어 활성 stroke를 보유.
//
// 흐름:
//   mouseDown   PenSettings에서 현재 색·두께 읽어 Stroke 새로 만들고 InkStrokeBuilder 시작점 append.
//               canvas.beginInProgressStroke로 Metal renderer 초기화.
//   mouseDragged raw tablet sample을 smoothing/resampling한 점으로 변환 후 incremental geometry 갱신.
//   mouseUp     endpoint anchor를 반영하고 canvas.commitStroke로 baked mesh에 편입.
//
// 시간 t는 Float ms 단위, mouseDown 시점 = 0. (분석/리플레이 용도.)
final class PenTool: Tool {
    private var current: Stroke?
    private var builder: InkStrokeBuilder?
    private var straightLine = StraightLineHoldRecognizer()
    private weak var currentCanvas: StrokeCanvasView?
    private var straightLineHoldTimer: Timer?
    private var startTimestamp: TimeInterval = 0

    func mouseDown(at pagePoint: CGPoint, event: NSEvent, canvas: StrokeCanvasView) {
        let inkFeel = InkFeelSettings.shared.current
        let stroke = Stroke(color: PenSettings.shared.currentColor,
                            width: PenSettings.shared.currentWidth,
                            inkFeel: inkFeel)
        startTimestamp = event.timestamp
        var builder = InkStrokeBuilder(baseWidth: stroke.width, feel: inkFeel)
        let point = builder.begin(at: pagePoint,
                                  time: 0,
                                  pressure: eventPressure(event))
        stroke.append(point)
        straightLine.begin(point)
        self.builder = builder
        current = stroke
        currentCanvas = canvas
        straightLineHoldTimer?.invalidate()
        straightLineHoldTimer = nil
        canvas.beginInProgressStroke(stroke)
    }

    func mouseDragged(to pagePoint: CGPoint, event: NSEvent, canvas: StrokeCanvasView) {
        guard let stroke = current, var builder else { return }
        let t = elapsedMilliseconds(for: event)
        let pressure = eventPressure(event)
        let rawPoint = StrokePoint(x: Float(pagePoint.x),
                                   y: Float(pagePoint.y),
                                   t: t,
                                   pressure: pressure)
        let newPoints = builder.append(to: pagePoint,
                                       time: t,
                                       pressure: pressure)
        self.builder = builder

        if let linePoints = straightLine.append(rawPoint) {
            straightLineHoldTimer?.invalidate()
            straightLineHoldTimer = nil
            stroke.replacePoints(linePoints)
            canvas.replaceInProgressStroke(stroke)
            return
        }
        scheduleStraightLineHoldCheck(now: t)

        guard !newPoints.isEmpty else { return }
        for point in newPoints {
            stroke.append(point)
        }
        canvas.updateInProgressStroke(stroke)
    }

    func mouseUp(at pagePoint: CGPoint, event: NSEvent, canvas: StrokeCanvasView) {
        guard let stroke = current, var builder else { return }
        let t = elapsedMilliseconds(for: event)
        let pressure = eventPressure(event)
        let rawPoint = StrokePoint(x: Float(pagePoint.x),
                                   y: Float(pagePoint.y),
                                   t: t,
                                   pressure: pressure)
        if let linePoints = straightLine.finish(rawPoint) {
            stroke.replacePoints(linePoints)
            canvas.replaceInProgressStroke(stroke)
        } else {
            let newPoints = builder.finish(at: pagePoint,
                                           time: t,
                                           pressure: pressure)
            for point in newPoints {
                stroke.append(point)
            }
            if !newPoints.isEmpty {
                canvas.updateInProgressStroke(stroke)
            }
        }
        canvas.commitStroke(stroke)
        current = nil
        self.builder = nil
        currentCanvas = nil
        straightLineHoldTimer?.invalidate()
        straightLineHoldTimer = nil
    }

    private func elapsedMilliseconds(for event: NSEvent) -> Float {
        let elapsed = max(event.timestamp - startTimestamp, 0)
        return Float(elapsed * 1_000)
    }

    private func eventPressure(_ event: NSEvent) -> Float {
        InkStrokeDynamics.normalizedPressure(event.pressure)
    }

    private func scheduleStraightLineHoldCheck(now: Float) {
        guard let delayMS = straightLine.holdCheckDelayMS(now: now) else {
            straightLineHoldTimer?.invalidate()
            straightLineHoldTimer = nil
            return
        }
        straightLineHoldTimer?.invalidate()
        let delay = max(TimeInterval(delayMS) / 1_000, 0.01)
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            self?.snapStraightLineAfterTimer()
        }
        RunLoop.main.add(timer, forMode: .common)
        straightLineHoldTimer = timer
    }

    private func snapStraightLineAfterTimer() {
        guard let stroke = current,
              let canvas = currentCanvas,
              let linePoints = straightLine.snapAfterHoldIfReady(now: elapsedNowMilliseconds()) else { return }
        straightLineHoldTimer = nil
        stroke.replacePoints(linePoints)
        canvas.replaceInProgressStroke(stroke)
    }

    private func elapsedNowMilliseconds() -> Float {
        let elapsed = max(ProcessInfo.processInfo.systemUptime - startTimestamp, 0)
        return Float(elapsed * 1_000)
    }
}
