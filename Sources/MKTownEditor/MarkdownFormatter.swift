import Foundation

enum MarkdownFormattingStyle {
    case bold
    case italic
    case inlineCode
    case link
    case heading(level: Int)
    case quote
    case unorderedList
}

struct MarkdownEdit: Equatable {
    let range: NSRange
    let replacement: String
    let selection: NSRange

    func applying(to text: String) -> String {
        (text as NSString).replacingCharacters(in: range, with: replacement)
    }
}

enum MarkdownFormatter {
    private static let headingExpression = try! NSRegularExpression(pattern: #"^( {0,3})(#{1,6})(?:[ \t]+|$)"#)

    static func apply(
        _ style: MarkdownFormattingStyle,
        to text: String,
        selection: NSRange
    ) -> MarkdownEdit {
        let safeSelection = clamped(selection, in: text)

        switch style {
        case .bold:
            return wrap(text, selection: safeSelection, prefix: "**", suffix: "**", placeholder: "太字")
        case .italic:
            return wrap(text, selection: safeSelection, prefix: "_", suffix: "_", placeholder: "斜体")
        case .inlineCode:
            return wrap(text, selection: safeSelection, prefix: "`", suffix: "`", placeholder: "コード")
        case .link:
            return link(text, selection: safeSelection)
        case let .heading(level):
            return heading(text, selection: safeSelection, level: level)
        case .quote:
            return prefixLines(text, selection: safeSelection, prefix: "> ")
        case .unorderedList:
            return prefixLines(text, selection: safeSelection, prefix: "- ")
        }
    }

    private static func wrap(
        _ text: String,
        selection: NSRange,
        prefix: String,
        suffix: String,
        placeholder: String
    ) -> MarkdownEdit {
        let nsText = text as NSString
        let selected = nsText.substring(with: selection)
        let content = selected.isEmpty ? placeholder : selected
        let replacement = prefix + content + suffix
        let prefixLength = (prefix as NSString).length
        let contentLength = (content as NSString).length
        return MarkdownEdit(
            range: selection,
            replacement: replacement,
            selection: NSRange(location: selection.location + prefixLength, length: contentLength)
        )
    }

    private static func link(_ text: String, selection: NSRange) -> MarkdownEdit {
        let nsText = text as NSString
        let selected = nsText.substring(with: selection)
        let label = selected.isEmpty ? "リンク" : selected
        let replacement = "[\(label)](https://)"
        let urlStart = selection.location + ("[\(label)](" as NSString).length
        return MarkdownEdit(range: selection, replacement: replacement, selection: NSRange(location: urlStart, length: 8))
    }

    private static func prefixLines(_ text: String, selection: NSRange, prefix: String) -> MarkdownEdit {
        let nsText = text as NSString
        let lineRange = nsText.lineRange(for: selection)
        let lines = nsText.substring(with: lineRange)
        let endsWithNewline = lines.hasSuffix("\n")
        let body = endsWithNewline ? String(lines.dropLast()) : lines
        let replacement = body
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { prefix + $0 }
            .joined(separator: "\n") + (endsWithNewline ? "\n" : "")
        return MarkdownEdit(
            range: lineRange,
            replacement: replacement,
            selection: NSRange(location: lineRange.location, length: (replacement as NSString).length)
        )
    }

    private static func heading(_ text: String, selection: NSRange, level: Int) -> MarkdownEdit {
        precondition((0...6).contains(level))
        let source = text as NSString
        let lineRange = source.lineRange(for: selection)
        var replacement = ""
        var cursor = lineRange.location
        let upper = NSMaxRange(lineRange)

        repeat {
            var lineStart = 0
            var lineEnd = 0
            var contentsEnd = 0
            source.getLineStart(&lineStart, end: &lineEnd, contentsEnd: &contentsEnd,
                                for: NSRange(location: cursor, length: 0))
            let content = source.substring(with: NSRange(location: lineStart, length: contentsEnd - lineStart))
            let ending = source.substring(with: NSRange(location: contentsEnd, length: lineEnd - contentsEnd))
            replacement += headingLine(content, level: level) + ending
            cursor = lineEnd
        } while cursor < upper

        let newSelection: NSRange
        if selection.length == 0 && lineRange.length == 0 && level > 0 {
            newSelection = NSRange(location: lineRange.location + level + 1, length: 0)
        } else {
            newSelection = NSRange(location: lineRange.location, length: (replacement as NSString).length)
        }
        return MarkdownEdit(range: lineRange, replacement: replacement, selection: newSelection)
    }

    private static func headingLine(_ line: String, level: Int) -> String {
        let nsLine = line as NSString
        guard let match = headingExpression.firstMatch(in: line, range: NSRange(location: 0, length: nsLine.length)) else {
            return level == 0 ? line : String(repeating: "#", count: level) + " " + line
        }
        let indentation = nsLine.substring(with: match.range(at: 1))
        var content = nsLine.substring(from: NSMaxRange(match.range))
        content = content.replacingOccurrences(of: #"[ \t]+#+[ \t]*$"#, with: "", options: .regularExpression)
        return indentation + (level == 0 ? "" : String(repeating: "#", count: level) + " ") + content
    }

    private static func clamped(_ selection: NSRange, in text: String) -> NSRange {
        let length = (text as NSString).length
        let location = min(max(selection.location, 0), length)
        return NSRange(location: location, length: min(max(selection.length, 0), length - location))
    }
}
