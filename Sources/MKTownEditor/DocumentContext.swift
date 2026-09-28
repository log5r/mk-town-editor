import Foundation

/// Location-dependent services for one document. The document contents remain in FileDocument.
struct DocumentContext: Equatable, Sendable {
    let fileURL: URL?

    var directoryURL: URL? {
        guard let fileURL, fileURL.isFileURL else { return nil }
        return fileURL.deletingLastPathComponent().standardizedFileURL
    }

    func resolveLocalResource(_ relativePath: String) -> URL? {
        guard let directoryURL, !relativePath.isEmpty else { return nil }
        let path = relativePath.removingPercentEncoding ?? relativePath
        guard !path.hasPrefix("/"), URL(string: path)?.scheme == nil else { return nil }
        return URL(fileURLWithPath: path, relativeTo: directoryURL).standardizedFileURL
    }
}
