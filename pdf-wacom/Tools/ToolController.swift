import Cocoa

final class ToolController {
    let pen = PenTool()
    let eraser = EraserTool()

    /// stroke 시작 시점의 keymap + PenSettings.currentTool을 보고 도구를 선택.
    /// 기본값은 Control hold면 강제 지우개. 그 외엔 PenSettings.currentTool 따름.
    func tool(forModifierFlags flags: NSEvent.ModifierFlags) -> Tool {
        if KeyboardModeState.shared.isEraserHeld ||
            InputSettings.shared.eraserHoldKey.matchesModifierFlags(flags) {
            return eraser
        }
        return PenSettings.shared.currentTool == .eraser ? eraser : pen
    }
}
