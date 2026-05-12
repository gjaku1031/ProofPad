import Cocoa
import SwiftUI

// host 윈도우 NSToolbar.
// [P1|P2|P3|⌫ Eraser|Ink Feel] — 같은 펜을 한 번 더 클릭하면 색·두께 편집 popover.
// Ink Feel은 새 stroke의 smoothing/pressure/latency 기본값을 조절하는 popover.
// 입력 토글은 펜 도구 왼쪽, 우측에는 keymap, PDF tools, flattened PDF export.
final class ToolbarBuilder: NSObject, NSToolbarDelegate {

    static let identifier = NSToolbar.Identifier("MainToolbar.v7")

    enum ItemID {
        static let sidebar = NSToolbarItem.Identifier("sidebar")
        static let mouseInput = NSToolbarItem.Identifier("mouseInput")
        static let tools = NSToolbarItem.Identifier("tools")
        static let keymap = NSToolbarItem.Identifier("keymap")
        static let pdfTools = NSToolbarItem.Identifier("pdfTools")
        static let exportPDF = NSToolbarItem.Identifier("exportPDF")
    }

    static func makeToolbar() -> NSToolbar {
        let toolbar = NSToolbar(identifier: identifier)
        toolbar.displayMode = .iconAndLabel
        toolbar.allowsUserCustomization = true
        toolbar.autosavesConfiguration = true
        let delegate = ToolbarBuilder()
        toolbar.delegate = delegate
        objc_setAssociatedObject(toolbar, &Self.delegateKey, delegate, .OBJC_ASSOCIATION_RETAIN)
        PenSettings.shared.onChange = { [weak delegate] in delegate?.syncUI() }
        delegate.inputSettingsObserver = NotificationCenter.default.addObserver(
            forName: InputSettings.didChangeNotification,
            object: InputSettings.shared,
            queue: .main
        ) { [weak delegate] _ in
            delegate?.syncUI()
        }
        return toolbar
    }

    private static var delegateKey: UInt8 = 0

    private weak var toolsControl: NSSegmentedControl?
    private weak var mouseInputButton: NSButton?
    private var penEditorPopover: NSPopover?
    private var inkFeelPopover: NSPopover?
    private var keymapPopover: NSPopover?
    private var inputSettingsObserver: NSObjectProtocol?

    deinit {
        if let inputSettingsObserver {
            NotificationCenter.default.removeObserver(inputSettingsObserver)
        }
    }

    // MARK: - NSToolbarDelegate

    func toolbar(_ toolbar: NSToolbar,
                 itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch itemIdentifier {
        case ItemID.sidebar:   return makeSidebarItem()
        case ItemID.mouseInput: return makeMouseInputItem()
        case ItemID.tools:     return makeToolsItem()
        case ItemID.keymap:    return makeKeymapItem()
        case ItemID.pdfTools:  return makePDFToolsItem()
        case ItemID.exportPDF: return makeExportItem()
        default:               return nil
        }
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [ItemID.sidebar, .space, ItemID.mouseInput, ItemID.tools, .flexibleSpace, ItemID.keymap, ItemID.pdfTools, ItemID.exportPDF]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [ItemID.sidebar, ItemID.mouseInput, ItemID.tools, ItemID.keymap, ItemID.pdfTools, ItemID.exportPDF, .flexibleSpace, .space]
    }

    // MARK: - Items

    private func makeToolsItem() -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: ItemID.tools)
        item.label = "Tool"
        item.paletteLabel = "Tool"
        // label은 비워두고 image로 통일 — pen 3개는 color swatch, 4번째는 eraser, 5번째는 feel settings.
        let control = NSSegmentedControl(labels: ["", "", "", "", ""],
                                         trackingMode: .selectOne,
                                         target: self,
                                         action: #selector(toolsChanged(_:)))
        control.segmentStyle = .texturedRounded
        if let eraserImg = NSImage(systemSymbolName: "eraser",
                                    accessibilityDescription: "Eraser") {
            control.setImage(eraserImg, forSegment: 3)
        }
        if let settingsImg = NSImage(systemSymbolName: "slider.horizontal.3",
                                     accessibilityDescription: "Ink Feel Settings") {
            control.setImage(settingsImg, forSegment: 4)
        }
        control.setWidth(36, forSegment: 0)
        control.setWidth(36, forSegment: 1)
        control.setWidth(36, forSegment: 2)
        control.setWidth(44, forSegment: 3)
        control.setWidth(44, forSegment: 4)
        control.setToolTip("Pen 1", forSegment: 0)
        control.setToolTip("Pen 2", forSegment: 1)
        control.setToolTip("Pen 3", forSegment: 2)
        control.setToolTip("Eraser", forSegment: 3)
        control.setToolTip("Ink Feel", forSegment: 4)
        control.translatesAutoresizingMaskIntoConstraints = false
        item.view = control
        self.toolsControl = control
        syncToolsControl()
        return item
    }

    private func makeSidebarItem() -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: ItemID.sidebar)
        item.label = "Sidebar"
        item.paletteLabel = "Sidebar"
        item.toolTip = "Toggle Sidebar (⌃⌘S)"
        item.image = NSImage(systemSymbolName: "sidebar.left",
                             accessibilityDescription: "Toggle Sidebar")
        item.action = Selector(("toggleDocumentSidebar:"))
        item.target = nil   // responder chain
        return item
    }

    private func makeMouseInputItem() -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: ItemID.mouseInput)
        item.label = "Mouse"
        item.paletteLabel = "Ignore Mouse"
        item.toolTip = "Ignore Mouse Drawing"

        let button = NSButton(image: Self.mouseInputImage(),
                              target: self,
                              action: #selector(toggleMouseInput(_:)))
        button.setButtonType(.toggle)
        button.bezelStyle = .texturedRounded
        button.imageScaling = .scaleProportionallyDown
        button.toolTip = "Ignore Mouse Drawing"
        button.frame = NSRect(x: 0, y: 0, width: 34, height: 28)
        item.view = button
        mouseInputButton = button
        syncMouseInputButton()
        return item
    }

    private func makeExportItem() -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: ItemID.exportPDF)
        item.label = "Flatten"
        item.paletteLabel = "Export Flattened PDF"
        item.image = NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: "Export Flattened PDF")
        item.action = Selector(("exportPDF:"))
        item.target = nil
        return item
    }

    private func makeKeymapItem() -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: ItemID.keymap)
        item.label = "Keymap"
        item.paletteLabel = "Keymap"
        item.toolTip = "Keymap"

        let button = NSButton(image: NSImage(systemSymbolName: "keyboard",
                                             accessibilityDescription: "Keymap") ?? NSImage(),
                              target: self,
                              action: #selector(showKeymapPopover(_:)))
        button.bezelStyle = .texturedRounded
        button.imageScaling = .scaleProportionallyDown
        button.toolTip = "Keymap"
        button.frame = NSRect(x: 0, y: 0, width: 34, height: 28)
        item.view = button
        return item
    }

    private func makePDFToolsItem() -> NSToolbarItem {
        let item = NSMenuToolbarItem(itemIdentifier: ItemID.pdfTools)
        item.label = "PDF"
        item.paletteLabel = "PDF Tools"
        item.toolTip = "PDF Tools"
        item.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "PDF Tools")
        item.menu = Self.makePDFToolsMenu()
        return item
    }

    private static func makePDFToolsMenu() -> NSMenu {
        let menu = NSMenu(title: "PDF Tools")
        menu.addItem(NSMenuItem(title: "Append PDF Pages…",
                                action: Selector(("appendPDFPages:")),
                                keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Append Images as Pages…",
                                action: Selector(("appendImagesAsPages:")),
                                keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Delete Current Page",
                                action: Selector(("deleteCurrentPage:")),
                                keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Export Current Page as PDF…",
                                action: Selector(("exportCurrentPagePDF:")),
                                keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Export Pages as Images…",
                                action: Selector(("exportPagesAsImages:")),
                                keyEquivalent: ""))
        return menu
    }

    // MARK: - Sync UI

    func syncUI() {
        syncToolsControl()
        syncMouseInputButton()
    }

    private func syncToolsControl() {
        guard let control = toolsControl else { return }
        let selected: Int = (PenSettings.shared.currentTool == .eraser) ? 3 : PenSettings.shared.currentPenIndex
        control.selectedSegment = selected
        for i in 0..<3 {
            let color = PenSettings.shared.pens[i].color.toNSColor()
            control.setImage(Self.swatchImage(color: color), forSegment: i)
        }
    }

    private static func swatchImage(color: NSColor) -> NSImage {
        // 14×14 단색 원 + 미세 1pt 어두운 윤곽 — 다크모드에서도 자기 색이 잘 보이게.
        let size = NSSize(width: 14, height: 14)
        let img = NSImage(size: size)
        img.lockFocus()
        let inset: CGFloat = 0.5
        let rect = NSRect(origin: .zero, size: size).insetBy(dx: inset, dy: inset)
        color.setFill()
        let path = NSBezierPath(ovalIn: rect)
        path.fill()
        NSColor.black.withAlphaComponent(0.25).setStroke()
        path.lineWidth = 1
        path.stroke()
        img.unlockFocus()
        return img
    }

    private static func mouseInputImage() -> NSImage {
        NSImage(systemSymbolName: "computermouse",
                accessibilityDescription: "Ignore Mouse Drawing")
        ?? NSImage(systemSymbolName: "cursorarrow",
                   accessibilityDescription: "Ignore Mouse Drawing")
        ?? NSImage()
    }

    private func syncMouseInputButton() {
        guard let button = mouseInputButton else { return }
        let ignoresMouse = InputSettings.shared.ignoresMouseInput
        button.state = ignoresMouse ? .on : .off
        button.contentTintColor = ignoresMouse ? .controlAccentColor : .secondaryLabelColor
        button.toolTip = ignoresMouse ? "Mouse Drawing Ignored" : "Mouse Drawing Allowed"
    }

    // MARK: - Tool click

    @objc private func toolsChanged(_ sender: NSSegmentedControl) {
        let idx = sender.selectedSegment
        let s = PenSettings.shared

        if idx == 4 {
            showInkFeelPopover(anchor: sender)
            syncToolsControl()
            return
        }

        // action 직전 상태에서 "같은 segment 다시 클릭"인지 판정.
        let wasActivePen = (s.currentTool == .pen && s.currentPenIndex == idx && idx < 3)
        let wasActiveEraser = (s.currentTool == .eraser && idx == 3)
        let sameClick = wasActivePen || wasActiveEraser

        if idx == 3 {
            s.selectEraser()
        } else if (0...2).contains(idx) {
            s.selectPen(idx)
        }

        if sameClick && (0...2).contains(idx) {
            showPenEditorPopover(penIndex: idx, anchor: sender)
        } else {
            dismissPenEditorPopover()
        }
        dismissInkFeelPopover()
    }

    @objc private func toggleMouseInput(_ sender: NSButton) {
        InputSettings.shared.setIgnoresMouseInput(sender.state == .on)
        syncMouseInputButton()
    }

    private func showPenEditorPopover(penIndex: Int, anchor: NSSegmentedControl) {
        dismissPenEditorPopover()
        dismissInkFeelPopover()
        dismissKeymapPopover()
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        let editor = PenEditorView(penIndex: penIndex)
        popover.contentViewController = NSHostingController(rootView: editor)
        // 클릭된 segment 영역 기준으로 popover 띄움. NSSegmentedControl이 segment rect API를 직접
        // 노출하지 않으므로 control 전체 frame을 사용 — popover가 segment 아래쪽 가운데에 뜸.
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
        penEditorPopover = popover
    }

    private func showInkFeelPopover(anchor: NSSegmentedControl) {
        dismissPenEditorPopover()
        dismissInkFeelPopover()
        dismissKeymapPopover()
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = NSHostingController(rootView: InkFeelEditorView())
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
        inkFeelPopover = popover
    }

    @objc private func showKeymapPopover(_ sender: NSButton) {
        dismissPenEditorPopover()
        dismissInkFeelPopover()
        if keymapPopover?.isShown == true {
            dismissKeymapPopover()
            return
        }

        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = NSHostingController(rootView: KeymapSettingsView())
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY)
        keymapPopover = popover
    }

    private func dismissPenEditorPopover() {
        penEditorPopover?.close()
        penEditorPopover = nil
    }

    private func dismissInkFeelPopover() {
        inkFeelPopover?.close()
        inkFeelPopover = nil
    }

    private func dismissKeymapPopover() {
        keymapPopover?.close()
        keymapPopover = nil
    }
}
