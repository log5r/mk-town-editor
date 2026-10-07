import Foundation

enum MarkdownSymbolCompletion {
    static func edit(in text: String, selection: NSRange, typed: String,
                     analysis: MarkdownAnalysis? = nil, inlineCodeRanges: [NSRange]? = nil,
                     allowsAnalysis: Bool = true) -> MarkdownEdit? {
        let source = text as NSString
        guard selection.location <= source.length,
              selection.length <= source.length - selection.location,
              typed.utf16.count == 1 else { return nil }
        let position = selection.location
        if isEscaped(source, at: position) { return nil }
        let isMarkdownMarker = typed == "`" || typed == "*" || typed == "_"
        if isMarkdownMarker {
            let inCodeBlock = MarkdownEditingContext.isInCode(at: position, source: text,
                analysis: analysis, allowsAnalysis: allowsAnalysis)
            guard !inCodeBlock else { return nil }
            // Inline code may span lines. Use background ranges when available;
            // pending large documents must not trigger an unbounded keystroke scan.
            guard inlineCodeRanges != nil || allowsAnalysis || source.length <= 8_192 else { return nil }
            let inCodeSpan = (inlineCodeRanges ?? MarkdownInlineSyntax.codeSpanRanges(in: text)).contains {
                position > $0.location && position < NSMaxRange($0)
            }
            if inCodeSpan { return nil }
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
        if selection.length == 0, position < source.length,
           source.substring(with: NSRange(location: position, length: 1)) == closing {
            return nil
        }
        let selected = source.substring(with: selection)
        let replacement = opening + selected + closing
        return MarkdownEdit(range: selection, replacement: replacement,
                            selection: NSRange(location: position + (opening as NSString).length,
                                               length: selection.length))
    }

    static func isEscaped(_ source: NSString, at position: Int) -> Bool {
        var cursor = position - 1
        while cursor >= 0 && source.character(at: cursor) == 92 { cursor -= 1 }
        return (position - cursor - 1) % 2 == 1
    }
}

/// Only delimiters inserted by this editor may be consumed without editing text.
struct MarkdownAutomaticClosers {
    struct Closer {
        var location: Int
        var openingStart: Int
        let marker: String
    }
    private var closers: [Closer] = []

    mutating func clear() { closers.removeAll() }

    mutating func edited(range: NSRange, delta: Int) {
        closers = closers.compactMap { item in
            if NSLocationInRange(item.location, range) || NSLocationInRange(item.openingStart, range) { return nil }
            var item = item
            if item.location >= NSMaxRange(range) { item.location += delta }
            if item.openingStart >= NSMaxRange(range) { item.openingStart += delta }
            return item
        }
    }

    func closer(at location: Int, typed: String, source: String) -> Closer? {
        guard let item = closers.first(where: { $0.location == location && $0.marker == typed }),
              location < source.utf16.count,
              (source as NSString).substring(with: NSRange(location: location, length: 1)) == typed else { return nil }
        return item
    }

    enum Match {
        /// The typed marker lengthens a balanced pair, e.g. "*|*" to "**|**".
        case extendsOpening
        /// Tracked closers already outnumber the opening run (after Backspace inside a pair);
        /// the typed marker is inserted literally, which restores the balance.
        case exceedsOpening
        /// A plain closer that the caret steps over.
        case closes
    }

    func match(_ item: Closer, at location: Int, source: String) -> Match {
        guard ["*", "_", "`"].contains(item.marker), item.openingStart < location else { return .closes }
        let text = source as NSString
        let opening = text.substring(with: NSRange(location: item.openingStart, length: location - item.openingStart))
        guard opening.allSatisfy({ String($0) == item.marker }) else { return .closes }
        var closing = 0
        while location + closing < text.length,
              text.substring(with: NSRange(location: location + closing, length: 1)) == item.marker,
              closers.contains(where: { $0.location == location + closing && $0.marker == item.marker }) {
            closing += 1
        }
        if closing == opening.utf16.count { return .extendsOpening }
        return closing > opening.utf16.count ? .exceedsOpening : .closes
    }

    mutating func consume(at location: Int) { closers.removeAll { $0.location == location } }

    mutating func register(edit: MarkdownEdit, typed: String, openingStart: Int? = nil) {
        let closing: String
        switch typed {
        case "(": closing = ")"
        case "[": closing = "]"
        case "{": closing = "}"
        default: closing = typed
        }
        // A wrapped selection may use a longer backtick delimiter.
        let openingLength = edit.selection.location - edit.range.location
        let closingLength = edit.replacement.utf16.count - openingLength - edit.range.length
        let start = edit.range.location + edit.replacement.utf16.count - closingLength
        for offset in 0..<max(0, closingLength) {
            closers.append(Closer(location: start + offset,
                openingStart: openingStart ?? edit.range.location, marker: closing))
        }
    }
}
