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
            commandButton(.find)
        }

        CommandMenu("Markdown") {
            commandButton(.bold)
            commandButton(.italic)
            commandButton(.strikethrough)
            commandButton(.inlineCode)
            Divider()
            commandButton(.link)
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
            commandButton(.toggleTaskCompletion)
        }
    }

    private func commandButton(_ command: EditorCommand) -> some View {
        Button(command.title) { command.perform(on: editorModel) }
            .keyboardShortcut(command.shortcut.key, modifiers: command.shortcut.modifiers)
            .disabled(!command.canExecute(in: editorModel))
    }
}
