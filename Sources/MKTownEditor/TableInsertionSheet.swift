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

struct TableGridSheet: View {
    let onSave: ([String], [[String]], [MarkdownTable.Alignment]) -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var header: [String]
    @State private var rows: [[String]]
    @State private var alignments: [MarkdownTable.Alignment]
    @State private var showsError = false

    init(draft: MarkdownTableGridDraft,
         onSave: @escaping ([String], [[String]], [MarkdownTable.Alignment]) -> Bool) {
        self.onSave = onSave
        _header = State(initialValue: draft.header)
        _rows = State(initialValue: draft.rows)
        _alignments = State(initialValue: draft.alignments)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("表をグリッドで編集")
                .font(.headline)
            Text("セルにはMarkdownを入力できます。パイプと改行は確定時に変換されます。")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Button("行を追加") { rows.append(Array(repeating: "", count: header.count)) }
                    .disabled(rows.count >= 100)
                Button("列を追加") {
                    header.append("")
                    alignments.append(.leading)
                    for index in rows.indices { rows[index].append("") }
                }
                .disabled(header.count >= 12)
                Spacer()
                Text("列数: \(header.count)・データ行数: \(rows.count)")
                    .foregroundStyle(.secondary)
            }
            ScrollView([.horizontal, .vertical]) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Text("見出し")
                            .frame(width: 52, alignment: .leading)
                        ForEach(header.indices, id: \.self) { column in
                            VStack(spacing: 4) {
                                TextField("列名", text: cellBinding(row: nil, column: column))
                                    .accessibilityLabel(Text("列 \(column + 1) の見出し"))
                                Picker("配置", selection: alignmentBinding(column: column)) {
                                    Text("左揃え").tag(MarkdownTable.Alignment.leading)
                                    Text("中央揃え").tag(MarkdownTable.Alignment.center)
                                    Text("右揃え").tag(MarkdownTable.Alignment.trailing)
                                }
                                .labelsHidden()
                                Button("列を削除", systemImage: "minus.circle") {
                                    guard header.indices.contains(column) else { return }
                                    header.remove(at: column)
                                    alignments.remove(at: column)
                                    for index in rows.indices { rows[index].remove(at: column) }
                                }
                                .labelStyle(.iconOnly)
                                .disabled(header.count == 1)
                                .accessibilityLabel(Text("列 \(column + 1) を削除"))
                            }
                            .frame(width: 150)
                        }
                    }
                    Divider()
                    ForEach(rows.indices, id: \.self) { row in
                        HStack(spacing: 6) {
                            Button("行を削除", systemImage: "minus.circle") {
                                if rows.indices.contains(row) { rows.remove(at: row) }
                            }
                            .labelStyle(.iconOnly)
                            .frame(width: 52)
                            .accessibilityLabel(Text("行 \(row + 1) を削除"))
                            ForEach(header.indices, id: \.self) { column in
                                TextField("セル", text: cellBinding(row: row, column: column))
                                    .frame(width: 150)
                                    .accessibilityLabel(Text("行 \(row + 1) 列 \(column + 1)"))
                            }
                        }
                    }
                }
                .padding(4)
            }
            .frame(minHeight: 180, maxHeight: 420)
            .border(.separator)
            if showsError {
                Text("表を保存できません。本文と編集状態を確認してください。")
                    .foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("キャンセル") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("表に適用") {
                    if onSave(header, rows, alignments) { dismiss() }
                    else { showsError = true }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .frame(width: 740)
        .padding(20)
    }

    private func cellBinding(row: Int?, column: Int) -> Binding<String> {
        Binding(get: {
            if let row {
                guard rows.indices.contains(row), rows[row].indices.contains(column) else { return "" }
                return rows[row][column]
            }
            return header.indices.contains(column) ? header[column] : ""
        }, set: { value in
            if let row {
                guard rows.indices.contains(row), rows[row].indices.contains(column) else { return }
                rows[row][column] = value
            } else if header.indices.contains(column) {
                header[column] = value
            }
        })
    }

    private func alignmentBinding(column: Int) -> Binding<MarkdownTable.Alignment> {
        Binding(get: { alignments.indices.contains(column) ? alignments[column] : .leading },
                set: { if alignments.indices.contains(column) { alignments[column] = $0 } })
    }
}
