import Cocoa

// MARK: - InputSettings
//
// 캔버스 입력 정책과 임시 hold 키를 앱 전역 preference로 관리한다.
// 기본값은 기존 동작과 동일하다: 마우스 drawing 무시, Control hold 지우개, Space hold 이동.
final class InputSettings {
    static let shared = InputSettings()
    static let didChangeNotification = Notification.Name("InputSettings.didChangeNotification")

    struct Snapshot: Codable, Equatable {
        var ignoresMouseInput: Bool
        var eraserHoldKey: InputHoldKey
        var moveHoldKey: InputHoldKey

        static let appDefault = Snapshot(
            ignoresMouseInput: true,
            eraserHoldKey: .modifier(.control),
            moveHoldKey: .keyCode(49, displayName: "Space")
        )
    }

    private static let defaultsKey = "InputSettings.v1"

    private(set) var current: Snapshot

    private init() {
        current = Self.loadSnapshot() ?? .appDefault
    }

    var ignoresMouseInput: Bool { current.ignoresMouseInput }
    var eraserHoldKey: InputHoldKey { current.eraserHoldKey }
    var moveHoldKey: InputHoldKey { current.moveHoldKey }

    func setIgnoresMouseInput(_ value: Bool) {
        guard current.ignoresMouseInput != value else { return }
        current.ignoresMouseInput = value
        saveAndNotify()
    }

    func setEraserHoldKey(_ key: InputHoldKey) {
        guard current.eraserHoldKey != key else { return }
        current.eraserHoldKey = key
        saveAndNotify()
    }

    func setMoveHoldKey(_ key: InputHoldKey) {
        guard current.moveHoldKey != key else { return }
        current.moveHoldKey = key
        saveAndNotify()
    }

    func resetToDefaults() {
        guard current != .appDefault else { return }
        current = .appDefault
        saveAndNotify()
    }

#if DEBUG
    func replaceForTesting(_ snapshot: Snapshot) {
        current = snapshot
        saveAndNotify()
    }
#endif

    private func saveAndNotify() {
        if let data = try? JSONEncoder().encode(current) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }

    private static func loadSnapshot() -> Snapshot? {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) else {
            return nil
        }
        return snapshot
    }
}

enum InputModifierKey: String, Codable, CaseIterable {
    case control
    case option
    case command
    case shift

    var flag: NSEvent.ModifierFlags {
        switch self {
        case .control: return .control
        case .option: return .option
        case .command: return .command
        case .shift: return .shift
        }
    }

    var displayName: String {
        switch self {
        case .control: return "Control"
        case .option: return "Option"
        case .command: return "Command"
        case .shift: return "Shift"
        }
    }
}

struct InputHoldKey: Codable, Equatable {
    enum Kind: String, Codable {
        case modifier
        case keyCode
    }

    var kind: Kind
    var modifier: InputModifierKey?
    var keyCode: UInt16?
    var displayName: String

    static func modifier(_ modifier: InputModifierKey) -> InputHoldKey {
        InputHoldKey(kind: .modifier,
                     modifier: modifier,
                     keyCode: nil,
                     displayName: modifier.displayName)
    }

    static func keyCode(_ keyCode: UInt16, displayName: String) -> InputHoldKey {
        InputHoldKey(kind: .keyCode,
                     modifier: nil,
                     keyCode: keyCode,
                     displayName: displayName)
    }

    var isModifier: Bool {
        kind == .modifier
    }

    func matchesModifierFlags(_ flags: NSEvent.ModifierFlags) -> Bool {
        guard kind == .modifier, let modifier else { return false }
        return flags.contains(modifier.flag)
    }

    func matchesKeyCode(_ keyCode: UInt16) -> Bool {
        guard kind == .keyCode else { return false }
        return self.keyCode == keyCode
    }

    static func fromModifierFlags(_ flags: NSEvent.ModifierFlags) -> InputHoldKey? {
        let order: [InputModifierKey] = [.control, .option, .command, .shift]
        guard let modifier = order.first(where: { flags.contains($0.flag) }) else { return nil }
        return .modifier(modifier)
    }

    static func fromKeyDown(_ event: NSEvent) -> InputHoldKey? {
        guard event.type == .keyDown else { return nil }
        return .keyCode(event.keyCode,
                        displayName: displayName(forKeyCode: event.keyCode,
                                                 characters: event.charactersIgnoringModifiers))
    }

    private static func displayName(forKeyCode keyCode: UInt16, characters: String?) -> String {
        switch keyCode {
        case 36: return "Return"
        case 48: return "Tab"
        case 49: return "Space"
        case 51: return "Delete"
        case 53: return "Escape"
        case 116: return "Page Up"
        case 121: return "Page Down"
        case 123: return "Left Arrow"
        case 124: return "Right Arrow"
        case 125: return "Down Arrow"
        case 126: return "Up Arrow"
        default:
            let cleaned = characters?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if cleaned.count == 1 {
                return cleaned.uppercased()
            }
            if !cleaned.isEmpty {
                return cleaned
            }
            return "Key \(keyCode)"
        }
    }
}
