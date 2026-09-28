import SwiftUI

@main
struct MKTownEditorApp: App {
    var body: some Scene {
        DocumentGroup(newDocument: MarkdownDocument()) { file in
            EditorWorkspace(document: file.$document, fileURL: file.fileURL)
        }
        .commands {
            MarkdownCommands()
        }
    }
}
