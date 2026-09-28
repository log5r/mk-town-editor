import Foundation

struct MarkdownDocumentLink: Equatable {
    let fileURL: URL
    let fragment: String?

    init?(url: URL, context: DocumentContext) {
        guard url.scheme == nil, url.host == nil, !url.path.isEmpty,
              let fileURL = context.resolveLocalResource(url.path),
              ["md", "markdown"].contains(fileURL.pathExtension.lowercased()) else { return nil }
        self.fileURL = fileURL
        fragment = url.fragment.flatMap { value in
            value.isEmpty ? nil : (value.removingPercentEncoding ?? value)
        }
    }
}

@MainActor
final class DocumentLinkNavigation: ObservableObject {
    struct Pending: Equatable {
        let fileURL: URL
        let fragment: String
    }

    @Published private(set) var pending: Pending?

    func request(_ link: MarkdownDocumentLink) {
        guard let fragment = link.fragment else { return }
        pending = Pending(fileURL: link.fileURL, fragment: fragment)
    }

    func take(for fileURL: URL) -> String? {
        guard pending?.fileURL == fileURL else { return nil }
        let fragment = pending?.fragment
        pending = nil
        return fragment
    }

    func cancel(for fileURL: URL) {
        if pending?.fileURL == fileURL { pending = nil }
    }
}
