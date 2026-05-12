import Cocoa

// MARK: - KeyboardModeState
//
// 앱 전역의 순간 키 모드. 그리기/지우기처럼 page canvas 안에서만 의미가 있는 임시 상태를 공유한다.
// 실제 keymap은 InputSettings가 소유하고, 이 타입은 "현재 hold 중인가"만 가진다.
final class KeyboardModeState {
    static let shared = KeyboardModeState()
    static let didChangeNotification = Notification.Name("KeyboardModeState.didChangeNotification")

    private(set) var isMoveHeld = false
    private(set) var isEraserHeld = false

    var isSpaceHeld: Bool { isMoveHeld }

    private init() {}

    func setSpaceHeld(_ value: Bool) {
        setMoveHeld(value)
    }

    func setMoveHeld(_ value: Bool) {
        guard isMoveHeld != value else { return }
        isMoveHeld = value
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }

    func setEraserHeld(_ value: Bool) {
        guard isEraserHeld != value else { return }
        isEraserHeld = value
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }

    func resetAll() {
        guard isMoveHeld || isEraserHeld else { return }
        isMoveHeld = false
        isEraserHeld = false
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }
}
