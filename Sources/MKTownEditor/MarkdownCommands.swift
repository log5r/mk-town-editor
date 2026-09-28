import SwiftUI

private struct MarkdownEditorModelKey: FocusedValueKey {
    typealias Value = MarkdownEditorModel
}

extension FocusedValues {
    var markdownEditorModel: MarkdownEditorModel? {
        get { self[MarkdownEditorModelKey.self] }
        set { self[MarkdownEditorModelKey.self] = newValue }
    }
}

struct MarkdownCommands: Commands {
    @FocusedValue(\.markdownEditorModel) private var editorModel

    var body: some Commands {
        CommandGroup(after: .textEditing) {
            Divider()
            Button("検索…") {
                editorModel?.showFindBar()
            }
            .keyboardShortcut("f", modifiers: .command)
            .disabled(editorModel == nil)
        }

        CommandMenu("Markdown") {
            Button("太字") { editorModel?.apply(.bold) }
                .keyboardShortcut("b", modifiers: .command)
            Button("斜体") { editorModel?.apply(.italic) }
                .keyboardShortcut("i", modifiers: .command)
            Button("インラインコード") { editorModel?.apply(.inlineCode) }
                .keyboardShortcut("`", modifiers: .command)
            Divider()
            Button("リンク") { editorModel?.apply(.link) }
                .keyboardShortcut("k", modifiers: .command)
            Button("見出し") { editorModel?.apply(.heading) }
                .keyboardShortcut("1", modifiers: [.command, .option])
            Button("引用") { editorModel?.apply(.quote) }
                .keyboardShortcut(">", modifiers: [.command, .shift])
            Button("箇条書き") { editorModel?.apply(.unorderedList) }
                .keyboardShortcut("8", modifiers: [.command, .shift])
        }
    }
}
