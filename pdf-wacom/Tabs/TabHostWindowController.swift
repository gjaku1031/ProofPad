import Cocoa

// 단일 호스트 윈도우. 모든 NoteDocument의 viewController를 호스팅하고,
// 활성 탭의 viewController만 컨테이너에 마운트한다.
//
// NSDocument 통합 방식:
// - 각 NoteDocument.makeWindowControllers는 host.add(document:) 호출만 하고
//   자체 NSWindowController는 만들지 않는다(windowControllers는 비어 있음).
// - 그래서 NSDocument.close 시 windowControllers loop가 아무 것도 닫지 않아
//   다른 탭에 영향 없음.
// - host는 NSWindowController 서브클래스. host.document = activeDocument로 set해
//   NSDocumentController.currentDocument를 통한 ⌘S 라우팅이 동작하게 한다.
// - 도큐먼트 닫기는 별도 ⌘W → closeActiveTab(_:) — NSWindow.performClose는 사용 안 함.
final class TabHostWindowController: NSWindowController, NSMenuItemValidation {

    static let shared: TabHostWindowController = makeShared()

    private(set) var documents: [NoteDocument] = []
    private(set) var activeDocument: NoteDocument?
    private var viewControllersByDocID: [ObjectIdentifier: DocumentViewController] = [:]

    private var hostContentVC: HostContentViewController!
    private var tabBarView: AppTabBarView { hostContentVC.tabBarView }
    private var containerView: NSView { hostContentVC.containerView }

    private static func makeShared() -> TabHostWindowController {
        let size = NSSize(width: 1280, height: 800)
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let frame = NSRect(
            x: visible.midX - size.width / 2,
            y: visible.midY - size.height / 2,
            width: size.width, height: size.height
        )
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        window.title = "pdf-wacom"
        window.setFrameAutosaveName("HostWindow")
        let wc = TabHostWindowController(window: window)
        wc.setupContent()
        return wc
    }

    private func setupContent() {
        guard let window = self.window else { return }
        // 시스템 tabbing UI 제거 (Show Tab Bar/Show All Tabs).
        window.tabbingMode = .disallowed

        let host = HostContentViewController()
        host.tabBarView.host = self
        self.hostContentVC = host
        window.contentViewController = host

        // NSToolbar
        window.toolbar = ToolbarBuilder.makeToolbar()
        if #available(macOS 11.0, *) {
            window.toolbarStyle = .unified
        }

        // 탭바 — titlebar accessory(.bottom)로 toolbar 아래에 부착.
        // 풀스크린 .autoHideToolbar 모드에서 toolbar와 동일한 슬라이드 애니메이션으로
        // 동시에 자동 숨김/표시 됨 (시스템이 동기 처리, lag·desync 없음).
        let accessory = NSTitlebarAccessoryViewController()
        accessory.view = host.tabBarView
        accessory.layoutAttribute = .bottom
        window.addTitlebarAccessoryViewController(accessory)

        // 윈도우 close 처리 (모든 탭 prompt) + 풀스크린 hook
        window.delegate = self
    }

    private var activeViewController: DocumentViewController? {
        guard let doc = activeDocument else { return nil }
        return viewControllersByDocID[ObjectIdentifier(doc)]
    }

    // MARK: - Selector forwarding to active DocumentViewController
    // 메뉴/툴바 selector가 NSResponder chain의 host에서 즉시 발견되어 enable 보장.

    @IBAction func scrollToNextSpread(_ sender: Any?) { activeViewController?.scrollToNextSpread(sender) }
    @IBAction func scrollToPreviousSpread(_ sender: Any?) { activeViewController?.scrollToPreviousSpread(sender) }

    @IBAction func zoomIn(_ sender: Any?) { activeViewController?.zoomIn(sender) }
    @IBAction func zoomOut(_ sender: Any?) { activeViewController?.zoomOut(sender) }
    @IBAction func fitWidth(_ sender: Any?) { activeViewController?.fitWidth(sender) }
    @IBAction func fitHeight(_ sender: Any?) { activeViewController?.fitHeight(sender) }
    @IBAction func fitPage(_ sender: Any?) { activeViewController?.fitPage(sender) }
    @IBAction func actualSize(_ sender: Any?) { activeViewController?.actualSize(sender) }
    @IBAction func goToPage(_ sender: Any?) { activeViewController?.goToPage(sender) }
    @IBAction func exportPDF(_ sender: Any?) { activeViewController?.exportPDF(sender) }
    @IBAction func toggleDocumentSidebar(_ sender: Any?) {
        activeViewController?.toggleDocumentSidebar(sender)
    }

    @objc func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(zoomIn(_:)),
             #selector(zoomOut(_:)),
             #selector(fitWidth(_:)),
             #selector(fitHeight(_:)),
             #selector(fitPage(_:)),
             #selector(actualSize(_:)),
             #selector(goToPage(_:)),
             #selector(exportPDF(_:)),
             #selector(toggleDocumentSidebar(_:)),
             #selector(closeActiveTab(_:)),
             #selector(nextTab(_:)),
             #selector(previousTab(_:)):
            return activeDocument != nil
        case #selector(tab1(_:)): return documents.count >= 1
        case #selector(tab2(_:)): return documents.count >= 2
        case #selector(tab3(_:)): return documents.count >= 3
        case #selector(tab4(_:)): return documents.count >= 4
        case #selector(tab5(_:)): return documents.count >= 5
        case #selector(tab6(_:)): return documents.count >= 6
        case #selector(tab7(_:)): return documents.count >= 7
        case #selector(tab8(_:)): return documents.count >= 8
        case #selector(tab9(_:)): return documents.count >= 9
        default:
            // 기본 NSResponder chain 동작에 위임
            return responds(to: menuItem.action)
        }
    }

    // MARK: - Tab management

    func add(document: NoteDocument) {
        guard !documents.contains(where: { $0 === document }) else {
            activate(document: document)
            return
        }
        documents.append(document)
        // viewController는 activate 시점에 lazy 생성 — 탭 다수 동시 add 시 부담 분산.
        activate(document: document)
        showWindowIfNeeded()
        tabBarView.reload()
        TabSession.save(documents: documents)
    }

    func activate(document: NoteDocument) {
        guard documents.contains(where: { $0 === document }) else { return }
        activeDocument = document
        self.document = document
        let vc = viewController(for: document)
        hostContentVC.setActive(vc)
        window?.title = document.displayName ?? "pdf-wacom"
        tabBarView.reload()
    }

    private func viewController(for document: NoteDocument) -> DocumentViewController {
        if let vc = viewControllersByDocID[ObjectIdentifier(document)] {
            return vc
        }
        let vc = DocumentViewController(document: document)
        viewControllersByDocID[ObjectIdentifier(document)] = vc
        return vc
    }

    func remove(document: NoteDocument) {
        guard let idx = documents.firstIndex(where: { $0 === document }) else { return }
        documents.remove(at: idx)
        viewControllersByDocID.removeValue(forKey: ObjectIdentifier(document))
        if activeDocument === document {
            let nextIdx = min(idx, documents.count - 1)
            if documents.indices.contains(nextIdx) {
                activate(document: documents[nextIdx])
            } else {
                activeDocument = nil
                self.document = nil
                hostContentVC.setActive(nil)
                window?.title = "pdf-wacom"
            }
        }
        tabBarView.reload()
        TabSession.save(documents: documents)
        if documents.isEmpty {
            window?.orderOut(nil)
        }
    }

    private func showWindowIfNeeded() {
        guard let window = self.window else { return }
        if !window.isVisible {
            window.makeKeyAndOrderFront(nil)
        }
    }

    // MARK: - Menu actions

    @IBAction func newDocumentTab(_ sender: Any?) {
        // ⌘T → Open dialog로 PDF/.pdfnote 선택 → 새 탭으로 추가
        NSDocumentController.shared.openDocument(nil)
    }

    @IBAction func closeActiveTab(_ sender: Any?) {
        guard let doc = activeDocument else { return }
        doc.canClose(
            withDelegate: self,
            shouldClose: #selector(document(_:shouldClose:contextInfo:)),
            contextInfo: nil
        )
    }

    @objc private func document(_ doc: NSDocument, shouldClose: Bool, contextInfo: UnsafeMutableRawPointer?) {
        guard shouldClose, let nd = doc as? NoteDocument else { return }
        remove(document: nd)
        nd.close()
    }

    @IBAction func nextTab(_ sender: Any?) {
        guard !documents.isEmpty,
              let active = activeDocument,
              let idx = documents.firstIndex(where: { $0 === active }) else { return }
        activate(document: documents[(idx + 1) % documents.count])
    }

    @IBAction func previousTab(_ sender: Any?) {
        guard !documents.isEmpty,
              let active = activeDocument,
              let idx = documents.firstIndex(where: { $0 === active }) else { return }
        activate(document: documents[(idx - 1 + documents.count) % documents.count])
    }

    @objc func activateTab(at index: Int) {
        guard documents.indices.contains(index) else { return }
        activate(document: documents[index])
    }

    // 메뉴 ⌘1 ~ ⌘9 액션 (selector "tab1:" ~ "tab9:")
    @IBAction func tab1(_ sender: Any?) { activateTab(at: 0) }
    @IBAction func tab2(_ sender: Any?) { activateTab(at: 1) }
    @IBAction func tab3(_ sender: Any?) { activateTab(at: 2) }
    @IBAction func tab4(_ sender: Any?) { activateTab(at: 3) }
    @IBAction func tab5(_ sender: Any?) { activateTab(at: 4) }
    @IBAction func tab6(_ sender: Any?) { activateTab(at: 5) }
    @IBAction func tab7(_ sender: Any?) { activateTab(at: 6) }
    @IBAction func tab8(_ sender: Any?) { activateTab(at: 7) }
    @IBAction func tab9(_ sender: Any?) { activateTab(at: 8) }

    // MARK: - Presentation Mode (⌘⇧F)

    private(set) var isInPresentationMode = false

    // MARK: - Tool selection (⌃⌘1/2/3, ⌃⌘E)

    @IBAction func selectPen1(_ sender: Any?) { PenSettings.shared.selectPen(0) }
    @IBAction func selectPen2(_ sender: Any?) { PenSettings.shared.selectPen(1) }
    @IBAction func selectPen3(_ sender: Any?) { PenSettings.shared.selectPen(2) }
    @IBAction func selectEraser(_ sender: Any?) { PenSettings.shared.selectEraser() }

    @IBAction func togglePresentationMode(_ sender: Any?) {
        guard let window = self.window else { return }
        // 시스템 풀스크린과 동시에 우리 탭바 hidden 처리.
        // delegate의 willEnter/didExit hook은 이미 등록되어 있어 거기서 보강.
        window.toggleFullScreen(nil)
    }
}

// MARK: - NSWindowDelegate

extension TabHostWindowController: NSWindowDelegate {

    // 풀스크린에서 NSToolbar를 OS가 자동 숨김/표시하도록 .autoHideToolbar 추가.
    // (수동 isVisible 토글은 fullscreen에서 무거운 chrome 애니메이션을 trigger해 lag 발생.)
    func window(_ window: NSWindow,
                willUseFullScreenPresentationOptions proposedOptions: NSApplication.PresentationOptions = []) -> NSApplication.PresentationOptions {
        return proposedOptions.union([.autoHideToolbar])
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        isInPresentationMode = true
        // toolbar + titlebar accessory(탭바)는 .autoHideToolbar로 시스템이 함께 처리.
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        isInPresentationMode = false
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // 사용자가 윈도우 close 버튼 누르면 모든 탭을 차례로 close prompt.
        // 단순화: 모든 탭에 dirty 검사 후 일괄 close.
        if documents.isEmpty {
            return true
        }
        // 첫 dirty 도큐먼트부터 순차 처리. 단순히 한 도큐먼트씩 canClose.
        closeAllTabsSequentially()
        return false
    }

    private func closeAllTabsSequentially() {
        guard let first = documents.first else {
            window?.close()
            return
        }
        first.canClose(
            withDelegate: self,
            shouldClose: #selector(documentInChainShouldClose(_:shouldClose:contextInfo:)),
            contextInfo: nil
        )
    }

    @objc private func documentInChainShouldClose(_ doc: NSDocument, shouldClose: Bool, contextInfo: UnsafeMutableRawPointer?) {
        if !shouldClose { return }   // 사용자가 취소
        guard let nd = doc as? NoteDocument else { return }
        remove(document: nd)
        nd.close()
        if !documents.isEmpty {
            closeAllTabsSequentially()
        }
    }
}
