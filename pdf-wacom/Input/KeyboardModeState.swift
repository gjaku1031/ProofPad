import Cocoa

// MARK: - KeyboardModeState
//
// 앱 전역의 순간 키 모드. 그리기/지우기처럼 page canvas 안에서만 의미가 있는 임시 상태를 공유한다.
// Space hold는 pointer drag를 drawing 대신 page pan으로 전환한다.
final class KeyboardModeState {
    static let shared = KeyboardModeState()
    static let didChangeNotification = Notification.Name("KeyboardModeState.didChangeNotification")

    private(set) var isSpaceHeld = false

    private init() {}

    func setSpaceHeld(_ value: Bool) {
        guard isSpaceHeld != value else { return }
        isSpaceHeld = value
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }
}
