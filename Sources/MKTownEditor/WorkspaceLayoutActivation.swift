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

    func activate(_ layout: WorkspaceNamedLayout, documents: [URL]) {
        event = Event(layout: layout,
            documentURLs: Set(documents.map {
                $0.resolvingSymlinksInPath().standardizedFileURL
            }))
    }

    func layout(for documentURL: URL) -> WorkspaceNamedLayout? {
        guard let event,
              event.documentURLs.contains(
                  documentURL.resolvingSymlinksInPath().standardizedFileURL) else { return nil }
        return event.layout
    }
}
