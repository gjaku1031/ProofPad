import Cocoa

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private let appUpdater = AppUpdater.shared
    private var arrowKeyMonitor: Any?
    private var holdKeyMonitor: Any?
    private var proximityMonitor: Any?
    private var resignActiveObserver: NSObjectProtocol?
    private var inputSettingsObserver: NSObjectProtocol?

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenuBuilder.build(updateController: appUpdater.updaterController)
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
        appUpdater.start()
        installHoldKeyMonitor()
        installArrowKeyNavigation()
        installTabletProximityMonitor()
        installKeyboardModeReset()
        installInputSettingsReset()
        DispatchQueue.main.async {
            self.restoreSessionOrPromptOpen()
        }
    }

    private func installApplicationIcon() {
        guard let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
              let icon = NSImage(contentsOf: iconURL) else { return }
        NSApp.applicationIconImage = icon
    }

    private func installHoldKeyMonitor() {
        holdKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { event in
            switch event.type {
            case .flagsChanged:
                if !Self.isInputRecorderFocused {
                    Self.syncModifierHoldStates(with: event.modifierFlags)
                }
                return event
            case .keyDown, .keyUp:
                return Self.handleHoldKeyEvent(event) ? nil : event
            default:
                return event
            }
        }
    }

    private static var isTextInputFocused: Bool {
        let firstResponder = NSApp.keyWindow?.firstResponder
        return firstResponder is NSText || firstResponder is NSTextView
    }

    private static var isInputRecorderFocused: Bool {
        NSApp.keyWindow?.firstResponder is InputKeyCaptureView
    }

    private static func syncModifierHoldStates(with flags: NSEvent.ModifierFlags) {
        let settings = InputSettings.shared
        if settings.moveHoldKey.isModifier {
            KeyboardModeState.shared.setMoveHeld(settings.moveHoldKey.matchesModifierFlags(flags))
        }
        if settings.eraserHoldKey.isModifier {
            KeyboardModeState.shared.setEraserHeld(settings.eraserHoldKey.matchesModifierFlags(flags))
        }
    }

    private static func handleHoldKeyEvent(_ event: NSEvent) -> Bool {
        let settings = InputSettings.shared
        let matchesMove = settings.moveHoldKey.matchesKeyCode(event.keyCode)
        let matchesEraser = settings.eraserHoldKey.matchesKeyCode(event.keyCode)
        guard matchesMove || matchesEraser else { return false }

        if event.type == .keyUp {
            var consumed = false
            if matchesMove, KeyboardModeState.shared.isMoveHeld {
                KeyboardModeState.shared.setMoveHeld(false)
                consumed = true
            }
            if matchesEraser, KeyboardModeState.shared.isEraserHeld {
                KeyboardModeState.shared.setEraserHeld(false)
                consumed = true
            }
            return consumed
        }

        guard shouldStartHoldMode(for: event) else { return false }
        if matchesMove {
            KeyboardModeState.shared.setMoveHeld(true)
        }
        if matchesEraser {
            KeyboardModeState.shared.setEraserHeld(true)
        }
        return true
    }

    private static func shouldStartHoldMode(for event: NSEvent) -> Bool {
        guard NSApp.keyWindow?.windowController is TabHostWindowController else { return false }
        guard !isTextInputFocused, !isInputRecorderFocused else { return false }
        let reservedModifiers = event.modifierFlags.intersection([.command, .option, .control])
        return reservedModifiers.isEmpty
    }

    private func installKeyboardModeReset() {
        resignActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: NSApp,
            queue: .main
        ) { _ in
            KeyboardModeState.shared.resetAll()
        }
    }

    private func installInputSettingsReset() {
        inputSettingsObserver = NotificationCenter.default.addObserver(
            forName: InputSettings.didChangeNotification,
            object: InputSettings.shared,
            queue: .main
        ) { _ in
            KeyboardModeState.shared.resetAll()
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
        let preopenedDocuments = NSDocumentController.shared.documents.compactMap { $0 as? PDFInkDocument }
        if !preopenedDocuments.isEmpty {
            preopenedDocuments.forEach { TabHostWindowController.shared.add(document: $0) }
            return
        }

        let urls = TabSession.loadURLs()
        if urls.isEmpty {
            TabHostWindowController.shared.showHome(nil)
            return
        }
        for url in urls {
            NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { document, _, _ in
                guard let document = document as? PDFInkDocument else { return }
                if !TabHostWindowController.shared.documents.contains(where: { $0 === document }) {
                    TabHostWindowController.shared.add(document: document)
                }
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            TabHostWindowController.shared.showHome(nil)
        }
        return true
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

    func applicationShouldRestoreApplicationState(_ app: NSApplication) -> Bool {
        false
    }

    func applicationShouldSaveApplicationState(_ app: NSApplication) -> Bool {
        false
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }
}
