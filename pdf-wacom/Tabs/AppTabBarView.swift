import Cocoa

// 탭 chip을 horizontal로 layout. 자리 남으면 max width(200), 많아지면 균등 압축(min 80).
final class AppTabBarView: NSView {

    weak var host: TabHostWindowController?

    private var chips: [TabChipView] = []

    private let horizontalMargin: CGFloat = 8
    private let chipSpacing: CGFloat = 4
    private let maxChipWidth: CGFloat = 200
    private let minChipWidth: CGFloat = 80

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let line = NSBezierPath()
        line.move(to: NSPoint(x: 0, y: 0.5))
        line.line(to: NSPoint(x: bounds.width, y: 0.5))
        NSColor.separatorColor.setStroke()
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
    var onSelect: (() -> Void)?
    var onClose: (() -> Void)?

    init(document: NoteDocument, isActive: Bool) {
        self.isActive = isActive
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        if isActive {
            layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.15).cgColor
            layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.5).cgColor
            layer?.borderWidth = 1
        } else {
            layer?.backgroundColor = NSColor.controlColor.cgColor
        }

        var displayName = document.displayName ?? "Untitled"
        if document.isDocumentEdited { displayName += " •" }
        label.stringValue = displayName
        label.font = .systemFont(ofSize: 12, weight: isActive ? .semibold : .regular)
        label.textColor = isActive ? .controlAccentColor : .labelColor
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        closeButton.bezelStyle = .accessoryBarAction
        closeButton.isBordered = false
        closeButton.title = "✕"
        closeButton.font = .systemFont(ofSize: 11)
        closeButton.target = self
        closeButton.action = #selector(closeTapped)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(closeButton)

        // 초기 frame이 0×0인 상태에서 자체 width constraint와 충돌하지 않도록
        // priority를 살짝 내려 자동 layout이 안전하게 깨질 수 있게 한다.
        let labelLeading = label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10)
        let labelTrailing = label.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -6)
        let closeTrailing = closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6)
        labelLeading.priority = .defaultHigh
        labelTrailing.priority = .defaultHigh
        closeTrailing.priority = .defaultHigh
        NSLayoutConstraint.activate([
            labelLeading,
            labelTrailing,
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeTrailing,
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 18),
            closeButton.heightAnchor.constraint(equalToConstant: 18),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

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
