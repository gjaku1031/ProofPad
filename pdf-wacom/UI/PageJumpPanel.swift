import SwiftUI

struct PageJumpView: View {
    let pageCount: Int
    let onConfirm: (Int) -> Void   // 0-based page index
    let onCancel: () -> Void

    @State private var input: String = ""
    @State private var hasError: Bool = false
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Go to Page")
                .font(.headline)
            TextField("1 – \(pageCount)", text: $input)
                .textFieldStyle(.roundedBorder)
                .focused($fieldFocused)
                .onSubmit(submit)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.red, lineWidth: hasError ? 1.5 : 0)
                )
                .onChange(of: input) { _ in
                    hasError = false
                }

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Go", action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(input.isEmpty)
            }
        }
        .padding()
        .frame(width: 280)
        .onAppear { fieldFocused = true }
    }

    private func submit() {
        guard let n = Int(input.trimmingCharacters(in: .whitespaces)),
              (1...pageCount).contains(n) else {
            hasError = true
            return
        }
        onConfirm(n - 1)
    }
}
