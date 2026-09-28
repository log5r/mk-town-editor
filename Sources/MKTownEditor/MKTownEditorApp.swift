import SwiftUI

@main
struct MKTownEditorApp: App {
    @StateObject private var settingsStore = EditorSettingsStore()
    @StateObject private var documentLinkNavigation = DocumentLinkNavigation()
    @StateObject private var workspaceStore = WorkspaceStore()

    var body: some Scene {
        DocumentGroup(newDocument: MarkdownDocument()) { file in
            EditorWorkspace(document: file.$document, fileURL: file.fileURL)
                .environmentObject(settingsStore)
                .environmentObject(documentLinkNavigation)
                .environmentObject(workspaceStore)
        }
        .commands {
            MarkdownCommands(settingsStore: settingsStore, workspaceStore: workspaceStore)
        }
        Settings {
            EditorPreferencesView(settingsStore: settingsStore)
        }
    }
}
