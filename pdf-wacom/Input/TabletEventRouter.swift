import Cocoa

// NSEvent의 tablet 메타데이터로 입력 디바이스를 분기.
// 펜이 아니면(=마우스/트랙패드) 캔버스 그리기를 차단한다.
enum TabletEventRouter {
    enum Decision {
        case ignore   // 마우스/트랙패드 — 캔버스 그리기 X
        case pen      // Wacom 펜 (펜 후미도 같이 펜 처리. 자동 지우개 전환은 정책상 제외)
    }

    static func decide(_ event: NSEvent) -> Decision {
        // tabletPoint subtype이 실린 mouse 이벤트만 펜으로 인정한다.
        // Wacom 드라이버 미설치 환경에서는 tabletPoint가 안 들어와 자연스럽게 ignore.
        guard event.subtype == .tabletPoint else { return .ignore }
        return .pen
    }
}
