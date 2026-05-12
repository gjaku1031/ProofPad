import XCTest
@testable import ProofPad

final class PageStrokesUndoTests: XCTestCase {

    func testAddAndRemovePostChangeNotifications() {
        let page = PageStrokes(pageIndex: 0)
        let stroke = makeStroke()
        var notificationCount = 0
        let observer = NotificationCenter.default.addObserver(
            forName: PageStrokes.didChangeNotification,
            object: page,
            queue: nil
        ) { _ in
            notificationCount += 1
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        page.add(stroke)
        page.remove(id: stroke.id)

        XCTAssertEqual(notificationCount, 2)
    }

    func testRecordingUndoMutatesPageStrokesWithoutCanvasTarget() {
        let page = PageStrokes(pageIndex: 0)
        let undoManager = UndoManager()
        let stroke = makeStroke()
        var notificationCount = 0
        var changeCount = 0
        let observer = NotificationCenter.default.addObserver(
            forName: PageStrokes.didChangeNotification,
            object: page,
            queue: nil
        ) { _ in
            notificationCount += 1
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        page.addRecordingUndo(stroke,
                              undoManager: undoManager,
                              notify: true,
                              onChange: { changeCount += 1 })
        XCTAssertEqual(page.strokes.map(\.id), [stroke.id])

        undoManager.undo()
        XCTAssertTrue(page.strokes.isEmpty)

        undoManager.redo()
        XCTAssertEqual(page.strokes.map(\.id), [stroke.id])
        XCTAssertEqual(notificationCount, 3)
        XCTAssertEqual(changeCount, 3)
    }

    private func makeStroke() -> Stroke {
        let stroke = Stroke(color: .systemRed, width: 2)
        stroke.append(StrokePoint(x: 10, y: 20, t: 0))
        stroke.append(StrokePoint(x: 30, y: 40, t: 1))
        return stroke
    }
}
