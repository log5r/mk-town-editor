import SwiftUI

private struct MarkdownEditorModelKey: FocusedValueKey {
    typealias Value = MarkdownEditorModel
}

private struct GoToLineActionKey: FocusedValueKey {
    typealias Value = () -> Void
}

private struct GoToHeadingActionKey: FocusedValueKey {
    typealias Value = () -> Void
}

struct NavigationHistoryActions {
    let canGoBack: Bool
    let canGoForward: Bool
    let goBack: () -> Void
    let goForward: () -> Void
}

private struct NavigationHistoryActionsKey: FocusedValueKey {
    typealias Value = NavigationHistoryActions
}

extension FocusedValues {
    var markdownEditorModel: MarkdownEditorModel? {
        get { self[MarkdownEditorModelKey.self] }
        set { self[MarkdownEditorModelKey.self] = newValue }
    }

    var goToLineAction: (() -> Void)? {
        get { self[GoToLineActionKey.self] }
        set { self[GoToLineActionKey.self] = newValue }
    }
    var goToHeadingAction: (() -> Void)? {
        get { self[GoToHeadingActionKey.self] }
        set { self[GoToHeadingActionKey.self] = newValue }
    }
    var navigationHistoryActions: NavigationHistoryActions? {
        get { self[NavigationHistoryActionsKey.self] }
        set { self[NavigationHistoryActionsKey.self] = newValue }
    }
}

struct MarkdownCommands: Commands {
    @FocusedValue(\.markdownEditorModel) private var editorModel
    @FocusedValue(\.goToLineAction) private var goToLineAction
    @FocusedValue(\.goToHeadingAction) private var goToHeadingAction
    @FocusedValue(\.navigationHistoryActions) private var navigationHistoryActions
    @ObservedObject var settingsStore: EditorSettingsStore

    var body: some Commands {
        CommandMenu("移動") {
            Button("戻る") { navigationHistoryActions?.goBack() }
                .keyboardShortcut("[", modifiers: [.command, .option])
                .disabled(navigationHistoryActions?.canGoBack != true)
            Button("進む") { navigationHistoryActions?.goForward() }
                .keyboardShortcut("]", modifiers: [.command, .option])
                .disabled(navigationHistoryActions?.canGoForward != true)
            Divider()
            Button("指定行へ移動…") { goToLineAction?() }
                .keyboardShortcut("l", modifiers: .command)
                .disabled(goToLineAction == nil)
            Button("見出しへ移動…") { goToHeadingAction?() }
                .keyboardShortcut("o", modifiers: [.command, .shift])
                .disabled(goToHeadingAction == nil)
        }
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
