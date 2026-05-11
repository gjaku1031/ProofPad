import Cocoa

protocol Tool: AnyObject {
    func mouseDown(at pagePoint: CGPoint, event: NSEvent, canvas: StrokeCanvasView)
    func mouseDragged(to pagePoint: CGPoint, event: NSEvent, canvas: StrokeCanvasView)
    func mouseUp(at pagePoint: CGPoint, event: NSEvent, canvas: StrokeCanvasView)
}
