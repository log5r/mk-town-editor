import SwiftUI

@main
struct MKTownEditorApp: App {
    @StateObject private var settingsStore = EditorSettingsStore()
    @StateObject private var documentLinkNavigation = DocumentLinkNavigation()

    var body: some Scene {
        DocumentGroup(newDocument: MarkdownDocument()) { file in
            EditorWorkspace(document: file.$document, fileURL: file.fileURL)
                .environmentObject(settingsStore)
                .environmentObject(documentLinkNavigation)
        }
        .commands {
            MarkdownCommands(settingsStore: settingsStore)
        }
        Settings {
            EditorPreferencesView(settingsStore: settingsStore)
        }
    }
}
