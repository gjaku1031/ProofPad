import Cocoa
import XCTest
@testable import ProofPad

final class TabChipInteractionTests: XCTestCase {

    func testMouseDownDoesNotSelectBeforeDragDecision() {
        let chip = makeChip()
        var selectCount = 0
        chip.onSelect = { selectCount += 1 }

        chip.mouseDown(with: mouseEvent(type: .leftMouseDown, x: 20, y: 12))

        XCTAssertEqual(selectCount, 0)
    }

    func testClickSelectsOnMouseUp() {
        let chip = makeChip()
        var selectCount = 0
        var dragEndCount = 0
        chip.onSelect = { selectCount += 1 }
        chip.onEndDrag = { dragEndCount += 1 }

        chip.mouseDown(with: mouseEvent(type: .leftMouseDown, x: 20, y: 12))
        chip.mouseUp(with: mouseEvent(type: .leftMouseUp, x: 21, y: 12))

        XCTAssertEqual(selectCount, 1)
        XCTAssertEqual(dragEndCount, 0)
    }

    func testDragReordersWithoutSelecting() {
        let chip = makeChip()
        var selectCount = 0
        var beginDragCount = 0
        var continueDragCount = 0
        var endDragCount = 0
        chip.onSelect = { selectCount += 1 }
        chip.onBeginDrag = { _ in beginDragCount += 1 }
        chip.onContinueDrag = { _ in continueDragCount += 1 }
        chip.onEndDrag = { endDragCount += 1 }

        chip.mouseDown(with: mouseEvent(type: .leftMouseDown, x: 20, y: 12))
        chip.mouseDragged(with: mouseEvent(type: .leftMouseDragged, x: 80, y: 12))
        chip.mouseUp(with: mouseEvent(type: .leftMouseUp, x: 80, y: 12))

        XCTAssertEqual(selectCount, 0)
        XCTAssertEqual(beginDragCount, 1)
        XCTAssertEqual(continueDragCount, 1)
        XCTAssertEqual(endDragCount, 1)
    }

    func testMiddleClickClosesWithoutSelectingOrDragging() {
        let chip = makeChip()
        var closeCount = 0
        var selectCount = 0
        var beginDragCount = 0
        chip.onClose = { closeCount += 1 }
        chip.onSelect = { selectCount += 1 }
        chip.onBeginDrag = { _ in beginDragCount += 1 }

        chip.otherMouseUp(with: middleMouseEvent(type: .otherMouseUp, x: 20, y: 12))

        XCTAssertEqual(closeCount, 1)
        XCTAssertEqual(selectCount, 0)
        XCTAssertEqual(beginDragCount, 0)
    }

    private func makeChip() -> TabChipView {
        let chip = TabChipView(document: PDFInkDocument(), isActive: false)
        chip.frame = NSRect(x: 0, y: 0, width: 180, height: 28)
        return chip
    }

    private func mouseEvent(type: NSEvent.EventType, x: CGFloat, y: CGFloat) -> NSEvent {
        NSEvent.mouseEvent(with: type,
                           location: NSPoint(x: x, y: y),
                           modifierFlags: [],
                           timestamp: 0,
                           windowNumber: 0,
                           context: nil,
                           eventNumber: 0,
                           clickCount: 1,
                           pressure: 0) ?? NSEvent()
    }

    private func middleMouseEvent(type: CGEventType, x: CGFloat, y: CGFloat) -> NSEvent {
        let source = CGEventSource(stateID: .hidSystemState)
        let event = CGEvent(mouseEventSource: source,
                            mouseType: type,
                            mouseCursorPosition: CGPoint(x: x, y: y),
                            mouseButton: .center)
        return event.flatMap(NSEvent.init(cgEvent:)) ?? NSEvent()
    }
}
