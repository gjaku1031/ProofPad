import Foundation

// MARK: - PageStrokes
//
// 한 PDF 페이지의 편집 가능한 ink stroke들.
//
// === 인바리언트 ===
//   - strokes는 추가 순서 = 그리기 순서. 인덱스는 안정적이지 않음 (remove 시 shift됨) — 식별은 stroke.id.
//   - pageIndex는 fixed (init 후 변경 X). PDFDocument의 페이지 index와 일치.
//   - 변경 시 didChangeNotification을 post — 현재 화면에 붙은 StrokeCanvasView가 model 변경을 다시 렌더.
//   - undo/redo는 view가 아니라 PageStrokes가 등록해 layout 재생성 뒤에도 stale canvas에 묶이지 않음.
//
// === 공간 인덱스 ===
//   Step 5 시점에 BBoxGrid 등 공간 인덱스 추가 예정. 현재는 linear scan으로 충분 (페이지당 stroke 수가 작음).
final class PageStrokes {
    static let didChangeNotification = Notification.Name("PageStrokes.didChange")

    let pageIndex: Int
    private(set) var strokes: [Stroke] = []

    init(pageIndex: Int) {
        self.pageIndex = pageIndex
    }

    func add(_ stroke: Stroke, notify: Bool = true) {
        strokes.append(stroke)
        if notify { postDidChange() }
    }

    @discardableResult
    func remove(id: UUID, notify: Bool = true) -> Stroke? {
        guard let idx = strokes.firstIndex(where: { $0.id == id }) else { return nil }
        let removed = strokes.remove(at: idx)
        if notify { postDidChange() }
        return removed
    }

    func addRecordingUndo(_ stroke: Stroke,
                          undoManager: UndoManager?,
                          actionName: String? = nil,
                          notify: Bool = true,
                          onChange: (() -> Void)? = nil) {
        add(stroke, notify: notify)
        if let actionName {
            undoManager?.setActionName(actionName)
        }
        let undoManagerBox = WeakUndoManagerBox(undoManager)
        undoManager?.registerUndo(withTarget: self) { page in
            page.removeRecordingUndo(stroke,
                                     undoManager: undoManagerBox.value,
                                     actionName: actionName,
                                     notify: true,
                                     onChange: onChange)
        }
        onChange?()
    }

    @discardableResult
    func removeRecordingUndo(_ stroke: Stroke,
                             undoManager: UndoManager?,
                             actionName: String? = nil,
                             notify: Bool = true,
                             onChange: (() -> Void)? = nil) -> Stroke? {
        guard let removed = remove(id: stroke.id, notify: notify) else { return nil }
        if let actionName {
            undoManager?.setActionName(actionName)
        }
        let undoManagerBox = WeakUndoManagerBox(undoManager)
        undoManager?.registerUndo(withTarget: self) { page in
            page.addRecordingUndo(removed,
                                  undoManager: undoManagerBox.value,
                                  actionName: actionName,
                                  notify: true,
                                  onChange: onChange)
        }
        onChange?()
        return removed
    }

    private func postDidChange() {
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }
}

private final class WeakUndoManagerBox {
    weak var value: UndoManager?

    init(_ value: UndoManager?) {
        self.value = value
    }
}
