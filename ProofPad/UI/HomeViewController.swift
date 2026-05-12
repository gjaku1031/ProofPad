import Cocoa

final class HomeViewController: NSViewController {

    var onOpenDocument: (() -> Void)?
    var onCreateBlankPDF: ((BlankPDFTemplate) -> Void)?
    var onMergePDFs: (() -> Void)?
    var onImagesToPDF: (() -> Void)?
    var onCheckForUpdates: (() -> Void)?
    var onOpenRecent: ((URL) -> Void)?

    private let recentStack = NSStackView()
    private var recentRows: [RecentFileRow] = []
    private var recentStoreObserver: NSObjectProtocol?
    private var recentClickMonitor: Any?

    deinit {
        if let recentStoreObserver {
            NotificationCenter.default.removeObserver(recentStoreObserver)
        }
        if let recentClickMonitor {
            NSEvent.removeMonitor(recentClickMonitor)
        }
    }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 1280, height: 800))
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.clear.cgColor
        view = root

        let content = NSStackView()
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 22
        content.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(content)

        content.addArrangedSubview(makeHeader())

        let body = NSStackView()
        body.orientation = .horizontal
        body.alignment = .top
        body.spacing = 18
        body.translatesAutoresizingMaskIntoConstraints = false
        content.addArrangedSubview(body)

        let recentPanel = makeRecentPanel()
        let toolsPanel = makeToolsPanel()
        body.addArrangedSubview(recentPanel)
        body.addArrangedSubview(toolsPanel)

        let preferredWidth = content.widthAnchor.constraint(equalToConstant: 980)
        preferredWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            content.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            content.topAnchor.constraint(equalTo: root.topAnchor, constant: 72),
            content.leadingAnchor.constraint(greaterThanOrEqualTo: root.leadingAnchor, constant: 40),
            content.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -40),
            preferredWidth,

            recentPanel.widthAnchor.constraint(equalToConstant: 560),
            toolsPanel.widthAnchor.constraint(equalToConstant: 400),
        ])
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        recentStoreObserver = NotificationCenter.default.addObserver(
            forName: RecentPDFStore.didChangeNotification,
            object: RecentPDFStore.shared,
            queue: .main
        ) { [weak self] _ in
            self?.reloadRecentFiles()
        }
        installRecentClickMonitor()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        reloadRecentFiles()
    }

    func reloadRecentFiles() {
        recentStack.arrangedSubviews.forEach {
            recentStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        recentRows.removeAll()

        let recentURLs = RecentPDFStore.shared.recentURLs()

        if recentURLs.isEmpty {
            let empty = makeEmptyRecentLabel()
            recentStack.addArrangedSubview(empty)
            empty.widthAnchor.constraint(equalTo: recentStack.widthAnchor).isActive = true
            return
        }

        for url in recentURLs {
            let row = RecentFileRow(url: url) { [weak self] selectedURL in
                self?.onOpenRecent?(selectedURL)
            }
            recentRows.append(row)
            recentStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: recentStack.widthAnchor).isActive = true
        }
    }

    private func makeHeader() -> NSView {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 14

        let icon = NSImageView()
        icon.image = NSApp.applicationIconImage
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(icon)

        let titleStack = NSStackView()
        titleStack.orientation = .vertical
        titleStack.alignment = .leading
        titleStack.spacing = 2
        stack.addArrangedSubview(titleStack)

        let title = NSTextField(labelWithString: "ProofPad")
        title.font = .systemFont(ofSize: 30, weight: .semibold)
        title.textColor = .labelColor
        titleStack.addArrangedSubview(title)

        let subtitle = NSTextField(labelWithString: "PDF Notes")
        subtitle.font = .systemFont(ofSize: 13.5, weight: .regular)
        subtitle.textColor = .secondaryLabelColor
        titleStack.addArrangedSubview(subtitle)

        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 54),
            icon.heightAnchor.constraint(equalToConstant: 54),
        ])
        return stack
    }

    private func makeRecentPanel() -> NSView {
        let (panel, stack) = makePanel(title: "Recent")

        let openButton = HomeActionButton(
            title: "Open PDF...",
            symbolName: "folder",
            target: self,
            action: #selector(openDocumentTapped)
        )
        stack.addArrangedSubview(openButton)

        let separator = NSBox()
        separator.boxType = .separator
        stack.addArrangedSubview(separator)

        recentStack.orientation = .vertical
        recentStack.alignment = .leading
        recentStack.spacing = 6
        recentStack.translatesAutoresizingMaskIntoConstraints = false

        let scrollContent = FlippedView()
        scrollContent.translatesAutoresizingMaskIntoConstraints = false
        scrollContent.addSubview(recentStack)

        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.documentView = scrollContent
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(scrollView)

        NSLayoutConstraint.activate([
            openButton.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scrollView.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scrollView.heightAnchor.constraint(equalToConstant: 420),

            scrollContent.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            scrollContent.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            scrollContent.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            scrollContent.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            scrollContent.heightAnchor.constraint(greaterThanOrEqualTo: scrollView.contentView.heightAnchor),
            recentStack.leadingAnchor.constraint(equalTo: scrollContent.leadingAnchor),
            recentStack.trailingAnchor.constraint(equalTo: scrollContent.trailingAnchor),
            recentStack.topAnchor.constraint(equalTo: scrollContent.topAnchor),
            recentStack.bottomAnchor.constraint(equalTo: scrollContent.bottomAnchor),
        ])
        reloadRecentFiles()
        return panel
    }

    private func makeToolsPanel() -> NSView {
        let (panel, stack) = makePanel(title: "Tools")

        let newNote = HomeActionButton(
            title: "New Note...",
            symbolName: "square.and.pencil",
            target: self,
            action: #selector(newNoteTapped(_:))
        )
        let mergePDF = HomeActionButton(
            title: "Merge PDFs...",
            symbolName: "doc.on.doc",
            target: self,
            action: #selector(mergePDFsTapped)
        )
        let imagesToPDF = HomeActionButton(
            title: "Images to PDF...",
            symbolName: "photo.on.rectangle",
            target: self,
            action: #selector(imagesToPDFTapped)
        )
        let checkForUpdates = HomeActionButton(
            title: "Check for Updates...",
            symbolName: "arrow.down.circle",
            target: self,
            action: #selector(checkForUpdatesTapped)
        )

        for button in [newNote, mergePDF, imagesToPDF, checkForUpdates] {
            stack.addArrangedSubview(button)
            button.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        return panel
    }

    private func makePanel(title: String) -> (NSVisualEffectView, NSStackView) {
        let panel = NSVisualEffectView()
        panel.material = .contentBackground
        panel.blendingMode = .withinWindow
        panel.state = .active
        panel.wantsLayer = true
        panel.layer?.cornerRadius = 8
        panel.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 18, bottom: 18, right: 18)
        stack.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(stack)

        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = .secondaryLabelColor
        stack.addArrangedSubview(label)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
            stack.topAnchor.constraint(equalTo: panel.topAnchor),
            stack.bottomAnchor.constraint(equalTo: panel.bottomAnchor),
        ])

        return (panel, stack)
    }

    private func makeEmptyRecentLabel() -> NSView {
        let label = NSTextField(labelWithString: "No Recent Files")
        label.font = .systemFont(ofSize: 13)
        label.textColor = .tertiaryLabelColor
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)
        NSLayoutConstraint.activate([
            container.heightAnchor.constraint(equalToConstant: 120),
            label.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor),
        ])
        return container
    }

    private func installRecentClickMonitor() {
        recentClickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self,
                  self.view.window === event.window else {
                return event
            }

            guard let window = self.view.window,
                  event.window == nil || event.window === window else {
                return event
            }

            for row in self.recentRows where row.window === window {
                let rowPoint = row.convert(event.locationInWindow, from: nil)
                if row.bounds.contains(rowPoint) {
                    row.openFromMouseClick()
                    return nil
                }
            }
            return event
        }
    }

    @objc private func openDocumentTapped() {
        onOpenDocument?()
    }

    @objc private func newNoteTapped(_ sender: NSButton) {
        let menu = NSMenu(title: "New Note")
        for template in BlankPDFTemplate.allCases {
            let item = NSMenuItem(title: template.title,
                                  action: #selector(templateMenuItemTapped(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = template
            item.image = NSImage(systemSymbolName: template.systemImageName,
                                 accessibilityDescription: template.title)
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    @objc private func templateMenuItemTapped(_ sender: NSMenuItem) {
        guard let template = sender.representedObject as? BlankPDFTemplate else { return }
        onCreateBlankPDF?(template)
    }

    @objc private func mergePDFsTapped() {
        onMergePDFs?()
    }

    @objc private func imagesToPDFTapped() {
        onImagesToPDF?()
    }

    @objc private func checkForUpdatesTapped() {
        onCheckForUpdates?()
    }
}

private class HomeActionButton: NSButton {
    init(title: String, symbolName: String, target: AnyObject?, action: Selector?) {
        super.init(frame: .zero)
        self.title = title
        self.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: title)
        self.imagePosition = .imageLeading
        self.imageScaling = .scaleProportionallyDown
        self.bezelStyle = .rounded
        self.controlSize = .large
        self.font = .systemFont(ofSize: 14, weight: .medium)
        self.target = target
        self.action = action
        self.translatesAutoresizingMaskIntoConstraints = false
        self.setContentHuggingPriority(.defaultLow, for: .horizontal)
        heightAnchor.constraint(equalToConstant: 42).isActive = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

final class RecentFileRow: NSControl {
    private let url: URL
    private let onOpen: (URL) -> Void
    private var isHovering = false
    private var isPressed = false

    init(url: URL, onOpen: @escaping (URL) -> Void) {
        self.url = url
        self.onOpen = onOpen
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 7
        toolTip = url.path
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(url.deletingPathExtension().lastPathComponent)

        let icon = NonHitTestingImageView()
        icon.image = NSWorkspace.shared.icon(forFile: url.path)
        icon.imageScaling = .scaleProportionallyDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        addSubview(icon)

        let textStack = NSStackView()
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 1
        textStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(textStack)

        let titleLabel = NonHitTestingLabel(labelWithString: url.deletingPathExtension().lastPathComponent)
        titleLabel.font = .systemFont(ofSize: 13.5, weight: .medium)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        textStack.addArrangedSubview(titleLabel)

        let pathLabel = NonHitTestingLabel(labelWithString: url.deletingLastPathComponent().path)
        pathLabel.font = .systemFont(ofSize: 11.5)
        pathLabel.textColor = .secondaryLabelColor
        pathLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.maximumNumberOfLines = 1
        textStack.addArrangedSubview(pathLabel)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 48),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 28),
            icon.heightAnchor.constraint(equalToConstant: 28),

            textStack.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            textStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            textStack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var acceptsFirstResponder: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override var isHighlighted: Bool {
        didSet { updateBackground() }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(point) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        isPressed = true
        updateBackground()
    }

    override func mouseUp(with event: NSEvent) {
        let shouldOpen = bounds.contains(convert(event.locationInWindow, from: nil))
        isPressed = false
        updateBackground()
        if shouldOpen {
            openRecent()
        }
    }

    override func accessibilityPerformPress() -> Bool {
        openRecent()
        return true
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        updateBackground()
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        updateBackground()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.activeInKeyWindow, .mouseEnteredAndExited, .inVisibleRect],
                                       owner: self,
                                       userInfo: nil))
    }

    @objc private func openRecent() {
        onOpen(url)
    }

    func openFromMouseClick() {
        isPressed = true
        updateBackground()
        openRecent()
        isPressed = false
        updateBackground()
    }

    private func updateBackground() {
        if isPressed || isHighlighted {
            layer?.backgroundColor = NSColor.selectedContentBackgroundColor.withAlphaComponent(0.22).cgColor
        } else if isHovering {
            layer?.backgroundColor = NSColor.unemphasizedSelectedContentBackgroundColor.withAlphaComponent(0.72).cgColor
        } else {
            layer?.backgroundColor = NSColor.clear.cgColor
        }
    }
}

private final class NonHitTestingImageView: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

private final class NonHitTestingLabel: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? {
        return nil
    }
}
