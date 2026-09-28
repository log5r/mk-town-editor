import Foundation

enum MarkdownSymbolCompletion {
    static func edit(in text: String, selection: NSRange, typed: String) -> MarkdownEdit? {
        let source = text as NSString
        guard selection.location <= source.length,
              selection.length <= source.length - selection.location,
              typed.utf16.count == 1 else { return nil }
        let position = selection.location
        if isEscaped(source, at: position) { return nil }
        let isMarkdownMarker = typed == "`" || typed == "*" || typed == "_"
        if isMarkdownMarker {
            let inCodeBlock = MarkdownAnalysis(text).blocks.contains {
                $0.kind == .codeBlock && NSLocationInRange(position, $0.sourceRange)
            }
            let inCodeSpan = MarkdownInlineSyntax.codeSpanRanges(in: text).contains {
                position > $0.location && position < NSMaxRange($0)
            }
            if inCodeBlock || inCodeSpan { return nil }
        }

        let opening: String
        let closing: String
        switch typed {
        case "(": opening = "("; closing = ")"
        case "[": opening = "["; closing = "]"
        case "{": opening = "{"; closing = "}"
        case "*", "_": opening = typed; closing = typed
        case "`":
            let selected = source.substring(with: selection)
            var longest = 0
            var run = 0
            for scalar in selected.utf16 {
                if scalar == 96 { run += 1; longest = max(longest, run) }
                else { run = 0 }
            }
            opening = String(repeating: "`", count: max(1, longest + 1))
            closing = opening
        default: return nil
        }
        let selected = source.substring(with: selection)
        let replacement = opening + selected + closing
        return MarkdownEdit(range: selection, replacement: replacement,
                            selection: NSRange(location: position + (opening as NSString).length,
                                               length: selection.length))
    }

    private static func isEscaped(_ source: NSString, at position: Int) -> Bool {
        var cursor = position - 1
        while cursor >= 0 && source.character(at: cursor) == 92 { cursor -= 1 }
        return (position - cursor - 1) % 2 == 1
    }
}
