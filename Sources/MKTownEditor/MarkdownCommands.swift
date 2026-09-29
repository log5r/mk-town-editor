import SwiftUI

private struct MarkdownEditorModelKey: FocusedValueKey {
    typealias Value = MarkdownEditorModel
}

struct FocusModeActions {
    let isActive: Bool
    let toggle: () -> Void
}

private struct FocusModeActionsKey: FocusedValueKey {
    typealias Value = FocusModeActions
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

private struct ExportHTMLActionKey: FocusedValueKey {
    typealias Value = () -> Void
}

private struct ExportPDFActionKey: FocusedValueKey {
    typealias Value = () -> Void
}

private struct ExportExternalActionKey: FocusedValueKey {
    typealias Value = () -> Void
}

private struct ImportRichTextActionKey: FocusedValueKey {
    typealias Value = () -> Void
}

private struct ExportPortablePackageActionKey: FocusedValueKey {
    typealias Value = () -> Void
}

private struct ExportWorkspaceBatchActionKey: FocusedValueKey {
    typealias Value = () -> Void
}

private struct PageSetupActionKey: FocusedValueKey {
    typealias Value = () -> Void
}

private struct PrintDocumentActionKey: FocusedValueKey {
    typealias Value = () -> Void
}

private struct CopyRichActionKey: FocusedValueKey {
    typealias Value = () -> Void
}

private struct ExportPlainTextActionKey: FocusedValueKey {
    typealias Value = () -> Void
}

private struct OpenQuickFileActionKey: FocusedValueKey {
    typealias Value = () -> Void
}

private struct SearchWorkspaceActionKey: FocusedValueKey {
    typealias Value = () -> Void
}

private struct ReplaceWorkspaceActionKey: FocusedValueKey {
    typealias Value = () -> Void
}

private struct OpenEncodingImportActionKey: FocusedValueKey {
    typealias Value = () -> Void
}

struct TextFormatActions {
    let format: MarkdownTextFormat
    let setNewline: (MarkdownTextFormat.Newline) -> Void
    let setBOM: (Bool) -> Void
}

private struct TextFormatActionsKey: FocusedValueKey {
    typealias Value = TextFormatActions
}

struct PreviewSearchActions {
    let show: () -> Void
    let next: () -> Void
    let previous: () -> Void
}

private struct PreviewSearchActionsKey: FocusedValueKey {
    typealias Value = PreviewSearchActions
}

extension FocusedValues {
    var focusModeActions: FocusModeActions? {
        get { self[FocusModeActionsKey.self] }
        set { self[FocusModeActionsKey.self] = newValue }
    }
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
    var exportHTMLAction: (() -> Void)? {
        get { self[ExportHTMLActionKey.self] }
        set { self[ExportHTMLActionKey.self] = newValue }
    }
    var exportPDFAction: (() -> Void)? {
        get { self[ExportPDFActionKey.self] }
        set { self[ExportPDFActionKey.self] = newValue }
    }
    var exportExternalAction: (() -> Void)? {
        get { self[ExportExternalActionKey.self] }
        set { self[ExportExternalActionKey.self] = newValue }
    }
    var importRichTextAction: (() -> Void)? {
        get { self[ImportRichTextActionKey.self] }
        set { self[ImportRichTextActionKey.self] = newValue }
    }
    var exportPortablePackageAction: (() -> Void)? {
        get { self[ExportPortablePackageActionKey.self] }
        set { self[ExportPortablePackageActionKey.self] = newValue }
    }
    var exportWorkspaceBatchAction: (() -> Void)? {
        get { self[ExportWorkspaceBatchActionKey.self] }
        set { self[ExportWorkspaceBatchActionKey.self] = newValue }
    }
    var pageSetupAction: (() -> Void)? {
        get { self[PageSetupActionKey.self] }
        set { self[PageSetupActionKey.self] = newValue }
    }
    var printDocumentAction: (() -> Void)? {
        get { self[PrintDocumentActionKey.self] }
        set { self[PrintDocumentActionKey.self] = newValue }
    }
    var copyRichAction: (() -> Void)? {
        get { self[CopyRichActionKey.self] }
        set { self[CopyRichActionKey.self] = newValue }
    }
    var exportPlainTextAction: (() -> Void)? {
        get { self[ExportPlainTextActionKey.self] }
        set { self[ExportPlainTextActionKey.self] = newValue }
    }
    var openQuickFileAction: (() -> Void)? {
        get { self[OpenQuickFileActionKey.self] }
        set { self[OpenQuickFileActionKey.self] = newValue }
    }
    var searchWorkspaceAction: (() -> Void)? {
        get { self[SearchWorkspaceActionKey.self] }
        set { self[SearchWorkspaceActionKey.self] = newValue }
    }
    var replaceWorkspaceAction: (() -> Void)? {
        get { self[ReplaceWorkspaceActionKey.self] }
        set { self[ReplaceWorkspaceActionKey.self] = newValue }
    }
    var openEncodingImportAction: (() -> Void)? {
        get { self[OpenEncodingImportActionKey.self] }
        set { self[OpenEncodingImportActionKey.self] = newValue }
    }
    var textFormatActions: TextFormatActions? {
        get { self[TextFormatActionsKey.self] }
        set { self[TextFormatActionsKey.self] = newValue }
    }
    var previewSearchActions: PreviewSearchActions? {
        get { self[PreviewSearchActionsKey.self] }
        set { self[PreviewSearchActionsKey.self] = newValue }
    }
}

struct MarkdownCommands: Commands {
    @FocusedValue(\.focusModeActions) private var focusModeActions
    @FocusedValue(\.markdownEditorModel) private var editorModel
    @FocusedValue(\.goToLineAction) private var goToLineAction
    @FocusedValue(\.goToHeadingAction) private var goToHeadingAction
    @FocusedValue(\.navigationHistoryActions) private var navigationHistoryActions
    @FocusedValue(\.zoomActions) private var zoomActions
    @FocusedValue(\.regexSearchAction) private var regexSearchAction
    @FocusedValue(\.exportHTMLAction) private var exportHTMLAction
    @FocusedValue(\.exportPDFAction) private var exportPDFAction
    @FocusedValue(\.exportExternalAction) private var exportExternalAction
    @FocusedValue(\.importRichTextAction) private var importRichTextAction
    @FocusedValue(\.exportPortablePackageAction) private var exportPortablePackageAction
    @FocusedValue(\.exportWorkspaceBatchAction) private var exportWorkspaceBatchAction
    @FocusedValue(\.pageSetupAction) private var pageSetupAction
    @FocusedValue(\.printDocumentAction) private var printDocumentAction
    @FocusedValue(\.copyRichAction) private var copyRichAction
    @FocusedValue(\.exportPlainTextAction) private var exportPlainTextAction
    @FocusedValue(\.openQuickFileAction) private var openQuickFileAction
    @FocusedValue(\.searchWorkspaceAction) private var searchWorkspaceAction
    @FocusedValue(\.replaceWorkspaceAction) private var replaceWorkspaceAction
    @FocusedValue(\.openEncodingImportAction) private var openEncodingImportAction
    @FocusedValue(\.textFormatActions) private var textFormatActions
    @FocusedValue(\.previewSearchActions) private var previewSearchActions
    @ObservedObject var settingsStore: EditorSettingsStore
    @ObservedObject var workspaceStore: WorkspaceStore

    var body: some Commands {
        CommandGroup(replacing: .printItem) {
            Button("ページ設定…") { pageSetupAction?() }
                .disabled(pageSetupAction == nil)
            Button("印刷…") { printDocumentAction?() }
                .keyboardShortcut("p", modifiers: .command)
                .disabled(printDocumentAction == nil)
        }
        CommandGroup(after: .pasteboard) {
            Button("HTML・RTFとしてコピー") { copyRichAction?() }
                .disabled(copyRichAction == nil || editorModel?.hasActiveEditor != true ||
                          editorModel?.selectedRange.length == 0)
        }
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
        CommandMenu("集中モード") {
            Button(focusModeActions?.isActive == true ? "集中モードを終了" : "集中モードを開始") {
                focusModeActions?.toggle()
            }
            .keyboardShortcut("j", modifiers: [.command, .shift])
            .disabled(focusModeActions == nil)
        }
        CommandMenu("ワークスペース") {
            Button("フォルダを開く…") { workspaceStore.chooseFolder() }
                .keyboardShortcut("o", modifiers: [.command, .option])
            Button("ファイル名で開く…") { openQuickFileAction?() }
                .keyboardShortcut("p", modifiers: [.command, .option])
                .disabled(openQuickFileAction == nil || workspaceStore.rootURL == nil)
            Button("フォルダ全体を検索…") { searchWorkspaceAction?() }
                .keyboardShortcut("f", modifiers: [.command, .option, .shift])
                .disabled(searchWorkspaceAction == nil || workspaceStore.rootURL == nil)
            Button("複数ファイルを置換…") { replaceWorkspaceAction?() }
                .disabled(replaceWorkspaceAction == nil || workspaceStore.rootURL == nil)
            Button("ファイル一覧を更新") { workspaceStore.refresh(force: true) }
                .disabled(workspaceStore.rootURL == nil)
        }
        CommandMenu("文字コード") {
            Button("文字コードを指定して取り込む…") { openEncodingImportAction?() }
                .disabled(openEncodingImportAction == nil)
            Divider()
            Text("改行形式")
            ForEach(MarkdownTextFormat.Newline.allCases) { newline in
                Button {
                    textFormatActions?.setNewline(newline)
                } label: {
                    if textFormatActions?.format.newline == newline {
                        Label(newline.title, systemImage: "checkmark")
                    } else {
                        Text(newline.title)
                    }
                }
                .disabled(textFormatActions == nil)
            }
            Divider()
            Button {
                if let format = textFormatActions?.format {
                    textFormatActions?.setBOM(!format.hasUTF8BOM)
                }
            } label: {
                if textFormatActions?.format.hasUTF8BOM == true {
                    Label("UTF-8 BOM", systemImage: "checkmark")
                } else {
                    Text("UTF-8 BOM")
                }
            }
            .disabled(textFormatActions == nil)
        }
        CommandMenu("取り込み") {
            Button("HTML・RTFからMarkdownへ…") { importRichTextAction?() }
                .disabled(importRichTextAction == nil)
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
                .keyboardShortcut("0", modifiers: [.command, .option, .shift])
                .disabled(zoomActions == nil)
        }
        CommandMenu("書き出し") {
            Button("HTML…") { exportHTMLAction?() }
                .disabled(exportHTMLAction == nil)
            Button("PDF…") { exportPDFAction?() }
                .disabled(exportPDFAction == nil)
            Button("DOCX・ODT・EPUB…") { exportExternalAction?() }
                .disabled(exportExternalAction == nil)
            Button("添付を含むパッケージ…") { exportPortablePackageAction?() }
                .disabled(exportPortablePackageAction == nil)
            Button("複数文書を一括書き出し…") { exportWorkspaceBatchAction?() }
                .disabled(exportWorkspaceBatchAction == nil)
            Button("テキスト…") { exportPlainTextAction?() }
                .disabled(exportPlainTextAction == nil)
        }
        CommandGroup(after: .textEditing) {
            Divider()
            if let previewSearchActions {
                Button("検索…") { previewSearchActions.show() }
                    .keyboardShortcut("f", modifiers: .command)
            } else {
                commandButton(.find)
            }
            Button("次を検索") {
                if let previewSearchActions { previewSearchActions.next() }
                else { editorModel?.findNext() }
            }
                .keyboardShortcut("g", modifiers: .command)
                .disabled(previewSearchActions == nil && editorModel == nil)
            Button("前を検索") {
                if let previewSearchActions { previewSearchActions.previous() }
                else { editorModel?.findPrevious() }
            }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(previewSearchActions == nil && editorModel == nil)
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
            commandButton(.convertLinkForm)
            commandButton(.footnote)
            commandButton(.image)
            commandButton(.table)
            Button("TSV・CSVから表へ変換…") { editorModel?.convertClipboardTable() }
                .disabled(editorModel?.canExecuteCommand != true)
            Menu("表を編集") {
                Button("グリッドで編集…") { editorModel?.presentTableGrid() }
                    .disabled(editorModel?.canPresentTableGrid != true)
                Divider()
                Button("下に行を追加") { editorModel?.editTable(.insertRow) }
                    .disabled(editorModel?.canEditTable(.insertRow) != true)
                Button("行を削除") { editorModel?.editTable(.deleteRow) }
                    .disabled(editorModel?.canEditTable(.deleteRow) != true)
                Divider()
                Button("選択行を上へ移動") { editorModel?.editTable(.moveRowUp) }
                    .disabled(editorModel?.canEditTable(.moveRowUp) != true)
                Button("選択行を下へ移動") { editorModel?.editTable(.moveRowDown) }
                    .disabled(editorModel?.canEditTable(.moveRowDown) != true)
                Divider()
                Button("右に列を追加") { editorModel?.editTable(.insertColumn) }
                    .disabled(editorModel?.canEditTable(.insertColumn) != true)
                Button("列を削除") { editorModel?.editTable(.deleteColumn) }
                    .disabled(editorModel?.canEditTable(.deleteColumn) != true)
                Divider()
                Button("列を左へ移動") { editorModel?.editTable(.moveColumnLeft) }
                    .disabled(editorModel?.canEditTable(.moveColumnLeft) != true)
                Button("列を右へ移動") { editorModel?.editTable(.moveColumnRight) }
                    .disabled(editorModel?.canEditTable(.moveColumnRight) != true)
                Divider()
                Button("選択列で昇順にソート") { editorModel?.editTable(.sortRowsAscending) }
                    .disabled(editorModel?.canEditTable(.sortRowsAscending) != true)
                Button("選択列で降順にソート") { editorModel?.editTable(.sortRowsDescending) }
                    .disabled(editorModel?.canEditTable(.sortRowsDescending) != true)
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
                Divider()
                Button("表を整形") { editorModel?.editTable(.formatTable) }
                    .disabled(editorModel?.canEditTable(.formatTable) != true)
            }
            Menu("見出しレベル") {
                commandButton(.heading(level: 0))
                Divider()
                ForEach(1...6, id: \.self) { level in
                    commandButton(.heading(level: level))
                }
            }
            commandButton(.quote)
            commandButton(.plainBlock)
            commandButton(.removeFormatting)
            commandButton(.tableOfContents)
            commandButton(.renumberList)
            commandButton(.duplicateLines)
            commandButton(.moveLinesUp)
            commandButton(.moveLinesDown)
            commandButton(.deleteLines)
            commandButton(.comment)
            commandButton(.expandSelection)
            commandButton(.shrinkSelection)
            commandButton(.selectNextOccurrence)
            commandButton(.toggleFold)
            commandButton(.unfoldAll)
            commandButton(.snippet)
            commandButton(.commandPalette)
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
        if let shortcut = settingsStore.shortcut(for: command), let key = shortcut.keyEquivalent {
            button.keyboardShortcut(key, modifiers: shortcut.modifiers)
        } else {
            button
        }
    }
}
