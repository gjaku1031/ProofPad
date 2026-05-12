import SwiftUI

// 새 stroke에 적용될 필기감 기본값을 조절한다. 현재 appDefault가 방금 튜닝한 "괜찮은 느낌"이다.
struct InkFeelEditorView: View {
    @State private var settings: InkFeelSettings.Snapshot

    init() {
        _settings = State(initialValue: InkFeelSettings.shared.current)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            InkFeelPreview(settings: settings)
                .frame(height: 64)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(nsColor: .textBackgroundColor))
                )

            InkFeelSlider(title: "Stabilization",
                          value: $settings.stabilization,
                          range: 0...1,
                          step: 0.05)
            InkFeelSlider(title: "Pressure response",
                          value: $settings.pressureResponse,
                          range: 0...1.8,
                          step: 0.05)
            InkFeelSlider(title: "Speed thinning",
                          value: $settings.speedThinning,
                          range: 0...1.8,
                          step: 0.05)
            InkFeelSlider(title: "Pressure smoothing",
                          value: $settings.pressureStability,
                          range: 0...0.9,
                          step: 0.05)
            InkFeelSlider(title: "Latency lead",
                          value: $settings.latencyLead,
                          range: 0...1.5,
                          step: 0.05)

            Divider()

            HStack {
                Spacer()
                Button {
                    settings = .appDefault
                    InkFeelSettings.shared.resetToAppDefault()
                } label: {
                    Label("Defaults", systemImage: "arrow.counterclockwise")
                }
            }
        }
        .padding(16)
        .frame(width: 320)
        .onChange(of: settings) { new in
            InkFeelSettings.shared.update(new)
        }
    }
}

private struct InkFeelSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(valueText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range, step: step)
        }
    }

    private var valueText: String {
        String(format: "%.2f", value)
    }
}

private struct InkFeelPreview: View {
    let settings: InkFeelSettings.Snapshot

    var body: some View {
        GeometryReader { geo in
            let points = previewPoints(in: geo.size)
            ZStack {
                ForEach(1..<points.count, id: \.self) { i in
                    Path { path in
                        let a = points[i - 1]
                        let b = points[i]
                        path.move(to: CGPoint(x: CGFloat(a.x), y: CGFloat(a.y)))
                        path.addLine(to: CGPoint(x: CGFloat(b.x), y: CGFloat(b.y)))
                    }
                    .stroke(Color.accentColor,
                            style: StrokeStyle(lineWidth: lineWidth(at: i, points: points),
                                               lineCap: .round,
                                               lineJoin: .round))
                }
            }
        }
    }

    private func previewPoints(in size: CGSize) -> [StrokePoint] {
        let w = max(size.width, 1)
        let h = max(size.height, 1)
        let raw = [
            StrokePoint(x: Float(w * 0.08), y: Float(h * 0.68), t: 0, pressure: 0.20),
            StrokePoint(x: Float(w * 0.22), y: Float(h * 0.30), t: 18, pressure: 0.60),
            StrokePoint(x: Float(w * 0.38), y: Float(h * 0.76), t: 44, pressure: 0.90),
            StrokePoint(x: Float(w * 0.56), y: Float(h * 0.24), t: 78, pressure: 0.45),
            StrokePoint(x: Float(w * 0.76), y: Float(h * 0.36), t: 118, pressure: 0.75),
            StrokePoint(x: Float(w * 0.92), y: Float(h * 0.28), t: 138, pressure: 1.00),
        ]
        guard let first = raw.first else { return [] }
        var builder = InkStrokeBuilder(baseWidth: 3, feel: settings)
        var points = [
            builder.begin(at: CGPoint(x: CGFloat(first.x), y: CGFloat(first.y)),
                          time: first.t,
                          pressure: first.pressure)
        ]
        for sample in raw.dropFirst() {
            points.append(contentsOf: builder.append(
                to: CGPoint(x: CGFloat(sample.x), y: CGFloat(sample.y)),
                time: sample.t,
                pressure: sample.pressure
            ))
        }
        return points
    }

    private func lineWidth(at index: Int, points: [StrokePoint]) -> CGFloat {
        let halfWidth = InkStrokeDynamics.halfWidth(
            baseWidth: 3,
            viewScale: 1,
            point: points[index],
            previous: points[index - 1],
            feel: settings
        )
        return CGFloat(halfWidth) * 2
    }
}
