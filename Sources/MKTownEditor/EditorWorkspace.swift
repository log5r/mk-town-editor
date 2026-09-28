import SwiftUI

struct EditorWorkspace: View {
    @Binding var document: MarkdownDocument
    let fileURL: URL?
    @EnvironmentObject private var settingsStore: EditorSettingsStore
    @EnvironmentObject private var documentLinkNavigation: DocumentLinkNavigation
    @Environment(\.undoManager) private var undoManager
    @Environment(\.openDocument) private var openDocument
    @StateObject private var editorModel = MarkdownEditorModel()
    @StateObject private var analysisStore = DocumentAnalysisStore()
    @State private var previewTaskUndoTarget = PreviewTaskUndoTarget()
    @SceneStorage("editorMode") private var legacyMode: String?
    @State private var unsavedMode: EditorMode = .split
    @State private var imageDropError: String?
    @State private var pasteNeedsSave = false
    @State private var sidebarVisibility: NavigationSplitViewVisibility = .detailOnly
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
    @State private var synchronizedBlockID: Int?
    @State private var showingRegexSearch = false

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
        analysisStore.snapshot?.statistics ?? DocumentStatistics(text: document.text)
    }

    private var documentContext: DocumentContext {
        DocumentContext(fileURL: fileURL)
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $sidebarVisibility) {
            outlineSidebar
                .navigationSplitViewColumnWidth(min: 190, ideal: 230, max: 320)
        } detail: {
            VStack(spacing: 0) {
                editorContent
                Divider()
                statusBar
            }
            .frame(minWidth: 720, minHeight: 480)
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button("アウトライン", systemImage: "sidebar.left") {
                    sidebarVisibility = sidebarVisibility == .detailOnly ? .all : .detailOnly
                }
                .help("アウトラインを表示または隠す")
            }
            ToolbarItemGroup(placement: .primaryAction) {
                ForEach(EditorCommand.toolbar, id: \.self) { command in
                    formatButton(command)
                }
            }

            ToolbarItem(placement: .primaryAction) {
                Button("リンク診断", systemImage: "link") {
                    showingLinkDiagnostics = true
                    checkLinks()
                }
                .help("ローカルリンクの参照先を確認")
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
        .sheet(isPresented: $showingGoToLine) {
            let index = MarkdownLineIndex(document.text)
            GoToLineSheet(lineCount: index.lineCount,
                          initialLine: index.line(containingUTF16Offset: editorModel.selectedRange.location)) { line in
                goToLine(line)
            }
        }
        .sheet(isPresented: $showingGoToHeading) {
            GoToHeadingSheet(entries: analysisStore.snapshot?.source == document.text ? outlineEntries : []) {
                navigate(to: $0)
            }
        }
        .sheet(isPresented: $showingRegexSearch) {
            RegexSearchSheet(source: document.text, selectedRange: editorModel.selectedRange,
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
        .sheet(item: $editorModel.linkDraft) { draft in
            LinkEditorSheet(draft: draft, documentContext: documentContext,
                            analysis: analysisStore.snapshot?.source == document.text
                                ? analysisStore.snapshot?.analysis : nil,
                            onSave: { label, destination, title in
                                editorModel.commitLink(label: label, destination: destination, title: title)
                            }, onSaveReference: { label, referenceID in
                                editorModel.commitReferenceLink(label: label, referenceID: referenceID)
                            })
        }
        .sheet(item: $editorModel.imageDraft) { draft in
            ImageEditorSheet(draft: draft, documentContext: documentContext) { alt, input, title in
                try await insertImage(alt: alt, input: input, title: title)
            }
        }
        .sheet(item: $editorModel.tableDraft) { _ in
            TableInsertionSheet { rows, columns in
                editorModel.commitTable(rows: rows, columns: columns)
            }
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
                 ? "画像を貼り付けるには保存先が必要です。書類を保存した後、もう一度貼り付けてください。"
                 : imageDropError ?? "")
        }
        .onAppear {
            analysisStore.update(source: document.text)
            receivePendingDocumentLink()
            if let fileURL {
                settingsStore.migrateLegacyMode(legacyMode, for: fileURL)
            } else {
                unsavedMode = legacyMode.flatMap(EditorMode.init(rawValue:)) ?? settingsStore.app.defaultMode
            }
            legacyMode = nil
        }
        .onChange(of: fileURL) { oldURL, newURL in
            navigationHistory.moveDocument(from: oldURL, to: newURL)
            synchronizedBlockID = nil
            if showingLinkDiagnostics { checkLinks() }
            switch (oldURL, newURL) {
            case let (oldURL?, newURL?):
                settingsStore.moveDocumentState(from: oldURL, to: newURL)
            case let (nil, newURL?):
                if !settingsStore.hasDocumentState(for: newURL) {
                    settingsStore.setMode(unsavedMode, for: newURL)
                }
            case let (oldURL?, nil):
                unsavedMode = settingsStore.mode(for: oldURL)
            case (nil, nil):
                break
            }
        }
        .onChange(of: document.text) { _, newText in
            analysisStore.update(source: newText)
            synchronizedBlockID = nil
            if showingLinkDiagnostics { checkLinks() }
        }
        .onChange(of: analysisStore.snapshot?.source) { _, _ in
            receivePendingDocumentLink()
        }
        .onChange(of: documentLinkNavigation.pending) { _, _ in
            receivePendingDocumentLink()
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
            HSplitView {
                sourceEditor
                    .frame(minWidth: 280)
                MarkdownPreview(markdown: document.text, documentContext: documentContext,
                                onToggleTask: previewTaskAction,
                                snapshot: analysisStore.snapshot, usesSharedAnalysis: true,
                                navigationTarget: previewNavigationTarget,
                                onOpenHeading: navigateToHeading,
                                onOpenDocument: openLinkedDocument,
                                onVisibleBlockChange: synchronizeEditor(to:),
                                onRevealSource: revealSource,
                                zoom: settingsStore.zoom(for: .preview))
                    .frame(minWidth: 280)
            }
        case .preview:
            MarkdownPreview(markdown: document.text, documentContext: documentContext,
                            onToggleTask: previewTaskAction,
                            snapshot: analysisStore.snapshot, usesSharedAnalysis: true,
                            navigationTarget: previewNavigationTarget,
                            onOpenHeading: navigateToHeading,
                            onOpenDocument: openLinkedDocument,
                            onRevealSource: revealSource,
                            zoom: settingsStore.zoom(for: .preview))
        }
    }

    private var previewTaskAction: ((Int) -> Void)? {
        guard analysisStore.snapshot?.source == document.text else { return nil }
        return { toggleTask(at: $0) }
    }

    private var outlineEntries: [MarkdownOutlineEntry] {
        analysisStore.snapshot.map { MarkdownOutline.entries(in: $0.analysis) } ?? []
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
                           layoutOptions: settingsStore.layoutOptions(),
                           sharedSnapshot: analysisStore.snapshot, usesSharedAnalysis: true,
                           imageImportMode: settingsStore.imageImportMode(for: fileURL),
                           onImageDrop: dropImage, onImagePaste: pasteImage,
                           onVisibleSourceChange: synchronizePreview(to:))
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

    private func insertImage(alt: String, input: ImageInput, title: String) async throws {
        let context = documentContext
        try await ImageInsertionService.insert(alt: alt, input: input, title: title,
                                               context: context, model: editorModel,
                                               currentContext: { documentContext })
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

@MainActor
final class PreviewTaskUndoTarget {
    func replaceText(_ newText: String, in text: Binding<String>, undoManager: UndoManager?) {
        let previous = text.wrappedValue
        guard previous != newText else { return }
        text.wrappedValue = newText
        if let undoManager {
            undoManager.registerUndo(withTarget: self) { [weak undoManager] target in
                target.replaceText(previous, in: text, undoManager: undoManager)
            }
            undoManager.setActionName("タスクの完了切替")
        }
    }
}

private struct LinkEditorSheet: View {
    let draft: MarkdownLinkDraft
    let documentContext: DocumentContext
    let analysis: MarkdownAnalysis?
    let onSave: (String, String, String) -> Bool
    let onSaveReference: (String, String) -> Bool
    @Environment(\.dismiss) private var dismiss
    private enum LinkForm: String, CaseIterable { case inline = "URL", reference = "参照ID" }
    @State private var form: LinkForm = .inline
    @State private var label: String
    @State private var destination: String
    @State private var title: String
    @State private var referenceID = ""
    @State private var showsSaveError = false
    @State private var fileCandidates: [FilePathSuggestion] = []
    @State private var headingSuggestions: [HeadingLinkSuggestion] = []

    init(draft: MarkdownLinkDraft, documentContext: DocumentContext, analysis: MarkdownAnalysis?,
         onSave: @escaping (String, String, String) -> Bool,
         onSaveReference: @escaping (String, String) -> Bool) {
        self.draft = draft
        self.documentContext = documentContext
        self.analysis = analysis
        self.onSave = onSave
        self.onSaveReference = onSaveReference
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
                        Text(value.rawValue).tag(value)
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
}
