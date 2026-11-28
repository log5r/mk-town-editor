import AppKit
import SwiftUI

@main
struct MKTownEditorApp: App {
    @NSApplicationDelegateAdaptor(ExternalDocumentOpenAppDelegate.self) private var appDelegate
    @StateObject private var settingsStore = EditorSettingsStore()
    @StateObject private var documentLinkNavigation = DocumentLinkNavigation.shared
    @StateObject private var workspaceStore = WorkspaceStore()
    @StateObject private var layoutActivation = WorkspaceLayoutActivation()

    var body: some Scene {
        DocumentGroup(newDocument: MarkdownDocument()) { file in
            MarkdownDocumentWindow(document: file.$document, fileURL: file.fileURL)
                .environmentObject(settingsStore)
                .environmentObject(documentLinkNavigation)
                .environmentObject(workspaceStore)
                .environmentObject(layoutActivation)
        }
        .commands {
            MarkdownCommands(settingsStore: settingsStore, workspaceStore: workspaceStore)
            ReadOnlyOpenCommands()
            ToolbarCommands()
        }
        Settings {
            EditorPreferencesView(settingsStore: settingsStore)
        }
    }
}

struct MarkdownDocumentWindow: View {
    @Binding var document: MarkdownDocument
    let fileURL: URL?
    @EnvironmentObject private var navigation: DocumentLinkNavigation
    @EnvironmentObject private var settingsStore: EditorSettingsStore
    @EnvironmentObject private var workspaceStore: WorkspaceStore
    @State private var isReadOnly = false

    init(document: Binding<MarkdownDocument>, fileURL: URL?) {
        _document = document
        self.fileURL = fileURL
    }

    var body: some View {
        Group {
            if let data = document.pendingEncodingData {
                MarkdownEncodingPicker(sourceData: data, onOpen: { document = $0 })
            } else {
                EditorWorkspace(document: $document, fileURL: fileURL, isReadOnly: readOnlyBinding)
            }
        }
        .onChange(of: fileURL, initial: true) { receiveReadOnlyOpen() }
        .onChange(of: navigation.pendingReadOnlyOpens) { receiveReadOnlyOpen() }
        .onChange(of: workspaceStore.isDocumentLocked(fileURL)) { receiveReadOnlyOpen() }
        .onChange(of: saveWhitespaceOptions, initial: true) { _, options in
            document.saveWhitespaceConfiguration.update(options)
        }
        .onChange(of: ObjectIdentifier(document.saveWhitespaceConfiguration)) {
            document.saveWhitespaceConfiguration.update(saveWhitespaceOptions)
        }
    }

    private var saveWhitespaceOptions: MarkdownSaveWhitespaceConfiguration.Options? {
        guard !readOnlyBinding.wrappedValue, !workspaceStore.isDocumentLocked(fileURL) else { return nil }
        let settings = settingsStore.whitespaceEditingOptions(for: fileURL)
        guard settings.trimsTrailingWhitespaceOnSave else { return nil }
        return .init(includingWhitespaceOnlyLines: settings.trimsWhitespaceOnlyLines,
                     dialect: settingsStore.markdownDialect(for: fileURL))
    }

    private var readOnlyBinding: Binding<Bool> {
        // A queued open can make the document read-only before this window's first layout.
        Binding(get: { isReadOnly || hasPendingReadOnlyOpen }, set: { isReadOnly = $0 })
    }

    private var hasPendingReadOnlyOpen: Bool {
        guard !navigation.pendingReadOnlyOpens.isEmpty, let fileURL,
              !workspaceStore.isDocumentLocked(fileURL) else { return false }
        return navigation.hasPendingReadOnlyOpen(for: fileURL)
    }

    private func receiveReadOnlyOpen() {
        guard let fileURL, hasPendingReadOnlyOpen else { return }
        isReadOnly = true
        navigation.finishReadOnlyOpen(for: fileURL)
    }
}

private struct ReadOnlyOpenCommands: Commands {
    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("読み取り専用で開く…", action: showOpenPanel)
        }
    }

    private func showOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = MarkdownDocument.readableContentTypes
        panel.allowsMultipleSelection = true
        panel.prompt = String(localized: "読み取り専用で開く")
        panel.beginAttached { response in
            guard response == .OK else { return }
            for url in panel.urls {
                ExternalDocumentOpenRequest(fileURL: url, isReadOnly: true).open(in: NSApp)
            }
        }
    }
}
