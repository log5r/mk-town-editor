import Foundation

struct DocumentStatistics: Equatable, Sendable {
    let characters: Int
    let nonWhitespaceCharacters: Int
    let words: Int
    let lines: Int

    init(text: String) {
        characters = text.count
        nonWhitespaceCharacters = text.filter { !$0.isWhitespace && !$0.isNewline }.count
        words = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
        lines = text.isEmpty ? 0 : text.components(separatedBy: .newlines).count
    }

    static func selection(in text: String, range: NSRange) -> DocumentStatistics? {
        let source = text as NSString
        guard range.length > 0, range.location >= 0, range.location <= source.length,
              range.length <= source.length - range.location else { return nil }
        return DocumentStatistics(text: source.substring(with: range))
    }

    static func sectionRange(at location: Int, in analysis: MarkdownAnalysis,
                             documentLength: Int) -> NSRange? {
        let entries = MarkdownOutline.entries(in: analysis)
        guard let current = entries.last(where: { $0.sourceRange.location <= location }),
              let index = entries.firstIndex(where: { $0.id == current.id }) else { return nil }
        let end = entries.dropFirst(index + 1).first { $0.level <= current.level }?
            .sourceRange.location ?? documentLength
        return NSRange(location: current.sourceRange.location,
                       length: max(0, end - current.sourceRange.location))
    }
}
