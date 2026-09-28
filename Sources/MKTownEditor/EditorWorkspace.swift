import SwiftUI

struct EditorWorkspace: View {
    @Binding var document: MarkdownDocument
    let fileURL: URL?
    @EnvironmentObject private var settingsStore: EditorSettingsStore
    @Environment(\.undoManager) private var undoManager
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
        .sheet(isPresented: $showingGoToLine) {
            let index = MarkdownLineIndex(document.text)
            GoToLineSheet(lineCount: index.lineCount,
                          initialLine: index.line(containingUTF16Offset: editorModel.selectedRange.location)) { line in
                goToLine(line)
            }
        }
        .sheet(item: $editorModel.linkDraft) { draft in
            LinkEditorSheet(draft: draft) { label, destination, title in
                editorModel.commitLink(label: label, destination: destination, title: title)
            }
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
            if let fileURL {
                settingsStore.migrateLegacyMode(legacyMode, for: fileURL)
            } else {
                unsavedMode = legacyMode.flatMap(EditorMode.init(rawValue:)) ?? settingsStore.app.defaultMode
            }
            legacyMode = nil
        }
        .onChange(of: fileURL) { oldURL, newURL in
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
                                navigationTarget: previewNavigationTarget)
                    .frame(minWidth: 280)
            }
        case .preview:
            MarkdownPreview(markdown: document.text, documentContext: documentContext,
                            onToggleTask: previewTaskAction,
                            snapshot: analysisStore.snapshot, usesSharedAnalysis: true,
                            navigationTarget: previewNavigationTarget)
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
        editorModel.navigate(to: entry.sourceRange.location)
        navigationSequence += 1
        previewNavigationTarget = PreviewNavigationTarget(blockID: entry.id, sequence: navigationSequence)
    }

    private func goToLine(_ requestedLine: Int) {
        let destination = MarkdownLineIndex(document.text).destination(for: requestedLine)
        if mode.wrappedValue == .preview { mode.wrappedValue = .editor }
        editorModel.navigate(to: destination.utf16Location)
    }

    private var sourceEditor: some View {
        MarkdownTextEditor(text: $document.text, model: editorModel,
                           textStyle: settingsStore.textStyle(for: fileURL),
                           layoutOptions: settingsStore.layoutOptions(),
                           sharedSnapshot: analysisStore.snapshot, usesSharedAnalysis: true,
                           imageImportMode: settingsStore.imageImportMode(for: fileURL),
                           onImageDrop: dropImage, onImagePaste: pasteImage)
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
    let onSave: (String, String, String) -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var label: String
    @State private var destination: String
    @State private var title: String
    @State private var showsSaveError = false

    init(draft: MarkdownLinkDraft, onSave: @escaping (String, String, String) -> Bool) {
        self.draft = draft
        self.onSave = onSave
        _label = State(initialValue: draft.label)
        _destination = State(initialValue: draft.destination)
        _title = State(initialValue: draft.title)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(draft.isExisting ? "リンクを編集" : "リンクを挿入")
                .font(.headline)
            Form {
                TextField("表示名", text: $label)
                TextField("URL", text: $destination)
                TextField("タイトル（任意）", text: $title)
            }
            .formStyle(.grouped)
            .frame(height: 180)
            if showsSaveError {
                Text("リンクを保存できません。本文と編集状態を確認してください。")
                    .foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("キャンセル") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(draft.isExisting ? "更新" : "挿入") {
                    if onSave(label, destination, title) {
                        dismiss()
                    } else {
                        showsSaveError = true
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                          destination.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .frame(width: 480)
        .padding(20)
    }
}
