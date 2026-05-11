import Cocoa

// NSEvent의 tablet 메타데이터로 입력 디바이스를 분기.
// 펜이 아니면(=마우스/트랙패드) 캔버스 그리기를 차단한다.
enum TabletEventRouter {
    enum Decision {
        case ignore   // 마우스/트랙패드 — 캔버스 그리기 X
        case pen      // Wacom 펜 (펜 후미도 같이 펜 처리. 자동 지우개 전환은 정책상 제외)
    }

    static func decide(_ event: NSEvent) -> Decision {
        // [A/B 테스트 모드] 마우스/트랙패드도 그리기 허용 — 깜빡임 원인이 input 단인지 render 단인지 분기.
        // 정상 동작 (Wacom 펜만 그리기)으로 돌리려면 아래 줄을 다음으로 교체:
        //   guard event.subtype == .tabletPoint else { return .ignore }
        return .pen
    }
}
