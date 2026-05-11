import Cocoa

// 탭 chip을 horizontal로 layout. 자리 남으면 max width(220), 많아지면 균등 압축(min 90).
// titlebar 영역 .bottom accessory에 부착되어 toolbar와 함께 fullscreen에서 auto-hide.
final class AppTabBarView: NSView {

    weak var host: TabHostWindowController?

    private var chips: [TabChipView] = []
    private let homeButton = TabHomeButton()
    private let scrollView = NSScrollView()
    private let chipContainerView = NSView()

    private let horizontalMargin: CGFloat = 12
    private let homeButtonWidth: CGFloat = 34
    private let homeSpacing: CGFloat = 8
    private let chipSpacing: CGFloat = 4
    private let maxChipWidth: CGFloat = 220
    private let minChipWidth: CGFloat = 90
    private var dragSession: TabDragSession?

    private struct TabLayoutMetrics {
        var chipWidth: CGFloat
        var chipHeight: CGFloat
        var contentWidth: CGFloat
    }

    private struct TabDragSession {
        weak var chip: TabChipView?
        let document: PDFInkDocument
        let sourceIndex: Int
        let startFrame: NSRect
        let startLocationInWindow: NSPoint
        var targetIndex: Int
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        homeButton.onClick = { [weak self] in
            self?.host?.showHome(nil)
        }
        addSubview(homeButton)

        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.documentView = chipContainerView
        addSubview(scrollView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    override var mouseDownCanMoveWindow: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        // 탭바와 content area 사이 hairline. 1px subtle.
        let line = NSBezierPath()
        line.move(to: NSPoint(x: 0, y: 0.5))
        line.line(to: NSPoint(x: bounds.width, y: 0.5))
        NSColor.separatorColor.withAlphaComponent(0.6).setStroke()
        line.lineWidth = 1
        line.stroke()
    }

    func reload() {
        guard let host = host else { return }
        dragSession = nil
        chips.forEach { $0.removeFromSuperview() }
        homeButton.isHomeActive = host.activeDocument == nil
        chips = host.documents.map { doc in
            let chip = TabChipView(document: doc, isActive: doc === host.activeDocument)
            chip.onSelect = { [weak host] in host?.activate(document: doc) }
            chip.onClose = { [weak host] in
                doc.canClose(
                    withDelegate: TabChipCloseDelegate.shared,
                    shouldClose: #selector(TabChipCloseDelegate.documentShouldClose(_:shouldClose:contextInfo:)),
                    contextInfo: nil
                )
                _ = host  // capture
            }
            chip.onBeginDrag = { [weak self, weak chip] startLocation in
                guard let chip else { return }
                self?.beginInteractiveDrag(chip: chip, document: doc, startLocationInWindow: startLocation)
            }
            chip.onContinueDrag = { [weak self] event in
                self?.updateInteractiveDrag(with: event)
            }
            chip.onEndDrag = { [weak self] in
                self?.endInteractiveDrag()
            }
            chipContainerView.addSubview(chip)
            return chip
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let chipAreaX = horizontalMargin + homeButtonWidth + homeSpacing
        let chipAreaWidth = max(0, bounds.width - chipAreaX - horizontalMargin)
        let barHeight = bounds.height - 4
        homeButton.frame = NSRect(x: horizontalMargin, y: 2, width: homeButtonWidth, height: barHeight)
        scrollView.frame = NSRect(x: chipAreaX, y: 2, width: chipAreaWidth, height: barHeight)

        layoutChips(animated: false)
    }

    private func currentLayoutMetrics() -> TabLayoutMetrics {
        let n = chips.count
        let availWidth = chipAreaWidth
        guard n > 0 else {
            return TabLayoutMetrics(
                chipWidth: minChipWidth,
                chipHeight: scrollView.contentView.bounds.height,
                contentWidth: availWidth
            )
        }
        let totalSpacing = chipSpacing * CGFloat(max(n - 1, 0))
        var chipWidth = (availWidth - totalSpacing) / CGFloat(n)
        chipWidth = min(chipWidth, maxChipWidth)
        chipWidth = max(chipWidth, minChipWidth)
        let contentWidth = max(availWidth, chipWidth * CGFloat(n) + totalSpacing)
        let chipHeight = scrollView.contentView.bounds.height
        return TabLayoutMetrics(chipWidth: chipWidth, chipHeight: chipHeight, contentWidth: contentWidth)
    }

    private var chipAreaWidth: CGFloat {
        max(0, bounds.width - (horizontalMargin + homeButtonWidth + homeSpacing) - horizontalMargin)
    }

    private func layoutChips(animated: Bool) {
        let n = chips.count
        guard n > 0 else {
            chipContainerView.frame = NSRect(x: 0, y: 0, width: chipAreaWidth, height: scrollView.contentView.bounds.height)
            return
        }
        let metrics = currentLayoutMetrics()
        chipContainerView.frame = NSRect(x: 0, y: 0, width: metrics.contentWidth, height: metrics.chipHeight)

        let frames = targetFrames(metrics: metrics)
        apply(frames: frames, animated: animated, duration: 0.13)
    }

    private func targetFrames(metrics: TabLayoutMetrics) -> [(TabChipView, NSRect)] {
        guard let dragSession, let draggedChip = dragSession.chip else {
            return chips.enumerated().map { index, chip in
                (chip, frameForSlot(index, metrics: metrics))
            }
        }

        var frames: [(TabChipView, NSRect)] = []
        var compactIndex = 0
        for chip in chips where chip !== draggedChip {
            let slot = compactIndex >= dragSession.targetIndex ? compactIndex + 1 : compactIndex
            frames.append((chip, frameForSlot(slot, metrics: metrics)))
            compactIndex += 1
        }
        return frames
    }

    private func frameForSlot(_ index: Int, metrics: TabLayoutMetrics) -> NSRect {
        NSRect(
            x: CGFloat(index) * (metrics.chipWidth + chipSpacing),
            y: 2,
            width: metrics.chipWidth,
            height: metrics.chipHeight
        )
    }

    private func apply(frames: [(TabChipView, NSRect)], animated: Bool, duration: TimeInterval) {
        guard animated else {
            for (chip, frame) in frames {
                chip.frame = frame
            }
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            for (chip, frame) in frames {
                chip.animator().frame = frame
            }
        }
    }

    private func beginInteractiveDrag(chip: TabChipView,
                                      document: PDFInkDocument,
                                      startLocationInWindow: NSPoint) {
        guard dragSession == nil,
              let sourceIndex = chips.firstIndex(where: { $0 === chip }) else { return }
        dragSession = TabDragSession(
            chip: chip,
            document: document,
            sourceIndex: sourceIndex,
            startFrame: chip.frame,
            startLocationInWindow: startLocationInWindow,
            targetIndex: sourceIndex
        )
        chip.setDraggingAppearance(true)
        NSCursor.closedHand.set()
    }

    private func updateInteractiveDrag(with event: NSEvent) {
        guard var session = dragSession, let chip = session.chip else { return }

        let metrics = currentLayoutMetrics()
        let start = chipContainerView.convert(session.startLocationInWindow, from: nil)
        let current = chipContainerView.convert(event.locationInWindow, from: nil)
        let deltaX = current.x - start.x
        let deltaY = max(-5, min(5, current.y - start.y))

        var frame = session.startFrame
        frame.origin.x = session.startFrame.origin.x + deltaX
        frame.origin.y = session.startFrame.origin.y + deltaY

        let minX = -metrics.chipWidth * 0.45
        let maxX = max(minX, metrics.contentWidth - metrics.chipWidth * 0.55)
        frame.origin.x = min(max(frame.origin.x, minX), maxX)
        chip.frame = frame

        autoscrollIfNeeded(for: frame)

        let targetIndex = targetIndex(forDraggedMidX: frame.midX, metrics: metrics)
        if targetIndex != session.targetIndex {
            session.targetIndex = targetIndex
            dragSession = session
            layoutChips(animated: true)
        } else {
            dragSession = session
        }
        NSCursor.closedHand.set()
    }

    private func targetIndex(forDraggedMidX midX: CGFloat, metrics: TabLayoutMetrics) -> Int {
        guard !chips.isEmpty else { return 0 }
        for index in chips.indices {
            if midX <= frameForSlot(index, metrics: metrics).midX {
                return index
            }
        }
        return max(chips.count - 1, 0)
    }

    private func autoscrollIfNeeded(for draggedFrame: NSRect) {
        let clipView = scrollView.contentView
        let visible = clipView.bounds
        let maxOffset = max(0, chipContainerView.bounds.width - visible.width)
        guard maxOffset > 0 else { return }

        let edgePadding: CGFloat = 36
        var origin = visible.origin
        if draggedFrame.maxX > visible.maxX - edgePadding {
            origin.x += min(18, draggedFrame.maxX - (visible.maxX - edgePadding))
        } else if draggedFrame.minX < visible.minX + edgePadding {
            origin.x -= min(18, (visible.minX + edgePadding) - draggedFrame.minX)
        }
        origin.x = min(max(origin.x, 0), maxOffset)
        guard abs(origin.x - visible.origin.x) > 0.5 else { return }
        clipView.scroll(to: origin)
        scrollView.reflectScrolledClipView(clipView)
    }

    private func endInteractiveDrag() {
        guard let session = dragSession, let chip = session.chip else {
            dragSession = nil
            return
        }
        let targetIndex = session.targetIndex
        let metrics = currentLayoutMetrics()
        let finalFrame = targetIndex == session.sourceIndex
            ? session.startFrame
            : frameForSlot(targetIndex, metrics: metrics)
        dragSession = nil

        let normalFrames = targetIndex == session.sourceIndex
            ? targetFrames(metrics: metrics)
            : []

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.11
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            chip.animator().frame = finalFrame
            for (otherChip, frame) in normalFrames where otherChip !== chip {
                otherChip.animator().frame = frame
            }
        } completionHandler: { [weak self, weak chip] in
            chip?.setDraggingAppearance(false)
            guard let self else { return }
            if targetIndex != session.sourceIndex {
                self.host?.moveTab(document: session.document, toFinalIndex: targetIndex)
            } else {
                self.needsLayout = true
            }
        }
    }
}

final class TabHomeButton: NSButton {
    var onClick: (() -> Void)?
    var isHomeActive = false {
        didSet { updateBackground() }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 7
        isBordered = false
        bezelStyle = .accessoryBarAction
        image = NSImage(systemSymbolName: "house", accessibilityDescription: "Home")
        imageScaling = .scaleProportionallyDown
        contentTintColor = .secondaryLabelColor
        toolTip = "Home"
        target = self
        action = #selector(clicked)
        updateBackground()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    override var mouseDownCanMoveWindow: Bool { false }

    @objc private func clicked() {
        onClick?()
    }

    private func updateBackground() {
        if isHomeActive {
            layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.72).cgColor
            contentTintColor = .labelColor
        } else {
            layer?.backgroundColor = NSColor.clear.cgColor
            contentTintColor = .secondaryLabelColor
        }
    }
}

final class TabChipView: NSView {
    private let label = NSTextField(labelWithString: "")
    private let closeButton = NSButton()
    private let document: PDFInkDocument
    private let isActive: Bool
    private let isDirty: Bool
    private var isHovering = false
    private var dragStartLocationInWindow: NSPoint?
    private var isDraggingTab = false
    var onSelect: (() -> Void)?
    var onClose: (() -> Void)?
    var onBeginDrag: ((NSPoint) -> Void)?
    var onContinueDrag: ((NSEvent) -> Void)?
    var onEndDrag: (() -> Void)?

    init(document: PDFInkDocument, isActive: Bool) {
        self.document = document
        self.isActive = isActive
        self.isDirty = document.isDocumentEdited
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 7

        let displayName = document.displayName ?? "Untitled"
        // dirty bullet은 label 안 아니고 별도 시각으로 처리하지 않음 — 단순화. 텍스트 옆 작은 dot.
        let attributed = NSMutableAttributedString(string: displayName)
        if isDirty {
            attributed.append(NSAttributedString(
                string: "  ●",
                attributes: [
                    .foregroundColor: NSColor.controlAccentColor,
                    .font: NSFont.systemFont(ofSize: 8)
                ]
            ))
        }
        label.attributedStringValue = attributed
        label.font = .systemFont(ofSize: 12.5,
                                  weight: isActive ? .medium : .regular)
        label.textColor = isActive ? .labelColor : .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        // 닫기 버튼 — active 또는 hover 시에만 노출. SF Symbol 사용.
        closeButton.isBordered = false
        closeButton.bezelStyle = .accessoryBarAction
        closeButton.image = NSImage(systemSymbolName: "xmark",
                                     accessibilityDescription: "Close tab")
        closeButton.imageScaling = .scaleProportionallyDown
        closeButton.contentTintColor = .secondaryLabelColor
        closeButton.target = self
        closeButton.action = #selector(closeTapped)
        closeButton.isHidden = !isActive
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(closeButton)

        // 초기 frame이 0×0인 상태에서 자체 width constraint와 충돌하지 않도록
        // priority를 살짝 내려 자동 layout이 안전하게 깨질 수 있게 한다.
        let labelLeading = label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12)
        let labelTrailing = label.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -6)
        let closeTrailing = closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8)
        labelLeading.priority = .defaultHigh
        labelTrailing.priority = .defaultHigh
        closeTrailing.priority = .defaultHigh
        NSLayoutConstraint.activate([
            labelLeading,
            labelTrailing,
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeTrailing,
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 16),
            closeButton.heightAnchor.constraint(equalToConstant: 16),
        ])

        updateBackground()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    override var mouseDownCanMoveWindow: Bool { false }

    func setDraggingAppearance(_ isDragging: Bool) {
        alphaValue = isDragging ? 0.96 : 1
        layer?.zPosition = isDragging ? 100 : 0
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = isDragging ? 0.22 : 0
        layer?.shadowRadius = isDragging ? 8 : 0
        layer?.shadowOffset = NSSize(width: 0, height: -2)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        updateBackground()
        if !isActive { closeButton.isHidden = false }
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        updateBackground()
        if !isActive { closeButton.isHidden = true }
    }

    private func updateBackground() {
        if isActive {
            layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.72).cgColor
        } else if isHovering {
            layer?.backgroundColor = NSColor.unemphasizedSelectedContentBackgroundColor.withAlphaComponent(0.72).cgColor
        } else {
            layer?.backgroundColor = NSColor.clear.cgColor
        }
    }

    override func mouseDown(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        if !closeButton.frame.contains(local) {
            dragStartLocationInWindow = event.locationInWindow
            isDraggingTab = false
        } else {
            super.mouseDown(with: event)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStartLocationInWindow else {
            super.mouseDragged(with: event)
            return
        }
        let distance = hypot(event.locationInWindow.x - start.x,
                             event.locationInWindow.y - start.y)
        guard distance >= 6 else { return }
        if !isDraggingTab {
            isDraggingTab = true
            onBeginDrag?(start)
        }
        onContinueDrag?(event)
        NSCursor.closedHand.set()
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            dragStartLocationInWindow = nil
            isDraggingTab = false
        }
        if isDraggingTab {
            onEndDrag?()
        } else if dragStartLocationInWindow != nil {
            onSelect?()
        }
    }

    @objc private func closeTapped() {
        onClose?()
    }
}

// canClose 콜백 NSObject delegate (4-arg selector signature).
final class TabChipCloseDelegate: NSObject {
    static let shared = TabChipCloseDelegate()
    @objc func documentShouldClose(_ doc: NSDocument, shouldClose: Bool, contextInfo: UnsafeMutableRawPointer?) {
        guard shouldClose, let nd = doc as? PDFInkDocument else { return }
        TabHostWindowController.shared.remove(document: nd)
        nd.close()
    }
}
