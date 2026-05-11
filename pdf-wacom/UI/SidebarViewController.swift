import Cocoa
import PDFKit

protocol SidebarViewControllerDelegate: AnyObject {
    func sidebar(_ vc: SidebarViewController, didChangeCoverIsSinglePage value: Bool)
    func sidebar(_ vc: SidebarViewController, didChangePagesPerSpread value: Int)
    func sidebar(_ vc: SidebarViewController, didSelectPageIndex index: Int)
}

final class SidebarViewController: NSViewController {

    weak var delegate: SidebarViewControllerDelegate?
    weak var document: PDFInkDocument?

    private var pageModeControl: NSSegmentedControl!
    private var coverCheckbox: NSButton!
    private var collectionView: NSCollectionView!
    private var scrollView: NSScrollView!

    private static let thumbItemID = NSUserInterfaceItemIdentifier("thumbItem")

    init(document: PDFInkDocument) {
        self.document = document
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func loadView() {
        let v = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 220, height: 600))
        v.material = .sidebar
        v.blendingMode = .withinWindow
        v.state = .active

        // 섹션 헤더 — 작은 caps small, secondary label color로 시각 위계 표현.
        let modeLabel = NSTextField(labelWithString: "PAGE LAYOUT")
        modeLabel.font = .systemFont(ofSize: 10, weight: .semibold)
        modeLabel.textColor = .tertiaryLabelColor
        modeLabel.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(modeLabel)

        let mode = NSSegmentedControl(labels: ["한 페이지", "두 페이지"],
                                      trackingMode: .selectOne,
                                      target: self,
                                      action: #selector(pageModeChanged(_:)))
        let currentMode = document?.effectivePagesPerSpread ?? 2
        mode.selectedSegment = currentMode == 1 ? 0 : 1
        mode.segmentStyle = .rounded
        mode.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(mode)
        self.pageModeControl = mode

        // Cover 옵션 체크박스 (두 페이지 모드에서만 의미가 있음)
        let cb = NSButton(checkboxWithTitle: "표지를 단독 페이지로",
                          target: self,
                          action: #selector(coverToggled(_:)))
        cb.font = .systemFont(ofSize: 12)
        cb.state = (document?.coverIsSinglePage ?? false) ? .on : .off
        cb.isEnabled = currentMode != 1
        cb.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(cb)
        self.coverCheckbox = cb

        // PAGES 섹션 헤더
        let pagesLabel = NSTextField(labelWithString: "PAGES")
        pagesLabel.font = .systemFont(ofSize: 10, weight: .semibold)
        pagesLabel.textColor = .tertiaryLabelColor
        pagesLabel.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(pagesLabel)

        let sep = NSBox()
        sep.boxType = .separator
        sep.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(sep)

        // 페이지 썸네일 — NSCollectionView 그리드.
        // 사이드바 너비가 늘어나면 한 줄에 들어가는 썸네일 갯수가 자동으로 늘어난다.
        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false

        let layout = NSCollectionViewFlowLayout()
        layout.itemSize = NSSize(width: 100, height: 140)
        layout.minimumInteritemSpacing = 8
        layout.minimumLineSpacing = 10
        layout.sectionInset = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)

        let cv = NSCollectionView()
        cv.collectionViewLayout = layout
        cv.dataSource = self
        cv.delegate = self
        cv.isSelectable = true
        cv.allowsMultipleSelection = false
        cv.backgroundColors = [.clear]
        cv.register(ThumbnailCollectionViewItem.self,
                    forItemWithIdentifier: Self.thumbItemID)

        scroll.documentView = cv
        v.addSubview(scroll)

        self.scrollView = scroll
        self.collectionView = cv

        NSLayoutConstraint.activate([
            modeLabel.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 16),
            modeLabel.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -16),
            modeLabel.topAnchor.constraint(equalTo: v.topAnchor, constant: 14),

            mode.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 16),
            mode.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -16),
            mode.topAnchor.constraint(equalTo: modeLabel.bottomAnchor, constant: 6),

            cb.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 16),
            cb.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -16),
            cb.topAnchor.constraint(equalTo: mode.bottomAnchor, constant: 10),

            sep.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 12),
            sep.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -12),
            sep.topAnchor.constraint(equalTo: cb.bottomAnchor, constant: 14),
            sep.heightAnchor.constraint(equalToConstant: 1),

            pagesLabel.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 16),
            pagesLabel.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -16),
            pagesLabel.topAnchor.constraint(equalTo: sep.bottomAnchor, constant: 12),

            scroll.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: pagesLabel.bottomAnchor, constant: 6),
            scroll.bottomAnchor.constraint(equalTo: v.bottomAnchor),
        ])

        self.view = v
    }

    func reloadThumbnails() {
        collectionView.reloadData()
    }

    @objc private func coverToggled(_ sender: NSButton) {
        let on = (sender.state == .on)
        delegate?.sidebar(self, didChangeCoverIsSinglePage: on)
    }

    @objc private func pageModeChanged(_ sender: NSSegmentedControl) {
        let pages = sender.selectedSegment == 0 ? 1 : 2
        // 한 페이지 모드에서는 표지 옵션이 무의미하므로 disable.
        coverCheckbox.isEnabled = pages != 1
        delegate?.sidebar(self, didChangePagesPerSpread: pages)
    }
}

extension SidebarViewController: NSCollectionViewDataSource {
    func collectionView(_ cv: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        return document?.pdfDocument?.pageCount ?? 0
    }

    func collectionView(_ cv: NSCollectionView,
                        itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = cv.makeItem(withIdentifier: Self.thumbItemID, for: indexPath)
        guard let thumb = item as? ThumbnailCollectionViewItem else { return item }
        if let page = document?.pdfDocument?.page(at: indexPath.item) {
            thumb.configure(page: page, pageIndex: indexPath.item)
        }
        return thumb
    }
}

extension SidebarViewController: NSCollectionViewDelegate {
    func collectionView(_ cv: NSCollectionView,
                        didSelectItemsAt indexPaths: Set<IndexPath>) {
        guard let ip = indexPaths.first else { return }
        delegate?.sidebar(self, didSelectPageIndex: ip.item)
    }
}

// MARK: - ThumbnailCollectionViewItem

final class ThumbnailCollectionViewItem: NSCollectionViewItem {

    private let imageContainer = NSView()
    private let thumbImageView = NSImageView()
    private let pageLabel = NSTextField(labelWithString: "")

    private static let thumbCache = NSCache<NSString, NSImage>()
    private var rasterToken: UInt64 = 0
    private static var tokenCounter: UInt64 = 0

    override func loadView() {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor.clear.cgColor

        imageContainer.translatesAutoresizingMaskIntoConstraints = false
        imageContainer.wantsLayer = true
        imageContainer.layer?.backgroundColor = NSColor.white.cgColor
        imageContainer.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.6).cgColor
        imageContainer.layer?.borderWidth = 0.5
        imageContainer.layer?.cornerRadius = 3
        // 더 명확한 elevation으로 페이지 카드 느낌. shadowPath은 frame 고정이라 첫 load 후 set.
        imageContainer.layer?.shadowOpacity = 0.22
        imageContainer.layer?.shadowRadius = 5
        imageContainer.layer?.shadowOffset = NSSize(width: 0, height: -1.5)
        imageContainer.layer?.shadowColor = NSColor.black.cgColor
        v.addSubview(imageContainer)

        thumbImageView.translatesAutoresizingMaskIntoConstraints = false
        thumbImageView.imageScaling = .scaleProportionallyDown
        imageContainer.addSubview(thumbImageView)

        pageLabel.translatesAutoresizingMaskIntoConstraints = false
        pageLabel.font = .systemFont(ofSize: 11, weight: .medium)
        pageLabel.textColor = .secondaryLabelColor
        pageLabel.alignment = .center
        v.addSubview(pageLabel)

        NSLayoutConstraint.activate([
            imageContainer.topAnchor.constraint(equalTo: v.topAnchor, constant: 6),
            imageContainer.centerXAnchor.constraint(equalTo: v.centerXAnchor),
            imageContainer.widthAnchor.constraint(equalToConstant: 100),
            imageContainer.heightAnchor.constraint(equalToConstant: 120),

            thumbImageView.topAnchor.constraint(equalTo: imageContainer.topAnchor),
            thumbImageView.leadingAnchor.constraint(equalTo: imageContainer.leadingAnchor),
            thumbImageView.trailingAnchor.constraint(equalTo: imageContainer.trailingAnchor),
            thumbImageView.bottomAnchor.constraint(equalTo: imageContainer.bottomAnchor),

            pageLabel.topAnchor.constraint(equalTo: imageContainer.bottomAnchor, constant: 6),
            pageLabel.centerXAnchor.constraint(equalTo: v.centerXAnchor),
            pageLabel.bottomAnchor.constraint(lessThanOrEqualTo: v.bottomAnchor, constant: -2),
        ])

        self.view = v
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        // shadowPath 갱신 — 컨테이너 크기는 고정이지만 첫 layout 후 안전 set.
        imageContainer.layer?.shadowPath = CGPath(
            rect: imageContainer.bounds,
            transform: nil
        )
    }

    func configure(page: PDFPage, pageIndex: Int) {
        pageLabel.stringValue = "\(pageIndex + 1)"
        let docId = page.document.map { ObjectIdentifier($0).hashValue } ?? 0
        let key = "\(docId).\(pageIndex).100x120" as NSString
        if let cached = Self.thumbCache.object(forKey: key) {
            thumbImageView.image = cached
            return
        }
        thumbImageView.image = nil   // 비치볼 방지 — 비우고 background에서 raster.

        Self.tokenCounter &+= 1
        let token = Self.tokenCounter
        rasterToken = token
        let size = NSSize(width: 100, height: 120)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let thumb = page.thumbnail(of: size, for: .mediaBox)
            Self.thumbCache.setObject(thumb, forKey: key)
            DispatchQueue.main.async {
                guard let self = self, self.rasterToken == token else { return }
                self.thumbImageView.image = thumb
            }
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        // 재사용 시 진행 중인 async raster 결과는 버린다.
        Self.tokenCounter &+= 1
        rasterToken = Self.tokenCounter
        thumbImageView.image = nil
        pageLabel.stringValue = ""
        updateSelectionAppearance()
    }

    override var isSelected: Bool {
        didSet { updateSelectionAppearance() }
    }

    private func updateSelectionAppearance() {
        imageContainer.layer?.borderColor = isSelected
            ? NSColor.controlAccentColor.cgColor
            : NSColor.separatorColor.cgColor
        imageContainer.layer?.borderWidth = isSelected ? 2 : 0.5
    }
}
