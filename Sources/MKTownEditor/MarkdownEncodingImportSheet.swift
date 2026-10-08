import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct MarkdownEncodingImportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var sourceEncoding: MarkdownTextEncoding = .utf8
    @State private var destinationEncoding: MarkdownTextEncoding = .utf8
    @State private var errorMessage: String?
    @State private var decodedCache = DerivedValueCache<MarkdownTextEncoding, String?>()

    let sourceURL: URL
    let sourceData: Data
    let onSaved: (URL) -> Void

    var body: some View {
        // 全体のデコードと往復検証は、読み込みの文字コードを変えた時だけ行う。
        let decodedText = decodedCache.value(for: sourceEncoding) { encoding in
            try? MarkdownEncodingConverter.decode(sourceData, as: encoding)
        }
        VStack(alignment: .leading, spacing: 14) {
            Text("文字コードを指定して取り込む").font(.headline)
            Text(sourceURL.lastPathComponent).foregroundStyle(.secondary)
            Picker("読み込み", selection: $sourceEncoding) {
                ForEach(MarkdownTextEncoding.allCases) { encoding in
                    Text(encoding.title).tag(encoding)
                }
            }
            if let decodedText {
                ScrollView {
                    Text(decodedText.isEmpty ? "空の書類" : String(decodedText.prefix(1_000)))
                        .font(.body.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                    .frame(height: 150)
                    .padding(8)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                Text("先頭1,000文字を表示しています。内容を確認してから保存してください。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("この文字コードでは損失なく読めません。別の候補を選んでください。")
                    .foregroundStyle(.red)
            }
            Picker("保存形式", selection: $destinationEncoding) {
                ForEach(MarkdownTextEncoding.allCases) { encoding in
                    Text(encoding.title).tag(encoding)
                }
            }
            Text("UTF-8で保存した書類は、このアプリでそのまま編集できます。")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("キャンセル") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("変換して保存…") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(decodedText == nil)
            }
        }
        .frame(width: 540)
        .padding(20)
    }

    private func save() {
        let converted: Data
        do {
            converted = try MarkdownEncodingConverter.convert(sourceData, from: sourceEncoding,
                                                              to: destinationEncoding)
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [MarkdownDocument.markdownType]
        panel.nameFieldStringValue = sourceURL.deletingPathExtension().lastPathComponent +
            "-converted.md"
        let encoding = destinationEncoding
        panel.beginAttached { response in
            guard response == .OK, let destination = panel.url else { return }
            do {
                try converted.write(to: destination, options: .atomic)
                dismiss()
                if encoding == .utf8 { onSaved(destination) }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
