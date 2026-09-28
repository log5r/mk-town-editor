import SwiftUI

struct EditorWorkspace: View {
    @Binding var document: MarkdownDocument
    let fileURL: URL?
    @StateObject private var editorModel = MarkdownEditorModel()
    @SceneStorage("editorMode") private var storedMode = EditorMode.split.rawValue

    private var mode: Binding<EditorMode> {
        Binding(
            get: { EditorMode(rawValue: storedMode) ?? .split },
            set: { storedMode = $0.rawValue }
        )
    }

    private var statistics: DocumentStatistics {
        DocumentStatistics(text: document.text)
    }

    private var documentContext: DocumentContext {
        DocumentContext(fileURL: fileURL)
    }

    var body: some View {
        VStack(spacing: 0) {
            editorContent
            Divider()
            statusBar
        }
        .frame(minWidth: 720, minHeight: 480)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                formatButton("太字", symbol: "bold", style: .bold)
                formatButton("斜体", symbol: "italic", style: .italic)
                formatButton("リンク", symbol: "link", style: .link)
            }

            ToolbarItem(placement: .principal) {
                Picker("表示", selection: mode) {
                    ForEach(EditorMode.allCases) { value in
                        Label(value.label, systemImage: value.symbolName)
                            .accessibilityLabel(value.label)
                            .tag(value)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 220)
            }
        }
        .focusedSceneValue(\.markdownEditorModel, editorModel)
    }

    @ViewBuilder
    private var editorContent: some View {
        switch mode.wrappedValue {
        case .editor:
            sourceEditor
        case .split:
            HSplitView {
                sourceEditor
                    .frame(minWidth: 280)
                MarkdownPreview(markdown: document.text, documentContext: documentContext)
                    .frame(minWidth: 280)
            }
        case .preview:
            MarkdownPreview(markdown: document.text, documentContext: documentContext)
        }
    }

    private var sourceEditor: some View {
        MarkdownTextEditor(text: $document.text, model: editorModel)
    }

    private var statusBar: some View {
        HStack(spacing: 12) {
            Text("Markdown")
            Spacer()
            Text("\(statistics.lines) 行")
            Text("\(statistics.words) 語")
            Text("\(statistics.characters) 文字")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .frame(height: 28)
        .background(.bar)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("文書統計。\(statistics.lines) 行、\(statistics.words) 語、\(statistics.characters) 文字")
    }

    private func formatButton(
        _ label: String,
        symbol: String,
        style: MarkdownFormattingStyle
    ) -> some View {
        Button {
            editorModel.apply(style)
        } label: {
            Label(label, systemImage: symbol)
        }
        .help(label)
        .disabled(mode.wrappedValue == .preview)
    }
}
