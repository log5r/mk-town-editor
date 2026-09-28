import Foundation

struct MarkdownTableDraft: Identifiable {
    let id = UUID()
    let range: NSRange
    let originalText: String
}

enum MarkdownTableInsertion {
    static func draft(in text: String, selection: NSRange) -> MarkdownTableDraft {
        let length = (text as NSString).length
        let location = min(max(selection.location, 0), length)
        let safe = NSRange(location: location,
                           length: min(max(selection.length, 0), length - location))
        return MarkdownTableDraft(range: safe, originalText: text)
    }

    static func edit(in text: String, draft: MarkdownTableDraft,
                     rows: Int, columns: Int) -> MarkdownEdit? {
        let source = text as NSString
        guard text == draft.originalText,
              (1...20).contains(rows), (1...12).contains(columns),
              draft.range.location <= source.length,
              NSMaxRange(draft.range) <= source.length else { return nil }
        let newline = text.contains("\r\n") ? "\r\n" : text.contains("\r") ? "\r" : "\n"
        let before = source.substring(to: draft.range.location)
        let after = source.substring(from: NSMaxRange(draft.range))
        let leading = spacing(before: before, newline: newline)
        let trailing = spacing(after: after, newline: newline)
        let header = "| " + (1...columns).map { "列\($0)" }.joined(separator: " | ") + " |"
        let delimiter = "| " + Array(repeating: "---", count: columns).joined(separator: " | ") + " |"
        let row = "| " + Array(repeating: " ", count: columns).joined(separator: " | ") + " |"
        let table = ([header, delimiter] + Array(repeating: row, count: rows)).joined(separator: newline)
        let replacement = leading + table + trailing
        return MarkdownEdit(range: draft.range, replacement: replacement,
                            selection: NSRange(location: draft.range.location + (leading as NSString).length + 2,
                                               length: ("列1" as NSString).length))
    }

    private static func spacing(before text: String, newline: String) -> String {
        if text.isEmpty || text.hasSuffix(newline + newline) { return "" }
        return text.hasSuffix(newline) ? newline : newline + newline
    }

    private static func spacing(after text: String, newline: String) -> String {
        if text.isEmpty || text.hasPrefix(newline + newline) { return "" }
        return text.hasPrefix(newline) ? newline : newline + newline
    }
}
