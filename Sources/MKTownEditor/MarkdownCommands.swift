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

struct ZoomActions {
    let adjust: (EditorZoomSurface, Double) -> Void
    let reset: (EditorZoomSurface) -> Void
}

private struct ZoomActionsKey: FocusedValueKey {
    typealias Value = ZoomActions
}

private struct RegexSearchActionKey: FocusedValueKey {
    typealias Value = () -> Void
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
    var zoomActions: ZoomActions? {
        get { self[ZoomActionsKey.self] }
        set { self[ZoomActionsKey.self] = newValue }
    }
    var regexSearchAction: (() -> Void)? {
        get { self[RegexSearchActionKey.self] }
        set { self[RegexSearchActionKey.self] = newValue }
    }
}

struct MarkdownCommands: Commands {
    @FocusedValue(\.markdownEditorModel) private var editorModel
    @FocusedValue(\.goToLineAction) private var goToLineAction
    @FocusedValue(\.goToHeadingAction) private var goToHeadingAction
    @FocusedValue(\.navigationHistoryActions) private var navigationHistoryActions
    @FocusedValue(\.zoomActions) private var zoomActions
    @FocusedValue(\.regexSearchAction) private var regexSearchAction
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
        CommandMenu("表示倍率") {
            Text("編集: \(Int((settingsStore.zoom(for: .editor) * 100).rounded()))%")
            Button("編集を拡大") { zoomActions?.adjust(.editor, 0.1) }
                .keyboardShortcut("+", modifiers: .command)
                .disabled(zoomActions == nil)
            Button("編集を縮小") { zoomActions?.adjust(.editor, -0.1) }
                .keyboardShortcut("-", modifiers: .command)
                .disabled(zoomActions == nil)
            Button("編集を標準サイズに戻す") { zoomActions?.reset(.editor) }
                .keyboardShortcut("0", modifiers: .command)
                .disabled(zoomActions == nil)
            Divider()
            Text("プレビュー: \(Int((settingsStore.zoom(for: .preview) * 100).rounded()))%")
            Button("プレビューを拡大") { zoomActions?.adjust(.preview, 0.1) }
                .keyboardShortcut("+", modifiers: [.command, .option])
                .disabled(zoomActions == nil)
            Button("プレビューを縮小") { zoomActions?.adjust(.preview, -0.1) }
                .keyboardShortcut("-", modifiers: [.command, .option])
                .disabled(zoomActions == nil)
            Button("プレビューを標準サイズに戻す") { zoomActions?.reset(.preview) }
                .keyboardShortcut("0", modifiers: [.command, .option])
                .disabled(zoomActions == nil)
        }
        CommandGroup(after: .textEditing) {
            Divider()
            commandButton(.find)
            Button("次を検索") { editorModel?.findNext() }
                .keyboardShortcut("g", modifiers: .command)
                .disabled(editorModel == nil)
            Button("前を検索") { editorModel?.findPrevious() }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(editorModel == nil)
            Button("置換…") { editorModel?.showReplaceBar() }
                .keyboardShortcut("f", modifiers: [.command, .option])
                .disabled(editorModel == nil)
            Button("すべて置換") { editorModel?.replaceAllMatches() }
                .keyboardShortcut("r", modifiers: [.command, .option, .shift])
                .disabled(editorModel?.canExecuteCommand != true)
            Button("選択範囲をすべて置換") { editorModel?.replaceAllInSelection() }
                .disabled(editorModel?.canExecuteCommand != true ||
                          editorModel?.selectedRange.length == 0)
            Divider()
            Button("正規表現検索・置換…") { regexSearchAction?() }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .disabled(regexSearchAction == nil)
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
            Menu("表を編集") {
                Button("下に行を追加") { editorModel?.editTable(.insertRow) }
                    .disabled(editorModel?.canEditTable(.insertRow) != true)
                Button("行を削除") { editorModel?.editTable(.deleteRow) }
                    .disabled(editorModel?.canEditTable(.deleteRow) != true)
                Divider()
                Button("右に列を追加") { editorModel?.editTable(.insertColumn) }
                    .disabled(editorModel?.canEditTable(.insertColumn) != true)
                Button("列を削除") { editorModel?.editTable(.deleteColumn) }
                    .disabled(editorModel?.canEditTable(.deleteColumn) != true)
                Divider()
                Picker("選択列の配置", selection: Binding<MarkdownTable.Alignment?>(
                    get: { editorModel?.selectedTableAlignment },
                    set: { if let alignment = $0 { editorModel?.editTable(.alignColumn(alignment)) } }
                )) {
                    Text("左揃え").tag(MarkdownTable.Alignment.leading as MarkdownTable.Alignment?)
                    Text("中央揃え").tag(MarkdownTable.Alignment.center as MarkdownTable.Alignment?)
                    Text("右揃え").tag(MarkdownTable.Alignment.trailing as MarkdownTable.Alignment?)
                }
                .disabled(editorModel?.selectedTableAlignment == nil)
            }
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
