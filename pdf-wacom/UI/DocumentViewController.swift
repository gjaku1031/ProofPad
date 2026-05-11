import Cocoa
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - DocumentViewController
//
// 한 NoteDocument를 표시하는 NSViewController. 탭 하나 = 이 인스턴스 하나.
// TabHostWindowController가 활성 탭의 viewController만 child VC로 add/remove한다.
//
// === View 계층 ===
//   container (root)
//     └── NSSplitView (vertical, sidebar | content)
//         ├── SidebarViewController.view  — 페이지 모드 토글 + 표지 옵션 + 썸네일 그리드(NSCollectionView)
//         └── content area
//             └── NSScrollView
//                 └── SpreadStripView (documentView)
//                     └── SpreadView × N
//                         └── PageView × 2 (펼침면) or × 1 (단일 페이지 모드)
//                             ├── PDFPageBackgroundView (PDF raster)
//                             └── StrokeCanvasView (펜 입력 + 렌더)
//
// === 책임 ===
//   - Spread layout 갱신 (manifest.coverIsSinglePage / pagesPerSpread 변경 시 reloadSpreads)
//   - ZoomController + SpreadStripView 연결
//   - 메뉴/툴바 selector(zoomIn, fitWidth, exportPDF, …) 직접 구현 — TabHostWindowController가 active VC로 forward.
//   - Sidebar toggle(`toggleDocumentSidebar:`) — divider 0 ↔ 저장된 width 애니메이션.
//   - ⌘G 페이지 점프 시트(SwiftUI hosting).
//   - Export PDF (PDFFlattenExporter).
final class DocumentViewController: NSViewController, SidebarViewControllerDelegate {

    private weak var document: NoteDocument?
    private let toolController = ToolController()
    private var scrollView: NSScrollView!
    private var stripView: SpreadStripView!
    private var sidebar: SidebarViewController!
    private var splitView: NSSplitView!
    private var sidebarSavedWidth: CGFloat = 220
    private var jumpHost: NSHostingController<PageJumpView>?
    private var zoomController: ZoomController!

    init(document: NoteDocument) {
        self.document = document
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func loadView() {
        let containerSize = NSSize(width: 1280, height: 800)
        let container = NSView(frame: NSRect(origin: .zero, size: containerSize))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        // NSSplitView (sidebar | content)
        let split = NSSplitView(frame: container.bounds)
        split.autoresizingMask = [.width, .height]
        split.isVertical = true
        split.dividerStyle = .thin
        split.delegate = self
        self.splitView = split

        // Sidebar
        if let doc = document {
            sidebar = SidebarViewController(document: doc)
            sidebar.delegate = self
            addChild(sidebar)
            split.addSubview(sidebar.view)
        }

        // Content area (scrollView + stripView)
        let contentArea = NSView()
        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.backgroundColor = NSColor.windowBackgroundColor

        let strip = SpreadStripView()
        strip.frame = NSRect(x: 0, y: 0, width: 800, height: 100)
        strip.autoresizingMask = .width
        scroll.documentView = strip

        contentArea.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: contentArea.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: contentArea.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: contentArea.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: contentArea.bottomAnchor),
        ])
        split.addSubview(contentArea)

        container.addSubview(split)
        view = container

        self.scrollView = scroll
        self.stripView = strip
        self.zoomController = ZoomController(stripView: strip)

        reloadSpreads()

        // Sidebar 초기 폭
        DispatchQueue.main.async {
            split.setPosition(220, ofDividerAt: 0)
        }
    }

    private func reloadSpreads() {
        guard let doc = document, let pdf = doc.pdfDocument else { return }
        let onChange: () -> Void = { [weak doc] in
            doc?.updateChangeCount(.changeDone)
        }
        let pagesPerSpread = doc.manifest.effectivePagesPerSpread
        stripView.pagesPerSpread = pagesPerSpread
        stripView.setSpreads(
            Spread.pair(pdf,
                        coverIsSinglePage: doc.manifest.coverIsSinglePage,
                        pagesPerSpread: pagesPerSpread),
            document: doc,
            toolController: toolController,
            onChange: onChange
        )
        sidebar?.reloadThumbnails()
    }

    // MARK: - SidebarViewControllerDelegate

    func sidebar(_ vc: SidebarViewController, didChangeCoverIsSinglePage value: Bool) {
        document?.setCoverIsSinglePage(value)
        reloadSpreads()
    }

    func sidebar(_ vc: SidebarViewController, didChangePagesPerSpread value: Int) {
        document?.setPagesPerSpread(value)
        reloadSpreads()
    }

    func sidebar(_ vc: SidebarViewController, didSelectPageIndex index: Int) {
        stripView.scroll(toPageIndex: index)
    }

    // MARK: - Page Jump (⌘G)

    @objc func goToPage(_ sender: Any?) {
        guard let pdf = document?.pdfDocument else { return }
        let pageCount = pdf.pageCount
        guard pageCount > 0 else { return }

        let view = PageJumpView(
            pageCount: pageCount,
            onConfirm: { [weak self] index in
                self?.dismissJump()
                self?.stripView.scroll(toPageIndex: index)
            },
            onCancel: { [weak self] in
                self?.dismissJump()
            }
        )
        let host = NSHostingController(rootView: view)
        jumpHost = host
        presentAsSheet(host)
    }

    private func dismissJump() {
        if let host = jumpHost {
            dismiss(host)
            jumpHost = nil
        }
    }

    // MARK: - Zoom actions

    @objc func zoomIn(_ sender: Any?) { zoomController.zoomIn() }
    @objc func zoomOut(_ sender: Any?) { zoomController.zoomOut() }
    @objc func fitWidth(_ sender: Any?) { zoomController.fitWidth() }
    @objc func fitHeight(_ sender: Any?) { zoomController.fitHeight() }
    @objc func fitPage(_ sender: Any?) { zoomController.fitPage() }
    @objc func actualSize(_ sender: Any?) { zoomController.actualSize() }

    // MARK: - Spread navigation (방향키)

    @objc func scrollToNextSpread(_ sender: Any?) { stripView.scrollToNextSpread() }
    @objc func scrollToPreviousSpread(_ sender: Any?) { stripView.scrollToPreviousSpread() }

    // MARK: - Export PDF

    // MARK: - Sidebar toggle

    @objc func toggleDocumentSidebar(_ sender: Any?) {
        guard let split = splitView, let sidebarView = sidebar?.view else { return }
        let target: CGFloat
        if split.isSubviewCollapsed(sidebarView) {
            target = sidebarSavedWidth
        } else {
            sidebarSavedWidth = max(sidebarView.frame.width, 200)
            target = 0
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.allowsImplicitAnimation = true
            split.setPosition(target, ofDividerAt: 0)
            split.layoutSubtreeIfNeeded()
        }
    }

    @objc func exportPDF(_ sender: Any?) {
        guard let doc = document, let window = view.window else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        let baseName = doc.displayName ?? "Note"
        panel.nameFieldStringValue = baseName + ".pdf"
        panel.canCreateDirectories = true
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try PDFFlattenExporter.export(document: doc, to: url)
            } catch {
                let alert = NSAlert(error: error)
                alert.runModal()
            }
        }
    }
}

extension DocumentViewController: NSSplitViewDelegate {
    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        return 180
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        // 썸네일이 한 줄에 4~5개까지 보이도록 충분히 넓힘.
        return 640
    }

    func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool {
        return subview == sidebar?.view
    }
}
