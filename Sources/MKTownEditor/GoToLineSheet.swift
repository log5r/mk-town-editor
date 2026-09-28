import SwiftUI

struct GoToLineSheet: View {
    let lineCount: Int
    let initialLine: Int
    let onGo: (Int) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var input = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("指定行へ移動")
                .font(.headline)
            TextField("行番号", text: $input)
                .accessibilityLabel("移動先の行番号")
                .onSubmit(go)
            Text("1〜\(lineCount) 行。範囲外の番号は最も近い行へ移動します。")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("キャンセル") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("移動") { go() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(Int(input) == nil)
            }
        }
        .padding(20)
        .frame(width: 360)
        .onAppear { input = String(initialLine) }
    }

    private func go() {
        guard let line = Int(input) else { return }
        onGo(line)
        dismiss()
    }
}
