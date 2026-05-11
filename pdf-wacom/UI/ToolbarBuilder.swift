import Cocoa
import SwiftUI

// host 윈도우 NSToolbar.
// [P1|P2|P3|⌫ Eraser] — 같은 펜을 한 번 더 클릭하면 그 펜 segment 아래에 색·두께 편집 popover.
// 우측: Export PDF.
final class ToolbarBuilder: NSObject, NSToolbarDelegate {

    static let identifier = NSToolbar.Identifier("MainToolbar.v4")

    enum ItemID {
        static let sidebar = NSToolbarItem.Identifier("sidebar")
        static let tools = NSToolbarItem.Identifier("tools")
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
        return toolbar
    }

    private static var delegateKey = "ToolbarBuilderDelegate"

    private weak var toolsControl: NSSegmentedControl?
    private var penEditorPopover: NSPopover?

    // MARK: - NSToolbarDelegate

    func toolbar(_ toolbar: NSToolbar,
                 itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch itemIdentifier {
        case ItemID.sidebar:   return makeSidebarItem()
        case ItemID.tools:     return makeToolsItem()
        case ItemID.exportPDF: return makeExportItem()
        default:               return nil
        }
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [ItemID.sidebar, .space, ItemID.tools, .flexibleSpace, ItemID.exportPDF]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [ItemID.sidebar, ItemID.tools, ItemID.exportPDF, .flexibleSpace, .space]
    }

    // MARK: - Items

    private func makeToolsItem() -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: ItemID.tools)
        item.label = "Tool"
        item.paletteLabel = "Tool"
        // label은 비워두고 image로 통일 — pen 3개는 color swatch, 4번째는 SF Symbol eraser.
        let control = NSSegmentedControl(labels: ["", "", "", ""],
                                         trackingMode: .selectOne,
                                         target: self,
                                         action: #selector(toolsChanged(_:)))
        control.segmentStyle = .texturedRounded
        if let eraserImg = NSImage(systemSymbolName: "eraser",
                                    accessibilityDescription: "Eraser") {
            control.setImage(eraserImg, forSegment: 3)
        }
        control.setWidth(36, forSegment: 0)
        control.setWidth(36, forSegment: 1)
        control.setWidth(36, forSegment: 2)
        control.setWidth(44, forSegment: 3)
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

    private func makeExportItem() -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: ItemID.exportPDF)
        item.label = "Export PDF"
        item.paletteLabel = "Export PDF"
        item.image = NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: "Export PDF")
        item.action = Selector(("exportPDF:"))
        item.target = nil
        return item
    }

    // MARK: - Sync UI

    func syncUI() {
        syncToolsControl()
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

    // MARK: - Tool click

    @objc private func toolsChanged(_ sender: NSSegmentedControl) {
        let idx = sender.selectedSegment
        let s = PenSettings.shared

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
    }

    private func showPenEditorPopover(penIndex: Int, anchor: NSSegmentedControl) {
        dismissPenEditorPopover()
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

    private func dismissPenEditorPopover() {
        penEditorPopover?.close()
        penEditorPopover = nil
    }
}
