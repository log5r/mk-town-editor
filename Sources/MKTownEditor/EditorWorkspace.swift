import SwiftUI

struct EditorWorkspace: View {
    @Binding var document: MarkdownDocument
    let fileURL: URL?
    @EnvironmentObject private var settingsStore: EditorSettingsStore
    @Environment(\.undoManager) private var undoManager
    @StateObject private var editorModel = MarkdownEditorModel()
    @State private var previewTaskUndoTarget = PreviewTaskUndoTarget()
    @SceneStorage("editorMode") private var legacyMode: String?
    @State private var unsavedMode: EditorMode = .split

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
        DocumentStatistics(text: document.text)
    }

    private var documentContext: DocumentContext {
        DocumentContext(fileURL: fileURL)
    }

    var body: some View {
        VStack(spacing: 0) {
            editorContent
            Divider()
            statusBar
        }
        .frame(minWidth: 720, minHeight: 480)
        .toolbar {
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
        .onAppear {
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
                                onToggleTask: toggleTask)
                    .frame(minWidth: 280)
            }
        case .preview:
            MarkdownPreview(markdown: document.text, documentContext: documentContext,
                            onToggleTask: toggleTask)
        }
    }

    private var sourceEditor: some View {
        MarkdownTextEditor(text: $document.text, model: editorModel)
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
