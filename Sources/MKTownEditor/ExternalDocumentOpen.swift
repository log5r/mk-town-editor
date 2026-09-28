import AppKit
import Foundation

/// A URL delivered through Launch Services; file contents remain owned by DocumentGroup.
struct ExternalDocumentOpenRequest: Equatable {
    let fileURL: URL
    let line: Int?

    init?(url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "mktowneditor",
              components.host?.lowercased() == "open",
              components.path.isEmpty || components.path == "/",
              components.fragment == nil,
              let items = components.queryItems,
              items.allSatisfy({ $0.name == "url" || $0.name == "line" }),
              items.filter({ $0.name == "url" }).count == 1,
              items.filter({ $0.name == "line" }).count <= 1,
              let value = items.first(where: { $0.name == "url" })?.value,
              let file = URL(string: value), file.isFileURL, !file.path.isEmpty,
              ["md", "markdown", "mdown", "mkd", "txt"].contains(file.pathExtension.lowercased())
        else { return nil }
        if let lineValue = items.first(where: { $0.name == "line" })?.value {
            guard let line = Int(lineValue), line > 0 else { return nil }
            self.line = line
        } else {
            line = nil
        }
        fileURL = file.resolvingSymlinksInPath().standardizedFileURL
    }

    var url: URL {
        var components = URLComponents()
        components.scheme = "mktowneditor"
        components.host = "open"
        components.queryItems = [URLQueryItem(name: "url", value: fileURL.absoluteString)]
        if let line { components.queryItems?.append(URLQueryItem(name: "line", value: String(line))) }
        return components.url!
    }
}

@MainActor
final class ExternalDocumentOpenAppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            guard let request = ExternalDocumentOpenRequest(url: url) else { continue }
            guard FileManager.default.fileExists(atPath: request.fileURL.path) else {
                application.presentError(CocoaError(.fileNoSuchFile))
                continue
            }
            if let line = request.line {
                DocumentLinkNavigation.shared.requestLine(in: request.fileURL, line: line)
            }
            NSDocumentController.shared.openDocument(withContentsOf: request.fileURL,
                                                     display: true) { _, _, error in
                if let error {
                    DocumentLinkNavigation.shared.cancelLine(for: request.fileURL)
                    application.presentError(error)
                }
            }
        }
    }
}
