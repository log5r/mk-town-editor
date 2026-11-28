import AppKit
import SwiftUI

struct EditorUnicodeInspector: View {
    let graphemes: [EditorUnicode.Grapheme]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Unicode情報")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(graphemes.indices, id: \.self) { index in
                        let grapheme = graphemes[index]
                        if index > 0 { Divider() }
                        Text(verbatim: unicodePreview(grapheme.text))
                            .font(.title3)
                            .accessibilityAddTraits(.isHeader)
                        ForEach(grapheme.scalars.indices, id: \.self) { scalarIndex in
                            if scalarIndex > 0 { Divider() }
                            EditorUnicodeScalarFields(info: grapheme.scalars[scalarIndex])
                        }
                    }
                }
                .padding(.trailing, 8)
            }
            .frame(height: hasMultipleScalars ? 290 : 150)
            HStack {
                Spacer()
                Button("コピー", action: copy)
                    .accessibilityLabel("Unicode情報をコピー")
            }
        }
        .frame(width: 380)
        .padding(16)
    }

    private var hasMultipleScalars: Bool {
        graphemes.count > 1 || (graphemes.first?.scalars.count ?? 0) > 1
    }

    private func copy() {
        let header = [
            String(localized: "文字"), String(localized: "コードポイント"),
            String(localized: "Unicode名"), String(localized: "Unicodeブロック"),
            String(localized: "一般カテゴリ")
        ].joined(separator: "\t")
        let rows = graphemes.flatMap { grapheme in
            let glyph = unicodePreview(grapheme.text)
            return grapheme.scalars.map { info in
                [glyph, info.codePoint, info.name, info.block, info.category].joined(separator: "\t")
            }
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(([header] + rows).joined(separator: "\n"), forType: .string)
    }
}

struct EditorUnicodeInsertionSheet: View {
    let onInsert: (Unicode.Scalar) -> Bool
    @Environment(\.dismiss) private var dismiss
    @FocusState private var inputFocused: Bool
    @State private var input = ""
    @State private var showsInsertionError = false

    var body: some View {
        let info = EditorUnicode.parseCodePoint(input)
        VStack(alignment: .leading, spacing: 12) {
            Text("コードポイントで文字を挿入")
                .font(.headline)
            TextField("コードポイント", text: $input, prompt: Text(verbatim: "U+3000"))
                .font(.body.monospaced())
                .focused($inputFocused)
                .onSubmit { insert(info) }
            VStack(alignment: .leading, spacing: 8) {
                if let info {
                    LabeledContent("プレビュー") {
                        Text(verbatim: unicodePreview(String(info.scalar)))
                            .font(.title3)
                    }
                    EditorUnicodeScalarFields(info: info)
                } else if !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("有効なUnicodeコードポイントを入力してください。")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(minHeight: 118, alignment: .topLeading)
            if showsInsertionError {
                Text("挿入できませんでした。キャンセルして選択範囲と編集状態を確認してください。")
                    .foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("キャンセル") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("挿入") { insert(info) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(info == nil)
            }
        }
        .frame(width: 380)
        .padding(20)
        .onAppear { inputFocused = true }
    }

    private func insert(_ info: EditorUnicode.ScalarInfo?) {
        guard let info else { return }
        if onInsert(info.scalar) {
            dismiss()
        } else {
            showsInsertionError = true
        }
    }
}

private struct EditorUnicodeScalarFields: View {
    let info: EditorUnicode.ScalarInfo

    var body: some View {
        VStack(spacing: 4) {
            field("コードポイント", value: info.codePoint)
            field("Unicode名", value: info.name)
            field("Unicodeブロック", value: info.block)
            field("一般カテゴリ", value: info.category)
        }
    }

    private func field(_ title: LocalizedStringKey, value: String) -> some View {
        LabeledContent(title) {
            Text(verbatim: value)
                .multilineTextAlignment(.trailing)
        }
        .accessibilityRepresentation {
            Text("\(Text(title))、\(Text(verbatim: value))")
        }
    }
}

private func unicodePreview(_ text: String) -> String {
    guard let first = text.unicodeScalars.first(where: { scalar in
        !scalar.properties.isWhitespace && !scalar.properties.isDefaultIgnorableCodePoint &&
            scalar.properties.generalCategory != .control
    }) else {
        return String(localized: "表示されない文字")
    }
    switch first.properties.generalCategory {
    case .nonspacingMark, .spacingMark, .enclosingMark:
        return "◌" + text
    default:
        return text
    }
}
