import SwiftUI

// 펜 P1/P2/P3 segment를 한 번 더 클릭하면 그 펜 아래에 떠서 색·두께를 편집한다.
struct PenEditorView: View {
    let penIndex: Int

    @State private var color: Color
    @State private var width: Double
    @State private var recentColors: [Color?]
    @State private var widthText: String

    init(penIndex: Int) {
        self.penIndex = penIndex
        let s = PenSettings.shared
        let pen = s.pens[penIndex]
        _color = State(initialValue: Color(nsColor: pen.color.toNSColor()))
        _width = State(initialValue: pen.width)
        _widthText = State(initialValue: String(format: "%.1f", pen.width))
        _recentColors = State(initialValue: Self.recentSlots())
    }

    private static func recentSlots() -> [Color?] {
        let s = PenSettings.shared.recentColors
        var slots: [Color?] = []
        for i in 0..<5 {
            slots.append(i < s.count ? Color(nsColor: s[i].toNSColor()) : nil)
        }
        return slots
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // S-curve preview
            PenStrokePreview(color: color, width: CGFloat(width))
                .frame(height: 60)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(nsColor: .textBackgroundColor))
                )

            // 두께 슬라이더 + 숫자 입력
            VStack(alignment: .leading, spacing: 4) {
                Text("Width").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Slider(value: $width, in: 1...16, step: 0.5)
                        .onChange(of: width) { new in
                            PenSettings.shared.setWidth(forPenIndex: penIndex, CGFloat(new))
                            widthText = String(format: "%.1f", new)
                        }
                    TextField("", text: $widthText)
                        .frame(width: 50)
                        .multilineTextAlignment(.trailing)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { commitWidthText() }
                }
            }

            // ColorPicker
            ColorPicker("Color", selection: $color, supportsOpacity: false)
                .onChange(of: color) { new in
                    PenSettings.shared.setColor(forPenIndex: penIndex, NSColor(new))
                    recentColors = Self.recentSlots()
                }

            // Recent — 항상 5 슬롯, 비면 placeholder
            VStack(alignment: .leading, spacing: 4) {
                Text("Recent").font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    ForEach(0..<5, id: \.self) { i in
                        let c = recentColors[i]
                        Button {
                            if let c {
                                PenSettings.shared.setColor(forPenIndex: penIndex, NSColor(c))
                                color = c
                                recentColors = Self.recentSlots()
                            }
                        } label: {
                            ZStack {
                                Circle()
                                    .fill(c ?? Color(nsColor: .quaternaryLabelColor))
                                    .frame(width: 24, height: 24)
                                Circle()
                                    .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
                                    .frame(width: 24, height: 24)
                                if c == nil {
                                    Image(systemName: "circle.dashed")
                                        .foregroundStyle(.tertiary)
                                        .font(.system(size: 10))
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(c == nil)
                    }
                }
            }
        }
        .padding(16)
        .frame(width: 300)
    }

    private func commitWidthText() {
        let clean = widthText.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        if let v = Double(clean) {
            let clamped = min(max(v, 1), 16)
            width = clamped
            widthText = String(format: "%.1f", clamped)
            PenSettings.shared.setWidth(forPenIndex: penIndex, CGFloat(clamped))
        } else {
            widthText = String(format: "%.1f", width)
        }
    }
}

// 노트/펜 앱에서 자주 보는 S-curve stroke 미리보기. 색·두께만 시각화 (필압 X).
struct PenStrokePreview: View {
    let color: Color
    let width: CGFloat

    var body: some View {
        GeometryReader { geo in
            Path { path in
                let w = geo.size.width
                let h = geo.size.height
                let margin: CGFloat = 16
                path.move(to: CGPoint(x: margin, y: h * 0.75))
                path.addCurve(
                    to: CGPoint(x: w - margin, y: h * 0.25),
                    control1: CGPoint(x: w * 0.40, y: h * 1.25),
                    control2: CGPoint(x: w * 0.60, y: h * -0.25)
                )
            }
            .stroke(color, style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
        }
    }
}
