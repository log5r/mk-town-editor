import Foundation

struct HeadingLinkSuggestion: Equatable, Identifiable, Sendable {
    let title: String
    let destination: String

    var id: String { destination }
}

enum MarkdownLinkCompletion {
    static func headings(for destination: String, current: MarkdownAnalysis,
                         context: DocumentContext) -> [HeadingLinkSuggestion] {
        guard let hash = destination.firstIndex(of: "#") else { return [] }
        let path = String(destination[..<hash])
        let query = String(destination[destination.index(after: hash)...])
        let analysis: MarkdownAnalysis
        if path.isEmpty {
            analysis = current
        } else {
            guard let url = context.resolveLocalResource(path),
                  ["md", "markdown"].contains(url.pathExtension.lowercased()),
                  let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  size <= 8_000_000,
                  let data = try? Data(contentsOf: url),
                  let text = try? MarkdownDocument.decode(data) else { return [] }
            analysis = MarkdownAnalysis(text)
        }
        return MarkdownHeadingIndex(analysis: analysis).anchors.compactMap { anchor in
            guard query.isEmpty || anchor.slug.localizedStandardContains(query) ||
                    anchor.entry.title.localizedStandardContains(query) else { return nil }
            return HeadingLinkSuggestion(title: anchor.entry.title,
                                         destination: path + "#" + anchor.slug)
        }
    }

    static func referenceIDs(in analysis: MarkdownAnalysis) -> [String] {
        analysis.references.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}
