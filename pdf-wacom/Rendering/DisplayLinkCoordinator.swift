import Cocoa
import CoreVideo

// MARK: - DisplayLinkCoordinator
//
// 앱 전체에 1개의 CVDisplayLink만 두고, 모든 StrokeCanvasView가 subscribe한다.
//
// 이전 구조: 페이지(=StrokeCanvasView)마다 자기 CVDisplayLink. 30페이지면 30개가 60Hz로 작동
// = 초당 1800개 main async block. 사용자 활동 없어도 main runloop를 지속적으로 두드림.
//
// 새 구조: 1개 DL → 60Hz로 단 1번 main async dispatch → fireAll이 subscriber 순회.
// 각 subscriber는 자기가 presentScheduled면 present, 아니면 no-op. 비활성 페이지는 0 cost.
//
// 효과:
//   - main runloop 부하 N→1 (페이지 수 무관)
//   - scroll / zoom 중 발생하는 layout pass와 경쟁 안 함
//   - 비활성 페이지가 idle 시 GPU/CPU 모두 0
//
// === 스레딩 ===
//   subscribe / unsubscribe는 main thread에서만 호출 (viewDidMoveToWindow에서).
//   fireAll도 main에서 실행 (DL 콜백이 main async로 hop).
//   따라서 subscribers 배열은 main-only — lock 불필요.
protocol DisplayLinkSubscriber: AnyObject {
    /// vsync 콜백. main thread에서 호출됨.
    func displayLinkFired()
}

final class DisplayLinkCoordinator {
    static let shared = DisplayLinkCoordinator()

    private var link: CVDisplayLink?
    /// weak ref로 보관 — subscriber가 dealloc되면 자동으로 nil되어 fireAll에서 제외됨.
    private var subscribers: [WeakSubscriberRef] = []

    private init() {}

    func subscribe(_ subscriber: DisplayLinkSubscriber) {
        // 중복 방어 — 같은 인스턴스 다시 subscribe 시 무시.
        if subscribers.contains(where: { $0.ref === subscriber }) { return }
        subscribers.append(WeakSubscriberRef(subscriber))
        if link == nil {
            start()
        }
    }

    func unsubscribe(_ subscriber: DisplayLinkSubscriber) {
        subscribers.removeAll { $0.ref === subscriber || $0.ref == nil }
        // subscribers 모두 dealloc되면 DL stop — 백그라운드 idle 보장.
        // (대부분 시나리오에선 앱 동안 1개 이상 살아있어 stop은 거의 안 됨.)
        if subscribers.isEmpty {
            stop()
        }
    }

    // MARK: - Private

    private func start() {
        var newLink: CVDisplayLink?
        guard CVDisplayLinkCreateWithActiveCGDisplays(&newLink) == kCVReturnSuccess,
              let newLink else { return }
        // singleton이라 self는 영구 alive — unretained 안전.
        let opaque = Unmanaged.passUnretained(self).toOpaque()
        CVDisplayLinkSetOutputCallback(newLink, { (_, _, _, _, _, context) -> CVReturn in
            guard let context else { return kCVReturnSuccess }
            let coord = Unmanaged<DisplayLinkCoordinator>.fromOpaque(context).takeUnretainedValue()
            DispatchQueue.main.async {
                coord.fireAll()
            }
            return kCVReturnSuccess
        }, opaque)
        CVDisplayLinkStart(newLink)
        link = newLink
    }

    private func stop() {
        guard let l = link else { return }
        link = nil
        CVDisplayLinkStop(l)
    }

    private func fireAll() {
        // dealloc된 weak ref 청소 + 콜백.
        var compacted: [WeakSubscriberRef] = []
        compacted.reserveCapacity(subscribers.count)
        for w in subscribers {
            if let s = w.ref {
                compacted.append(w)
                s.displayLinkFired()
            }
        }
        subscribers = compacted
    }
}

private final class WeakSubscriberRef {
    weak var ref: DisplayLinkSubscriber?
    init(_ r: DisplayLinkSubscriber) { self.ref = r }
}
