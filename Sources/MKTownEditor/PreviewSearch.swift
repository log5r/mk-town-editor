import Foundation

struct PreviewSearchMatch: Identifiable, Equatable, Sendable {
    let range: NSRange
    let line: Int
    let excerpt: String

    var id: Int { range.location }
}

enum PreviewSearch {
    static func matches(in text: String, query: String, caseSensitive: Bool = false,
                        maximumResults: Int = 5_000) -> [PreviewSearchMatch] {
        guard !query.isEmpty else { return [] }
        let source = text as NSString
        let index = MarkdownLineIndex(text)
        let options: NSString.CompareOptions = caseSensitive ? [] : [.caseInsensitive]
        var results: [PreviewSearchMatch] = []
        var start = 0
        while start < source.length {
            // 検索語が変わって取り消された検索は、文書の末尾まで走査せずに終える。
            if Task.isCancelled { return results }
            let found = source.range(of: query, options: options,
                                     range: NSRange(location: start, length: source.length - start))
            if found.location == NSNotFound { break }
            let line = index.line(containingUTF16Offset: found.location)
            let lineStart = index.starts[line - 1]
            let lineEnd = line < index.lineCount ? index.starts[line] - 1 : source.length
            let excerpt = source.substring(with: NSRange(location: lineStart,
                                                          length: max(0, lineEnd - lineStart)))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            results.append(PreviewSearchMatch(range: found, line: line,
                                              excerpt: String(excerpt.prefix(240))))
            if results.count >= maximumResults { break }
            start = found.location + max(found.length, 1)
        }
        return results
    }

    static func next(in matches: [PreviewSearchMatch], after location: Int?,
                     backwards: Bool = false) -> PreviewSearchMatch? {
        guard !matches.isEmpty else { return nil }
        guard let location else { return backwards ? matches.last : matches.first }
        if backwards {
            return matches.last { $0.range.location < location } ?? matches.last
        }
        return matches.first { $0.range.location > location } ?? matches.first
    }
}
