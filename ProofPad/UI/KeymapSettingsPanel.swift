import AppKit
import SwiftUI

struct KeymapSettingsView: View {
    private enum RecordingTarget {
        case eraser
        case move
    }

    @State private var snapshot: InputSettings.Snapshot
    @State private var recordingTarget: RecordingTarget?

    init() {
        _snapshot = State(initialValue: InputSettings.shared.current)
    }

    var body: some View {
        ZStack {
            VStack(alignment: .leading, spacing: 14) {
                Label("Keymap", systemImage: "keyboard")
                    .font(.headline)

                VStack(spacing: 10) {
                    KeymapRow(title: "Eraser",
                              subtitle: "Hold to erase",
                              key: snapshot.eraserHoldKey,
                              isRecording: recordingTarget == .eraser) {
                        recordingTarget = .eraser
                    }
                    KeymapRow(title: "Move",
                              subtitle: "Hold to pan pages",
                              key: snapshot.moveHoldKey,
                              isRecording: recordingTarget == .move) {
                        recordingTarget = .move
                    }
                }

                Divider()

                HStack {
                    Spacer()
                    Button {
                        InputSettings.shared.resetToDefaults()
                        snapshot = InputSettings.shared.current
                        recordingTarget = nil
                    } label: {
                        Label("Defaults", systemImage: "arrow.counterclockwise")
                    }
                }
            }

            InputKeyCaptureBridge(
                isRecording: recordingTarget != nil,
                onCapture: applyCapturedKey(_:),
                onCancel: { recordingTarget = nil }
            )
            .frame(width: 1, height: 1)
            .opacity(0)
        }
        .padding(16)
        .frame(width: 300)
    }

    private func applyCapturedKey(_ key: InputHoldKey) {
        switch recordingTarget {
        case .eraser:
            InputSettings.shared.setEraserHoldKey(key)
        case .move:
            InputSettings.shared.setMoveHoldKey(key)
        case nil:
            return
        }
        snapshot = InputSettings.shared.current
        recordingTarget = nil
    }
}

private struct KeymapRow: View {
    let title: String
    let subtitle: String
    let key: InputHoldKey
    let isRecording: Bool
    let onRecord: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body.weight(.medium))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(isRecording ? "Press key..." : key.displayName) {
                onRecord()
            }
            .font(.body.monospacedDigit())
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .frame(minWidth: 108)
        }
    }
}

private struct InputKeyCaptureBridge: NSViewRepresentable {
    var isRecording: Bool
    var onCapture: (InputHoldKey) -> Void
    var onCancel: () -> Void

    func makeNSView(context: Context) -> InputKeyCaptureView {
        let view = InputKeyCaptureView(frame: .zero)
        view.onCapture = onCapture
        view.onCancel = onCancel
        return view
    }

    func updateNSView(_ nsView: InputKeyCaptureView, context: Context) {
        nsView.isRecording = isRecording
        nsView.onCapture = onCapture
        nsView.onCancel = onCancel
        guard isRecording else { return }
        DispatchQueue.main.async {
            nsView.window?.makeFirstResponder(nsView)
        }
    }
}

final class InputKeyCaptureView: NSView {
    var isRecording = false
    var onCapture: ((InputHoldKey) -> Void)?
    var onCancel: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }

    override func keyDown(with event: NSEvent) {
        guard isRecording else {
            super.keyDown(with: event)
            return
        }
        if event.keyCode == 53 {
            isRecording = false
            onCancel?()
            return
        }
        guard let key = InputHoldKey.fromKeyDown(event) else { return }
        isRecording = false
        onCapture?(key)
    }

    override func flagsChanged(with event: NSEvent) {
        guard isRecording else {
            super.flagsChanged(with: event)
            return
        }
        guard let key = InputHoldKey.fromModifierFlags(event.modifierFlags) else { return }
        isRecording = false
        onCapture?(key)
    }
}
