import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct EditorWorkspace: View {
    @Binding var document: MarkdownDocument
    let fileURL: URL?
    @EnvironmentObject private var settingsStore: EditorSettingsStore
    @EnvironmentObject private var documentLinkNavigation: DocumentLinkNavigation
    @EnvironmentObject private var workspaceStore: WorkspaceStore
    @Environment(\.undoManager) private var undoManager
    @Environment(\.openDocument) private var openDocument
    @StateObject private var editorModel = MarkdownEditorModel()
    @StateObject private var analysisStore = DocumentAnalysisStore()
    @State private var previewTaskUndoTarget = PreviewTaskUndoTarget()
    @StateObject private var detachedPreview = DetachedPreviewWindowManager()
    @StateObject private var previewUpdates = PreviewUpdateController()
    @SceneStorage("editorMode") private var legacyMode: String?
    @State private var unsavedMode: EditorMode = .split
    @State private var imageDropError: String?
    @State private var pasteNeedsSave = false
    @State private var sidebarVisibility: NavigationSplitViewVisibility = .detailOnly
    @State private var focusMode = FocusModeState()
    @State private var splitRatio = 0.5
    @State private var splitOrientation: EditorSplitOrientation = .sideBySide
    @State private var previewFirst = false
    @State private var splitDragStart: Double?
    @State private var previewNavigationTarget: PreviewNavigationTarget?
    @State private var navigationSequence = 0
    @State private var showingGoToLine = false
    @State private var showingGoToHeading = false
    @State private var navigationHistory = NavigationHistory()
    @State private var missingHeading: String?
    @State private var documentLinkError: String?
    @State private var showingLinkDiagnostics = false
    @State private var isCheckingLinks = false
    @State private var linkDiagnostics: [MarkdownLinkDiagnostic] = []
    @State private var showingMarkdownLint = false
    @State private var isCheckingMarkdownLint = false
    @State private var markdownLintDiagnostics: [MarkdownLintDiagnostic] = []
    @State private var showingAutoFormat = false
    @State private var synchronizedBlockID: Int?
    @State private var showingRegexSearch = false
    @State private var htmlExportError: String?
    @State private var pdfExportError: String?
    @State private var isExportingPDF = false
    @State private var showingPrintSettings = false
    @State private var printInfo = NSPrintInfo.shared.copy() as! NSPrintInfo
    @State private var printSettings = MarkdownPrintSettings()
    @State private var printError: String?
    @State private var printRequested = false
    @State private var richCopyError: String?
    @State private var showingPlainExport = false
    @State private var showingExternalExport = false
    @State private var showingRichImport = false
    @State private var showingPortablePackage = false
    @State private var showingBatchExport = false
    @State private var plainExportRequested = false
    @State private var plainOptions = MarkdownPlainTextOptions()
    @State private var plainExportError: String?
    @State private var exportFormat: MarkdownExportFormat?
    @State private var pendingExport: (MarkdownExportFormat, MarkdownExportPreset)?
    @State private var sidebarTab: SidebarTab = .outline
    @State private var workspaceOpenError: String?
    @State private var showingQuickOpen = false
    @State private var showingWorkspaceSearch = false
    @State private var showingWorkspaceReplace = false
    @State private var showingAttachmentAudit = false
    @State private var showingSnapshotHistory = false
    @State private var showingFolderSettings = false
    @State private var showingPreviewSearch = false
    @State private var previewSearchQuery = ""
    @State private var previewSearchCaseSensitive = false
    @State private var previewSearchRange: NSRange?
    @State private var showingStatistics = false
    @State private var writingGoalInput = ""
    @State private var unsavedSessionBaseline: Int?
    @State private var fileAction: WorkspaceFileAction?
    @State private var encodingImport: EncodingImport?
    @State private var encodingImportError: String?
    @State private var workspaceViewActive = false
    @State private var openBufferID = UUID()

    private enum SidebarTab: String, CaseIterable {
        case outline = "アウトライン"
        case inspector = "インスペクタ"
        case bookmarks = "ブックマーク"
        case files = "ファイル"

        var title: String {
            switch self {
            case .outline: String(localized: "アウトライン")
            case .inspector: String(localized: "インスペクタ")
            case .bookmarks: String(localized: "ブックマーク")
            case .files: String(localized: "ファイル")
            }
        }
    }

    private struct EncodingImport: Identifiable {
        let id = UUID()
        let url: URL
        let data: Data
    }

    private var mode: Binding<EditorMode> {
        Binding(
            get: { fileURL.map(settingsStore.mode(for:)) ?? unsavedMode },
            set: { newMode in
                if let fileURL {
                    settingsStore.setMode(newMode, for: fileURL)
                } else {
                    unsavedMode = newMode
                }
            }
        )
    }

    private var statistics: DocumentStatistics {
        if let snapshot = analysisStore.snapshot, snapshot.source == document.text {
            return snapshot.statistics
        }
        return DocumentStatistics(text: document.text)
    }

    private var selectionStatistics: DocumentStatistics? {
        DocumentStatistics.selection(in: document.text, ranges: editorModel.selectedRanges)
    }

    private var wordCountMode: WordCountMode {
        settingsStore.app.wordCountMode ?? .whitespace
    }

    private var displayedWordCount: Int {
        if wordCountMode == .whitespace { return statistics.words }
        return wordCountMode.count(in: document.text)
    }

    private var wordCountBinding: Binding<WordCountMode> {
        Binding(get: { wordCountMode }, set: { mode in
            var settings = settingsStore.app
            settings.wordCountMode = mode
            settingsStore.setAppSettings(settings)
        })
    }

    private var readingEstimate: ReadingEstimateSettings {
        settingsStore.app.readingEstimate ?? ReadingEstimateSettings()
    }

    private func updateReadingEstimate(_ update: (inout ReadingEstimateSettings) -> Void) {
        var value = readingEstimate
        update(&value)
        var settings = settingsStore.app
        settings.readingEstimate = value
        settingsStore.setAppSettings(settings)
    }

    private var readingLanguageBinding: Binding<ReadingLanguage> {
        Binding(get: { readingEstimate.language },
                set: { language in updateReadingEstimate { $0.language = language } })
    }

    private func rateBinding(spoken: Bool) -> Binding<Int> {
        Binding(get: { spoken ? readingEstimate.speakingRate : readingEstimate.readingRate },
                set: { rate in
                    updateReadingEstimate { value in
                        switch (value.language, spoken) {
                        case (.japanese, false): value.japaneseReadingRate = rate
                        case (.japanese, true): value.japaneseSpeakingRate = rate
                        case (.english, false): value.englishReadingRate = rate
                        case (.english, true): value.englishSpeakingRate = rate
                        }
                    }
                })
    }

    private var sectionStatistics: (title: String, value: DocumentStatistics)? {
        guard let snapshot = analysisStore.snapshot, snapshot.source == document.text else { return nil }
        let entries = MarkdownOutline.entries(in: snapshot.analysis)
        guard let heading = MarkdownOutline.currentSection(at: editorModel.selectedRange.location,
                                                           in: entries),
              let range = DocumentStatistics.sectionRange(
                at: editorModel.selectedRange.location, in: snapshot.analysis,
                documentLength: (document.text as NSString).length) else { return nil }
        let section = (document.text as NSString).substring(with: range)
        return (heading.title, DocumentStatistics(text: section))
    }

    private var documentContext: DocumentContext {
        DocumentContext(fileURL: fileURL,
                        attachmentDirectory: settingsStore.attachmentDirectory(for: fileURL),
                        markdownDialect: settingsStore.markdownDialect(for: fileURL))
    }

    private var navigationView: some View {
        NavigationSplitView(columnVisibility: $sidebarVisibility) {
            workspaceSidebar
                .navigationSplitViewColumnWidth(min: 190, ideal: 230, max: 320)
        } detail: {
            VStack(spacing: 0) {
                editorContent
                if !focusMode.isActive {
                    Divider()
                    statusBar
                }
            }
            .frame(minWidth: 720, minHeight: 480)
            .overlay(alignment: .topTrailing) {
                if focusMode.isActive {
                    Button("集中モードを終了", systemImage: "arrow.down.right.and.arrow.up.left") {
                        toggleFocusMode()
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .padding(12)
                    .help("集中モードを終了")
                }
            }
        }
        .toolbar(id: "mktown-editor") {
            ToolbarItem(id: "sidebar", placement: .navigation) {
                Button("サイドバー", systemImage: "sidebar.left") {
                    sidebarVisibility = sidebarVisibility == .detailOnly ? .all : .detailOnly
                }
                .help("サイドバーを表示または隠す")
            }
            ForEach(EditorCommand.toolbar, id: \.self) { command in
                ToolbarItem(id: "command-\(command.toolbarIdentifier)", placement: .primaryAction,
                            showsByDefault: EditorCommand.defaultToolbar.contains(command)) {
                    formatButton(command)
                }
            }

            ToolbarItem(id: "link-diagnostics", placement: .primaryAction) {
                Button("リンク診断", systemImage: "link") {
                    showingLinkDiagnostics = true
                    checkLinks()
                }
                .help("ローカルリンクの参照先を確認")
            }
            ToolbarItem(id: "snapshots", placement: .primaryAction) {
                Button("明示スナップショット", systemImage: "clock.arrow.circlepath") {
                    showingSnapshotHistory = true
                }
                .disabled(fileURL == nil)
                .help("名前を付けた本文履歴を保存・比較・復元")
            }
            ToolbarItem(id: "writing-tools", placement: .primaryAction) {
                Menu("文章ツール", systemImage: "text.badge.checkmark") {
                    Button("Markdown診断") {
                        showingMarkdownLint = true
                        checkMarkdownLint()
                    }
                    Button("自動整形…") { showingAutoFormat = true }
                }
                .help("Markdown診断と自動整形")
            }

            ToolbarItem(id: "display-mode", placement: .principal) {
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
            ToolbarItem(id: "split-layout", placement: .primaryAction) {
                Menu("分割配置", systemImage: "rectangle.split.2x1") {
                    Picker("方向", selection: $splitOrientation) {
                        ForEach(EditorSplitOrientation.allCases, id: \.self) { orientation in
                            Text(orientation.title).tag(orientation)
                        }
                    }
                    Toggle("プレビューを先に表示", isOn: $previewFirst)
                }
                .disabled(mode.wrappedValue != .split)
            }
            ToolbarItem(id: "detached-preview", placement: .primaryAction) {
                Button("プレビューを別ウインドウで開く", systemImage: "rectangle.on.rectangle") {
                    detachedPreview.show(document: $document, documentURL: fileURL,
                                         settingsStore: settingsStore, updates: previewUpdates)
                }
                .help("現在の書類のプレビューを別ウインドウで表示")
            }
        }
        .toolbar(focusMode.isActive ? .hidden : .automatic, for: .windowToolbar)
        .focusedSceneValue(\.focusModeActions, FocusModeActions(
            isActive: focusMode.isActive, toggle: toggleFocusMode))
        .focusedSceneValue(\.markdownEditorModel, editorModel)
        .focusedSceneValue(\.goToLineAction) { showingGoToLine = true }
        .focusedSceneValue(\.goToHeadingAction) { showingGoToHeading = true }
        .focusedSceneValue(\.navigationHistoryActions, NavigationHistoryActions(
            canGoBack: navigationHistory.canGoBack,
            canGoForward: navigationHistory.canGoForward,
            goBack: { goBack() }, goForward: { goForward() }
        ))
        .focusedSceneValue(\.zoomActions, ZoomActions(
            adjust: { surface, amount in settingsStore.adjustZoom(for: surface, by: amount) },
            reset: { surface in settingsStore.resetZoom(for: surface) }
        ))
        .focusedSceneValue(\.regexSearchAction) {
            if mode.wrappedValue == .preview { mode.wrappedValue = .editor }
            showingRegexSearch = true
        }
        .focusedSceneValue(\.exportHTMLAction) { exportHTML() }
        .focusedSceneValue(\.exportPDFAction) { exportPDF() }
        .focusedSceneValue(\.exportExternalAction) { showingExternalExport = true }
        .focusedSceneValue(\.importRichTextAction) { showingRichImport = true }
        .focusedSceneValue(\.exportPortablePackageAction) { showingPortablePackage = true }
        .focusedSceneValue(\.exportWorkspaceBatchAction) { showingBatchExport = true }
        .focusedSceneValue(\.pageSetupAction) { pageSetup() }
        .focusedSceneValue(\.printDocumentAction) { showingPrintSettings = true }
        .focusedSceneValue(\.copyRichAction) { copyRichSelection() }
        .focusedSceneValue(\.exportPlainTextAction) { showingPlainExport = true }
        .focusedSceneValue(\.openQuickFileAction) { showingQuickOpen = true }
        .focusedSceneValue(\.searchWorkspaceAction) { showingWorkspaceSearch = true }
        .focusedSceneValue(\.replaceWorkspaceAction) { showingWorkspaceReplace = true }
        .focusedSceneValue(\.previewSearchActions,
            mode.wrappedValue == .preview ? PreviewSearchActions(
                show: { showingPreviewSearch = true },
                next: { navigatePreviewSearch(backwards: false) },
                previous: { navigatePreviewSearch(backwards: true) }
            ) : nil)
        .focusedSceneValue(\.openEncodingImportAction) { chooseEncodingImport() }
        .focusedSceneValue(\.textFormatActions, TextFormatActions(
            format: document.format,
            setNewline: { document.format.newline = $0 },
            setBOM: { document.format.hasUTF8BOM = $0 }
        ))
    }

    private var sheetView: some View {
        navigationView
        .sheet(isPresented: $showingGoToLine) {
            let index = MarkdownLineIndex(document.text)
            GoToLineSheet(lineCount: index.lineCount,
                          initialLine: index.line(containingUTF16Offset: editorModel.selectedRange.location)) { line in
                goToLine(line)
            }
        }
        .sheet(isPresented: $showingPrintSettings, onDismiss: {
            guard printRequested else { return }
            printRequested = false
            printDocument()
        }) {
            MarkdownPrintSettingsSheet(settings: printSettings, paperSize: printInfo.paperSize) { settings in
                printSettings = settings
                printRequested = true
            }
        }
        .sheet(isPresented: $showingPlainExport, onDismiss: {
            guard plainExportRequested else { return }
            plainExportRequested = false
            exportPlainText()
        }) {
            MarkdownPlainTextExportSheet(options: plainOptions) { options in
                plainOptions = options
                plainExportRequested = true
            }
        }
        .sheet(isPresented: $showingExternalExport) {
            ExternalConversionSheet(markdown: document.text, documentURL: fileURL,
                dialect: settingsStore.markdownDialect(for: fileURL))
        }
        .sheet(isPresented: $showingRichImport) {
            RichTextImportSheet(currentText: $document.text) { imported, expected in
                guard document.text == expected else { return false }
                if editorModel.hasActiveEditor {
                    let range = NSRange(location: 0, length: (expected as NSString).length)
                    let edit = MarkdownEdit(range: range, replacement: imported,
                        selection: NSRange(location: 0, length: 0))
                    return editorModel.applyRegexEdit(edit, expectedSource: expected)
                }
                previewTaskUndoTarget.replaceText(imported, in: $document.text,
                    undoManager: undoManager, actionName: String(localized: "HTML・RTFを取り込む"))
                return true
            }
        }
        .sheet(isPresented: $showingPortablePackage) {
            PortablePackageSheet(source: document.text, documentURL: fileURL,
                                 dialect: settingsStore.markdownDialect(for: fileURL))
        }
        .sheet(isPresented: $showingBatchExport) { WorkspaceBatchExportSheet() }
        .sheet(item: $exportFormat, onDismiss: {
            guard let request = pendingExport else { return }
            pendingExport = nil
            switch request.0 {
            case .html: saveHTML(preset: request.1)
            case .pdf: savePDF(preset: request.1)
            }
        }) { format in
            MarkdownExportPresetSheet(format: format) { preset in
                pendingExport = (format, preset)
            }
        }
        .sheet(isPresented: $showingQuickOpen) {
            WorkspaceQuickOpenSheet { url in
                Task {
                    do { try await openDocument(at: url) }
                    catch { workspaceOpenError = error.localizedDescription }
                }
            }
        }
        .sheet(isPresented: $showingWorkspaceSearch) {
            WorkspaceSearchSheet { result in openWorkspaceSearchResult(result) }
        }
        .sheet(isPresented: $showingWorkspaceReplace) {
            WorkspaceReplaceSheet(currentDocumentURL: fileURL) {
                workspaceStore.refresh(force: true)
            }
        }
        .sheet(isPresented: $showingAttachmentAudit) {
            if let root = workspaceStore.rootURL {
                WorkspaceAttachmentAuditSheet(root: root) { url in
                    Task {
                        do { try await openDocument(at: url) }
                        catch { workspaceOpenError = error.localizedDescription }
                    }
                }
            }
        }
        .sheet(isPresented: $showingSnapshotHistory) {
            if let fileURL {
                WorkspaceSnapshotHistorySheet(documentURL: fileURL,
                    currentText: $document.text) { restored, expected in
                    guard document.text == expected else { return false }
                    if editorModel.hasActiveEditor {
                        let range = NSRange(location: 0, length: (expected as NSString).length)
                        let edit = MarkdownEdit(range: range, replacement: restored,
                            selection: NSRange(location: 0, length: 0))
                        return editorModel.applyRegexEdit(edit, expectedSource: expected)
                    }
                    previewTaskUndoTarget.replaceText(restored, in: $document.text,
                        undoManager: undoManager, actionName: String(localized: "スナップショットを復元"))
                    return true
                }
            }
        }
        .sheet(isPresented: $showingFolderSettings) {
            if let root = workspaceStore.rootURL {
                FolderEditorSettingsView(settingsStore: settingsStore, folderURL: root)
            }
        }
        .sheet(isPresented: $showingPreviewSearch) {
            PreviewSearchSheet(query: $previewSearchQuery,
                               caseSensitive: $previewSearchCaseSensitive,
                               source: document.text,
                               selectedLocation: previewSearchRange?.location,
                               onNavigate: navigatePreviewMatch)
        }
        .sheet(item: $fileAction) { action in
            if let root = workspaceStore.rootURL {
                WorkspaceFileOperationSheet(action: action, rootURL: root,
                                            currentDocumentURL: fileURL) {
                    workspaceStore.refresh(force: true)
                }
            }
        }
        .sheet(item: $encodingImport) { input in
            MarkdownEncodingImportSheet(sourceURL: input.url, sourceData: input.data) { url in
                Task {
                    do { try await openDocument(at: url) }
                    catch { encodingImportError = error.localizedDescription }
                }
            }
        }
        .sheet(isPresented: $showingGoToHeading) {
            GoToHeadingSheet(entries: analysisStore.snapshot?.source == document.text ? outlineEntries : []) {
                navigate(to: $0)
            }
        }
        .sheet(isPresented: $showingRegexSearch) {
            RegexSearchSheet(source: document.text, selectedRange: editorModel.selectedRange,
                             initialScope: editorModel.selectedRange,
                             onSelect: { range in
                                let destination = NavigationPoint(documentURL: fileURL,
                                                                  utf16Location: range.location)
                                navigationHistory.recordJump(from: currentNavigationPoint, to: destination)
                                editorModel.selectAndReveal(range)
                             }, onReplace: { edit, source in
                                editorModel.applyRegexEdit(edit, expectedSource: source)
                             })
        }
        .sheet(isPresented: $showingLinkDiagnostics) {
            LinkDiagnosticsSheet(diagnostics: linkDiagnostics, isChecking: isCheckingLinks,
                                 source: document.text) { diagnostic in
                showingLinkDiagnostics = false
                if mode.wrappedValue == .preview { mode.wrappedValue = .editor }
                navigate(to: diagnostic.sourceRange.location)
            }
        }
        .sheet(isPresented: $showingMarkdownLint) {
            MarkdownLintSheet(diagnostics: markdownLintDiagnostics,
                              isChecking: isCheckingMarkdownLint,
                              source: document.text,
                              disabledRules: settingsStore.app.disabledLintRules ?? [],
                              onToggleRule: { rule, isEnabled in
                                  var settings = settingsStore.app
                                  var disabled = settings.disabledLintRules ?? []
                                  if isEnabled { disabled.remove(rule) } else { disabled.insert(rule) }
                                  settings.disabledLintRules = disabled
                                  settingsStore.setAppSettings(settings)
                                  checkMarkdownLint()
                              }, onSelect: { diagnostic in
                                  showingMarkdownLint = false
                                  if mode.wrappedValue == .preview { mode.wrappedValue = .editor }
                                  navigate(to: diagnostic.sourceRange.location)
                              })
        }
        .sheet(isPresented: $showingAutoFormat) {
            MarkdownAutoFormatSheet(source: document.text,
                                    selectedRange: editorModel.selectedRange) { plan in
                guard document.text == plan.source else { return false }
                if editorModel.hasActiveEditor {
                    return editorModel.applyRegexEdit(plan.edit, expectedSource: plan.source)
                }
                previewTaskUndoTarget.replaceText(plan.edit.applying(to: plan.source),
                    in: $document.text, undoManager: undoManager, actionName: String(localized: "Markdownを自動整形"))
                return true
            }
        }
    }

    private var alertView: some View {
        sheetView
        .alert("見出しが見つかりません", isPresented: Binding(
            get: { missingHeading != nil },
            set: { if !$0 { missingHeading = nil } }
        )) {
            Button("OK") { missingHeading = nil }
        } message: {
            Text("#\(missingHeading ?? "") に対応する見出しがありません。")
        }
        .alert("リンク先を開けません", isPresented: Binding(
            get: { documentLinkError != nil },
            set: { if !$0 { documentLinkError = nil } }
        )) {
            Button("OK") { documentLinkError = nil }
        } message: {
            Text(documentLinkError ?? "")
        }
        .alert("HTMLを書き出せません", isPresented: Binding(
            get: { htmlExportError != nil },
            set: { if !$0 { htmlExportError = nil } }
        )) {
            Button("OK") { htmlExportError = nil }
        } message: {
            Text(htmlExportError ?? "")
        }
        .alert("PDFを書き出せません", isPresented: Binding(
            get: { pdfExportError != nil },
            set: { if !$0 { pdfExportError = nil } }
        )) {
            Button("OK") { pdfExportError = nil }
        } message: {
            Text(pdfExportError ?? "")
        }
        .alert("印刷できません", isPresented: Binding(
            get: { printError != nil },
            set: { if !$0 { printError = nil } }
        )) {
            Button("OK") { printError = nil }
        } message: {
            Text(printError ?? "")
        }
        .alert("書式付きコピーに失敗しました", isPresented: Binding(
            get: { richCopyError != nil },
            set: { if !$0 { richCopyError = nil } }
        )) {
            Button("OK") { richCopyError = nil }
        } message: {
            Text(richCopyError ?? "")
        }
        .alert("テキストを書き出せません", isPresented: Binding(
            get: { plainExportError != nil },
            set: { if !$0 { plainExportError = nil } }
        )) {
            Button("OK") { plainExportError = nil }
        } message: {
            Text(plainExportError ?? "")
        }
        .alert("ファイルを開けません", isPresented: Binding(
            get: { workspaceOpenError != nil },
            set: { if !$0 { workspaceOpenError = nil } }
        )) {
            Button("OK") { workspaceOpenError = nil }
        } message: {
            Text(workspaceOpenError ?? "")
        }
        .alert("フォルダを記憶できません", isPresented: Binding(
            get: { workspaceStore.errorMessage != nil },
            set: { if !$0 { workspaceStore.clearError() } }
        )) {
            Button("OK") { workspaceStore.clearError() }
        } message: {
            Text(workspaceStore.errorMessage ?? "")
        }
        .sheet(item: $editorModel.linkDraft) { draft in
            LinkEditorSheet(draft: draft, documentContext: documentContext,
                            analysis: analysisStore.snapshot?.source == document.text
                                ? analysisStore.snapshot?.analysis : nil,
                            onSave: { label, destination, title in
                                editorModel.commitLink(label: label, destination: destination, title: title)
                            }, onSaveReference: { label, referenceID in
                                editorModel.commitReferenceLink(label: label, referenceID: referenceID)
                            }, onAttach: { label, url, mode in
                                let context = documentContext
                                try await AttachmentInsertionService.insert(label: label,
                                    fileURL: url, mode: mode, context: context,
                                    model: editorModel, currentContext: { documentContext })
                            })
        }
        .sheet(item: $editorModel.imageDraft) { draft in
            ImageEditorSheet(draft: draft, documentContext: documentContext) { alt, input, title, width, transform in
                try await insertImage(alt: alt, input: input, title: title,
                                      width: width, transform: transform)
            }
        }
        .sheet(item: $editorModel.tableDraft) { _ in
            TableInsertionSheet { rows, columns in
                editorModel.commitTable(rows: rows, columns: columns)
            }
        }
        .sheet(isPresented: $editorModel.showingSnippetPicker) {
            SnippetPickerView(snippets: editorModel.snippets) { snippet in
                editorModel.insertSnippet(snippet)
            }
        }
        .sheet(isPresented: $editorModel.showingCommandPalette) {
            CommandPaletteView(model: editorModel)
        }
        .alert(pasteNeedsSave ? "先に書類を保存" : "画像を挿入できません", isPresented: Binding(
            get: { imageDropError != nil || pasteNeedsSave },
            set: { if !$0 { imageDropError = nil; pasteNeedsSave = false } }
        )) {
            if pasteNeedsSave {
                Button("キャンセル", role: .cancel) { pasteNeedsSave = false }
                Button("保存…") {
                    pasteNeedsSave = false
                    NSApp.sendAction(#selector(NSDocument.save(_:)), to: nil, from: nil)
                }
            } else {
                Button("OK", role: .cancel) { imageDropError = nil }
            }
        } message: {
            Text(pasteNeedsSave
                 ? String(localized: "画像を貼り付けるには保存先が必要です。書類を保存した後、もう一度貼り付けてください。")
                 : imageDropError ?? "")
        }
        .alert("文字コードの取り込みに失敗", isPresented: Binding(
            get: { encodingImportError != nil },
            set: { if !$0 { encodingImportError = nil } }
        )) {
            Button("OK", role: .cancel) { encodingImportError = nil }
        } message: {
            Text(encodingImportError ?? "")
        }
    }

    var body: some View {
        alertView
        .onAppear {
            if !workspaceViewActive {
                workspaceViewActive = true
                if let fileURL {
                    workspaceStore.registerOpenDocument(fileURL)
                    registerOpenBuffer(for: fileURL)
                }
                restorePosition(for: fileURL)
            }
            analysisStore.update(source: document.text,
                                 dialect: settingsStore.markdownDialect(for: fileURL))
            if let fileURL {
                settingsStore.ensureWritingSession(for: fileURL,
                    initialCharacters: statistics.characters)
            } else if unsavedSessionBaseline == nil {
                unsavedSessionBaseline = statistics.characters
            }
            receivePendingDocumentLink()
            receivePendingSearchPosition()
            workspaceStore.refresh()
            if let fileURL {
                settingsStore.migrateLegacyMode(legacyMode, for: fileURL)
            } else {
                unsavedMode = legacyMode.flatMap(EditorMode.init(rawValue:)) ?? settingsStore.app.defaultMode
            }
            legacyMode = nil
            receivePendingExternalLine()
        }
        .onDisappear {
            savePosition(for: fileURL)
            detachedPreview.close()
            if workspaceViewActive {
                if let fileURL {
                    workspaceStore.unregisterOpenDocument(fileURL)
                    workspaceStore.unregisterOpenBuffer(id: openBufferID, url: fileURL)
                }
                workspaceViewActive = false
            }
        }
        .onReceive(Timer.publish(every: 3, on: .main, in: .common).autoconnect()) { _ in
            workspaceStore.refresh()
            savePosition(for: fileURL)
        }
        .onChange(of: fileURL) { oldURL, newURL in
            detachedPreview.updateDocumentURL(newURL)
            savePosition(for: oldURL)
            if workspaceViewActive {
                if let oldURL {
                    workspaceStore.unregisterOpenDocument(oldURL)
                    workspaceStore.unregisterOpenBuffer(id: openBufferID, url: oldURL)
                }
                if let newURL {
                    workspaceStore.registerOpenDocument(newURL)
                    registerOpenBuffer(for: newURL)
                }
            }
            navigationHistory.moveDocument(from: oldURL, to: newURL)
            synchronizedBlockID = nil
            if showingLinkDiagnostics { checkLinks() }
            if showingMarkdownLint { checkMarkdownLint() }
            switch (oldURL, newURL) {
            case let (oldURL?, newURL?):
                settingsStore.moveDocumentState(from: oldURL, to: newURL)
            case let (nil, newURL?):
                if !settingsStore.hasDocumentState(for: newURL) {
                    settingsStore.setMode(unsavedMode, for: newURL)
                }
                settingsStore.ensureWritingSession(for: newURL,
                    initialCharacters: unsavedSessionBaseline ?? statistics.characters)
            case let (oldURL?, nil):
                unsavedMode = settingsStore.mode(for: oldURL)
            case (nil, nil):
                break
            }
            restorePosition(for: newURL)
            receivePendingExternalLine()
        }
        .onChange(of: document.text) { _, newText in
            previewUpdates.sourceChanged()
            analysisStore.update(source: newText,
                                 dialect: settingsStore.markdownDialect(for: fileURL))
            previewSearchRange = nil
            synchronizedBlockID = nil
            if showingLinkDiagnostics { checkLinks() }
            if showingMarkdownLint { checkMarkdownLint() }
        }
        .onChange(of: previewSearchQuery) { _, _ in previewSearchRange = nil }
        .onChange(of: settingsStore.markdownDialect(for: fileURL)) { _, dialect in
            analysisStore.update(source: document.text, dialect: dialect)
            previewUpdates.resume()
        }
        .onChange(of: previewSearchCaseSensitive) { _, _ in previewSearchRange = nil }
        .onChange(of: splitOrientation) { _, _ in savePosition(for: fileURL) }
        .onChange(of: previewFirst) { _, _ in savePosition(for: fileURL) }
        .onChange(of: analysisStore.snapshot?.source) { _, _ in
            receivePendingDocumentLink()
            if let previewSearchRange { scrollPreview(to: previewSearchRange.location) }
        }
        .onChange(of: documentLinkNavigation.pending) { _, _ in
            receivePendingDocumentLink()
        }
        .onChange(of: documentLinkNavigation.pendingPosition) { _, _ in
            receivePendingSearchPosition()
        }
        .onChange(of: documentLinkNavigation.pendingLines) { _, _ in
            receivePendingExternalLine()
        }
        .onDisappear {
            analysisStore.cancel()
        }
    }

    @ViewBuilder
    private var editorContent: some View {
        switch mode.wrappedValue {
        case .editor:
            sourceEditor
        case .split:
            splitEditor
        case .preview:
            previewPane(synchronizesScroll: false)
        }
    }

    private var splitEditor: some View {
        GeometryReader { geometry in
            if splitOrientation == .sideBySide {
                let extent = EditorSplitSizing.editorExtent(total: geometry.size.width,
                    ratio: splitRatio, minimum: 280)
                HStack(spacing: 0) {
                    if previewFirst {
                        splitPreview.frame(maxWidth: .infinity)
                        splitDivider(total: geometry.size.width, minimum: 280,
                            horizontal: true)
                        sourceEditor.frame(width: extent)
                    } else {
                        sourceEditor.frame(width: extent)
                        splitDivider(total: geometry.size.width, minimum: 280,
                            horizontal: true)
                        splitPreview.frame(maxWidth: .infinity)
                    }
                }
            } else {
                let extent = EditorSplitSizing.editorExtent(total: geometry.size.height,
                    ratio: splitRatio, minimum: 180)
                VStack(spacing: 0) {
                    if previewFirst {
                        splitPreview.frame(maxHeight: .infinity)
                        splitDivider(total: geometry.size.height, minimum: 180,
                            horizontal: false)
                        sourceEditor.frame(height: extent)
                    } else {
                        sourceEditor.frame(height: extent)
                        splitDivider(total: geometry.size.height, minimum: 180,
                            horizontal: false)
                        splitPreview.frame(maxHeight: .infinity)
                    }
                }
            }
        }
    }

    private var splitPreview: some View {
        previewPane(synchronizesScroll: true)
    }

    private func previewPane(synchronizesScroll: Bool) -> some View {
        let displayedSource = previewUpdates.state.displayedSource ?? document.text
        let isCurrent = displayedSource == document.text
        let selectedSnapshot = previewUpdates.state.isPaused
            ? previewUpdates.snapshot : analysisStore.snapshot
        let matchingSnapshot = selectedSnapshot?.source == displayedSource &&
            selectedSnapshot?.dialect == documentContext.markdownDialect ? selectedSnapshot : nil
        let taskAction: ((Int) -> Void)? = isCurrent ? previewTaskAction : nil
        let headingAction: ((String) -> Void)? = isCurrent
            ? { fragment in navigateToHeading(fragment) } : nil
        let scrollAction: ((Int) -> Void)? = synchronizesScroll && isCurrent
            ? { blockID in synchronizeEditor(to: blockID) } : nil
        let revealAction: ((NSRange) -> Void)? = isCurrent
            ? { range in revealSource(range) } : nil
        let preview = MarkdownPreview(
            markdown: displayedSource, documentContext: documentContext,
            onToggleTask: taskAction, snapshot: matchingSnapshot, usesSharedAnalysis: true,
            navigationTarget: isCurrent ? previewNavigationTarget : nil,
            searchRange: isCurrent ? previewSearchRange : nil,
            onOpenHeading: headingAction, onOpenDocument: openLinkedDocument,
            onVisibleBlockChange: scrollAction, onRevealSource: revealAction,
            showsFrontMatter: settingsStore.app.showsFrontMatterInPreview ?? false,
            zoom: settingsStore.zoom(for: .preview),
            loadsRemoteImages: settingsStore.app.loadsRemoteImages ?? false,
            theme: settingsStore.app.previewTheme ?? .system,
            bodyWidth: settingsStore.app.previewBodyWidth ?? 900)
        return VStack(spacing: 0) {
            PreviewUpdateControls(updates: previewUpdates, source: document.text,
                                  preferredSnapshot: analysisStore.snapshot,
                                  dialect: documentContext.markdownDialect)
            preview
        }
    }

    private func splitDivider(total: CGFloat, minimum: CGFloat,
                              horizontal: Bool) -> some View {
        let available = max(1, total - 8)
        let effectiveMinimum = min(minimum, available / 2)
        return Color.clear
            .frame(width: horizontal ? 8 : nil, height: horizontal ? nil : 8)
            .overlay {
                Rectangle()
                    .fill(Color.secondary.opacity(0.35))
                    .frame(width: horizontal ? 1 : nil, height: horizontal ? nil : 1)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 1)
                .onChanged { value in
                    if splitDragStart == nil { splitDragStart = splitRatio }
                    let delta = horizontal ? value.translation.width : value.translation.height
                    let sign: CGFloat = previewFirst ? -1 : 1
                    let proposed = (splitDragStart ?? splitRatio) + Double(sign * delta / available)
                    splitRatio = max(Double(effectiveMinimum / available),
                                     min(1 - Double(effectiveMinimum / available), proposed))
                }
                .onEnded { _ in
                    splitDragStart = nil
                    savePosition(for: fileURL)
                })
            .accessibilityElement()
            .accessibilityLabel("編集とプレビューの分割位置")
            .accessibilityValue("編集 \(Int(splitRatio * 100))%")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: splitRatio = min(0.8, splitRatio + 0.05)
                case .decrement: splitRatio = max(0.2, splitRatio - 0.05)
                @unknown default: break
                }
                savePosition(for: fileURL)
            }
    }

    private func savePosition(for url: URL?) {
        guard let url else { return }
        settingsStore.savePosition(for: url, selection: editorModel.selectedRange,
                                   scrollX: editorModel.scrollOrigin.x,
                                   scrollY: editorModel.scrollOrigin.y, splitRatio: splitRatio,
                                   sidebarTab: sidebarTab.rawValue,
                                   sidebarVisible: (focusMode.savedSidebarVisibility ?? sidebarVisibility) != .detailOnly,
                                   splitOrientation: splitOrientation,
                                   previewFirst: previewFirst)
    }

    private func toggleFocusMode() {
        sidebarVisibility = focusMode.toggle(sidebarVisibility: sidebarVisibility)
        savePosition(for: fileURL)
    }

    private func restorePosition(for url: URL?) {
        guard let url, let state = settingsStore.displayState(for: url) else { return }
        if let location = state.selectionLocation {
            editorModel.restorePosition(selection: NSRange(location: location,
                                                           length: state.selectionLength ?? 0),
                                        scrollX: state.scrollX ?? 0,
                                        scrollY: state.scrollY ?? 0)
        }
        if let ratio = state.splitRatio { splitRatio = ratio }
        if let orientation = state.splitOrientation { splitOrientation = orientation }
        if let first = state.previewFirst { previewFirst = first }
        if let tab = state.sidebarTab.flatMap(SidebarTab.init(rawValue:)) { sidebarTab = tab }
        if let visible = state.sidebarVisible { sidebarVisibility = visible ? .all : .detailOnly }
    }

    private var previewTaskAction: ((Int) -> Void)? {
        guard analysisStore.snapshot?.source == document.text else { return nil }
        return { toggleTask(at: $0) }
    }

    private var outlineEntries: [MarkdownOutlineEntry] {
        analysisStore.snapshot.map { MarkdownOutline.entries(in: $0.analysis) } ?? []
    }

    private var workspaceSidebar: some View {
        VStack(spacing: 0) {
            Picker("サイドバー", selection: $sidebarTab) {
                ForEach(SidebarTab.allCases, id: \.self) { tab in
                    Text(tab.title).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(8)
            switch sidebarTab {
            case .outline: outlineSidebar
            case .inspector: contentInspectorSidebar
            case .bookmarks: bookmarksSidebar
            case .files: fileSidebar
            }
        }
    }

    private var contentInspectorSidebar: some View {
        let isReady = analysisStore.snapshot?.source == document.text
        let items = analysisStore.snapshot.flatMap { snapshot in
            snapshot.source == document.text
                ? MarkdownContentInspector.items(in: document.text, analysis: snapshot.analysis)
                : nil
        } ?? []
        return List {
            ForEach(MarkdownContentKind.allCases, id: \.self) { kind in
                let matching = items.filter { $0.kind == kind }
                Section("\(kind.title)（\(matching.count)）") {
                    ForEach(matching) { item in
                        Button { navigate(to: item.sourceRange.location) } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.label).lineLimit(2)
                                if let destination = item.destination {
                                    Text(destination).font(.caption)
                                        .foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(kind.title)、\(item.label)")
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if !isReady {
                ProgressView("項目を解析中…")
            } else if items.isEmpty {
                ContentUnavailableView("項目がありません", systemImage: "list.bullet.rectangle")
            }
        }
    }

    private var bookmarksSidebar: some View {
        VStack(spacing: 0) {
            HStack {
                Text("ブックマーク").font(.headline)
                Spacer()
                Button("現在位置を追加", systemImage: "bookmark.fill") {
                    guard let fileURL else { return }
                    settingsStore.addBookmark(DocumentBookmark.capture(in: document.text,
                        at: editorModel.selectedRange.location, documentURL: fileURL))
                }
                .labelStyle(.iconOnly)
                .disabled(fileURL == nil)
                .help("現在のカーソル位置をブックマーク")
            }
            .padding(12)
            List(settingsStore.bookmarks) { bookmark in
                Button { openBookmark(bookmark) } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(bookmark.title).lineLimit(1)
                        Text(bookmark.documentURL.lastPathComponent)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button("ブックマークを削除", role: .destructive) {
                        settingsStore.removeBookmark(bookmark.id)
                    }
                }
            }
            .listStyle(.sidebar)
            .overlay {
                if settingsStore.bookmarks.isEmpty {
                    ContentUnavailableView("ブックマークがありません", systemImage: "bookmark")
                }
            }
        }
    }

    private func openBookmark(_ bookmark: DocumentBookmark) {
        if bookmark.documentURL == fileURL {
            navigate(to: bookmark.resolvedLocation(in: document.text))
            return
        }
        Task {
            do {
                let snapshots = try workspaceStore.openBufferSnapshots()
                let data = try snapshots[bookmark.documentURL]
                    ?? Data(contentsOf: bookmark.documentURL)
                let text = try MarkdownDocument.decode(data)
                let location = bookmark.resolvedLocation(in: text)
                documentLinkNavigation.requestPosition(in: bookmark.documentURL,
                    range: NSRange(location: location, length: 0))
                try await openDocument(at: bookmark.documentURL)
            } catch {
                documentLinkNavigation.cancelPosition(for: bookmark.documentURL)
                workspaceOpenError = error.localizedDescription
            }
        }
    }

    private var fileSidebar: some View {
        VStack(spacing: 0) {
            HStack {
                Text(workspaceStore.rootURL?.lastPathComponent ?? "フォルダ未選択")
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                Button("フォルダを開く…", systemImage: "folder.badge.plus") {
                    workspaceStore.chooseFolder()
                }
                .labelStyle(.iconOnly)
                .help("ワークスペースのフォルダを選ぶ")
                Button("ファイル名で開く…", systemImage: "magnifyingglass") {
                    showingQuickOpen = true
                }
                .labelStyle(.iconOnly)
                .disabled(workspaceStore.rootURL == nil)
                .help("ファイル名で書類を探す")
                if let root = workspaceStore.rootURL {
                    Button("フォルダの編集設定", systemImage: "gearshape") {
                        showingFolderSettings = true
                    }
                    .labelStyle(.iconOnly)
                    .help("このフォルダの字下げ・添付先・Markdown構文")
                    Menu {
                        Button("新規Markdown書類…") { fileAction = .createDocument(root) }
                        Button("新規フォルダ…") { fileAction = .createFolder(root) }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .help("ワークスペースに作成")
                    Menu {
                        Picker("並び順", selection: Binding(
                            get: { workspaceStore.viewSettings.sortOrder },
                            set: { workspaceStore.setSortOrder($0) }
                        )) {
                            ForEach(WorkspaceViewSettings.SortOrder.allCases, id: \.self) { value in
                                Text(value.title).tag(value)
                            }
                        }
                        Picker("表示", selection: Binding(
                            get: { workspaceStore.viewSettings.filter },
                            set: { workspaceStore.setFileFilter($0) }
                        )) {
                            ForEach(WorkspaceViewSettings.FileFilter.allCases, id: \.self) { value in
                                Text(value.title).tag(value)
                            }
                        }
                        Divider()
                        Button("すべての拡張子") { workspaceStore.setExtensionFilter(nil) }
                        ForEach(workspaceStore.availableExtensions, id: \.self) { ext in
                            Button {
                                workspaceStore.setExtensionFilter(ext)
                            } label: {
                                if workspaceStore.viewSettings.fileExtension == ext {
                                    Label(".\(ext)", systemImage: "checkmark")
                                } else {
                                    Text(".\(ext)")
                                }
                            }
                        }
                        Divider()
                        Button("添付ファイルを確認…") { showingAttachmentAudit = true }
                    } label: {
                        Image(systemName: "line.3.horizontal.decrease")
                    }
                    .help("並び順とフィルター")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            List {
                OutlineGroup(workspaceStore.visibleNodes, children: \.children) { node in
                    if node.isDirectory {
                        HStack {
                            Label(node.name, systemImage: "folder")
                            if isPinned(node) { Image(systemName: "pin.fill").foregroundStyle(.secondary) }
                        }
                            .contextMenu { fileContextActions(for: node) }
                    } else {
                        Button {
                            Task {
                                if node.isEditableDocument {
                                    do { try await openDocument(at: node.url) }
                                    catch { workspaceOpenError = error.localizedDescription }
                                } else if !NSWorkspace.shared.open(node.url) {
                                    workspaceOpenError = String(localized: "添付ファイルを開けませんでした。")
                                }
                            }
                        } label: {
                            HStack {
                                Label(node.name, systemImage: node.isEditableDocument ? "doc.text" : "paperclip")
                                if isPinned(node) { Image(systemName: "pin.fill").foregroundStyle(.secondary) }
                            }
                        }
                        .buttonStyle(.plain)
                        .contextMenu { fileContextActions(for: node) }
                    }
                }
            }
            .listStyle(.sidebar)
            if workspaceStore.isTruncated {
                Text("項目が多いため一部のみ表示しています")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(8)
            }
        }
        .overlay {
            if workspaceStore.rootURL == nil {
                ContentUnavailableView("フォルダを開く", systemImage: "folder",
                                       description: Text("Markdown書類と添付を一覧できます"))
                    .allowsHitTesting(false)
            }
        }
    }

    @ViewBuilder
    private func fileContextActions(for node: WorkspaceNode) -> some View {
        Button(isPinned(node) ? "ピン留めを外す" : "ピン留め") {
            workspaceStore.togglePin(node.url)
        }
        Divider()
        if node.isDirectory {
            Button("新規Markdown書類…") { fileAction = .createDocument(node.url) }
            Button("新規フォルダ…") { fileAction = .createFolder(node.url) }
            Divider()
        }
        Button("名前を変更…") { fileAction = .rename(node.url) }
        Button("移動…") { fileAction = .move(node.url) }
        Button("ゴミ箱へ移動…", role: .destructive) { fileAction = .trash(node.url) }
    }

    private func isPinned(_ node: WorkspaceNode) -> Bool {
        guard let root = workspaceStore.rootURL else { return false }
        return workspaceStore.viewSettings.isPinned(node.url, root: root)
    }

    private var outlineSidebar: some View {
        let entries = outlineEntries
        let highlightedID = currentSectionID
        return List(entries) { entry in
            Button {
                navigate(to: entry)
            } label: {
                Text(entry.title)
                    .lineLimit(1)
                    .padding(.leading, CGFloat(entry.level - 1) * 12)
            }
            .buttonStyle(.plain)
            .contextMenu {
                Button("セクションを上へ移動") {
                    editorModel.moveSection(at: entry.sourceRange.location, direction: .up)
                }
                .disabled(editorModel.textView == nil ||
                    MarkdownSectionMove.edit(in: document.text,
                        headingLocation: entry.sourceRange.location, direction: .up) == nil)
                Button("セクションを下へ移動") {
                    editorModel.moveSection(at: entry.sourceRange.location, direction: .down)
                }
                .disabled(editorModel.textView == nil ||
                    MarkdownSectionMove.edit(in: document.text,
                        headingLocation: entry.sourceRange.location, direction: .down) == nil)
                Divider()
                Button("見出しと子見出しを昇格") {
                    editorModel.changeSectionLevel(at: entry.sourceRange.location, by: -1)
                }
                .disabled(editorModel.textView == nil ||
                    MarkdownSectionLevel.edit(in: document.text,
                        headingLocation: entry.sourceRange.location, by: -1) == nil)
                Button("見出しと子見出しを降格") {
                    editorModel.changeSectionLevel(at: entry.sourceRange.location, by: 1)
                }
                .disabled(editorModel.textView == nil ||
                    MarkdownSectionLevel.edit(in: document.text,
                        headingLocation: entry.sourceRange.location, by: 1) == nil)
            }
            .listRowBackground(highlightedID == entry.id ? Color.accentColor.opacity(0.16) : Color.clear)
            .disabled(analysisStore.snapshot?.source != document.text)
            .accessibilityLabel("見出しレベル \(entry.level)、\(entry.title)")
            .accessibilityAddTraits(highlightedID == entry.id ? .isSelected : [])
        }
        .listStyle(.sidebar)
        .navigationTitle("アウトライン")
        .overlay {
            if outlineEntries.isEmpty {
                ContentUnavailableView("見出しがありません", systemImage: "list.bullet.indent")
            }
        }
    }

    private var currentSectionID: Int? {
        guard analysisStore.snapshot?.source == document.text else { return nil }
        return MarkdownOutline.currentSection(at: editorModel.selectedRange.location,
                                              in: outlineEntries)?.id
    }

    private func navigate(to entry: MarkdownOutlineEntry) {
        guard analysisStore.snapshot?.source == document.text else { return }
        navigate(to: entry.sourceRange.location, previewBlockID: entry.id)
    }

    private func goToLine(_ requestedLine: Int) {
        let destination = MarkdownLineIndex(document.text).destination(for: requestedLine)
        if mode.wrappedValue == .preview { mode.wrappedValue = .editor }
        navigate(to: destination.utf16Location)
    }

    private func navigateToHeading(_ fragment: String) {
        guard let snapshot = analysisStore.snapshot, snapshot.source == document.text else { return }
        guard let entry = MarkdownHeadingIndex(analysis: snapshot.analysis).entry(forFragment: fragment) else {
            missingHeading = fragment
            return
        }
        navigate(to: entry)
    }

    private func openLinkedDocument(_ url: URL) {
        guard let link = MarkdownDocumentLink(url: url, context: documentContext) else { return }
        if link.fileURL == fileURL {
            if let fragment = link.fragment { navigateToHeading(fragment) }
            return
        }
        documentLinkNavigation.request(link)
        Task {
            do {
                try await openDocument(at: link.fileURL)
            } catch {
                documentLinkNavigation.cancel(for: link.fileURL)
                documentLinkError = error.localizedDescription
            }
        }
    }

    private func receivePendingDocumentLink() {
        guard let fileURL, analysisStore.snapshot?.source == document.text,
              let fragment = documentLinkNavigation.take(for: fileURL) else { return }
        navigateToHeading(fragment)
    }

    private func openWorkspaceSearchResult(_ result: WorkspaceSearchResult) {
        if result.url.resolvingSymlinksInPath().standardizedFileURL ==
            fileURL?.resolvingSymlinksInPath().standardizedFileURL {
            mode.wrappedValue = .editor
            editorModel.selectAndReveal(result.sourceRange)
            return
        }
        documentLinkNavigation.requestPosition(in: result.url, range: result.sourceRange)
        Task {
            do { try await openDocument(at: result.url) }
            catch {
                documentLinkNavigation.cancelPosition(for: result.url)
                workspaceOpenError = error.localizedDescription
            }
        }
    }

    private func receivePendingSearchPosition() {
        guard let fileURL, let range = documentLinkNavigation.takePosition(for: fileURL) else { return }
        mode.wrappedValue = .editor
        editorModel.selectAndReveal(range)
    }

    private func receivePendingExternalLine() {
        guard let fileURL, let line = documentLinkNavigation.takeLine(for: fileURL) else { return }
        mode.wrappedValue = .editor
        let location = MarkdownLineIndex(document.text).destination(for: line).utf16Location
        navigate(to: location)
    }

    private func checkLinks() {
        let source = document.text
        let cachedAnalysis = analysisStore.snapshot?.source == source
            ? analysisStore.snapshot?.analysis : nil
        let context = documentContext
        isCheckingLinks = true
        Task {
            let diagnostics = await Task.detached(priority: .userInitiated) {
                let analysis = cachedAnalysis ?? MarkdownAnalysis(source)
                return MarkdownLinkDiagnostics.inspect(source, analysis: analysis, context: context)
            }.value
            guard document.text == source else { return }
            linkDiagnostics = diagnostics
            isCheckingLinks = false
        }
    }

    private func checkMarkdownLint() {
        let source = document.text
        let cachedAnalysis = analysisStore.snapshot?.source == source
            ? analysisStore.snapshot?.analysis : nil
        let context = documentContext
        let disabled = settingsStore.app.disabledLintRules ?? []
        isCheckingMarkdownLint = true
        Task {
            let diagnostics = await Task.detached(priority: .userInitiated) {
                MarkdownLint.inspect(source, analysis: cachedAnalysis ?? MarkdownAnalysis(source),
                                     context: context, disabled: disabled)
            }.value
            guard document.text == source,
                  (settingsStore.app.disabledLintRules ?? []) == disabled else { return }
            markdownLintDiagnostics = diagnostics
            isCheckingMarkdownLint = false
        }
    }

    private func chooseEncodingImport() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [MarkdownDocument.markdownType, .plainText]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            encodingImport = EncodingImport(url: url, data: try Data(contentsOf: url))
        } catch {
            encodingImportError = error.localizedDescription
        }
    }

    private func exportHTML() {
        exportFormat = .html
    }

    private func saveHTML(preset: MarkdownExportPreset) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.html]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = (fileURL?.deletingPathExtension().lastPathComponent ?? "document") + ".html"
        panel.begin { response in
            guard response == .OK, let destination = panel.url else { return }
            let html = MarkdownHTMLExporter.render(document.text, documentURL: fileURL,
                                                   preset: preset,
                                                   dialect: settingsStore.markdownDialect(for: fileURL))
            do {
                try html.write(to: destination, atomically: true, encoding: .utf8)
            } catch {
                htmlExportError = error.localizedDescription
            }
        }
    }

    private func exportPDF() {
        guard !isExportingPDF else { return }
        exportFormat = .pdf
    }

    private func savePDF(preset: MarkdownExportPreset) {
        guard !isExportingPDF else { return }
        isExportingPDF = true
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = (fileURL?.deletingPathExtension().lastPathComponent ?? "document") + ".pdf"
        panel.begin { response in
            guard response == .OK, let destination = panel.url else {
                isExportingPDF = false
                return
            }
            let source = document.text
            let sourceURL = fileURL
            Task { @MainActor in
                defer { isExportingPDF = false }
                do {
                    try MarkdownPDFExporter.export(source, documentURL: sourceURL, to: destination,
                                                   preset: preset,
                                                   dialect: settingsStore.markdownDialect(for: sourceURL))
                } catch {
                    pdfExportError = error.localizedDescription
                }
            }
        }
    }

    private func pageSetup() {
        _ = NSPageLayout().runModal(with: printInfo)
    }

    private func printDocument() {
        do {
            let info = printInfo.copy() as! NSPrintInfo
            try printSettings.apply(to: info)
            let title = fileURL?.deletingPathExtension().lastPathComponent ?? String(localized: "無題")
            let view = try MarkdownPDFExporter.printableView(document.text, documentURL: fileURL,
                                                             printInfo: info, title: title,
                                                             header: printSettings.header,
                                                             footer: printSettings.footer,
                                                             dialect: settingsStore.markdownDialect(for: fileURL))
            let operation = NSPrintOperation(view: view, printInfo: info)
            operation.jobTitle = title
            operation.showsPrintPanel = true
            _ = operation.run()
        } catch {
            printError = error.localizedDescription
        }
    }

    private func copyRichSelection() {
        guard let textView = editorModel.textView else { return }
        let source = textView.string as NSString
        let selection = textView.selectedRange()
        guard selection.length > 0, NSMaxRange(selection) <= source.length else { return }
        do {
            try MarkdownRichClipboard.copy(source.substring(with: selection), documentURL: fileURL,
                                            to: .general,
                                            dialect: settingsStore.markdownDialect(for: fileURL))
        } catch {
            richCopyError = error.localizedDescription
        }
    }

    private func exportPlainText() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = (fileURL?.deletingPathExtension().lastPathComponent ?? "document") + ".txt"
        panel.begin { response in
            guard response == .OK, let destination = panel.url else { return }
            let text = MarkdownPlainTextExporter.render(document.text, options: plainOptions)
            do {
                try text.write(to: destination, atomically: true, encoding: .utf8)
            } catch {
                plainExportError = error.localizedDescription
            }
        }
    }

    private var currentNavigationPoint: NavigationPoint {
        NavigationPoint(documentURL: fileURL, utf16Location: editorModel.selectedRange.location)
    }

    private func navigate(to location: Int, previewBlockID: Int? = nil) {
        let destination = NavigationPoint(documentURL: fileURL, utf16Location: location)
        navigationHistory.recordJump(from: currentNavigationPoint, to: destination)
        editorModel.navigate(to: location)
        if let previewBlockID {
            navigationSequence += 1
            previewNavigationTarget = PreviewNavigationTarget(blockID: previewBlockID,
                                                              sequence: navigationSequence)
        } else {
            scrollPreview(to: location)
        }
    }

    private func goBack() {
        guard let destination = navigationHistory.goBack(from: currentNavigationPoint),
              destination.documentURL == fileURL else { return }
        editorModel.navigate(to: destination.utf16Location)
        scrollPreview(to: destination.utf16Location)
    }

    private func goForward() {
        guard let destination = navigationHistory.goForward(from: currentNavigationPoint),
              destination.documentURL == fileURL else { return }
        editorModel.navigate(to: destination.utf16Location)
        scrollPreview(to: destination.utf16Location)
    }

    private func scrollPreview(to sourceLocation: Int) {
        guard let snapshot = analysisStore.snapshot, snapshot.source == document.text else { return }
        guard let block = PreviewScrollSync.block(containingOrBefore: sourceLocation,
                                                 in: snapshot.analysis) else { return }
        navigationSequence += 1
        previewNavigationTarget = PreviewNavigationTarget(blockID: block.id, sequence: navigationSequence)
    }

    private func navigatePreviewSearch(backwards: Bool) {
        let matches = PreviewSearch.matches(in: document.text, query: previewSearchQuery,
                                            caseSensitive: previewSearchCaseSensitive)
        guard let match = PreviewSearch.next(in: matches, after: previewSearchRange?.location,
                                             backwards: backwards) else {
            showingPreviewSearch = true
            return
        }
        navigatePreviewMatch(match)
    }

    private func navigatePreviewMatch(_ match: PreviewSearchMatch) {
        let destination = NavigationPoint(documentURL: fileURL,
                                          utf16Location: match.range.location)
        navigationHistory.recordJump(from: currentNavigationPoint, to: destination)
        previewSearchRange = match.range
        editorModel.selectAndReveal(match.range)
        scrollPreview(to: match.range.location)
    }

    private func synchronizePreview(to sourceLocation: Int) {
        guard mode.wrappedValue == .split,
              let snapshot = analysisStore.snapshot, snapshot.source == document.text,
              let block = PreviewScrollSync.block(containingOrBefore: sourceLocation,
                                                  in: snapshot.analysis),
              block.id != synchronizedBlockID else { return }
        synchronizedBlockID = block.id
        navigationSequence += 1
        previewNavigationTarget = PreviewNavigationTarget(blockID: block.id, sequence: navigationSequence)
    }

    private func synchronizeEditor(to blockID: Int) {
        guard mode.wrappedValue == .split, blockID != synchronizedBlockID,
              let snapshot = analysisStore.snapshot, snapshot.source == document.text,
              let block = snapshot.analysis.blocks.first(where: { $0.id == blockID }) else { return }
        synchronizedBlockID = blockID
        editorModel.scrollToTop(sourceLocation: block.sourceRange.location)
    }

    private func revealSource(_ range: NSRange) {
        guard analysisStore.snapshot?.source == document.text else { return }
        let destination = NavigationPoint(documentURL: fileURL, utf16Location: range.location)
        navigationHistory.recordJump(from: currentNavigationPoint, to: destination)
        if mode.wrappedValue == .preview { mode.wrappedValue = .editor }
        editorModel.selectAndReveal(range)
    }

    private var sourceEditor: some View {
        MarkdownTextEditor(text: $document.text, model: editorModel,
                           textStyle: settingsStore.textStyle(for: fileURL),
                           layoutOptions: settingsStore.layoutOptions(for: fileURL),
                           sharedSnapshot: analysisStore.snapshot, usesSharedAnalysis: true,
                           imageImportMode: settingsStore.imageImportMode(for: fileURL),
                           tableAddsRowOnTab: settingsStore.app.tableAddsRowOnTab ?? true,
                           proofing: settingsStore.app.proofing ?? EditorProofingSettings(),
                           snippets: settingsStore.app.snippets ?? [],
                           whitespaceOptions: EditorWhitespaceOptions(
                               showsCharacters: settingsStore.app.showsInvisibleCharacters ?? false,
                               showsIndentGuides: settingsStore.app.showsIndentGuides ?? false),
                           isEditable: !workspaceStore.isDocumentLocked(fileURL),
                           onImageDrop: dropImage, onImagePaste: pasteImage,
                           onVisibleSourceChange: synchronizePreview(to:))
    }

    private func registerOpenBuffer(for url: URL) {
        let binding = $document
        workspaceStore.registerOpenBuffer(id: openBufferID, url: url,
            encodedData: { binding.wrappedValue.encodedData() },
            updateText: { binding.wrappedValue.text = $0 })
    }

    private func dropImage(_ url: URL, at location: Int) {
        guard let draft = editorModel.imageDropDraft(at: location) else { return }
        let context = documentContext
        let mode = settingsStore.imageImportMode(for: fileURL)
        Task {
            do {
                try await ImageInsertionService.insertDrop(fileURL: url, draft: draft,
                                                           mode: mode, context: context,
                                                           model: editorModel,
                                                           currentContext: { documentContext })
            } catch {
                imageDropError = error.localizedDescription
            }
        }
    }

    private func pasteImage(_ data: Data) {
        guard let draft = editorModel.imagePasteDraft() else { return }
        let context = documentContext
        guard context.directoryURL != nil else {
            pasteNeedsSave = true
            return
        }
        Task {
            do {
                try await ImageInsertionService.insertPaste(imageData: data, draft: draft,
                                                            context: context, model: editorModel,
                                                            currentContext: { documentContext })
            } catch {
                imageDropError = error.localizedDescription
            }
        }
    }

    private func toggleTask(at sourceLocation: Int) {
        if editorModel.hasActiveEditor {
            editorModel.toggleTask(at: sourceLocation)
            return
        }
        guard let edit = MarkdownFormatter.toggleTasks(in: document.text,
            selection: NSRange(location: sourceLocation, length: 0)) else { return }
        previewTaskUndoTarget.replaceText(edit.applying(to: document.text),
                                          in: $document.text, undoManager: undoManager)
    }

    private func insertImage(alt: String, input: ImageInput, title: String,
                             width: Int?, transform: ImageTransformOptions?) async throws {
        let context = documentContext
        try await ImageInsertionService.insert(alt: alt, input: input, title: title,
                                               width: width,
                                               transform: transform,
                                               context: context, model: editorModel,
                                               currentContext: { documentContext })
    }

    private var statusBar: some View {
        HStack(spacing: 12) {
            Text("Markdown")
            Spacer()
            Text("\(statistics.lines) 行")
            Text("\(displayedWordCount) 語")
                .help(wordCountMode.title)
            if let selectionStatistics {
                Text("選択 \(selectionStatistics.characters) 文字")
            } else if let sectionStatistics {
                Text("節 \(sectionStatistics.value.characters) 文字")
            }
            Button("\(statistics.characters) 文字") { showingStatistics = true }
                .buttonStyle(.plain)
                .help("文字数の内訳を表示")
                .accessibilityLabel("\(statusAccessibilityLabel)。内訳を表示")
                .popover(isPresented: $showingStatistics, arrowEdge: .top) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("文字数の内訳").font(.headline)
                        Picker("語数の数え方", selection: wordCountBinding) {
                            ForEach(WordCountMode.allCases, id: \.self) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                        Text("\(displayedWordCount) 語。\(wordCountMode.explanation)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Divider()
                        Picker("時間の推定言語", selection: readingLanguageBinding) {
                            ForEach(ReadingLanguage.allCases, id: \.self) { language in
                                Text(language.title).tag(language)
                            }
                        }
                        let speedRange = readingEstimate.language == .japanese ? 100...2000 : 50...500
                        Stepper(value: rateBinding(spoken: false), in: speedRange, step: 10) {
                            Text("読む速度: \(readingEstimate.readingRate) \(readingEstimate.language.unit)")
                        }
                        Stepper(value: rateBinding(spoken: true), in: speedRange, step: 10) {
                            Text("音読速度: \(readingEstimate.speakingRate) \(readingEstimate.language.unit)")
                        }
                        Text("読了の目安: \(estimatedTimeLabel(spoken: false)) / 音読の目安: \(estimatedTimeLabel(spoken: true))")
                            .font(.caption)
                        Text("Markdown原文を対象にした推定値です。実際の所要時間は読み方で変わります。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Divider()
                        statisticsRow(String(localized: "全文"), value: statistics)
                        if let selectionStatistics {
                            statisticsRow(String(localized: "選択範囲"), value: selectionStatistics)
                        } else {
                            Text("選択範囲なし")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if let sectionStatistics {
                            statisticsRow(String(localized: "セクション: \(sectionStatistics.title)"),
                                          value: sectionStatistics.value)
                        }
                        Text("空白込みは改行・空白を含む文字数、空白除外は改行・空白を除く文字数です。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Divider()
                        writingProgressView
                    }
                    .padding(16)
                    .frame(width: 370, alignment: .leading)
                    .onAppear { writingGoalInput = fileURL.flatMap {
                        settingsStore.displayState(for: $0)?.writingGoal.map(String.init)
                    } ?? "" }
                }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .frame(height: 28)
        .background(.bar)
        .accessibilityElement(children: .contain)
    }

    private var statusAccessibilityLabel: String {
        var value = String(localized: "文書統計。\(statistics.lines) 行、\(wordCountMode.title)で\(displayedWordCount) 語、全文 \(statistics.characters) 文字")
        if let selectionStatistics {
            value += String(localized: "、選択範囲 \(selectionStatistics.characters) 文字")
        } else if let sectionStatistics {
            value += String(localized: "、セクション \(sectionStatistics.value.characters) 文字")
        }
        return value
    }

    private func statisticsRow(_ title: String, value: DocumentStatistics) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.subheadline.weight(.semibold))
            Text("空白込み \(value.characters) 文字 / 空白除外 \(value.nonWhitespaceCharacters) 文字")
                .font(.caption)
        }
    }

    private func estimatedTimeLabel(spoken: Bool) -> String {
        guard let minutes = readingEstimate.estimatedMinutes(for: document.text, spoken: spoken) else {
            return "—"
        }
        return String(localized: "約\(minutes) 分")
    }

    private var writingProgressView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("執筆目標とセッション").font(.headline)
            if let fileURL {
                let state = settingsStore.displayState(for: fileURL)
                if let goal = state?.writingGoal {
                    ProgressView(value: min(1, Double(statistics.characters) / Double(goal))) {
                        Text("\(statistics.characters) / \(goal) 文字")
                    }
                    Text(statistics.characters >= goal ? "目標を達成しました" : "目標まで \(goal - statistics.characters) 文字")
                        .font(.caption)
                }
                HStack {
                    TextField("文字数目標", text: $writingGoalInput)
                        .textFieldStyle(.roundedBorder)
                    Button("設定") {
                        settingsStore.setWritingGoal(Int(writingGoalInput), for: fileURL)
                    }
                    .disabled((Int(writingGoalInput) ?? 0) <= 0)
                    if state?.writingGoal != nil {
                        Button("解除") {
                            settingsStore.setWritingGoal(nil, for: fileURL)
                            writingGoalInput = ""
                        }
                    }
                }
                let change = statistics.characters - (state?.sessionBaselineCharacters ?? statistics.characters)
                Text("セッションの増減: \(change >= 0 ? "+" : "")\(change) 文字")
                Button("セッションをここから開始") {
                    settingsStore.resetWritingSession(for: fileURL,
                        currentCharacters: statistics.characters)
                }
                .font(.caption)
            } else {
                Text("目標を保存するには書類を保存してください。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                let change = statistics.characters - (unsavedSessionBaseline ?? statistics.characters)
                Text("このウインドウの増減: \(change >= 0 ? "+" : "")\(change) 文字")
            }
        }
    }

    private func formatButton(_ command: EditorCommand) -> some View {
        Button {
            command.perform(on: editorModel)
        } label: {
            Label(command.title, systemImage: command.symbolName)
        }
        .help(command.title)
        .disabled(!command.canExecute(in: editorModel))
    }
}

private struct MarkdownPrintSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State var settings: MarkdownPrintSettings
    let paperSize: NSSize
    let onPrint: (MarkdownPrintSettings) -> Void

    var body: some View {
        Form {
            Section("余白（pt）") {
                TextField("上", value: $settings.topMargin, format: .number)
                TextField("下", value: $settings.bottomMargin, format: .number)
                TextField("左", value: $settings.leftMargin, format: .number)
                TextField("右", value: $settings.rightMargin, format: .number)
            }
            Section("ヘッダーとフッター") {
                Toggle("ヘッダーに書類名を表示", isOn: $settings.header)
                Toggle("フッターにページ番号を表示", isOn: $settings.footer)
            }
            if !settings.isValid(for: paperSize) {
                Text("余白を小さくしてください。本文領域には縦横100pt以上が必要です。")
                    .foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("キャンセル") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("印刷…") {
                    dismiss()
                    onPrint(settings)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!settings.isValid(for: paperSize))
            }
        }
        .frame(width: 360)
        .padding(20)
    }
}

private struct MarkdownPlainTextExportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State var options: MarkdownPlainTextOptions
    let onExport: (MarkdownPlainTextOptions) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("テキスト書き出し").font(.headline)
            Toggle("リンク先のURLを残す", isOn: $options.linkDestinations)
            Toggle("脚注を残す", isOn: $options.footnotes)
            Toggle("画像の説明を残す", isOn: $options.imageDescriptions)
            HStack {
                Spacer()
                Button("キャンセル") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("続ける…") {
                    dismiss()
                    onExport(options)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .frame(width: 320)
        .padding(20)
    }
}

private struct LinkDiagnosticsSheet: View {
    let diagnostics: [MarkdownLinkDiagnostic]
    let isChecking: Bool
    let source: String
    let onSelect: (MarkdownLinkDiagnostic) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("リンク診断").font(.headline)
                Spacer()
                Button("閉じる") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            if isChecking {
                ProgressView("リンクを確認中")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if diagnostics.isEmpty {
                ContentUnavailableView("リンクの問題は見つかりません", systemImage: "checkmark.circle")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                let lines = MarkdownLineIndex(source)
                List(diagnostics) { diagnostic in
                    Button {
                        onSelect(diagnostic)
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(diagnostic.title).fontWeight(.medium)
                            Text("\(lines.line(containingUTF16Offset: diagnostic.sourceRange.location)) 行: \(diagnostic.detail)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(minWidth: 560, minHeight: 350)
        .padding(20)
    }
}

private struct MarkdownLintSheet: View {
    let diagnostics: [MarkdownLintDiagnostic]
    let isChecking: Bool
    let source: String
    let disabledRules: Set<MarkdownLintRule>
    let onToggleRule: (MarkdownLintRule, Bool) -> Void
    let onSelect: (MarkdownLintDiagnostic) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Markdown診断").font(.headline)
                Spacer()
                Button("閉じる") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            HStack {
                ForEach(MarkdownLintRule.allCases, id: \.self) { rule in
                    Toggle(rule.title, isOn: Binding(
                        get: { !disabledRules.contains(rule) },
                        set: { onToggleRule(rule, $0) }
                    ))
                }
            }
            if isChecking {
                ProgressView("Markdownを確認中")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if diagnostics.isEmpty {
                ContentUnavailableView("有効な規則で問題は見つかりません", systemImage: "checkmark.circle")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                let lines = MarkdownLineIndex(source)
                List(diagnostics) { diagnostic in
                    Button { onSelect(diagnostic) } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(diagnostic.rule.title).fontWeight(.medium)
                            Text("\(lines.line(containingUTF16Offset: diagnostic.sourceRange.location)) 行: \(diagnostic.detail)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(minWidth: 560, minHeight: 350)
        .padding(20)
    }
}

private struct MarkdownAutoFormatSheet: View {
    let source: String
    let selectedRange: NSRange
    let onApply: (MarkdownAutoFormatPlan) -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var selectionOnly = false
    @State private var applyFailed = false

    private var plan: MarkdownAutoFormatPlan? {
        MarkdownAutoFormat.plan(source, selection: selectionOnly ? selectedRange : nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Markdownの自動整形").font(.headline)
                Spacer()
                Button("閉じる") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            Picker("対象", selection: $selectionOnly) {
                Text("文書全体").tag(false)
                Text("選択範囲の行").tag(true)
            }
            .pickerStyle(.segmented)
            .disabled(selectedRange.length == 0)
            Text("箇条書き記号と見出しの空白を揃え、不要な行末空白を除きます。コード、明示改行、フロントマターは保持します。")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let plan {
                Text("\(plan.changes.count) 行を変更します。")
                List(plan.changes, id: \.line) { change in
                    VStack(alignment: .leading, spacing: 3) {
                        Text("行 \(change.line)").fontWeight(.semibold)
                        Text("− \(change.before)").foregroundStyle(.secondary)
                        Text("+ \(change.after)")
                    }
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                }
            } else {
                ContentUnavailableView("変更箇所はありません", systemImage: "checkmark.circle")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if applyFailed {
                Text("本文が変更されたか編集中のため、整形を適用できませんでした。")
                    .foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("整形を適用") {
                    guard let plan else { return }
                    if onApply(plan) { dismiss() } else { applyFailed = true }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(plan == nil)
            }
        }
        .frame(width: 650, height: 450)
        .padding(20)
    }
}

@MainActor
final class PreviewTaskUndoTarget {
    func replaceText(_ newText: String, in text: Binding<String>, undoManager: UndoManager?,
                     actionName: String = String(localized: "タスクの完了切替")) {
        let previous = text.wrappedValue
        guard previous != newText else { return }
        text.wrappedValue = newText
        if let undoManager {
            undoManager.registerUndo(withTarget: self) { [weak undoManager] target in
                target.replaceText(previous, in: text, undoManager: undoManager,
                                   actionName: actionName)
            }
            undoManager.setActionName(actionName)
        }
    }
}

private struct LinkEditorSheet: View {
    let draft: MarkdownLinkDraft
    let documentContext: DocumentContext
    let analysis: MarkdownAnalysis?
    let onSave: (String, String, String) -> Bool
    let onSaveReference: (String, String) -> Bool
    let onAttach: @MainActor (String, URL, ImageImportMode) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    private enum LinkForm: String, CaseIterable {
        case inline = "URL", reference = "参照ID"
        var title: String { self == .inline ? "URL" : String(localized: "参照ID") }
    }
    @State private var form: LinkForm = .inline
    @State private var label: String
    @State private var destination: String
    @State private var title: String
    @State private var referenceID = ""
    @State private var showsSaveError = false
    @State private var fileCandidates: [FilePathSuggestion] = []
    @State private var headingSuggestions: [HeadingLinkSuggestion] = []
    @State private var attachmentURL: URL?
    @State private var attachmentMode: ImageImportMode = .managedCopy
    @State private var showsAttachmentImporter = false
    @State private var isAttaching = false
    @State private var attachmentError: String?

    init(draft: MarkdownLinkDraft, documentContext: DocumentContext, analysis: MarkdownAnalysis?,
         onSave: @escaping (String, String, String) -> Bool,
         onSaveReference: @escaping (String, String) -> Bool,
         onAttach: @escaping @MainActor (String, URL, ImageImportMode) async throws -> Void) {
        self.draft = draft
        self.documentContext = documentContext
        self.analysis = analysis
        self.onSave = onSave
        self.onSaveReference = onSaveReference
        self.onAttach = onAttach
        _label = State(initialValue: draft.label)
        _destination = State(initialValue: draft.destination)
        _title = State(initialValue: draft.title)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(draft.isExisting ? "リンクを編集" : "リンクを挿入")
                .font(.headline)
            let referenceIDs = analysis.map(MarkdownLinkCompletion.referenceIDs(in:)) ?? []
            if !referenceIDs.isEmpty {
                Picker("リンク形式", selection: $form) {
                    ForEach(LinkForm.allCases, id: \.self) { value in
                        Text(value.title).tag(value)
                    }
                }
                .pickerStyle(.segmented)
            }
            Form {
                TextField("表示名", text: $label)
                if form == .inline {
                    TextField("URL", text: $destination)
                    TextField("タイトル（任意）", text: $title)
                } else {
                    Picker("参照ID", selection: $referenceID) {
                        Text("選択してください").tag("")
                        ForEach(referenceIDs, id: \.self) { id in Text(id).tag(id) }
                    }
                }
            }
            .formStyle(.grouped)
            .frame(height: 180)
            if form == .inline && !draft.isExisting {
                HStack {
                    Button("ファイルを選択…") { showsAttachmentImporter = true }
                        .disabled(documentContext.directoryURL == nil || isAttaching)
                    Text(attachmentURL?.lastPathComponent ?? "ファイル未選択")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if attachmentURL != nil {
                    Picker("添付方法", selection: $attachmentMode) {
                        ForEach(ImageImportMode.allCases, id: \.self) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    Button("ファイルを添付") { attachFile() }
                        .disabled(isAttaching || label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            if let attachmentError {
                Text(attachmentError).foregroundStyle(.red)
            }
            let fileSuggestions = form == .inline
                ? FilePathCompletion.matches(destination, in: fileCandidates) : []
            if !fileSuggestions.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("この書類のフォルダ内")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(fileSuggestions) { suggestion in
                        Button {
                            destination = suggestion.path
                        } label: {
                            Label(suggestion.path, systemImage: suggestion.isDirectory ? "folder" : "doc")
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("リンク先候補、\(suggestion.path)")
                    }
                }
                .padding(8)
                .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
            }
            if form == .inline && !headingSuggestions.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("見出し")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(Array(headingSuggestions.prefix(8))) { suggestion in
                        Button {
                            destination = suggestion.destination
                        } label: {
                            Label(suggestion.title, systemImage: "number")
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("見出し候補、\(suggestion.title)")
                    }
                }
                .padding(8)
                .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
            }
            if form == .inline && documentContext.directoryURL == nil {
                Text("ファイルへの相対リンクを補完するには、先に書類を保存してください。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if showsSaveError {
                Text("リンクを保存できません。本文と編集状態を確認してください。")
                    .foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("キャンセル") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(draft.isExisting ? "更新" : "挿入") {
                    let saved = form == .inline
                        ? onSave(label, destination, title)
                        : onSaveReference(label, referenceID)
                    if saved {
                        dismiss()
                    } else {
                        showsSaveError = true
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                          (form == .inline
                           ? destination.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                           : referenceID.isEmpty))
            }
        }
        .fileImporter(isPresented: $showsAttachmentImporter, allowedContentTypes: [.item],
                      allowsMultipleSelection: false) { outcome in
            switch outcome {
            case let .success(urls):
                attachmentURL = urls.first
                if label == String(localized: "リンク"), let file = urls.first {
                    label = file.deletingPathExtension().lastPathComponent
                }
            case let .failure(error): attachmentError = error.localizedDescription
            }
        }
        .frame(width: 480)
        .padding(20)
        .task(id: documentContext.directoryURL) {
            guard let directory = documentContext.directoryURL else {
                fileCandidates = []
                return
            }
            fileCandidates = await Task.detached(priority: .userInitiated) {
                FilePathCompletion.scan(in: directory)
            }.value
        }
        .task(id: destination) {
            guard let analysis else { headingSuggestions = []; return }
            let query = destination
            let context = documentContext
            let suggestions = await Task.detached(priority: .userInitiated) {
                MarkdownLinkCompletion.headings(for: query, current: analysis, context: context)
            }.value
            if !Task.isCancelled { headingSuggestions = suggestions }
        }
    }

    private func attachFile() {
        guard let attachmentURL else { return }
        isAttaching = true
        attachmentError = nil
        Task {
            do {
                try await onAttach(label, attachmentURL, attachmentMode)
                dismiss()
            } catch {
                attachmentError = error.localizedDescription
            }
            isAttaching = false
        }
    }
}
