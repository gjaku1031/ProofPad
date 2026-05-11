import Cocoa
import XCTest
@testable import pdf_wacom

final class InputSettingsTests: XCTestCase {
    private var originalSettings: InputSettings.Snapshot!
    private var originalPenIndex = 0
    private var originalTool = PenSettings.ToolKind.pen

    override func setUp() {
        super.setUp()
        originalSettings = InputSettings.shared.current
        originalPenIndex = PenSettings.shared.currentPenIndex
        originalTool = PenSettings.shared.currentTool
        InputSettings.shared.replaceForTesting(.appDefault)
        PenSettings.shared.selectPen(0)
        KeyboardModeState.shared.resetAll()
        TabletEventRouter.setPenInProximityForTesting(false)
    }

    override func tearDown() {
        TabletEventRouter.setPenInProximityForTesting(false)
        KeyboardModeState.shared.resetAll()
        InputSettings.shared.replaceForTesting(originalSettings)
        switch originalTool {
        case .pen:
            PenSettings.shared.selectPen(originalPenIndex)
        case .eraser:
            PenSettings.shared.selectEraser()
        }
        super.tearDown()
    }

    func testDefaultInputSettingsMatchExistingBehavior() {
        XCTAssertTrue(InputSettings.shared.ignoresMouseInput)
        XCTAssertEqual(InputSettings.shared.eraserHoldKey, .modifier(.control))
        XCTAssertEqual(InputSettings.shared.moveHoldKey, .keyCode(49, displayName: "Space"))
    }

    func testMouseRoutingRespectsIgnoreMouseSetting() {
        let event = mouseEvent()

        guard case .ignore = TabletEventRouter.decide(event) else {
            return XCTFail("Mouse should be ignored by default")
        }

        InputSettings.shared.setIgnoresMouseInput(false)
        guard case .pen = TabletEventRouter.decide(event) else {
            return XCTFail("Mouse should be accepted when ignore is disabled")
        }
    }

    func testToolControllerUsesConfiguredEraserHoldState() {
        let controller = ToolController()

        XCTAssertTrue(controller.tool(forModifierFlags: .control) is EraserTool)
        XCTAssertTrue(controller.tool(forModifierFlags: []) is PenTool)

        InputSettings.shared.setEraserHoldKey(.keyCode(14, displayName: "E"))
        KeyboardModeState.shared.setEraserHeld(true)

        XCTAssertTrue(controller.tool(forModifierFlags: []) is EraserTool)
    }

    func testKeyDownCaptureUsesReadableDisplayNames() {
        let event = NSEvent.keyEvent(with: .keyDown,
                                     location: .zero,
                                     modifierFlags: [],
                                     timestamp: 0,
                                     windowNumber: 0,
                                     context: nil,
                                     characters: " ",
                                     charactersIgnoringModifiers: " ",
                                     isARepeat: false,
                                     keyCode: 49)

        XCTAssertEqual(InputHoldKey.fromKeyDown(event!)?.displayName, "Space")
    }

    private func mouseEvent() -> NSEvent {
        NSEvent.mouseEvent(with: .leftMouseDown,
                           location: .zero,
                           modifierFlags: [],
                           timestamp: 0,
                           windowNumber: 0,
                           context: nil,
                           eventNumber: 0,
                           clickCount: 1,
                           pressure: 0) ?? NSEvent()
    }
}
