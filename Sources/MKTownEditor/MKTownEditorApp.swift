import SwiftUI

@main
struct MKTownEditorApp: App {
    @StateObject private var settingsStore = EditorSettingsStore()

    var body: some Scene {
        DocumentGroup(newDocument: MarkdownDocument()) { file in
            EditorWorkspace(document: file.$document, fileURL: file.fileURL)
                .environmentObject(settingsStore)
        }
        .commands {
            MarkdownCommands(settingsStore: settingsStore)
        }
    }
}
