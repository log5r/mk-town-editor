import Foundation

struct FrontMatterProperty: Identifiable, Equatable {
    let key: String
    let value: String
    let valueRange: NSRange
    let lineRange: NSRange

    var id: String { key }
}

enum FrontMatterProperties {
    private static let entryPattern = try! NSRegularExpression(
        pattern: #"^([A-Za-z][A-Za-z0-9_-]*):[ \t]*(.*)$"#)
    private static let keyPattern = try! NSRegularExpression(
        pattern: #"^[A-Za-z][A-Za-z0-9_-]*$"#)

    static func items(in source: String) -> [FrontMatterProperty] {
        var seen: Set<String> = []
        return lines(in: source).compactMap { row in
            guard let property = row.property,
                  seen.insert(row.key.lowercased()).inserted else { return nil }
            return property
        }
    }

    static func upsert(in source: String, key: String, value: String) -> MarkdownEdit? {
        guard valid(key: key, value: value) else { return nil }
        let rows = lines(in: source)
        if let existing = rows.first(where: { $0.key.caseInsensitiveCompare(key) == .orderedSame }) {
            guard let property = existing.property else { return nil }
            let text = source as NSString
            let beforeComment = property.valueRange.length == 0 &&
                property.valueRange.location < text.length &&
                text.character(at: property.valueRange.location) == 35
            return edit(range: property.valueRange,
                        replacement: beforeComment ? value + " " : value)
        }
        let newline = source.contains("\r\n") ? "\r\n" : "\n"
        if let frontMatter = MarkdownFrontMatter(source: source),
           let closing = closingLineStart(in: source, frontMatter: frontMatter) {
            return edit(range: NSRange(location: closing, length: 0),
                        replacement: "\(key): \(value)\(newline)")
        }
        return edit(range: NSRange(location: 0, length: 0),
                    replacement: "---\(newline)\(key): \(value)\(newline)---\(newline)")
    }

    static func remove(in source: String, key: String) -> MarkdownEdit? {
        guard let row = lines(in: source).first(where: {
            $0.key.caseInsensitiveCompare(key) == .orderedSame
        }), row.property != nil else { return nil }
        return edit(range: row.lineRange, replacement: "")
    }

    private static func valid(key: String, value: String) -> Bool {
        let keyLength = (key as NSString).length
        let valueText = value as NSString
        var trimmedEnd = valueText.length
        while trimmedEnd > 0 &&
            (valueText.character(at: trimmedEnd - 1) == 32 ||
             valueText.character(at: trimmedEnd - 1) == 9) {
            trimmedEnd -= 1
        }
        return keyLength > 0 && keyLength <= 80 && value.utf16.count <= 2_000 &&
            !value.contains("\n") && !value.contains("\r") &&
            scalarEnd(in: valueText, start: 0, end: valueText.length) == trimmedEnd &&
            keyPattern.firstMatch(in: key, range: NSRange(location: 0, length: keyLength)) != nil
    }

    private static func edit(range: NSRange, replacement: String) -> MarkdownEdit {
        MarkdownEdit(range: range, replacement: replacement,
                     selection: NSRange(location: range.location + (replacement as NSString).length,
                                        length: 0))
    }

    private struct Row {
        let key: String
        let lineRange: NSRange
        let property: FrontMatterProperty?
    }

    private static func lines(in source: String) -> [Row] {
        guard let frontMatter = MarkdownFrontMatter(source: source) else { return [] }
        let text = source as NSString
        let starts = MarkdownLineIndex(source, through: NSMaxRange(frontMatter.sourceRange)).starts
        var rows: [Row] = []
        for index in 1..<starts.count {
            let start = starts[index]
            guard start < NSMaxRange(frontMatter.sourceRange) else { break }
            let end = index + 1 < starts.count ? starts[index + 1] : text.length
            let full = NSRange(location: start, length: end - start)
            let line = text.substring(with: full).trimmingCharacters(in: .newlines)
            if line == "---" || line == "..." { break }
            let lineLength = (line as NSString).length
            guard let match = entryPattern.firstMatch(in: line,
                range: NSRange(location: 0, length: lineLength)) else { continue }
            let key = (line as NSString).substring(with: match.range(at: 1))
            let rawValue = match.range(at: 2)
            let valueStart = start + rawValue.location
            let valueEnd = scalarEnd(in: text, start: valueStart,
                                     end: valueStart + rawValue.length)
            let valueRange = NSRange(location: valueStart, length: valueEnd - valueStart)
            let value = text.substring(with: valueRange)
            let isComplex = (value.isEmpty || value.hasPrefix("|") || value.hasPrefix(">")) &&
                hasNestedLine(after: index, starts: starts, in: text,
                              before: NSMaxRange(frontMatter.sourceRange))
            let property = isComplex ? nil : FrontMatterProperty(key: key, value: value,
                valueRange: valueRange, lineRange: full)
            rows.append(Row(key: key, lineRange: full, property: property))
        }
        return rows
    }

    private static func hasNestedLine(after index: Int, starts: [Int], in text: NSString,
                                      before boundary: Int) -> Bool {
        guard index + 1 < starts.count else { return false }
        for next in (index + 1)..<starts.count {
            let start = starts[next]
            guard start < boundary else { return false }
            let end = next + 1 < starts.count ? starts[next + 1] : text.length
            let line = text.substring(with: NSRange(location: start, length: end - start))
                .trimmingCharacters(in: .newlines)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            return line.first == " " || line.first == "\t"
        }
        return false
    }

    private static func scalarEnd(in text: NSString, start: Int, end: Int) -> Int {
        var quote: unichar = 0
        var cursor = start
        var contentEnd = end
        while cursor < end {
            let unit = text.character(at: cursor)
            if quote == 34 && unit == 92 && cursor + 1 < end {
                cursor += 2
                continue
            }
            if quote == 39 && unit == 39 && cursor + 1 < end &&
               text.character(at: cursor + 1) == 39 {
                cursor += 2
                continue
            }
            if quote == 0 && (unit == 34 || unit == 39) {
                quote = unit
            } else if quote == unit {
                quote = 0
            } else if quote == 0 && unit == 35 &&
                        (cursor == start || text.character(at: cursor - 1) == 32 ||
                         text.character(at: cursor - 1) == 9) {
                contentEnd = cursor
                break
            }
            cursor += 1
        }
        while contentEnd > start &&
            (text.character(at: contentEnd - 1) == 32 || text.character(at: contentEnd - 1) == 9) {
            contentEnd -= 1
        }
        return contentEnd
    }

    private static func closingLineStart(in source: String,
                                         frontMatter: MarkdownFrontMatter) -> Int? {
        let text = source as NSString
        let starts = MarkdownLineIndex(source, through: NSMaxRange(frontMatter.sourceRange)).starts
        for index in 1..<starts.count {
            let start = starts[index]
            guard start < NSMaxRange(frontMatter.sourceRange) else { break }
            let end = index + 1 < starts.count ? starts[index + 1] : text.length
            let line = text.substring(with: NSRange(location: start, length: end - start))
                .trimmingCharacters(in: .newlines)
            if line == "---" || line == "..." { return start }
        }
        return nil
    }
}
