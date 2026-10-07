import AppKit
import CryptoKit
import SwiftUI
import UniformTypeIdentifiers

/// Keeps AppKit toolbar customization families separate for simultaneous document windows.
struct EditorToolbarInstanceID: Equatable {
    let rawValue: String

    init(documentURL: URL?, uuid: UUID = UUID()) {
        if let documentURL {
            let path = documentURL.standardizedFileURL.path
            let digest = SHA256.hash(data: Data(path.utf8))
            rawValue = "mktown-editor-" + digest.prefix(12).map { String(format: "%02x", $0) }.joined()
        } else {
            rawValue = "mktown-editor-\(uuid.uuidString)"
        }
    }
}

struct EditorWorkspace: View {
    @Binding var document: MarkdownDocument
    let fileURL: URL?

    init(document: Binding<MarkdownDocument>, fileURL: URL?) {
        _document = document
        self.fileURL = fileURL
        _toolbarInstanceID = State(initialValue: EditorToolbarInstanceID(documentURL: fileURL))
    }

    @EnvironmentObject private var settingsStore: EditorSettingsStore
    @EnvironmentObject private var documentLinkNavigation: DocumentLinkNavigation
    @EnvironmentObject private var workspaceStore: WorkspaceStore
    @EnvironmentObject private var layoutActivation: WorkspaceLayoutActivation
    @Environment(\.undoManager) private var undoManager
    @Environment(\.openDocument) private var openDocument
    @StateObject private var editorModel = MarkdownEditorModel()
    @State private var positionSaveTask: Task<Void, Never>?
    @State private var cloudMonitor: WorkspaceDirectoryMonitor?
    @StateObject private var analysisStore = DocumentAnalysisStore()
    @StateObject private var statusStore = DocumentStatusStore()
    @State private var previewTaskUndoTarget = PreviewTaskUndoTarget()
    @StateObject private var detachedPreview = DetachedPreviewWindowManager()
    @StateObject private var slideWindow = MarkdownSlideWindowManager()
    @StateObject private var previewUpdates = PreviewUpdateController()
    @SceneStorage("editorMode") private var legacyMode: String?
    @State private var unsavedMode: EditorMode = .split
    @State private var toolbarInstanceID: EditorToolbarInstanceID
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
    @State private var externalLinkChecks: [MarkdownExternalLinkCheck] = []
    @State private var isCheckingExternalLinks = false
    @State private var externalLinkTask: Task<Void, Never>?
    @State private var showingMarkdownLint = false
    @State private var showingWorkspaceTags = false
    @State private var showingBacklinks = false
    @State private var showingWikiLinks = false
    @State private var wikiSelection = NSRange(location: 0, length: 0)
    @State private var showingFrontMatterProperties = false
    @State private var isCheckingMarkdownLint = false
    @State private var markdownLintDiagnostics: [MarkdownLintDiagnostic] = []
    @State private var showingTerminology = false
    @State private var isCheckingTerminology = false
    @State private var terminologyIssues: [TerminologyIssue] = []
    @State private var terminologySource = ""
    @State private var terminologyTask: Task<[TerminologyIssue], Never>?
    @State private var showingAutoFormat = false
    @State private var synchronizedBlockID: Int?
    @State private var showingRegexSearch = false
    @State private var htmlExportError: String?
    @State private var pdfExportError: String?
    @State private var documentOperation: Task<Void, Never>?
    @State private var documentOperationRunning = false
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
    @State private var showingDailyNote = false
    @State private var showingWorkspaceTasks = false
    @State private var showingLinkGraph = false
    @State private var showingNoteSplit = false
    @State private var splitHeadingLocation: Int?
    @State private var showingNoteMerge = false
    @State private var showingNamedLayouts = false
    @State private var showingWorkspaceSearch = false
    @State private var showingWorkspaceReplace = false
    @State private var showingAttachmentAudit = false
    @State private var showingSnapshotHistory = false
    @State private var showingGitHistory = false
    @State private var showingGitCommit = false
    @State private var showingCloudStatus = false
    @State private var showingPublication = false
    @State private var showingCollaboration = false
    @State private var showingAISuggestion = false
    @StateObject private var collaboration = CollaborationSession()
    @State private var pendingCollaborativeText: String?
    @State private var cloudStatus: CloudFileStatus?
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
                let currentMode = fileURL.map(settingsStore.mode(for:)) ?? unsavedMode
                if currentMode != newMode { editorModel.prepareForViewTransition() }
                if let fileURL {
                    settingsStore.setMode(newMode, for: fileURL)
                } else {
                    unsavedMode = newMode
                }
            }
        )
    }

    private var statistics: DocumentStatistics {
        analysisStore.snapshot?.statistics ?? .empty
    }

    private var selectionStatistics: DocumentStatistics? { statusStore.selection }

    private var wordCountMode: WordCountMode {
        settingsStore.app.wordCountMode ?? .whitespace
    }

    private var displayedWordCount: Int {
        analysisStore.snapshot?.wordCounts[wordCountMode] ?? 0
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

    private var sectionStatistics: (title: String, value: DocumentStatistics)? { statusStore.section }

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
        // NavigationSplitView supplies the standard sidebar toggle.
        .toolbar(id: toolbarInstanceID.rawValue) {
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
                    Button("用語の表記を確認") {
                        showingTerminology = true
                        checkTerminology()
                    }
                    Button("自動整形…") { showingAutoFormat = true }
                }
                .help("Markdown診断・用語確認・自動整形")
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
                                         settingsStore: settingsStore,
                                         workspaceStore: workspaceStore, updates: previewUpdates)
                }
                .help("現在の書類のプレビューを別ウインドウで表示")
            }
            ToolbarItem(id: "slides", placement: .primaryAction) {
                Button("スライド表示", systemImage: "play.rectangle") {
                    showSlidePresentation()
                }
                .help("区切り線をスライド境界として全画面表示")
            }
            ToolbarItem(id: "git-history", placement: .primaryAction) {
                Button("Gitの差分と履歴", systemImage: "clock.arrow.circlepath") {
                    showingGitHistory = true
                }
                .disabled(fileURL == nil)
            }
            ToolbarItem(id: "git-commit", placement: .primaryAction) {
                Button("Gitのステージとコミット", systemImage: "checkmark.circle") {
                    showingGitCommit = true
                }
                .disabled(fileURL == nil)
            }
            ToolbarItem(id: "cloud-status", placement: .primaryAction) {
                Button(cloudStatus?.hasUnresolvedConflicts == true ? "競合版あり" : "同期状態と競合版",
                       systemImage: cloudStatus?.hasUnresolvedConflicts == true
                           ? "exclamationmark.triangle" : "icloud") {
                    showingCloudStatus = true
                }
                .disabled(fileURL == nil)
            }
            ToolbarItem(id: "publication", placement: .primaryAction) {
                Button("ブログ・静的サイトへ公開", systemImage: "square.and.arrow.up") {
                    showingPublication = true
                }
            }
            ToolbarItem(id: "collaboration", placement: .primaryAction) {
                Button("共同編集とコメント", systemImage: "person.2") {
                    showingCollaboration = true
                }
            }
            ToolbarItem(id: "ai-suggestion", placement: .primaryAction) {
                Button("選択範囲をAIで推敲・翻訳", systemImage: "text.badge.checkmark") {
                    showingAISuggestion = true
                }
                .disabled(!editorModel.hasActiveEditor || editorModel.selectedRange.length == 0)
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
            .overlay {
                if documentOperationRunning {
                    VStack(spacing: 12) {
                        ProgressView("処理中…")
                        Button("中止") { documentOperation?.cancel() }
                    }
                    .padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityElement(children: .contain)
                }
            }
            .onDisappear { documentOperation?.cancel() }
            // Use one system toolbar background across both editor panes.
            .toolbarBackground(Color(nsColor: .windowBackgroundColor), for: .windowToolbar)
            .toolbarBackground(.visible, for: .windowToolbar)
        .sheet(isPresented: $showingGitHistory) {
            if let fileURL { GitHistorySheet(fileURL: fileURL) }
        }
        .sheet(isPresented: $showingGitCommit) {
            if let fileURL {
                GitCommitSheet(fileURL: fileURL) { url in
                    Task {
                        do { try await openDocument(at: url) }
                        catch { workspaceOpenError = error.localizedDescription }
                    }
                }
            }
        }
        .sheet(isPresented: $showingCloudStatus) {
            if let fileURL {
                CloudFileStatusSheet(fileURL: fileURL, source: $document.text) { selected, expected in
                    guard document.text == expected else { return false }
                    if editorModel.hasActiveEditor {
                        let range = NSRange(location: 0, length: (expected as NSString).length)
                        return editorModel.applyRegexEdit(MarkdownEdit(range: range,
                            replacement: selected, selection: NSRange(location: 0, length: 0)),
                            expectedSource: expected)
                    }
                    previewTaskUndoTarget.replaceText(selected, in: $document.text,
                        undoManager: undoManager, actionName: String(localized: "競合版を採用"))
                    return true
                }
            }
        }
        .sheet(isPresented: $showingPublication) {
            PublicationSheet(source: $document.text, documentURL: fileURL)
        }
        .sheet(isPresented: $showingCollaboration) {
            CollaborationSheet(session: collaboration, editorModel: editorModel,
                               source: $document.text,
                               documentTitle: fileURL?.lastPathComponent ?? String(localized: "無題"))
        }
        .sheet(isPresented: $showingAISuggestion) {
            AISuggestionSheet(editorModel: editorModel, source: $document.text)
        }
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
            GoToHeadingSheet(entries: currentAnalysisSnapshot?.outlineEntries ?? []) {
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
                                 externalChecks: externalLinkChecks,
                                 isCheckingExternal: isCheckingExternalLinks,
                                 source: document.text,
                                 onCheckExternal: checkExternalLinks,
                                 onSelect: { range in
                                     showingLinkDiagnostics = false
                                     if mode.wrappedValue == .preview { mode.wrappedValue = .editor }
                                     navigate(to: range.location)
                                 })
                .onDisappear {
                    externalLinkTask?.cancel()
                    isCheckingExternalLinks = false
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
        .sheet(isPresented: $showingWorkspaceTags) {
            if let root = workspaceStore.rootURL {
                WorkspaceTagsSheet(root: root, nodes: workspaceStore.nodes,
                                   isTruncated: workspaceStore.isTruncated,
                                   loadOpenBuffers: {
                                       try workspaceStore.openBufferSnapshots(under: root)
                                   }, onOpen: { url in
                                       showingWorkspaceTags = false
                                       Task {
                                           do { try await openDocument(at: url) }
                                           catch { workspaceOpenError = error.localizedDescription }
                                       }
                                   })
            }
        }
        .sheet(isPresented: $showingBacklinks) {
            if let root = workspaceStore.rootURL, let target = fileURL {
                WorkspaceBacklinksSheet(root: root, targetURL: target,
                    nodes: workspaceStore.nodes, isTruncated: workspaceStore.isTruncated,
                    loadOpenBuffers: {
                        try workspaceStore.openBufferSnapshots(under: root)
                    }, onOpen: { backlink in
                        showingBacklinks = false
                        if backlink.sourceURL.resolvingSymlinksInPath().standardizedFileURL ==
                            target.resolvingSymlinksInPath().standardizedFileURL {
                            if mode.wrappedValue == .preview { mode.wrappedValue = .editor }
                            navigate(to: backlink.sourceRange.location)
                        } else {
                            documentLinkNavigation.requestPosition(in: backlink.sourceURL,
                                range: backlink.sourceRange)
                            Task {
                                do { try await openDocument(at: backlink.sourceURL) }
                                catch {
                                    documentLinkNavigation.cancelPosition(for: backlink.sourceURL)
                                    workspaceOpenError = error.localizedDescription
                                }
                            }
                        }
                    })
            }
        }
        .sheet(isPresented: $showingWikiLinks) {
            if let root = workspaceStore.rootURL, let fileURL {
                WorkspaceWikiLinkSheet(root: root, nodes: workspaceStore.nodes,
                    documentURL: fileURL, source: document.text,
                    selection: wikiSelection, onApply: { edit, expectedSource in
                        guard document.text == expectedSource,
                              !workspaceStore.isDocumentLocked(fileURL) else { return false }
                        if editorModel.hasActiveEditor {
                            return editorModel.applyRegexEdit(edit, expectedSource: expectedSource)
                        }
                        previewTaskUndoTarget.replaceText(edit.applying(to: expectedSource),
                            in: $document.text, undoManager: undoManager,
                            actionName: String(localized: "Wikiリンクを変更"))
                        return true
                    }, onOpen: { url in
                        if url.resolvingSymlinksInPath().standardizedFileURL ==
                            fileURL.resolvingSymlinksInPath().standardizedFileURL { return }
                        Task {
                            do { try await openDocument(at: url) }
                            catch { workspaceOpenError = error.localizedDescription }
                        }
                    })
            }
        }
        .sheet(isPresented: $showingDailyNote) {
            if let root = workspaceStore.rootURL {
                WorkspaceDailyNoteSheet(root: root) { url in
                    workspaceStore.refresh(force: true)
                    Task {
                        do { try await openDocument(at: url) }
                        catch { workspaceOpenError = error.localizedDescription }
                    }
                }
            }
        }
        .sheet(isPresented: $showingWorkspaceTasks) {
            if let root = workspaceStore.rootURL {
                WorkspaceTaskSheet(root: root, nodes: workspaceStore.nodes,
                    isTruncated: workspaceStore.isTruncated,
                    loadOpenBuffers: {
                        try workspaceStore.openBufferSnapshots(under: root)
                    }, onToggle: { task in
                        if task.sourceURL.resolvingSymlinksInPath().standardizedFileURL ==
                            fileURL?.resolvingSymlinksInPath().standardizedFileURL {
                            applyWorkspaceTask(task)
                        } else {
                            documentLinkNavigation.requestTaskToggle(task)
                            Task {
                                do { try await openDocument(at: task.sourceURL) }
                                catch {
                                    documentLinkNavigation.cancelTaskToggle(for: task.sourceURL)
                                    workspaceOpenError = error.localizedDescription
                                }
                            }
                        }
                    }, onOpen: { task in
                        if task.sourceURL.resolvingSymlinksInPath().standardizedFileURL ==
                            fileURL?.resolvingSymlinksInPath().standardizedFileURL {
                            if mode.wrappedValue == .preview { mode.wrappedValue = .editor }
                            navigate(to: task.sourceLocation)
                        } else {
                            documentLinkNavigation.requestPosition(in: task.sourceURL,
                                range: NSRange(location: task.sourceLocation, length: 0))
                            Task {
                                do { try await openDocument(at: task.sourceURL) }
                                catch {
                                    documentLinkNavigation.cancelPosition(for: task.sourceURL)
                                    workspaceOpenError = error.localizedDescription
                                }
                            }
                        }
                    })
            }
        }
        .sheet(isPresented: $showingLinkGraph) {
            if let root = workspaceStore.rootURL {
                WorkspaceLinkGraphSheet(root: root, focusURL: fileURL,
                    nodes: workspaceStore.nodes,
                    isTruncated: workspaceStore.isTruncated,
                    loadOpenBuffers: {
                        try workspaceStore.openBufferSnapshots(under: root)
                    }, onOpen: { url in
                        guard url.resolvingSymlinksInPath().standardizedFileURL !=
                            fileURL?.resolvingSymlinksInPath().standardizedFileURL else { return }
                        Task {
                            do { try await openDocument(at: url) }
                            catch { workspaceOpenError = error.localizedDescription }
                        }
                    })
            }
        }
        .sheet(isPresented: $showingNoteSplit) {
            if let root = workspaceStore.rootURL, let fileURL,
               let headingLocation = splitHeadingLocation {
                WorkspaceNoteSplitSheet(root: root, sourceURL: fileURL,
                    source: document.text, headingLocation: headingLocation,
                    workspaceDocuments: WorkspaceQuickOpen.search(
                        nodes: workspaceStore.nodes, root: root,
                        query: "", limit: Int.max).map(\.url),
                    onCreate: { plan, destination, expectedSource in
                        guard document.text == expectedSource,
                              !workspaceStore.isDocumentLocked(fileURL) else {
                            throw WorkspaceNoteOperationError.sourceChanged
                        }
                        return try WorkspaceNoteOperations.applySplit(plan,
                            destinationURL: destination, root: root) {
                            if editorModel.hasActiveEditor {
                                return editorModel.applyRegexEdit(plan.sourceEdit,
                                    expectedSource: expectedSource)
                            }
                            previewTaskUndoTarget.replaceText(
                                plan.sourceEdit.applying(to: expectedSource),
                                in: $document.text, undoManager: undoManager,
                                actionName: String(localized: "セクションを分割"))
                            return true
                        }
                    }, onOpen: { url in
                        workspaceStore.refresh(force: true)
                        Task {
                            do { try await openDocument(at: url) }
                            catch { workspaceOpenError = error.localizedDescription }
                        }
                    })
            }
        }
        .sheet(isPresented: $showingNoteMerge) {
            if let root = workspaceStore.rootURL {
                WorkspaceNoteMergeSheet(root: root, nodes: workspaceStore.nodes,
                    loadOpenBuffers: {
                        try workspaceStore.openBufferSnapshots(under: root)
                    }, onOpen: { url in
                        workspaceStore.refresh(force: true)
                        Task {
                            do { try await openDocument(at: url) }
                            catch { workspaceOpenError = error.localizedDescription }
                        }
                    })
            }
        }
        .sheet(isPresented: $showingNamedLayouts) {
            if let root = workspaceStore.rootURL {
                WorkspaceNamedLayoutSheet(root: root,
                    current: WorkspaceNamedLayout.capture(name: "", root: root,
                        openDocuments: workspaceStore.openDocumentURLs,
                        activeDocument: fileURL, mode: mode.wrappedValue,
                        sidebarTab: sidebarTab.rawValue,
                        sidebarVisible: (focusMode.savedSidebarVisibility ?? sidebarVisibility) != .detailOnly,
                        splitRatio: splitRatio, splitOrientation: splitOrientation,
                        previewFirst: previewFirst),
                    onApply: applyNamedLayout)
            }
        }
        .sheet(isPresented: $showingFrontMatterProperties) {
            FrontMatterPropertiesSheet(source: document.text,
                canEdit: !workspaceStore.isDocumentLocked(fileURL)) { edit, expectedSource in
                    guard document.text == expectedSource,
                          !workspaceStore.isDocumentLocked(fileURL) else { return false }
                    if editorModel.hasActiveEditor {
                        return editorModel.applyRegexEdit(edit, expectedSource: expectedSource)
                    }
                    previewTaskUndoTarget.replaceText(edit.applying(to: expectedSource),
                        in: $document.text, undoManager: undoManager,
                        actionName: String(localized: "文書プロパティを変更"))
                    return true
                }
        }
        .sheet(isPresented: $showingTerminology) {
            TerminologySheet(issues: terminologyIssues, isChecking: isCheckingTerminology,
                             source: terminologySource, canReplace: editorModel.canExecuteCommand,
                             hasEntries: !(settingsStore.app.terminologyEntries ?? []).isEmpty,
                             onSelect: { issue in
                                 showingTerminology = false
                                 if mode.wrappedValue == .preview { mode.wrappedValue = .editor }
                                 navigate(to: issue.range.location)
                             }, onReplace: { issue in
                                 guard document.text == terminologySource,
                                       let edit = issue.replacement(in: terminologySource) else { return false }
                                 return editorModel.applyRegexEdit(edit, expectedSource: terminologySource)
                             })
                .onDisappear {
                    terminologyTask?.cancel()
                    terminologyTask = nil
                    isCheckingTerminology = false
                }
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
                            analysis: currentAnalysisSnapshot?.analysis,
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
        .sheet(item: $editorModel.tableGridDraft) { draft in
            TableGridSheet(draft: draft) { header, rows, alignments in
                editorModel.commitTableGrid(header: header, rows: rows, alignments: alignments)
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
            monitorCloudDocument(fileURL)
            refreshCloudStatus()
            if let fileURL {
                settingsStore.migrateLegacyMode(legacyMode, for: fileURL)
            } else {
                unsavedMode = legacyMode.flatMap(EditorMode.init(rawValue:)) ?? settingsStore.app.defaultMode
            }
            legacyMode = nil
            receivePendingExternalLine()
            receivePendingWorkspaceTask()
        }
        .onDisappear {
            savePosition(for: fileURL)
            detachedPreview.close()
            collaboration.stop()
            if workspaceViewActive {
                if let fileURL {
                    workspaceStore.unregisterOpenDocument(fileURL)
                    workspaceStore.unregisterOpenBuffer(id: openBufferID, url: fileURL)
                }
                workspaceViewActive = false
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshCloudStatus()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSText.didChangeNotification)) { _ in
            if let pendingCollaborativeText { applyCollaborativeText(pendingCollaborativeText) }
        }
        .onChange(of: editorModel.viewport) { _, _ in schedulePositionSave() }
        .onChange(of: fileURL) { oldURL, newURL in
            if oldURL != nil, oldURL != newURL { collaboration.stop() }
            monitorCloudDocument(newURL)
            refreshCloudStatus()
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
            if showingTerminology { checkTerminology() }
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
            receivePendingWorkspaceTask()
        }
        .onChange(of: document.text) { _, newText in
            workspaceStore.openBufferDidChange()
            collaboration.localChange(newText)
            previewUpdates.sourceChanged()
            analysisStore.update(source: newText,
                                 dialect: settingsStore.markdownDialect(for: fileURL))
            previewSearchRange = nil
            synchronizedBlockID = nil
            if showingLinkDiagnostics { checkLinks() }
            if showingMarkdownLint { checkMarkdownLint() }
            if showingTerminology { checkTerminology() }
        }
        .onChange(of: collaboration.currentText) { _, sharedText in
            applyCollaborativeText(sharedText)
        }
        .onChange(of: settingsStore.app.terminologyEntries) { _, _ in
            if showingTerminology { checkTerminology() }
        }
        .onChange(of: settingsStore.app.terminologyOptions) { _, _ in
            if showingTerminology { checkTerminology() }
        }
        .onChange(of: previewSearchQuery) { _, _ in previewSearchRange = nil }
        .onChange(of: settingsStore.markdownDialect(for: fileURL)) { _, dialect in
            analysisStore.update(source: document.text, dialect: dialect)
            previewUpdates.resume()
        }
        .onChange(of: previewSearchCaseSensitive) { _, _ in previewSearchRange = nil }
        .onChange(of: editorModel.selectedRanges) { _, _ in
            schedulePositionSave()
            statusStore.update(snapshot: currentAnalysisSnapshot, selections: editorModel.selectedRanges)
        }
        .onChange(of: splitOrientation) { _, _ in savePosition(for: fileURL) }
        .onChange(of: previewFirst) { _, _ in savePosition(for: fileURL) }
        .onChange(of: analysisStore.snapshot?.source) { _, _ in
            receiveCompletedAnalysis()
        }
        .onChange(of: analysisStore.snapshot?.dialect) { _, _ in
            receiveCompletedAnalysis()
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
        .onChange(of: documentLinkNavigation.pendingTaskToggle) { _, _ in
            receivePendingWorkspaceTask()
        }
        .onChange(of: layoutActivation.event?.id) { _, _ in
            guard let fileURL, let layout = layoutActivation.layout(for: fileURL) else { return }
            applyNamedLayoutState(layout)
        }
        .onDisappear {
            positionSaveTask?.cancel()
            cloudMonitor?.stop()
            cloudMonitor = nil
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
        let selectedSnapshot = previewUpdates.state.isPaused
            ? previewUpdates.snapshot ?? analysisStore.snapshot : analysisStore.snapshot
        let presentation = PreviewPresentation(snapshot: selectedSnapshot,
            requestedSource: previewUpdates.state.displayedSource ?? document.text,
            currentSource: document.text, dialect: documentContext.markdownDialect)
        let displayedSource = presentation.source
        let isCurrent = presentation.isCurrent
        let taskAction: ((Int) -> Void)? = isCurrent ? previewTaskAction : nil
        let headingAction: ((String) -> Void)? = isCurrent
            ? { fragment in navigateToHeading(fragment) } : nil
        // Keep the structured scroll view mounted even while source actions are stale.
        let scrollAction: ((Int) -> Void)? = synchronizesScroll
            ? { blockID in if isCurrent { synchronizeEditor(to: blockID) } } : nil
        let revealAction: ((NSRange) -> Void)? = { range in
            if isCurrent { revealSource(range) }
        }
        let preview = MarkdownPreview(
            markdown: displayedSource, documentContext: documentContext,
            onToggleTask: taskAction, snapshot: presentation.snapshot, usesSharedAnalysis: true,
            navigationTarget: previewUpdates.state.isPaused && !isCurrent ? nil : previewNavigationTarget,
            searchRange: isCurrent ? previewSearchRange : nil,
            onOpenHeading: headingAction, onOpenDocument: openLinkedDocument,
            workspaceDocumentURLs: displayedSource.contains("![[") ? workspaceStore.documentURLs : [],
            workspaceContentRevision: workspaceStore.openBufferRevision,
            loadWorkspaceOpenBuffers: workspaceStore.rootURL.map { root in
                { try workspaceStore.openBufferSnapshots(under: root) }
            },
            onOpenEmbeddedDocument: { url in
                Task {
                    do { try await openDocument(at: url) }
                    catch { workspaceOpenError = error.localizedDescription }
                }
            },
            onVisibleBlockChange: scrollAction, onRevealSource: revealAction,
            showsFrontMatter: settingsStore.app.showsFrontMatterInPreview ?? false,
            zoom: settingsStore.zoom(for: .preview),
            loadsRemoteImages: settingsStore.app.loadsRemoteImages ?? false,
            loadsExternalLinkPreviews: settingsStore.app.loadsExternalLinkPreviews ?? false,
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

    private func applyNamedLayout(_ layout: WorkspaceNamedLayout) {
        guard let root = workspaceStore.rootURL else { return }
        let resolved = layout.resolveDocuments(root: root)
        for url in resolved.urls {
            settingsStore.applyWorkspaceLayout(layout, to: url)
        }
        layoutActivation.activate(layout, documents: resolved.urls)
        applyNamedLayoutState(layout)
        Task {
            var failed = resolved.missing
            for url in resolved.urls {
                do { try await openDocument(at: url) }
                catch { failed.append(url.lastPathComponent) }
            }
            if !failed.isEmpty {
                workspaceOpenError = String(localized: "開けなかった書類: \(failed.joined(separator: ", "))")
            }
        }
    }

    private func applyNamedLayoutState(_ layout: WorkspaceNamedLayout) {
        if focusMode.isActive {
            sidebarVisibility = focusMode.toggle(sidebarVisibility: sidebarVisibility)
        }
        mode.wrappedValue = layout.mode
        sidebarTab = SidebarTab(rawValue: layout.sidebarTab) ?? .outline
        sidebarVisibility = layout.sidebarVisible ? .all : .detailOnly
        splitRatio = min(0.8, max(0.2, layout.splitRatio))
        splitOrientation = layout.splitOrientation
        previewFirst = layout.previewFirst
        savePosition(for: fileURL)
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
        guard currentAnalysisSnapshot != nil else { return nil }
        return { toggleTask(at: $0) }
    }

    private var currentAnalysisSnapshot: DocumentSnapshot? {
        guard let snapshot = analysisStore.snapshot,
              snapshot.matches(source: document.text, dialect: documentContext.markdownDialect) else { return nil }
        return snapshot
    }

    private var outlineEntries: [MarkdownOutlineEntry] {
        analysisStore.snapshot?.outlineEntries ?? []
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
        let isReady = currentAnalysisSnapshot != nil
        let items = currentAnalysisSnapshot.map { snapshot in
            MarkdownContentInspector.items(in: document.text, analysis: snapshot.analysis)
        } ?? []
        return List {
            Section("文書プロパティ") {
                Button("プロパティを編集…") { showingFrontMatterProperties = true }
            }
            Section("参照元") {
                Button("バックリンクを表示…") { showingBacklinks = true }
                    .disabled(fileURL == nil || workspaceStore.rootURL == nil)
                Button("文書リンクのグラフを表示…") { showingLinkGraph = true }
                    .disabled(workspaceStore.rootURL == nil)
            }
            Section("Wikiリンク") {
                Button("Wikiリンクを挿入・編集…") {
                    wikiSelection = editorModel.selectedRange
                    showingWikiLinks = true
                }
                .disabled(fileURL == nil || workspaceStore.rootURL == nil ||
                    workspaceStore.isDocumentLocked(fileURL))
            }
            Section("文書を整理") {
                Button("現在のセクションを分割…") {
                    guard currentAnalysisSnapshot != nil else { return }
                    splitHeadingLocation = MarkdownOutline.currentSection(
                        at: editorModel.selectedRange.location, in: outlineEntries)?.sourceRange.location
                    showingNoteSplit = splitHeadingLocation != nil
                }
                .disabled(!isReady || fileURL == nil || workspaceStore.rootURL == nil ||
                    workspaceStore.isDocumentLocked(fileURL) ||
                    MarkdownOutline.currentSection(at: editorModel.selectedRange.location,
                        in: outlineEntries) == nil)
                Button("書類を結合…") { showingNoteMerge = true }
                    .disabled(workspaceStore.rootURL == nil)
            }
            Section("作業レイアウト") {
                Button("名前付きレイアウト…") { showingNamedLayouts = true }
                    .disabled(workspaceStore.rootURL == nil)
            }
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
                Button("日付ノートを開く…", systemImage: "calendar") {
                    showingDailyNote = true
                }
                .labelStyle(.iconOnly)
                .disabled(workspaceStore.rootURL == nil)
                .help("日付ノートを開く")
                Button("未完了のタスクを表示…", systemImage: "checklist") {
                    showingWorkspaceTasks = true
                }
                .labelStyle(.iconOnly)
                .disabled(workspaceStore.rootURL == nil)
                .help("未完了のタスクを表示")
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
                        Button("タグ一覧…") { showingWorkspaceTags = true }
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
        let snapshot = analysisStore.snapshot
        let entries = snapshot?.outlineEntries ?? []
        let isCurrent = currentAnalysisSnapshot != nil
        let canEdit = isCurrent && editorModel.canExecuteCommand
        let highlightedID = currentSectionID
        return List(entries) { entry in
            let actions = snapshot?.sectionActions[entry.id]
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
                    editorModel.moveSection(at: entry.sourceRange.location, direction: .up, snapshot: snapshot,
                        dialect: documentContext.markdownDialect)
                }
                .disabled(!canEdit || actions?.canMoveUp != true)
                Button("セクションを下へ移動") {
                    editorModel.moveSection(at: entry.sourceRange.location, direction: .down, snapshot: snapshot,
                        dialect: documentContext.markdownDialect)
                }
                .disabled(!canEdit || actions?.canMoveDown != true)
                Divider()
                Button("見出しと子見出しを昇格") {
                    editorModel.changeSectionLevel(at: entry.sourceRange.location, by: -1, snapshot: snapshot,
                        dialect: documentContext.markdownDialect)
                }
                .disabled(!canEdit || actions?.canPromote != true)
                Button("見出しと子見出しを降格") {
                    editorModel.changeSectionLevel(at: entry.sourceRange.location, by: 1, snapshot: snapshot,
                        dialect: documentContext.markdownDialect)
                }
                .disabled(!canEdit || actions?.canDemote != true)
            }
            .listRowBackground(highlightedID == entry.id ? Color.accentColor.opacity(0.16) : Color.clear)
            .disabled(!isCurrent)
            .accessibilityLabel("見出しレベル \(entry.level)、\(entry.title)")
            .accessibilityAddTraits(highlightedID == entry.id ? .isSelected : [])
        }
        .listStyle(.sidebar)
        .navigationTitle("アウトライン")
        .overlay {
            if entries.isEmpty {
                ContentUnavailableView("見出しがありません", systemImage: "list.bullet.indent")
            }
        }
    }

    private var currentSectionID: Int? {
        guard currentAnalysisSnapshot != nil else { return nil }
        return MarkdownOutline.currentSection(at: editorModel.selectedRange.location,
                                              in: outlineEntries)?.id
    }

    private func navigate(to entry: MarkdownOutlineEntry) {
        guard let snapshot = currentAnalysisSnapshot,
              snapshot.outlineEntries.contains(entry) else { return }
        navigate(to: entry.sourceRange.location, previewBlockID: entry.id)
    }

    private func goToLine(_ requestedLine: Int) {
        let destination = MarkdownLineIndex(document.text).destination(for: requestedLine)
        if mode.wrappedValue == .preview { mode.wrappedValue = .editor }
        navigate(to: destination.utf16Location)
    }

    private func navigateToHeading(_ fragment: String) {
        guard let snapshot = currentAnalysisSnapshot else { return }
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

    private func receiveCompletedAnalysis() {
        guard currentAnalysisSnapshot != nil else { return }
        statusStore.update(snapshot: currentAnalysisSnapshot, selections: editorModel.selectedRanges)
        receivePendingDocumentLink()
        receivePendingWorkspaceTask()
        if let previewSearchRange { scrollPreview(to: previewSearchRange.location) }
    }

    private func receivePendingDocumentLink() {
        guard let fileURL, currentAnalysisSnapshot != nil,
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

    private func receivePendingWorkspaceTask() {
        guard currentAnalysisSnapshot != nil,
              let fileURL,
              let task = documentLinkNavigation.takeTaskToggle(for: fileURL) else { return }
        applyWorkspaceTask(task)
    }

    private func applyWorkspaceTask(_ task: WorkspaceTaskItem) {
        guard let edit = WorkspaceTaskIndex.toggleEdit(for: task, in: document.text),
              !workspaceStore.isDocumentLocked(fileURL) else {
            workspaceOpenError = String(localized: "タスクの位置または内容が変わりました。一覧を更新してください。")
            return
        }
        if editorModel.hasActiveEditor {
            guard editorModel.applyRegexEdit(edit, expectedSource: document.text) else {
                workspaceOpenError = String(localized: "タスクを変更できませんでした。")
                return
            }
            editorModel.selectAndReveal(NSRange(location: task.sourceLocation, length: 0))
        } else {
            previewTaskUndoTarget.replaceText(edit.applying(to: document.text),
                in: $document.text, undoManager: undoManager,
                actionName: String(localized: "タスクを完了"))
        }
    }

    private func checkLinks() {
        let source = document.text
        externalLinkTask?.cancel()
        externalLinkChecks = []
        isCheckingExternalLinks = false
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

    private func checkExternalLinks() {
        let source = document.text
        let cachedAnalysis = analysisStore.snapshot?.source == source
            ? analysisStore.snapshot?.analysis : nil
        let analysis = cachedAnalysis ?? MarkdownAnalysis(source)
        let targets = MarkdownExternalLinkChecker.targets(in: source, analysis: analysis)
        externalLinkTask?.cancel()
        externalLinkChecks = []
        isCheckingExternalLinks = true
        externalLinkTask = Task {
            let results = await MarkdownExternalLinkChecker.inspect(targets)
            guard !Task.isCancelled, document.text == source else { return }
            externalLinkChecks = results
            isCheckingExternalLinks = false
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

    private func checkTerminology() {
        terminologyTask?.cancel()
        let source = document.text
        let entries = settingsStore.app.terminologyEntries ?? []
        let options = settingsStore.app.terminologyOptions ?? TerminologyOptions()
        let cachedAnalysis = analysisStore.snapshot?.source == source
            ? analysisStore.snapshot?.analysis : nil
        isCheckingTerminology = true
        let worker = Task.detached(priority: .userInitiated) {
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return [TerminologyIssue]() }
            return TerminologyDictionary.inspect(source, entries: entries, options: options,
                analysis: cachedAnalysis)
        }
        terminologyTask = worker
        Task {
            let issues = await worker.value
            guard !worker.isCancelled, showingTerminology, document.text == source,
                  (settingsStore.app.terminologyEntries ?? []) == entries,
                  (settingsStore.app.terminologyOptions ?? TerminologyOptions()) == options else { return }
            terminologyIssues = issues
            terminologySource = source
            isCheckingTerminology = false
            terminologyTask = nil
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

    private func startDocumentOperation(_ action: @escaping @MainActor () async throws -> Void,
                                        onError: @escaping @MainActor (String) -> Void) {
        guard !documentOperationRunning else { return }
        documentOperationRunning = true
        documentOperation = Task { @MainActor in
            defer { documentOperationRunning = false; documentOperation = nil }
            do { try await action() }
            catch is CancellationError { }
            catch { onError(error.localizedDescription) }
        }
    }

    private func beginSavePanel(_ panel: NSSavePanel, completion: @escaping (NSApplication.ModalResponse) -> Void) {
        if let window = NSApp.keyWindow { panel.beginSheetModal(for: window, completionHandler: completion) }
        else { panel.begin(completionHandler: completion) }
    }

    private func saveHTML(preset: MarkdownExportPreset) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.html]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = (fileURL?.deletingPathExtension().lastPathComponent ?? "document") + ".html"
        beginSavePanel(panel) { response in
            guard response == .OK, let destination = panel.url else { return }
            let source = document.text, url = fileURL, dialect = documentContext.markdownDialect
            startDocumentOperation {
                let html = try await MarkdownHTMLExporter.renderAsync(source, documentURL: url, preset: preset, dialect: dialect)
                try await DocumentWork.perform { try Data(html.utf8).write(to: destination, options: .atomic) }
            } onError: { htmlExportError = $0 }
        }
    }

    private func exportPDF() {
        guard !documentOperationRunning else { return }
        exportFormat = .pdf
    }

    private func showSlidePresentation() {
        let deck = MarkdownSlideDeck(document.text, dialect: documentContext.markdownDialect)
        slideWindow.show(deck: deck, context: documentContext) {
            saveSlidePDF(deck)
        }
    }

    private func monitorCloudDocument(_ url: URL?) {
        cloudMonitor?.stop()
        cloudMonitor = url.map { url in
            WorkspaceDirectoryMonitor(root: url.deletingLastPathComponent()) { refreshCloudStatus() }
        }
    }

    private func schedulePositionSave() {
        positionSaveTask?.cancel()
        positionSaveTask = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
            savePosition(for: fileURL)
        }
    }

    private func refreshCloudStatus() {
        let next = fileURL.flatMap { try? CloudFileStatus.read(at: $0) }
        if cloudStatus != next { cloudStatus = next }
    }

    private func applyCollaborativeText(_ sharedText: String) {
        guard collaboration.isActive else { pendingCollaborativeText = nil; return }
        guard document.text != sharedText else { pendingCollaborativeText = nil; return }
        if editorModel.hasActiveEditor {
            guard editorModel.applyCollaborativeText(sharedText,
                expectedSource: document.text) else {
                pendingCollaborativeText = sharedText
                return
            }
        } else {
            document.text = sharedText
        }
        pendingCollaborativeText = nil
    }

    private func saveSlidePDF(_ deck: MarkdownSlideDeck) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = (fileURL?.deletingPathExtension().lastPathComponent ?? "slides") + "-slides.pdf"
        beginSavePanel(panel) { response in
            guard response == .OK, let destination = panel.url else { return }
            let url = fileURL, dialect = documentContext.markdownDialect
            startDocumentOperation {
                try await MarkdownSlidePDFExporter.exportAsync(deck, documentURL: url, to: destination, dialect: dialect)
            } onError: { pdfExportError = $0 }
        }
    }

    private func savePDF(preset: MarkdownExportPreset) {
        guard !documentOperationRunning else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = (fileURL?.deletingPathExtension().lastPathComponent ?? "document") + ".pdf"
        beginSavePanel(panel) { response in
            guard response == .OK, let destination = panel.url else { return }
            let source = document.text, url = fileURL, dialect = documentContext.markdownDialect
            startDocumentOperation {
                try await MarkdownPDFExporter.exportAsync(source, documentURL: url, to: destination, preset: preset, dialect: dialect)
            } onError: { pdfExportError = $0 }
        }
    }

    private func pageSetup() {
        _ = NSPageLayout().runModal(with: printInfo)
    }

    private func printDocument() {
        let source = document.text, url = fileURL, dialect = documentContext.markdownDialect
        let info = printInfo.copy() as! NSPrintInfo
        let title = url?.deletingPathExtension().lastPathComponent ?? String(localized: "無題")
        startDocumentOperation {
            try printSettings.apply(to: info)
            let view = try await MarkdownPDFExporter.printableViewAsync(source, documentURL: url,
                printInfo: info, title: title, header: printSettings.header, footer: printSettings.footer, dialect: dialect)
            try Task.checkCancellation()
            let operation = NSPrintOperation(view: view, printInfo: info)
            operation.jobTitle = title
            operation.showsPrintPanel = true
            _ = await MarkdownPDFExporter.run(operation)
        } onError: { printError = $0 }
    }

    private func copyRichSelection() {
        guard let textView = editorModel.textView else { return }
        let source = textView.editorSource as NSString
        let selection = textView.selectedRange()
        guard selection.length > 0, NSMaxRange(selection) <= source.length else { return }
        let selected = source.substring(with: selection), url = fileURL, dialect = documentContext.markdownDialect
        startDocumentOperation {
            try await MarkdownRichClipboard.copyAsync(selected, documentURL: url, to: .general, dialect: dialect)
        } onError: { richCopyError = $0 }
    }

    private func exportPlainText() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = (fileURL?.deletingPathExtension().lastPathComponent ?? "document") + ".txt"
        beginSavePanel(panel) { response in
            guard response == .OK, let destination = panel.url else { return }
            let source = document.text, options = plainOptions
            startDocumentOperation {
                try await DocumentWork.perform {
                    let text = MarkdownPlainTextExporter.render(source, options: options)
                    try Task.checkCancellation()
                    try Data(text.utf8).write(to: destination, options: .atomic)
                }
            } onError: { plainExportError = $0 }
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
        guard let snapshot = currentAnalysisSnapshot else { return }
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
              let snapshot = currentAnalysisSnapshot,
              let block = PreviewScrollSync.block(containingOrBefore: sourceLocation,
                                                  in: snapshot.analysis),
              block.id != synchronizedBlockID else { return }
        synchronizedBlockID = block.id
        navigationSequence += 1
        previewNavigationTarget = PreviewNavigationTarget(blockID: block.id, sequence: navigationSequence)
    }

    private func synchronizeEditor(to blockID: Int) {
        guard mode.wrappedValue == .split, blockID != synchronizedBlockID,
              let snapshot = currentAnalysisSnapshot,
              let block = snapshot.analysis.blocks.first(where: { $0.id == blockID }) else { return }
        synchronizedBlockID = blockID
        editorModel.scrollToTop(sourceLocation: block.sourceRange.location)
    }

    private func revealSource(_ range: NSRange) {
        guard currentAnalysisSnapshot != nil else { return }
        let destination = NavigationPoint(documentURL: fileURL, utf16Location: range.location)
        navigationHistory.recordJump(from: currentNavigationPoint, to: destination)
        if mode.wrappedValue == .preview { mode.wrappedValue = .editor }
        editorModel.selectAndReveal(range)
    }

    private var sourceEditor: some View {
        HStack(spacing: 0) {
            MarkdownTextEditor(text: $document.text, model: editorModel,
                               textStyle: settingsStore.textStyle(for: fileURL),
                               layoutOptions: settingsStore.layoutOptions(for: fileURL),
                               sharedSnapshot: analysisStore.snapshot, usesSharedAnalysis: true,
                               imageImportMode: settingsStore.imageImportMode(for: fileURL),
                               tableAddsRowOnTab: settingsStore.app.tableAddsRowOnTab ?? true,
                               proofing: settingsStore.app.proofing ?? EditorProofingSettings(),
                               snippets: settingsStore.app.effectiveSnippets,
                               whitespaceOptions: EditorWhitespaceOptions(
                                   showsCharacters: settingsStore.app.showsInvisibleCharacters ?? false,
                                   showsIndentGuides: settingsStore.app.showsIndentGuides ?? false),
                               isEditable: !workspaceStore.isDocumentLocked(fileURL),
                               onImageDrop: dropImage, onImagePaste: pasteImage,
                               onVisibleSourceChange: synchronizePreview(to:),
                               documentContext: documentContext,
                               loadsExternalLinkPreviews: settingsStore.app.loadsExternalLinkPreviews ?? false,
                               usesInlineLivePresentation: settingsStore.app.usesInlineLivePresentation ?? false,
                               usesTypewriterMode: settingsStore.app.usesTypewriterMode ?? false)
            if settingsStore.app.showsMinimap ?? false {
                Divider()
                MarkdownMinimapView(source: document.text, viewport: editorModel.viewport) { location in
                    editorModel.selectAndReveal(NSRange(location: location, length: 0))
                }
            }
        }
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
        let amount = readingEstimate.language == .japanese
            ? statistics.nonWhitespaceCharacters : (analysisStore.snapshot?.wordCounts[.english] ?? 0)
        let rate = max(1, spoken ? readingEstimate.speakingRate : readingEstimate.readingRate)
        guard amount > 0 else {
            return "—"
        }
        let minutes = (amount + rate - 1) / rate
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
    let externalChecks: [MarkdownExternalLinkCheck]
    let isCheckingExternal: Bool
    let source: String
    let onCheckExternal: () -> Void
    let onSelect: (NSRange) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("リンク診断").font(.headline)
                Spacer()
                Button("外部URLを確認") { onCheckExternal() }
                    .disabled(isCheckingExternal)
                Button("閉じる") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            if isChecking || isCheckingExternal {
                ProgressView("リンクを確認中")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if diagnostics.isEmpty && externalChecks.isEmpty {
                ContentUnavailableView("リンクの問題は見つかりません", systemImage: "checkmark.circle")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                let lines = MarkdownLineIndex(source)
                List {
                    if !diagnostics.isEmpty {
                        Section("ローカルリンク") {
                            ForEach(diagnostics) { diagnostic in
                                Button {
                                    onSelect(diagnostic.sourceRange)
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
                    if !externalChecks.isEmpty {
                        Section("外部URL") {
                            ForEach(externalChecks) { check in
                                Button {
                                    onSelect(check.target.sourceRange)
                                } label: {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(check.status.title).fontWeight(.medium)
                                        Text("\(lines.line(containingUTF16Offset: check.target.sourceRange.location)) 行: \(check.target.url.absoluteString)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        if let code = check.httpStatus {
                                            Text("HTTP \(code)")
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
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

private struct TerminologySheet: View {
    let issues: [TerminologyIssue]
    let isChecking: Bool
    let source: String
    let canReplace: Bool
    let hasEntries: Bool
    let onSelect: (TerminologyIssue) -> Void
    let onReplace: (TerminologyIssue) -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var replaceFailed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("用語の表記を確認").font(.headline)
                Spacer()
                Button("閉じる") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            if isChecking {
                ProgressView("用語を確認中")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if issues.isEmpty {
                ContentUnavailableView(hasEntries ? "表記の問題は見つかりません" : "用語辞書に項目がありません",
                                       systemImage: hasEntries ? "checkmark.circle" : "text.book.closed")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                let lines = MarkdownLineIndex(source)
                List(issues) { issue in
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("\(issue.prohibited) → \(issue.preferred)")
                                .fontWeight(.medium)
                            Text("\(lines.line(containingUTF16Offset: issue.range.location)) 行")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("移動") { onSelect(issue) }
                        Button("置換") {
                            if !onReplace(issue) { replaceFailed = true }
                        }
                        .disabled(!canReplace)
                        .help(canReplace ? "推奨表記に置き換える" : "編集表示で置換できます")
                    }
                }
            }
        }
        .frame(minWidth: 560, minHeight: 350)
        .padding(20)
        .alert("置換できませんでした", isPresented: $replaceFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("本文が変更されたか編集中のため、置換できませんでした。")
        }
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
