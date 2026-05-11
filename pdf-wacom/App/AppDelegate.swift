import Cocoa

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var arrowKeyMonitor: Any?
    private var spacePanMonitor: Any?
    private var proximityMonitor: Any?
    private var resignActiveObserver: NSObjectProtocol?

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenuBuilder.build()
        NSApp.setActivationPolicy(.regular)
        // 시스템 NSWindow tabbing(Show Tab Bar/Show All Tabs)을 막아 우리 자체 탭바와 충돌 회피.
        NSWindow.allowsAutomaticWindowTabbing = false
        // mouse coalescing OFF — 모든 pen sample을 받음. 빠른 curve(한글 받침·꺾임)에서
        // 샘플 누락으로 stroke가 끊기거나 직선 점프해 글자 망가지는 것 방지.
        // 안전: framesInFlight cap=1이라 매 이벤트마다 present 시도해도 GPU 쪽에서 자연 throttle.
        NSEvent.isMouseCoalescingEnabled = false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installApplicationIcon()
        NSApp.activate(ignoringOtherApps: true)
        installSpacePanMonitor()
        installArrowKeyNavigation()
        installTabletProximityMonitor()
        installKeyboardModeReset()
        DispatchQueue.main.async {
            self.restoreSessionOrPromptOpen()
        }
    }

    private func installApplicationIcon() {
        guard let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
              let icon = NSImage(contentsOf: iconURL) else { return }
        NSApp.applicationIconImage = icon
    }

    private func installSpacePanMonitor() {
        spacePanMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { event in
            guard event.keyCode == 49 else { return event } // Space
            if event.type == .keyUp, KeyboardModeState.shared.isSpaceHeld {
                KeyboardModeState.shared.setSpaceHeld(false)
                return nil
            }
            let reservedModifiers = event.modifierFlags.intersection([.command, .option, .control])
            guard reservedModifiers.isEmpty else { return event }
            guard NSApp.keyWindow?.windowController is TabHostWindowController else { return event }
            guard !Self.isTextInputFocused else { return event }

            KeyboardModeState.shared.setSpaceHeld(true)
            return nil
        }
    }

    private static var isTextInputFocused: Bool {
        let firstResponder = NSApp.keyWindow?.firstResponder
        return firstResponder is NSText || firstResponder is NSTextView
    }

    private func installKeyboardModeReset() {
        resignActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: NSApp,
            queue: .main
        ) { _ in
            KeyboardModeState.shared.setSpaceHeld(false)
        }
    }

    /// Wacom 펜이 태블릿 근접 영역 진입/이탈 시 TabletEventRouter 상태 갱신.
    /// 이게 없으면 proximity 경계 transition 때 subtype이 잠시 .mouseEvent로 오는 펜 샘플들이
    /// 거부되어 stroke에 구멍 생김 (한글 받침 같은 짧은 획 누락 사례).
    private func installTabletProximityMonitor() {
        proximityMonitor = NSEvent.addLocalMonitorForEvents(matching: .tabletProximity) { event in
            TabletEventRouter.noteProximity(event)
            return event
        }
    }

    private func restoreSessionOrPromptOpen() {
        let urls = TabSession.loadURLs()
        if urls.isEmpty {
            if NSDocumentController.shared.documents.isEmpty {
                NSDocumentController.shared.openDocument(nil)
            }
            return
        }
        for url in urls {
            NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, _ in }
        }
    }

    // 방향키로 펼침면 이동 (textField/textView에 포커스가 있으면 그쪽 우선).
    // 주의: 방향키 NSEvent는 .function/.numericPad bit가 set되어 있어
    // deviceIndependentFlagsMask로 잡으면 isEmpty가 false가 됨. 명시적 mask 사용.
    private func installArrowKeyNavigation() {
        let userModifiers: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
        arrowKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let flags = event.modifierFlags.intersection(userModifiers)
            guard flags.isEmpty || flags == .shift else { return event }

            let firstResponder = NSApp.keyWindow?.firstResponder
            if firstResponder is NSText || firstResponder is NSTextView { return event }

            switch event.keyCode {
            case 125, 124, 121:   // Down, Right, PageDown
                TabHostWindowController.shared.scrollToNextSpread(nil)
                return nil
            case 126, 123, 116:   // Up, Left, PageUp
                TabHostWindowController.shared.scrollToPreviousSpread(nil)
                return nil
            default:
                return event
            }
        }
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }
}
