import Foundation

struct MarkdownOutlineEntry: Identifiable, Equatable, Sendable {
    let id: Int
    let level: Int
    let title: String
    let sourceRange: NSRange
}

enum MarkdownOutline {
    static func entries(in analysis: MarkdownAnalysis) -> [MarkdownOutlineEntry] {
        analysis.blocks.compactMap { block in
            guard case let .heading(level) = block.kind else { return nil }
            let title = block.content.trimmingCharacters(in: .whitespacesAndNewlines)
            return MarkdownOutlineEntry(id: block.id, level: level,
                                        title: title.isEmpty ? "無題の見出し" : title,
                                        sourceRange: block.sourceRange)
        }
    }

    static func currentSection(at sourceLocation: Int,
                               in entries: [MarkdownOutlineEntry]) -> MarkdownOutlineEntry? {
        guard sourceLocation >= 0 else { return nil }
        return entries.last { $0.sourceRange.location <= sourceLocation }
    }

    static func search(_ query: String, in entries: [MarkdownOutlineEntry]) -> [MarkdownOutlineEntry] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return entries }
        return entries.filter { $0.title.localizedStandardContains(term) }
    }
}
