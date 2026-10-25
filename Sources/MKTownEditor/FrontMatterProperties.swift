import Foundation

struct FrontMatterProperty: Identifiable, Equatable {
    let key: String
    let value: String
    let valueRange: NSRange
    let lineRange: NSRange

    var id: String { key }
}

/// A conservative presentation of common Obsidian properties, not a general YAML decoder.
/// Unsupported values retain their YAML; unsupported document structures use the raw view.
enum FrontMatterPreviewProperties {
    struct Row: Equatable {
        let key: String
        let values: [String]
        let isVerbatim: Bool
    }

    private static let entry = try! NSRegularExpression(
        pattern: #"^([\p{L}\p{N}_][\p{L}\p{N}_ -]*):(?:[ \t]+(.*)|$)"#)

    static func rows(in frontMatter: MarkdownFrontMatter) -> [Row]? {
        var entries: [(key: String, lines: [String])] = []
        let content = frontMatter.content.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        for line in content.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                if !entries.isEmpty { entries[entries.count - 1].lines.append(line) }
                continue
            }
            let text = line as NSString
            if let match = entry.firstMatch(in: line, range: NSRange(location: 0, length: text.length)) {
                let valueRange = match.range(at: 2)
                entries.append((text.substring(with: match.range(at: 1)),
                    [valueRange.location == NSNotFound ? "" : text.substring(with: valueRange)]))
            } else if !entries.isEmpty && (line.first?.isWhitespace == true || trimmed.hasPrefix("- ")) {
                entries[entries.count - 1].lines.append(line)
            } else {
                return nil
            }
        }
        return entries.map { item in
            let first = item.lines[0]
            let continuation = item.lines.dropFirst().filter {
                let trimmed = $0.trimmingCharacters(in: .whitespaces)
                return !trimmed.isEmpty && !trimmed.hasPrefix("#")
            }
            if continuation.isEmpty {
                if let values = inlineList(first) {
                    return Row(key: item.key, values: values, isVerbatim: false)
                }
                if let value = scalar(first) {
                    return Row(key: item.key, values: [value], isVerbatim: false)
                }
            } else if scalar(first) == "" {
                var values: [String] = []
                var indentation: Int?
                for line in continuation {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    let width = line.prefix(while: { $0 == " " }).count
                    guard (indentation == nil || indentation == width), trimmed.hasPrefix("- "),
                          let value = scalar(String(trimmed.dropFirst(2))), !value.isEmpty else {
                        return Row(key: item.key, values: [item.lines.joined(separator: "\n")], isVerbatim: true)
                    }
                    indentation = width
                    values.append(value)
                }
                return Row(key: item.key, values: values, isVerbatim: false)
            }
            return Row(key: item.key, values: [item.lines.joined(separator: "\n")], isVerbatim: true)
        }
    }

    private static func scalar(_ source: String) -> String? {
        let value = source.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("\"") {
            // JSON's quoted strings are a safe subset of YAML's double-quoted strings.
            // YAML-specific escapes remain verbatim rather than being misinterpreted.
            var escaped = false
            for index in value.indices.dropFirst() {
                let character = value[index]
                if !escaped && character == "\"" {
                    let suffix = value[value.index(after: index)...].trimmingCharacters(in: .whitespaces)
                    guard suffix.isEmpty || suffix.hasPrefix("#"),
                          let data = String(value[...index]).data(using: .utf8) else { return nil }
                    return (try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)) as? String
                }
                if character == "\\" { escaped.toggle() } else { escaped = false }
            }
            return nil
        }
        if value.hasPrefix("'") {
            var cursor = value.index(after: value.startIndex)
            var result = ""
            while cursor < value.endIndex {
                let next = value.index(after: cursor)
                if value[cursor] == "'" {
                    if next < value.endIndex && value[next] == "'" {
                        result.append("'")
                        cursor = value.index(after: next)
                        continue
                    }
                    let suffix = value[next...].trimmingCharacters(in: .whitespaces)
                    return suffix.isEmpty || suffix.hasPrefix("#") ? result : nil
                }
                result.append(value[cursor])
                cursor = next
            }
            return nil
        }
        let uncommented: String
        if let comment = value.range(of: #"(^|\s)#"#, options: .regularExpression) {
            uncommented = String(value[..<comment.lowerBound]).trimmingCharacters(in: .whitespaces)
        } else { uncommented = value }
        guard !uncommented.contains(": "), !uncommented.contains(":\t"),
              uncommented != "-", !uncommented.hasPrefix("- "),
              uncommented.first.map({ !"[]{}&*!|>@`%,?:".contains($0) }) ?? true else { return nil }
        return uncommented
    }

    private static func inlineList(_ source: String) -> [String]? {
        let value = source.trimmingCharacters(in: .whitespaces)
        guard value.first == "[" else { return nil }
        var result: [String] = []
        var part = ""
        var quote: Character?
        var escaped = false
        for index in value.indices.dropFirst() {
            let character = value[index]
            if let current = quote {
                part.append(character)
                if !escaped && character == current { quote = nil }
                if current == "\"" && character == "\\" { escaped.toggle() } else { escaped = false }
            } else if (character == "\"" || character == "'") && part.trimmingCharacters(in: .whitespaces).isEmpty {
                quote = character
                part.append(character)
            } else if character == "," || character == "]" {
                if !part.trimmingCharacters(in: .whitespaces).isEmpty {
                    guard let item = scalar(part), !item.isEmpty else { return nil }
                    result.append(item)
                } else if character == "," { return nil }
                part = ""
                if character == "]" {
                    let suffix = value[value.index(after: index)...].trimmingCharacters(in: .whitespaces)
                    return suffix.isEmpty || suffix.hasPrefix("#") ? result : nil
                }
            } else if character == "[" || character == "{" || character == "}" ||
                        (character == "#" && (part.isEmpty || part.last?.isWhitespace == true)) {
                return nil
            } else { part.append(character) }
        }
        return nil
    }
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
