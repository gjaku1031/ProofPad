import Cocoa

final class ToolController {
    let pen = PenTool()
    let eraser = EraserTool()

    /// stroke 시작 시점의 modifier + PenSettings.currentTool을 보고 도구를 선택.
    /// ⌃ hold면 강제 지우개. 그 외엔 PenSettings.currentTool 따름.
    func tool(forModifierFlags flags: NSEvent.ModifierFlags) -> Tool {
        if flags.contains(.control) { return eraser }
        return PenSettings.shared.currentTool == .eraser ? eraser : pen
    }
}
