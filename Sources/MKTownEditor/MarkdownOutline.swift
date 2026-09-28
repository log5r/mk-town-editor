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

enum MarkdownSelectionExpansion {
    static func next(in text: String, selection: NSRange) -> NSRange? {
        let length = (text as NSString).length
        guard selection.location >= 0, NSMaxRange(selection) <= length else { return nil }
        let analysis = MarkdownAnalysis(text)
        let codeBlocks = analysis.blocks.filter { $0.kind == .codeBlock }.map(\.sourceRange)
        let codeSpans = MarkdownInlineSyntax.codeSpanRanges(in: text)
        var candidates = MarkdownLinkSyntax.inlineLinks(in: text).map(\.range).filter { link in
            !codeBlocks.contains { NSIntersectionRange($0, link).length > 0 } &&
                !codeSpans.contains { NSIntersectionRange($0, link).length > 0 }
        }
        for block in analysis.blocks {
            switch block.kind {
            case .paragraph, .codeBlock:
                candidates.append(block.sourceRange)
            case .unorderedList, .orderedList:
                var ids = Set([block.id])
                var end = NSMaxRange(block.sourceRange)
                for child in analysis.blocks where child.sourceRange.location >= block.sourceRange.location {
                    if let parent = child.parentID, ids.contains(parent) {
                        ids.insert(child.id)
                        end = max(end, NSMaxRange(child.sourceRange))
                    }
                }
                candidates.append(NSRange(location: block.sourceRange.location,
                    length: end - block.sourceRange.location))
            default: break
            }
        }
        if let section = DocumentStatistics.sectionRange(at: selection.location,
            in: analysis, documentLength: length) {
            candidates.append(section)
        }
        candidates.append(NSRange(location: 0, length: length))
        return candidates.filter { candidate in
            candidate != selection && candidate.length > selection.length &&
                candidate.location <= selection.location &&
                NSMaxRange(candidate) >= NSMaxRange(selection)
        }.min { $0.length < $1.length }
    }
}
