import SwiftUI

enum MarkdownExportFormat: String, Identifiable {
    case html
    case pdf

    var id: String { rawValue }
    var title: String { rawValue.uppercased() }
}

struct MarkdownExportPresetSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var presets = MarkdownExportPresetStore().load()
    @State private var selectedID = MarkdownExportPreset.standard.id
    @State private var draft = MarkdownExportPreset.standard
    @State private var saveError: String?

    let format: MarkdownExportFormat
    let onExport: (MarkdownExportPreset) -> Void

    var body: some View {
        Form {
            Picker("プリセット", selection: $selectedID) {
                ForEach(presets) { preset in
                    Text(preset.name).tag(preset.id)
                }
            }
            .onChange(of: selectedID) { _, id in
                if let preset = presets.first(where: { $0.id == id }) { draft = preset }
            }
            TextField("プリセット名", text: $draft.name)
            TextField("本文幅（px）", value: $draft.bodyWidth, format: .number)
            TextField("文字サイズ（px）", value: $draft.fontSize, format: .number)
            Picker("フォント", selection: $draft.font) {
                ForEach(MarkdownExportPreset.Font.allCases, id: \.self) { font in
                    Text(font.title).tag(font)
                }
            }
            TextField("余白（pt）", value: $draft.margin, format: .number)
            Toggle("表紙を付ける", isOn: $draft.cover)
            Toggle("目次を付ける", isOn: $draft.tableOfContents)
            if let saveError {
                Text(saveError).foregroundStyle(.red)
            }
            HStack {
                Button("プリセットを保存") { savePreset() }
                    .disabled(!draft.isValid)
                Spacer()
                Button("キャンセル") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("\(format.title)を書き出す…") {
                    dismiss()
                    onExport(draft)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!draft.isValid)
            }
        }
        .frame(width: 400)
        .padding(20)
    }

    private func savePreset() {
        do {
            let saved = try MarkdownExportPresetStore().save(draft)
            presets = MarkdownExportPresetStore().load()
            selectedID = saved.id
            draft = saved
            saveError = nil
        } catch {
            saveError = error.localizedDescription
        }
    }
}
