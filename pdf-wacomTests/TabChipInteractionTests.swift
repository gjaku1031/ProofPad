import Cocoa
import XCTest
@testable import pdf_wacom

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
        var dropCount = 0
        chip.onSelect = { selectCount += 1 }
        chip.onDrop = { _, _ in dropCount += 1 }

        chip.mouseDown(with: mouseEvent(type: .leftMouseDown, x: 20, y: 12))
        chip.mouseUp(with: mouseEvent(type: .leftMouseUp, x: 21, y: 12))

        XCTAssertEqual(selectCount, 1)
        XCTAssertEqual(dropCount, 0)
    }

    func testDragDropsWithoutSelecting() {
        let chip = makeChip()
        var selectCount = 0
        var dropCount = 0
        chip.onSelect = { selectCount += 1 }
        chip.onDrop = { _, _ in dropCount += 1 }

        chip.mouseDown(with: mouseEvent(type: .leftMouseDown, x: 20, y: 12))
        chip.mouseDragged(with: mouseEvent(type: .leftMouseDragged, x: 80, y: 12))
        chip.mouseUp(with: mouseEvent(type: .leftMouseUp, x: 80, y: 12))

        XCTAssertEqual(selectCount, 0)
        XCTAssertEqual(dropCount, 1)
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
}
