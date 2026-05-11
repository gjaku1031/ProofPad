import Cocoa

// 메뉴/단축키와 SpreadStripView를 연결하는 컨트롤러.
// ⌘+/⌘-는 1.25배수로 step. ⌘0은 Fit Width로 리셋.
final class ZoomController {

    private weak var stripView: SpreadStripView?

    init(stripView: SpreadStripView) {
        self.stripView = stripView
    }

    func zoomIn() { stripView?.zoomBy(factor: 1.25) }
    func zoomOut() { stripView?.zoomBy(factor: 1.0 / 1.25) }

    func setMode(_ mode: SpreadStripView.ZoomMode) {
        stripView?.zoomMode = mode
    }

    func actualSize() {
        stripView?.zoomMode = .custom(1.0)
    }

    func fitWidth() { setMode(.fitWidth) }
    func fitHeight() { setMode(.fitHeight) }
    func fitPage() { setMode(.fitPage) }
}
