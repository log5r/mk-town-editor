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
    @ObservedObject var settingsStore: EditorSettingsStore

    var body: some Commands {
        CommandMenu("文字表示") {
            Button("文字を拡大") { settingsStore.adjustFontSize(by: 1) }
                .keyboardShortcut("+", modifiers: .command)
            Button("文字を縮小") { settingsStore.adjustFontSize(by: -1) }
                .keyboardShortcut("-", modifiers: .command)
            Button("標準サイズ") { settingsStore.resetFontSize() }
                .keyboardShortcut("0", modifiers: .command)
        }
        CommandGroup(after: .textEditing) {
            Divider()
            commandButton(.find)
        }

        CommandMenu("Markdown") {
            commandButton(.bold)
            commandButton(.italic)
            commandButton(.strikethrough)
            commandButton(.inlineCode)
            Divider()
            commandButton(.link)
            commandButton(.image)
            commandButton(.table)
            Menu("見出しレベル") {
                commandButton(.heading(level: 0))
                Divider()
                ForEach(1...6, id: \.self) { level in
                    commandButton(.heading(level: level))
                }
            }
            commandButton(.quote)
            commandButton(.unorderedList)
            commandButton(.orderedList)
            commandButton(.taskList)
            commandButton(.indentList)
            commandButton(.outdentList)
            commandButton(.toggleTaskCompletion)
            Menu("コードブロック") {
                commandButton(.codeBlock(language: nil))
                Divider()
                ForEach(MarkdownCodeLanguage.allCases, id: \.self) { language in
                    commandButton(.codeBlock(language: language))
                }
            }
            commandButton(.horizontalRule)
            Divider()
            Picker("画像ドロップ", selection: Binding(
                get: { settingsStore.imageImportMode(for: nil) },
                set: { settingsStore.setImageImportMode($0) }
            )) {
                ForEach(ImageImportMode.allCases, id: \.self) { mode in
                    Text(mode.title).tag(mode)
                }
            }
        }
    }

    @ViewBuilder
    private func commandButton(_ command: EditorCommand) -> some View {
        let button = Button(command.title) { command.perform(on: editorModel) }
            .disabled(!command.canExecute(in: editorModel))
        if let shortcut = command.shortcut {
            button.keyboardShortcut(shortcut.key, modifiers: shortcut.modifiers)
        } else {
            button
        }
    }
}
