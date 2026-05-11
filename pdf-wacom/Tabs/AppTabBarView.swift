import Cocoa

// 탭 chip을 horizontal로 layout. 자리 남으면 max width(220), 많아지면 균등 압축(min 90).
// titlebar 영역 .bottom accessory에 부착되어 toolbar와 함께 fullscreen에서 auto-hide.
final class AppTabBarView: NSView {

    weak var host: TabHostWindowController?

    private var chips: [TabChipView] = []

    private let horizontalMargin: CGFloat = 12
    private let chipSpacing: CGFloat = 4
    private let maxChipWidth: CGFloat = 220
    private let minChipWidth: CGFloat = 90

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        // titlebar 영역과 톤을 맞춤 — 약간 더 가라앉은 배경. 시스템 windowBackgroundColor는 light/dark 자동.
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

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
        chips.forEach { $0.removeFromSuperview() }
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
            addSubview(chip)
            return chip
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let n = chips.count
        guard n > 0 else { return }
        let availWidth = bounds.width - horizontalMargin * 2
        let totalSpacing = chipSpacing * CGFloat(max(n - 1, 0))
        var chipWidth = (availWidth - totalSpacing) / CGFloat(n)
        chipWidth = min(chipWidth, maxChipWidth)
        chipWidth = max(chipWidth, minChipWidth)
        let chipHeight = bounds.height - 4
        var x: CGFloat = horizontalMargin
        for chip in chips {
            chip.frame = NSRect(x: x, y: 2, width: chipWidth, height: chipHeight)
            x += chipWidth + chipSpacing
        }
    }
}

final class TabChipView: NSView {
    private let label = NSTextField(labelWithString: "")
    private let closeButton = NSButton()
    private let isActive: Bool
    private let isDirty: Bool
    private var isHovering = false
    var onSelect: (() -> Void)?
    var onClose: (() -> Void)?

    init(document: NoteDocument, isActive: Bool) {
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
            // 활성 탭 — controlBackgroundColor (보통 흰색)로 toolbar에서 분리되는 느낌.
            // accent 색을 절제하고 contrast로 활성 표시.
            layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        } else if isHovering {
            layer?.backgroundColor = NSColor.unemphasizedSelectedContentBackgroundColor.cgColor
        } else {
            layer?.backgroundColor = NSColor.clear.cgColor
        }
    }

    override func mouseDown(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        if !closeButton.frame.contains(local) {
            onSelect?()
        } else {
            super.mouseDown(with: event)
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
        guard shouldClose, let nd = doc as? NoteDocument else { return }
        TabHostWindowController.shared.remove(document: nd)
        nd.close()
    }
}
