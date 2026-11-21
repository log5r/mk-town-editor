import Combine
import Foundation

@MainActor
final class WorkspaceLayoutActivation: ObservableObject {
    struct Event {
        let id = UUID()
        let layout: WorkspaceNamedLayout
        let documentURLs: Set<URL>
    }

    @Published private(set) var event: Event?
    /// Documents of the last activation that have not shown a window yet. Their new windows use
    /// the mode the layout saved instead of starting in the preview.
    private var openingDocuments: Set<URL> = []

    func activate(_ layout: WorkspaceNamedLayout, documents: [URL]) {
        let event = Event(layout: layout,
            documentURLs: Set(documents.map {
                $0.resolvingSymlinksInPath().standardizedFileURL
            }))
        self.event = event
        openingDocuments = event.documentURLs
    }

    func isOpening(_ documentURL: URL) -> Bool {
        openingDocuments.contains(documentURL.resolvingSymlinksInPath().standardizedFileURL)
    }

    /// Called by the document's window when it appears or applies the layout, so a later open
    /// of the same document starts as usual.
    func finishOpening(_ documentURL: URL) {
        openingDocuments.remove(documentURL.resolvingSymlinksInPath().standardizedFileURL)
    }

    func layout(for documentURL: URL) -> WorkspaceNamedLayout? {
        guard let event,
              event.documentURLs.contains(
                  documentURL.resolvingSymlinksInPath().standardizedFileURL) else { return nil }
        return event.layout
    }
}
