import Cocoa

// NSEvent의 tablet 메타데이터로 입력 디바이스를 분기.
// 펜이 아니면(=마우스/트랙패드) 캔버스 그리기를 차단한다.
//
// === 왜 proximity 추적이 필요한가 ===
// Wacom 펜은 stroke 사이사이에 살짝 떠 (한 글자 안의 각 획). 펜이 proximity 경계에 있는 순간의
// mouseDown은 subtype이 .tabletPoint가 아니라 .mouseEvent로 올 수 있다. subtype만 보고 reject하면
// 그 stroke가 통째로 누락 → 한글 받침같은 다음 획이 안 찍히는 현상.
// proximity 진입 시점에 state를 잡아두고, proximity 안이면 subtype 무관하게 펜으로 인정한다.
enum TabletEventRouter {
    enum Decision {
        case ignore
        case pen
    }

    /// tabletProximity 이벤트로 갱신되는 펜 근접 상태.
    /// AppDelegate에서 NSEvent.addLocalMonitorForEvents(matching: .tabletProximity)로 hook.
    private(set) static var penInProximity = false

    static func noteProximity(_ event: NSEvent) {
        guard event.type == .tabletProximity else { return }
        penInProximity = event.isEnteringProximity
    }

#if DEBUG
    static func setPenInProximityForTesting(_ value: Bool) {
        penInProximity = value
    }
#endif

    static func decide(_ event: NSEvent) -> Decision {
        // 1) tabletPoint subtype이면 무조건 펜.
        if event.subtype == .tabletPoint { return .pen }
        // 2) 펜이 근접 안에 있으면 subtype이 잠깐 다르게 와도 펜으로 인정 (proximity 경계 transition).
        if penInProximity { return .pen }
        // 3) 테스트/범용 입력용으로 마우스 drawing을 허용할 수 있다. 기본값은 기존처럼 ignore.
        return InputSettings.shared.ignoresMouseInput ? .ignore : .pen
    }
}
