import Cocoa

// host 윈도우의 contentViewController. 활성 도큐먼트 컨테이너만 관리.
// 탭바는 TabHostWindowController가 직접 소유 → NSTitlebarAccessoryViewController로 부착.
// (풀스크린에서 toolbar와 자동 동기화 숨김/표시.)
final class HostContentViewController: NSViewController {

    let containerView: NSView
    private weak var activeChild: NSViewController?

    init() {
        self.containerView = NSView(frame: .zero)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func loadView() {
        let v = NSView(frame: NSRect(x: 0, y: 0, width: 1280, height: 800))
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        v.addSubview(containerView)
        view = v
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        containerView.frame = view.bounds
        if let active = activeChild {
            active.view.frame = containerView.bounds
        }
    }

    func setActive(_ vc: NSViewController?) {
        if let old = activeChild {
            old.view.removeFromSuperview()
            old.removeFromParent()
        }
        if let vc = vc {
            addChild(vc)
            vc.view.autoresizingMask = [.width, .height]
            vc.view.frame = containerView.bounds
            containerView.addSubview(vc.view)
            activeChild = vc
        }
    }
}
