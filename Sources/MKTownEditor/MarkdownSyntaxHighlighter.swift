import AppKit
import Foundation

struct MarkdownSyntaxSpan: Equatable {
    enum Role: Equatable {
        case heading
        case code
        case link
        case marker
        case quoteMarker
        case listMarker
        case taskMarker
        case tableMarker
    }

    let range: NSRange
    let role: Role
}

@MainActor
enum MarkdownSyntaxHighlighter {
    private static let quoteExpression = try! NSRegularExpression(pattern: #"^[ \t]*(?:>[ \t]*)+"#)
    private static let listExpression = try! NSRegularExpression(
        pattern: #"^(?:[ \t]*>[ \t]*)*[ \t]*([-+*]|[0-9]{1,9}[.)])(?=[ \t])"#
    )
    private static let taskExpression = try! NSRegularExpression(
        pattern: #"^(?:[ \t]*>[ \t]*)*[ \t]*(?:[-+*]|[0-9]{1,9}[.)])[ \t]+(\[[ xX]\])"#
    )
    private static let linkExpression = try! NSRegularExpression(
        pattern: #"(?<!!)\[[^\]\n]+\](?:\([^\n]*?\)|\[[^\]\n]*\])"#
    )

    static func spans(in text: String) -> [MarkdownSyntaxSpan] {
        let source = text as NSString
        let analysis = MarkdownAnalysis(text)
        let codeBlocks = analysis.blocks.filter { $0.kind == .codeBlock }.map(\.sourceRange)
        var result: [MarkdownSyntaxSpan] = []
        for block in analysis.blocks {
            switch block.kind {
            case .heading:
                result.append(MarkdownSyntaxSpan(range: block.sourceRange, role: .heading))
            case .codeBlock:
                result.append(MarkdownSyntaxSpan(range: block.sourceRange, role: .code))
            case .horizontalRule:
                result.append(MarkdownSyntaxSpan(range: block.sourceRange, role: .marker))
            case .table:
                let range = block.sourceRange
                for offset in range.location..<NSMaxRange(range)
                where source.character(at: offset) == 124 {
                    result.append(MarkdownSyntaxSpan(range: NSRange(location: offset, length: 1),
                                                     role: .tableMarker))
                }
            default: break
            }
        }

        var cursor = 0
        while cursor < source.length {
            let lineRange = source.lineRange(for: NSRange(location: cursor, length: 0))
            if !codeBlocks.contains(where: { NSLocationInRange(lineRange.location, $0) }) {
                let line = source.substring(with: lineRange)
                let length = (line as NSString).length
                for (expression, role, group) in [
                    (quoteExpression, MarkdownSyntaxSpan.Role.quoteMarker, 0),
                    (listExpression, .listMarker, 1),
                    (taskExpression, .taskMarker, 1)
                ] {
                    if let match = expression.firstMatch(in: line, range: NSRange(location: 0, length: length)) {
                        let local = match.range(at: group)
                        result.append(MarkdownSyntaxSpan(
                            range: NSRange(location: lineRange.location + local.location, length: local.length),
                            role: role))
                    }
                }
            }
            cursor = NSMaxRange(lineRange)
        }

        let codeSpans = MarkdownInlineSyntax.codeSpanRanges(in: text).filter { span in
            !codeBlocks.contains(where: { NSIntersectionRange($0, span).length > 0 })
        }
        result += codeSpans.map { MarkdownSyntaxSpan(range: $0, role: .code) }
        for match in linkExpression.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            guard !isEscaped(source, at: match.range.location),
                  !overlaps(match.range, any: codeBlocks + codeSpans) else { continue }
            result.append(MarkdownSyntaxSpan(range: match.range, role: .link))
        }
        for marker in ["**", "__", "~~", "*", "_"] {
            let escaped = NSRegularExpression.escapedPattern(for: marker)
            let boundary = marker.count == 1 ? "(?<!\(escaped))" : ""
            let after = marker.count == 1 ? "(?!\(escaped))" : ""
            let expression = try! NSRegularExpression(
                pattern: boundary + escaped + after + #"([^\n]+?)"# + boundary + escaped + after
            )
            for match in expression.matches(in: text, range: NSRange(location: 0, length: source.length)) {
                let markerLength = (marker as NSString).length
                let opening = NSRange(location: match.range.location, length: markerLength)
                let closing = NSRange(location: NSMaxRange(match.range) - markerLength, length: markerLength)
                guard !isEscaped(source, at: opening.location),
                      !isEscaped(source, at: closing.location),
                      !overlaps(opening, any: codeBlocks + codeSpans),
                      !overlaps(closing, any: codeBlocks + codeSpans) else { continue }
                result.append(MarkdownSyntaxSpan(range: opening, role: .marker))
                result.append(MarkdownSyntaxSpan(range: closing, role: .marker))
            }
        }
        return result
    }

    static func apply(to textView: NSTextView) {
        guard !textView.hasMarkedText(), let layoutManager = textView.layoutManager else { return }
        let length = (textView.string as NSString).length
        guard length > 0 else { return }
        let fullRange = NSRange(location: 0, length: length)
        layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: fullRange)
        for span in spans(in: textView.string)
        where span.range.length > 0 && NSMaxRange(span.range) <= length {
            layoutManager.addTemporaryAttribute(.foregroundColor, value: color(for: span.role),
                                                 forCharacterRange: span.range)
        }
    }

    private static func color(for role: MarkdownSyntaxSpan.Role) -> NSColor {
        switch role {
        case .heading: .systemBlue
        case .code: .systemPurple
        case .link: .linkColor
        case .marker: .secondaryLabelColor
        case .quoteMarker: .systemTeal
        case .listMarker: .systemOrange
        case .taskMarker: .systemGreen
        case .tableMarker: .systemIndigo
        }
    }

    private static func overlaps(_ range: NSRange, any ranges: [NSRange]) -> Bool {
        ranges.contains { NSIntersectionRange(range, $0).length > 0 }
    }

    private static func isEscaped(_ source: NSString, at location: Int) -> Bool {
        var cursor = location - 1
        while cursor >= 0 && source.character(at: cursor) == 92 { cursor -= 1 }
        return (location - cursor - 1) % 2 == 1
    }
}
