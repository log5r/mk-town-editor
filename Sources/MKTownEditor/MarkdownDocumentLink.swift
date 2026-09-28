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
    static let shared = DocumentLinkNavigation()

    struct Pending: Equatable {
        let fileURL: URL
        let fragment: String
    }

    struct PendingPosition: Equatable {
        let fileURL: URL
        let range: NSRange
    }

    @Published private(set) var pending: Pending?
    @Published private(set) var pendingPosition: PendingPosition?
    @Published private(set) var pendingLines: [URL: Int] = [:]

    func requestLine(in fileURL: URL, line: Int) {
        guard line > 0 else { return }
        pendingLines[fileURL.resolvingSymlinksInPath().standardizedFileURL] = line
    }

    func takeLine(for fileURL: URL) -> Int? {
        pendingLines.removeValue(forKey: fileURL.resolvingSymlinksInPath().standardizedFileURL)
    }

    func cancelLine(for fileURL: URL) {
        pendingLines.removeValue(forKey: fileURL.resolvingSymlinksInPath().standardizedFileURL)
    }

    func requestPosition(in fileURL: URL, range: NSRange) {
        pendingPosition = PendingPosition(fileURL: fileURL.resolvingSymlinksInPath().standardizedFileURL,
                                          range: range)
    }

    func takePosition(for fileURL: URL) -> NSRange? {
        guard pendingPosition?.fileURL == fileURL.resolvingSymlinksInPath().standardizedFileURL else {
            return nil
        }
        let range = pendingPosition?.range
        pendingPosition = nil
        return range
    }

    func cancelPosition(for fileURL: URL) {
        if pendingPosition?.fileURL == fileURL.resolvingSymlinksInPath().standardizedFileURL {
            pendingPosition = nil
        }
    }

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
