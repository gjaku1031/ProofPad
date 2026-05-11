import Cocoa

// MARK: - PenSettings (singleton)
//
// 앱 전역 펜·지우개 설정. 펜 3개 슬롯(P1/P2/P3) + 현재 도구(.pen/.eraser) + 최근 색 5개.
// UserDefaults에 JSON snapshot으로 persist.
//
// === Lifecycle ===
//   첫 실행 → 기본 펜 3개(빨강/검정/파랑, width=2) + 빈 recent.
//   이후 → UserDefaults snapshot 로드.
//
// === 변경 통지 ===
//   onChange 콜백 — ToolbarBuilder가 segment swatch 색을 동기화하는 데 사용. 매 setter 호출 시 발화.
//   여러 구독자 필요해지면 multicast로 바꿔야 함 (현재는 single closure).
final class PenSettings {

    enum ToolKind: String, Codable {
        case pen, eraser
    }

    struct ColorData: Codable, Equatable {
        var r: Double, g: Double, b: Double, a: Double
    }

    struct PenState: Codable {
        var color: ColorData
        var width: Double
    }

    static let shared = PenSettings()

    private(set) var pens: [PenState]
    private(set) var currentPenIndex: Int
    private(set) var currentTool: ToolKind
    private(set) var recentColors: [ColorData]

    /// 설정이 바뀌면 호출 (NSToolbar UI 동기화용).
    var onChange: (() -> Void)?

    private init() {
        if let snap = Self.loadSnapshot() {
            pens = snap.pens
            currentPenIndex = max(0, min(snap.currentPenIndex, snap.pens.count - 1))
            currentTool = snap.currentTool
            recentColors = snap.recentColors
        } else {
            pens = [
                PenState(color: ColorData.from(.systemRed), width: 2),
                PenState(color: ColorData.from(.black),     width: 2),
                PenState(color: ColorData.from(.systemBlue), width: 2),
            ]
            currentPenIndex = 0
            currentTool = .pen
            recentColors = []
        }
    }

    // MARK: - Active pen / tool

    var currentColor: NSColor {
        pens[currentPenIndex].color.toNSColor()
    }

    var currentWidth: CGFloat {
        CGFloat(pens[currentPenIndex].width)
    }

    func setCurrentColor(_ color: NSColor) {
        pens[currentPenIndex].color = ColorData.from(color)
        pushRecentColor(ColorData.from(color))
        currentTool = .pen
        save()
        onChange?()
    }

    func setCurrentWidth(_ width: CGFloat) {
        pens[currentPenIndex].width = Double(width)
        save()
        onChange?()
    }

    /// 특정 펜의 색만 변경 (해당 펜으로 전환은 안 함).
    func setColor(forPenIndex index: Int, _ color: NSColor) {
        guard pens.indices.contains(index) else { return }
        pens[index].color = ColorData.from(color)
        pushRecentColor(ColorData.from(color))
        save()
        onChange?()
    }

    /// 특정 펜의 두께만 변경.
    func setWidth(forPenIndex index: Int, _ width: CGFloat) {
        guard pens.indices.contains(index) else { return }
        pens[index].width = Double(width)
        save()
        onChange?()
    }

    func selectPen(_ index: Int) {
        guard pens.indices.contains(index) else { return }
        currentPenIndex = index
        currentTool = .pen
        save()
        onChange?()
    }

    func selectEraser() {
        currentTool = .eraser
        save()
        onChange?()
    }

    private func pushRecentColor(_ color: ColorData) {
        recentColors.removeAll { $0.isClose(to: color) }
        recentColors.insert(color, at: 0)
        if recentColors.count > 5 { recentColors.removeLast() }
    }

    // MARK: - Persist

    private struct Snapshot: Codable {
        var pens: [PenState]
        var currentPenIndex: Int
        var currentTool: ToolKind
        var recentColors: [ColorData]
    }

    private static let defaultsKey = "PenSettings.v1"

    private func save() {
        let s = Snapshot(pens: pens,
                         currentPenIndex: currentPenIndex,
                         currentTool: currentTool,
                         recentColors: recentColors)
        if let data = try? JSONEncoder().encode(s) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }

    private static func loadSnapshot() -> Snapshot? {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey) else { return nil }
        return try? JSONDecoder().decode(Snapshot.self, from: data)
    }
}

extension PenSettings.ColorData {
    static func from(_ color: NSColor) -> Self {
        let c = color.usingColorSpace(.sRGB) ?? color
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.getRed(&r, green: &g, blue: &b, alpha: &a)
        return Self(r: Double(r), g: Double(g), b: Double(b), a: Double(a))
    }

    func toNSColor() -> NSColor {
        NSColor(srgbRed: CGFloat(r), green: CGFloat(g), blue: CGFloat(b), alpha: CGFloat(a))
    }

    func isClose(to other: Self, tolerance: Double = 0.01) -> Bool {
        abs(r - other.r) < tolerance && abs(g - other.g) < tolerance && abs(b - other.b) < tolerance
    }
}
