import Foundation

/// Supported inline HTML is deliberately limited to plain text inside mark, sup and sub.
enum MarkdownInlineExtensions {
    enum Kind: String, Sendable {
        case mark, sup, sub
    }

    struct Item: Sendable {
        let kind: Kind
        let content: String
    }

    private static let pattern = try! NSRegularExpression(
        pattern: #"<(mark|sup|sub)>([^<>\r\n]+)</\1>"#, options: .caseInsensitive)

    static func placeholders(in source: String) -> (text: String, items: [(String, Item)]) {
        let text = source as NSString
        let codeRanges = MarkdownInlineSyntax.codeSpanRanges(in: source)
        var output = ""
        var items: [(String, Item)] = []
        var cursor = 0
        for match in pattern.matches(in: source, range: NSRange(location: 0, length: text.length)) {
            let start = match.range.location
            if codeRanges.contains(where: { NSLocationInRange(start, $0) }) ||
                isEscaped(text, at: start) { continue }
            guard let kind = Kind(rawValue: text.substring(with: match.range(at: 1)).lowercased()) else { continue }
            output += text.substring(with: NSRange(location: cursor, length: start - cursor))
            let token = "MKTOWNINLINEEXTENSION\(items.count)END"
            output += token
            items.append((token, Item(kind: kind, content: text.substring(with: match.range(at: 2)))))
            cursor = NSMaxRange(match.range)
        }
        output += text.substring(from: cursor)
        return (output, items)
    }

    static func plainText(in source: String) -> String {
        let parsed = placeholders(in: source)
        var output = parsed.text
        for (token, item) in parsed.items {
            output = output.replacingOccurrences(of: token, with: item.content)
        }
        return output
    }

    private static func isEscaped(_ source: NSString, at index: Int) -> Bool {
        var cursor = index - 1
        while cursor >= 0, source.character(at: cursor) == 92 { cursor -= 1 }
        return (index - cursor - 1) % 2 == 1
    }
}
