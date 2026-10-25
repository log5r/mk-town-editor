import SwiftUI

@main
struct MKTownMobileApp: App {
    var body: some Scene {
        DocumentGroup(newDocument: MarkdownDocument()) { file in
            MobileEditorWorkspace(document: file.$document)
        }
    }
}
