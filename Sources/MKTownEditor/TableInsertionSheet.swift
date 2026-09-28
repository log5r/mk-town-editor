import SwiftUI

struct TableInsertionSheet: View {
    let onInsert: (Int, Int) -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var rows = 2
    @State private var columns = 3
    @State private var showsError = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("表を挿入")
                .font(.headline)
            Form {
                Stepper("列数: \(columns)", value: $columns, in: 1...12)
                Stepper("データ行数: \(rows)", value: $rows, in: 1...20)
            }
            .formStyle(.grouped)
            .frame(height: 130)
            if showsError {
                Text("表を挿入できません。本文と編集状態を確認してください。")
                    .foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("キャンセル") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("挿入") {
                    if onInsert(rows, columns) { dismiss() }
                    else { showsError = true }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .frame(width: 380)
        .padding(20)
    }
}
