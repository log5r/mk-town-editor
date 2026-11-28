import Foundation

enum MarkdownWhitespaceTrim {
    /// Only the parts of line endings that are both removable and selected are changed.
    /// An empty selection applies the command to the whole document.
    static func edit(in text: String, selection: NSRange = NSRange(location: 0, length: 0),
                     includingWhitespaceOnlyLines: Bool,
                     dialect: MarkdownDialect, analysis: MarkdownAnalysis? = nil) -> MarkdownEdit? {
        let removals = removals(in: text, selection: selection,
                               includingWhitespaceOnlyLines: includingWhitespaceOnlyLines,
                               dialect: dialect, analysis: analysis)
        guard let first = removals.first, let last = removals.last else { return nil }
        let range = NSRange(location: first.location, length: NSMaxRange(last) - first.location)
        let source = text as NSString
        var replacement = ""
        var cursor = range.location
        for removal in removals {
            let untouched = NSRange(location: cursor, length: removal.location - cursor)
            replacement.append(source.substring(with: untouched))
            cursor = NSMaxRange(removal)
        }

        func mappedOffset(_ offset: Int) -> Int {
            offset - removals.prefix { $0.location < offset }.reduce(0) { removed, range in
                removed + min(range.length, max(0, offset - range.location))
            }
        }
        let start = mappedOffset(selection.location)
        let end = mappedOffset(NSMaxRange(selection))
        return MarkdownEdit(range: range, replacement: replacement,
                            selection: NSRange(location: start, length: end - start))
    }

    private static func removals(in text: String, selection: NSRange, includingWhitespaceOnlyLines: Bool,
                                 dialect: MarkdownDialect, analysis: MarkdownAnalysis?) -> [NSRange] {
        let source = text as NSString
        guard selection.location >= 0, selection.location <= source.length, selection.length >= 0,
              selection.length <= source.length - selection.location else { return [] }
        let target = selection.length > 0 ? selection : NSRange(location: 0, length: source.length)
        var candidates: [NSRange] = []
        var whitespaceOnlyCandidates = Set<NSRange>()
        var cursor = target.location
        while cursor < NSMaxRange(target) {
            var lineStart = 0, lineEnd = 0, contentEnd = 0
            source.getLineStart(&lineStart, end: &lineEnd, contentsEnd: &contentEnd,
                                for: NSRange(location: cursor, length: 0))
            cursor = lineEnd

            var whitespaceStart = contentEnd
            while whitespaceStart > lineStart {
                let unit = source.character(at: whitespaceStart - 1)
                guard unit == 32 || unit == 9 else { break }
                whitespaceStart -= 1
            }
            let suffix = NSRange(location: whitespaceStart, length: contentEnd - whitespaceStart)
            let removal = NSIntersectionRange(suffix, target)
            guard removal.length > 0 else { continue }
            if whitespaceStart == lineStart {
                guard includingWhitespaceOnlyLines else { continue }
                whitespaceOnlyCandidates.insert(removal)
            } else if lineEnd > contentEnd &&
                        !preservesLineBreak(in: source, lineStart: lineStart, suffix: suffix, removing: removal) {
                continue
            }
            candidates.append(removal)
        }
        guard !candidates.isEmpty else { return [] }

        let parsed = analysis ?? MarkdownAnalysis(text, dialect: dialect)
        let protected = protectedRanges(in: source, analysis: parsed, candidates: candidates)
        return candidates.filter { range in
            // An indented blank line can connect subsequent lines to a footnote definition.
            if whitespaceOnlyCandidates.contains(range),
               MarkdownInlineSyntax.intersects(range, sortedRanges: parsed.footnotes.definitionRanges) {
                return false
            }
            return !MarkdownInlineSyntax.intersects(range, sortedRanges: protected)
        }
    }

    private static func protectedRanges(in source: NSString, analysis: MarkdownAnalysis,
                                        candidates: [NSRange]) -> [NSRange] {
        var protected: [NSRange] = []
        func appendCodeSpans(in range: NSRange) {
            guard source.range(of: "`", options: .literal, range: range).location != NSNotFound else { return }
            let spans = MarkdownInlineSyntax.codeSpanRanges(in: source.substring(with: range))
            protected += spans.map { NSRange(location: range.location + $0.location, length: $0.length) }
        }

        for block in analysis.blocks where MarkdownInlineSyntax.intersects(block.sourceRange, sortedRanges: candidates) {
            switch block.kind {
            case .codeBlock:
                protected.append(block.sourceRange)
                continue
            case .unorderedList, .orderedList:
                // An empty list item still needs a separator after its marker.
                if block.content.isEmpty || block.content.first == "\n" {
                    protected.append(source.lineRange(for: NSRange(location: block.sourceRange.location, length: 0)))
                }
            case .paragraph, .heading:
                break
            default:
                continue
            }
            appendCodeSpans(in: block.sourceRange)
        }
        for definition in analysis.footnotes.definitionRanges
            where MarkdownInlineSyntax.intersects(definition, sortedRanges: candidates) {
            appendCodeSpans(in: definition)
        }
        if let frontMatter = analysis.frontMatter { protected.append(frontMatter.sourceRange) }
        // A block can span a region the parser masked. Merge overlaps before binary search.
        return protected.sorted { $0.location < $1.location }.reduce(into: [NSRange]()) { ranges, range in
            if let last = ranges.last, NSMaxRange(last) > range.location {
                ranges[ranges.count - 1] = NSUnionRange(last, range)
            } else {
                ranges.append(range)
            }
        }
    }

    private static func preservesLineBreak(in source: NSString, lineStart: Int,
                                           suffix: NSRange, removing removal: NSRange) -> Bool {
        let end = NSMaxRange(suffix)
        // Keep an existing hard break including any whitespace before its two final spaces.
        if suffix.length >= 2, source.character(at: end - 1) == 32,
           source.character(at: end - 2) == 32 { return false }

        switch suffix.length - removal.length {
        case 0:
            // Removing everything after an unescaped backslash would introduce a hard break.
            var start = suffix.location
            while start > lineStart, source.character(at: start - 1) == 92 { start -= 1 }
            return (suffix.location - start).isMultiple(of: 2)
        case 1:
            return true
        default:
            // A partial selection can leave two newly adjacent spaces at the end of the line.
            let afterRemoval = end - NSMaxRange(removal)
            let last = afterRemoval > 0 ? end - 1 : removal.location - 1
            let previous = afterRemoval > 1 ? end - 2 : removal.location - (2 - afterRemoval)
            return source.character(at: last) != 32 || source.character(at: previous) != 32
        }
    }
}
