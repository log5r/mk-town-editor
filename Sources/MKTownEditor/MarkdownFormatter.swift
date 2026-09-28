import Foundation

enum MarkdownFormattingStyle {
    case bold
    case italic
    case inlineCode
    case link
    case heading
    case quote
    case unorderedList
}

struct MarkdownEdit: Equatable {
    let text: String
    let selection: NSRange
}

enum MarkdownFormatter {
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
        case .heading:
            return prefixLines(text, selection: safeSelection, prefix: "# ")
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
        let updated = nsText.replacingCharacters(in: selection, with: replacement)
        let prefixLength = (prefix as NSString).length
        let contentLength = (content as NSString).length
        return MarkdownEdit(
            text: updated,
            selection: NSRange(location: selection.location + prefixLength, length: contentLength)
        )
    }

    private static func link(_ text: String, selection: NSRange) -> MarkdownEdit {
        let nsText = text as NSString
        let selected = nsText.substring(with: selection)
        let label = selected.isEmpty ? "リンク" : selected
        let replacement = "[\(label)](https://)"
        let updated = nsText.replacingCharacters(in: selection, with: replacement)
        let urlStart = selection.location + ("[\(label)](" as NSString).length
        return MarkdownEdit(text: updated, selection: NSRange(location: urlStart, length: 8))
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
        let updated = nsText.replacingCharacters(in: lineRange, with: replacement)
        return MarkdownEdit(
            text: updated,
            selection: NSRange(location: lineRange.location, length: (replacement as NSString).length)
        )
    }

    private static func clamped(_ selection: NSRange, in text: String) -> NSRange {
        let length = (text as NSString).length
        let location = min(max(selection.location, 0), length)
        return NSRange(location: location, length: min(max(selection.length, 0), length - location))
    }
}
