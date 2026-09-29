import Foundation

struct TerminologyEntry: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var prohibited: String
    var preferred: String
}

struct TerminologyOptions: Codable, Equatable, Sendable {
    var excludesCode = true
    var excludesQuotes = true
}

struct TerminologyIssue: Equatable, Identifiable, Sendable {
    let entryID: UUID
    let range: NSRange
    let prohibited: String
    let preferred: String

    var id: String { "\(entryID.uuidString)-\(range.location)" }

    func replacement(in source: String) -> MarkdownEdit? {
        let text = source as NSString
        guard range.location >= 0, NSMaxRange(range) <= text.length,
              text.substring(with: range) == prohibited else { return nil }
        return MarkdownEdit(range: range, replacement: preferred,
            selection: NSRange(location: range.location + (preferred as NSString).length,
                               length: 0))
    }
}

enum TerminologyDictionary {
    static func inspect(_ source: String, entries: [TerminologyEntry],
                        options: TerminologyOptions = TerminologyOptions(),
                        analysis: MarkdownAnalysis? = nil) -> [TerminologyIssue] {
        let text = source as NSString
        let validEntries = entries.filter {
            !$0.prohibited.isEmpty && !$0.preferred.isEmpty && $0.prohibited != $0.preferred
        }
        guard text.length > 0, !validEntries.isEmpty else { return [] }
        let analysis = analysis ?? MarkdownAnalysis(source)
        var excluded = analysis.blocks.filter { block in
            (options.excludesCode && block.kind == .codeBlock) ||
                (options.excludesQuotes && block.kind == .quote)
        }.map(\.sourceRange)
        if options.excludesCode {
            excluded += MarkdownInlineSyntax.codeSpanRanges(in: source)
        }
        excluded += MarkdownLinkSyntax.inlineLinks(in: source).map(\.destinationRange)
        var excludedOffsets = IndexSet()
        for range in excluded where range.length > 0 {
            excludedOffsets.insert(integersIn: range.location..<NSMaxRange(range))
        }
        var coveredOffsets = IndexSet()
        var issues: [TerminologyIssue] = []
        for entry in validEntries {
            if Task.isCancelled { return [] }
            var cursor = 0
            while cursor < text.length {
                if Task.isCancelled { return [] }
                let match = text.range(of: entry.prohibited,
                    range: NSRange(location: cursor, length: text.length - cursor))
                guard match.location != NSNotFound else { break }
                let offsets = match.location..<NSMaxRange(match)
                if !excludedOffsets.intersects(integersIn: offsets) &&
                    !coveredOffsets.intersects(integersIn: offsets) {
                    issues.append(TerminologyIssue(entryID: entry.id, range: match,
                        prohibited: entry.prohibited, preferred: entry.preferred))
                    coveredOffsets.insert(integersIn: offsets)
                }
                cursor = NSMaxRange(match)
            }
        }
        return issues.sorted { $0.range.location < $1.range.location }
    }
}
